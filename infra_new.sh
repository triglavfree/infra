#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v11.0.1 (ИСПРАВЛЕННАЯ ВЕРСИЯ)
# =============================================================================

# Цвета
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 81); NEON_GREEN=$(tput setaf 84)
        NEON_YELLOW=$(tput setaf 220); NEON_RED=$(tput setaf 203)
        NEON_PURPLE=$(tput setaf 141); NEON_BLUE=$(tput setaf 75)
        SOFT_WHITE=$(tput setaf 252); MUTED_GRAY=$(tput setaf 245)
        DIM_GRAY=$(tput setaf 240); BOLD=$(tput bold); RESET=$(tput sgr0)
    else
        NEON_CYAN=$(tput setaf 6); NEON_GREEN=$(tput setaf 2)
        NEON_YELLOW=$(tput setaf 3); NEON_RED=$(tput setaf 1)
        NEON_PURPLE=$(tput setaf 5); NEON_BLUE=$(tput setaf 4)
        SOFT_WHITE=$(tput setaf 7); MUTED_GRAY=$(tput setaf 8)
        DIM_GRAY=$(tput setaf 8); BOLD=$(tput bold); RESET=$(tput sgr0)
    fi
else
    NEON_CYAN=""; NEON_GREEN=""; NEON_YELLOW=""; NEON_RED=""
    NEON_PURPLE=""; NEON_BLUE=""; SOFT_WHITE=""; MUTED_GRAY=""
    DIM_GRAY=""; BOLD=""; RESET=""
fi

CURRENT_USER="${SUDO_USER:-$(whoami)}"
CURRENT_UID=$(id -u "$CURRENT_USER")
CURRENT_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"
SERVER_IP=$(hostname -I | awk '{print $1}')

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
print_error() { echo -e "  ${NEON_RED}✗${RESET} ${BOLD}$1${RESET}" >&2; }
print_info() { echo -e "  ${NEON_BLUE}ℹ${RESET} ${MUTED_GRAY}$1${RESET}"; }
print_url() { echo -e "  ${NEON_CYAN}➜${RESET} ${BOLD}${NEON_CYAN}$1${RESET}"; }

# Проверка прав
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

print_header "INFRASTRUCTURE v11.0.1 (ИСПРАВЛЕННАЯ)"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== ДИРЕКТОРИИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"
QUADLET_USER_DIR="$CURRENT_HOME/.config/containers/systemd"
QUADLET_SYSTEM_DIR="/etc/containers/systemd"

for dir in "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR" \
           "$BACKUP_DIR/cache" "$BACKUP_DIR/snapshots" \
           "$VOLUMES_DIR"/{gitea,torrserver,homepage/config} \
           "$QUADLET_USER_DIR"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$CURRENT_USER:$CURRENT_USER" "$dir"
        chmod 755 "$dir"
    fi
done

sudo mkdir -p "$QUADLET_SYSTEM_DIR" \
            /var/lib/{gitea-runner,netbird,rest-server,vaultwarden,backrest}/{data,config,cache} 2>/dev/null

print_success "Директории созданы"

# =============== BOOTSTRAP ===============
print_step "Подготовка системы"

if [ ! -f "$INFRA_DIR/.bootstrap_done" ]; then
    print_info "Настройка системы..."

    RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    SWAP_MB=$((RAM_MB * 2))
    [ $SWAP_MB -gt 8192 ] && SWAP_MB=8192

    sudo bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get upgrade -y -qq >/dev/null 2>&1 || true
        apt-get install -y -qq uidmap slirp4netns fuse-overlayfs curl openssl ufw fail2ban apache2-utils argon2 >/dev/null 2>&1 || true

        # Swap
        if [ ! -f /swapfile ] && [ \$(free | grep -c Swap) -eq 0 ] || [ \$(free | awk '/^Swap:/ {print \$2}') -eq 0 ]; then
            fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_MB} 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            sysctl vm.swappiness=10 >/dev/null 2>&1
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi

        # BBR
        if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
        fi

        # subuid/subgid
        if ! grep -q '$CURRENT_USER:' /etc/subuid 2>/dev/null; then
            usermod --add-subuids 100000-165535 --add-subgids 100000-165535 '$CURRENT_USER' 2>/dev/null || true
        fi

        # UFW (ВСЕ ПОРТЫ СРАЗУ)
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow 22/tcp comment 'SSH'
        ufw allow 3000/tcp comment 'Gitea HTTP'
        ufw allow 3001/tcp comment 'Homepage'
        ufw allow 2222/tcp comment 'Gitea SSH'
        ufw allow 8090/tcp comment 'TorrServer'
        ufw allow 8080/tcp comment 'Vaultwarden'
        ufw allow 9898/tcp comment 'Backrest'
        ufw allow 8000/tcp comment 'Restic REST'
        ufw allow 51820/udp comment 'WireGuard/NetBird'
        ufw --force enable >/dev/null 2>&1

        # fail2ban
        cat > /etc/fail2ban/jail.local <<'EOFAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOFAIL
        systemctl restart fail2ban >/dev/null 2>&1 || true
        systemctl enable fail2ban >/dev/null 2>&1 || true
    "

    sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true
    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена"
else
    print_info "Bootstrap уже выполнен"
fi

# =============== CLI ===============
print_step "Установка CLI"

cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BACKUP_DIR="$INFRA_DIR/backups"

# Цвета (сокращённо для CLI)
NEON_CYAN="\e[36m"; NEON_GREEN="\e[32m"; NEON_YELLOW="\e[33m"
NEON_RED="\e[31m"; NEON_PURPLE="\e[35m"; NEON_BLUE="\e[34m"
SOFT_WHITE="\e[97m"; MUTED_GRAY="\e[90m"; DIM_GRAY="\e[2m"
BOLD="\e[1m"; RESET="\e[0m"

ICON_OK="${NEON_GREEN}●${RESET}"
ICON_FAIL="${NEON_RED}●${RESET}"
ICON_WARN="${NEON_YELLOW}●${RESET}"
ICON_INFO="${NEON_BLUE}●${RESET}"
ICON_ARROW="▸"

format_uptime() { local d=$1; [ $d -lt 60 ] && echo "${d}s" || [ $d -lt 3600 ] && echo "$((d/60))m" || echo "$((d/3600))h$(((d%3600)/60))m"; }

get_container_status() {
    local name=$1 user=$2
    local runtime=""; [ "$user" = "root" ] && runtime="sudo podman" || runtime="podman"
    local container_name="$name"; [ "$user" != "root" ] && container_name="systemd-$name"
    
    if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^$container_name$"; then
        local start=$($runtime inspect --format='{{.State.StartedAt}}' "$container_name" 2>/dev/null)
        local uptime=""
        if [ -n "$start" ] && [ "$start" != "0001-01-01T00:00:00Z" ]; then
            local diff=$(($(date +%s) - $(date -d "$start" +%s 2>/dev/null || echo 0)))
            uptime=$(format_uptime $diff)
        fi
        echo -e "${ICON_OK} ${NEON_GREEN}running${RESET} ${DIM_GRAY}(${uptime})${RESET}"
    elif $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^$container_name$"; then
        echo -e "${ICON_FAIL} ${NEON_RED}stopped${RESET}"
    else
        echo -e "${DIM_GRAY}● not created${RESET}"
    fi
}

get_service_status() {
    local name=$1 user=$2
    if [ "$user" = "root" ]; then
        systemctl is-active --quiet "$name" 2>/dev/null && echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}" || echo -e "${DIM_GRAY}● inactive${RESET}"
    else
        systemctl --user is-active --quiet "$name" 2>/dev/null && echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}" || echo -e "${DIM_GRAY}● inactive${RESET}"
    fi
}

status_cmd() {
    clear
    echo -e "${NEON_CYAN}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${NEON_CYAN}║${RESET} ${BOLD}INFRA STATUS v11.0.1${RESET}"
    echo -e "${NEON_CYAN}╚══════════════════════════════════════════════════╝${RESET}"
    local ip=$(hostname -I | awk '{print $1}')

    echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}Rootless Services (User: $USER)${RESET}"
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Gitea" "$(get_service_status gitea user) $(get_container_status gitea user)"
    podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-gitea$" && echo "                ${MUTED_GRAY}→ http://${ip}:3000${RESET}"
    
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "TorrServer" "$(get_service_status torrserver user) $(get_container_status torrserver user)"
    podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-torrserver$" && echo "                ${MUTED_GRAY}→ http://${ip}:8090${RESET}"
    
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Homepage" "$(get_service_status homepage user) $(get_container_status homepage user)"
    podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-homepage$" && echo "                ${MUTED_GRAY}→ http://${ip}:3001${RESET}"

    echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}Rootful Services (System)${RESET}"
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Gitea Runner" "$(get_service_status gitea-runner root) $(get_container_status gitea-runner root)"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "NetBird VPN" "$(get_service_status netbird root) $(get_container_status netbird root)"

    echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}Backup & Security (System)${RESET}"
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Restic Server" "$(get_service_status rest-server root) $(get_container_status rest-server root)"
    sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^rest-server$" && echo "                ${MUTED_GRAY}→ http://${ip}:8000 (basic auth)${RESET}"
    
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Vaultwarden" "$(get_service_status vaultwarden root) $(get_container_status vaultwarden root)"
    sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^vaultwarden$" && echo "                ${MUTED_GRAY}→ http://${ip}:8080/admin${RESET}"
    
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "Backrest" "$(get_service_status backrest root) $(get_container_status backrest root)"
    sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^backrest$" && echo "                ${MUTED_GRAY}→ http://${ip}:9898${RESET}"

    echo -e "\n${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    echo -e "${MUTED_GRAY}Commands: ${NEON_CYAN}status${RESET}|${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}"
}

case "${1:-status}" in
    status) status_cmd ;;
    logs) 
        case "$2" in
            netbird|gitea-runner|rest-server|vaultwarden|backrest) sudo journalctl -u "$2" -f ;;
            gitea|torrserver|homepage) journalctl --user -u "$2" -f ;;
            *) echo "Usage: infra logs <service>"; exit 1 ;;
        esac
        ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver homepage 2>/dev/null
        sudo systemctl stop gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
        echo -e "  ${ICON_OK} Services stopped"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver homepage 2>/dev/null
        sudo systemctl start gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
        echo -e "  ${ICON_OK} Services started"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        case "$2" in
            netbird|gitea-runner|rest-server|vaultwarden|backrest) sudo systemctl restart "$2" ;;
            gitea|torrserver|homepage) systemctl --user restart "$2" ;;
            *) echo "Unknown service: $2"; exit 1 ;;
        esac
        echo -e "  ${ICON_OK} $2 restarted"
        ;;
    clear)
        echo -e "${NEON_RED}▸ ПОЛНОЕ УДАЛЕНИЕ${RESET}"
        read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
        [ "$CONFIRM" = "yes" ] || exit 0
        systemctl --user stop gitea torrserver homepage 2>/dev/null
        sudo systemctl stop gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
        podman rm -f systemd-gitea systemd-torrserver systemd-homepage 2>/dev/null
        sudo podman rm -f gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
        rm -f ~/.config/containers/systemd/{gitea,torrserver,homepage}.container
        sudo rm -f /etc/containers/systemd/{gitea-runner,netbird,rest-server,vaultwarden,backrest}.container
        systemctl --user daemon-reload
        sudo systemctl daemon-reload
        read -rp "  Удалить все данные? [y/N]: " DEL_DATA
        [[ "$DEL_DATA" =~ ^[Yy]$ ]] && sudo rm -rf "$INFRA_DIR" /var/lib/gitea-runner /var/lib/netbird /var/lib/rest-server /var/lib/vaultwarden /var/lib/backrest
        sudo rm -f /usr/local/bin/infra
        echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
        echo -e "${NEON_GREEN}${BOLD}║        ИНФРАСТРУКТУРА ПОЛНОСТЬЮ УДАЛЕНА        ║${RESET}"
        echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
        ;;
    *) echo "Использование: infra {status|start|stop|restart|logs|clear}" ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true
print_success "CLI установлен"

# =============== TORRSERVER ===============
print_step "Создание TorrServer"
cat > "$QUADLET_USER_DIR/torrserver.container" <<EOF
[Unit]
Description=TorrServer Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=ghcr.io/yourok/torrserver:latest
Volume=$CURRENT_HOME/infra/volumes/torrserver:/app/z:Z
PublishPort=8090:8090

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$QUADLET_USER_DIR/torrserver.container"
systemctl --user daemon-reload
systemctl --user start torrserver.service
print_success "TorrServer запущен"
print_url "http://${SERVER_IP}:8090/"

# =============== GITEA ===============
print_step "Создание Gitea"
cat > "$QUADLET_USER_DIR/gitea.container" <<EOF
[Unit]
Description=Gitea Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=docker.io/gitea/gitea:latest
Volume=$CURRENT_HOME/infra/volumes/gitea:/data:Z
PublishPort=3000:3000
PublishPort=2222:22
Environment=GITEA__server__ROOT_URL=http://$SERVER_IP:3000/
Environment=GITEA__actions__ENABLED=true

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$QUADLET_USER_DIR/gitea.container"
systemctl --user daemon-reload
systemctl --user start gitea.service
print_success "Gitea запущена"
print_url "http://${SERVER_IP}:3000/"

# Ждём Gitea
print_info "Ожидание 30 секунд для инициализации Gitea..."
sleep 30

# =============== GITEA RUNNER ===============
print_step "Настройка Gitea Runner"
if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    read -rp "  Registration Token (из Gitea Admin > Actions > Runners): " RUNNER_TOKEN
    if [ -n "$RUNNER_TOKEN" ]; then
        sudo mkdir -p /var/lib/gitea-runner
        sudo chmod 755 /var/lib/gitea-runner
        sudo tee "$QUADLET_SYSTEM_DIR/gitea-runner.container" > /dev/null <<EOF
[Unit]
Description=Gitea Runner
After=network-online.target gitea.service
Wants=podman-auto-update.service

[Container]
Image=docker.io/gitea/act_runner:nightly
ContainerName=gitea-runner
Volume=/var/run/docker.sock:/var/run/docker.sock:Z
Volume=/var/lib/gitea-runner:/data:Z
Environment=GITEA_INSTANCE_URL=http://$SERVER_IP:3000
Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN
Environment=GITEA_RUNNER_NAME=runner-$(hostname | cut -d. -f1)
AddCapability=SYS_ADMIN
AddDevice=/dev/fuse

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF
        sudo chmod 644 "$QUADLET_SYSTEM_DIR/gitea-runner.container"
        sudo systemctl daemon-reload
        sudo systemctl start gitea-runner.service
        print_success "Runner запущен"
    fi
else
    print_warning "Gitea API не доступен, Runner можно настроить позже"
fi

# =============== NETBIRD ===============
print_step "Настройка NetBird"
read -rp "  NetBird Setup Key (Enter - пропустить): " NB_KEY
if [ -n "$NB_KEY" ]; then
    sudo mkdir -p /var/lib/netbird
    sudo chmod 755 /var/lib/netbird
    sudo tee "$QUADLET_SYSTEM_DIR/netbird.container" > /dev/null <<EOF
[Unit]
Description=NetBird VPN Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/netbirdio/netbird:latest
ContainerName=netbird
Network=host
AddDevice=/dev/net/tun
Volume=/var/lib/netbird:/etc/netbird:Z
Environment=NB_SETUP_KEY=$NB_KEY
Environment=NB_MANAGEMENT_URL=https://api.netbird.io:443
SecurityLabelDisable=true
AddCapability=ALL

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 "$QUADLET_SYSTEM_DIR/netbird.container"
    sudo systemctl daemon-reload
    sudo systemctl start netbird.service
    print_success "NetBird запущен"
fi

# =============== REST-SERVER ===============
print_step "Настройка Restic REST сервера"
if [ ! -f "/var/lib/rest-server/.htpasswd" ]; then
    sudo mkdir -p /var/lib/rest-server
    REST_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    echo "$REST_PASS" | sudo tee /var/lib/rest-server/.restic_pass > /dev/null
    sudo htpasswd -B -b -c /var/lib/rest-server/.htpasswd restic "$REST_PASS" >/dev/null 2>&1
    sudo chmod 600 /var/lib/rest-server/.htpasswd /var/lib/rest-server/.restic_pass
    print_success "Создан пользователь restic для rest-server"
    print_info "Пароль сохранен в /var/lib/rest-server/.restic_pass"
fi

sudo tee "$QUADLET_SYSTEM_DIR/rest-server.container" > /dev/null <<EOF
[Unit]
Description=Restic REST Server
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/restic/rest-server:latest
ContainerName=rest-server
Volume=/var/lib/rest-server:/data:Z
PublishPort=8000:8000
Exec=rest-server --path /data --htpasswd-file /data/.htpasswd --append-only --listen :8000

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/rest-server.container"
sudo systemctl daemon-reload
sudo systemctl start rest-server.service
print_success "Restic REST сервер запущен на порту 8000"

# =============== VAULTWARDEN ===============
print_step "Настройка Vaultwarden"
sudo mkdir -p /var/lib/vaultwarden /etc/vaultwarden/secrets

# Генерируем и хэшируем admin токен
echo ""
print_info "Создание admin токена для Vaultwarden"
print_info "Придумайте пароль для входа в админ-панель (запомните его!)"
read -rsp "  Введите пароль: " VAULT_PASS
echo ""

# Генерируем хэш через argon2
SALT=$(openssl rand -base64 32)
VAULT_HASH=$(echo -n "$VAULT_PASS" | argon2 "$SALT" -e -id -k 65540 -t 3 -p 4)

# Сохраняем хэш
echo "VAULTWARDEN_ADMIN_TOKEN=$VAULT_HASH" | sudo tee /etc/vaultwarden/secrets/admin_token.env > /dev/null
sudo chmod 600 /etc/vaultwarden/secrets/admin_token.env

# Создаём конфиг
sudo tee "$QUADLET_SYSTEM_DIR/vaultwarden.container" > /dev/null <<EOF
[Unit]
Description=Vaultwarden Password Manager
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/vaultwarden/server:latest
ContainerName=vaultwarden
Volume=/var/lib/vaultwarden:/data:Z
PublishPort=8080:80
Environment=DOMAIN=http://$SERVER_IP:8080
Environment=WEBSOCKET_ENABLED=true
Environment=SIGNUPS_ALLOWED=false
Environment=ADMIN_TOKEN=$VAULT_HASH

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/vaultwarden.container"
sudo systemctl daemon-reload
sudo systemctl start vaultwarden.service
print_success "Vaultwarden запущен на порту 8080"
print_info "Страница администратора: http://$SERVER_IP:8080/admin"
print_info "Вход по паролю: $VAULT_PASS (запомните его!)"

# =============== BACKREST ===============
print_step "Настройка Backrest"
sudo mkdir -p /var/lib/backrest/{data,config,cache}
sudo chown -R 1000:1000 /var/lib/backrest 2>/dev/null

if [ -f "/var/lib/rest-server/.restic_pass" ]; then
    RESTIC_PASS=$(sudo cat /var/lib/rest-server/.restic_pass)
    sudo tee /var/lib/backrest/config/restic.env > /dev/null <<EOF
RESTIC_REPOSITORY=rest:http://restic:$RESTIC_PASS@localhost:8000/windows-backup
RESTIC_PASSWORD=$RESTIC_PASS
EOF
    sudo chmod 600 /var/lib/backrest/config/restic.env
fi

sudo tee "$QUADLET_SYSTEM_DIR/backrest.container" > /dev/null <<EOF
[Unit]
Description=Backrest WebUI for Restic
After=network-online.target rest-server.service
Wants=podman-auto-update.service

[Container]
Image=ghcr.io/garethgeorge/backrest:latest
ContainerName=backrest
Volume=/var/lib/backrest/data:/data:Z
Volume=/var/lib/backrest/config:/config:Z
Volume=/var/lib/backrest/cache:/cache:Z
Volume=$VOLUMES_DIR:/userdata:ro,Z
Environment=BACKREST_DATA=/data
Environment=BACKREST_CONFIG=/config/config.json
Environment=XDG_CACHE_HOME=/cache
Environment=BACKREST_PORT=:9898
PublishPort=9898:9898

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/backrest.container"
sudo systemctl daemon-reload
sudo systemctl start backrest.service
print_success "Backrest запущен на порту 9898"
print_url "http://${SERVER_IP}:9898/"

# =============== HOMEPAGE ===============
print_step "Настройка Homepage"
HOMEPAGE_CONFIG_DIR="$VOLUMES_DIR/homepage/config"
mkdir -p "$HOMEPAGE_CONFIG_DIR"

cat > "$HOMEPAGE_CONFIG_DIR/settings.yaml" <<EOF
---
title: "Infrastructure Dashboard"
theme: dark
color: slate
headerStyle: clean
hideVersion: false
useEqualHeights: true
statusStyle: "dot"
statusPosition: "bottom"
search:
  provider: duckduckgo
  target: _blank
EOF

cat > "$HOMEPAGE_CONFIG_DIR/services.yaml" <<EOF
---
# Services will be auto-discovered via Podman socket
EOF

cat > "$HOMEPAGE_CONFIG_DIR/bookmarks.yaml" <<EOF
---
Infrastructure:
  - Gitea:
      - abbr: "GT"
        href: "http://$SERVER_IP:3000"
        description: "Git Repository"
  - TorrServer:
      - abbr: "TS"
        href: "http://$SERVER_IP:8090"
        description: "Torrent Streaming"
  - Backrest:
      - abbr: "BR"
        href: "http://$SERVER_IP:9898"
        description: "Backup Management"
  - Vaultwarden:
      - abbr: "VW"
        href: "http://$SERVER_IP:8080/admin"
        description: "Password Manager"
EOF

chown -R "$CURRENT_USER:$CURRENT_USER" "$HOMEPAGE_CONFIG_DIR"

cat > "$QUADLET_USER_DIR/homepage.container" <<EOF
[Unit]
Description=Homepage Dashboard
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=ghcr.io/gethomepage/homepage:latest
Volume=$HOMEPAGE_CONFIG_DIR:/app/config:Z
PublishPort=3001:3000
Environment=PUID=$CURRENT_UID
Environment=PGID=$CURRENT_UID
Environment=HOMEPAGE_ALLOWED_HOSTS=$SERVER_IP:3001,localhost:3001,127.0.0.1:3001,$(hostname):3001

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$QUADLET_USER_DIR/homepage.container"
systemctl --user daemon-reload
systemctl --user start homepage.service
print_success "Homepage запущен на порту 3001"
print_url "http://${SERVER_IP}:3001/"

# =============== ИТОГ ===============
print_header "ГОТОВО v11.0.1"

echo -e "${NEON_GREEN}●${RESET} Homepage:     ${NEON_CYAN}http://$SERVER_IP:3001/${RESET}"
echo -e "${NEON_GREEN}●${RESET} Gitea:        ${NEON_CYAN}http://$SERVER_IP:3000/${RESET}"
echo -e "${NEON_GREEN}●${RESET} TorrServer:   ${NEON_CYAN}http://$SERVER_IP:8090/${RESET}"
echo -e "${NEON_GREEN}●${RESET} Vaultwarden:  ${NEON_CYAN}http://$SERVER_IP:8080/admin${RESET}"
echo -e "                 ${MUTED_GRAY}Пароль: вы его ввели при установке${RESET}"
echo -e "${NEON_GREEN}●${RESET} Backrest:     ${NEON_CYAN}http://$SERVER_IP:9898/${RESET}"
echo -e "${NEON_GREEN}●${RESET} Restic REST:  ${NEON_CYAN}http://$SERVER_IP:8000/${RESET} ${MUTED_GRAY}(user: restic)${RESET}"
echo ""
echo -e "Управление: ${NEON_CYAN}infra status${RESET}"
echo -e "Логи:       ${NEON_CYAN}infra logs <service>${RESET}"

# =============== САМОУДАЛЕНИЕ ===============
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi
