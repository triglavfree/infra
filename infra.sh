#!/bin/bash
set -euo pipefail
# =============================================================================
# INFRASTRUCTURE v8.9.3
# =============================================================================
# Исправлено: Автоматический netbird up после старта, правильные пути в Gitea
# =============================================================================

# =============== АНИМАЦИЯ И ЦВЕТА ===============
NEON_CYAN='\033[38;5;81m'
NEON_GREEN='\033[38;5;84m'
NEON_YELLOW='\033[38;5;220m'
NEON_RED='\033[38;5;203m'
NEON_PURPLE='\033[38;5;141m'
NEON_BLUE='\033[38;5;75m'
SOFT_WHITE='\033[38;5;252m'
MUTED_GRAY='\033[38;5;245m'
DIM_GRAY='\033[38;5;240m'
BOLD='\033[1m'
RESET='\033[0m'

CURRENT_USER="${SUDO_USER:-$(whoami)}"
CURRENT_UID=$(id -u "$CURRENT_USER")

typewrite() {
    local text="$1" color="${2:-$SOFT_WHITE}" delay="${3:-0.01}"
    printf "${color}"
    for ((i=0; i<${#text}; i++)); do
        printf "%s" "${text:$i:1}"
        sleep "$delay"
    done
    printf "${RESET}\n"
}

print_header() {
    echo ""
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"
    echo -e "${NEON_CYAN}${BOLD}  $1${RESET}"
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${NEON_CYAN}${BOLD}▸${RESET} ${SOFT_WHITE}${BOLD}$1${RESET}"
    echo -e "${DIM_GRAY}  $(printf '─%.0s' $(seq 1 40))${RESET}"
}

print_success() { echo -e "  ${NEON_GREEN}✓${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_warning() { echo -e "  ${NEON_YELLOW}⚡${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_error() { echo -e "  ${NEON_RED}✗${RESET} ${BOLD}$1${RESET}" >&2; exit 1; }
print_info() { echo -e "  ${NEON_BLUE}ℹ${RESET} ${MUTED_GRAY}$1${RESET}"; }
print_substep() { echo -e "  ${DIM_GRAY}→${RESET} ${MUTED_GRAY}$1${RESET}"; }

# =============== ПРОВЕРКА ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
fi

CURRENT_GID=$(id -g "$CURRENT_USER")
CURRENT_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"
SERVER_IP=$(hostname -I | awk '{print $1}')

print_header "INFRASTRUCTURE v8.9.3"
typewrite "Инициализация..." "$MUTED_GRAY" 0.02
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== КАТАЛОГИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
CONTAINERS_DIR="$INFRA_DIR/containers"
BOOTSTRAP_DIR="$INFRA_DIR/bootstrap"
RESTIC_DIR="$INFRA_DIR/restic"
RESTIC_REPO="$RESTIC_DIR/repo"
RESTIC_PASSWORD_FILE="$RESTIC_DIR/password.txt"
RESTIC_ENV_FILE="$RESTIC_DIR/restic.env"

CREATED_COUNT=0
for dir in "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$CONTAINERS_DIR" "$BOOTSTRAP_DIR" \
           "$RESTIC_DIR" "$RESTIC_REPO" "$VOLUMES_DIR"/{gitea,torrserver,gitea-runner,netbird}; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null
        chown "$CURRENT_USER:$CURRENT_USER" "$dir" 2>/dev/null || true
        ((CREATED_COUNT++)) || true
    fi
done

if [ $CREATED_COUNT -gt 0 ]; then
    print_success "Создано $CREATED_COUNT директорий"
else
    print_info "Директории уже существуют"
fi

if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    openssl rand -base64 32 > "$RESTIC_PASSWORD_FILE" 2>/dev/null || echo "$(date +%s)$RANDOM" > "$RESTIC_PASSWORD_FILE"
    chmod 600 "$RESTIC_PASSWORD_FILE"
    print_success "Пароль Restic создан"
else
    print_info "Пароль Restic уже существует"
fi

# =============== LINGER ===============
print_step "Настройка linger"

if ! loginctl show-user "$CURRENT_USER" 2>/dev/null | grep -q "Linger=yes"; then
    print_substep "Включение linger..."
    if sudo loginctl enable-linger "$CURRENT_USER"; then
        print_success "Linger активирован"
    else
        print_warning "Возможно, уже включен"
    fi
    sleep 1
else
    print_info "Linger уже включен"
fi

# =============== BOOTSTRAP ===============
print_step "Подготовка системы"

BOOTSTRAP_NEEDS_UPDATE=0
if [ ! -f "$BOOTSTRAP_DIR/bootstrap.sh" ]; then
    BOOTSTRAP_NEEDS_UPDATE=1
fi

if [ $BOOTSTRAP_NEEDS_UPDATE -eq 1 ]; then
    cat > "$BOOTSTRAP_DIR/bootstrap.sh" <<'BOOTEOF'
#!/bin/bash
set -euo pipefail
REAL_USER="${REAL_USER:-$SUDO_USER}"
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "1000")
[ -z "$REAL_USER" ] && exit 1
[ "$(id -u)" != "0" ] && exit 1

modprobe wireguard 2>/dev/null || true
echo "wireguard" > /etc/modules-load.d/wireguard.conf 2>/dev/null || true

cat > /etc/sysctl.d/99-netbird.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv4.ip_unprivileged_port_start=80
EOF
sysctl --system >/dev/null 2>&1 || true

[ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && \
    echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true

systemctl enable systemd-resolved 2>/dev/null || true
systemctl start systemd-resolved 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    podman podman-docker uidmap slirp4netns fuse-overlayfs \
    ufw fail2ban gpg cron net-tools dnsutils jq curl \
    wireguard-tools linux-headers-$(uname -r) openssl \
    >/dev/null 2>&1 || true

if [ -f "/home/$REAL_USER/.ssh/authorized_keys" ] && \
   grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2)' "/home/$REAL_USER/.ssh/authorized_keys" 2>/dev/null; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
    systemctl restart sshd 2>/dev/null || true
fi

if [ ! -f /etc/subuid ] || ! grep -q "$REAL_USER:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER" 2>/dev/null || true
fi

mkdir -p /run/user/$REAL_UID
chown $REAL_USER:$REAL_USER /run/user/$REAL_UID
chmod 700 /run/user/$REAL_UID

mkdir -p /var/lib/netbird
chmod 755 /var/lib/netbird

SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1 || true
ufw allow 80,443,3000,8090,2222/tcp >/dev/null 2>&1 || true
ufw allow 3478/udp >/dev/null 2>&1 || true
ufw allow 49152:65535/udp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

echo "✓ Готово"
BOOTEOF
    chmod +x "$BOOTSTRAP_DIR/bootstrap.sh"
    print_success "Bootstrap создан"
else
    print_info "Bootstrap уже актуален"
fi

# =============== RESTIC SETUP ===============
print_step "Настройка Restic"

RESTIC_ENV_NEEDS_UPDATE=0
if [ ! -f "$RESTIC_ENV_FILE" ]; then
    RESTIC_ENV_NEEDS_UPDATE=1
fi

if [ $RESTIC_ENV_NEEDS_UPDATE -eq 1 ]; then
    cat > "$RESTIC_ENV_FILE" <<EOF
# Restic конфигурация
# Для локальных бэкапов оставьте как есть
# Для S3: RESTIC_REPOSITORY=s3:s3.amazonaws.com/bucketname
# Для B2: RESTIC_REPOSITORY=b2:bucketname:path

# AWS S3:
# AWS_ACCESS_KEY_ID=your-key
# AWS_SECRET_ACCESS_KEY=your-secret

# Backblaze B2:
# B2_ACCOUNT_ID=your-account
# B2_ACCOUNT_KEY=your-key
EOF
    chmod 600 "$RESTIC_ENV_FILE"
    print_success "Restic env создан"
else
    print_info "Restic env уже существует"
fi

if [ ! -f "$BIN_DIR/restic-wrapper" ]; then
    cat > "$BIN_DIR/restic-wrapper" <<EOF
#!/bin/bash
RESTIC_DIR="$RESTIC_DIR"
RESTIC_REPO="$RESTIC_REPO"
RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
RESTIC_ENV_FILE="$RESTIC_ENV_FILE"
RESTIC_IMAGE="docker.io/restic/restic:latest"

if [ -f "\$RESTIC_ENV_FILE" ]; then
    set -a
    source "\$RESTIC_ENV_FILE"
    set +a
fi

if ! podman image exists \$RESTIC_IMAGE 2>/dev/null; then
    echo "Загрузка Restic..." >&2
    podman pull \$RESTIC_IMAGE >/dev/null 2>&1
fi

if [ -z "\${RESTIC_REPOSITORY:-}" ]; then
    RESTIC_REPOSITORY="/restic-repo"
fi

podman run --rm -it \\
    --volume "\$RESTIC_REPO:/restic-repo:Z" \\
    --volume "\$RESTIC_PASSWORD_FILE:/restic-password:ro,Z" \\
    --volume "\$RESTIC_ENV_FILE:/restic.env:ro,Z" \\
    --env-file "\$RESTIC_ENV_FILE" \\
    --env RESTIC_REPOSITORY="\$RESTIC_REPOSITORY" \\
    --env RESTIC_PASSWORD_FILE=/restic-password \\
    --security-opt label=disable \\
    \$RESTIC_IMAGE "\$@"
EOF
    chmod +x "$BIN_DIR/restic-wrapper"
    print_success "Restic wrapper создан"
else
    print_info "Restic wrapper уже существует"
fi

if [ ! -f "$RESTIC_REPO/config" ]; then
    print_substep "Инициализация локального репозитория..."
    if "$BIN_DIR/restic-wrapper" init 2>/dev/null; then
        print_success "Репозиторий создан"
        echo ""
        echo -e "  ${NEON_YELLOW}⚠ ВАЖНО:${RESET} ${SOFT_WHITE}Сохраните пароль из файла:${RESET}"
        echo -e "  ${NEON_CYAN}$RESTIC_PASSWORD_FILE${RESET}"
        echo -e "  ${MUTED_GRAY}Без этого пароля данные невозможно восстановить!${RESET}"
        echo ""
    else
        print_info "Репозиторий уже существует"
    fi
else
    print_info "Restic репозиторий уже инициализирован"
fi

# =============== CLI INFRA ===============
print_step "Создание CLI"

CLI_NEEDS_UPDATE=0
if [ ! -f "$BIN_DIR/infra" ]; then
    CLI_NEEDS_UPDATE=1
else
    CURRENT_SIZE=$(stat -c%s "$BIN_DIR/infra" 2>/dev/null || echo 0)
    if [ $CURRENT_SIZE -lt 1000 ]; then
        CLI_NEEDS_UPDATE=1
    fi
fi

if [ $CLI_NEEDS_UPDATE -eq 1 ]; then
    cat > "$BIN_DIR/infra" <<'CLIEOF'
#!/bin/bash
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
RESTIC_DIR="$INFRA_DIR/restic"
RESTIC_REPO="$RESTIC_DIR/repo"
RESTIC_PASSWORD_FILE="$RESTIC_DIR/password.txt"
RESTIC_ENV_FILE="$RESTIC_DIR/restic.env"
NETBIRD_CONFIG="/var/lib/netbird"
RESTIC_IMAGE="docker.io/restic/restic:latest"

if [ -f "$RESTIC_ENV_FILE" ]; then
    set -a
    source "$RESTIC_ENV_FILE"
    set +a
fi

restic_cmd() {
    if ! podman image exists $RESTIC_IMAGE 2>/dev/null; then
        podman pull $RESTIC_IMAGE >/dev/null 2>&1
    fi
    
    podman run --rm \
        --volume "$RESTIC_REPO:/restic-repo:Z" \
        --volume "$RESTIC_PASSWORD_FILE:/restic-password:ro,Z" \
        --volume "$RESTIC_ENV_FILE:/restic.env:ro,Z" \
        --env-file "$RESTIC_ENV_FILE" \
        --env RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/restic-repo}" \
        --env RESTIC_PASSWORD_FILE=/restic-password \
        --security-opt label=disable \
        $RESTIC_IMAGE "$@"
}

CYAN='\033[38;5;81m'
GREEN='\033[38;5;84m'
YELLOW='\033[38;5;220m'
RED='\033[38;5;203m'
BLUE='\033[38;5;75m'
WHITE='\033[38;5;252m'
GRAY='\033[38;5;240m'
RESET='\033[0m'
BOLD='\033[1m'

show_status() {
    echo -e "${BOLD}${CYAN}▸ СТАТУС СЕРВИСОВ${RESET}"
    echo ""
    
    echo -e "${GRAY}Rootless:${RESET}"
    systemctl --user list-units --type=service --state=running 2>/dev/null | \
        grep -E "(gitea|torrserver|gitea-runner)" | \
        while read line; do
            name=$(echo "$line" | awk '{print $1}' | sed 's/.service//')
            echo -e "  ${GREEN}●${RESET} ${WHITE}${name}${RESET}"
        done || echo -e "  ${YELLOW}⚡${RESET} ${GRAY}Нет активных${RESET}"
    
    echo ""
    echo -e "${GRAY}Rootful:${RESET}"
    systemctl list-units --type=service --state=running 2>/dev/null | \
        grep -E "netbird" | \
        while read line; do
            name=$(echo "$line" | awk '{print $1}' | sed 's/.service//')
            echo -e "  ${GREEN}●${RESET} ${WHITE}${name}${RESET} ${BLUE}(rootful)${RESET}"
        done || echo -e "  ${YELLOW}⚡${RESET} ${GRAY}NetBird не запущен${RESET}"
    
    echo ""
    echo -e "${BOLD}${CYAN}▸ Restic:${RESET}"
    if [ -f "$RESTIC_REPO/config" ] || [ -n "${RESTIC_REPOSITORY:-}" ]; then
        local snapshot_count=$(restic_cmd snapshots --json 2>/dev/null | jq 'length' || echo "0")
        local repo_type="локально"
        [ -n "${RESTIC_REPOSITORY:-}" ] && [[ "$RESTIC_REPOSITORY" == s3* ]] && repo_type="S3"
        [ -n "${RESTIC_REPOSITORY:-}" ] && [[ "$RESTIC_REPOSITORY" == b2* ]] && repo_type="B2"
        printf "  ${GREEN}●${RESET} ${WHITE}%s снапшотов (%s)${RESET}\n" "$snapshot_count" "$repo_type"
    else
        echo -e "  ${RED}✗${RESET} ${GRAY}Не настроен${RESET}"
    fi
    
    echo ""
    echo -e "${BOLD}${CYAN}▸ Диск:${RESET}"
    du -sh "$VOLUMES_DIR"/* 2>/dev/null | while read size dir; do
        name=$(basename "$dir")
        printf "  ${GRAY}%-15s${RESET} ${WHITE}%8s${RESET}\n" "$name" "$size"
    done || true
}

show_monitor() {
    echo -e "${BOLD}${CYAN}▸ Проверка сервисов${RESET}\n"
    local services="gitea:3000 torrserver:8090"
    for svc in $services; do
        name="${svc%%:*}"; port="${svc##*:}"
        if curl -sf --max-time 2 "http://localhost:$port" >/dev/null 2>&1; then
            printf "  ${GREEN}✓${RESET} ${WHITE}%-12s${RESET} ${GRAY}:$port${RESET} ${GREEN}ONLINE${RESET}\n" "$name"
        else
            printf "  ${RED}✗${RESET} ${WHITE}%-12s${RESET} ${GRAY}:$port${RESET} ${RED}OFFLINE${RESET}\n" "$name"
        fi
    done
    
    echo ""
    if sudo systemctl is-active --quiet netbird.service 2>/dev/null; then
        printf "  ${GREEN}✓${RESET} ${WHITE}%-12s${RESET} ${GRAY}wg0${RESET} ${GREEN}CONNECTED${RESET}\n" "netbird"
        local nb_ip=$(sudo podman exec netbird netbird status 2>/dev/null | grep "NetBird IP:" | awk '{print $3}' || echo "N/A")
        printf "    ${GRAY}IP: %s${RESET}\n" "$nb_ip"
    else
        printf "  ${RED}✗${RESET} ${WHITE}%-12s${RESET} ${GRAY}wg0${RESET} ${RED}OFFLINE${RESET}\n" "netbird"
    fi
}

do_backup() {
    echo -e "${CYAN}Остановка сервисов...${RESET}"
    systemctl --user stop gitea torrserver gitea-runner 2>/dev/null || true
    sudo systemctl stop netbird 2>/dev/null || true
    sleep 2
    
    echo -e "${CYAN}Бэкап volumes...${RESET}"
    podman run --rm \
        --volume "$RESTIC_REPO:/restic-repo:Z" \
        --volume "$RESTIC_PASSWORD_FILE:/restic-password:ro,Z" \
        --volume "$RESTIC_ENV_FILE:/restic.env:ro,Z" \
        --volume "$VOLUMES_DIR:/backup/volumes:ro,Z" \
        --env-file "$RESTIC_ENV_FILE" \
        --env RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/restic-repo}" \
        --env RESTIC_PASSWORD_FILE=/restic-password \
        --security-opt label=disable \
        $RESTIC_IMAGE backup /backup/volumes --tag "volumes" 2>/dev/null && \
        echo -e "${GREEN}✓ Volumes${RESET}" || \
        echo -e "${RED}✗ Ошибка volumes${RESET}"
    
    echo -e "${CYAN}Бэкап NetBird...${RESET}"
    if [ -d "$NETBIRD_CONFIG" ]; then
        local temp_archive="$INFRA_DIR/.netbird-$(date +%s).tar.gz"
        sudo tar -czf "$temp_archive" -C / var/lib/netbird 2>/dev/null
        
        podman run --rm \
            --volume "$RESTIC_REPO:/restic-repo:Z" \
            --volume "$RESTIC_PASSWORD_FILE:/restic-password:ro,Z" \
            --volume "$RESTIC_ENV_FILE:/restic.env:ro,Z" \
            --volume "$temp_archive:/backup/netbird.tar.gz:ro,Z" \
            --env-file "$RESTIC_ENV_FILE" \
            --env RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/restic-repo}" \
            --env RESTIC_PASSWORD_FILE=/restic-password \
            --security-opt label=disable \
            $RESTIC_IMAGE backup /backup/netbird.tar.gz --tag "netbird" 2>/dev/null && \
            echo -e "${GREEN}✓ NetBird${RESET}" || \
            echo -e "${RED}✗ Ошибка NetBird${RESET}"
        
        rm -f "$temp_archive"
    else
        echo -e "${YELLOW}⚡ NetBird конфиг не найден${RESET}"
    fi
    
    echo -e "${CYAN}Очистка старых снапшотов...${RESET}"
    restic_cmd forget --keep-last 7 --prune 2>/dev/null || true
    
    echo -e "${GREEN}✓ Бэкап завершен${RESET}"
    restic_cmd snapshots 2>/dev/null || true
    
    echo -e "${CYAN}Запуск сервисов...${RESET}"
    systemctl --user start gitea torrserver gitea-runner 2>/dev/null || true
    sudo systemctl start netbird 2>/dev/null || true
}

do_restore() {
    echo -e "${YELLOW}Доступные снапшоты:${RESET}"
    restic_cmd snapshots 2>/dev/null || { echo -e "${RED}Нет снапшотов${RESET}"; exit 1; }
    
    echo ""
    read -rp "$(echo -e "${YELLOW}ID снапшота (Enter — последний):${RESET} ")" SNAPSHOT_ID
    
    if [ -z "$SNAPSHOT_ID" ]; then
        SNAPSHOT_ID=$(restic_cmd snapshots --json 2>/dev/null | jq -r '.[-1].id')
        echo -e "${GRAY}Используем последний: $SNAPSHOT_ID${RESET}"
    fi
    
    echo -e "${YELLOW}Остановка сервисов...${RESET}"
    systemctl --user stop '*.service' 2>/dev/null || true
    sudo systemctl stop netbird 2>/dev/null || true
    sleep 2
    
    echo -e "${CYAN}Восстановление volumes...${RESET}"
    podman run --rm \
        --volume "$RESTIC_REPO:/restic-repo:Z" \
        --volume "$RESTIC_PASSWORD_FILE:/restic-password:ro,Z" \
        --volume "$RESTIC_ENV_FILE:/restic.env:ro,Z" \
        --volume "$VOLUMES_DIR:/restore:Z" \
        --env-file "$RESTIC_ENV_FILE" \
        --env RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/restic-repo}" \
        --env RESTIC_PASSWORD_FILE=/restic-password \
        --security-opt label=disable \
        $RESTIC_IMAGE restore "$SNAPSHOT_ID" --target /restore 2>/dev/null && \
        chown -R "$USER:$USER" "$VOLUMES_DIR" 2>/dev/null || true
    
    local temp_restore="$INFRA_DIR/.restore_$(date +%s)"
    mkdir -p "$temp_restore"
    
    podman run --rm \
        --volume "$RESTIC_REPO:/restic-repo:Z" \
        --volume "$RESTIC_PASSWORD_FILE:/restic-password:ro,Z" \
        --volume "$RESTIC_ENV_FILE:/restic.env:ro,Z" \
        --volume "$temp_restore:/restore:Z" \
        --env-file "$RESTIC_ENV_FILE" \
        --env RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/restic-repo}" \
        --env RESTIC_PASSWORD_FILE=/restic-password \
        --security-opt label=disable \
        $RESTIC_IMAGE restore "$SNAPSHOT_ID" --target /restore --include "netbird.tar.gz" 2>/dev/null
    
    if [ -f "$temp_restore/backup/netbird.tar.gz" ] || [ -f "$temp_restore/netbird.tar.gz" ]; then
        local nb_archive=$(find "$temp_restore" -name "netbird.tar.gz" 2>/dev/null | head -1)
        if [ -n "$nb_archive" ]; then
            echo -e "${CYAN}Восстановление NetBird...${RESET}"
            sudo rm -rf "$NETBIRD_CONFIG" 2>/dev/null || true
            sudo tar -xzf "$nb_archive" -C / 2>/dev/null && \
                echo -e "${GREEN}✓ NetBird${RESET}" || \
                echo -e "${RED}✗ Ошибка NetBird${RESET}"
        fi
    else
        echo -e "${YELLOW}⚡ NetBird не найден в снапшоте${RESET}"
    fi
    
    rm -rf "$temp_restore"
    
    echo -e "${CYAN}Запуск сервисов...${RESET}"
    systemctl --user start gitea torrserver gitea-runner 2>/dev/null || true
    sudo systemctl start netbird 2>/dev/null || true
    
    echo -e "${GREEN}✓ Восстановление завершено${RESET}"
}

case "${1:-status}" in
    status) show_status ;;
    backup) do_backup ;;
    restore) do_restore ;;
    snapshots)
        echo -e "${BOLD}${CYAN}▸ Снапшоты:${RESET}"
        restic_cmd snapshots 2>/dev/null || echo -e "${RED}Ошибка${RESET}"
        ;;
    check)
        echo -e "${CYAN}Проверка репозитория...${RESET}"
        restic_cmd check 2>/dev/null && echo -e "${GREEN}✓ OK${RESET}" || echo -e "${RED}✗ Ошибка${RESET}"
        ;;
    start) 
        systemctl --user start gitea torrserver gitea-runner && \
        sudo systemctl start netbird && \
        echo -e "${GREEN}✓ Запущены${RESET}"
        ;;
    stop) 
        systemctl --user stop gitea torrserver gitea-runner && \
        sudo systemctl stop netbird && \
        echo -e "${YELLOW}✓ Остановлены${RESET}"
        ;;
    restart)
        systemctl --user restart gitea torrserver gitea-runner && \
        sudo systemctl restart netbird && \
        echo -e "${GREEN}✓ Перезапущены${RESET}"
        ;;
    logs) 
        [ -z "${2:-}" ] && { echo "Использование: infra logs <сервис>"; exit 1; }
        if [ "$2" = "netbird" ]; then
            sudo journalctl -u netbird.service -n 100 -f
        else
            journalctl --user -u "${2}.service" -n 100 -f
        fi
        ;;
    monitor) show_monitor ;;
    netbird-status)
        echo -e "${CYAN}Статус NetBird:${RESET}"
        sudo podman exec netbird netbird status 2>/dev/null || echo -e "${RED}Не запущен${RESET}"
        ;;
    netbird-down)
        sudo podman exec netbird netbird down 2>/dev/null && echo -e "${YELLOW}Отключен${RESET}"
        ;;
    netbird-up)
        sudo podman exec netbird netbird up 2>/dev/null && echo -e "${GREEN}Подключен${RESET}"
        ;;
    update)
        echo -e "${CYAN}Обновление образов...${RESET}"
        podman auto-update --rollback=false 2>/dev/null || \
        echo -e "${YELLOW}⚡ Обновите вручную: podman pull <образ>${RESET}"
        ;;
    restic)
        shift
        restic_cmd "$@"
        ;;
    *) 
        echo -e "${BOLD}Использование:${RESET} infra ${GRAY}{команда}${RESET}"
        echo ""
        echo -e "  ${CYAN}status${RESET}      - статус сервисов"
        echo -e "  ${CYAN}monitor${RESET}     - проверка портов"
        echo -e "  ${CYAN}backup${RESET}      - создать бэкап"
        echo -e "  ${CYAN}restore${RESET}     - восстановить из бэкапа"
        echo -e "  ${CYAN}snapshots${RESET}   - список снапшотов"
        echo -e "  ${CYAN}check${RESET}       - проверить репозиторий"
        echo -e "  ${CYAN}logs${RESET} ${GRAY}<сервис>${RESET} - логи сервиса"
        echo -e "  ${CYAN}start/stop/restart${RESET} - управление сервисами"
        echo -e "  ${CYAN}restic${RESET} ${GRAY}<команда>${RESET} - прямые команды restic"
        echo ""
        echo -e "${GRAY}Облачные бэкапы:${RESET} Настройте в $RESTIC_ENV_FILE"
        ;;
esac
CLIEOF

    chmod +x "$BIN_DIR/infra"
    print_success "CLI создан"
else
    print_info "CLI уже актуален"
fi

if [ ! -L "/usr/local/bin/infra" ] || [ "$(readlink /usr/local/bin/infra)" != "$BIN_DIR/infra" ]; then
    sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true
    print_success "Симлинк infra создан"
fi

if ! grep -q "infra/bin" "$CURRENT_HOME/.bashrc" 2>/dev/null; then
    echo '' >> "$CURRENT_HOME/.bashrc"
    echo 'export PATH="$HOME/infra/bin:$PATH"' >> "$CURRENT_HOME/.bashrc"
    echo 'alias i="infra"' >> "$CURRENT_HOME/.bashrc"
    print_success "PATH и alias добавлены в .bashrc"
else
    print_info ".bashrc уже настроен"
fi

# =============== HEALTHCHECK ===============
print_step "Настройка healthcheck"

if [ ! -f "$BIN_DIR/healthcheck.sh" ]; then
    cat > "$BIN_DIR/healthcheck.sh" <<'HEALTHEOF'
#!/bin/bash
LOG_FILE="$HOME/infra/logs/healthcheck.log"
mkdir -p "$(dirname "$LOG_FILE")"

check_service() {
    local name=$1 port=$2
    if ! curl -sf --max-time 3 "http://localhost:$port" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name:$port НЕДОСТУПЕН, перезапуск..." >> "$LOG_FILE"
        systemctl --user restart "$name.service" 2>/dev/null || true
    fi
}

check_service gitea 3000
check_service torrserver 8090

if ! sudo systemctl is-active --quiet netbird.service 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird НЕДОСТУПЕН, перезапуск..." >> "$LOG_FILE"
    sudo systemctl restart netbird.service 2>/dev/null || true
fi
HEALTHEOF
    chmod +x "$BIN_DIR/healthcheck.sh"
    print_success "Healthcheck создан"
else
    print_info "Healthcheck уже существует"
fi

# =============== СЕРВИСЫ ===============
print_step "Создание сервисов"

USER_CONFIG="${XDG_CONFIG_HOME:-$CURRENT_HOME/.config}"
SYSTEMD_DIR="$USER_CONFIG/containers/systemd"
mkdir -p "$SYSTEMD_DIR"

PODMAN_SOCKET_PATH="/run/user/$CURRENT_UID/podman"
if [ ! -d "$PODMAN_SOCKET_PATH" ]; then
    print_substep "Создание директории для Podman socket..."
    mkdir -p "$PODMAN_SOCKET_PATH" 2>/dev/null || true
fi

# Gitea service
if [ ! -f ~/.config/systemd/user/gitea.service ] || \
   ! grep -q "Type=forking" ~/.config/systemd/user/gitea.service 2>/dev/null; then
    print_substep "Создание gitea.service..."
    mkdir -p ~/.config/systemd/user/

    cat > ~/.config/systemd/user/gitea.service <<EOF
[Unit]
Description=Gitea (Podman container)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Restart=always
RestartSec=5
TimeoutStartSec=900
PIDFile=%t/container-gitea.pid
Environment=PODMAN_SYSTEMD_UNIT=gitea.service
ExecStartPre=-/usr/bin/podman rm -f gitea
ExecStart=/usr/bin/podman run \\
    --name gitea \\
    --replace \\
    --rm \\
    -d \\
    --pidfile %t/container-gitea.pid \\
    --security-opt label=disable \\
    --memory=2G \\
    --cpus=2.0 \\
    -v $CURRENT_HOME/infra/volumes/gitea:/data \\
    -e GITEA__server__DOMAIN=$SERVER_IP \\
    -e GITEA__server__ROOT_URL=http://$SERVER_IP:3000/ \\
    -e GITEA__server__SSH_DOMAIN=$SERVER_IP \\
    -e GITEA__server__SSH_PORT=2222 \\
    -e GITEA__actions__ENABLED=true \\
    -e GITEA__database__SQLITE_BUSY_TIMEOUT=5000 \\
    -e GITEA__database__SQLITE_JOURNAL_MODE=WAL \\
    -e GITEA__database__SQLITE_LOCK_TIMEOUT=5000 \\
    -e GITEA__log__LEVEL=Warn \\
    -e GITEA__log__MODE=console \\
    -p 3000:3000 \\
    -p 2222:22 \\
    docker.io/gitea/gitea:latest
ExecStop=/usr/bin/podman stop -t 10 gitea
ExecStopPost=-/usr/bin/podman rm -f gitea

[Install]
WantedBy=default.target
EOF
    chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/gitea.service 2>/dev/null || true
    print_success "gitea.service создан"
else
    print_info "gitea.service уже актуален"
fi

# TorrServer через Quadlet
create_container() {
    echo "$2" > "$1"
    chown "$CURRENT_USER:$CURRENT_USER" "$1" 2>/dev/null || true
}

TORRSERVER_CONTAINER="$CONTAINERS_DIR/torrserver.container"
if [ ! -f "$TORRSERVER_CONTAINER" ]; then
    create_container "$TORRSERVER_CONTAINER" "[Container]
Image=ghcr.io/yourok/torrserver:latest
Volume=$CURRENT_HOME/infra/volumes/torrserver:/app/z:Z
PublishPort=8090:8090
Environment=TS_DONTKILL=1
Label=io.containers.autoupdate=registry

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=default.target"
    print_success "torrserver.container создан"
else
    print_info "torrserver.container уже актуален"
fi

rm -f "$SYSTEMD_DIR"/*.container 2>/dev/null || true
cp "$CONTAINERS_DIR"/*.container "$SYSTEMD_DIR/" 2>/dev/null || true
chown -R "$CURRENT_USER:$CURRENT_USER" "$SYSTEMD_DIR" 2>/dev/null || true

print_success "Сервисы настроены"

# =============== NETBIRD ===============
print_step "Настройка NetBird"

if [ ! -d "/var/lib/netbird" ]; then
    print_substep "Создание /var/lib/netbird..."
    sudo mkdir -p /var/lib/netbird
    sudo chmod 755 /var/lib/netbird
fi

sudo rm -f /etc/containers/systemd/netbird.container 2>/dev/null || true

NETBIRD_NEEDS_UPDATE=0
if [ ! -f /etc/systemd/system/netbird.service ]; then
    NETBIRD_NEEDS_UPDATE=1
else
    if ! grep -q "docker.io/netbirdio/netbird:latest" /etc/systemd/system/netbird.service 2>/dev/null; then
        NETBIRD_NEEDS_UPDATE=1
    fi
fi

if [ $NETBIRD_NEEDS_UPDATE -eq 1 ]; then
    print_substep "Создание netbird.service..."
    sudo tee /etc/systemd/system/netbird.service > /dev/null <<'NETBIRDEOF'
[Unit]
Description=NetBird Mesh VPN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
Environment="NB_SETUP_KEY=PLACEHOLDER_SETUP_KEY"
Environment="NB_MANAGEMENT_URL=https://api.netbird.io:443   "
Environment="NB_LOG_LEVEL=info"
ExecStartPre=-/usr/bin/podman rm -f netbird
ExecStart=/usr/bin/podman run \
    --name netbird \
    --rm \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SYS_ADMIN \
    --device /dev/net/tun \
    --network host \
    --pid host \
    -v /var/lib/netbird:/etc/netbird:Z \
    -v /run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro \
    -e NB_SETUP_KEY \
    -e NB_MANAGEMENT_URL \
    -e NB_LOG_LEVEL \
    docker.io/netbirdio/netbird:latest
ExecStop=/usr/bin/podman stop -t 10 netbird
ExecStopPost=-/usr/bin/podman rm -f netbird

[Install]
WantedBy=multi-user.target
NETBIRDEOF
    sudo chmod 644 /etc/systemd/system/netbird.service
    sudo systemctl daemon-reload
    print_success "NetBird сервис создан"
else
    print_info "NetBird сервис уже актуален"
fi

# =============== ХОСТ ===============
print_step "Настройка хоста"

print_substep "Запуск bootstrap..."
if sudo REAL_USER="$CURRENT_USER" REAL_HOME="$CURRENT_HOME" "$BOOTSTRAP_DIR/bootstrap.sh" >/dev/null 2>&1; then
    print_success "Система настроена"
else
    print_warning "Часть настроек уже применена"
fi

# =============== ЗАПУСК СЕРВИСОВ ===============
print_step "Запуск сервисов"

export XDG_RUNTIME_DIR="/run/user/$CURRENT_UID"
systemctl --user set-environment XDG_RUNTIME_DIR="/run/user/$CURRENT_UID" 2>/dev/null || true
systemctl --user daemon-reexec 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

if [ ! -S "/run/user/$CURRENT_UID/podman/podman.sock" ]; then
    print_substep "Запуск Podman API socket..."
    systemctl --user start podman.socket 2>/dev/null || true
    sleep 2
fi

# Запускаем в фоне, не блокируемся
services=(gitea torrserver)
for svc in "${services[@]}"; do
    if systemctl --user is-active --quiet "$svc.service" 2>/dev/null; then
        print_info "$svc уже запущен"
    else
        print_substep "Запуск $svc..."
        # Запуск в фоне, не ждём завершения
        (systemctl --user start "$svc.service" 2>/dev/null &) 
    fi
done

# Ждём немного для инициализации
sleep 5

# Проверяем статус без блокировки
for svc in "${services[@]}"; do
    if systemctl --user is-active --quiet "$svc.service" 2>/dev/null; then
        print_success "$svc активен"
    else
        print_warning "$svc запускается (может занять 10-30 сек)..."
    fi
done

# =============== GITEA RUNNER ===============
print_step "Настройка Gitea Runner"

# Проверяем существование runner
RUNNER_EXISTS=0
if systemctl --user is-active --quiet gitea-runner.service 2>/dev/null || \
   systemctl --user is-enabled gitea-runner.service 2>/dev/null | grep -q enabled; then
    RUNNER_EXISTS=1
    print_info "Runner уже существует"
    read -rp "$(echo -e "  ${NEON_YELLOW}→${RESET} ${SOFT_WHITE}Пересоздать runner? [y/N]:${RESET} ")" RECREATE_RUNNER
    if [[ "$RECREATE_RUNNER" =~ ^[Yy]$ ]]; then
        print_substep "Остановка и удаление текущего runner..."
        systemctl --user stop gitea-runner.service 2>/dev/null || true
        systemctl --user disable gitea-runner.service 2>/dev/null || true
        podman rm -f gitea-runner 2>/dev/null || true
        rm -f ~/.config/systemd/user/gitea-runner.service
        systemctl --user daemon-reload
        RUNNER_EXISTS=0
    fi
fi

if [ $RUNNER_EXISTS -eq 0 ]; then
    echo ""
    echo -e "${NEON_PURPLE}${BOLD}▸ РЕГИСТРАЦИЯ RUNNER'А${RESET}"
    echo ""
    echo -e "  ${MUTED_GRAY}1. Откройте Gitea:${RESET} ${NEON_CYAN}http://$SERVER_IP:3000${RESET}"
    echo -e "  ${MUTED_GRAY}2. Панель Управления → Действия → Раннеры${RESET}"
    echo -e "  ${MUTED_GRAY}3. Нажмите 'Создать новый раннер'${RESET}"
    echo -e "  ${MUTED_GRAY}4. Скопируйте Registration Token${RESET}"
    echo ""

    read -rp "$(echo -e "  ${NEON_YELLOW}→${RESET} ${SOFT_WHITE}Registration Token (Enter — пропустить):${RESET} ")" RUNNER_TOKEN
    
    if [ -n "${RUNNER_TOKEN:-}" ]; then
        mkdir -p "$VOLUMES_DIR/gitea-runner"
        chown "$CURRENT_USER:$CURRENT_USER" "$VOLUMES_DIR/gitea-runner" 2>/dev/null || true
        
        print_substep "Создание gitea-runner.service..."
        
        # Используем простой тип simple вместо forking для надёжности
        cat > ~/.config/systemd/user/gitea-runner.service <<EOF
[Unit]
Description=Gitea Runner (Podman container)
After=gitea.service network-online.target
Wants=gitea.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=300
Environment=PODMAN_SYSTEMD_UNIT=gitea-runner.service
Environment=GITEA_INSTANCE_URL=http://$SERVER_IP:3000
Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN
Environment=GITEA_RUNNER_NAME=runner-$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')-$(date +%s | tail -c 4)
Environment=GITEA_RUNNER_LABELS=ubuntu-latest:docker://node:20-bullseye,self-hosted:host
Environment=GITEA_RUNNER_FETCH_INTERVAL=5s
ExecStartPre=-/usr/bin/podman rm -f gitea-runner
ExecStart=/usr/bin/podman run \\
    --name gitea-runner \\
    --replace \\
    --rm \\
    --security-opt label=disable \\
    -v $CURRENT_HOME/infra/volumes/gitea-runner:/data:Z \\
    -v /run/user/$CURRENT_UID/podman/podman.sock:/var/run/docker.sock:ro \\
    -e GITEA_INSTANCE_URL \\
    -e GITEA_RUNNER_REGISTRATION_TOKEN \\
    -e GITEA_RUNNER_NAME \\
    -e GITEA_RUNNER_LABELS \\
    -e GITEA_RUNNER_FETCH_INTERVAL \\
    docker.io/gitea/act_runner:nightly
ExecStop=/usr/bin/podman stop -t 10 gitea-runner
ExecStopPost=-/usr/bin/podman rm -f gitea-runner

[Install]
WantedBy=default.target
EOF

        chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/gitea-runner.service 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
        
        print_substep "Запуск runner..."
        # Включаем автозапуск
        systemctl --user enable gitea-runner.service 2>/dev/null || true
        
        # Запускаем и ждём немного
        if systemctl --user start gitea-runner.service 2>/dev/null; then
            sleep 15
            if systemctl --user is-active --quiet gitea-runner.service 2>/dev/null; then
                print_success "Runner активен и зарегистрирован"
                RUNNER_EXISTS=1
            else
                print_warning "Сервис не стал активным, проверяем логи..."
                local runner_logs=$(journalctl --user -u gitea-runner.service -n 30 --no-pager 2>/dev/null || echo "")
                if echo "$runner_logs" | grep -qi "registration\|token\|unauthorized"; then
                    print_error "Ошибка регистрации — проверьте токен"
                    echo -e "  ${DIM_GRAY}Полный лог: journalctl --user -u gitea-runner.service -n 50${RESET}"
                    # Удаляем неработающий сервис
                    systemctl --user stop gitea-runner.service 2>/dev/null || true
                    systemctl --user disable gitea-runner.service 2>/dev/null || true
                    rm -f ~/.config/systemd/user/gitea-runner.service
                    systemctl --user daemon-reload
                    RUNNER_EXISTS=0
                else
                    print_warning "Возможно, runner ещё регистрируется..."
                    echo -e "  ${DIM_GRAY}Проверьте статус через: infra logs gitea-runner${RESET}"
                    # Проверим ещё раз через 10 секунд
                    sleep 10
                    if systemctl --user is-active --quiet gitea-runner.service 2>/dev/null; then
                        print_success "Runner теперь активен"
                        RUNNER_EXISTS=1
                    else
                        print_warning "Runner не запустился. Проверьте логи."
                        RUNNER_EXISTS=0
                    fi
                fi
            fi
        else
            print_warning "Не удалось запустить сервис"
            echo -e "  ${DIM_GRAY}Попробуйте вручную: systemctl --user start gitea-runner.service${RESET}"
            echo -e "  ${DIM_GRAY}Логи: journalctl --user -u gitea-runner.service -n 50${RESET}"
            RUNNER_EXISTS=0
        fi
    else
        print_info "Runner пропущен. Создать позже:"
        echo -e "  ${DIM_GRAY}1. Получите токен в Gitea: http://$SERVER_IP:3000/admin/actions/runners${RESET}"
        echo -e "  ${DIM_GRAY}2. Запустите скрипт заново или создайте вручную${RESET}"
        RUNNER_EXISTS=0
    fi
fi

# =============== NETBIRD SETUP ===============
print_step "Настройка NetBird VPN"

# Проверяем статус
if sudo systemctl is-active --quiet netbird.service 2>/dev/null; then
    # Проверяем, подключен ли он (есть ли IP)
    NB_IP=$(sudo podman exec netbird netbird status 2>/dev/null | grep "NetBird IP:" | awk '{print $3}' || echo "")
    if [ -n "$NB_IP" ]; then
        print_info "NetBird уже подключен"
        print_success "IP: $NB_IP"
    else
        print_warning "NetBird запущен, но не подключен"
        # Пробуем подключить
        print_substep "Попытка подключения..."
        sudo podman exec netbird netbird up 2>/dev/null || true
        sleep 5
        NB_IP=$(sudo podman exec netbird netbird status 2>/dev/null | grep "NetBird IP:" | awk '{print $3}' || echo "N/A")
        if [ -n "$NB_IP" ] && [ "$NB_IP" != "N/A" ]; then
            print_success "Подключен (IP: $NB_IP)"
        else
            print_warning "Не удалось подключить автоматически"
        fi
    fi
else
    echo ""
    echo -e "${NEON_BLUE}${BOLD}▸ ПОДКЛЮЧЕНИЕ NETBIRD${RESET}"
    echo ""
    echo -e "  ${MUTED_GRAY}1. Получите setup key:${RESET} ${NEON_CYAN}https://app.netbird.io  ${RESET}"
    echo -e "  ${MUTED_GRAY}2. Скопируйте ключ (формат UUID)${RESET}"
    echo ""

    read -rp "$(echo -e "  ${NEON_YELLOW}→${RESET} ${SOFT_WHITE}Setup Key (Enter — пропустить):${RESET} ")" NB_SETUP_KEY
    echo ""

    if [ -n "$NB_SETUP_KEY" ]; then
        sudo rm -rf /var/lib/netbird/* 2>/dev/null || true
        
        sudo sed -i "s/PLACEHOLDER_SETUP_KEY/$NB_SETUP_KEY/g" /etc/systemd/system/netbird.service
        sudo systemctl daemon-reload
        
        print_substep "Запуск NetBird..."
        sudo systemctl enable netbird.service 2>/dev/null || true
        
        if sudo systemctl start netbird.service 2>/dev/null; then
            sleep 8
            # После старта делаем netbird up
            print_substep "Активация соединения..."
            sudo podman exec netbird netbird up 2>/dev/null || true
            sleep 5
            
            if sudo systemctl is-active --quiet netbird.service 2>/dev/null; then
                NB_IP=$(sudo podman exec netbird netbird status 2>/dev/null | grep "NetBird IP:" | awk '{print $3}' || echo "N/A")
                if [ -n "$NB_IP" ] && [ "$NB_IP" != "N/A" ]; then
                    print_success "Подключен (IP: $NB_IP)"
                else
                    print_warning "Сервис запущен, но IP не получен. Проверьте: infra netbird-status"
                fi
            else
                print_warning "Запускается... (проверьте: infra netbird-status)"
            fi
        else
            print_warning "Не запустился (см. логи: sudo journalctl -u netbird -n 30)"
        fi
    else
        print_info "Настроен, но не запущен. Введите ключ позже:"
        echo -e "  ${DIM_GRAY}sudo sed -i 's/PLACEHOLDER_SETUP_KEY/ВАШ_КЛЮЧ/g' /etc/systemd/system/netbird.service${RESET}"
        echo -e "  ${DIM_GRAY}sudo systemctl daemon-reload && sudo systemctl start netbird${RESET}"
        echo -e "  ${DIM_GRAY}Затем: sudo podman exec netbird netbird up${RESET}"
    fi
fi

# =============== CRON ===============
print_step "Настройка cron"

CRON_NEEDS_UPDATE=0
if ! crontab -l 2>/dev/null | grep -q "healthcheck.sh" || \
   ! crontab -l 2>/dev/null | grep -q "infra backup"; then
    CRON_NEEDS_UPDATE=1
fi

if [ $CRON_NEEDS_UPDATE -eq 1 ]; then
    (
        crontab -l 2>/dev/null | grep -v "healthcheck\|infra" || true
        echo "*/5 * * * * $BIN_DIR/healthcheck.sh >> $INFRA_DIR/logs/cron.log 2>&1"
        echo "0 4 * * 0 $BIN_DIR/infra backup >> $INFRA_DIR/logs/backup.log 2>&1"
    ) | crontab - 2>/dev/null || true
    print_success "Cron настроен (healthcheck каждые 5 мин, бэкап по воскресеньям в 4:00)"
else
    print_info "Cron уже настроен"
fi

# =============== ИТОГ ===============
print_header "ГОТОВО"

typewrite "Конфигурация завершена!" "$NEON_GREEN" 0.03

echo ""
echo -e "${NEON_CYAN}${BOLD}▸ ДОСТУП К СЕРВИСАМ:${RESET}"
echo -e "  ${NEON_GREEN}●${RESET} Gitea      ${NEON_CYAN}http://$SERVER_IP:3000${RESET}"
echo -e "  ${NEON_GREEN}●${RESET} TorrServer ${NEON_CYAN}http://$SERVER_IP:8090${RESET}"
echo -e "  ${NEON_YELLOW}→${RESET} SSH Git    ${SOFT_WHITE}ssh://git@$SERVER_IP:2222${RESET}"

echo ""
echo -e "${NEON_BLUE}${BOLD}▸ УПРАВЛЕНИЕ:${RESET}"
echo -e "  ${DIM_GRAY}infra status${RESET}     ${MUTED_GRAY}- статус всех сервисов${RESET}"
echo -e "  ${DIM_GRAY}infra monitor${RESET}    ${MUTED_GRAY}- проверка портов${RESET}"
echo -e "  ${DIM_GRAY}infra logs gitea${RESET} ${MUTED_GRAY}- логи Gitea${RESET}"

echo ""
echo -e "${NEON_PURPLE}${BOLD}▸ БЭКАПЫ (Restic):${RESET}"
echo -e "  ${DIM_GRAY}infra backup${RESET}     ${MUTED_GRAY}- создать бэкап${RESET}"
echo -e "  ${DIM_GRAY}infra restore${RESET}    ${MUTED_GRAY}- восстановить${RESET}"
echo -e "  ${DIM_GRAY}infra snapshots${RESET}  ${MUTED_GRAY}- список снапшотов${RESET}"

echo ""
echo -e "${NEON_YELLOW}⚡ ВАЖНО:${RESET}"
echo -e "  ${MUTED_GRAY}• Пароль Restic сохранён в:${RESET} ${NEON_CYAN}$RESTIC_PASSWORD_FILE${RESET}"
echo -e "  ${NEON_RED}  Без этого пароля данные невозможно восстановить!${RESET}"
echo -e "  ${MUTED_GRAY}• Для облачных бэкапов настройте:${RESET} ${NEON_CYAN}$RESTIC_ENV_FILE${RESET}"

if [ $RUNNER_EXISTS -eq 0 ]; then
    echo ""
    echo -e "${NEON_PURPLE}▸ RUNNER:${RESET}"
    echo -e "  ${MUTED_GRAY}Для создания runner перейдите в Gitea:${RESET}"
    echo -e "  ${NEON_CYAN}http://$SERVER_IP:3000/admin/actions/runners${RESET}"
    echo -e "  ${MUTED_GRAY}Или запустите скрипт заново${RESET}"
fi

echo ""
typewrite "Выполните: source ~/.bashrc" "$NEON_CYAN" 0.02
echo ""
