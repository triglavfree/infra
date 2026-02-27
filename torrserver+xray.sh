#!/bin/bash

# --- Конфигурация ---
TORRSERVER_PORT=8090
XRAY_PORT=443
AUTH_USER="admin"
AUTH_PASS="securepassword"
DOMAIN=""

# --- Цвета и форматирование ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Проверка зависимостей ---
check_dependencies() {
    local missing=()
    for cmd in podman wget dialog jq nc; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Ошибка: Отсутствуют зависимости: ${missing[*]}${NC}"
        exit 1
    fi
}

# --- Спиннер для долгих операций ---
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# --- Проверка открытого порта ---
check_port() {
    local port=$1
    if nc -z -w5 127.0.0.1 "$port" &> /dev/null; then
        echo -e "${GREEN}Порт $port открыт${NC}"
    else
        echo -e "${RED}Порт $port закрыт${NC}"
        exit 1
    fi
}

# --- Установка TorrServer ---
install_torrserver() {
    echo -e "${YELLOW}Установка TorrServer...${NC}"

    # Создание директорий
    mkdir -p ~/.config/containers/systemd/torrserver
    mkdir -p ~/torrserver/config
    mkdir -p ~/torrserver/downloads

    # Создание конфига Quadlet
    cat > ~/.config/containers/systemd/torrserver.container <<EOL
[Unit]
Description=TorrServer Podman Container
After=network.target

[Container]
Image=docker.io/yourok/torrserver:latest
ContainerName=torrserver
PublishPort=$TORRSERVER_PORT:8090
Volume=~/torrserver/config:/torrserver/config
Volume=~/torrserver/downloads:/torrserver/downloads
Environment=TS_AUTH_USER=$AUTH_USER
Environment=TS_AUTH_PASS=$AUTH_PASS

[Install]
WantedBy=multi-user.target
EOL

    # Запуск контейнера
    systemctl --user daemon-reload
    systemctl --user enable --now torrserver.container &
    spinner $!
    sleep 5

    # Проверка порта
    check_port $TORRSERVER_PORT
}

# --- Установка Xray ---
install_xray() {
    echo -e "${YELLOW}Установка Xray...${NC}"
    wget -qO- https://raw.githubusercontent.com/ServerTechnologies/simple-xray-core/refs/heads/main/xhttp-xray-install | bash -s -- "$DOMAIN" &
    spinner $!
    sleep 5

    # Проверка порта
    check_port $XRAY_PORT
}

# --- Основной процесс ---
main() {
    check_dependencies

    # Запрос домена
    while [ -z "$DOMAIN" ]; do
        DOMAIN=$(dialog --inputbox "Введите доменное имя:" 8 40 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then
            echo -e "${RED}Установка отменена.${NC}"
            exit 1
        fi
    done

    install_torrserver
    install_xray

    echo -e "${GREEN}Установка завершена!${NC}"
    echo -e "TorrServer: http://localhost:$TORRSERVER_PORT"
    echo -e "Xray: https://$DOMAIN"
}

main
