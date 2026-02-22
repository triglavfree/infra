#!/bin/bash
set -uo pipefail
# =============================================================================
# INFRASTRUCTURE v9.2.2
# =============================================================================
# Исправлено: Ширина box с учетом цветов, дефолтный путь для локального бэкапа
# =============================================================================

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

# =============== ПРОВЕРКА ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
    print_error "Запускайте от обычного пользователя с sudo!"
    exit 1
fi

CURRENT_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"
SERVER_IP=$(hostname -I | awk '{print $1}')

print_header "INFRASTRUCTURE v9.2.2"
print_info "User: $CURRENT_USER | UID: $CURRENT_UID | IP: $SERVER_IP"

# =============== КАТАЛОГИ С ПРАВАМИ ===============
print_step "Создание структуры"

INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BIN_DIR="$INFRA_DIR/bin"
LOGS_DIR="$INFRA_DIR/logs"
BACKUP_DIR="$INFRA_DIR/backups"

for dir in "$INFRA_DIR" "$VOLUMES_DIR" "$BIN_DIR" "$LOGS_DIR" "$BACKUP_DIR" "$BACKUP_DIR/cache" \
           "$VOLUMES_DIR"/{gitea,torrserver}; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$CURRENT_USER:$CURRENT_USER" "$dir"
        chmod 755 "$dir"
    fi
done
print_success "Директории созданы с правами $CURRENT_USER"

# =============== BOOTSTRAP ===============
print_step "Подготовка системы"

if [ ! -f "$INFRA_DIR/.bootstrap_done" ]; then
    sudo bash -c "
        modprobe wireguard 2>/dev/null || true
        echo wireguard > /etc/modules-load.d/wireguard.conf 2>/dev/null || true
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq podman podman-docker uidmap slirp4netns fuse-overlayfs curl openssl >/dev/null 2>&1 || true
        
        if ! grep -q '$CURRENT_USER:' /etc/subuid 2>/dev/null; then
            usermod --add-subuids 100000-165535 --add-subgids 100000-165535 '$CURRENT_USER' 2>/dev/null || true
        fi
        
        mkdir -p /run/user/$CURRENT_UID
        chown $CURRENT_USER:$CURRENT_USER /run/user/$CURRENT_UID
        chmod 700 /run/user/$CURRENT_UID
        
        mkdir -p /var/lib/gitea-runner /var/lib/netbird
        chmod 755 /var/lib/gitea-runner /var/lib/netbird
    "
    touch "$INFRA_DIR/.bootstrap_done"
    print_success "Система настроена"
else
    print_info "Bootstrap уже выполнен"
fi

sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true

# =============== CLI ===============
printf '%s' '#!/bin/bash
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BACKUP_DIR="$INFRA_DIR/backups"

# Цвета
NEON_GREEN='\''\033[38;5;84m'\'' 
NEON_RED='\''\033[38;5;203m'\''
NEON_YELLOW='\''\033[38;5;220m'\''
NEON_CYAN='\''\033[38;5;81m'\''
NEON_PURPLE='\''\033[38;5;141m'\''
NEON_BLUE='\''\033[38;5;75m'\''
SOFT_WHITE='\''\033[38;5;252m'\''
MUTED_GRAY='\''\033[38;5;245m'\''
DIM_GRAY='\''\033[38;5;240m'\''
BOLD='\''\033[1m'\''
RESET='\''\033[0m'\''

# Символы
ICON_OK="${NEON_GREEN}●${RESET}"
ICON_FAIL="${NEON_RED}●${RESET}"
ICON_WARN="${NEON_YELLOW}●${RESET}"
ICON_INFO="${NEON_BLUE}●${RESET}"
ICON_ARROW="▸"

# Функция для вычисления видимой длины строки (без escape-последовательностей)
visible_length() {
    local str="$1"
    # Удаляем все escape-последовательности
    echo -n "$str" | sed '\''s/\x1b\[[0-9;]*m//g'\'' | wc -c
}

print_box() {
    local title="$1"
    local time_str="$(date +%H:%M:%S)"
    local full_title="${title} ${time_str}"
    local width=50
    
    # Вычисляем видимую длину
    local vis_len=$(visible_length "$full_title")
    local padding=$((width - vis_len))
    [ $padding -lt 0 ] && padding=0
    
    local line=$(printf '\''═%.0s'\'' $(seq 1 $width))
    
    echo ""
    echo -e "${NEON_CYAN}╔${line}╗${RESET}"
    printf "${NEON_CYAN}║${RESET} ${BOLD}%s${RESET}%*s${NEON_CYAN}║${RESET}\n" "$full_title" "$padding" " "
    echo -e "${NEON_CYAN}╚${line}╝${RESET}"
}

print_section() {
    echo ""
    echo -e "${NEON_PURPLE}${ICON_ARROW}${RESET} ${BOLD}$1${RESET}"
    echo -e "${DIM_GRAY}$(printf '\''─%.0s'\'' $(seq 1 48))${RESET}"
}

print_metric() {
    printf "  ${DIM_GRAY}%-12s${RESET} %s\n" "$1" "$2"
}

get_container_status() {
    local name=$1
    local user=$2
    local runtime=""
    
    if [ "$user" = "root" ]; then
        runtime="sudo podman"
    else
        runtime="podman"
    fi
    
    if $runtime ps --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
        local health=$($runtime inspect --format='\''{{.State.Health.Status}}'\'' "$name" 2>/dev/null || echo "no-check")
        local uptime=$($runtime inspect --format='\''{{.State.StartedAt}}'\'' "$name" 2>/dev/null | xargs -I {} date -d "{}" +%s 2>/dev/null || echo "0")
        local now=$(date +%s)
        local diff=$((now - uptime))
        local uptime_str=""
        
        if [ $diff -lt 60 ]; then
            uptime_str="${diff}s"
        elif [ $diff -lt 3600 ]; then
            uptime_str="$((diff / 60))m"
        else
            uptime_str="$((diff / 3600))h$((diff % 3600 / 60))m"
        fi
        
        if [ "$health" = "healthy" ] || [ "$health" = "no-check" ]; then
            echo -e "${ICON_OK} ${NEON_GREEN}running${RESET} ${DIM_GRAY}(${uptime_str})${RESET}"
        else
            echo -e "${ICON_WARN} ${NEON_YELLOW}unhealthy${RESET} ${DIM_GRAY}(${uptime_str})${RESET}"
        fi
    else
        if $runtime ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
            echo -e "${ICON_FAIL} ${NEON_RED}stopped${RESET}"
        else
            echo -e "${DIM_GRAY}● not created${RESET}"
        fi
    fi
}

get_service_status() {
    local name=$1
    local user=$2
    
    if [ "$user" = "root" ]; then
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        elif systemctl is-failed --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_FAIL} ${NEON_RED}failed${RESET}"
        else
            echo -e "${DIM_GRAY}● inactive${RESET}"
        fi
    else
        if systemctl --user is-active --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_OK} ${NEON_GREEN}active${RESET}"
        elif systemctl --user is-failed --quiet "$name" 2>/dev/null; then
            echo -e "${ICON_FAIL} ${NEON_RED}failed${RESET}"
        else
            echo -e "${DIM_GRAY}● inactive${RESET}"
        fi
    fi
}

status_cmd() {
    clear
    print_box "INFRASTRUCTURE STATUS"
    
    # === ROOTLESS SERVICES ===
    print_section "Rootless Services (User: $USER)"
    
    local gitea_svc=$(get_service_status "gitea" "user")
    local gitea_ctr=$(get_container_status "gitea" "user")
    print_metric "Gitea" "$gitea_svc $gitea_ctr"
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^gitea$"; then
        local gitea_port=$(podman port gitea 2>/dev/null | grep "3000/tcp" | cut -d: -f2 || echo "3000")
        local gitea_ssh=$(podman port gitea 2>/dev/null | grep "22/tcp" | cut -d: -f2 || echo "2222")
        print_metric "" "${MUTED_GRAY}http://$(hostname -I | awk '\''{print $1}'\''):${gitea_port} | ssh://$(hostname -I | awk '\''{print $1}'\''):${gitea_ssh}${RESET}"
    fi
    
    local torr_svc=$(get_service_status "torrserver" "user")
    local torr_ctr=$(get_container_status "torrserver" "user")
    print_metric "TorrServer" "$torr_svc $torr_ctr"
    if podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^torrserver$"; then
        local torr_port=$(podman port torrserver 2>/dev/null | grep "8090/tcp" | cut -d: -f2 || echo "8090")
        print_metric "" "${MUTED_GRAY}http://$(hostname -I | awk '\''{print $1}'\''):${torr_port}${RESET}"
    fi
    
    # === ROOTFUL SERVICES ===
    print_section "Rootful Services (System)"
    
    local runner_svc=$(get_service_status "gitea-runner" "root")
    local runner_ctr=$(get_container_status "gitea-runner" "root")
    print_metric "Gitea Runner" "$runner_svc $runner_ctr"
    if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^gitea-runner$"; then
        local runner_reg=$(sudo podman inspect --format='\''{{range .Config.Env}}{{if eq (index (split . "=") 0) "GITEA_INSTANCE_URL"}}{{index (split . "=") 1}}{{end}}{{end}}'\'' gitea-runner 2>/dev/null | cut -d/ -f3 || echo "unknown")
        print_metric "" "${MUTED_GRAY}→ $runner_reg${RESET}"
    fi
    
    local netbird_svc=$(get_service_status "netbird" "root")
    local netbird_ctr=$(get_container_status "netbird" "root")
    print_metric "NetBird VPN" "$netbird_svc $netbird_ctr"
    if sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^netbird$"; then
        local nb_ip=$(sudo podman exec netbird ip addr show wt0 2>/dev/null | grep "inet " | awk '\''{print $2}'\'' | cut -d/ -f1 || echo "connecting...")
        [ "$nb_ip" != "connecting..." ] && print_metric "" "${MUTED_GRAY}IP: $nb_ip${RESET}" || print_metric "" "${NEON_YELLOW}Connecting...${RESET}"
    fi
    
    # === RESOURCES ===
    print_section "Resources"
    
    local disk_usage=$(df -h "$INFRA_DIR" 2>/dev/null | tail -1 | awk '\''{print $3 "/" $2 " (" $5 ")"}'\'' || echo "N/A")
    print_metric "Disk" "$disk_usage"
    
    local mem_info=$(free -h 2>/dev/null | awk '\''/^Mem:/ {print $3 "/" $2}'\'' || echo "N/A")
    print_metric "Memory" "$mem_info"
    
    local ctr_count=$(podman ps -q 2>/dev/null | wc -l)
    local ctr_total=$(podman ps -aq 2>/dev/null | wc -l)
    local root_ctr_count=$(sudo podman ps -q 2>/dev/null | wc -l)
    local root_ctr_total=$(sudo podman ps -aq 2>/dev/null | wc -l)
    print_metric "Containers" "${SOFT_WHITE}user:${RESET} ${NEON_CYAN}${ctr_count}${RESET}/${ctr_total} ${SOFT_WHITE}root:${RESET} ${NEON_CYAN}${root_ctr_count}${RESET}/${root_ctr_total}"
    
    # === BACKUP STATUS ===
    print_section "Backup"
    
    if [ -f "$INFRA_DIR/.backup_configured" ]; then
        local last_backup="never"
        if [ -f "$INFRA_DIR/logs/backup.log" ]; then
            last_backup=$(grep "Бэкап завершён" "$INFRA_DIR/logs/backup.log" | tail -1 | awk '\''{print $1 " " $2}'\'' || echo "never")
            [ -z "$last_backup" ] && last_backup="never"
        fi
        
        local backup_count=0
        if [ -f "$INFRA_DIR/.backup_env" ]; then
            source "$INFRA_DIR/.backup_env"
            backup_count=$(podman run --rm -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" -e RESTIC_PASSWORD="$RESTIC_PASSWORD" -v "$BACKUP_DIR/cache:/cache" docker.io/restic/restic:latest snapshots --cache-dir=/cache 2>/dev/null | grep -c "^[0-9a-f]" || echo "0")
        fi
        
        print_metric "Status" "${ICON_OK} ${NEON_GREEN}configured${RESET}"
        print_metric "Last" "$last_backup"
        print_metric "Snapshots" "$backup_count"
    else
        print_metric "Status" "${DIM_GRAY}● not configured${RESET}"
        print_metric "Setup" "${MUTED_GRAY}infra backup-setup${RESET}"
    fi
    
    # === QUICK ACTIONS ===
    echo ""
    echo -e "${DIM_GRAY}$(printf '\''─%.0s'\'' $(seq 1 48))${RESET}"
    echo -e "${MUTED_GRAY}Commands: ${NEON_CYAN}start${RESET}|${NEON_CYAN}stop${RESET}|${NEON_CYAN}restart <svc>${RESET}|${NEON_CYAN}logs <svc>${RESET}|${NEON_CYAN}backup${RESET}|${NEON_CYAN}clear${RESET}"
}

case "${1:-status}" in
    status)
        status_cmd
        ;;
    logs)
        [ "$2" = "netbird" ] && sudo journalctl -u netbird -f || journalctl --user -u "$2" -f
        ;;
    stop)
        echo -e "${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
        systemctl --user stop gitea torrserver 2>/dev/null && echo -e "  ${ICON_OK} Gitea/TorrServer" || echo -e "  ${DIM_GRAY}○ Gitea/TorrServer${RESET}"
        sudo systemctl stop gitea-runner netbird 2>/dev/null && echo -e "  ${ICON_OK} Runner/NetBird" || echo -e "  ${DIM_GRAY}○ Runner/NetBird${RESET}"
        ;;
    start)
        echo -e "${NEON_GREEN}▸ Запуск сервисов...${RESET}"
        systemctl --user start gitea torrserver 2>/dev/null && echo -e "  ${ICON_OK} Gitea/TorrServer" || echo -e "  ${ICON_FAIL} Gitea/TorrServer"
        sudo systemctl start gitea-runner netbird 2>/dev/null && echo -e "  ${ICON_OK} Runner/NetBird" || echo -e "  ${ICON_FAIL} Runner/NetBird"
        ;;
    restart)
        echo -e "${NEON_CYAN}▸ Перезапуск $2...${RESET}"
        if [ "$2" = "netbird" ] || [ "$2" = "gitea-runner" ]; then
            sudo systemctl restart "$2" && echo -e "  ${ICON_OK} $2 перезапущен" || echo -e "  ${ICON_FAIL} Ошибка"
        else
            systemctl --user restart "$2" && echo -e "  ${ICON_OK} $2 перезапущен" || echo -e "  ${ICON_FAIL} Ошибка"
        fi
        ;;
    clear)
        echo -e "${NEON_RED}▸ УДАЛЕНИЕ ВСЕЙ ИНФРАСТРУКТУРЫ${RESET}"
        read -rp "  Вы уверены? Все данные будут удалены [yes/N]: " CONFIRM
        if [ "$CONFIRM" = "yes" ]; then
            echo -e "  ${NEON_YELLOW}▸ Остановка сервисов...${RESET}"
            
            systemctl --user stop gitea torrserver 2>/dev/null || true
            echo -e "    ${ICON_OK} User сервисы остановлены"
            
            sudo systemctl stop gitea-runner netbird 2>/dev/null || true
            sudo systemctl disable gitea-runner netbird 2>/dev/null || true
            echo -e "    ${ICON_OK} Rootful сервисы остановлены"
            
            echo -e "  ${NEON_YELLOW}▸ Удаление контейнеров...${RESET}"
            
            podman rm -f gitea torrserver 2>/dev/null || true
            echo -e "    ${ICON_OK} User контейнеры удалены"
            
            sudo podman rm -f gitea-runner netbird 2>/dev/null || true
            echo -e "    ${ICON_OK} Rootful контейнеры удалены"
            
            echo -e "  ${NEON_YELLOW}▸ Удаление образов...${RESET}"
            podman rmi -f $(podman images -q) 2>/dev/null || true
            sudo podman rmi -f $(sudo podman images -q) 2>/dev/null || true
            echo -e "    ${ICON_OK} Образы удалены"
            
            echo -e "  ${NEON_YELLOW}▸ Очистка Podman...${RESET}"
            podman system prune -f 2>/dev/null || true
            sudo podman system prune -f 2>/dev/null || true
            echo -e "    ${ICON_OK} Podman очищен"
            
            echo -e "  ${NEON_YELLOW}▸ Удаление systemd units...${RESET}"
            rm -f ~/.config/systemd/user/gitea.service ~/.config/systemd/user/torrserver.service
            sudo rm -f /etc/systemd/system/gitea-runner.service /etc/systemd/system/netbird.service
            systemctl --user daemon-reload
            sudo systemctl daemon-reload
            echo -e "    ${ICON_OK} Units удалены"
            
            echo -e "  ${NEON_YELLOW}▸ Удаление cron задач...${RESET}"
            ( crontab -l 2>/dev/null | grep -v "infra" | grep -v "restic" || true ) | crontab - 2>/dev/null || true
            echo -e "    ${ICON_OK} Cron очищен"
            
            read -rp "  Удалить директорию $INFRA_DIR с данными? [y/N]: " DEL_DATA
            if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
                echo -e "  ${NEON_YELLOW}▸ Удаление данных...${RESET}"
                rm -rf "$INFRA_DIR"
                sudo rm -rf /var/lib/gitea-runner /var/lib/netbird
                echo -e "    ${ICON_OK} Данные удалены"
            else
                echo -e "  ${ICON_INFO} Директория сохранена: $INFRA_DIR"
            fi
            
            echo -e "  ${NEON_YELLOW}▸ Удаление CLI...${RESET}"
            sudo rm -f /usr/local/bin/infra
            
            echo ""
            echo -e "${NEON_GREEN}${BOLD}╔════════════════════════════════════════════════╗${RESET}"
            echo -e "${NEON_GREEN}${BOLD}║     ИНФРАСТРУКТУРА ПОЛНОСТЬЮ УДАЛЕНА           ║${RESET}"
            echo -e "${NEON_GREEN}${BOLD}╚════════════════════════════════════════════════╝${RESET}"
        else
            echo -e "${NEON_YELLOW}Отменено${RESET}"
        fi
        ;;
    backup)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then
            echo -e "${ICON_FAIL} Бэкап не настроен. Запустите: ${NEON_CYAN}infra backup-setup${RESET}"
            exit 1
        fi
        
        source "$INFRA_DIR/.backup_env"
        
        # Проверяем наличие cache директории
        mkdir -p "$BACKUP_DIR/cache"
        
        echo -e "${NEON_CYAN}▸ Создание бэкапа $(date +%Y-%m-%d %H:%M:%S)...${RESET}"
        
        # Создаём снапшот volumes через tar перед бэкапом
        mkdir -p "$BACKUP_DIR/snapshots"
        SNAPSHOT="$BACKUP_DIR/snapshots/infra-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$SNAPSHOT" -C "$VOLUMES_DIR" . 2>/dev/null || true
        
        # Запускаем restic backup с проверкой ошибок
        if ! podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$INFRA_DIR:/data:ro" \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            backup /data --exclude=/data/backups --cache-dir=/cache 2>&1 | tee -a "$INFRA_DIR/logs/backup.log"; then
            
            echo -e "  ${ICON_FAIL} ${NEON_RED}Ошибка бэкапа${RESET}"
            rm -f "$SNAPSHOT" 2>/dev/null
            exit 1
        fi
        
        # Очистка старых снапшотов (оставляем последние 3)
        ls -t "$BACKUP_DIR/snapshots"/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
        
        # Prune старых бэкапов restic (оставляем последние 7 дней)
        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            forget --keep-daily 7 --prune --cache-dir=/cache 2>/dev/null || true
        
        echo -e "  ${ICON_OK} ${NEON_GREEN}Бэкап завершён${RESET}"
        ;;
    backup-setup)
        echo -e "${NEON_CYAN}▸ Настройка бэкапов (Restic)${RESET}"
        echo ""
        echo "  Выберите backend:"
        echo -e "  ${NEON_CYAN}1)${RESET} Локальная директория"
        echo -e "  ${NEON_CYAN}2)${RESET} SFTP (user@host:/path)"
        echo -e "  ${NEON_CYAN}3)${RESET} S3 (s3:s3.amazonaws.com/bucket)"
        echo -e "  ${NEON_CYAN}4)${RESET} rclone (rclone:remote:path)"
        read -rp "  Backend [1-4]: " BACKEND_TYPE
        
        case "$BACKEND_TYPE" in
            1) 
                read -rp "  Путь для бэкапов [по умолчанию: /backup/infra]: " REPO_PATH
                # Дефолтное значение если пустой ввод
                REPO_PATH="${REPO_PATH:-/backup/infra}"
                REPO="local:$REPO_PATH" 
                ;;
            2) 
                read -rp "  SFTP адрес (user@host:/path): " REPO_PATH
                REPO="sftp:$REPO_PATH" 
                ;;
            3) 
                read -rp "  S3 endpoint (s3:host:port/bucket): " REPO_PATH
                REPO="$REPO_PATH"
                read -rp "  AWS_ACCESS_KEY_ID: " AWS_KEY
                read -rp "  AWS_SECRET_ACCESS_KEY: " AWS_SECRET 
                ;;
            4) 
                read -rp "  rclone remote (rclone:remote:path): " REPO_PATH
                REPO="$REPO_PATH" 
                ;;
            *) 
                echo -e "  ${ICON_FAIL} Неверный выбор" 
                exit 1 
                ;;
        esac
        
        read -rsp "  Пароль для шифрования бэкапов: " RESTIC_PASS
        echo ""
        
        # Проверка и дефолтное значение для cron
        read -rp "  Время автобэкапа [по умолчанию: 0 2 * * *]: " CRON_TIME
        CRON_TIME="${CRON_TIME:-0 2 * * *}"
        
        # Валидация cron (простая проверка на 5 полей)
        if [ $(echo "$CRON_TIME" | wc -w) -ne 5 ]; then
            echo -e "  ${ICON_WARN} Неверный формат cron. Используется значение по умолчанию: 0 2 * * *"
            CRON_TIME="0 2 * * *"
        fi
        
        # Создаём cache директорию заранее
        mkdir -p "$BACKUP_DIR/cache"
        
        # Сохраняем конфиг
        cat > "$INFRA_DIR/.backup_env" <<EOENV
RESTIC_REPOSITORY=$REPO
RESTIC_PASSWORD=$RESTIC_PASS
EOENV
        [ -n "${AWS_KEY:-}" ] && echo "AWS_ACCESS_KEY_ID=$AWS_KEY" >> "$INFRA_DIR/.backup_env"
        [ -n "${AWS_SECRET:-}" ] && echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET" >> "$INFRA_DIR/.backup_env"
        chmod 600 "$INFRA_DIR/.backup_env"
        
        # Создаём директорию для локального бэкапа если нужно
        if [[ "$REPO" == local:* ]]; then
            LOCAL_PATH="${REPO#local:}"
            if [ ! -d "$LOCAL_PATH" ]; then
                echo -e "  ${NEON_CYAN}▸ Создание директории $LOCAL_PATH...${RESET}"
                sudo mkdir -p "$LOCAL_PATH"
                sudo chown "$USER:$USER" "$LOCAL_PATH" 2>/dev/null || true
            fi
        fi
        
        # Инициализация репозитория
        echo -e "  ${NEON_CYAN}▸ Инициализация репозитория...${RESET}"
        if podman run --rm \
            -e RESTIC_REPOSITORY="$REPO" \
            -e RESTIC_PASSWORD="$RESTIC_PASS" \
            ${AWS_KEY:+-e AWS_ACCESS_KEY_ID="$AWS_KEY"} \
            ${AWS_SECRET:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET"} \
            -v "$BACKUP_DIR/cache:/cache" \
            ${LOCAL_PATH:+-v "$LOCAL_PATH:$LOCAL_PATH:Z"} \
            docker.io/restic/restic:latest \
            init --cache-dir=/cache 2>/dev/null; then
            
            echo -e "  ${ICON_OK} ${NEON_GREEN}Репозиторий инициализирован${RESET}"
        else
            echo -e "  ${ICON_WARN} Репозиторий уже существует или ошибка инициализации"
        fi
        
        touch "$INFRA_DIR/.backup_configured"
        
        # Добавляем в cron
        ( crontab -l 2>/dev/null | grep -v "infra backup" || true; echo "$CRON_TIME $INFRA_DIR/bin/infra backup >> $INFRA_DIR/logs/backup.log 2>&1" ) | crontab -
        
        echo -e "  ${ICON_OK} ${NEON_GREEN}Бэкап настроен${RESET}"
        echo -e "  ${MUTED_GRAY}Репозиторий: $REPO${RESET}"
        echo -e "  ${MUTED_GRAY}Расписание: $CRON_TIME${RESET}"
        echo -e "  ${MUTED_GRAY}Тест: infra backup${RESET}"
        ;;
    backup-list)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then
            echo -e "${ICON_FAIL} Бэкап не настроен"
            exit 1
        fi
        source "$INFRA_DIR/.backup_env"
        echo -e "${NEON_CYAN}▸ Снапшоты:${RESET}"
        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            snapshots --cache-dir=/cache
        ;;
    backup-restore)
        if [ ! -f "$INFRA_DIR/.backup_configured" ]; then
            echo -e "${ICON_FAIL} Бэкап не настроен"
            exit 1
        fi
        source "$INFRA_DIR/.backup_env"
        
        echo -e "${NEON_CYAN}▸ Доступные снапшоты:${RESET}"
        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            snapshots --cache-dir=/cache
        
        echo ""
        read -rp "  ID снапшота [по умолчанию: latest]: " SNAP_ID
        SNAP_ID="${SNAP_ID:-latest}"
        read -rp "  Куда восстановить [$INFRA_DIR]: " TARGET
        TARGET="${TARGET:-$INFRA_DIR}"
        
        read -rp "  Остановить сервисы перед восстановлением? [Y/n]: " STOP_SERV
        if [[ ! "${STOP_SERV:-Y}" =~ ^[Nn]$ ]]; then
            systemctl --user stop gitea torrserver 2>/dev/null || true
            sudo systemctl stop gitea-runner netbird 2>/dev/null || true
            echo -e "  ${ICON_OK} Сервисы остановлены"
        fi
        
        echo -e "  ${NEON_CYAN}▸ Восстановление $SNAP_ID в $TARGET...${RESET}"
        podman run --rm \
            -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
            -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            ${AWS_ACCESS_KEY_ID:+-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"} \
            ${AWS_SECRET_ACCESS_KEY:+-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"} \
            -v "$TARGET:/restore:Z" \
            -v "$BACKUP_DIR/cache:/cache" \
            docker.io/restic/restic:latest \
            restore "$SNAP_ID" --target /restore --cache-dir=/cache
        
        echo -e "  ${ICON_OK} ${NEON_GREEN}Восстановление завершено${RESET}"
        ;;
    *)
        echo "Использование: infra {status|start|stop|restart <svc>|logs <svc>|clear|backup|backup-setup|backup-list|backup-restore}"
        ;;
esac
' > "$BIN_DIR/infra"

chmod +x "$BIN_DIR/infra"
sudo ln -sf "$BIN_DIR/infra" /usr/local/bin/infra 2>/dev/null || true

# =============== GITEA ROOTLESS ===============
print_step "Создание Gitea (rootless)"

mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/gitea.service <<EOF
[Unit]
Description=Gitea
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f gitea
ExecStart=/usr/bin/podman run --name gitea --rm \
    -v $CURRENT_HOME/infra/volumes/gitea:/data:Z \
    -e GITEA__server__ROOT_URL=http://$SERVER_IP:3000/ \
    -e GITEA__actions__ENABLED=true \
    -p 3000:3000 -p 2222:22 \
    docker.io/gitea/gitea:latest
ExecStop=/usr/bin/podman stop -t 10 gitea

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/gitea.service

systemctl --user daemon-reload
systemctl --user start gitea.service && print_success "Gitea запущена" || print_warning "Возможна ошибка запуска"

print_info "Ждём инициализацию (15 сек)..."
sleep 15

if curl -sf --max-time 5 "http://$SERVER_IP:3000/api/v1/version" >/dev/null 2>&1; then
    print_success "Gitea API доступен"
    GITEA_READY=1
else
    print_warning "Gitea API не отвечает (возможно ещё инициализируется)"
    GITEA_READY=0
fi

# =============== TORRSERVER ROOTLESS ===============
print_step "Создание TorrServer (rootless)"

cat > ~/.config/systemd/user/torrserver.service <<EOF
[Unit]
Description=TorrServer
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f torrserver
ExecStart=/usr/bin/podman run --name torrserver --rm \
    -v $CURRENT_HOME/infra/volumes/torrserver:/app/z:Z \
    -p 8090:8090 \
    ghcr.io/yourok/torrserver:latest
ExecStop=/usr/bin/podman stop -t 10 torrserver

[Install]
WantedBy=default.target
EOF

chown "$CURRENT_USER:$CURRENT_USER" ~/.config/systemd/user/torrserver.service

systemctl --user daemon-reload
systemctl --user start torrserver.service && print_success "TorrServer запущен" || print_warning "Возможна ошибка запуска"

# =============== RUNNER ROOTFUL ===============
print_step "Настройка Gitea Runner (rootful)"

SKIP_RUNNER=0
if [ -f /etc/systemd/system/gitea-runner.service ]; then
    print_info "Runner уже существует"
    read -rp "  Пересоздать? [y/N]: " RECREATE
    if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
        sudo systemctl stop gitea-runner 2>/dev/null || true
        sudo rm -f /etc/systemd/system/gitea-runner.service
    else
        SKIP_RUNNER=1
    fi
fi

if [ $SKIP_RUNNER -eq 0 ]; then
    echo ""
    echo -e "${NEON_PURPLE}${BOLD}▸ РЕГИСТРАЦИЯ RUNNER'А${RESET}"
    echo ""
    [ $GITEA_READY -eq 1 ] && echo -e "  ${NEON_GREEN}✓ Gitea готова!${RESET}" || echo -e "  ${NEON_YELLOW}⚡ Gitea может быть ещё инициализируется${RESET}"
    echo -e "  Откройте: ${NEON_CYAN}http://$SERVER_IP:3000/-/admin/actions/runners${RESET}"
    echo ""
    
    read -rp "  Registration Token: " RUNNER_TOKEN
    
    if [ -n "$RUNNER_TOKEN" ]; then
        sudo tee /etc/systemd/system/gitea-runner.service > /dev/null <<EOF
[Unit]
Description=Gitea Runner
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f gitea-runner
ExecStart=/usr/bin/podman run --name gitea-runner --rm \
    --privileged \
    -v /var/run/docker.sock:/var/run/docker.sock:Z \
    -v /var/lib/gitea-runner:/data:Z \
    -e GITEA_INSTANCE_URL=http://$SERVER_IP:3000 \
    -e GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN \
    -e GITEA_RUNNER_NAME=runner-$(hostname | cut -d. -f1) \
    docker.io/gitea/act_runner:nightly
ExecStop=/usr/bin/podman stop -t 10 gitea-runner

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable gitea-runner.service 2>/dev/null || true
        
        if sudo systemctl start gitea-runner.service; then
            print_success "Runner запущен"
            sleep 8
            if sudo podman ps --format "{{.Names}}" | grep -q "^gitea-runner$"; then
                print_info "Логи runner:"
                sudo podman logs gitea-runner 2>&1 | tail -3
            fi
        else
            print_error "Ошибка запуска runner"
        fi
    else
        print_info "Runner пропущен"
    fi
fi

# =============== NETBIRD ROOTFUL ===============
print_step "Настройка NetBird (rootful)"

if sudo systemctl is-active --quiet netbird.service 2>/dev/null; then
    print_success "NetBird уже запущен"
else
    echo ""
    echo -e "${NEON_BLUE}${BOLD}▸ ПОДКЛЮЧЕНИЕ NETBIRD${RESET}"
    echo ""
    read -rp "  Setup Key (Enter - пропустить): " NB_KEY
    
    if [ -n "${NB_KEY:-}" ]; then
        sudo tee /etc/systemd/system/netbird.service > /dev/null <<EOF
[Unit]
Description=NetBird VPN
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStartPre=-/usr/bin/podman rm -f netbird
ExecStart=/usr/bin/podman run --name netbird --rm \
    --privileged \
    --network host \
    --device /dev/net/tun:/dev/net/tun \
    -v /var/lib/netbird:/etc/netbird:Z \
    -e NB_SETUP_KEY=$NB_KEY \
    -e NB_MANAGEMENT_URL=https://api.netbird.io:443  \
    docker.io/netbirdio/netbird:latest
ExecStop=/usr/bin/podman stop -t 10 netbird

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable netbird.service 2>/dev/null || true
        
        if sudo systemctl start netbird.service; then
            print_success "NetBird запущен"
            sleep 8
            if sudo podman ps --format "{{.Names}}" | grep -q "^netbird$"; then
                print_info "Логи NetBird:"
                sudo podman logs netbird 2>&1 | tail -3
            fi
        else
            print_error "Ошибка NetBird"
        fi
    else
        print_info "NetBird пропущен"
    fi
fi

# =============== CRON ===============
print_step "Настройка cron"
( crontab -l 2>/dev/null | grep -v "infra" || true; echo "*/5 * * * * $BIN_DIR/infra status > /dev/null 2>&1 || true" ) | crontab - 2>/dev/null || true

# =============== ИТОГ ===============
print_header "ГОТОВО"
echo -e "${NEON_GREEN}●${RESET} Gitea:      ${NEON_CYAN}http://$SERVER_IP:3000${RESET}"
echo -e "${NEON_GREEN}●${RESET} TorrServer: ${NEON_CYAN}http://$SERVER_IP:8090${RESET}"
echo -e "\nУправление: ${NEON_CYAN}infra status|start|stop|logs <сервис>${RESET}"
echo -e "Очистка:    ${NEON_CYAN}infra clear${RESET}"
echo -e "Бэкап:      ${NEON_CYAN}infra backup-setup${RESET} → ${NEON_CYAN}infra backup${RESET}"
echo -e "Директория: ${NEON_CYAN}$INFRA_DIR${RESET} (владелец: $CURRENT_USER)"
