#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy for Ubuntu Server 24.04.4 LTS
#
# Usage:
#   curl -s https://raw.githubusercontent.com/triglavfree/infra/main/telemt.sh | bash
#
# With custom port:
#   TELEMT_PORT=9443 curl -s https://... | bash
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
        log_info "Processes using port ${TELEMT_PORT}:"
        ss -tlnp | grep ":${TELEMT_PORT}" || true
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
    rm -f /etc/containers/storage.conf 2>/dev/null || true
    systemctl stop podman 2>/dev/null || true
    
    # Only reset if there's a driver mismatch
    if podman info 2>&1 | grep -q "mismatch"; then
        log_info "Resetting podman storage..."
        podman system reset -f 2>/dev/null || true
    fi
    log_ok "Done"
}

get_ip() {
    curl -s --max-time 5 -4 ifconfig.me || echo "UNKNOWN"
}

gen_secret() {
    openssl rand -hex 16
}

build_image() {
    log_info "Building container image..."
    local tmpdir
    tmpdir=$(mktemp -d)
    
    # Containerfile with dynamic EXPOSE via build arg
    cat > "${tmpdir}/Containerfile" << EOF
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
RUN addgroup -g 1000 telemt && adduser -u 1000 -G telemt -D telemt
ARG ARCH
ARG PORT=8443
RUN arch=\$(echo \${ARCH} | sed 's/amd64/x86_64/;s/arm64/aarch64/') && \
    wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-\${arch}-linux-musl.tar.gz" && \
    tar -xzf telemt-*.tar.gz -C /usr/local/bin && chmod +x /usr/local/bin/telemt && rm telemt-*.tar.gz
RUN mkdir -p /etc/telemt && chown telemt:telemt /etc/telemt
USER telemt
EXPOSE \${PORT}
ENTRYPOINT ["/usr/local/bin/telemt"]
CMD ["/etc/telemt/telemt.toml"]
EOF

    log_info "Building for port ${TELEMT_PORT}..."
    podman build \
        --build-arg ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
        --build-arg PORT="${TELEMT_PORT}" \
        -t localhost/telemt:latest "${tmpdir}" 2>&1 | tail -5
    
    rm -rf "${tmpdir}"
    log_ok "Image built"
}

create_config() {
    log_info "Creating config for port ${TELEMT_PORT}..."
    
    # Clean old config
    rm -rf "${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}"
    
    # Correct telemt config format based on official example
    # Port goes in [server] section, NOT in [[server.listeners]]
    cat > "${CONFIG_DIR}/telemt.toml" << EOF
# Telemt MTProto Proxy Configuration

[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "user"
public_host = "${TELEMT_DOMAIN}"
public_port = ${TELEMT_PORT}

[server]
port = ${TELEMT_PORT}

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TLS_MASK}"
mask = true
tls_emulation = true

[access.users]
user = "${TELEMT_SECRET}"
EOF

    chown -R 1000:1000 "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"
    chmod 644 "${CONFIG_DIR}/telemt.toml"
    
    # Verify config was created correctly
    log_info "Verifying config:"
    grep -E "^(port|public_port|public_host)" "${CONFIG_DIR}/telemt.toml"
    
    log_ok "Config created"
}

run_container() {
    log_info "Starting container..."
    
    # Remove old container
    podman rm -f telemt 2>/dev/null || true
    
    # Run with explicit port mapping
    podman run -d --name telemt \
        --restart always \
        -p "${TELEMT_PORT}:${TELEMT_PORT}" \
        -v /etc/telemt:/etc/telemt:ro \
        --ulimit nofile=65536:65536 \
        localhost/telemt:latest
    
    sleep 3
    
    # Check if container is actually running
    if podman ps --format "{{.Names}}" | grep -q "^telemt$"; then
        log_ok "Container started successfully"
    else
        log_error "Container failed to start!"
        log_info "Container logs:"
        podman logs telemt 2>&1 | tail -20
        exit 1
    fi
}

firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "${TELEMT_PORT}/tcp" comment "Telemt" 2>/dev/null || true
        log_ok "Firewall: port ${TELEMT_PORT} open"
    fi
}

show_info() {
    local link="https://t.me/proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=ee${TELEMT_SECRET}"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║              DEPLOYMENT COMPLETE!                        ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Server:${NC}    ${YELLOW}${TELEMT_DOMAIN}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Port:${NC}      ${YELLOW}${TELEMT_PORT}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Secret:${NC}   ${YELLOW}${TELEMT_SECRET}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TLS Mask:${NC} ${YELLOW}${TLS_MASK}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                 ${CYAN}CONNECTION LINK${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "  ${link}"
    echo ""
    echo -e "${GREEN}║${NC}  ${YELLOW}podman logs -f telemt${NC}     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}podman stop telemt${NC}          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}podman start telemt${NC}${NC}         ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}cat /etc/telemt/telemt.toml${NC}  ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo "${link}" > "${CONFIG_DIR}/connection-link.txt"
    chown 1000:1000 "${CONFIG_DIR}/connection-link.txt"
    log_ok "Link saved to ${CONFIG_DIR}/connection-link.txt"
}

interactive() {
    local ip
    ip=$(get_ip)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              SETUP                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Detected IP: ${YELLOW}${ip}${NC}"
    echo ""
    echo -e "Note: Port 443 may be occupied. Using ${YELLOW}8443${NC} as default."
    echo ""
    
    read -rp "Port [8443]: " port_input
    TELEMT_PORT="${port_input:-8443}"
    
    while ss -tlnp | grep -q ":${TELEMT_PORT} "; do
        log_error "Port ${TELEMT_PORT} is in use!"
        ss -tlnp | grep ":${TELEMT_PORT}" || true
        read -rp "Enter another port: " TELEMT_PORT
    done
    
    read -rp "Domain or IP [${ip}]: " d
    TELEMT_DOMAIN="${d:-${ip}}"
    
    local s
    s=$(gen_secret)
    read -rp "Secret [${s}]: " d
    TELEMT_SECRET="${d:-${s}}"
}

verify_deployment() {
    log_info "Verifying deployment..."
    
    # Check container is running
    if ! podman ps --format "{{.Names}}" | grep -q "^telemt$"; then
        log_error "Container not running!"
        return 1
    fi
    
    # Check port is listening
    sleep 2
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_ok "Port ${TELEMT_PORT} is listening"
    else
        log_error "Port ${TELEMT_PORT} is NOT listening!"
        log_info "Container logs:"
        podman logs telemt 2>&1 | tail -15
        return 1
    fi
    
    # Show recent logs
    log_info "Container logs (last 15 lines):"
    podman logs telemt 2>&1 | tail -15
    
    return 0
}

main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║       Telemt MTProto Proxy Installer              ║${NC}"
    echo -e "${GREEN}║           Ubuntu Server 24.04                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════${NC}"
    echo ""
    
    check_root
    
    if ! is_interactive; then
        TELEMT_DOMAIN=$(get_ip)
        TELEMT_SECRET=$(gen_secret)
        log_info "Non-interactive mode"
        log_info "IP: ${TELEMT_DOMAIN}"
        log_info "Port: ${TELEMT_PORT}"
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
    verify_deployment
    show_info
    
    log_ok "Deployment complete!"
}

main "$@"
