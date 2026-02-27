#!/bin/bash
#===============================================================================
# Telemt MTProto Proxy for Ubuntu Server 24.04.4 LTS
# FIXED VERSION - with proper port configuration
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
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

CONFIG_DIR="/etc/telemt"
TELEMT_PORT="8443"
TELEMT_SECRET=""
TELEMT_DOMAIN=""
TLS_MASK="www.microsoft.com"

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
    apt-get install -y -qq curl wget openssl podman ca-certificates xxd
    log_ok "Done"
}

configure_podman() {
    log_info "Configuring Podman..."
    rm -f /etc/containers/storage.conf 2>/dev/null || true
    systemctl stop podman 2>/dev/null || true
    
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
    log_info "Building container image for port ${TELEMT_PORT}..."
    local tmpdir
    tmpdir=$(mktemp -d)
    
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
# No EXPOSE - we'll handle port via command line
ENTRYPOINT ["/usr/local/bin/telemt"]
CMD ["--port", "${PORT}", "/etc/telemt/telemt.toml"]
EOF

    log_info "Building image (this may take a minute)..."
    if ! podman build \
        --build-arg ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
        --build-arg PORT="${TELEMT_PORT}" \
        -t localhost/telemt:latest "${tmpdir}" 2>&1 | tee "${tmpdir}/build.log"; then
        log_error "Build failed!"
        cat "${tmpdir}/build.log"
        rm -rf "${tmpdir}"
        exit 1
    fi
    
    rm -rf "${tmpdir}"
    log_ok "Image built successfully"
}

create_config() {
    log_info "Creating config for port ${TELEMT_PORT}..."
    
    rm -rf "${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}"
    
    # FIXED: Proper telemt config format - only using [[server.listeners]]
    cat > "${CONFIG_DIR}/telemt.toml" << EOF
# Telemt MTProto Proxy Configuration

[general]
log_level = "info"

[general.modes]
classic = false
secure = false
tls = true

# IMPORTANT: Only use [[server.listeners]] format - this is what telemt expects
[[server.listeners]]
ip = "0.0.0.0"
port = ${TELEMT_PORT}
# announce_ip = "${TELEMT_DOMAIN}"

[censorship]
tls_domain = "${TLS_MASK}"
mask = true

[access.users]
"user" = "${TELEMT_SECRET}"
EOF

    chown -R 1000:1000 "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"
    chmod 644 "${CONFIG_DIR}/telemt.toml"
    
    log_ok "Config created with port ${TELEMT_PORT}"
}

run_container() {
    log_info "Starting container on port ${TELEMT_PORT}..."
    
    # Stop and remove any existing container
    podman stop telemt 2>/dev/null || true
    podman rm telemt 2>/dev/null || true
    
    # Create cache directory
    mkdir -p "${CONFIG_DIR}/cache"
    chown -R 1000:1000 "${CONFIG_DIR}/cache"
    
    # Run container with explicit port mapping and command line port override
    if ! podman run -d --name telemt \
        --restart always \
        -p "${TELEMT_PORT}:${TELEMT_PORT}" \
        -v "${CONFIG_DIR}:/etc/telemt:ro" \
        -v "${CONFIG_DIR}/cache:/var/lib/telemt:rw" \
        --ulimit nofile=65536:65536 \
        localhost/telemt:latest \
        --port "${TELEMT_PORT}" /etc/telemt/telemt.toml; then
        log_error "Failed to start container!"
        exit 1
    fi
    
    sleep 5
    
    # Check if container is running
    if podman ps --format "{{.Names}}" | grep -q "^telemt$"; then
        log_ok "Container started successfully"
    else
        log_error "Container failed to start!"
        log_info "Container status:"
        podman ps -a | grep telemt
        log_info "Container logs:"
        podman logs telemt 2>&1 | tail -30
        exit 1
    fi
}

firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "${TELEMT_PORT}/tcp" comment "Telemt" 2>/dev/null || true
        log_ok "Firewall: port ${TELEMT_PORT} opened"
    fi
    
    # Also check if there are any other firewall rules blocking
    if command -v iptables &>/dev/null; then
        if iptables -L INPUT -n | grep -q "DROP\|REJECT"; then
            log_warn "iptables may have restrictive rules. Check with: iptables -L INPUT -n"
        fi
    fi
}

verify_deployment() {
    log_info "Verifying deployment on port ${TELEMT_PORT}..."
    
    # Check container is running
    if ! podman ps --format "{{.Names}}" | grep -q "^telemt$"; then
        log_error "Container not running!"
        return 1
    fi
    
    # Check port is listening on host
    sleep 3
    if ss -tlnp | grep -q ":${TELEMT_PORT} "; then
        log_ok "Port ${TELEMT_PORT} is listening on host"
    else
        log_error "Port ${TELEMT_PORT} is NOT listening on host!"
        log_info "Host listening ports:"
        ss -tlnp | grep -E ":(22|${TELEMT_PORT}|443|80)" || true
        log_info "Container logs:"
        podman logs telemt 2>&1 | tail -20
        return 1
    fi
    
    # Check container logs for binding confirmation
    if podman logs telemt 2>&1 | grep -q "listening on"; then
        log_ok "Container confirmed listening"
    else
        log_warn "Could not confirm listening in logs. Checking manually..."
    fi
    
    # Show recent logs
    log_info "Container recent logs:"
    podman logs telemt 2>&1 | tail -10
    
    return 0
}

show_info() {
    local tls_hex
    tls_hex=$(echo -n "${TLS_MASK}" | xxd -p)
    
    # Create proper TLS secret (ee + secret + domain hex)
    local tls_secret="ee${TELEMT_SECRET}${tls_hex}"
    
    local link="tg://proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    local link_web="https://t.me/proxy?server=${TELEMT_DOMAIN}&port=${TELEMT_PORT}&secret=${tls_secret}"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║              TELEMT DEPLOYMENT COMPLETE!                  ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Server:${NC}    ${YELLOW}${TELEMT_DOMAIN}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Port:${NC}      ${YELLOW}${TELEMT_PORT}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}Secret:${NC}   ${YELLOW}${TELEMT_SECRET}${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TLS Mask:${NC} ${YELLOW}${TLS_MASK}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                 ${CYAN}CONNECTION LINKS${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "  ${link_web}"
    echo ""
    echo -e "  ${link}"
    echo ""
    echo -e "${GREEN}║${NC}  ${YELLOW}Useful commands:${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}podman logs -f telemt${NC}     - view logs"
    echo -e "${GREEN}║${NC}  ${CYAN}podman stop telemt${NC}        - stop container"
    echo -e "${GREEN}║${NC}  ${CYAN}podman start telemt${NC}       - start container"
    echo -e "${GREEN}║${NC}  ${CYAN}cat /etc/telemt/telemt.toml${NC} - view config"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo "${link_web}" > "${CONFIG_DIR}/connection-link.txt"
    echo "${link}" >> "${CONFIG_DIR}/connection-link.txt"
    chown 1000:1000 "${CONFIG_DIR}/connection-link.txt" 2>/dev/null || true
    log_ok "Link saved to ${CONFIG_DIR}/connection-link.txt"
}

test_connection() {
    log_info "Testing local connection..."
    
    # Test local connection to the port
    if command -v nc &>/dev/null; then
        if nc -z localhost "${TELEMT_PORT}" 2>/dev/null; then
            log_ok "Local connection to port ${TELEMT_PORT} successful"
        else
            log_error "Local connection to port ${TELEMT_PORT} failed!"
            return 1
        fi
    fi
    
    # Try to get a response from the proxy
    if command -v curl &>/dev/null; then
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${TELEMT_PORT}" 2>/dev/null | grep -q "400\|200"; then
            log_ok "Proxy responded to HTTP request"
        else
            log_warn "No HTTP response (expected for MTProto)"
        fi
    fi
}

interactive() {
    local ip
    ip=$(get_ip)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              TELEMT INTERACTIVE SETUP                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Detected IP: ${YELLOW}${ip}${NC}"
    echo -e "Default port: ${YELLOW}8443${NC} (non-privileged, safe from conflicts)"
    echo ""
    
    read -rp "Port [8443]: " port_input
    TELEMT_PORT="${port_input:-8443}"
    
    while ss -tlnp | grep -q ":${TELEMT_PORT} "; do
        log_error "Port ${TELEMT_PORT} is in use!"
        ss -tlnp | grep ":${TELEMT_PORT}" || true
        read -rp "Enter another port: " TELEMT_PORT
    done
    
    read -rp "Domain or IP for links [${ip}]: " d
    TELEMT_DOMAIN="${d:-${ip}}"
    
    local s
    s=$(gen_secret)
    read -rp "Secret [${s}]: " d
    TELEMT_SECRET="${d:-${s}}"
    
    read -rp "TLS mask domain [${TLS_MASK}]: " d
    TLS_MASK="${d:-${TLS_MASK}}"
}

main() {
    if [[ -n "${1:-}" ]]; then
        TELEMT_PORT="$1"
    fi
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}║       Telemt MTProto Proxy Installer        ║${NC}"
    echo -e "${GREEN}║           Ubuntu Server 24.04               ║${NC}"
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
    
    if verify_deployment; then
        test_connection
        show_info
        log_ok "Deployment complete! Port ${TELEMT_PORT} should now be accessible."
        log_info "Test from another machine: nc -zv ${TELEMT_DOMAIN} ${TELEMT_PORT}"
    else
        log_error "Deployment verification failed!"
        exit 1
    fi
}

main "$@"
