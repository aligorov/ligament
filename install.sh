#!/usr/bin/env bash
# =============================================================================
# Ligament 2FA — быстрое развёртывание одной командой (готовый образ Docker Hub)
#
#   curl -fsSL .../install.sh | bash          # localhost:80, авто-пароль БД
#   ./install.sh --http-port 8080             # свой HTTP-порт (без root)
#   ./install.sh --tag v0.8.22                # пин конкретной версии
#   ./install.sh --set-password '...'         # свой пароль БД (иначе сгенерится)
#
# Что делает:
#   1. Проверяет docker/compose и СВОБОДНОСТЬ портов (80/8080 tcp, 1812/1813 udp);
#   2. Генерирует и НАВСЕГДА сохраняет пароль PostgreSQL в .env (chmod 600) —
#      при повторных запусках переиспользуется (смена = потеря БД);
#   3. Поднимает postgres+ligament, ждёт /healthz;
#   4. Выкладывает admin_password.txt и admin_recovery_codes.txt рядом со скриптом.
# =============================================================================
set -euo pipefail

compose_file="docker-compose.yml"
env_file=".env"
http_port="" app_port="" radius_auth="" radius_acct=""
image_tag="" pg_password="" fresh=0

# ---------- вывод ----------
say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- аргументы ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --http-port)   http_port="${2:?}"; shift 2 ;;
    --app-port)    app_port="${2:?}"; shift 2 ;;
    --radius-auth) radius_auth="${2:?}"; shift 2 ;;
    --radius-acct) radius_acct="${2:?}"; shift 2 ;;
    --tag)         image_tag="${2:?}"; shift 2 ;;
    --set-password) pg_password="${2:?}"; shift 2 ;;
    --fresh)        fresh=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

cd "$(dirname "$0")"

# ---------- зависимости ----------
say "Проверка зависимостей"
command -v docker >/dev/null || die "docker не найден: установите Docker (https://docs.docker.com/engine/install/)"
docker compose version >/dev/null 2>&1 || die "docker compose (v2 plugin) не найден"
docker info >/dev/null 2>&1 || die "docker-демон недоступен (запущен ли сервис? права группы docker?)"
[[ -f "$compose_file" ]] || die "не найден $compose_file — запускайте из корня репозитория ligament"

# ---------- порты ----------
port_busy_tcp() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"
  elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else warn "нет ss/netstat/lsof — проверку порта $p пропускаю"; return 1; fi
}
port_busy_udp() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -lunH "( sport = :$p )" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1 && netstat -lun >/dev/null 2>&1; then netstat -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"
  else warn "нет ss/netstat — системную проверку udp/$p пропускаю"; return 1; fi
}
docker_busy() { # порт, занятый ДРУГИМ контейнером (на macOS/Windows ss его не видит)
  local p="$1"
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "[:.]${p}->"
}

say "Проверка свободности портов"
P_HTTP="${http_port:-80}"; P_APP="${app_port:-8080}"
P_AUTH="${radius_auth:-1812}"; P_ACCT="${radius_acct:-1813}"
for p in "$P_HTTP" "$P_APP"; do
  port_busy_tcp "$p" && die "порт tcp/$p занят процессом хоста (--http-port/--app-port, или: sudo ss -ltnp | grep :$p)"
  docker_busy "$p" && die "порт tcp/$p занят другим контейнером (docker ps --format '{{.Ports}}' | grep $p)"
done
for p in "$P_AUTH" "$P_ACCT"; do
  { port_busy_udp "$p" || docker_busy "$p"; } && warn "udp/$p занят — RADIUS-порты можно сменить (--radius-auth/--radius-acct)"
done
if [[ "$P_HTTP" == "$P_APP" ]]; then die "--http-port и --app-port совпадают ($P_HTTP)"; fi
if [[ "$P_HTTP" -lt 1024 || "$P_APP" -lt 1024 ]] && [[ "$(id -u)" != "0" ]] && [[ "$(uname)" == "Linux" ]]; then
  warn "порт <1024 без root: docker обычно справляется через capabilities, при ошибке bind — sudo или порт ≥1024"
fi

# ---------- осиротевший volume прошлой установки ----------
# Проект compose = имя каталога; volume БД переживает down и даже удаление
# каталога. Свежий .env + старый volume = вечный SASL-отказ (именно это
# ловили на живом сервере). На свежей установке без .env наличие volume —
# стоп с двумя выходами: вернуть старый .env или --fresh (снести БД).
proj_name="$(basename "$PWD")"
vol_db="${proj_name}_twofa_pgdata"
have_env=0; [[ -f "$env_file" && -s "$env_file" ]] && have_env=1
if [[ "$have_env" -eq 0 ]] && docker volume inspect "$vol_db" >/dev/null 2>&1; then
  if [[ "$fresh" -eq 1 ]]; then
    warn "Найден volume прошлой установки: $vol_db — удаляю (--fresh)"
    docker volume rm "$vol_db" >/dev/null
  else
    die "Найдена БД прошлой установки (volume $vol_db), а $env_file с её паролем — нет.
    Варианты:
      a) перенесите сюда СТАРЫЙ .env той установки (данные сохранятся);
      b) данные не нужны: ./install.sh --fresh  (БД будет пересоздана с нуля);
      c) своё имя каталога = отдельный проект docker (volume не пересечётся)."
  fi
fi

# ---------- пароли ----------
say "Пароли"
gen_pass() { (command -v openssl >/dev/null && openssl rand -base64 24 | tr -d '/+=' | head -c 28) || (LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28); }
if [[ -f "$env_file" ]] && grep -q '^TWOFA_PG_PASSWORD=' "$env_file"; then
  say "Найден $env_file — пароль БД переиспользуется (смена пароля = потеря базы)"
  # shellcheck disable=SC1091
  set -a; source "$env_file"; set +a
else
  [[ -n "$pg_password" ]] || pg_password="$(gen_pass)"
  printf 'TWOFA_PG_PASSWORD=%s\n' "$pg_password" > "$env_file"
  chmod 600 "$env_file"
  say "Сгенерирован пароль PostgreSQL и сохранён в $env_file (chmod 600)"
fi
[[ -n "$image_tag" ]] && printf 'TWOFA_IMAGE_TAG=%s\n' "$image_tag" >> "$env_file"
# Порты в .env — compose подставляет их сам (дефолты в docker-compose.yml).
# 80 и 8080 оба ведут на web-порт контейнера: 80 — для ACME/plain-прокси,
# 8080 — прямое обращение. Повторный запуск обновляет значения (не дублирует).
upsert_env() { # key value
  if grep -q "^$1=" "$env_file" 2>/dev/null; then
    sed -i.bak "s|^$1=.*|$1=$2|" "$env_file" && rm -f "$env_file.bak"
  else
    printf '%s=%s\n' "$1" "$2" >> "$env_file"
  fi
}
upsert_env LIG_HTTP_PORT   "$P_HTTP"
upsert_env LIG_APP_PORT    "$P_APP"
upsert_env LIG_RADIUS_AUTH "$P_AUTH"
upsert_env LIG_RADIUS_ACCT "$P_ACCT"
[[ -n "$image_tag" ]] && { upsert_env TWOFA_IMAGE_TAG "$image_tag"; say "Версия образа закреплена: $image_tag"; }

# ---------- развёртывание ----------
dc() { docker compose --env-file "$env_file" -f "$compose_file" "$@"; }

say "Pull образов"
dc pull --quiet

say "Запуск (db → ligament)"
dc up -d

# ---------- здоровье ----------
probe_port="${P_APP}"
[[ -n "$app_port" ]] || probe_port="$P_HTTP"
say "Ожидание /healthz на :$probe_port (до 120с)"
ok=""
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:${probe_port}/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [[ -z "$ok" ]]; then
  warn "healthz не ответил — смотри: dc logs twofa | tail -50"
  if dc logs twofa 2>/dev/null | tail -50 | grep -q "password authentication failed"; then
    warn "Пароль БД не совпадает с volume twofa_pgdata (пароль из старого .env потерян?)."
    warn "  Верните старый .env, либо (данные не нужны):"
    warn "    cd \"$PWD\" && docker compose --env-file .env -f docker-compose.yml down -v && rm -f .env && ./install.sh --fresh"
  fi
  dc ps
  exit 1
fi
host_hint="$(hostname 2>/dev/null || echo localhost)"
say "Сервер здоров: http://${host_hint}:${probe_port}/healthz → ok"

# ---------- админ-доступ ----------
say "Извлечение учётных данных администратора"
cid="$(dc ps -q twofa)"
for f in admin_password.txt admin_recovery_codes.txt; do
  if docker cp "$cid:/home/nonroot/$f" "./$f" 2>/dev/null; then
    chmod 600 "./$f"
    say "→ ./$f (chmod 600)"
  else
    warn "$f недоступен (первые 2 минуты после старта; повторите: docker cp $cid:/home/nonroot/$f .)"
  fi
done

echo
say "Готово. Дальше:"
echo "  1) Откройте http://<адрес>:${probe_port} — логин admin, пароль из ./admin_password.txt"
echo "  2) ./admin_recovery_codes.txt — 5 одноразовых кодов восстановления (сохраните в сейф!)"
echo "  3) Админка → Лицензия: загрузите файл лицензии (или спросите код активации хоста)"
echo "  4) Порты: web ${P_HTTP}/${P_APP}, RADIUS ${P_AUTH}/${P_ACCT} (udp); PostgreSQL опубликован ВНУТРИ сети docker"
echo "  5) Обновление: ./install.sh --tag vX.Y.Z (данные в volume twofa_pgdata не тронуты)"
