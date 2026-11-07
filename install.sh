#!/usr/bin/env bash
# =============================================================================
# Ligament 2FA — быстрое развёртывание одной командой (готовый образ Docker Hub)
#
#   curl -fsSL https://raw.githubusercontent.com/aligorov/ligament/main/install.sh | bash
#   ./install.sh --http-port 8080             # свой HTTP-порт (без root)
#   ./install.sh --tag latest                 # пин конкретной версии
#   ./install.sh --set-password '...'         # свой пароль БД (иначе сгенерится)
#   ./install.sh --fresh                      # чистая переустановка со сбросом БД
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
    --http-port)    http_port="${2:?}"; shift 2 ;;
    --app-port)     app_port="${2:?}"; shift 2 ;;
    --radius-auth)  radius_auth="${2:?}"; shift 2 ;;
    --radius-acct)  radius_acct="${2:?}"; shift 2 ;;
    --tag)          image_tag="${2:?}"; shift 2 ;;
    --set-password) pg_password="${2:?}"; shift 2 ;;
    --fresh)        fresh=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

# ---------- валидация аргументов ----------
for p_name in http_port app_port radius_auth radius_acct; do
  p_val="${!p_name}"
  [[ -z "$p_val" ]] && continue
  [[ "$p_val" =~ ^[0-9]+$ ]] || die "--${p_name//_/-}: ожидается номер порта, получено: '$p_val'"
done
[[ -z "$image_tag" ]] || [[ "$image_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "--tag: допустимы буквы, цифры, точка, дефис, подчёркивание: '$image_tag'"

# Переходим в директорию скрипта, только если это реальный файл
if [[ -f "${BASH_SOURCE[0]:-$0}" ]]; then
  cd "$(dirname "${BASH_SOURCE[0]:-$0}")"
fi

# ---------- зависимости ----------
say "Проверка зависимостей"
command -v docker >/dev/null || die "docker не найден: установите Docker (https://docs.docker.com/engine/install/)"

DC_CMD=""
if docker compose version >/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  die "docker compose не найден (установите плагин docker compose v2 или docker-compose)"
fi

docker info >/dev/null 2>&1 || die "docker-демон недоступен (запущен ли сервис? права группы docker?)"

# ---------- автогенерация docker-compose.yml ----------
if [[ ! -f "$compose_file" ]]; then
  say "Создание конфигурации $compose_file..."
  cat <<'EOF' > "$compose_file"
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: twofa
      POSTGRES_PASSWORD: "${TWOFA_PG_PASSWORD:?пароль БД не задан: создайте .env (echo TWOFA_PG_PASSWORD=... > .env)}"
      POSTGRES_DB: twofa
    volumes:
      - twofa_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U twofa -d twofa"]
      interval: 5s
      timeout: 3s
      retries: 20
    restart: unless-stopped

  twofa:
    image: aligorov/ligament_2fa:${TWOFA_IMAGE_TAG:-latest}
    hostname: ligament-auth
    depends_on:
      db:
        condition: service_healthy
    environment:
      TWOFA_DB_DSN: "host=db port=5432 user=twofa dbname=twofa password='${TWOFA_PG_PASSWORD:?пароль БД не задан}'"
    ports:
      - "${LIG_HTTP_PORT:-80}:8080"
      - "${LIG_APP_PORT:-8080}:8080"
      - "${LIG_RADIUS_AUTH:-1812}:1812/udp"
      - "${LIG_RADIUS_ACCT:-1813}:1813/udp"
    volumes:
      - /etc/machine-id:/etc/host-machine-id:ro
    restart: unless-stopped

volumes:
  twofa_pgdata:
EOF
fi

# Поддержка machine-id в Linux
if [[ ! -f /etc/machine-id ]] && [[ "$(uname)" == "Linux" ]]; then
  if [[ -f /var/lib/dbus/machine-id ]]; then
    ln -s /var/lib/dbus/machine-id /etc/machine-id 2>/dev/null || true
  else
    touch /etc/machine-id 2>/dev/null || true
  fi
fi

# ---------- проверка портов ----------
port_busy_tcp() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"
  elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else return 1; fi
}
port_busy_udp() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -lunH "( sport = :$p )" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1 && netstat -lun >/dev/null 2>&1; then netstat -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"
  else return 1; fi
}
docker_busy() {
  local p="$1"
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "[:.]${p}->"
}

say "Проверка портов"
P_APP="${app_port:-8080}"
P_HTTP="${http_port:-80}"
P_AUTH="${radius_auth:-1812}"
P_ACCT="${radius_acct:-1813}"

# Авто-подбор веб-порта, если дефолтный занят
if port_busy_tcp "$P_APP" || docker_busy "$P_APP"; then
  if [[ -n "$app_port" ]]; then
    die "Указанный порт --app-port $P_APP занят на хосте"
  fi
  warn "Порт tcp/$P_APP занят другим сервисом. Ищу свободный порт..."
  while port_busy_tcp "$P_APP" || docker_busy "$P_APP"; do
    P_APP=$((P_APP + 1))
  done
  say "Веб-интерфейс будет запущен на свободном порту :$P_APP"
fi

if port_busy_tcp "$P_HTTP" || docker_busy "$P_HTTP"; then
  if [[ -n "$http_port" ]]; then
    die "Указанный порт --http-port $P_HTTP занят на хосте"
  fi
  warn "Порт tcp/$P_HTTP (HTTP) занят существующим веб-сервером хоста."
  # Назначаем запасной или отключаем конфликтный биндинг
  P_HTTP=$((P_APP + 100))
  while port_busy_tcp "$P_HTTP" || docker_busy "$P_HTTP" || [[ "$P_HTTP" == "$P_APP" ]]; do
    P_HTTP=$((P_HTTP + 1))
  done
  say "Резервный HTTP-порт перенаправлен на :$P_HTTP"
fi

for p in "$P_AUTH" "$P_ACCT"; do
  { port_busy_udp "$p" || docker_busy "$p"; } && warn "udp/$p занят — RADIUS-порты можно сменить (--radius-auth/--radius-acct)"
done

# ---------- осиротевший volume прошлой установки ----------
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
      a) перенесите сюда старый .env (данные сохранятся);
      b) начать с чистого листа: ./install.sh --fresh  (БД будет пересоздана);
      c) запустить в другой папке (создастся отдельный проект docker)."
  fi
fi

# ---------- пароли и .env ----------
say "Настройка окружения"
gen_pass() {
  local s=""
  if command -v openssl >/dev/null 2>&1; then
    s="$(openssl rand -base64 48 | tr -d '/+=')"
  else
    s="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  fi
  printf '%s' "${s:0:28}"
}

if [[ -f "$env_file" ]] && grep -q '^TWOFA_PG_PASSWORD=' "$env_file"; then
  say "Найден существующий $env_file — пароль БД сохранён"
else
  if [[ -n "$pg_password" ]]; then
    [[ "$pg_password" =~ ^[A-Za-z0-9!@#%^*+=:,._~-]+$ ]] \
      || die "--set-password: недопустимые спецсимволы в пароле"
  else
    pg_password="$(gen_pass)"
  fi
  printf 'TWOFA_PG_PASSWORD=%s\n' "$pg_password" > "$env_file"
  chmod 600 "$env_file"
  say "Сгенерирован надежный пароль БД и сохранён в $env_file"
fi
chmod 600 "$env_file"

ensure_gitignore() {
  local gi=".gitignore" entry
  touch "$gi"
  local entries=(
    ".env" "*.bak" "ap2.txt" "admin_password.txt" "admin_recovery_codes.txt" "config.yaml"
  )
  for entry in "${entries[@]}"; do
    grep -qxF "$entry" "$gi" || printf '%s\n' "$entry" >> "$gi"
  done
}
ensure_gitignore

upsert_env() {
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
[[ -n "$image_tag" ]] && { upsert_env TWOFA_IMAGE_TAG "$image_tag"; say "Версия образа: $image_tag"; }

# ---------- развёртывание ----------
dc() { $DC_CMD --env-file "$env_file" -f "$compose_file" "$@"; }

say "Загрузка Docker-образов"
dc pull

say "Запуск сервисов Ligament (PostgreSQL + Core)"
dc up -d

# ---------- ожидание запуска ----------
say "Ожидание готовности сервера (/healthz на :$P_APP)..."
ok=""
for _ in $(seq 1 45); do
  if curl -fsS -m 2 "http://127.0.0.1:${P_APP}/healthz" >/dev/null 2>&1 || \
     curl -fsS -m 2 "http://127.0.0.1:${P_HTTP}/healthz" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done

if [[ -z "$ok" ]]; then
  warn "healthz не ответил вовремя. Проверяем логи контейнеров:"
  dc logs --tail=40 twofa || true
  dc ps
  exit 1
fi

# ---------- извлечение учетных данных ----------
say "Извлечение пароля администратора"
cid="$(dc ps -q twofa)"

for _ in $(seq 1 15); do
  if docker cp "$cid:/home/nonroot/admin_password.txt" "./admin_password.txt" 2>/dev/null; then
    chmod 600 "./admin_password.txt"
    break
  fi
  sleep 1
done

docker cp "$cid:/home/nonroot/admin_recovery_codes.txt" "./admin_recovery_codes.txt" 2>/dev/null \
  && chmod 600 "./admin_recovery_codes.txt" || true

server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$server_ip" ]] && server_ip="$(hostname 2>/dev/null || echo localhost)"

admin_pass="см. ./admin_password.txt"
if [[ -f "./admin_password.txt" ]]; then
  admin_pass="$(cat ./admin_password.txt | tr -d '\r\n')"
fi

echo
printf '\033[1;32m═══════════════════════════════════════════════════════════════════════\033[0m\n'
printf '  \033[1;32m✔ Установка Ligament 2FA успешно завершена!\033[0m\n'
printf '\033[1;32m═══════════════════════════════════════════════════════════════════════\033[0m\n'
printf '  \033[1mURL панели управления:\033[0m \033[1;36mhttp://%s:%s\033[0m\n' "$server_ip" "$P_APP"
if [[ "$P_HTTP" != "$P_APP" && "$P_HTTP" != "80" ]]; then
  printf '  \033[1mДополнительный HTTP:\033[0m   \033[1;36mhttp://%s:%s\033[0m\n' "$server_ip" "$P_HTTP"
fi
printf '  \033[1mЛогин:\033[0m                 \033[1;33madmin\033[0m\n'
printf '  \033[1mПароль администратора:\033[0m \033[1;32m%s\033[0m\n' "$admin_pass"
printf '\033[1;32m───────────────────────────────────────────────────────────────────────\033[0m\n'
printf '  • Пароль сохранён в:        \033[1m./admin_password.txt\033[0m\n'
printf '  • Коды восстановления:      \033[1m./admin_recovery_codes.txt\033[0m (5 шт)\n'
printf '  • Настройки и секреты БД:   \033[1m./.env\033[0m\n'
printf '\033[1;32m═══════════════════════════════════════════════════════════════════════\033[0m\n'
echo
