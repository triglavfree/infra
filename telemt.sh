#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy for Ubuntu Server 24.04.4 LTS
#
# curl -s https://raw.githubusercontent.com/triglavfree/infra/main/telemt.sh | bash
#===============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CONFIG_DIR="/etc/telemt"
TELEMT_PORT="${TELEMT_PORT:-8443}"
TELEMT_SECRET="${TELEMT_SECRET:-}"
TELEMT_DOMAIN="${TELEMT_DOMAIN:-}"
TLS_MASK="${TLS_MASK:-www.microsoft.com}"

check_root() {
    [[ $EUID -eq 0 ]] || { log_error "Run as root"; exit 1; }
}

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

check_port() {
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_error "Port ${TELEMT_PORT} is already in use!"
        exit 1
    fi
}

install_deps() {
    log_info "Installing packages..."
    apt-get update -qq
    apt-get install -y -qq curl wget openssl podman ca-certificates
    log_ok "Done"
}

configure_podman() {
    log_info "Configuring Podman..."
    rm -f /etc/containers/storage.conf
    systemctl stop podman 2>/dev/null || true
    podman system reset -f 2>/dev/null || true
    log_ok "Done"
}

get_ip() {
    curl -s --max-time 5 -4 ifconfig.me || echo "UNKNOWN"
}

gen_secret() {
    openssl rand -hex 16
}

build_image() {
    log_info "Building image..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "${tmpdir}/Containerfile" << 'EOF'
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
RUN addgroup -g 1000 telemt && adduser -u 1000 -G telemt -D telemt
ARG ARCH
RUN arch=$(echo ${ARCH} | sed 's/amd64/x86_64/;s/arm64/aarch64/') && \
    wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-musl.tar.gz" && \
    tar -xzf telemt-*.tar.gz -C /usr/local/bin && chmod +x /usr/local/bin/telemt && rm telemt-*.tar.gz
RUN mkdir -p /etc/telemt && chown telemt:telemt /etc/telemt
USER telemt
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/telemt"]
CMD ["/etc/telemt/telemt.toml"]
EOF
    podman build --build-arg ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
        -t localhost/telemt:latest "${tmpdir}" 2>&1 | tail -5
    rm -rf "${tmpdir}"
    log_ok "Done"
}

create_config() {
    log_info "Creating config..."
    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_DIR}/telemt.toml" << EOF
[general]
[general.modes]
tls = true
[[server.listeners]]
ip = "0.0.0.0"
port = ${TELEMT_PORT}
[censorship]
tls_domain = "${TLS_MASK}"
[access.users]
user = "${TELEMT_SECRET}"
EOF
    chmod 600 "${CONFIG_DIR}/telemt.toml"
    log_ok "Done"
}

run_container() {
    log_info "Starting container..."
    podman rm -f telemt 2>/dev/null || true
    podman run -d --name telemt \
        --restart always \
        -p ${TELEMT_PORT}:${TELEMT_PORT} \
        -v /etc/telemt:/etc/telemt:ro \
        --ulimit nofile=65536:65536 \
        localhost/telemt:latest
    log_ok "Done"
}

firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow ${TELEMT_PORT}/tcp comment "Telemt" 2>/dev/null
        log_ok "Firewall: port ${TELEMT_PORT} open"
    fi
}

show_info() {
    local link="https://t.me/proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=ee${TELEMT_SECRET}"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║           DEPLOYMENT COMPLETE!                        ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Server:${NC}  ${YELLOW}${TELEMT_DOMAIN}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Port:${NC}    ${YELLOW}${TELEMT_PORT}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Secret:${NC} ${YELLOW}${TELEMT_SECRET}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}               ${CYAN}CONNECTION LINK${NC}                 ${GREEN}║${NC}"
    echo ""
    echo -e "  ${link}"
    echo ""
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════${NC}"
    echo "${link}" > "${CONFIG_DIR}/connection-link.txt"
    log_ok "Saved to ${CONFIG_DIR}/connection-link.txt"
}

interactive() {
    local ip
    ip=$(get_ip)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              SETUP                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "IP: ${YELLOW}${ip}${NC}"
    echo ""
    echo -e "Port 443 is used. Using ${YELLOW}8443${NC} as default."
    echo ""
    read -rp "Port [8443]: " port_input
    TELEMT_PORT="${port_input:-8443}"
    while ss -tlnp | grep -q ":${TELEMT_PORT} "; do
        log_error "Port ${TELEMT_PORT} is in use!"
        read -rp "Enter another port: " TELEMT_PORT
    done
    read -rp "Domain [${ip}]: " d
    TELEMT_DOMAIN="${d:-${ip}}"
    local s=$(gen_secret)
    read -rp "Secret [${s}]: " d
    TELEMT_SECRET="${d:-${s}}"
}

main() {
    echo ""
    echo -e "${GREEN}Telemt MTProto Proxy${NC}"
    echo -e "${GREEN}Ubuntu 24.04${NC}"
    echo ""
    check_root
    if ! is_interactive; then
        TELEMT_DOMAIN=$(get_ip)
        TELEMT_SECRET=$(gen_secret)
    else
        interactive
    fi
    check_port
    log_info "Deploying on port ${TELEMT_PORT}..."
    install_deps
    configure_podman
    build_image
    create_config
    firewall
    run_container
    show_info
    log_ok "Done!"
}
main
