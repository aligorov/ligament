#!/usr/bin/env bash
# ==============================================================================
# 🛡️ Ligament Enterprise Platform — Универсальный оркестратор и установщик
# Документация: https://github.com/aligorov/ligament
#
# Режимы работы:
#   1. Интерактивный TUI-терминал с псевдографикой (по умолчанию)
#   2. CLI-автоматизация:
#      ./install.sh --all                        # Все центральные модули
#      ./install.sh --core-only                  # Только ядро 2FA
#      ./install.sh --modules core,chat,guard    # Выборочная установка
#      ./install.sh --role ice                   # Установка ICE (Coturn + Certbot)
#      ./install.sh --role relay                 # Установка узла Relay для филиала
#      ./install.sh --update                     # Обновление всех активных модулей
#      ./install.sh --update-module chat         # Точечное обновление конкретного модуля
#      ./install.sh --deploy-remote-ice <host>   # Удалённый деплой ICE по SSH
#      ./install.sh --deploy-remote-relay <host> # Удалённый деплой Relay по SSH
#      ./install.sh --fresh                      # Чистый старт со сбросом БД
# ==============================================================================
set -euo pipefail

VERSION="2.2.1"
DEFAULT_INSTALL_DIR="/opt/ligament"
RAW_BASE_URL="https://raw.githubusercontent.com/aligorov/ligament/main"
target_dir=""
env_file=".env"
compose_file="docker-compose.yml"
role="central"
selected_modules="core"
fresh=0
skip_preflight=0
image_tag=""
pg_password=""
force_mirrors=0
no_mirrors=0
cli_action=""
update_target=""
remote_host=""
remote_user="root"
remote_port="22"
remote_key=""
ice_realm=""
ice_email=""
relay_core_url=""
relay_secret=""

# ANSI Цвета и оформление
CLR_ESC="\033["
C_RESET="${CLR_ESC}0m"
C_BOLD="${CLR_ESC}1m"
C_DIM="${CLR_ESC}2m"
C_RED="${CLR_ESC}1;31m"
C_GREEN="${CLR_ESC}1;32m"
C_YELLOW="${CLR_ESC}1;33m"
C_BLUE="${CLR_ESC}1;34m"
C_MAGENTA="${CLR_ESC}1;35m"
C_CYAN="${CLR_ESC}1;36m"
C_WHITE="${CLR_ESC}1;37m"

say()    { printf "${C_GREEN}==>${C_RESET} %b\n" "$*" >&2; }
info()   { printf "${C_CYAN}[i]${C_RESET} %b\n" "$*" >&2; }
warn()   { printf "${C_YELLOW}[!][Предупреждение]${C_RESET} %b\n" "$*" >&2; }
die()    { printf "${C_RED}[X][Ошибка]${C_RESET} %b\n" "$*" >&2; exit 1; }
divider(){ printf "${C_DIM}────────────────────────────────────────────────────────────────────────${C_RESET}\n" >&2; }

# Безопасное чтение ввода пользователя с поддержкой /dev/tty и очисткой \r
prompt_read() {
  local prompt_text="$1" var_name="$2" default_val="${3:-}"
  local val=""
  printf "%b" "$prompt_text" >&2
  if [[ -c /dev/tty ]]; then
    read -r val < /dev/tty || true
  elif [[ -t 0 ]]; then
    read -r val || true
  else
    val=""
  fi
  val="$(printf '%s' "$val" | tr -d '\r\n')"
  if [[ -z "$val" && -n "$default_val" ]]; then
    val="$default_val"
  fi
  eval "$var_name=\"\$val\""
}

# Определение рабочей директории
init_workdir() {
  if [[ -n "$target_dir" ]]; then
    mkdir -p "$target_dir"
    cd "$target_dir"
  elif [[ -f "docker-compose.yml" && -f "install.sh" ]]; then
    # Уже находимся в каталоге репозитория
    target_dir="$(pwd)"
  elif [[ "$(id -u)" -eq 0 ]]; then
    target_dir="$DEFAULT_INSTALL_DIR"
    mkdir -p "$target_dir"
    cd "$target_dir"
  else
    target_dir="$(pwd)/ligament"
    mkdir -p "$target_dir"
    cd "$target_dir"
  fi
}

# Гарантия наличия манифестов (автозагрузка с GitHub при curl | bash)
ensure_required_files() {
  ensure_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
      mkdir -p "$(dirname "$f")"
      say "Загрузка конфигурации $f с GitHub..."
      if ! curl -fsSL "$RAW_BASE_URL/$f" -o "$f"; then
        warn "Не удалось загрузить $f с GitHub."
      fi
      [[ "$f" == *.sh ]] && chmod +x "$f" || true
    fi
  }

  mkdir -p config
  ensure_file "docker-compose.yml"
  ensure_file "docker-compose.ice.yml"
  ensure_file "docker-compose.relay.yml"
  ensure_file "config/turnserver.conf"
  ensure_file "config/relay.example.yaml"
}

# Генератор безопасных паролей
gen_pass() {
  local len="${1:-28}" s=""
  if command -v openssl >/dev/null 2>&1; then
    s="$(openssl rand -base64 48 | tr -d '/+=')"
  else
    s="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  fi
  printf '%s' "${s:0:$len}"
}

# ------------------------------------------------------------------------------
# PRE-FLIGHT СИСТЕМНЫЕ ПРОВЕРКИ (CPU, RAM, Disk, OS, Docker)
# ------------------------------------------------------------------------------
check_system_requirements() {
  [[ "$skip_preflight" -eq 1 ]] && return 0
  say "Проверка минимальных системных требований..."
  local os_type arch cpu_cores mem_total_mb disk_free_mb
  os_type="$(uname -s)"
  arch="$(uname -m)"

  # 1. Архитектура
  if [[ "$arch" != "x86_64" && "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
    die "Неподдерживаемая архитектура: $arch. Требуется x86_64 (amd64) или aarch64 (arm64)."
  fi

  # 2. CPU
  if command -v nproc >/dev/null 2>&1; then
    cpu_cores="$(nproc)"
  elif [[ "$os_type" == "Darwin" ]]; then
    cpu_cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  else
    cpu_cores=2
  fi

  if [[ "$cpu_cores" -lt 2 ]]; then
    warn "Обнаружено только $cpu_cores CPU-ядро (рекомендуется минимум 2, для AI/Recorder — 4+)."
  fi

  # 3. RAM
  if [[ -f /proc/meminfo ]]; then
    mem_total_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  elif [[ "$os_type" == "Darwin" ]]; then
    local mem_bytes; mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 4294967296)"
    mem_total_mb=$((mem_bytes / 1024 / 1024))
  else
    mem_total_mb=2048
  fi

  if [[ "$mem_total_mb" -lt 1800 ]]; then
    warn "Доступно менее 2 ГБ RAM ($mem_total_mb МБ). Рекомендуется включить swap или использовать Core-only профиль."
  fi

  # 4. Дисковое пространство
  disk_free_mb="$(df -m . 2>/dev/null | awk 'NR==2 {print $4}' || echo 20000)"
  if [[ -n "$disk_free_mb" && "$disk_free_mb" -lt 5120 ]]; then
    warn "В каталоге установки доступно менее 5 ГБ диска ($((disk_free_mb / 1024)) ГБ свободно). Рекомендуется от 20+ ГБ."
  fi

  # 5. Наличие Docker
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$os_type" == "Linux" && "$(id -u)" -eq 0 ]]; then
      say "Docker Engine не найден. Выполняю автоматическую установку через get.docker.com..."
      curl -fsSL https://get.docker.com | sh
      systemctl enable --now docker || true
    else
      die "Docker не найден. Установите Docker: https://docs.docker.com/engine/install/"
    fi
  fi

  # 6. Проверка Docker Compose v2
  DC_CMD=""
  if docker compose version >/dev/null 2>&1; then
    DC_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC_CMD="docker-compose"
  else
    die "Docker Compose v2 не найден (установите плагин docker-compose-plugin)."
  fi

  docker info >/dev/null 2>&1 || die "Docker-демон недоступен. Проверьте статус службы 'systemctl status docker' и права группы docker."
  info "Системные проверки пройдены: $arch, $cpu_cores CPU, ${mem_total_mb}MB RAM, Docker готов."
}

# ------------------------------------------------------------------------------
# НАСТРОЙКА ЗЕРКАЛ DOCKER HUB ДЛЯ РФ
# ------------------------------------------------------------------------------
setup_docker_mirrors() {
  [[ "$no_mirrors" -eq 1 ]] && return 0
  [[ "$(uname -s)" == "Linux" ]] || return 0
  [[ "$(id -u)" == "0" ]] || return 0

  if docker info 2>/dev/null | grep -q "Registry Mirrors:"; then
    return 0
  fi

  say "Подключение быстрых зеркал Docker Hub (/etc/docker/daemon.json)..."
  mkdir -p /etc/docker
  local daemon_json="/etc/docker/daemon.json"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, os
path = "/etc/docker/daemon.json"
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except Exception:
        data = {}
mirrors = data.setdefault("registry-mirrors", [])
for m in ["https://dockerhub.timeweb.cloud", "https://dh-mirror.gitverse.ru", "https://huecker.io"]:
    if m not in mirrors:
        mirrors.append(m)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
'
  elif command -v jq >/dev/null 2>&1 && [[ -f "$daemon_json" && -s "$daemon_json" ]]; then
    local tmp; tmp="$(mktemp)"
    jq '.["registry-mirrors"] = ((.["registry-mirrors"] // []) + ["https://dockerhub.timeweb.cloud", "https://dh-mirror.gitverse.ru", "https://huecker.io"] | unique)' "$daemon_json" > "$tmp" && mv "$tmp" "$daemon_json"
  else
    if [[ ! -f "$daemon_json" || ! -s "$daemon_json" ]]; then
      cat <<'EOF' > "$daemon_json"
{
  "registry-mirrors": [
    "https://dockerhub.timeweb.cloud",
    "https://dh-mirror.gitverse.ru",
    "https://huecker.io"
  ]
}
EOF
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || true
  fi
  info "Зеркала подключены: timeweb, gitverse, huecker."
}

# ------------------------------------------------------------------------------
# ПРОВЕРКА И БЕСКОНФЛИКТНЫЙ ПОДБОР ПОРТОВ
# ------------------------------------------------------------------------------
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

docker_port_busy() {
  local p="$1"
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "[:.]${p}->"
}

inspect_port_owner() {
  local p="$1"
  local owner=""
  local docker_cont=""
  docker_cont="$(docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "$docker_cont" ]]; then
    echo "Docker-контейнер: $docker_cont"
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    owner="$(lsof -iTCP:"$p" -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR==2 {print $1 " (PID " $2 ")"}')"
  fi
  if [[ -z "$owner" ]] && command -v ss >/dev/null 2>&1; then
    owner="$(ss -ltnp "( sport = :$p )" 2>/dev/null | awk 'NR>1 {print $NF}' | tr -d '"')"
  fi
  echo "${owner:-Занят процессом хоста}"
}

resolve_free_port() {
  local p="$1" name="$2"
  while port_busy_tcp "$p" || docker_port_busy "$p"; do
    local owner; owner="$(inspect_port_owner "$p")"
    warn "Порт tcp/$p ($name) занят ($owner), подбираю свободный..."
    p=$((p + 1))
  done
  echo "$p"
}

# ------------------------------------------------------------------------------
# ИНСПЕКЦИЯ ПУТЕЙ И ПРОВЕРКА УЖЕ УСТАНОВЛЕННЫХ КОМПОНЕНТОВ
# ------------------------------------------------------------------------------
get_container_info() {
  local name="$1"
  local status=""
  status="$(docker ps --filter "name=^/${name}$" --format '{{.Status}}' 2>/dev/null || true)"
  if [[ -n "$status" ]]; then
    echo "UP|$status"
    return 0
  fi
  status="$(docker ps -a --filter "name=^/${name}$" --format '{{.Status}}' 2>/dev/null || true)"
  if [[ -n "$status" ]]; then
    echo "EXITED|$status"
    return 0
  fi
  echo "NONE|"
}

get_volume_mountpoint() {
  local vol="$1"
  local mp=""
  for v in "$vol" "ligament_${vol}" "ligament-${vol}" "ligament_${vol//-/_}"; do
    mp="$(docker volume inspect "$v" --format '{{.Mountpoint}}' 2>/dev/null || true)"
    if [[ -n "$mp" ]]; then
      echo "$mp"
      return 0
    fi
  done
  echo ""
}

detect_existing_installation() {
  local cur_path; cur_path="$(pwd -P)"
  say "Инспекция окружения, путей и статуса компонентов Ligament..."

  local d_root="/var/lib/docker"
  if command -v docker >/dev/null 2>&1; then
    d_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  fi
  local disk_avail; disk_avail="$(df -h "$d_root" 2>/dev/null | awk 'NR==2 {print $4 " свободно из " $2}' || echo "N/A")"
  info "Каталог установки: ${C_BOLD}$cur_path${C_RESET}"
  info "Хранилище Docker:  ${C_BOLD}$d_root${C_RESET} (${C_GREEN}$disk_avail${C_RESET})"

  if [[ -f "$env_file" ]]; then
    local profs; profs="$(grep '^COMPOSE_PROFILES=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "core")"
    local p_app; p_app="$(grep '^LIG_APP_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "8080")"
    info "Конфигурация Core: .env активен (профили: ${C_GREEN}$profs${C_RESET}, порт: ${C_CYAN}:$p_app${C_RESET})"
  fi

  if [[ -f ".env.ice" ]]; then
    local r; r="$(grep '^ICE_REALM=' .env.ice 2>/dev/null | cut -d= -f2 || echo "")"
    info "Конфигурация ICE: .env.ice активен (домен: ${C_GREEN}${r:-не задан}${C_RESET})"
  fi

  if [[ -f "config/relay.yaml" ]]; then
    info "Конфигурация Relay: config/relay.yaml присутствует"
  fi

  echo
  printf "  ${C_BOLD}%-22s %-20s %-16s %s${C_RESET}\n" "МОДУЛЬ" "СТАТУС СЕРВИСА" "ПОРТЫ" "ТОМ ДАННЫХ НА ХОСТЕ"
  printf "  ${C_DIM}────────────────────── ──────────────────── ──────────────── ───────────────────────────────────${C_RESET}\n"

  render_mod_row() {
    local title="$1" cont_app="$2" cont_db="$3" ports="$4" vol_name="$5"
    local s_app; s_app="$(get_container_info "$cont_app")"
    local status_display=""
    local app_state="${s_app%%|*}"

    if [[ "$app_state" == "UP" ]]; then
      status_display="${C_GREEN}✔ РАБОТАЕТ${C_RESET}"
    elif [[ "$app_state" == "EXITED" ]]; then
      status_display="${C_RED}■ ОСТАНОВЛЕН${C_RESET}"
    else
      status_display="${C_DIM}· Не установлен${C_RESET}"
    fi

    local vol_path=""
    if [[ -n "$vol_name" ]]; then
      vol_path="$(get_volume_mountpoint "$vol_name")"
      if [[ -z "$vol_path" ]]; then
        vol_path="${C_DIM}${vol_name}${C_RESET}"
      else
        vol_path="${C_WHITE}${vol_path}${C_RESET}"
      fi
    else
      vol_path="${C_DIM}—${C_RESET}"
    fi

    printf "  %-22s %-29b %-16s %b\n" "$title" "$status_display" "$ports" "$vol_path"
  }

  local p_core; p_core="$(grep '^LIG_APP_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 8080)"
  local p_chat; p_chat="$(grep '^LIG_CHAT_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 8097)"
  local p_rec;  p_rec="$(grep '^LIG_RECORDER_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 8095)"
  local p_tick; p_tick="$(grep '^LIG_TICKET_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 8096)"
  local p_grd;  p_grd="$(grep '^LIG_GUARD_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 8090)"

  render_mod_row "🛡️ Core 2FA (Auth)"     "ligament-core"    "ligament-core-db"     ":$p_core, :1812" "twofa_pgdata"
  render_mod_row "💬 Ligament Chat"       "ligament-chat"    "ligament-chat-db"     ":$p_chat"        "chat_pgdata"
  render_mod_row "📹 Recorder & AI"       "ligament-recoder" "ligament-recorder-db" ":$p_rec"         "recorder_pgdata"
  render_mod_row "🎫 Helpdesk Ticket"     "ligament-ticket"  "ligament-ticket-db"   ":$p_tick"        "ticket_pgdata"
  render_mod_row "🪪 Guard Monitor"       "ligament-guard"   ""                     ":$p_grd"         ""
  render_mod_row "🧊 WebRTC ICE (VPS)"    "ligament-ice"     "ligament-ice-certbot" ":5349, :3478"    "ligament_ice_certs"
  render_mod_row "📡 Branch Relay"        "ligament-relay"   ""                     ":8082, :1812"    ""

  printf "  ${C_DIM}─────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# ФОРМИРОВАНИЕ .env И СЕКРЕТОВ
# ------------------------------------------------------------------------------
ensure_env_file() {
  say "Формирование конфигурации и ключей безопасности (.env)..."
  touch "$env_file"
  chmod 600 "$env_file"

  upsert_env() {
    local k="$1" v="$2"
    if grep -q "^$k=" "$env_file" 2>/dev/null; then
      sed -i.bak "s|^$k=.*|$k=$v|" "$env_file" && rm -f "$env_file.bak"
    else
      printf '%s=%s\n' "$k" "$v" >> "$env_file"
    fi
  }

  # Пароль базы данных
  if ! grep -q '^TWOFA_PG_PASSWORD=' "$env_file" 2>/dev/null; then
    [[ -z "$pg_password" ]] && pg_password="$(gen_pass 28)"
    upsert_env "TWOFA_PG_PASSWORD" "$pg_password"
  fi

  # Токены и секреты WebRTC / ICE
  if ! grep -q '^LIG_TURN_PASSWORD=' "$env_file" 2>/dev/null; then
    upsert_env "LIG_TURN_PASSWORD" "$(gen_pass 32)"
  fi
  upsert_env "LIG_TURN_USER" "ligament"

  # Порты
  P_APP="$(resolve_free_port 8080 'Core WebUI')"
  P_HTTP="$(resolve_free_port 80 'Core HTTP')"
  P_CHAT="$(resolve_free_port 8097 'Chat')"
  P_REC="$(resolve_free_port 8095 'Recorder')"
  P_TICK="$(resolve_free_port 8096 'Ticket')"
  P_GUARD="$(resolve_free_port 8090 'Guard')"

  upsert_env "LIG_APP_PORT" "$P_APP"
  upsert_env "LIG_HTTP_PORT" "$P_HTTP"
  upsert_env "LIG_CHAT_PORT" "$P_CHAT"
  upsert_env "LIG_RECORDER_PORT" "$P_REC"
  upsert_env "LIG_TICKET_PORT" "$P_TICK"
  upsert_env "LIG_GUARD_PORT" "$P_GUARD"
  upsert_env "LIG_RADIUS_AUTH" "1812"
  upsert_env "LIG_RADIUS_ACCT" "1813"

  # Профили
  upsert_env "COMPOSE_PROFILES" "$selected_modules"
  [[ -n "$image_tag" ]] && upsert_env "TWOFA_IMAGE_TAG" "$image_tag"

  # Гарантия наличия .gitignore
  local gi=".gitignore" entry
  touch "$gi"
  for entry in ".env" "*.bak" "ap2.txt" "admin_password.txt" "admin_recovery_codes.txt" "config/relay.yaml" ".qoder/"; do
    grep -qxF "$entry" "$gi" 2>/dev/null || printf '%s\n' "$entry" >> "$gi"
  done
}

# ------------------------------------------------------------------------------
# РАЗВЁРТЫВАНИЕ ЦЕНТРАЛЬНОГО СЕРВЕРА
# ------------------------------------------------------------------------------
deploy_central() {
  ensure_required_files
  say "Развёртывание Ligament Central Platform (Профили: $selected_modules)..."
  setup_docker_mirrors

  if [[ "$fresh" -eq 1 ]]; then
    warn "Флаг --fresh: удаление старых контейнеров и томов базы данных..."
    $DC_CMD down -v --remove-orphans 2>/dev/null || true
  fi

  say "Загрузка Docker-образов для профилей: $selected_modules..."
  $DC_CMD pull || die "Ошибка загрузки Docker-образов"

  say "Запуск сервисов..."
  $DC_CMD up -d

  say "Ожидание готовности ядра (/healthz)..."
  local p_app ok=""
  p_app="$(grep '^LIG_APP_PORT=' "$env_file" | cut -d= -f2 || echo 8080)"
  for _ in $(seq 1 45); do
    if curl -fsS -m 2 "http://127.0.0.1:${p_app}/healthz" >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 2
  done

  if [[ -z "$ok" ]]; then
    warn "Healthcheck не ответил за 90 сек. Проверьте логи: $DC_CMD logs twofa"
  fi

  # Извлечение учетных данных первого администратора
  say "Проверка первичного пароля администратора..."
  local cid admin_pass="см. ./admin_password.txt"
  cid="$($DC_CMD ps -q twofa 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    for _ in $(seq 1 10); do
      if docker cp "$cid:/home/nonroot/admin_password.txt" "./admin_password.txt" 2>/dev/null; then
        chmod 600 "./admin_password.txt"
        admin_pass="$(tr -d '\r\n' < ./admin_password.txt)"
        break
      fi
      sleep 1
    done
    docker cp "$cid:/home/nonroot/admin_recovery_codes.txt" "./admin_recovery_codes.txt" 2>/dev/null && chmod 600 "./admin_recovery_codes.txt" || true
  fi

  local server_ip
  server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "$server_ip" ]] && server_ip="127.0.0.1"

  echo
  printf "${C_GREEN}╔═══════════════════════════════════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_GREEN}║  ✔ УСТАНОВКА LIGAMENT ENTERPRISE УСПЕШНО ЗАВЕРШЕНА!                   ║${C_RESET}\n"
  printf "${C_GREEN}╚═══════════════════════════════════════════════════════════════════════╝${C_RESET}\n"
  printf "  ${C_BOLD}Панель управления (Core 2FA):${C_RESET} ${C_CYAN}http://%s:%s${C_RESET}\n" "$server_ip" "$p_app"
  [[ "$selected_modules" =~ chat ]]    && printf "  ${C_BOLD}Корпоративный Chat:${C_RESET}            ${C_CYAN}http://%s:%s${C_RESET}\n" "$server_ip" "$(grep '^LIG_CHAT_PORT=' "$env_file" | cut -d= -f2)"
  [[ "$selected_modules" =~ recorder ]]&& printf "  ${C_BOLD}Медиа-сервер Recorder:${C_RESET}        ${C_CYAN}http://%s:%s${C_RESET}\n" "$server_ip" "$(grep '^LIG_RECORDER_PORT=' "$env_file" | cut -d= -f2)"
  [[ "$selected_modules" =~ ticket ]]  && printf "  ${C_BOLD}Helpdesk Ticket:${C_RESET}              ${C_CYAN}http://%s:%s${C_RESET}\n" "$server_ip" "$(grep '^LIG_TICKET_PORT=' "$env_file" | cut -d= -f2)"
  [[ "$selected_modules" =~ guard ]]   && printf "  ${C_BOLD}Монитор охраны Guard:${C_RESET}         ${C_CYAN}http://%s:%s${C_RESET}\n" "$server_ip" "$(grep '^LIG_GUARD_PORT=' "$env_file" | cut -d= -f2)"
  divider
  printf "  ${C_BOLD}Логин администратора:${C_RESET}         ${C_YELLOW}admin${C_RESET}\n"
  printf "  ${C_BOLD}Пароль администратора:${C_RESET}        ${C_GREEN}%s${C_RESET}\n" "$admin_pass"
  printf "  ${C_BOLD}Аварийные recovery-коды:${C_RESET}      ${C_WHITE}./admin_recovery_codes.txt (5 шт)${C_RESET}\n"
  printf "  ${C_BOLD}Файл секретов и портов:${C_RESET}       ${C_WHITE}./.env (chmod 600)${C_RESET}\n"
  divider
}

# ------------------------------------------------------------------------------
# РАЗВЁРТЫВАНИЕ ICE (WebRTC STUN/TURN) НА VPS
# ------------------------------------------------------------------------------
deploy_ice() {
  ensure_required_files
  say "Развёртывание Ligament ICE (Coturn STUN/TURN + Let's Encrypt)..."
  info "Каталог установки: $(pwd -P)"

  # Авто-очистка остановленных или конфликтующих контейнеров прошлой попытки
  local old_ice
  old_ice="$(docker ps -a --filter "name=ligament-ice" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "$old_ice" ]]; then
    say "Обнаружены предыдущие контейнеры ICE ($old_ice). Остановка перед запуском..."
    docker rm -f ligament-ice ligament-ice-certbot 2>/dev/null || true
  fi

  local def_realm="turn.company.com" def_email=""
  if [[ -f .env.ice ]]; then
    def_realm="$(grep '^ICE_REALM=' .env.ice 2>/dev/null | cut -d= -f2 || true)"
    def_email="$(grep '^ACME_EMAIL=' .env.ice 2>/dev/null | cut -d= -f2 || true)"
  fi
  [[ -z "$def_realm" ]] && def_realm="turn.company.com"

  if [[ -z "$ice_realm" ]]; then
    prompt_read "${C_BOLD}Введите публичный домен для TURN [${def_realm}]: ${C_RESET}" ice_realm "$def_realm"
  fi
  [[ -z "$ice_realm" ]] && die "Домен TURN обязателен"

  if [[ -z "$ice_email" ]]; then
    [[ -z "$def_email" ]] && def_email="admin@$ice_realm"
    prompt_read "${C_BOLD}Введите email для Let's Encrypt [${def_email}]: ${C_RESET}" ice_email "$def_email"
  fi

  local ice_pass
  if [[ -f .env.ice ]] && grep -q '^TURN_PASSWORD=' .env.ice 2>/dev/null; then
    ice_pass="$(grep '^TURN_PASSWORD=' .env.ice | cut -d= -f2)"
  else
    ice_pass="$(gen_pass 32)"
  fi

  say "Проверка доступности портов для ICE..."
  local port_443_tcp="443:443/tcp"
  local port_443_udp="443:443/udp"
  local turn_port="443"

  if port_busy_tcp 443 || docker_port_busy 443; then
    local owner; owner="$(inspect_port_owner 443)"
    warn "Порт 443/tcp занят ($owner)."
    info "TURNS TLS переключён на стандартный защищённый порт RFC 5349."
    local free_fb; free_fb="$(resolve_free_port 8443 'ICE Fallback')"
    port_443_tcp="${free_fb}:443/tcp"
    port_443_udp="${free_fb}:443/udp"
    turn_port="5349"
  fi

  cat <<EOF > .env.ice
ICE_REALM=$ice_realm
ACME_EMAIL=$ice_email
TURN_USER=ligament
TURN_PASSWORD=$ice_pass
EXTERNAL_IP=$(curl -fsS -m 3 https://api.ipify.org 2>/dev/null || echo "")
ICE_PORT_443_TCP=$port_443_tcp
ICE_PORT_443_UDP=$port_443_udp
EOF
  chmod 600 .env.ice

  say "Запуск ICE стека через docker-compose.ice.yml..."
  $DC_CMD --env-file .env.ice -f docker-compose.ice.yml pull
  $DC_CMD --env-file .env.ice -f docker-compose.ice.yml up -d

  echo
  say "ICE сервер успешно запущен!"
  info "Каталог конфигурации: $(pwd -P)/.env.ice"
  info "Параметры для интеграции в центральный .env ядра:"
  printf "  ${C_GREEN}LIG_TURN_SERVER=\"turn:%s:%s\"${C_RESET}\n" "$ice_realm" "$turn_port"
  printf "  ${C_GREEN}LIG_TURN_USER=\"ligament\"${C_RESET}\n"
  printf "  ${C_GREEN}LIG_TURN_PASSWORD=\"%s\"${C_RESET}\n" "$ice_pass"
}

# ------------------------------------------------------------------------------
# РАЗВЁРТЫВАНИЕ RELAY В ФИЛИАЛЕ
# ------------------------------------------------------------------------------
deploy_relay() {
  ensure_required_files
  say "Развёртывание Ligament Relay (Edge-агент филиала)..."

  mkdir -p config
  if [[ ! -f "config/relay.yaml" ]]; then
    if [[ -z "$relay_core_url" ]]; then
      prompt_read "${C_BOLD}Введите URL центрального сервера [https://2fa.company.com]: ${C_RESET}" relay_core_url "https://2fa.company.com"
    fi
    if [[ -z "$relay_secret" ]]; then
      prompt_read "${C_BOLD}Введите пароль/секрет узла Relay: ${C_RESET}" relay_secret
    fi
    [[ -z "$relay_secret" ]] && die "Пароль узла Relay обязателен"

    cat <<EOF > config/relay.yaml
core:
  url: "${relay_core_url}"
  password: "${relay_secret}"
local:
  http_port: 8082
  radius_port: 1812
cache:
  offline_ttl_hours: 72
EOF
    chmod 600 config/relay.yaml
  fi

  say "Запуск Relay через docker-compose.relay.yml..."
  $DC_CMD -f docker-compose.relay.yml pull
  $DC_CMD -f docker-compose.relay.yml up -d
  info "Ligament Relay успешно запущен на портах :8082 (HTTP) и :1812/udp (RADIUS)."
}

# ------------------------------------------------------------------------------
# УДАЛЁННЫЙ ДЕПЛОЙ ПО SSH
# ------------------------------------------------------------------------------
deploy_remote_ssh() {
  local target_role="$1" host="$2"
  say "Удалённый деплой роли [$target_role] на хост $host..."
  local ssh_opts="-o StrictHostKeyChecking=accept-new -p $remote_port"
  [[ -n "$remote_key" ]] && ssh_opts="$ssh_opts -i $remote_key"

  say "Проверка SSH-связи с ${remote_user}@${host}..."
  ssh $ssh_opts "${remote_user}@${host}" "uname -a" >/dev/null || die "Не удалось подключиться к ${remote_user}@${host} по SSH."

  say "Провижининг Docker на удалённом хосте..."
  ssh $ssh_opts "${remote_user}@${host}" '
    set -euo pipefail
    if ! command -v docker >/dev/null 2>&1; then
      echo "Установка Docker на удаленном сервере..."
      curl -fsSL https://get.docker.com | sh
      systemctl enable --now docker || true
    fi
    mkdir -p /opt/ligament
  '

  ensure_required_files
  if [[ "$target_role" == "ice" ]]; then
    say "Копирование конфигурации ICE..."
    scp $ssh_opts docker-compose.ice.yml config/turnserver.conf "${remote_user}@${host}:/opt/ligament/"
    ssh $ssh_opts "${remote_user}@${host}" "cd /opt/ligament && docker compose -f docker-compose.ice.yml pull && docker compose -f docker-compose.ice.yml up -d"
    say "ICE успешно развернут на удаленном VPS $host!"
  elif [[ "$target_role" == "relay" ]]; then
    say "Копирование конфигурации Relay..."
    scp $ssh_opts docker-compose.relay.yml config/relay.yaml "${remote_user}@${host}:/opt/ligament/"
    ssh $ssh_opts "${remote_user}@${host}" "cd /opt/ligament && docker compose -f docker-compose.relay.yml pull && docker compose -f docker-compose.relay.yml up -d"
    say "Relay успешно развернут на удаленном узле $host!"
  fi
}

# ------------------------------------------------------------------------------
# ОБНОВЛЕНИЕ ОБРАЗОВ (PULL ВСЕХ ИЛИ ТОЧЕЧНО --NO-DEPS)
# ------------------------------------------------------------------------------
update_services() {
  local target="$1"
  if [[ -z "$target" || "$target" == "all" ]]; then
    say "Обновление ВСЕХ запущенных сервисов..."
    $DC_CMD pull
    $DC_CMD up -d --remove-orphans
    info "Все сервисы успешно обновлены до последних версий."
  else
    say "Точечное обновление сервиса [$target] (zero-downtime для остальных)..."
    $DC_CMD pull "$target"
    $DC_CMD up -d --no-deps "$target"
    info "Сервис [$target] успешно обновлен и перезапущен."
  fi
}

# ------------------------------------------------------------------------------
# ПОДКЛЮЧЕНИЕ ОТДЕЛЬНОГО МОДУЛЯ (ИНКРЕМЕНТАЛЬНЫЙ ЗАПУСК БЕЗ ПЕРЕЗАГРУЗКИ ЯДРА)
# ------------------------------------------------------------------------------
add_or_start_module() {
  local mod="$1"
  ensure_required_files
  ensure_env_file

  local current_profs
  current_profs="$(grep '^COMPOSE_PROFILES=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "core")"

  if [[ "$current_profs" == "all" ]]; then
    selected_modules="all"
  elif [[ "$current_profs" != *"$mod"* ]]; then
    selected_modules="${current_profs},${mod}"
  else
    selected_modules="$current_profs"
  fi

  upsert_env "COMPOSE_PROFILES" "$selected_modules"
  say "Подключение модуля [$mod] к активному профилю: $selected_modules..."

  local svcs=("$mod")
  case "$mod" in
    chat)     svcs=("chat-db" "chat") ;;
    recorder) svcs=("recorder-db" "recorder") ;;
    ticket)   svcs=("ticket-db" "ticket") ;;
    guard)    svcs=("guard") ;;
    core)     svcs=("db" "twofa") ;;
  esac

  say "Загрузка Docker-образов для: ${svcs[*]}..."
  $DC_CMD pull "${svcs[@]}" || warn "Некоторые образы не удалось обновить, использую локальные кэшированные..."

  say "Запуск сервисов без остановки работающих контейнеров (--no-recreate)..."
  $DC_CMD up -d --no-recreate "${svcs[@]}"

  local server_ip
  server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "$server_ip" ]] && server_ip="127.0.0.1"

  echo
  say "Модуль [$mod] успешно запущен!"
  case "$mod" in
    chat)     info "Ligament Chat доступен: ${C_CYAN}http://${server_ip}:$(grep '^LIG_CHAT_PORT=' "$env_file" | cut -d= -f2)${C_RESET}" ;;
    recorder) info "Ligament Recorder доступен: ${C_CYAN}http://${server_ip}:$(grep '^LIG_RECORDER_PORT=' "$env_file" | cut -d= -f2)${C_RESET}" ;;
    ticket)   info "Ligament Ticket доступен: ${C_CYAN}http://${server_ip}:$(grep '^LIG_TICKET_PORT=' "$env_file" | cut -d= -f2)${C_RESET}" ;;
    guard)    info "Ligament Guard доступен: ${C_CYAN}http://${server_ip}:$(grep '^LIG_GUARD_PORT=' "$env_file" | cut -d= -f2)${C_RESET}" ;;
    core)     info "Ligament Core 2FA доступен: ${C_CYAN}http://${server_ip}:$(grep '^LIG_APP_PORT=' "$env_file" | cut -d= -f2)${C_RESET}" ;;
  esac
}

# ------------------------------------------------------------------------------
# ИНТЕРАКТИВНОЕ TUI-МЕНЮ
# ------------------------------------------------------------------------------
run_interactive_tui() {
  printf "\n${C_CYAN}╔═══════════════════════════════════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_CYAN}║${C_RESET}  ${C_BOLD}🛡️  LIGAMENT ENTERPRISE PLATFORM — УСТАНОВКА И ОРКЕСТРАЦИЯ${C_RESET}         ${C_CYAN}║${C_RESET}\n"
  printf "${C_CYAN}║${C_RESET}  ${C_DIM}Версия: %-8s · Каталог: %-37s${C_RESET} ${C_CYAN}║${C_RESET}\n" "$VERSION" "$(pwd | sed 's/.*\///')"
  printf "${C_CYAN}╚═══════════════════════════════════════════════════════════════════════╝${C_RESET}\n\n"

  detect_existing_installation
  echo

  printf "  ${C_BOLD}Выберите действие или модуль для установки:${C_RESET}\n\n"
  printf "  ${C_GREEN}[1] 🚀 All-in-One Enterprise${C_RESET} (Развернуть весь стек модулей разом)\n"
  printf "      ${C_DIM}Core 2FA + Chat + Recorder + Ticket + Guard${C_RESET}\n\n"
  printf "  ${C_CYAN}[2] 🛡️  Core 2FA Security Core${C_RESET} (Базовое ядро безопасности + Web + RADIUS)\n"
  printf "  ${C_BLUE}[3] 💬 Ligament Chat${C_RESET} (Корпоративный мессенджер + P2P WebRTC сигнализация)\n"
  printf "  ${C_MAGENTA}[4] 📹 Ligament Recorder & AI${C_RESET} (Запись сессий/звонков + AI Worker)\n"
  printf "  ${C_YELLOW}[5] 🎫 Ligament Ticket${C_RESET} (Helpdesk & система инцидентов)\n"
  printf "  ${C_WHITE}[6] 🪪 Ligament Guard${C_RESET} (Kiosk монитор КПП и турникетов)\n\n"
  divider
  printf "  ${C_YELLOW}[7] 🧊 Ligament ICE${C_RESET} (Медиа-шлюз Coturn STUN/TURN на VPS)\n"
  printf "  ${C_YELLOW}[8] 📡 Ligament Relay${C_RESET} (Edge-агент филиала)\n\n"
  divider
  printf "  ${C_WHITE}[9] 🔄 Обновление контейнеров (Pull & Restart)${C_RESET}\n"
  printf "  ${C_WHITE}[10] 📊 Детальная инспекция путей, томов, портов и логи${C_RESET}\n"
  printf "  ${C_RED}[0] ❌ Выход${C_RESET}\n\n"

  local choice=""
  prompt_read "${C_BOLD}Введите номер действия [0-10]: ${C_RESET}" choice

  case "$choice" in
    1) selected_modules="all"; ensure_env_file; deploy_central ;;
    2) add_or_start_module "core" ;;
    3) add_or_start_module "chat" ;;
    4) add_or_start_module "recorder" ;;
    5) add_or_start_module "ticket" ;;
    6) add_or_start_module "guard" ;;
    7) deploy_ice ;;
    8) deploy_relay ;;
    9)
      echo
      printf "  [1] Обновить ВСЕ модули стека\n"
      printf "  [2] Обновить конкретный модуль (twofa, chat, recorder, ticket, guard)\n"
      local u_choice=""
      prompt_read "Выбор [1-2]: " u_choice "1"
      if [[ "$u_choice" == "2" ]]; then
        local s_name=""
        prompt_read "Имя сервиса: " s_name "twofa"
        update_services "$s_name"
      else
        update_services "all"
      fi
      ;;
    10)
      detect_existing_installation
      divider
      say "Инспекция томов и физических путей на диске:"
      for v in twofa_pgdata chat_pgdata chat_data recorder_pgdata recorder_data ticket_pgdata ice_certs ligament_ice_certs; do
        local mp; mp="$(get_volume_mountpoint "$v")"
        if [[ -n "$mp" ]]; then
          printf "   • Том %-22s -> %s\n" "$v" "$mp"
        fi
      done
      divider
      say "Запущенные контейнеры и порты Docker:"
      $DC_CMD ps 2>/dev/null || docker ps
      divider
      say "Инспекция сетевых портов на хосте:"
      for p in 80 443 8080 8097 8095 8096 8090 3478 5349 1812; do
        if port_busy_tcp "$p" || port_busy_udp "$p" || docker_port_busy "$p"; then
          local o; o="$(inspect_port_owner "$p")"
          printf "   • Порт %-6s : %s\n" "$p" "$o"
        fi
      done
      divider
      say "Последние строки логов:"
      $DC_CMD logs --tail=25 2>/dev/null || true
      ;;
    0|q|exit) exit 0 ;;
    *) warn "Неверный выбор: '$choice'. Выход."; exit 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# РАЗБОР АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)                  selected_modules="all"; cli_action="deploy_central"; shift ;;
    --core-only)            selected_modules="core"; cli_action="deploy_central"; shift ;;
    --modules)              selected_modules="${2:?}"; cli_action="deploy_central"; shift 2 ;;
    --role)                 role="${2:?}"; shift 2 ;;
    --dir)                  target_dir="${2:?}"; shift 2 ;;
    --update)               cli_action="update"; update_target="all"; shift ;;
    --update-module)        cli_action="update"; update_target="${2:?}"; shift 2 ;;
    --deploy-remote-ice)    cli_action="remote_ice"; remote_host="${2:?}"; shift 2 ;;
    --deploy-remote-relay)  cli_action="remote_relay"; remote_host="${2:?}"; shift 2 ;;
    --remote-user)          remote_user="${2:?}"; shift 2 ;;
    --remote-port)          remote_port="${2:?}"; shift 2 ;;
    --remote-key)           remote_key="${2:?}"; shift 2 ;;
    --ice-realm)            ice_realm="${2:?}"; shift 2 ;;
    --ice-email)            ice_email="${2:?}"; shift 2 ;;
    --tag)                  image_tag="${2:?}"; shift 2 ;;
    --set-password)         pg_password="${2:?}"; shift 2 ;;
    --fresh)                fresh=1; shift ;;
    --skip-preflight)       skip_preflight=1; shift ;;
    --mirrors)              force_mirrors=1; shift ;;
    --no-mirrors)           no_mirrors=1; shift ;;
    -h|--help)
      echo "Ligament Enterprise Installer v$VERSION"
      echo "Использование: ./install.sh [ОПЦИИ]"
      echo "  --all                        Установка всех центральных модулей стека"
      echo "  --core-only                  Установка только базового ядра 2FA"
      echo "  --modules <список>           Выборочные модули (core,chat,recorder,ticket,guard)"
      echo "  --update                     Обновление всех активных модулей"
      echo "  --update-module <имя>        Точечное обновление модуля (twofa, chat, recorder, ticket, guard)"
      echo "  --role ice|relay|central     Выбор целевой роли сервера"
      echo "  --deploy-remote-ice <host>   Удалённый деплой WebRTC ICE по SSH"
      echo "  --deploy-remote-relay <host> Удалённый деплой Relay по SSH"
      echo "  --fresh                      Сброс базы данных и чистый запуск"
      echo "  --skip-preflight             Пропуск проверки системных требований"
      exit 0
      ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
done

# Точка входа
init_workdir
check_system_requirements

if [[ -n "$cli_action" ]]; then
  case "$cli_action" in
    deploy_central) ensure_env_file; deploy_central ;;
    update)         update_services "$update_target" ;;
    remote_ice)     deploy_remote_ssh "ice" "$remote_host" ;;
    remote_relay)   deploy_remote_ssh "relay" "$remote_host" ;;
  esac
elif [[ "$role" == "ice" ]]; then
  deploy_ice
elif [[ "$role" == "relay" ]]; then
  deploy_relay
else
  run_interactive_tui
fi
