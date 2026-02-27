#!/bin/bash
#===============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ: Xray (нативно) + Telemt (podman) + TorrServer (podman)
#===============================================================================
set -euo pipefail

# Цвета и стили
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; NC='\033[0m'

TOP_LEFT='╔'; TOP_RIGHT='╗'; BOTTOM_LEFT='╚'; BOTTOM_RIGHT='╝'
HORIZONTAL='═'; VERTICAL='║'; CROSS_LEFT='╠'; CROSS_RIGHT='╣'

# Переменные
TELEMT_PORT="8443"                # Хост-порт для Telemt (проброс на 443 в контейнере)
TELEMT_SECRET=""
TELEMT_TLS_MASK="www.microsoft.com"
DOMAIN=""                          # Внешний IP или домен
XRAY_CONFIG_DIR="/usr/local/etc/xray"
TELEMT_CONFIG_DIR="/etc/telemt"
TORRSERVER_DATA="/var/lib/torrserver"
QUADLET_DIR="/etc/containers/systemd"

#-------------------------------------------------------------------------------
# Функции вывода
#-------------------------------------------------------------------------------
print_header() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║     XRAY (НАТИВНО) + TELEMT + TORRSERVER (В КОНТЕЙНЕРАХ PODMAN)            ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

print_section() { echo -e "${CYAN}${CROSS_LEFT}${HORIZONTAL}${HORIZONTAL} ${1} ${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${CROSS_RIGHT}${NC}"; }

print_info() { echo -e "${BLUE}  ▶${NC} $1"; }
print_ok() { echo -e "${GREEN}  ✓${NC} $1"; }
print_error() { echo -e "${RED}  ✗${NC} $1"; exit 1; }
print_warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
print_value() { printf "  ${CYAN}%-15s${NC} ${YELLOW}%s${NC}\n" "$1:" "$2"; }
print_command() { printf "  ${GREEN}❯${NC} ${YELLOW}%s${NC}\n" "$1"; }
print_line() { echo -e "  ${BLUE}──────────────────────────────────────────────────────${NC}"; }

check_root() { [[ $EUID -eq 0 ]] || print_error "Запустите от root"; }
get_ip() { curl -s --max-time 5 -4 ifconfig.me || echo "UNKNOWN"; }
gen_secret() { openssl rand -hex 16; }

#-------------------------------------------------------------------------------
# УСТАНОВКА ЗАВИСИМОСТЕЙ
#-------------------------------------------------------------------------------
install_deps() {
    print_section "УСТАНОВКА ЗАВИСИМОСТЕЙ"
    apt update -qq
    apt install -y -qq curl wget openssl ca-certificates xxd podman jq ufw qrencode
    print_ok "Базовые пакеты установлены"
}

#-------------------------------------------------------------------------------
# УСТАНОВКА XRAY (нативно, официальный скрипт)
#-------------------------------------------------------------------------------
install_xray() {
    print_section "УСТАНОВКА XRAY-CORE (НАТИВНО)"
    
    if command -v xray &>/dev/null; then
        print_ok "Xray уже установлен"
        return 0
    fi
    
    print_info "Установка Xray через официальный скрипт..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    print_ok "Xray установлен"
}

#-------------------------------------------------------------------------------
# ГЕНЕРАЦИЯ КЛЮЧЕЙ ДЛЯ REALITY
#-------------------------------------------------------------------------------
generate_xray_keys() {
    print_section "ГЕНЕРАЦИЯ КЛЮЧЕЙ XRAY (REALITY)"
    
    # Генерируем UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    # Генерируем ключи x25519 (используем xray, если доступен)
    if command -v xray &>/dev/null; then
        KEY_PAIR=$(xray x25519)
        PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private" | awk '{print $3}')
        PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public" | awk '{print $3}')
    else
        # fallback: используем openssl для генерации ключей (не идеально, но для демо)
        PRIVATE_KEY=$(openssl rand -base64 32)
        PUBLIC_KEY=$(openssl rand -base64 32)
        print_warn "Не удалось сгенерировать ключи через xray, использованы случайные"
    fi
    
    # Короткий ID (8 байт hex)
    SHORT_ID=$(openssl rand -hex 8)
    
    # Сохраняем в файл
    cat > ${XRAY_CONFIG_DIR}/.keys << EOF
uuid=${UUID}
shortid=${SHORT_ID}
privatekey=${PRIVATE_KEY}
publickey=${PUBLIC_KEY}
EOF
    
    print_ok "Ключи сгенерированы и сохранены в ${XRAY_CONFIG_DIR}/.keys"
}

#-------------------------------------------------------------------------------
# СОЗДАНИЕ КОНФИГА XRAY (с fallback на Telemt)
#-------------------------------------------------------------------------------
create_xray_config() {
    print_section "НАСТРОЙКА XRAY (с fallback на Telemt)"
    
    source ${XRAY_CONFIG_DIR}/.keys
    
    cat > ${XRAY_CONFIG_DIR}/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": ["geoip:cn"],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "${UUID}",
                        "flow": ""
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                    {
                        "dest": ${TELEMT_PORT},
                        "xver": 1
                    }
                ]
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "github.com:443",
                    "serverNames": [
                        "github.com",
                        "www.github.com"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [
                        "${SHORT_ID}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "policy": {
        "levels": {
            "0": {
                "handshake": 3,
                "connIdle": 180
            }
        }
    }
}
EOF
    
    print_ok "Конфиг Xray создан с fallback на порт ${TELEMT_PORT}"
}

#-------------------------------------------------------------------------------
# ПЕРЕЗАПУСК XRAY
#-------------------------------------------------------------------------------
restart_xray() {
    print_section "ПЕРЕЗАПУСК XRAY"
    systemctl restart xray
    sleep 2
    if systemctl is-active xray &>/dev/null; then
        print_ok "Xray запущен"
    else
        print_error "Ошибка запуска Xray. Проверьте логи: journalctl -u xray"
    fi
}

#-------------------------------------------------------------------------------
# УСТАНОВКА TELEMT
#-------------------------------------------------------------------------------
install_telemt() {
    print_section "УСТАНОВКА TELEMT (ЧЕРЕЗ PODMAN)"
    
    TELEMT_SECRET=$(gen_secret)
    mkdir -p ${TELEMT_CONFIG_DIR}
    
    # Конфиг Telemt
    cat > ${TELEMT_CONFIG_DIR}/telemt.toml << EOF
[general]
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[[server.listeners]]
ip = "0.0.0.0"
port = 443
announce_ip = "${DOMAIN}"
proxy_protocol = true

[censorship]
tls_domain = "${TELEMT_TLS_MASK}"
mask = true

[access.users]
"user" = "${TELEMT_SECRET}"
EOF
    
    # Quadlet-файл для Telemt
    mkdir -p ${QUADLET_DIR}
    cat > ${QUADLET_DIR}/telemt.container << EOF
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/whn0thacked/telemt-docker:latest
ContainerName=telemt
PublishPort=${TELEMT_PORT}:443
Volume=${TELEMT_CONFIG_DIR}/telemt.toml:/etc/telemt.toml:ro,Z

# Hardening
SecurityOpt=no-new-privileges:true
DropCapability=ALL
AddCapability=NET_BIND_SERVICE
ReadOnlyRootFilesystem=true
Tmpfs=/tmp:rw,size=16m

[Service]
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl start telemt
    sleep 2
    if systemctl is-active telemt &>/dev/null; then
        print_ok "Telemt запущен (порт ${TELEMT_PORT} → контейнер:443)"
    else
        print_error "Ошибка запуска Telemt. Проверьте: journalctl -u telemt"
    fi
}

#-------------------------------------------------------------------------------
# УСТАНОВКА TORRSERVER
#-------------------------------------------------------------------------------
install_torrserver() {
    print_section "УСТАНОВКА TORRSERVER (ЧЕРЕЗ PODMAN)"
    
    mkdir -p ${TORRSERVER_DATA}
    
    cat > ${QUADLET_DIR}/torrserver.container << EOF
[Unit]
Description=TorrServer - Torrent Streaming Server
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/yourok/torrserver:latest
ContainerName=torrserver
PublishPort=8090:8090
Volume=${TORRSERVER_DATA}:/torrserver:Z

[Service]
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl start torrserver
    sleep 2
    if systemctl is-active torrserver &>/dev/null; then
        print_ok "TorrServer запущен (порт 8090)"
    else
        print_error "Ошибка запуска TorrServer. Проверьте: journalctl -u torrserver"
    fi
}

#-------------------------------------------------------------------------------
# НАСТРОЙКА UFW
#-------------------------------------------------------------------------------
setup_firewall() {
    print_section "НАСТРОЙКА ФАЙРВОЛА"
    
    if command -v ufw &>/dev/null; then
        ufw allow 443/tcp comment "Xray + Telemt fallback" &>/dev/null
        ufw allow 8090/tcp comment "TorrServer" &>/dev/null
        ufw --force enable &>/dev/null
        print_ok "Порты 443 и 8090 открыты в UFW"
    fi
}

#-------------------------------------------------------------------------------
# ВЫВОД ИНФОРМАЦИИ
#-------------------------------------------------------------------------------
show_info() {
    local tls_hex=$(echo -n "${TELEMT_TLS_MASK}" | xxd -p)
    local telemt_link="tg://proxy?server=${DOMAIN}&port=443&secret=ee${TELEMT_SECRET}${tls_hex}"
    
    source ${XRAY_CONFIG_DIR}/.keys 2>/dev/null || true
    
    echo ""
    echo -e "${GREEN}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${GREEN}${VERTICAL}${NC}                 ${WHITE}УСТАНОВКА ПОЛНОСТЬЮ ЗАВЕРШЕНА${NC}                 ${GREEN}${VERTICAL}${NC}"
    echo -e "${GREEN}${CROSS_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${CROSS_RIGHT}${NC}"
    
    echo -e "${WHITE}${BOLD}🔒 XRAY (REALITY):${NC}"
    print_value "Адрес" "${DOMAIN}"
    print_value "Порт" "443"
    print_value "UUID" "${UUID}"
    print_value "ShortID" "${SHORT_ID}"
    print_value "PublicKey" "${PUBLIC_KEY}"
    echo ""
    
    echo -e "${WHITE}${BOLD}📱 TELEMT:${NC}"
    print_value "Ссылка" "${telemt_link}"
    print_value "Секрет" "${TELEMT_SECRET}"
    print_value "TLS маска" "${TELEMT_TLS_MASK}"
    echo ""
    
    echo -e "${WHITE}${BOLD}🎬 TORRSERVER:${NC}"
    print_value "URL" "http://${DOMAIN}:8090"
    echo ""
    
    echo -e "${WHITE}${BOLD}🛠️  Управление:${NC}"
    print_command "systemctl status xray"
    print_command "systemctl status telemt"
    print_command "systemctl status torrserver"
    print_command "journalctl -u xray -f"
    print_command "journalctl -u telemt -f"
    print_command "journalctl -u torrserver -f"
    echo ""
    
    echo -e "${YELLOW}⚠️  Секрет Telemt показан только один раз. Сохраните его!${NC}"
    echo -e "${YELLOW}⚠️  Для Xray ссылка формируется как:${NC}"
    echo -e "  vless://${UUID}@${DOMAIN}:443?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=firefox&type=xhttp&path=%2F&sni=github.com&sid=${SHORT_ID}#xray-${DOMAIN}"
    echo ""
    
    echo -e "${GREEN}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    echo ""
    
    # Сохраняем ссылку Telemt в файл (на случай, если не скопировали)
    echo "${telemt_link}" > /root/telemt-link.txt
    print_info "Ссылка Telemt сохранена в /root/telemt-link.txt"
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ФУНКЦИЯ
#-------------------------------------------------------------------------------
main() {
    print_header
    check_root
    
    DOMAIN=$(get_ip)
    print_info "Внешний IP: ${DOMAIN}"
    
    install_deps
    install_xray
    generate_xray_keys
    create_xray_config
    restart_xray
    install_telemt
    install_torrserver
    setup_firewall
    show_info
    
    print_ok "Установка полностью завершена!"
}

main "$@"
