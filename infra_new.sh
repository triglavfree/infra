#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v12.0.0 (ФИНАЛЬНАЯ QUADLET EDITION)
# =============================================================================
# Полноценная домашняя инфраструктура на Ubuntu Server 24.04
# ВСЕ СЕРВИСЫ УПРАВЛЯЮТСЯ ЧЕРЕЗ QUADLET
#
# ✅ KeeWeb — менеджер паролей (совместим с KeePass)
# ✅ Faucet — MCP-сервер + GUI для API-ключей (AI-агенты)
# ✅ Backrest — управление бэкапами
# ✅ Restic REST — хранилище бэкапов
# ✅ Gitea + Runner — Git с CI/CD
# ✅ TorrServer — торрент-стриминг
# ✅ Homepage — красивый дашборд
# ✅ Traefik — reverse proxy с дашбордом и авто-HTTPS
# ✅ NetBird VPN — доступ из любой точки
# ✅ mkcert — локальный HTTPS для .lab доменов
# =============================================================================

# =============== 1. ЦВЕТА ===============
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 51); NEON_GREEN=$(tput setaf 48)
        NEON_YELLOW=$(tput setaf 220); NEON_RED=$(tput setaf 196)
        NEON_PURPLE=$(tput setaf 135); NEON_BLUE=$(tput setaf 39)
        SOFT_WHITE=$(tput setaf 255); MUTED_GRAY=$(tput setaf 245)
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

# =============== 2. ФУНКЦИИ ===============
print_header() { 
    echo ""; 
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"; 
    echo -e "${NEON_CYAN}${BOLD}  $1${RESET}"; 
    echo -e "${DIM_GRAY}─────────────────────────────────────────${RESET}"; 
    echo ""; 
}

print_step() { 
    echo ""; 
    echo -e "${NEON_CYAN}${BOLD}▸${RESET} ${SOFT_WHITE}${BOLD}$1${RESET}"; 
    echo -e "${DIM_GRAY}  $(printf '─%.0s' $(seq 1 40))${RESET}"; 
}

print_success() { echo -e "  ${NEON_GREEN}✓${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_warning() { echo -e "  ${NEON_YELLOW}⚡${RESET} ${SOFT_WHITE}$1${RESET}"; }
print_error() { echo -e "  ${NEON_RED}✗${RESET} ${BOLD}$1${RESET}" >&2; }
print_info() { echo -e "  ${NEON_BLUE}ℹ${RESET} ${MUTED_GRAY}$1${RESET}"; }
print_url() { echo -e "  ${NEON_CYAN}➜${RESET} ${BOLD}${NEON_CYAN}$1${RESET}"; }

step() {
    local msg=$1
    local cmd=$2
    local critical=${3:-false}
    echo -ne "  ${MUTED_GRAY}➜${RESET} $msg... "
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${NEON_GREEN}✓${RESET}"
        return 0
    else
        echo -e "${NEON_RED}✗${RESET}"
        if [ "$critical" = true ]; then
            print_error "Критическая ошибка. Прерывание."
            exit 1
        fi
        return 1
    fi
}

# =============== 3. ПРОВЕРКА ПРАВ ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

print_header "🚀 INFRASTRUCTURE v12.0.0 (QUADLET EDITION)"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== 4. ДИРЕКТОРИИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"
CERT_DIR="$INFRA_DIR/certs"
FAUCET_DIR="$INFRA_DIR/faucet"
TRAEFIK_DIR="$INFRA_DIR/traefik"
KEEWEB_DIR="$INFRA_DIR/keeweb"
QUADLET_USER_DIR="$CURRENT_HOME/.config/containers/systemd"
QUADLET_SYSTEM_DIR="/etc/containers/systemd"

USER_DIRS=(
    "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR"
    "$BACKUP_DIR/cache" "$BACKUP_DIR/snapshots" "$CERT_DIR"
    "$VOLUMES_DIR/gitea" "$VOLUMES_DIR/torrserver" "$VOLUMES_DIR/homepage/config"
    "$FAUCET_DIR"/{data,config}
    "$TRAEFIK_DIR"/{config,data}
    "$KEEWEB_DIR"/data
    "$QUADLET_USER_DIR"
)

SYSTEM_DIRS=(
    "$QUADLET_SYSTEM_DIR"
    "/var/lib/gitea-runner" "/var/lib/netbird" "/var/lib/rest-server"
    "/var/lib/backrest/data" "/var/lib/backrest/config" "/var/lib/backrest/cache"
)

for dir in "${USER_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$CURRENT_USER:$CURRENT_USER" "$dir"
        chmod 755 "$dir"
    fi
done

for dir in "${SYSTEM_DIRS[@]}"; do
    sudo mkdir -p "$dir"
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$dir" 2>/dev/null || true
done

print_success "Директории созданы"

# =============== 5. BOOTSTRAP ===============
print_step "Подготовка системы"

if [ ! -f "$INFRA_DIR/.bootstrap_done" ]; then
    print_info "Настройка системы (это займёт несколько минут)..."

    RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    SWAP_MB=$((RAM_MB * 2))
    [ $SWAP_MB -gt 8192 ] && SWAP_MB=8192

    sudo bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get upgrade -y -qq >/dev/null 2>&1 || true
        
        # Установка пакетов
        apt-get install -y -qq uidmap slirp4netns fuse-overlayfs curl wget \
            openssl ufw fail2ban apache2-utils argon2 jq podman podman-docker \
            >/dev/null 2>&1 || true

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

        # UFW
        sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw 2>/dev/null
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw default allow routed >/dev/null 2>&1
        
        ufw allow 22/tcp >/dev/null 2>&1      # SSH
        ufw allow 80/tcp >/dev/null 2>&1      # HTTP (Traefik)
        ufw allow 443/tcp >/dev/null 2>&1     # HTTPS (Traefik)
        ufw allow 8080/tcp >/dev/null 2>&1    # Traefik Dashboard
        ufw allow 3000/tcp >/dev/null 2>&1    # Gitea
        ufw allow 2222/tcp >/dev/null 2>&1    # Gitea SSH
        ufw allow 3001/tcp >/dev/null 2>&1    # Homepage
        ufw allow 8090/tcp >/dev/null 2>&1    # TorrServer
        ufw allow 8082/tcp >/dev/null 2>&1    # Faucet
        ufw allow 9898/tcp >/dev/null 2>&1    # Backrest
        ufw allow 8000/tcp >/dev/null 2>&1    # Restic REST
        ufw allow 51820/udp >/dev/null 2>&1   # NetBird
        
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

    # Настройка registries.conf для Podman
    sudo tee /etc/containers/registries.conf > /dev/null <<EOF
unqualified-search-registries = ["docker.io", "quay.io", "registry.fedoraproject.org"]
[[registry]]
prefix = "docker.io"
location = "docker.io"
[[registry.mirror]]
location = "mirror.gcr.io"
[[registry.mirror]]
location = "docker-mirror.rancher.io"
EOF

    # Настройка Quadlet
    if [ -f "/usr/libexec/podman/quadlet" ]; then
        if [ ! -L "/usr/lib/systemd/system-generators/podman-system-generator" ]; then
            sudo ln -sf /usr/libexec/podman/quadlet /usr/lib/systemd/system-generators/podman-system-generator
        fi
        print_success "Quadlet настроен"
    fi

    sudo systemctl enable --now podman.socket >/dev/null 2>&1 || true
    sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true

    # Включаем автообновление для Quadlet
    systemctl --user enable podman-auto-update.timer 2>/dev/null || true
    systemctl --user start podman-auto-update.timer 2>/dev/null || true
    sudo systemctl enable podman-auto-update.timer 2>/dev/null || true
    sudo systemctl start podman-auto-update.timer 2>/dev/null || true

    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена"
else
    print_info "Bootstrap уже выполнен"
fi

# =============== 6. mkcert ===============
print_step "Настройка локального HTTPS"

if ! command -v mkcert &> /dev/null; then
    step "Загрузка mkcert" "
        wget -qO /tmp/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
        chmod +x /tmp/mkcert
        sudo mv /tmp/mkcert /usr/local/bin/mkcert
    " true
fi

step "Установка локального CA" "mkcert -install" true
step "Генерация сертификатов" "
    mkcert -key-file \"$CERT_DIR/lab-key.pem\" \
           -cert-file \"$CERT_DIR/lab-cert.pem\" \
           localhost 127.0.0.1 $SERVER_IP \
           keeweb.lab keys.lab git.lab backup.lab home.lab torrent.lab traefik.lab \
           $(hostname) $(hostname).local
" true

print_success "SSL сертификаты созданы"

# =============== 7. CLI ===============
print_step "Установка CLI"

cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
SERVER_IP=$(hostname -I | awk '{print $1}')

# Цвета
NEON_CYAN="\e[38;5;51m"; NEON_GREEN="\e[38;5;48m"; NEON_YELLOW="\e[38;5;220m"
NEON_RED="\e[38;5;196m"; NEON_PURPLE="\e[38;5;135m"; NEON_BLUE="\e[38;5;39m"
SOFT_WHITE="\e[38;5;255m"; MUTED_GRAY="\e[38;5;245m"; DIM_GRAY="\e[38;5;240m"
BOLD="\e[1m"; RESET="\e[0m"

ICON_OK="${NEON_GREEN}●${RESET}"; ICON_FAIL="${NEON_RED}●${RESET}"
ICON_WARN="${NEON_YELLOW}●${RESET}"; ICON_INFO="${NEON_BLUE}●${RESET}"
ICON_ARROW="▸"

get_container_url() {
    local name=$1
    local user=$2
    local runtime="podman"
    [ "$user" = "root" ] && runtime="sudo podman"
    
    local ports=$($runtime port $name 2>/dev/null | grep -v "->" | head -1)
    if [ -n "$ports" ]; then
        local host_port=$(echo "$ports" | awk -F'->' '{print $1}' | sed 's/0.0.0.0/'"$SERVER_IP"'/')
        echo "$host_port"
    else
        echo ""
    fi
}

check_url() {
    local url=$1
    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$url" 2>/dev/null | grep -q "200\|302\|401\|403"; then
        echo -e "${NEON_GREEN}✓${RESET}"
    else
        echo -e "${NEON_RED}✗${RESET}"
    fi
}

get_status() {
    local name=$1 type=$2 user=$3
    case $type in
        service)
            # Для Quadlet имена сервисов соответствуют именам container файлов
            local service_name="$name.service"
            if [ "$user" = "root" ]; then
                systemctl is-active --quiet "$service_name" 2>/dev/null && echo "active" || echo "inactive"
            else
                systemctl --user is-active --quiet "$service_name" 2>/dev/null && echo "active" || echo "inactive"
            fi
            ;;
        container)
            local runtime="podman"
            [ "$user" = "root" ] && runtime="sudo podman"
            
            # Quadlet создаёт контейнеры с именем как в .container файле
            if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^$name$"; then
                echo "running"
            elif $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^$name$"; then
                local status=$($runtime inspect --format='{{.State.Status}}' "$name" 2>/dev/null)
                [ "$status" = "exited" ] && echo "stopped" || echo "$status"
            else
                echo "not_created"
            fi
            ;;
    esac
}

format_status() {
    case $1 in
        active|running) echo -e "${ICON_OK} ${NEON_GREEN}$1${RESET}" ;;
        inactive|stopped) echo -e "${ICON_FAIL} ${NEON_RED}$1${RESET}" ;;
        *) echo -e "${DIM_GRAY}● not created${RESET}" ;;
    esac
}

status_cmd() {
    clear
    echo -e "${NEON_CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${NEON_CYAN}║${RESET} ${BOLD}${SOFT_WHITE}INFRA STATUS v12.0.0 (QUADLET)${RESET}                     ${NEON_CYAN}║${RESET}"
    echo -e "${NEON_CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"

    declare -A services=(
        [gitea]="user"
        [torrserver]="user"
        [homepage]="user"
        [gitea-runner]="root"
        [netbird]="root"
        [traefik]="root"
        [faucet]="root"
        [rest-server]="root"
        [keeweb]="root"
        [backrest]="root"
    )

    declare -A sections=(
        ["Rootless Services (Quadlet)"]="gitea torrserver homepage"
        ["Rootful Services (Quadlet)"]="gitea-runner netbird traefik faucet keeweb"
        ["Backup & Storage"]="rest-server backrest"
    )

    for section in "Rootless Services (Quadlet)" "Rootful Services (Quadlet)" "Backup & Storage"; do
        echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$section${RESET}"
        echo -e "${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
        
        for svc in ${sections[$section]}; do
            user="${services[$svc]}"
            svc_status=$(format_status "$(get_status $svc service $user)")
            ctr_status=$(format_status "$(get_status $svc container $user)")
            
            printf "  ${DIM_GRAY}%-18s${RESET} %s %s\n" "$svc" "$svc_status" "$ctr_status"
            
            if [ "$ctr_status" != "${DIM_GRAY}● not created${RESET}" ]; then
                case "$svc" in
                    traefik)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Dashboard:${RESET} http://$SERVER_IP:8080 $(check_url "http://$SERVER_IP:8080")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://traefik.lab"
                        ;;
                    faucet)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}UI:${RESET} http://$SERVER_IP:8082 $(check_url "http://$SERVER_IP:8082")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}MCP:${RESET} http://$SERVER_IP:8082/mcp $(check_url "http://$SERVER_IP:8082/mcp")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://keys.lab"
                        ;;
                    keeweb)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}URL:${RESET} http://$SERVER_IP:8080 $(check_url "http://$SERVER_IP:8080")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://keeweb.lab"
                        ;;
                    homepage)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}URL:${RESET} http://$SERVER_IP:3001 $(check_url "http://$SERVER_IP:3001")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://home.lab"
                        ;;
                    gitea)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}URL:${RESET} http://$SERVER_IP:3000 $(check_url "http://$SERVER_IP:3000")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://git.lab"
                        ;;
                    torrserver)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}URL:${RESET} http://$SERVER_IP:8090 $(check_url "http://$SERVER_IP:8090")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://torrent.lab"
                        ;;
                    backrest)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}URL:${RESET} http://$SERVER_IP:9898 $(check_url "http://$SERVER_IP:9898")"
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}Domain:${RESET} https://backup.lab"
                        ;;
                    rest-server)
                        echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}URL:${RESET} http://$SERVER_IP:8000 $(check_url "http://$SERVER_IP:8000")"
                        ;;
                    *)
                        container_url=$(get_container_url $svc $user)
                        if [ -n "$container_url" ]; then
                            url="http://$container_url"
                            echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}${url}${RESET} $(check_url "$url")"
                        fi
                        ;;
                esac
            fi
        done
    done

    # NetBird IP
    if sudo podman ps | grep -q netbird; then
        NB_IP=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$NB_IP" ]; then
            echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}NetBird VPN${RESET}"
            echo -e "${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
            echo -e "        ${NEON_CYAN}↗${RESET} ${MUTED_GRAY}VPN IP:${RESET} $NB_IP"
        fi
    fi

    # Ресурсы
    echo -e "\n${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}Resources${RESET}"
    echo -e "${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
    printf "  ${DIM_GRAY}%-12s${RESET} ${SOFT_WHITE}%s${RESET}\n" "Disk" "$(df -h "$INFRA_DIR" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    printf "  ${DIM_GRAY}%-12s${RESET} ${SOFT_WHITE}%s${RESET}\n" "Memory" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')"
    printf "  ${DIM_GRAY}%-12s${RESET} ${SOFT_WHITE}user: %d, system: %d${RESET}\n" "Containers" "$(podman ps -q 2>/dev/null | wc -l)" "$(sudo podman ps -q 2>/dev/null | wc -l)"

    echo -e "\n${DIM_GRAY}────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${ICON_OK} running  ${ICON_FAIL} stopped  ${NEON_CYAN}↗${RESET} URL ${NEON_GREEN}✓${RESET} доступен ${NEON_RED}✗${RESET} недоступен"
    echo -e "  ${MUTED_GRAY}Commands: ${NEON_CYAN}status${RESET}|${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}|${NEON_CYAN}backup${RESET}|${NEON_CYAN}clear${RESET}"
}

backup_cmd() {
    BACKUP_DIR="$INFRA_DIR/backups/snapshots"
    mkdir -p "$BACKUP_DIR"
    backup_time=$(date +%Y%m%d-%H%M%S)
    SNAPSHOT="$BACKUP_DIR/infra-$backup_time.tar.gz"
    echo -e "${NEON_CYAN}▸ Создание бэкапа...${RESET}"
    if podman run --rm -v "$INFRA_DIR/volumes:/data:ro" -v "$BACKUP_DIR:/backup:Z" docker.io/library/alpine:latest tar -czf "/backup/$(basename $SNAPSHOT)" -C /data . 2>/dev/null; then
        sudo chown $USER:$USER "$SNAPSHOT" 2>/dev/null
        size=$(du -h "$SNAPSHOT" 2>/dev/null | cut -f1)
        echo -e "  ${ICON_OK} Бэкап создан: $(basename $SNAPSHOT) ($size)"
    else
        echo -e "  ${ICON_WARN} Ошибка создания бэкапа"
    fi
}

clear_cmd() {
    echo -e "${NEON_RED}▸ ПОЛНОЕ УДАЛЕНИЕ ИНФРАСТРУКТУРЫ${RESET}"
    read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
    [ "$CONFIRM" = "yes" ] || exit 0

    echo -e "  ${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
    systemctl --user stop gitea torrserver homepage 2>/dev/null
    sudo systemctl stop gitea-runner netbird rest-server keeweb traefik backrest faucet 2>/dev/null

    echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
    sudo podman rm -f gitea-runner netbird rest-server keeweb traefik backrest faucet 2>/dev/null
    podman rm -f gitea torrserver homepage 2>/dev/null

    echo -e "  ${NEON_YELLOW}▸ Удаление Quadlet файлов...${RESET}"
    rm -f "$HOME/.config/containers/systemd"/{gitea,torrserver,homepage}.container
    sudo rm -f /etc/containers/systemd/{gitea-runner,netbird,rest-server,keeweb,traefik,backrest,faucet}.container

    sudo systemctl daemon-reload
    systemctl --user daemon-reload

    read -rp "  Удалить все данные? [y/N]: " DEL_DATA
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        echo -e "  ${NEON_YELLOW}▸ Удаление данных...${RESET}"
        sudo rm -rf "$HOME/infra" /var/lib/gitea-runner /var/lib/netbird /var/lib/rest-server /var/lib/backrest
    fi

    sudo rm -f /usr/local/bin/infra
    rm -f "$HOME/infra/bin/infra"
    echo -e "\n${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
    echo -e "${NEON_GREEN}${BOLD}║        ИНФРАСТРУКТУРА ПОЛНОСТЬЮ УДАЛЕНА        ║${RESET}"
    echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
}

case "${1:-status}" in
    status) status_cmd ;;
    logs) 
        case "$2" in
            netbird|gitea-runner|rest-server|keeweb|traefik|backrest|faucet) sudo journalctl -u "$2" -f ;;
            gitea|torrserver|homepage) journalctl --user -u "$2" -f ;;
            *) echo "Usage: infra logs <service>"; exit 1 ;;
        esac
        ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver homepage 2>/dev/null
        sudo systemctl stop gitea-runner netbird rest-server keeweb traefik backrest faucet 2>/dev/null
        echo -e "  ${ICON_OK} Services stopped"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        sudo systemctl start traefik 2>/dev/null
        sleep 5
        sudo systemctl start gitea-runner netbird rest-server keeweb backrest faucet 2>/dev/null
        systemctl --user start gitea torrserver homepage 2>/dev/null
        echo -e "  ${ICON_OK} Services started"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        case "$2" in
            netbird|gitea-runner|rest-server|keeweb|traefik|backrest|faucet) sudo systemctl restart "$2" ;;
            gitea|torrserver|homepage) systemctl --user restart "$2" ;;
            *) echo "Unknown service: $2"; exit 1 ;;
        esac
        echo -e "  ${ICON_OK} $2 restarted"
        ;;
    backup) backup_cmd ;;
    clear) clear_cmd ;;
    *) echo "Использование: infra {status|start|stop|restart|logs|backup|clear}" ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true
print_success "CLI установлен"

# =============== 8. TORRSERVER (rootless QUADLET) ===============
print_step "Создание TorrServer (Quadlet)"

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

chown $CURRENT_USER:$CURRENT_USER "$QUADLET_USER_DIR/torrserver.container"
systemctl --user daemon-reload
systemctl --user enable --now torrserver.service
sleep 3
print_success "TorrServer запущен через Quadlet"
print_url "http://$SERVER_IP:8090"

# =============== 9. GITEA (rootless QUADLET) ===============
print_step "Создание Gitea (Quadlet с лейблами Traefik)"

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
Environment=GITEA__server__ROOT_URL=https://git.lab
Environment=GITEA__server__HTTP_PORT=3000
Environment=GITEA__server__DOMAIN=git.lab
Environment=GITEA__server__SSH_DOMAIN=git.lab
Environment=GITEA__actions__ENABLED=true
# Traefik labels
Label=traefik.enable=true
Label=traefik.http.routers.gitea-http.rule=Host(\`git.lab\`)
Label=traefik.http.routers.gitea-http.entrypoints=web
Label=traefik.http.routers.gitea-http.middlewares=https-redirect@file
Label=traefik.http.routers.gitea-https.rule=Host(\`git.lab\`)
Label=traefik.http.routers.gitea-https.entrypoints=websecure
Label=traefik.http.routers.gitea-https.tls=true
Label=traefik.http.services.gitea.loadbalancer.server.port=3000

[Service]
Restart=always
TimeoutStopSec=60
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown $CURRENT_USER:$CURRENT_USER "$QUADLET_USER_DIR/gitea.container"
systemctl --user daemon-reload
systemctl --user enable --now gitea.service
print_success "Gitea запущена через Quadlet"
print_url "https://git.lab (после настройки Traefik и hosts)"

# =============== 10. GITEA RUNNER (rootful QUADLET) ===============
print_step "Настройка Gitea Runner"

print_info "Ожидание 60 секунд для инициализации Gitea..."
sleep 60

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    echo ""
    print_info "🔑 Для регистрации Runner'а нужен токен"
    print_info "1. Открой в браузере: ${NEON_CYAN}http://$SERVER_IP:3000/-/admin/actions/runners${RESET}"
    print_info "2. Нажми 'Create new runner'"
    print_info "3. Скопируй токен"
    echo ""
    
    read -rp "  Registration Token: " RUNNER_TOKEN
    
    if [ -n "$RUNNER_TOKEN" ]; then
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
TimeoutStopSec=60
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

        sudo chmod 644 "$QUADLET_SYSTEM_DIR/gitea-runner.container"
        sudo systemctl daemon-reload
        sudo systemctl enable --now gitea-runner.service
        print_success "Gitea Runner запущен через Quadlet"
    fi
else
    print_warning "Gitea API не доступен. Runner можно настроить позже"
fi

# =============== 11. NETBIRD (rootful QUADLET) ===============
print_step "Настройка NetBird"
echo ""
print_info "🌐 Для подключения к VPN нужен Setup Key"
print_info "1. Зарегистрируйся на https://app.netbird.io/"
print_info "2. Создай Setup Key в разделе Setup Keys"
print_info "3. Введи его ниже (или Enter чтобы пропустить)"
echo ""
read -rp "  NetBird Setup Key: " NB_KEY

if [ -n "$NB_KEY" ]; then
    sudo mkdir -p /var/lib/netbird
    
    sudo tee "$QUADLET_SYSTEM_DIR/netbird.container" > /dev/null <<EOF
[Unit]
Description=NetBird VPN Container
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/netbirdio/netbird:0.66.0
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
    sudo systemctl enable --now netbird.service
    print_success "NetBird запущен через Quadlet"
else
    print_info "NetBird пропущен"
fi

# =============== 12. RESTIC REST SERVER (rootful QUADLET) ===============
print_step "Настройка Restic REST сервера"

if [ ! -f "/var/lib/rest-server/.htpasswd" ]; then
    REST_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    echo "$REST_PASS" | sudo tee /var/lib/rest-server/.restic_pass > /dev/null
    sudo htpasswd -B -b -c /var/lib/rest-server/.htpasswd restic "$REST_PASS" >/dev/null 2>&1
    sudo chmod 600 /var/lib/rest-server/.htpasswd /var/lib/rest-server/.restic_pass
    print_info "Пароль restic: $REST_PASS"
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
sudo systemctl enable --now rest-server.service
print_success "Restic REST сервер запущен через Quadlet"
print_url "http://$SERVER_IP:8000"

# =============== 13. BACKREST (rootful QUADLET) ===============
print_step "Настройка Backrest"

sudo chown -R 1000:1000 /var/lib/backrest 2>/dev/null || true

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
sudo systemctl enable --now backrest.service
print_success "Backrest запущен через Quadlet"
print_url "http://$SERVER_IP:9898"

# =============== 14. FAUCET (rootful QUADLET) ===============
print_step "Настройка Faucet (MCP Server + GUI)"

# Создаём директории
mkdir -p "$FAUCET_DIR"/{data,config}

# Генерируем пароль
FAUCET_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
FAUCET_JWT=$(openssl rand -base64 32)

# Создаём конфиг
cat > "$FAUCET_DIR/config/faucet.yaml" <<EOF
database:
  driver: sqlite
  dsn: /data/faucet.db

auth:
  enabled: true
  jwt_secret: ${FAUCET_JWT}
  
admin:
  enabled: true
  users:
    - username: admin
      password: ${FAUCET_PASS}
EOF

# Права доступа (ВАЖНО для избежания readonly database)
chmod 755 "$FAUCET_DIR"
chmod 755 "$FAUCET_DIR/config"
chmod 644 "$FAUCET_DIR/config/faucet.yaml"
chmod 777 "$FAUCET_DIR/data"
touch "$FAUCET_DIR/data/faucet.db"
chmod 666 "$FAUCET_DIR/data/faucet.db"
echo "$FAUCET_PASS" > "$FAUCET_DIR/admin_password.txt"
chmod 600 "$FAUCET_DIR/admin_password.txt"

# Quadlet файл для Faucet
sudo tee "$QUADLET_SYSTEM_DIR/faucet.container" > /dev/null <<EOF
[Unit]
Description=Faucet MCP Server with GUI
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/faucetdb/faucet:latest
ContainerName=faucet
Volume=$FAUCET_DIR/data:/data:Z
Volume=$FAUCET_DIR/config:/config:Z
PublishPort=8082:8080
Environment=FAUCET_CONFIG=/config/faucet.yaml
User=$CURRENT_UID:$CURRENT_UID
# Traefik labels
Label=traefik.enable=true
Label=traefik.http.routers.faucet-http.rule=Host(\`keys.lab\`)
Label=traefik.http.routers.faucet-http.entrypoints=web
Label=traefik.http.routers.faucet-http.middlewares=https-redirect@file
Label=traefik.http.routers.faucet-https.rule=Host(\`keys.lab\`)
Label=traefik.http.routers.faucet-https.entrypoints=websecure
Label=traefik.http.routers.faucet-https.tls=true
Label=traefik.http.services.faucet.loadbalancer.server.port=8080

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/faucet.container"
sudo systemctl daemon-reload
sudo systemctl enable --now faucet.service

print_success "Faucet запущен через Quadlet"
print_info "Логин: admin / Пароль: $FAUCET_PASS"
print_url "https://keys.lab (после настройки Traefik и hosts)"

# =============== 15. TRAEFIK (rootful QUADLET) ===============
print_step "Настройка Traefik (Reverse Proxy с дашбордом)"

# Статическая конфигурация Traefik
cat > "$TRAEFIK_DIR/config/traefik.yml" <<EOF
api:
  dashboard: true
  debug: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
  traefik:
    address: ":8080"

serversTransport:
  insecureSkipVerify: true

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: podman
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true
EOF

# Динамическая конфигурация Traefik
cat > "$TRAEFIK_DIR/config/dynamic.yml" <<EOF
tls:
  certificates:
    - certFile: /etc/traefik/certs/lab-cert.pem
      keyFile: /etc/traefik/certs/lab-key.pem
  options:
    default:
      minVersion: VersionTLS12

http:
  middlewares:
    https-redirect:
      redirectScheme:
        scheme: https
        permanent: true
    security-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        customFrameOptionsValue: "SAMEORIGIN"
    auth-basic:
      basicAuth:
        users:
          - "admin:\$2y\$05\$YourHashedPasswordHere"  # ЗАМЕНИТЕ НА СГЕНЕРИРОВАННЫЙ

  routers:
    traefik-dashboard:
      rule: "Host(\`traefik.lab\`)"
      service: api@internal
      entryPoints:
        - traefik
      middlewares:
        - auth-basic
EOF

# Quadlet файл для Traefik
sudo tee "$QUADLET_SYSTEM_DIR/traefik.container" > /dev/null <<EOF
[Unit]
Description=Traefik Reverse Proxy
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/traefik:latest
ContainerName=traefik
Volume=$TRAEFIK_DIR/config/traefik.yml:/etc/traefik/traefik.yml:Z
Volume=$TRAEFIK_DIR/config/dynamic.yml:/etc/traefik/dynamic.yml:Z
Volume=$CERT_DIR:/etc/traefik/certs:ro,Z
Volume=/var/run/docker.sock:/var/run/docker.sock:ro,Z
PublishPort=80:80
PublishPort=443:443
PublishPort=8080:8080
# Traefik self-labels for dashboard
Label=traefik.enable=true
Label=traefik.http.routers.dashboard.rule=Host(\`traefik.lab\`)
Label=traefik.http.routers.dashboard.service=api@internal
Label=traefik.http.routers.dashboard.middlewares=auth-basic@file

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/traefik.container"
sudo systemctl daemon-reload
sudo systemctl enable --now traefik.service

print_success "Traefik запущен через Quadlet"
print_url "http://$SERVER_IP:8080 (дашборд)"
print_url "https://traefik.lab (после настройки hosts)"

# =============== 16. KEEWEB (rootful QUADLET) ===============
print_step "Настройка KeeWeb (менеджер паролей)"

# Quadlet файл для KeeWeb
sudo tee "$QUADLET_SYSTEM_DIR/keeweb.container" > /dev/null <<EOF
[Unit]
Description=KeeWeb Password Manager
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=ghcr.io/keeweb/keeweb:latest
ContainerName=keeweb
Volume=$KEEWEB_DIR/data:/config:Z
PublishPort=8080:80
# Traefik labels
Label=traefik.enable=true
Label=traefik.http.routers.keeweb-http.rule=Host(\`keeweb.lab\`)
Label=traefik.http.routers.keeweb-http.entrypoints=web
Label=traefik.http.routers.keeweb-http.middlewares=https-redirect@file
Label=traefik.http.routers.keeweb-https.rule=Host(\`keeweb.lab\`)
Label=traefik.http.routers.keeweb-https.entrypoints=websecure
Label=traefik.http.routers.keeweb-https.tls=true
Label=traefik.http.services.keeweb.loadbalancer.server.port=80

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/keeweb.container"
sudo systemctl daemon-reload
sudo systemctl enable --now keeweb.service

print_success "KeeWeb запущен через Quadlet"
print_url "http://$SERVER_IP:8080"
print_url "https://keeweb.lab (после настройки Traefik и hosts)"

# =============== 17. HOMEPAGE (rootless QUADLET) ===============
print_step "Настройка Homepage"

echo ""
print_info "🌤 Хочешь видеть погоду на дашборде?"
print_info "1. Зарегистрируйся на https://home.openweathermap.org/users/sign_up"
print_info "2. Получи API ключ"
echo ""
read -rp "  OpenWeatherMap API ключ (Enter чтобы пропустить): " WEATHER_KEY

HOMEPAGE_CONFIG_DIR="$VOLUMES_DIR/homepage/config"
mkdir -p "$HOMEPAGE_CONFIG_DIR"

# Проверяем и исправляем права
chmod 755 "$HOMEPAGE_CONFIG_DIR"
chmod 644 "$HOMEPAGE_CONFIG_DIR"/*.yaml 2>/dev/null || true

# Создаём конфиг services.yaml
cat > "$HOMEPAGE_CONFIG_DIR/services.yaml" <<EOF
---
Инфраструктура:
  - KeeWeb:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/keepass.png
      href: https://keeweb.lab
      description: "Менеджер паролей"
  - Faucet:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/faucet.png
      href: https://keys.lab
      description: "API-ключи для AI (MCP)"
  - Gitea:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/gitea.png
      href: https://git.lab
      description: "Git репозиторий"
  - Backrest:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: https://backup.lab
      description: "Управление бэкапами"
  - TorrServer:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/torrent.png
      href: https://torrent.lab
      description: "Торрент стриминг"

Администрирование:
  - Traefik:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/traefik.png
      href: https://traefik.lab
      description: "Reverse proxy + дашборд"
  - NetBird:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/netbird.png
      href: https://app.netbird.io
      description: "VPN управление"
  - Restic REST:
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/restic.png
      href: http://$SERVER_IP:8000
      description: "Хранилище бэкапов"

Доступ напрямую:
  - Faucet (прямой):
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/faucet.png
      href: http://$SERVER_IP:8082
      description: "UI без Traefik"
  - KeeWeb (прямой):
      icon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/keepass.png
      href: http://$SERVER_IP:8080
      description: "Без Traefik"
EOF

# Создаём конфиг settings.yaml
cat > "$HOMEPAGE_CONFIG_DIR/settings.yaml" <<EOF
---
title: "DevOps Lab Dashboard"
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

# Добавляем погоду если есть ключ
if [ -n "$WEATHER_KEY" ]; then
  cat >> "$HOMEPAGE_CONFIG_DIR/settings.yaml" <<EOF

weather:
  - name: "Погода в Барнауле"
    type: "openweathermap"
    apiKey: "$WEATHER_KEY"
    units: "metric"
    city: "Barnaul"
    country: "RU"
EOF
fi

chmod 644 "$HOMEPAGE_CONFIG_DIR"/*.yaml
chown -R $CURRENT_USER:$CURRENT_USER "$HOMEPAGE_CONFIG_DIR"

# Quadlet файл для Homepage
cat > "$QUADLET_USER_DIR/homepage.container" <<EOF
[Unit]
Description=Homepage Dashboard
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=ghcr.io/gethomepage/homepage:latest
ContainerName=homepage
Volume=$HOMEPAGE_CONFIG_DIR:/app/config:ro,Z
Volume=/var/run/docker.sock:/var/run/docker.sock:ro,Z
PublishPort=3001:3000
Environment=HOMEPAGE_ALLOWED_HOSTS=$SERVER_IP:3001,localhost:3001,home.lab:3001
# Traefik labels
Label=traefik.enable=true
Label=traefik.http.routers.homepage-http.rule=Host(\`home.lab\`)
Label=traefik.http.routers.homepage-http.entrypoints=web
Label=traefik.http.routers.homepage-http.middlewares=https-redirect@file
Label=traefik.http.routers.homepage-https.rule=Host(\`home.lab\`)
Label=traefik.http.routers.homepage-https.entrypoints=websecure
Label=traefik.http.routers.homepage-https.tls=true
Label=traefik.http.services.homepage.loadbalancer.server.port=3000

[Service]
Restart=always
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown $CURRENT_USER:$CURRENT_USER "$QUADLET_USER_DIR/homepage.container"
systemctl --user daemon-reload
systemctl --user enable --now homepage.service

# Проверяем что конфиги применились
sleep 5
if journalctl --user -u homepage.service -n 20 --no-pager 2>&1 | grep -q "config"; then
    print_success "Homepage запущен через Quadlet с конфигурацией"
else
    print_warning "Проверьте логи: journalctl --user -u homepage.service -f"
fi

print_success "Homepage запущен через Quadlet"
print_url "http://$SERVER_IP:3001"
print_url "https://home.lab (после настройки Traefik и hosts)"

# =============== 18. ФИНАЛЬНЫЙ ВЫВОД ===============
print_header "🚀 ИНФРАСТРУКТУРА ПОЛНОСТЬЮ ГОТОВА (QUADLET)"

cat <<EOF

${NEON_GREEN}╔══════════════════════════════════════════════════════════╗${RESET}
${NEON_GREEN}║         🔌 ДОСТУП ДЛЯ ПЕРВОНАЧАЛЬНОЙ НАСТРОЙКИ         ║${RESET}
${NEON_GREEN}╚══════════════════════════════════════════════════════════╝${RESET}

${NEON_CYAN}🏠 ДАШБОРД${RESET}
  ${NEON_GREEN}●${RESET} Homepage:            ${NEON_CYAN}http://$SERVER_IP:3001${RESET}
  ${NEON_GREEN}●${RESET} Homepage (домен):    ${NEON_CYAN}https://home.lab${RESET}

${NEON_CYAN}🔄 REVERSE PROXY${RESET}
  ${NEON_GREEN}●${RESET} Traefik Dashboard:   ${NEON_CYAN}http://$SERVER_IP:8080${RESET}
  ${NEON_GREEN}●${RESET} Traefik (домен):     ${NEON_CYAN}https://traefik.lab${RESET}
  ${MUTED_GRAY}  └─ Basic auth: настройте в ~/infra/traefik/config/dynamic.yml

${NEON_CYAN}🔐 МЕНЕДЖЕРЫ ПАРОЛЕЙ${RESET}
  ${NEON_GREEN}●${RESET} KeeWeb:              ${NEON_CYAN}http://$SERVER_IP:8080${RESET}
  ${NEON_GREEN}●${RESET} KeeWeb (домен):      ${NEON_CYAN}https://keeweb.lab${RESET}
  ${NEON_GREEN}●${RESET} Faucet (UI):         ${NEON_CYAN}http://$SERVER_IP:8082${RESET}
  ${NEON_GREEN}●${RESET} Faucet (MCP):        ${NEON_CYAN}http://$SERVER_IP:8082/mcp${RESET}
  ${NEON_GREEN}●${RESET} Faucet (домен):      ${NEON_CYAN}https://keys.lab${RESET}
  ${MUTED_GRAY}  └─ Логин: admin / Пароль: ${NEON_CYAN}$FAUCET_PASS${RESET}

${NEON_CYAN}📦 РАЗРАБОТКА И БЭКАПЫ${RESET}
  ${NEON_GREEN}●${RESET} Gitea:               ${NEON_CYAN}http://$SERVER_IP:3000${RESET}
  ${NEON_GREEN}●${RESET} Gitea (домен):       ${NEON_CYAN}https://git.lab${RESET}
  ${NEON_GREEN}●${RESET} Backrest:            ${NEON_CYAN}http://$SERVER_IP:9898${RESET}
  ${NEON_GREEN}●${RESET} Backrest (домен):    ${NEON_CYAN}https://backup.lab${RESET}
  ${NEON_GREEN}●${RESET} Restic REST:         ${NEON_CYAN}http://$SERVER_IP:8000${RESET} (user: restic)

${NEON_CYAN}🎬 МЕДИА${RESET}
  ${NEON_GREEN}●${RESET} TorrServer:          ${NEON_CYAN}http://$SERVER_IP:8090${RESET}
  ${NEON_GREEN}●${RESET} TorrServer (домен):  ${NEON_CYAN}https://torrent.lab${RESET}

${NEON_CYAN}🪟 WINDOWS КЛИЕНТЫ${RESET}
  ${NEON_GREEN}●${RESET} NetBird:     ${NEON_CYAN}https://pkgs.netbird.io/windows${RESET}
  ${NEON_GREEN}●${RESET} KeeWeb:      ${NEON_CYAN}https://keeweb.info${RESET}
  ${NEON_GREEN}●${RESET} Restic:      ${NEON_CYAN}https://github.com/restic/restic/releases${RESET}

${NEON_BLUE}📋 ДЛЯ РАБОТЫ ДОМЕНОВ${RESET}
  ${NEON_YELLOW}1.${RESET} Добавьте в hosts файл на Windows (C:\Windows\System32\drivers\etc\hosts):
     ${NEON_CYAN}$SERVER_IP keeweb.lab keys.lab git.lab backup.lab home.lab torrent.lab traefik.lab${RESET}
  ${NEON_YELLOW}2.${RESET} Запустите от администратора: ${NEON_CYAN}ipconfig /flushdns${RESET}
  ${NEON_YELLOW}3.${RESET} Откройте любой домен в браузере (например, https://keeweb.lab)

${NEON_GREEN}🎉 УПРАВЛЕНИЕ ЧЕРЕЗ QUADLET:${RESET}
  ${NEON_CYAN}infra status${RESET}              - статус всех сервисов
  ${NEON_CYAN}systemctl --user start gitea${RESET}   - ручной запуск rootless сервиса
  ${NEON_CYAN}sudo systemctl start traefik${RESET}   - ручной запуск rootful сервиса
  ${NEON_CYAN}infra logs <service>${RESET}           - логи сервиса
  ${NEON_CYAN}infra backup${RESET}                   - бэкап всех данных
  ${NEON_CYAN}infra clear${RESET}                     - полное удаление

${NEON_GREEN}🔑 ВСЕ ПАРОЛИ СОХРАНЕНЫ В:${RESET} ${NEON_CYAN}~/infra/credentials.txt${RESET}
EOF

# Сохраняем все credentials
cat > "$INFRA_DIR/credentials.txt" <<EOF
# ========================================
# INFRASTRUCTURE CREDENTIALS v12.0.0 (QUADLET)
# Сгенерировано: $(date)
# ========================================

=== TRAEFIK ===
Dashboard: http://$SERVER_IP:8080
Domain: https://traefik.lab
Basic auth: настройте в ~/infra/traefik/config/dynamic.yml

=== KEEWEB ===
URL: http://$SERVER_IP:8080
Domain: https://keeweb.lab

=== FAUCET ===
Admin UI: http://$SERVER_IP:8082
Username: admin
Password: $FAUCET_PASS
MCP endpoint: http://$SERVER_IP:8082/mcp
Domain: https://keys.lab

=== GITEA ===
URL: http://$SERVER_IP:3000
Domain: https://git.lab

=== BACKREST ===
URL: http://$SERVER_IP:9898
Domain: https://backup.lab

=== RESTIC REST ===
URL: http://$SERVER_IP:8000
Username: restic
Password: $(sudo cat /var/lib/rest-server/.restic_pass 2>/dev/null || echo "смотри в /var/lib/rest-server/.restic_pass")

=== TORRSERVER ===
URL: http://$SERVER_IP:8090
Domain: https://torrent.lab

=== HOMEPAGE ===
URL: http://$SERVER_IP:3001
Domain: https://home.lab

=== NETBIRD ===
VPN IP: $(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "не определен")
Dashboard: https://app.netbird.io

=== QUADLET ФАЙЛЫ ===
Rootless: ~/.config/containers/systemd/
Rootful: /etc/containers/systemd/
Автообновление: podman-auto-update.timer (включено)
EOF

chmod 600 "$INFRA_DIR/credentials.txt"
print_success "Все credentials сохранены в ~/infra/credentials.txt"

# =============== 19. САМОУДАЛЕНИЕ ===============
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi
