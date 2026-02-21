#!/bin/bash
set -euo pipefail
# ============================================================================
# infra.sh — автономный развёртыватель инфраструктуры (v4.1.1)
# ============================================================================
# Исправления v4.1.1:
#   • create_quadlet: heredoc читается через $(cat), не $2
#   • bootstrap.sh: подключает common.sh для print_* функций
#   • Telegram API URL: убраны пробелы в healthcheck.sh
#   • RESTIC_REPOSITORY: убраны trailing spaces
#   • Gitea runner: проверка пустого токена
#   • WireGuard: авто-определение сетевого интерфейса
#   • Healthcheck: добавлена проверка Caddy
#   • Restic: добавлен --one-file-system для безопасности
# ============================================================================
# =============== ЦВЕТОВАЯ СХЕМА ===============
DARK_GRAY='\033[38;5;242m'
SOFT_BLUE='\033[38;5;67m'
SOFT_GREEN='\033[38;5;71m'
SOFT_YELLOW='\033[38;5;178m'
SOFT_RED='\033[38;5;167m'
MEDIUM_GRAY='\033[38;5;246m'
LIGHT_GRAY='\033[38;5;250m'
BOLD='\033[1m'
RESET='\033[0m'
print_step() {
echo -e "
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}${SOFT_BLUE}▸ ${1}${RESET}"
echo -e "${DARK_GRAY}───────────────────────────────────────────────────────────────────────────────${RESET}
"
}
print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error()   { echo -e "
${SOFT_RED}✗${RESET} ${BOLD}${1}${RESET}
" >&2; exit 1; }
print_info()    { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }
print_substep() { echo -e "${MEDIUM_GRAY}  →${RESET} ${1}"; }
# =============== ОПРЕДЕЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
print_error "Запускайте от обычного пользователя (не от root напрямую)!"
fi
CURRENT_USER="${SUDO_USER:-$(whoami)}"
CURRENT_HOME="${HOME:-$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)}"
if ! getent passwd "$CURRENT_USER" >/dev/null 2>&1; then
print_error "Пользователь '$CURRENT_USER' не найден!"
fi
if [ ! -d "$CURRENT_HOME" ]; then
REAL_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
print_warning "Домашняя директория $CURRENT_HOME не существует. Используем: $REAL_HOME"
CURRENT_HOME="$REAL_HOME"
fi
# =============== РЕЖИМЫ РАБОТЫ ===============
RESTORE_MODE=false
if [[ "${1:-}" == "--restore" ]]; then
RESTORE_MODE=true
shift
fi
print_step "Подготовка инфраструктуры для: $CURRENT_USER"
print_info "Домашняя директория: $CURRENT_HOME"
# =============== СТРУКТУРА КАТАЛОГОВ ===============
INFRA_DIR="$CURRENT_HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
SECRETS_DIR="$INFRA_DIR/secrets"
BOOTSTRAP_DIR="$INFRA_DIR/bootstrap"
BIN_DIR="$INFRA_DIR/bin"
CONTAINERS_DIR="$INFRA_DIR/containers"
DOCS_DIR="$INFRA_DIR/docs"
BACKUPS_DIR="$INFRA_DIR/backups"
LOGS_DIR="$INFRA_DIR/logs"
for dir in "$INFRA_DIR" "$VOLUMES_DIR" "$SECRETS_DIR" "$BOOTSTRAP_DIR" "$BIN_DIR" "$CONTAINERS_DIR" "$DOCS_DIR" "$BACKUPS_DIR" "$LOGS_DIR"; do
install -d -m 755 -o "$CURRENT_USER" -g "$CURRENT_USER" "$dir" 2>/dev/null || mkdir -p "$dir"
done
chmod 700 "$SECRETS_DIR"
# =============== ГЕНЕРАЦИЯ ФАЙЛОВ ===============
# 1. Общие функции
cat > "$BOOTSTRAP_DIR/common.sh" <<'EOF'
DARK_GRAY='\033[38;5;242m'; SOFT_BLUE='\033[38;5;67m'; SOFT_GREEN='\033[38;5;71m'
SOFT_YELLOW='\033[38;5;178m'; SOFT_RED='\033[38;5;167m'; MEDIUM_GRAY='\033[38;5;246m'
LIGHT_GRAY='\033[38;5;250m'; BOLD='\033[1m'; RESET='\033[0m'
print_step() { echo -e "
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; echo -e "${BOLD}${SOFT_BLUE}▸ ${1}${RESET}"; echo -e "${DARK_GRAY}───────────────────────────────────────────────────────────────────────────────${RESET}
"; }
print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error()   { echo -e "
${SOFT_RED}✗${RESET} ${BOLD}${1}${RESET}
" >&2; exit 1; }
print_info()    { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }
print_substep() { echo -e "${MEDIUM_GRAY}  →${RESET} ${1}"; }
EOF
# 2. Bootstrap-скрипт
cat > "$BOOTSTRAP_DIR/bootstrap.sh" <<'BOOTEOF'
#!/bin/bash
set -euo pipefail
# ← КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: подключить common.sh для print_* функций
source "$(dirname "$0")/common.sh"

REAL_USER="${REAL_USER:-$SUDO_USER}"
REAL_HOME="${REAL_HOME:-/home/$REAL_USER}"
[ -z "$REAL_USER" ] && { echo "✗ Не удалось определить пользователя" >&2; exit 1; }
SOFT_BLUE='\033[38;5;67m'; SOFT_GREEN='\033[38;5;71m'; SOFT_YELLOW='\033[38;5;178m'
SOFT_RED='\033[38;5;167m'; LIGHT_GRAY='\033[38;5;250m'; RESET='\033[0m'
print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error()   { echo -e "
${SOFT_RED}✗${RESET} ${1}
" >&2; exit 1; }
print_info()    { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }
[ "$(id -u)" != "0" ] && print_error "Запускайте с sudo!"
print_step "SSH Hardening"
if [ -f "$REAL_HOME/.ssh/authorized_keys" ] && grep -qE '^(ssh-rsa|ssh-ed25519)' "$REAL_HOME/.ssh/authorized_keys" 2>/dev/null; then
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
if sshd -t && (systemctl reload sshd 2>/dev/null || systemctl restart sshd) && sleep 2 && systemctl is-active --quiet sshd; then
print_success "Пароли в SSH отключены"
else
cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config 2>/dev/null
systemctl restart sshd
print_warning "SSH не запустился — конфигурация восстановлена"
fi
else
print_warning "SSH-ключи не настроены — пароли остаются включёнными"
fi
print_step "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || true
apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1 || true
apt-get autoremove -yqq >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
print_success "Система обновлена"
print_step "Установка пакетов"
PKGS=("podman" "podman-docker" "ufw" "fail2ban" "fstrim" "gpg" "wireguard")
for pkg in "${PKGS[@]}"; do
print_substep "Установка: $pkg"
dpkg -l | grep -q "^ii  $pkg " || apt-get install -y -qq "$pkg" >/dev/null 2>&1
done
print_success "Пакеты установлены"
print_step "Сетевые оптимизации (BBR)"
modprobe tcp_bbr 2>/dev/null && echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf || true
cat > /etc/sysctl.d/99-infra.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_syncookies = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-infra.conf >/dev/null 2>&1 || true
print_success "BBR настроен"
print_step "Swap"
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
SWAP_SIZE=512
[ "$TOTAL_MEM" -le 1024 ] && SWAP_SIZE=2048
[ "$TOTAL_MEM" -le 2048 ] && SWAP_SIZE=1024
[ "$TOTAL_MEM" -le 4096 ] && SWAP_SIZE=512
if ! swapon --show | grep -q '/swapfile'; then
fallocate -l ${SWAP_SIZE}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE status=none
chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
print_success "Swap настроен (${SWAP_SIZE}M)"
print_step "Диск"
systemctl enable --now fstrim.timer 2>/dev/null || true
print_success "TRIM включён"
print_step "Fail2Ban + UFW"
SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<F2B
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 1h
F2B
systemctl restart fail2ban 2>/dev/null || true
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow 22 comment "SSH" >/dev/null 2>&1
ufw allow 3000 comment "Gitea" >/dev/null 2>&1
ufw allow 3001 comment "AdGuard WebUI" >/dev/null 2>&1
ufw allow 53:53/udp comment "AdGuard DNS" >/dev/null 2>&1
ufw allow 53:53/tcp comment "AdGuard DNS" >/dev/null 2>&1
ufw allow 51820:51820/udp comment "WireGuard" >/dev/null 2>&1
ufw allow 8081 comment "Vaultwarden" >/dev/null 2>&1
ufw allow 8090 comment "TorrServer" >/dev/null 2>&1
ufw allow 9999 comment "Dozzle" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1 || true
print_success "Брандмауэр настроен"
print_step "WireGuard: генерация ключей"
# Авто-определение основного сетевого интерфейса
WG_INTERFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
WG_INTERFACE="${WG_INTERFACE:-eth0}"
if [ ! -f "/etc/wireguard/private.key" ]; then
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key /etc/wireguard/public.key
print_substep "Public key: $(cat /etc/wireguard/public.key)"
else
print_info "Ключи WireGuard уже существуют"
fi
cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = $(cat /etc/wireguard/private.key)
Address = 10.0.0.1/24
ListenPort = 51820
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
WGEOF
systemctl enable --now wg-quick@wg0 2>/dev/null || print_warning "WireGuard: проверьте имя интерфейса в wg0.conf"
print_success "WireGuard настроен (wg0)"
print_step "Включение linger для $REAL_USER"
loginctl enable-linger "$REAL_USER" 2>/dev/null && \
print_success "Linger включён — контейнеры будут автозапускаться" || \
print_error "Не удалось включить linger"
print_step "Активация podman auto-update"
if systemctl --user daemon-reload 2>/dev/null && \
systemctl --user enable --now podman-auto-update.timer 2>/dev/null; then
print_success "Авто-обновление контейнеров включено (проверка раз в 24ч)"
print_info "Управление: infra update"
else
print_warning "Не удалось активировать podman-auto-update.timer"
fi
BOOTEOF
chmod +x "$BOOTSTRAP_DIR/bootstrap.sh"
# 3. CLI-утилита
cat > "$BIN_DIR/infra" <<'CLIEOF'
#!/bin/bash
set -euo pipefail
INFRA_DIR="$HOME/infra"
VOLUMES_DIR="$INFRA_DIR/volumes"
BACKUPS_DIR="$INFRA_DIR/backups"
DARK_GRAY='\033[38;5;242m'; SOFT_BLUE='\033[38;5;67m'; SOFT_GREEN='\033[38;5;71m'
SOFT_YELLOW='\033[38;5;178m'; SOFT_RED='\033[38;5;167m'; LIGHT_GRAY='\033[38;5;250m'; RESET='\033[0m'
print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error()   { echo -e "${SOFT_RED}✗${RESET} ${1}" >&2; exit 1; }
print_info()    { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }
case "${1:-status}" in
status)
echo -e "
${SOFT_BLUE}Состояние сервисов:${RESET}"
systemctl --user --no-pager status '*.service' 2>/dev/null | grep -E "(●|Active:)" || echo "Нет активных сервисов"
echo -e "
${SOFT_BLUE}Использование томов:${RESET}"
du -sh "$VOLUMES_DIR"/* 2>/dev/null | sort -hr || echo "Тома пусты"
echo -e "
${SOFT_BLUE}Локальные бэкапы:${RESET}"
ls -lh "$BACKUPS_DIR"/*.gpg 2>/dev/null | tail -5 || echo "  (нет зашифрованных архивов)"
;;
backup)
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="$BACKUPS_DIR/infra-backup-$TIMESTAMP.tar.gz.gpg"
echo -e "${SOFT_BLUE}Создание зашифрованного бэкапа (GPG)...${RESET}"
echo -e "${SOFT_YELLOW}⚠ Введите пароль для шифрования (запрашивается дважды):${RESET}"
tar -czf - -C "$INFRA_DIR" volumes 2>/dev/null | \
gpg --symmetric --cipher-algo AES256 --output "$BACKUP_FILE" --yes
if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
print_success "Бэкап создан: $BACKUP_FILE ($SIZE)"
echo -e "${LIGHT_GRAY}💡 Для восстановления: скопируйте файл на новый сервер и выполните:${RESET}"
echo -e "     infra restore"
else
print_error "Не удалось создать бэкап"
fi
;;
restore)
BACKUP_FILE=$(ls -t "$BACKUPS_DIR"/infra-backup-*.tar.gz.gpg 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
print_warning "Зашифрованные бэкапы не найдены в $BACKUPS_DIR"
exit 1
fi
echo -e "${SOFT_BLUE}Восстановление из: $(basename "$BACKUP_FILE")${RESET}"
echo -e "${SOFT_YELLOW}⚠ Введите пароль для расшифровки:${RESET}"
echo -e "${LIGHT_GRAY}Остановка контейнеров...${RESET}"
systemctl --user stop '*.service' 2>/dev/null || true
sleep 3
if ! gpg --decrypt "$BACKUP_FILE" 2>/dev/null | tar -xzf - -C "$INFRA_DIR"; then
print_error "Ошибка расшифровки или распаковки. Проверьте пароль."
fi
chown -R "$USER:$USER" "$VOLUMES_DIR" 2>/dev/null || true
echo -e "${LIGHT_GRAY}Запуск контейнеров...${RESET}"
systemctl --user start '*.service' 2>/dev/null || true
sleep 5
print_success "Восстановление завершено! Проверьте статус: infra status"
;;
update)
echo -e "${SOFT_BLUE}Управление авто-обновлениями контейнеров${RESET}"
case "${2:-status}" in
status)
echo -e "
${SOFT_BLUE}Статус таймера:${RESET}"
systemctl --user status podman-auto-update.timer --no-pager 2>/dev/null || echo "Таймер не активен"
echo -e "
${SOFT_BLUE}Последние запуски:${RESET}"
journalctl --user -u podman-auto-update.service -n 5 --no-pager -o short 2>/dev/null || echo "Нет записей в логе"
echo -e "
${SOFT_BLUE}Контейнеры с авто-обновлением:${RESET}"
grep -l "io.containers.autoupdate" "$HOME/.config/containers/systemd/"*.container 2>/dev/null | \
xargs -r basename -a | sed 's/\.container$//' || echo "  (нет настроенных)"
;;
run)
echo -e "${SOFT_BLUE}Запуск проверки обновлений (dry-run)...${RESET}"
podman auto-update --dry-run 2>&1 | tee /tmp/podman-update-check.log || true
echo -e "
${SOFT_GREEN}✓ Проверка завершена${RESET}"
echo -e "${LIGHT_GRAY}Логи: /tmp/podman-update-check.log${RESET}"
;;
apply)
echo -e "${SOFT_YELLOW}⚠ Применение обновлений (перезапуск контейнеров)...${RESET}"
echo -e "${LIGHT_GRAY}Остановка сервисов...${RESET}"
systemctl --user stop '*.service' 2>/dev/null || true
sleep 2
echo -e "${LIGHT_GRAY}Запуск auto-update...${RESET}"
if podman auto-update 2>&1 | tee /tmp/podman-update-apply.log; then
echo -e "
${LIGHT_GRAY}Запуск сервисов...${RESET}"
systemctl --user start '*.service' 2>/dev/null || true
print_success "Обновления применены"
else
print_warning "Обновление завершилось с ошибками — сервисы не запущены"
echo -e "${SOFT_RED}Ручной запуск: infra start${RESET}"
fi
;;
*)
echo "infra update — управление авто-обновлениями"
echo "  status  — статус таймера и логи"
echo "  run     — проверить наличие обновлений (dry-run)"
echo "  apply   — скачать и применить обновления (перезапустит контейнеры)"
;;
esac
;;
monitor)
echo -e "${SOFT_BLUE}Быстрая проверка сервисов:${RESET}"
for svc in caddy:80 gitea:3000 vaultwarden:8081 adguardhome:3001 torrserver:8090; do
name="${svc%%:*}"; port="${svc##*:}"
if curl -sf --max-time 3 "http://localhost:$port" >/dev/null 2>&1; then
echo -e "  ${SOFT_GREEN}✓${RESET} $name (:$port)"
else
echo -e "  ${SOFT_RED}✗${RESET} $name (:$port) — не отвечает"
fi
done
;;
start)
systemctl --user start '*.service' 2>/dev/null && print_success "Контейнеры запущены" || print_warning "Не все контейнеры запущены"
;;
stop)
systemctl --user stop '*.service' 2>/dev/null && print_success "Контейнеры остановлены" || true
;;
logs)
[ -z "${2:-}" ] && { echo "Использование: infra logs <service>"; exit 1; }
journalctl --user -u "${2}.service" -n 50 --no-pager
;;
*)
echo "infra — управление инфраструктурой"
echo "  status    — статус сервисов и бэкапов"
echo "  backup    — создать зашифрованный GPG архив (локально)"
echo "  restore   — восстановить из последнего GPG архива"
echo "  update    — управление авто-обновлениями (podman auto-update)"
echo "  monitor   — быстрая проверка доступности сервисов"
echo "  start/stop — управление сервисами"
echo "  logs <svc> — логи сервиса"
;;
esac
CLIEOF
chmod +x "$BIN_DIR/infra"
# 4. Health-check скрипт (исправлен Telegram URL)
cat > "$BIN_DIR/healthcheck.sh" <<'HCEOF'
#!/bin/bash
set -euo pipefail
# Минималистичный health-check с уведомлениями
# Запускать через cron: */5 * * * * $HOME/infra/bin/healthcheck.sh
INFRA_DIR="$HOME/infra"
LOG_FILE="$INFRA_DIR/logs/healthcheck.log"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
notify() {
local msg="$1"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
-d "chat_id=${TELEGRAM_CHAT_ID}" \
-d "text=🔴 ${msg}" \
-d "parse_mode=HTML" >/dev/null 2>&1 || true
fi
}
check_http() {
local name="$1" url="$2" expected_code="${3:-200}"
if ! curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "$url" | grep -q "^$expected_code$"; then
log "✗ $name: HTTP check failed ($url)"
notify "$name не отвечает: $url"
return 1
fi
log "✓ $name: OK"
return 0
}
check_tcp() {
local name="$1" host="$2" port="$3"
if ! timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
log "✗ $name: TCP check failed ($host:$port)"
notify "$name не отвечает на порту $port"
return 1
fi
log "✓ $name: TCP OK"
return 0
}
mkdir -p "$(dirname "$LOG_FILE")"
check_http "Caddy" "http://localhost:80"
check_http "Gitea" "http://localhost:3000"
check_http "Vaultwarden" "http://localhost:8081"
check_http "AdGuard Home" "http://localhost:3001"
check_tcp "TorrServer" "localhost" 8090
check_tcp "WireGuard" "localhost" 51820
for svc in gitea vaultwarden adguardhome torrserver caddy; do
if ! systemctl --user is-active --quiet "${svc}.service" 2>/dev/null; then
log "✗ $svc.service: не активен"
notify "Сервис $svc упал (systemd)"
fi
done
log "=== Health-check completed ==="
HCEOF
chmod +x "$BIN_DIR/healthcheck.sh"
# 5. Quadlet-файлы с label авто-обновления
CURRENT_UID=$(id -u "$CURRENT_USER")
CURRENT_GID=$(id -g "$CURRENT_USER")
# ← КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: heredoc читается через $(cat), не $2
create_quadlet() {
    local file="$1"
    local content
    content=$(cat)
    if ! echo "$content" | grep -q "io.containers.autoupdate"; then
        content="${content%]*}"
        content="${content}Label=io.containers.autoupdate=image
]"
    fi
    echo "$content" > "$file"
}
create_quadlet "$CONTAINERS_DIR/gitea.container" <<EOF
[Container]
Image=docker.io/gitea/gitea:1.22-rootless
Volume=$CURRENT_HOME/infra/volumes/gitea:/data
PublishPort=3000:3000
PublishPort=2222:22
Environment=USER_UID=$CURRENT_UID
Environment=USER_GID=$CURRENT_GID
Environment=GITEA__server__DOMAIN=localhost:3000
Environment=GITEA__server__ROOT_URL=http://localhost:3000/
Environment=GITEA__server__SSH_DOMAIN=localhost
Environment=GITEA__server__SSH_PORT=2222
Environment=GITEA__actions__ENABLED=true
[Service]
Restart=always
EOF
create_quadlet "$CONTAINERS_DIR/vaultwarden.container" <<EOF
[Container]
Image=docker.io/vaultwarden/server:1.31-alpine
Volume=$CURRENT_HOME/infra/volumes/vaultwarden:/data
PublishPort=8081:80
[Service]
Restart=always
EOF
create_quadlet "$CONTAINERS_DIR/torrserver.container" <<EOF
[Container]
Image=ghcr.io/yourok/torrserver:latest
Volume=$CURRENT_HOME/infra/volumes/torrserver:/app/z
PublishPort=8090:8090
[Service]
Restart=always
EOF
create_quadlet "$CONTAINERS_DIR/caddy.container" <<EOF
[Container]
Image=docker.io/library/caddy:2.8-alpine
Volume=$CURRENT_HOME/infra/volumes/caddy:/data
Volume=$CURRENT_HOME/infra/volumes/caddy_config:/config
PublishPort=80:80
PublishPort=443:443
[Service]
Restart=always
EOF
create_quadlet "$CONTAINERS_DIR/dozzle.container" <<EOF
[Container]
Image=docker.io/amir20/dozzle:latest
Volume=/run/user/$CURRENT_UID/podman/podman.sock:/var/run/docker.sock:ro
PublishPort=9999:8080
[Service]
Restart=always
EOF
# =============== ADGUARD HOME ===============
create_quadlet "$CONTAINERS_DIR/adguardhome.container" <<EOF
[Container]
Image=docker.io/adguard/adguardhome:latest
Volume=$CURRENT_HOME/infra/volumes/adguardhome/work:/opt/adguardhome/work
Volume=$CURRENT_HOME/infra/volumes/adguardhome/conf:/opt/adguardhome/conf
PublishPort=53:53/udp
PublishPort=53:53/tcp
PublishPort=3001:3000
[Service]
Restart=always
User=root
Capability=CAP_NET_BIND_SERVICE
EOF
# =============== RESTIC (ОБЛАЧНЫЙ БЭКАП) — без авто-обновления ===============
cat > "$CONTAINERS_DIR/restic.container" <<EOF
[Container]
Image=docker.io/restic/restic:latest
Volume=$CURRENT_HOME/infra/volumes:/backup/volumes:ro
Volume=$CURRENT_HOME/infra/containers:/backup/containers:ro
Volume=$CURRENT_HOME/infra/secrets/restic:/restic:ro
Environment=RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-s3:https://storage.example.com/infra-backup}
Environment=AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
Environment=AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
Environment=RESTIC_PASSWORD_FILE=/restic/password
Entrypoint=/bin/sh
Cmd=-c "restic backup /backup/volumes /backup/containers --one-file-system --exclude '*.tmp' --exclude '*.log' && restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune && restic check"
[Service]
Restart=on-failure
EOF
cat > "$CONTAINERS_DIR/restic.timer" <<EOF
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
# =============== НАСТРОЙКА ХОСТА ===============
if ! $RESTORE_MODE; then
print_step "Настройка хоста (требуются права sudo)"
if sudo REAL_USER="$CURRENT_USER" REAL_HOME="$CURRENT_HOME" "$BOOTSTRAP_DIR/bootstrap.sh"; then
print_success "Хост подготовлен"
else
print_warning "Ошибка настройки хоста — продолжаем"
fi
fi
# =============== РЕГИСТРАЦИЯ КОНТЕЙНЕРОВ ===============
USER_CONFIG="${XDG_CONFIG_HOME:-$CURRENT_HOME/.config}"
mkdir -p "$USER_CONFIG/containers/systemd"
for file in "$CONTAINERS_DIR"/*.container "$CONTAINERS_DIR"/*.timer; do
[ -f "$file" ] && ln -sf "$file" "$USER_CONFIG/containers/systemd/$(basename "$file")" 2>/dev/null || true
done
systemctl --user daemon-reexec 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
# Запуск контейнеров (кроме restic)
if ! $RESTORE_MODE; then
print_step "Запуск сервисов"
for svc in gitea vaultwarden torrserver caddy dozzle adguardhome; do
print_substep "Запуск: $svc"
systemctl --user enable --now "${svc}.service" 2>/dev/null && \
print_success "Запущен: $svc" || \
print_warning "Не удалось запустить: $svc"
done
print_step "Ожидание готовности Gitea"
for i in {1..60}; do
if curl -s --max-time 2 http://localhost:3000 > /dev/null 2>&1; then
print_success "Gitea готова"
break
fi
sleep 2
printf "."
done
echo
LOCAL_IP=$(hostname -I | awk '{print $1}')
cat <<EOF
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
${SOFT_BLUE}👉 Откройте: http://$LOCAL_IP:3000${RESET}
${SOFT_BLUE}👉 Создайте администратора в Gitea (первый пользователь = админ)${RESET}
${SOFT_BLUE}👉 После создания — нажмите Enter${RESET}
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
EOF
read -p "Нажмите Enter после настройки админа... "
# Настройка раннера
cat <<EOF
${SOFT_BLUE}👉 Получите токен раннера в Gitea:${RESET}
${LIGHT_GRAY}  http://$LOCAL_IP:3000/admin/runners → Add Runner${RESET}
${SOFT_BLUE}👉 Вставьте токен ниже (пустой ввод = пропустить):${RESET}
EOF
read -rsp "Токен: " RUNNER_TOKEN
echo
if [ -n "${RUNNER_TOKEN:-}" ]; then
cat > "$CONTAINERS_DIR/gitea-runner.container" <<EOF
[Container]
Image=docker.io/gitea/act_runner:0.3.0-dind-rootless
Volume=$CURRENT_HOME/infra/volumes/gitea-runner:/data
Volume=/run/user/$CURRENT_UID/podman/podman.sock:/var/run/docker.sock:ro
Environment=GITEA_INSTANCE_URL=http://host.containers.internal:3000
Environment=GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN
Environment=GITEA_RUNNER_NAME=$(hostname)-infra-runner
Environment=GITEA_RUNNER_LABELS=infra,linux,amd64
Environment=DOCKER_HOST=unix:///var/run/docker.sock
Label=io.containers.autoupdate=registry
[Service]
Restart=always
EOF
ln -sf "$CONTAINERS_DIR/gitea-runner.container" "$USER_CONFIG/containers/systemd/"
systemctl --user daemon-reload
systemctl --user enable --now gitea-runner.service 2>/dev/null && \
print_success "Раннер запущен" || \
print_warning "Не удалось запустить раннер"
sleep 30
podman logs gitea-runner 2>/dev/null | grep -q "Runner registered successfully" && \
print_success "Раннер зарегистрирован" || true
else
print_info "Настройка раннера пропущена (пустой токен)"
fi
# Настройка cron для healthcheck
print_step "Настройка health-check (cron)"
if command -v crontab >/dev/null 2>&1; then
(crontab -l 2>/dev/null || true; echo "*/5 * * * * $CURRENT_HOME/infra/bin/healthcheck.sh") | crontab -
print_success "Health-check добавлен в cron (каждые 5 минут)"
else
print_warning "crontab не найден — health-check не настроен"
fi
fi
# =============== ФИНАЛЬНЫЙ ОТЧЁТ ===============
LOCAL_IP=$(hostname -I | awk '{print $1}')
if $RESTORE_MODE; then
cat <<EOF
${DARK_GRAY}╔═══════════════════════════════════════════════════════════════════════════════╗${RESET}
${SOFT_GREEN}║  ✅ Структура развёрнута для восстановления                                  ║${RESET}
${DARK_GRAY}╚═══════════════════════════════════════════════════════════════════════════════╝${RESET}
${SOFT_BLUE}Следующие шаги:${RESET}
1. Скопируйте зашифрованный бэкап в ~/infra/backups/
2. Восстановите: infra restore
3. После восстановления сервисы запустятся автоматически
${SOFT_YELLOW}Важно:${RESET}
• Пароль от GPG-архива НЕ хранится в системе — запоминайте его!
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
EOF
else
cat <<EOF
${DARK_GRAY}╔═══════════════════════════════════════════════════════════════════════════════╗${RESET}
${SOFT_GREEN}║  ✅ Инфраструктура развёрнута и готова к работе!                             ║${RESET}
${DARK_GRAY}╚═══════════════════════════════════════════════════════════════════════════════╝${RESET}
${SOFT_BLUE}Доступ к сервисам:${RESET}
• Gitea:        http://$LOCAL_IP:3000
• AdGuard Home: http://$LOCAL_IP:3001  (DNS: $LOCAL_IP:53)
• Vaultwarden:  http://$LOCAL_IP:8081
• TorrServer:   http://$LOCAL_IP:8090
• Dozzle:       http://$LOCAL_IP:9999
• WireGuard:    UDP 51820 (ключи в /etc/wireguard/)
${SOFT_BLUE}Управление:${RESET}
• Статус:          infra status
• Локальный бэкап: infra backup   ← GPG-архив в ~/infra/backups/
• Восстановление:  infra restore
• Авто-обновление: infra update   ← podman auto-update + systemd
• Мониторинг:      infra monitor  ← быстрая проверка доступности
• Запуск/стоп:     infra start / infra stop
${SOFT_BLUE}Облачные бэкапы (Restic) — опционально:${RESET}
1. Создайте файл пароля:
echo "пароль" > ~/infra/secrets/restic/password && chmod 600 ~/infra/secrets/restic/password
2. Задайте переменные окружения для облака (S3/WebDAV/etc)
3. Активируйте таймер:
systemctl --user enable --now restic.timer
${SOFT_YELLOW}Важно:${RESET}
• Авто-обновление работает через label io.containers.autoupdate=image
• Для отката используйте конкретные теги: gitea:1.22.0 вместо :latest
• CLI-бэкапы и Restic — независимые механизмы
• Данные сервисов: $CURRENT_HOME/infra/volumes/
• Контейнеры автозапускаются после перезагрузки (linger)
• Health-check работает через cron (каждые 5 минут)
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
EOF
fi
if ! grep -q "alias infra=" "$CURRENT_HOME/.bashrc" 2>/dev/null; then
echo 'alias infra="$HOME/infra/bin/infra"' >> "$CURRENT_HOME/.bashrc"
print_info "Добавлен алиас 'infra' — выполните: source ~/.bashrc"
fi
print_success "Готово! Инфраструктура развёрнута для: $CURRENT_USER"
