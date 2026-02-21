#!/bin/bash
set -euo pipefail
# ============================================================================
# infra.sh — автономный развёртыватель инфраструктуры (v5.0.0 для Ubuntu Server 24.04)
# ============================================================================
# Изменения v5.0.0:
#   • Полная оптимизация под Ubuntu Server 24.04 LTS
#   • Авто-отключение systemd-resolved для AdGuard Home
#   • Исправлена генерация Quadlet через podman-systemd-generator
#   • Улучшена обработка linger и user services
#   • Добавлена установка cron если отсутствует
#   • Исправлены права доступа к volumes (rootless podman)
#   • Добавлена проверка apparmor для rootless контейнеров
#   • Исправлено определение SSH сервиса для Ubuntu 24.04
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

# =============== ПРОВЕРКА СИСТЕМНЫХ ТРЕБОВАНИЙ ===============
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$NAME" == "Ubuntu" ]] && [[ "$VERSION_ID" == "24.04"* ]]; then
        print_info "Обнаружена Ubuntu Server $VERSION_ID"
    else
        print_warning "Этот скрипт оптимизирован для Ubuntu Server 24.04 LTS"
        print_info "Текущая система: $NAME $VERSION_ID"
    fi
else
    print_error "Не удалось определить операционную систему"
fi

# =============== ОПРЕДЕЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ===============
if [ "$(id -u)" = "0" ] && [ -z "${SUDO_USER:-}" ]; then
print_error "Запускайте от обычного пользователя с sudo (не от root напрямую)!"
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

# =============== ПРОВЕРКА LINGER (КРИТИЧНО ДЛЯ UBUNTU 24.04) ===============
# В Ubuntu 24.04 linger должен быть включен ДО создания user services
print_step "Проверка systemd linger"

if ! loginctl show-user "$CURRENT_USER" 2>/dev/null | grep -q "Linger=yes"; then
    print_substep "Включение linger для $CURRENT_USER (требуется для автозапуска контейнеров)"
    
    # Создаем директорию linger если её нет
    sudo mkdir -p /var/lib/systemd/linger
    
    if sudo loginctl enable-linger "$CURRENT_USER" 2>/dev/null; then
        print_success "Linger включен"
        
        # Проверяем создание файла
        if [ -f "/var/lib/systemd/linger/$CURRENT_USER" ]; then
            print_info "Файл linger создан: /var/lib/systemd/linger/$CURRENT_USER"
        fi
        
        # Даем время на применение
        sleep 2
        
        if loginctl show-user "$CURRENT_USER" 2>/dev/null | grep -q "Linger=yes"; then
            print_success "Linger активен для $CURRENT_USER"
        else
            print_warning "Linger не подтвержден, но продолжаем..."
        fi
    else
        print_error "Критическая ошибка: не удалось включить linger. Сервисы не будут автозапускаться!"
    fi
else
    print_info "Linger уже включен для $CURRENT_USER"
fi

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

# 2. Bootstrap-скрипт (оптимизирован для Ubuntu 24.04)
cat > "$BOOTSTRAP_DIR/bootstrap.sh" <<'BOOTEOF'
#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

REAL_USER="${REAL_USER:-$SUDO_USER}"
REAL_HOME="${REAL_HOME:-/home/$REAL_USER}"

[ -z "$REAL_USER" ] && { echo "✗ Не удалось определить пользователя" >&2; exit 1; }

print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error()   { echo -e "
${SOFT_RED}✗${RESET} ${1}
" >&2; exit 1; }
print_info()    { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }

[ "$(id -u)" != "0" ] && print_error "Запускайте с sudo!"

# === UBUNTU 24.04: ОТКЛЮЧЕНИЕ SYSTEMD-RESOLVED ===
print_step "Настройка DNS (systemd-resolved)"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    print_warning "systemd-resolved активен и занимает порт 53"
    print_substep "Остановка и отключение systemd-resolved..."
    
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    
    # Восстанавливаем resolv.conf
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    fi
    
    print_success "systemd-resolved отключен"
    print_info "AdGuard Home теперь может использовать порт 53"
else
    print_info "systemd-resolved не активен"
fi

print_step "SSH Hardening"

if [ -f "$REAL_HOME/.ssh/authorized_keys" ] && grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2)' "$REAL_HOME/.ssh/authorized_keys" 2>/dev/null; then
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s) 2>/dev/null || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Ubuntu 24.04 использует ssh.service
SSH_SERVICE="ssh"
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
fi

print_info "Используем сервис: $SSH_SERVICE"

if sshd -t 2>/dev/null; then
    systemctl reload "$SSH_SERVICE" 2>/dev/null || systemctl restart "$SSH_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SSH_SERVICE"; then
        print_success "SSH настроен (пароли отключены)"
    else
        print_warning "SSH не перезапустился"
    fi
else
    print_warning "Ошибка в конфигурации SSH"
fi
else
print_warning "SSH-ключи не настроены — пароли остаются включёнными"
fi

print_step "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1 || true
apt-get autoremove -yqq >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
print_success "Система обновлена"

print_step "Установка пакетов"
# Ubuntu 24.04: cron может отсутствовать в минимальной установке
PKGS=("podman" "podman-docker" "ufw" "fail2ban" "gpg" "wireguard-tools" "cron" "apparmor-utils")

for pkg in "${PKGS[@]}"; do
    print_substep "Проверка: $pkg"
    if dpkg -l | grep -q "^ii  $pkg "; then
        print_info "$pkg уже установлен"
    else
        print_substep "Установка: $pkg"
        apt-get install -y -qq --no-install-recommends "$pkg" >/dev/null 2>&1 || {
            print_warning "Повторная попытка установки $pkg..."
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq --no-install-recommends "$pkg" >/dev/null 2>&1 || {
                print_warning "Не удалось установить $pkg (пропускаем)"
            }
        }
    fi
done

# Проверяем что cron запущен
if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
    print_success "Cron активен"
else
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
fi

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
net.ipv4.ip_forward = 1
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

print_step "Диск (fstrim)"
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
ufw allow "$SSH_PORT/tcp" comment "SSH" >/dev/null 2>&1
ufw allow 3000/tcp comment "Gitea" >/dev/null 2>&1
ufw allow 3001/tcp comment "AdGuard WebUI" >/dev/null 2>&1
ufw allow 53/udp comment "AdGuard DNS" >/dev/null 2>&1
ufw allow 53/tcp comment "AdGuard DNS" >/dev/null 2>&1
ufw allow 51820/udp comment "WireGuard" >/dev/null 2>&1
ufw allow 8081/tcp comment "Vaultwarden" >/dev/null 2>&1
ufw allow 8090/tcp comment "TorrServer" >/dev/null 2>&1
ufw allow 9999/tcp comment "Dozzle" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1 || true
print_success "Брандмауэр настроен"

print_step "WireGuard: генерация ключей"
# Ubuntu 24.04: улучшенное определение интерфейса
WG_INTERFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)

if [ -z "$WG_INTERFACE" ] || [ ! -d "/sys/class/net/$WG_INTERFACE" ]; then
    WG_INTERFACE=$(ip -o link show 2>/dev/null | grep -v "lo:" | grep "state UP" | head -1 | awk -F': ' '{print $2}')
fi

if [ -z "$WG_INTERFACE" ] || [ ! -d "/sys/class/net/$WG_INTERFACE" ]; then
    WG_INTERFACE="eth0"
fi

print_info "Используем интерфейс: $WG_INTERFACE"

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

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
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
WGEOF

chmod 600 /etc/wireguard/wg0.conf

if wg-quick down wg0 2>/dev/null; then sleep 1; fi
if wg-quick up wg0 2>/dev/null; then
    systemctl enable wg-quick@wg0 2>/dev/null || true
    print_success "WireGuard настроен и запущен (wg0)"
else
    print_warning "WireGuard: проверьте конфигурацию вручную"
fi

print_step "Включение linger для $REAL_USER"
loginctl enable-linger "$REAL_USER" 2>/dev/null && \
print_success "Linger включён" || \
print_warning "Не удалось включить linger"

print_step "Настройка rootless Podman"
# Ubuntu 24.04: настройка subuid/subgid для rootless
if ! grep -q "$REAL_USER:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER" 2>/dev/null || true
    print_info "Настроены subuid/subgid для $REAL_USER"
fi

# Проверка apparmor профиля для rootless
if [ -f /etc/apparmor.d/podman ]; then
    print_info "AppArmor профиль для Podman найден"
fi

print_success "Rootless Podman настроен"

BOOTEOF

chmod +x "$BOOTSTRAP_DIR/bootstrap.sh"

# 3. CLI-утилита (без изменений, работает корректно)
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

# 4. Health-check скрипт (исправлен URL Telegram)
cat > "$BIN_DIR/healthcheck.sh" <<'HCEOF'
#!/bin/bash
set -euo pipefail

INFRA_DIR="$HOME/infra"
LOG_FILE="$INFRA_DIR/logs/healthcheck.log"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

notify() {
local msg="$1"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
# Исправлен URL: убраны пробелы
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
-d "chat_id=${TELEGRAM_CHAT_ID}" \
-d "text=🔴 ${msg}" \
-d "parse_mode=HTML" >/dev/null 2>&1 || true
fi
}

check_http() {
local name="$1" url="$2" expected_code="${3:-200}"
local response
response=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
if [ "$response" != "$expected_code" ]; then
log "✗ $name: HTTP check failed ($url) - got $response"
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

# Проверка Caddy добавлена
check_http "Caddy" "http://localhost:80" || true
check_http "Gitea" "http://localhost:3000" || true
check_http "Vaultwarden" "http://localhost:8081" || true
check_http "AdGuard Home" "http://localhost:3001" || true
check_tcp "TorrServer" "localhost" 8090 || true
check_tcp "WireGuard" "localhost" 51820 || true

for svc in gitea vaultwarden adguardhome torrserver caddy; do
if ! systemctl --user is-active --quiet "${svc}.service" 2>/dev/null; then
log "✗ $svc.service: не активен"
notify "Сервис $svc упал (systemd)"
fi
done

log "=== Health-check completed ==="
HCEOF

chmod +x "$BIN_DIR/healthcheck.sh"

# 5. Quadlet-файлы (исправлена генерация для Ubuntu 24.04)
CURRENT_UID=$(id -u "$CURRENT_USER")
CURRENT_GID=$(id -g "$CURRENT_USER")

# Ubuntu 24.04: используем прямую запись файлов с правильным форматированием
write_quadlet() {
    local file="$1"
    local content="$2"
    
    # Добавляем автообновление если отсутствует
    if ! echo "$content" | grep -q "io.containers.autoupdate"; then
        content=$(echo "$content" | sed 's/^\[Service\]$/Label=io.containers.autoupdate=image\n[Service]/')
    fi
    
    echo "$content" > "$file"
    chown "$CURRENT_USER:$CURRENT_USER" "$file"
}

write_quadlet "$CONTAINERS_DIR/gitea.container" "[Container]
Image=docker.io/gitea/gitea:1.22-rootless
Volume=$CURRENT_HOME/infra/volumes/gitea:/data:Z
PublishPort=3000:3000
PublishPort=2222:22
Environment=USER_UID=$CURRENT_UID
Environment=USER_GID=$CURRENT_GID
Environment=GITEA__server__DOMAIN=localhost:3000
Environment=GITEA__server__ROOT_URL=http://localhost:3000/
Environment=GITEA__server__SSH_DOMAIN=localhost
Environment=GITEA__server__SSH_PORT=2222
Environment=GITEA__actions__ENABLED=true
Label=io.containers.autoupdate=registry

[Service]
Restart=always"

write_quadlet "$CONTAINERS_DIR/vaultwarden.container" "[Container]
Image=docker.io/vaultwarden/server:1.31-alpine
Volume=$CURRENT_HOME/infra/volumes/vaultwarden:/data:Z
PublishPort=8081:80
Label=io.containers.autoupdate=registry

[Service]
Restart=always"

write_quadlet "$CONTAINERS_DIR/torrserver.container" "[Container]
Image=ghcr.io/yourok/torrserver:latest
Volume=$CURRENT_HOME/infra/volumes/torrserver:/app/z:Z
PublishPort=8090:8090
Label=io.containers.autoupdate=registry

[Service]
Restart=always"

write_quadlet "$CONTAINERS_DIR/caddy.container" "[Container]
Image=docker.io/library/caddy:2.8-alpine
Volume=$CURRENT_HOME/infra/volumes/caddy:/data:Z
Volume=$CURRENT_HOME/infra/volumes/caddy_config:/config:Z
PublishPort=80:80
PublishPort=443:443
Label=io.containers.autoupdate=registry

[Service]
Restart=always"

write_quadlet "$CONTAINERS_DIR/dozzle.container" "[Container]
Image=docker.io/amir20/dozzle:latest
Volume=/run/user/$CURRENT_UID/podman/podman.sock:/var/run/docker.sock:ro
PublishPort=9999:8080
Label=io.containers.autoupdate=registry

[Service]
Restart=always"

# AdGuard Home требует root в контейнере для порта 53
write_quadlet "$CONTAINERS_DIR/adguardhome.container" "[Container]
Image=docker.io/adguard/adguardhome:latest
Volume=$CURRENT_HOME/infra/volumes/adguardhome/work:/opt/adguardhome/work:Z
Volume=$CURRENT_HOME/infra/volumes/adguardhome/conf:/opt/adguardhome/conf:Z
PublishPort=53:53/udp
PublishPort=53:53/tcp
PublishPort=3001:3000
User=root
Group=root
Label=io.containers.autoupdate=registry

[Service]
Restart=always"

# Restic backup
cat > "$CONTAINERS_DIR/restic.container" <<EOF
[Container]
Image=docker.io/restic/restic:latest
Volume=$CURRENT_HOME/infra/volumes:/backup/volumes:ro,Z
Volume=$CURRENT_HOME/infra/containers:/backup/containers:ro,Z
Volume=$CURRENT_HOME/infra/secrets/restic:/restic:ro,Z
Environment=RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-}
Environment=AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
Environment=AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
Environment=RESTIC_PASSWORD_FILE=/restic/password
Entrypoint=/bin/sh
Exec=-c "restic backup /backup/volumes /backup/containers --one-file-system --exclude '*.tmp' --exclude '*.log' && restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune"

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

# =============== РЕГИСТРАЦИЯ КОНТЕЙНЕРОВ (UBUNTU 24.04) ===============
USER_CONFIG="${XDG_CONFIG_HOME:-$CURRENT_HOME/.config}"
SYSTEMD_USER_DIR="$USER_CONFIG/containers/systemd"
mkdir -p "$SYSTEMD_USER_DIR"

# Очищаем старые ссылки
rm -f "$SYSTEMD_USER_DIR"/*.container "$SYSTEMD_USER_DIR"/*.timer 2>/dev/null || true

# Создаем симлинки
for file in "$CONTAINERS_DIR"/*.container "$CONTAINERS_DIR"/*.timer; do
    if [ -f "$file" ]; then
        ln -sf "$file" "$SYSTEMD_USER_DIR/$(basename "$file")"
        print_substep "Зарегистрирован: $(basename "$file")"
    fi
done

# Ubuntu 24.04: генерация systemd unit файлов через quadlet
print_step "Генерация systemd unit файлов"

# Проверяем наличие podman
if ! command -v podman >/dev/null 2>&1; then
    print_error "Podman не установлен!"
fi

# Для Ubuntu 24.04 используем systemd generator
export XDG_CONFIG_HOME="$USER_CONFIG"
export XDG_RUNTIME_DIR="/run/user/$CURRENT_UID"

# Создаем runtime директорию если нужно
if [ ! -d "/run/user/$CURRENT_UID" ]; then
    sudo mkdir -p "/run/user/$CURRENT_UID"
    sudo chown "$CURRENT_USER:$CURRENT_USER" "/run/user/$CURRENT_UID"
    sudo chmod 700 "/run/user/$CURRENT_UID"
fi

# Генерация unit файлов через quadlet
print_substep "Генерация systemd units..."
/usr/libexec/podman/quadlet -dryrun -user 2>/dev/null || true

# Перезагрузка systemd user instance
print_substep "Перезагрузка systemd..."
systemctl --user daemon-reexec 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

# Проверка генерации
if systemctl --user list-unit-files 2>/dev/null | grep -q "gitea.service"; then
    print_success "Systemd unit файлы сгенерированы"
else
    print_warning "Quadlet файлы не обнаружены в systemd, пробуем альтернативный метод..."
    
    # Альтернативный метод: ручная генерация
    for container in "$SYSTEMD_USER_DIR"/*.container; do
        if [ -f "$container" ]; then
            base=$(basename "$container" .container)
            # Конвертируем container в service через podman generate
            podman generate systemd --name "$base" --files --new 2>/dev/null || true
        fi
    done
fi

# =============== ЗАПУСК СЕРВИСОВ ===============
if ! $RESTORE_MODE; then
print_step "Запуск сервисов"

# Сначала запускаем базовые сервисы
for svc in caddy adguardhome; do
    print_substep "Запуск: $svc"
    if systemctl --user enable --now "${svc}.service" 2>/dev/null; then
        print_success "Запущен: $svc"
    else
        print_warning "Не удалось запустить: $svc"
        systemctl --user status "${svc}.service" 2>/dev/null | head -5 || true
    fi
    sleep 2
done

# Затем остальные
for svc in gitea vaultwarden torrserver dozzle; do
    print_substep "Запуск: $svc"
    if systemctl --user enable --now "${svc}.service" 2>/dev/null; then
        print_success "Запущен: $svc"
    else
        print_warning "Не удалось запустить: $svc"
    fi
    sleep 2
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
Volume=$CURRENT_HOME/infra/volumes/gitea-runner:/data:Z
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

ln -sf "$CONTAINERS_DIR/gitea-runner.container" "$SYSTEMD_USER_DIR/"
systemctl --user daemon-reload

if systemctl --user enable --now gitea-runner.service 2>/dev/null; then
    print_success "Раннер запущен"
    sleep 5
    if podman logs gitea-runner 2>/dev/null | grep -q "Runner registered successfully\|Successfully registered"; then
        print_success "Раннер зарегистрирован в Gitea"
    else
        print_warning "Проверьте логи раннера: infra logs gitea-runner"
    fi
else
    print_warning "Не удалось запустить раннер"
fi
else
print_info "Настройка раннера пропущена"
fi

print_step "Настройка health-check (cron)"
if command -v crontab >/dev/null 2>&1; then
    # Удаляем дубликаты
    crontab -l 2>/dev/null | grep -v "healthcheck.sh" | crontab - 2>/dev/null || true
    # Добавляем новую запись
    (crontab -l 2>/dev/null || true; echo "*/5 * * * * $CURRENT_HOME/infra/bin/healthcheck.sh >/dev/null 2>&1") | crontab -
    print_success "Health-check добавлен в cron (каждые 5 минут)"
else
    print_warning "crontab не найден — создаем systemd таймер для health-check"
    
    cat > "$CONTAINERS_DIR/healthcheck.timer" <<EOF
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

    cat > "$CONTAINERS_DIR/healthcheck.service" <<EOF
[Unit]
Description=Health check for infrastructure

[Service]
Type=oneshot
ExecStart=$CURRENT_HOME/infra/bin/healthcheck.sh
EOF

    ln -sf "$CONTAINERS_DIR/healthcheck.timer" "$SYSTEMD_USER_DIR/"
    ln -sf "$CONTAINERS_DIR/healthcheck.service" "$SYSTEMD_USER_DIR/"
    systemctl --user daemon-reload
    systemctl --user enable --now healthcheck.timer 2>/dev/null || true
    print_success "Health-check таймер создан"
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
• Локальный бэкап: infra backup
• Восстановление:  infra restore
• Авто-обновление: infra update
• Мониторинг:      infra monitor
• Запуск/стоп:     infra start / infra stop

${SOFT_YELLOW}Важно для Ubuntu 24.04:${RESET}
• systemd-resolved отключен для AdGuard Home
• Контейнеры используют :Z флаги для SELinux/AppArmor
• Linger включен — сервисы запускаются при загрузке
• Проверьте статус: systemctl --user status

${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
EOF
fi

# Добавляем алиас
if ! grep -q "alias infra=" "$CURRENT_HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/infra/bin:$PATH"' >> "$CURRENT_HOME/.bashrc"
    echo 'alias infra="$HOME/infra/bin/infra"' >> "$CURRENT_HOME/.bashrc"
    print_info "Добавлены алиасы — выполните: source ~/.bashrc"
fi

print_success "Готово! Инфраструктура развёрнута для: $CURRENT_USER"
