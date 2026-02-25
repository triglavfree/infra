#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v11.0.0 (FULL INTEGRATION WITH BACKREST, VAULTWARDEN, HOMEPAGE)
# =============================================================================
# Tested on: Ubuntu Server 24.04.4 LTS
# Author: DevOps Team
# Description: Complete infrastructure setup with Gitea, TorrServer, NetBird,
#              Restic REST Server, Vaultwarden, Backrest, and Homepage
# =============================================================================

# =============== ЦВЕТА И ФУНКЦИИ ВЫВОДА ===============
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 81)
        NEON_GREEN=$(tput setaf 84)
        NEON_YELLOW=$(tput setaf 220)
        NEON_RED=$(tput setaf 203)
        NEON_PURPLE=$(tput setaf 141)
        NEON_BLUE=$(tput setaf 75)
        SOFT_WHITE=$(tput setaf 252)
        MUTED_GRAY=$(tput setaf 245)
        DIM_GRAY=$(tput setaf 240)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    else
        NEON_CYAN=$(tput setaf 6)
        NEON_GREEN=$(tput setaf 2)
        NEON_YELLOW=$(tput setaf 3)
        NEON_RED=$(tput setaf 1)
        NEON_PURPLE=$(tput setaf 5)
        NEON_BLUE=$(tput setaf 4)
        SOFT_WHITE=$(tput setaf 7)
        MUTED_GRAY=$(tput setaf 8)
        DIM_GRAY=$(tput setaf 8)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
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

# =============== ФУНКЦИИ ВЫВОДА ===============
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

# =============== ПРОВЕРКА ПРАВ ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

print_header "INFRASTRUCTURE v11.0.0 (FULL INTEGRATION)"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== СОЗДАНИЕ ДИРЕКТОРИЙ ===============
print_step "Создание структуры директорий"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"

# Директории для Quadlet
QUADLET_USER_DIR="$CURRENT_HOME/.config/containers/systemd"
QUADLET_SYSTEM_DIR="/etc/containers/systemd"

# Создаем все необходимые директории
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

# Системные директории
sudo mkdir -p "$QUADLET_SYSTEM_DIR" \
            /var/lib/gitea-runner \
            /var/lib/netbird \
            /var/lib/rest-server \
            /var/lib/vaultwarden \
            /var/lib/backrest/{data,config,cache}

# Устанавливаем права
sudo chmod 755 /var/lib/gitea-runner /var/lib/netbird /var/lib/rest-server \
               /var/lib/vaultwarden /var/lib/backrest
sudo chown -R root:root /var/lib/rest-server /var/lib/vaultwarden /var/lib/backrest

print_success "Директории созданы"

# =============== ДИАГНОСТИКА QUADLET ===============
print_step "Диагностика Quadlet"

if [ -f "/usr/libexec/podman/quadlet" ]; then
    print_success "Quadlet найден: /usr/libexec/podman/quadlet"
    if [ ! -L "/usr/lib/systemd/system-generators/podman-system-generator" ]; then
        print_warning "Systemd генератор не найден, создаем ссылку"
        sudo ln -sf /usr/libexec/podman/quadlet /usr/lib/systemd/system-generators/podman-system-generator
    fi
    if ! systemctl is-active --quiet podman.socket; then
        sudo systemctl enable --now podman.socket
    fi
    print_success "podman.socket активен"
else
    print_error "Quadlet не установлен! Устанавливаем podman..."
    sudo apt-get update
    sudo apt-get install -y podman podman-docker apache2-utils
fi

# =============== BOOTSTRAP СИСТЕМЫ ===============
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
        apt-get install -y -qq uidmap slirp4netns fuse-overlayfs curl openssl ufw fail2ban apache2-utils >/dev/null 2>&1 || true

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
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 3000/tcp comment 'Gitea HTTP' >/dev/null 2>&1
        ufw allow 3001/tcp comment 'Homepage' >/dev/null 2>&1
        ufw allow 2222/tcp comment 'Gitea SSH' >/dev/null 2>&1
        ufw allow 8090/tcp comment 'TorrServer' >/dev/null 2>&1
        ufw allow 51820/udp comment 'WireGuard' >/dev/null 2>&1
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

# =============== CLI УСТАНОВКА ===============
print_step "Установка CLI"

cat > "$BIN_DIR/infra" <<'ENDOFCLI'
#!/bin/bash
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BACKUP_DIR="$INFRA_DIR/backups"

# =============== ЦВЕТА ДЛЯ CLI ===============
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ $ncolors -ge 256 ]; then
        NEON_CYAN=$(tput setaf 81); NEON_GREEN=$(tput setaf 84); NEON_YELLOW=$(tput setaf 220)
        NEON_RED=$(tput setaf 203); NEON_PURPLE=$(tput setaf 141); NEON_BLUE=$(tput setaf 75)
        SOFT_WHITE=$(tput setaf 252); MUTED_GRAY=$(tput setaf 245); DIM_GRAY=$(tput setaf 240)
        BOLD=$(tput bold); RESET=$(tput sgr0)
    else
        NEON_CYAN=$(tput setaf 6); NEON_GREEN=$(tput setaf 2); NEON_YELLOW=$(tput setaf 3)
        NEON_RED=$(tput setaf 1); NEON_PURPLE=$(tput setaf 5); NEON_BLUE=$(tput setaf 4)
        SOFT_WHITE=$(tput setaf 7); MUTED_GRAY=$(tput setaf 8); DIM_GRAY=$(tput setaf 8)
        BOLD=$(tput bold); RESET=$(tput sgr0)
    fi
else
    NEON_CYAN=""; NEON_GREEN=""; NEON_YELLOW=""; NEON_RED=""
    NEON_PURPLE=""; NEON_BLUE=""; SOFT_WHITE=""; MUTED_GRAY=""
    DIM_GRAY=""; BOLD=""; RESET=""
fi

ICON_OK="${NEON_GREEN}●${RESET}"
ICON_FAIL="${NEON_RED}●${RESET}"
ICON_WARN="${NEON_YELLOW}●${RESET}"
ICON_INFO="${NEON_BLUE}●${RESET}"
ICON_ARROW="▸"

# =============== ФУНКЦИИ CLI ===============
print_box() {
    local title="$1"
    local datetime=$(date "+%d.%m.%Y %H:%M:%S")
    local full_title="${title} ${datetime}"
    echo ""
    echo -e "${NEON_CYAN}╔══════════════════════════════════════════════════╗${RESET}"
    printf "${NEON_CYAN}║${RESET} ${BOLD}%-48s${RESET} ${NEON_CYAN}║${RESET}\n" "$full_title"
    echo -e "${NEON_CYAN}╚══════════════════════════════════════════════════╝${RESET}"
}

print_section() {
    echo ""
    echo -e "${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$1${RESET}"
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
}

print_metric() {
    printf "  ${DIM_GRAY}%-14s${RESET} %s\n" "$1" "$2"
}

format_uptime() {
    local diff=$1
    if [ $diff -lt 60 ]; then
        echo "${diff}s"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff / 60))m"
    else
        echo "$((diff / 3600))h$(((diff % 3600) / 60))m"
    fi
}

get_container_status() {
    local name=$1
    local user=$2
    local runtime=""
    [ "$user" = "root" ] && runtime="sudo podman" || runtime="podman"
    
    local container_name="$name"
    [ "$user" != "root" ] && container_name="systemd-$name"
    
    if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^$container_name$"; then
        local started_at=$($runtime inspect --format='{{.State.StartedAt}}' "$container_name" 2>/dev/null)
        local uptime_str=""
        
        if [ -n "$started_at" ] && [ "$started_at" != "0001-01-01T00:00:00Z" ]; then
            local start_epoch=$(date -d "$started_at" +%s 2>/dev/null)
            local now_epoch=$(date +%s)
            local diff=$((now_epoch - start_epoch))
            uptime_str=$(format_uptime $diff)
        fi
        
        echo -e "${ICON_OK} ${NEON_GREEN}running${RESET} ${DIM_GRAY}(${uptime_str})${RESET}"
        return
    fi
    
    if $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^$container_name$"; then
        echo -e "${ICON_FAIL} ${NEON_RED}stopped${RESET}"
    else
        echo -e "${DIM_GRAY}● not created${RESET}"
    fi
}

get_service_status() {
    local name=$1
    local user=$2
    if [ "$user" = "root" ]; then
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        else
            echo -e "${DIM_GRAY}● inactive${RESET}"
        fi
    else
        if systemctl --user is-active --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        else
            echo -e "${DIM_GRAY}● inactive${RESET}"
        fi
    fi
}

get_disk_type() {
    local disk=$1
    [ -z "$disk" ] && echo "unknown" && return
    
    local mount_point="$INFRA_DIR"
    local device=""
    
    if command -v findmnt &>/dev/null; then
        device=$(findmnt -no SOURCE "$mount_point" 2>/dev/null | head -1)
    fi
    
    if [ -z "$device" ]; then
        device=$(df "$mount_point" 2>/dev/null | tail -1 | awk '{print $1}')
    fi
    
    local base_disk=$(echo "$device" | sed -E 's/[0-9]+$//' | sed -E 's/p[0-9]+$//')
    local dev_name=$(basename "$base_disk")
    
    if command -v lsblk &>/dev/null && [ -n "$dev_name" ]; then
        local rotational=$(lsblk -d -o ROTA "/dev/$dev_name" 2>/dev/null | tail -1)
        if [ "$rotational" = "0" ]; then
            echo "SSD"
            return
        elif [ "$rotational" = "1" ]; then
            echo "HDD"
            return
        fi
    fi
    
    echo "unknown"
}

# =============== STATUS COMMAND ===============
status_cmd() {
    clear
    print_box "INFRA STATUS v11.0.0"
    local server_ip=$(hostname -I | awk '{print $1}')

    print_section "Rootless Services (User: $USER)"
    local gitea_svc=$(get_service_status "gitea" "user")
    local gitea_ctr=$(get_container_status "gitea" "user")
    print_metric "Gitea" "$gitea_svc $gitea_ctr"
    
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-gitea$"; then
        local gitea_port=$(podman port systemd-gitea 2>/dev/null | grep "3000/tcp" | cut -d: -f2 || echo "3000")
        local gitea_ssh=$(podman port systemd-gitea 2>/dev/null | grep "22/tcp" | cut -d: -f2 || echo "2222")
        print_metric "" "${MUTED_GRAY}→ http://${server_ip}:${gitea_port} | ssh://${server_ip}:${gitea_ssh}${RESET}"
    fi
    
    local torr_svc=$(get_service_status "torrserver" "user")
    local torr_ctr=$(get_container_status "torrserver" "user")
    print_metric "TorrServer" "$torr_svc $torr_ctr"
    
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-torrserver$"; then
        local torr_port=$(podman port systemd-torrserver 2>/dev/null | grep "8090/tcp" | cut -d: -f2 || echo "8090")
        print_metric "" "${MUTED_GRAY}→ http://${server_ip}:${torr_port}${RESET}"
    fi

    local hp_svc=$(get_service_status "homepage" "user")
    local hp_ctr=$(get_container_status "homepage" "user")
    print_metric "Homepage" "$hp_svc $hp_ctr"
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-homepage$"; then
        print_metric "" "${MUTED_GRAY}→ http://${server_ip}:3001${RESET}"
    fi

    print_section "Rootful Services (System)"
    local runner_svc=$(get_service_status "gitea-runner" "root")
    local runner_ctr=$(get_container_status "gitea-runner" "root")
    print_metric "Gitea Runner" "$runner_svc $runner_ctr"
    
    local netbird_svc=$(get_service_status "netbird" "root")
    local netbird_ctr=$(get_container_status "netbird" "root")
    print_metric "NetBird VPN" "$netbird_svc $netbird_ctr"
    
    print_section "Backup & Security Services (System)"
    local rest_svc=$(get_service_status "rest-server" "root")
    local rest_ctr=$(get_container_status "rest-server" "root")
    print_metric "Restic Server" "$rest_svc $rest_ctr"

    local vault_svc=$(get_service_status "vaultwarden" "root")
    local vault_ctr=$(get_container_status "vaultwarden" "root")
    print_metric "Vaultwarden" "$vault_svc $vault_ctr"

    local backrest_svc=$(get_service_status "backrest" "root")
    local backrest_ctr=$(get_container_status "backrest" "root")
    print_metric "Backrest" "$backrest_svc $backrest_ctr"

    print_section "Resources"
    local disk_info=$(df -h "$INFRA_DIR" 2>/dev/null | tail -1)
    local disk_usage=$(echo "$disk_info" | awk '{print $3 "/" $2 " (" $5 ")"}')
    local disk_dev=$(echo "$disk_info" | awk '{print $1}')
    local disk_type=$(get_disk_type "$disk_dev")
    local fs_type=$(df -T "$INFRA_DIR" 2>/dev/null | tail -1 | awk '{print $2}')
    
    case "$disk_type" in
        "SSD"|"NVMe") disk_type_colored="${NEON_GREEN}${disk_type}${RESET}" ;;
        "HDD") disk_type_colored="${NEON_YELLOW}${disk_type}${RESET}" ;;
        *) disk_type_colored="${DIM_GRAY}${disk_type}${RESET}" ;;
    esac
    
    print_metric "Disk" "$disk_usage ${NEON_CYAN}[${disk_type_colored}]${RESET} ${MUTED_GRAY}(${fs_type})${RESET}"
    
    local mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')
    print_metric "Memory" "$mem_info"
    
    local swap_info=$(free -h 2>/dev/null | awk '/^Swap:/ {if ($2 != "0B") print $3 "/" $2; else print "disabled"}')
    print_metric "Swap" "$swap_info"
    
    local ctr_count=$(podman ps -q 2>/dev/null | wc -l)
    local ctr_total=$(podman ps -aq 2>/dev/null | wc -l)
    local root_ctr_count=$(sudo podman ps -q 2>/dev/null | wc -l)
    local root_ctr_total=$(sudo podman ps -aq 2>/dev/null | wc -l)
    print_metric "Containers" "${SOFT_WHITE}user:${RESET} ${NEON_CYAN}${ctr_count}${RESET}/${ctr_total} ${SOFT_WHITE}root:${RESET} ${NEON_CYAN}${root_ctr_count}${RESET}/${root_ctr_total}"

    if [ -f "$INFRA_DIR/.netbird_urls" ]; then
        print_section "Public URLs (NetBird)"
        while read -r url; do
            if [[ "$url" == *"vaultwarden"* ]]; then
                print_metric "Vaultwarden" "${NEON_CYAN}$url${RESET}"
            elif [[ "$url" == *"restic"* ]]; then
                print_metric "Restic" "${NEON_CYAN}$url${RESET}"
            elif [[ "$url" == *"backrest"* ]]; then
                print_metric "Backrest" "${NEON_CYAN}$url${RESET}"
            elif [[ "$url" == *"homepage"* ]]; then
                print_metric "Homepage" "${NEON_CYAN}$url${RESET}"
            elif [[ "$url" == *"gitea"* ]]; then
                print_metric "Gitea" "${NEON_CYAN}$url${RESET}"
            fi
        done < "$INFRA_DIR/.netbird_urls"
    fi

    echo ""
    echo -e "${DIM_GRAY}──────────────────────────────────────────────────${RESET}"
    echo -e "${MUTED_GRAY}Commands: ${NEON_CYAN}status${RESET}|${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart${RESET}|${NEON_CYAN}logs${RESET}|${NEON_CYAN}update${RESET}|${NEON_CYAN}clear${RESET}"
}

# =============== ОСНОВНЫЕ КОМАНДЫ ===============
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
        systemctl --user stop gitea torrserver homepage 2>/dev/null && echo -e "  ${ICON_OK} User services" || echo -e "  ${DIM_GRAY}○ User services${RESET}"
        sudo systemctl stop gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null && echo -e "  ${ICON_OK} System services" || echo -e "  ${DIM_GRAY}○ System services${RESET}"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver homepage 2>/dev/null && echo -e "  ${ICON_OK} User services" || echo -e "  ${ICON_FAIL} User services"
        sudo systemctl start gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null && echo -e "  ${ICON_OK} System services" || echo -e "  ${ICON_FAIL} System services"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        case "$2" in
            netbird|gitea-runner|rest-server|vaultwarden|backrest)
                sudo systemctl restart "$2" && echo -e "  ${ICON_OK} $2 перезапущен" || echo -e "  ${ICON_FAIL} Ошибка"
                ;;
            gitea|torrserver|homepage)
                systemctl --user restart "$2" && echo -e "  ${ICON_OK} $2 перезапущен" || echo -e "  ${ICON_FAIL} Ошибка"
                ;;
            *) echo "Unknown service: $2"; exit 1 ;;
        esac
        ;;
    update)
        echo -e "${NEON_CYAN}▸ Обновление контейнеров...${RESET}"
        systemctl --user stop gitea torrserver homepage 2>/dev/null
        podman auto-update --rollback 2>/dev/null && echo -e "  ${ICON_OK} User containers updated" || echo -e "  ${ICON_INFO} No updates"
        systemctl --user start gitea torrserver homepage 2>/dev/null
        
        sudo systemctl stop gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
        sudo podman auto-update --rollback 2>/dev/null && echo -e "  ${ICON_OK} System containers updated" || echo -e "  ${ICON_INFO} No updates"
        sudo systemctl start gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
        echo -e "  ${ICON_OK} ${NEON_GREEN}Update completed${RESET}"
        ;;
    clear)
        echo -e "${NEON_RED}▸ УДАЛЕНИЕ ВСЕЙ ИНФРАСТРУКТУРЫ${RESET}"
        read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
        if [ "$CONFIRM" = "yes" ]; then
            echo -e "  ${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
            systemctl --user stop gitea torrserver homepage 2>/dev/null
            sudo systemctl stop gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
            
            echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
            podman rm -f gitea torrserver homepage 2>/dev/null
            sudo podman rm -f gitea-runner netbird rest-server vaultwarden backrest 2>/dev/null
            
            echo -e "  ${NEON_YELLOW}▸ Удаление Quadlet файлов...${RESET}"
            rm -f ~/.config/containers/systemd/{gitea,torrserver,homepage}.container
            sudo rm -f /etc/containers/systemd/{gitea-runner,netbird,rest-server,vaultwarden,backrest}.container
            
            systemctl --user daemon-reload
            sudo systemctl daemon-reload
            
            read -rp "  Удалить директорию $INFRA_DIR с данными? [y/N]: " DEL_DATA
            if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
                sudo rm -rf "$INFRA_DIR" /var/lib/gitea-runner /var/lib/netbird /var/lib/rest-server /var/lib/vaultwarden /var/lib/backrest
            fi
            
            sudo rm -f /usr/local/bin/infra
            echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
            echo -e "${NEON_GREEN}${BOLD}║     INFRASTRUCTURE COMPLETELY REMOVED         ║${RESET}"
            echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
        fi
        ;;
    *)
        echo "Использование: infra {status|start|stop|restart <svc>|logs <svc>|update|clear}"
        echo "Сервисы: gitea, torrserver, homepage, gitea-runner, netbird, rest-server, vaultwarden, backrest"
        ;;
esac
ENDOFCLI

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true
print_success "CLI установлен"

# =============== PODMAN AUTO-UPDATE ===============
print_step "Настройка авто-обновления"

systemctl --user enable podman-auto-update.timer 2>/dev/null || true
systemctl --user start podman-auto-update.timer 2>/dev/null || true
sudo systemctl enable podman-auto-update.timer 2>/dev/null || true
sudo systemctl start podman-auto-update.timer 2>/dev/null || true
print_success "Auto-update timers включены"

# =============== TORRSERVER ROOTLESS ===============
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
TimeoutStopSec=10
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

# =============== GITEA ROOTLESS ===============
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
Environment=GITEA__repository_upload__ENABLED=true
Environment=GITEA__repository_upload__MAX_FILES=1000
Environment=GITEA__repository_upload__FILE_MAX_SIZE=5000

[Service]
Restart=always
TimeoutStopSec=60
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

# Ждём настройку Gitea
print_info "Ожидание 60 секунд для настройки Gitea..."
sleep 60

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    GITEA_READY=1
else
    print_warning "Gitea API не отвечает"
    GITEA_READY=0
fi

# =============== GITEA RUNNER ROOTFUL ===============
print_step "Настройка Gitea Runner"

SKIP_RUNNER=0
if sudo systemctl list-unit-files 2>/dev/null | grep -q "gitea-runner.service"; then
    print_info "Runner уже существует"
    read -rp "  Пересоздать? [y/N]: " RECREATE
    [[ "$RECREATE" =~ ^[Yy]$ ]] && SKIP_RUNNER=0 || SKIP_RUNNER=1
fi

if [ $SKIP_RUNNER -eq 0 ] && [ $GITEA_READY -eq 1 ]; then
    echo ""
    read -rp "  Registration Token (from Gitea Admin > Actions > Runners): " RUNNER_TOKEN

    if [ -n "$RUNNER_TOKEN" ]; then
        sudo rm -rf /var/lib/gitea-runner
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
Exec=act_runner daemon
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
        sudo systemctl start gitea-runner.service

        sleep 5
        if sudo podman ps --format "{{.Names}}" | grep -q "^gitea-runner$"; then
            print_success "Runner запущен"
        else
            print_error "Ошибка запуска runner"
        fi
    fi
fi

# =============== NETBIRD ROOTFUL ===============
print_step "Настройка NetBird"

SKIP_NETBIRD=0
if sudo systemctl list-unit-files 2>/dev/null | grep -q "netbird.service"; then
    print_info "NetBird уже существует"
    read -rp "  Пересоздать? [y/N]: " RECREATE_NB
    [[ "$RECREATE_NB" =~ ^[Yy]$ ]] && SKIP_NETBIRD=0 || SKIP_NETBIRD=1
fi

if [ $SKIP_NETBIRD -eq 0 ]; then
    echo ""
    read -rp "  NetBird Setup Key (from https://app.netbird.io/setup-keys): " NB_KEY

    if [ -n "$NB_KEY" ]; then
        sudo rm -rf /var/lib/netbird
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
TimeoutStopSec=30
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

        sudo chmod 644 "$QUADLET_SYSTEM_DIR/netbird.container"
        sudo systemctl daemon-reload
        sudo systemctl start netbird.service

        sleep 10
        if sudo podman ps --format "{{.Names}}" | grep -q "^netbird$"; then
            print_success "NetBird запущен"
            NB_IP=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
            [ -n "$NB_IP" ] && print_info "IP в сети NetBird: $NB_IP"
        else
            print_error "Ошибка запуска NetBird"
        fi
    fi
fi

# =============== REST-SERVER ROOTFUL ===============
print_step "Настройка Restic REST сервера"

if [ ! -f "/var/lib/rest-server/.htpasswd" ]; then
    REST_USER="restic"
    REST_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    
    echo "$REST_PASS" | sudo tee /var/lib/rest-server/.restic_pass > /dev/null
    sudo htpasswd -B -b -c /var/lib/rest-server/.htpasswd "$REST_USER" "$REST_PASS" >/dev/null 2>&1
    sudo chmod 600 /var/lib/rest-server/.htpasswd /var/lib/rest-server/.restic_pass
    
    print_success "Создан пользователь $REST_USER для rest-server"
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
PublishPort=127.0.0.1:8000:8000
Exec=rest-server --path /data --htpasswd-file /data/.htpasswd --append-only --listen :8000

[Service]
Restart=always
TimeoutStopSec=30
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/rest-server.container"
sudo systemctl daemon-reload
sudo systemctl start rest-server.service

sleep 3
if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^rest-server$"; then
    print_success "Restic REST сервер запущен на localhost:8000"
    REST_SERVER_READY=1
else
    print_error "Ошибка запуска rest-server"
    REST_SERVER_READY=0
fi

# =============== VAULTWARDEN ROOTFUL ===============
print_step "Настройка Vaultwarden"

if [ ! -f "/etc/vaultwarden/secrets/admin_token.env" ]; then
    sudo mkdir -p /etc/vaultwarden/secrets
    VAULT_ADMIN_TOKEN=$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-32)
    echo "VAULTWARDEN_ADMIN_TOKEN=$VAULT_ADMIN_TOKEN" | sudo tee /etc/vaultwarden/secrets/admin_token.env > /dev/null
    sudo chmod 600 /etc/vaultwarden/secrets/admin_token.env
    print_success "Сгенерирован admin токен для Vaultwarden"
fi

VAULT_DOMAIN="https://vaultwarden.local"

sudo tee "$QUADLET_SYSTEM_DIR/vaultwarden.container" > /dev/null <<EOF
[Unit]
Description=Vaultwarden Password Manager
After=network-online.target
Wants=podman-auto-update.service

[Container]
Image=docker.io/vaultwarden/server:latest
ContainerName=vaultwarden
Volume=/var/lib/vaultwarden:/data:Z
PublishPort=127.0.0.1:8080:80
Environment=DOMAIN=$VAULT_DOMAIN
Environment=WEBSOCKET_ENABLED=true
Environment=SIGNUPS_ALLOWED=false
EnvironmentFile=/etc/vaultwarden/secrets/admin_token.env

[Service]
Restart=always
TimeoutStopSec=30
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/vaultwarden.container"
sudo systemctl daemon-reload
sudo systemctl start vaultwarden.service

sleep 5
if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^vaultwarden$"; then
    print_success "Vaultwarden запущен на localhost:8080"
    VAULTWARDEN_READY=1
else
    print_error "Ошибка запуска vaultwarden"
    VAULTWARDEN_READY=0
fi

# =============== BACKREST ROOTFUL ===============
print_step "Настройка Backrest"

if [ -f "/var/lib/rest-server/.restic_pass" ]; then
    RESTIC_PASS=$(sudo cat /var/lib/rest-server/.restic_pass)
    RESTIC_USER="restic"
    
    sudo tee /var/lib/backrest/config/restic.env > /dev/null <<EOF
RESTIC_REPOSITORY=rest:http://$RESTIC_USER:$RESTIC_PASS@localhost:8000/windows-backup
RESTIC_PASSWORD=$RESTIC_PASS
EOF
    sudo chmod 600 /var/lib/backrest/config/restic.env
    print_success "Настроено подключение к rest-server"
fi

if [ ! -f "/var/lib/backrest/config/webui_pass" ]; then
    BACKREST_WEBUI_PASS=$(openssl rand -base64 16 | tr -d "=+/")
    echo "$BACKREST_WEBUI_PASS" | sudo tee /var/lib/backrest/config/webui_pass > /dev/null
    sudo chmod 600 /var/lib/backrest/config/webui_pass
    print_success "Сгенерирован пароль для WebUI Backrest"
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
Environment=BACKREST_PORT=0.0.0.0:9898
PublishPort=127.0.0.1:9898:9898

[Service]
Restart=always
TimeoutStopSec=30
Type=notify
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$QUADLET_SYSTEM_DIR/backrest.container"
sudo systemctl daemon-reload
sudo systemctl start backrest.service

sleep 8
if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^backrest$"; then
    print_success "Backrest запущен на localhost:9898"
    print_info "WebUI пароль: $(sudo cat /var/lib/backrest/config/webui_pass)"
    BACKREST_READY=1
else
    print_error "Ошибка запуска backrest"
    BACKREST_READY=0
fi

# =============== HOMEPAGE ROOTLESS (QUADLET) ===============
print_step "Настройка Homepage Dashboard"

HOMEPAGE_CONFIG_DIR="$VOLUMES_DIR/homepage/config"
mkdir -p "$HOMEPAGE_CONFIG_DIR"

# Определяем путь к Podman socket для текущего пользователя
PODMAN_SOCKET_PATH="/run/user/$CURRENT_UID/podman/podman.sock"

# Проверяем, существует ли socket (должен быть после enable-linger)
if [ ! -S "$PODMAN_SOCKET_PATH" ]; then
    print_warning "Podman socket не найден, активируем linger..."
    sudo loginctl enable-linger "$CURRENT_USER"
    # Ждём создания socket
    sleep 3
fi

# Создаём базовую конфигурацию (как и раньше, но с важным комментарием)
cat > "$HOMEPAGE_CONFIG_DIR/settings.yaml" <<'EOF'
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

# В services.yaml добавим пояснение про Podman
cat > "$HOMEPAGE_CONFIG_DIR/services.yaml" <<'EOF'
---
# Сервисы автоматически обнаруживаются через Podman socket
# Для ручного добавления сервисов используйте формат:
# Service Name:
#   - url: http://localhost:port
#     description: "Описание"
EOF

# Исправленный Quadlet файл - монтируем ПРАВИЛЬНЫЙ socket
cat > "$QUADLET_USER_DIR/homepage.container" <<EOF
[Unit]
Description=Homepage Dashboard
After=network-online.target
Wants=podman-auto-update.service

[Container]
Label=io.containers.autoupdate=registry
Image=ghcr.io/gethomepage/homepage:latest
Volume=$HOMEPAGE_CONFIG_DIR:/app/config:Z
Volume=$PODMAN_SOCKET_PATH:/var/run/docker.sock:ro,Z  # ← ВАЖНО: монтируем podman.sock как docker.sock
PublishPort=3001:3000
Environment=PUID=$CURRENT_UID
Environment=PGID=$CURRENT_UID
Environment=HOMEPAGE_ALLOWED_HOSTS=$(hostname),localhost,127.0.0.1,$SERVER_IP

# Добавляем права доступа к socket
AddCapability=DAC_OVERRIDE

[Service]
Restart=always
TimeoutStopSec=30
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$QUADLET_USER_DIR/homepage.container"

# Перед запуском убеждаемся, что socket существует
if [ ! -S "$PODMAN_SOCKET_PATH" ]; then
    print_error "Podman socket не найден по пути: $PODMAN_SOCKET_PATH"
    print_info "Проверьте: systemctl --user status podman.socket"
else
    systemctl --user daemon-reload
    systemctl --user start homepage.service
    
    sleep 5
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^systemd-homepage$"; then
        print_success "Homepage запущен на порту 3001"
        print_url "http://${SERVER_IP}:3001/"
        HOMEPAGE_READY=1
        
        # Информация о Docker-совместимости
        print_info "Homepage общается с Podman через совместимый API [citation:2]"
    else
        print_error "Ошибка запуска homepage"
        HOMEPAGE_READY=0
    fi
fi

# =============== NETBIRD REVERSE PROXY ===============
print_step "Настройка NetBird Reverse Proxy"

# Функция для получения peer_id
get_netbird_peer_id() {
    local token=$1
    local hostname=$(hostname)
    
    curl -s -H "Authorization: Token $token" \
        "https://api.netbird.io/api/peers" 2>/dev/null | \
        grep -B5 -A5 "\"name\":\"$hostname\"" | \
        grep '"id"' | head -1 | cut -d'"' -f4
}

# Функция для создания reverse proxy
create_netbird_proxy() {
    local name=$1
    local port=$2
    local subdomain=$3
    local token=$4
    local peer_id=$5
    local account=$6
    
    if [ -z "$peer_id" ] || [ -z "$token" ] || [ -z "$account" ]; then
        return 1
    fi
    
    local domain="${subdomain}.${account}.proxy.netbird.io"
    
    # Проверяем существование
    existing=$(curl -s -H "Authorization: Token $token" \
        "https://api.netbird.io/api/services" 2>/dev/null | \
        grep -B3 "\"domain\":\"$domain\"")
    
    if [ -n "$existing" ]; then
        print_info "Прокси для $subdomain уже существует: https://$domain"
        echo "https://$domain" >> "$INFRA_DIR/.netbird_urls.tmp"
        return 0
    fi
    
    # Создаем новый
    response=$(curl -s -X POST "https://api.netbird.io/api/services" \
        -H "Authorization: Token $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$name\",
            \"domain\": \"$domain\",
            \"targets\": [{
                \"type\": \"peer\",
                \"peer_id\": \"$peer_id\",
                \"port\": $port,
                \"protocol\": \"http\"
            }]
        }")
    
    if echo "$response" | grep -q '"id"'; then
        print_success "Прокси создан: https://$domain"
        echo "https://$domain" >> "$INFRA_DIR/.netbird_urls.tmp"
        return 0
    else
        print_error "Ошибка создания прокси для $name"
        return 1
    fi
}

# Запрашиваем токен
if [ ! -f "$INFRA_DIR/.netbird_token" ]; then
    echo ""
    print_info "Для публичных HTTPS ссылок через NetBird требуется API токен"
    print_info "Получите: https://app.netbird.io/api-tokens"
    read -rp "  NetBird API Token: " NB_API_TOKEN
    read -rp "  Account name (abc123 из abc123.proxy.netbird.io): " NB_ACCOUNT
    
    if [ -n "$NB_API_TOKEN" ] && [ -n "$NB_ACCOUNT" ]; then
        echo "$NB_API_TOKEN" > "$INFRA_DIR/.netbird_token"
        echo "$NB_ACCOUNT" > "$INFRA_DIR/.netbird_account"
        chmod 600 "$INFRA_DIR/.netbird_token" "$INFRA_DIR/.netbird_account"
        print_success "Токен сохранен"
    fi
fi

# Создаем прокси
if [ -f "$INFRA_DIR/.netbird_token" ] && [ -f "$INFRA_DIR/.netbird_account" ]; then
    NB_TOKEN=$(cat "$INFRA_DIR/.netbird_token")
    NB_ACCOUNT=$(cat "$INFRA_DIR/.netbird_account")
    
    print_info "Получение идентификатора пира..."
    PEER_ID=$(get_netbird_peer_id "$NB_TOKEN")
    
    if [ -n "$PEER_ID" ]; then
        print_success "Peer ID: $PEER_ID"
        
        > "$INFRA_DIR/.netbird_urls.tmp"
        
        # Создаем прокси для готовых сервисов
        [ "${VAULTWARDEN_READY:-0}" = "1" ] && create_netbird_proxy "vaultwarden" 8080 "vaultwarden" "$NB_TOKEN" "$PEER_ID" "$NB_ACCOUNT"
        [ "${REST_SERVER_READY:-0}" = "1" ] && create_netbird_proxy "restic" 8000 "restic" "$NB_TOKEN" "$PEER_ID" "$NB_ACCOUNT"
        [ "${BACKREST_READY:-0}" = "1" ] && create_netbird_proxy "backrest" 9898 "backrest" "$NB_TOKEN" "$PEER_ID" "$NB_ACCOUNT"
        [ "${HOMEPAGE_READY:-0}" = "1" ] && create_netbird_proxy "homepage" 3001 "homepage" "$NB_TOKEN" "$PEER_ID" "$NB_ACCOUNT"
        
        if [ -f "$INFRA_DIR/.netbird_urls.tmp" ]; then
            sort -u "$INFRA_DIR/.netbird_urls.tmp" > "$INFRA_DIR/.netbird_urls"
            rm -f "$INFRA_DIR/.netbird_urls.tmp"
            print_success "URLs сохранены в $INFRA_DIR/.netbird_urls"
        fi
        
        # Обновляем Vaultwarden domain
        if [ -f "$INFRA_DIR/.netbird_urls" ] && grep -q "vaultwarden" "$INFRA_DIR/.netbird_urls"; then
            VAULT_URL=$(grep "vaultwarden" "$INFRA_DIR/.netbird_urls" | head -1)
            sudo systemctl stop vaultwarden.service
            sudo sed -i "s|Environment=DOMAIN=.*|Environment=DOMAIN=$VAULT_URL|" "$QUADLET_SYSTEM_DIR/vaultwarden.container"
            sudo systemctl daemon-reload
            sudo systemctl start vaultwarden.service
            print_success "Vaultwarden domain обновлен"
        fi
    else
        print_error "Не удалось получить Peer ID"
    fi
fi

# =============== CRON ===============
print_step "Настройка cron"
(crontab -l 2>/dev/null | grep -v "infra" || true; echo "*/5 * * * * $BIN_DIR/infra status > /dev/null 2>&1") | crontab - 2>/dev/null || true

# =============== ИТОГ ===============
print_header "ГОТОВО v11.0.0"

echo -e "${NEON_GREEN}●${RESET} Homepage:     ${NEON_CYAN}http://$SERVER_IP:3001/${RESET} ${NEON_GREEN}(главный дашборд)${RESET}"
echo -e "${NEON_GREEN}●${RESET} Gitea:        ${NEON_CYAN}http://$SERVER_IP:3000/${RESET}"
echo -e "${NEON_GREEN}●${RESET} TorrServer:   ${NEON_CYAN}http://$SERVER_IP:8090/${RESET}"
echo -e "${NEON_GREEN}●${RESET} Vaultwarden:  ${NEON_CYAN}http://$SERVER_IP:8080/${RESET}"
echo -e "${NEON_GREEN}●${RESET} Backrest:     ${NEON_CYAN}http://$SERVER_IP:9898/${RESET}"
echo -e "${NEON_GREEN}●${RESET} Restic Server:${NEON_CYAN}localhost:8000${RESET} (внутренний)"
echo ""
echo -e "${NEON_BLUE}ℹ${RESET} Важные пароли:"
echo -e "   Vaultwarden Admin Token: ${NEON_YELLOW}$(sudo cat /etc/vaultwarden/secrets/admin_token.env 2>/dev/null | cut -d= -f2)${RESET}"
echo -e "   Backrest WebUI: первый вход создайте администратора"
echo -e "   Restic REST: пользователь ${NEON_CYAN}restic${RESET}, пароль в ${NEON_CYAN}/var/lib/rest-server/.restic_pass${RESET}"
echo ""
echo -e "Управление: ${NEON_CYAN}infra status${RESET}"
echo -e "Логи:       ${NEON_CYAN}infra logs <service>${RESET}"
echo -e "Обновление: ${NEON_CYAN}infra update${RESET}"

# =============== САМОУДАЛЕНИЕ ===============
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$BIN_DIR/infra" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/infra" ]; then
    rm -f "$SCRIPT_PATH"
    print_success "Скрипт удалён"
fi
