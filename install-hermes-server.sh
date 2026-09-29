#!/bin/bash
# install-hermes-server.sh
# Instala Hermes Agent + Traefik local (HTTP only) em servidor Alpine/Debian/Ubuntu
# Traefik Central termina TLS e proxya HTTP para este servidor

set -euo pipefail

# ============================================
# CORES
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*"; }

# ============================================
# DETECTAR OS
# ============================================
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    PKG="apk add --no-cache"
    INIT="openrc"
elif [ -f /etc/debian_version ]; then
    OS="debian"
    PKG="apt-get update && apt-get install -y"
    INIT="systemd"
else
    err "OS não suportado. Use Alpine, Debian ou Ubuntu."
    exit 1
fi
log "OS detectado: $OS ($INIT)"

# ============================================
# INPUTS INTERATIVOS
# ============================================
echo
echo "============================================"
echo "  INSTALAÇÃO HERMES + TRAEFIK LOCAL"
echo "============================================"
echo

read -p "Domínio (ex: agente.metabancaria.com.br): " DOMAIN
[ -z "$DOMAIN" ] && { err "Domínio obrigatório"; exit 1; }

read -p "IP do Traefik Central (ex: 192.168.25.101): " CENTRAL_IP
[ -z "$CENTRAL_IP" ] && { err "IP do Central obrigatório"; exit 1; }

read -p "Usuário do dashboard Hermes (default: admin): " DASH_USER
DASH_USER=${DASH_USER:-admin}

read -sp "Senha do dashboard Hermes: " DASH_PASS
echo
[ -z "$DASH_PASS" ] && { err "Senha obrigatória"; exit 1; }

read -p "Email para Let's Encrypt (no Central): " LE_EMAIL
[ -z "$LE_EMAIL" ] && LE_EMAIL="admin@$DOMAIN"

# Gerar secret para sessões
DASH_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)

# Hash da senha (scrypt via python)
DASH_PASS_HASH=$(python3 -c "
import sys
try:
    from plugins.dashboard_auth.basic import hash_password
    print(hash_password('$DASH_PASS'))
except:
    import hashlib, secrets
    salt = secrets.token_bytes(16)
    # fallback simples
    print('scrypt\$' + hashlib.sha256(('$DASH_PASS' + salt.hex()).encode()).hexdigest())
" 2>/dev/null || echo "scrypt\$fallback")

log "Configurações:"
echo "  Domínio: $DOMAIN"
echo "  Central IP: $CENTRAL_IP"
echo "  Dashboard user: $DASH_USER"
echo "  Email LE: $LE_EMAIL"
echo

read -p "Confirma instalação? (s/N): " CONF
[[ "$CONF" =~ ^[sS]$ ]] || { err "Cancelado"; exit 1; }

# ============================================
# INSTALAR DEPENDÊNCIAS
# ============================================
log "Instalando dependências..."

if [ "$OS" = "alpine" ]; then
    apk add --no-cache python3 py3-pip git curl openssl bash
    # Traefik
    apk add --no-cache traefik
    # Hermes
    pip3 install --break-system-packages hermes-agent
else
    apt-get update
    apt-get install -y python3 python3-pip python3-venv git curl openssl
    # Traefik (binary)
    curl -fsSL https://raw.githubusercontent.com/traefik/traefik/v2.11.2/install.sh | bash -s -- -b /usr/local/bin v2.11.2
    # Hermes
    python3 -m venv /opt/hermes-venv
    /opt/hermes-venv/bin/pip install --upgrade pip
    /opt/hermes-venv/bin/pip install hermes-agent
    ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
fi

# ============================================
# CONFIG HERMES
# ============================================
log "Configurando Hermes..."

HERMES_HOME="/root/.hermes"
mkdir -p "$HERMES_HOME"/{skills,plugins,logs,sessions,memories}

cat > "$HERMES_HOME/config.yaml" << EOF
model:
  default: free-stack
  provider: custom
  base_url: https://routers.riquest.com.br/v1
  api_key: CHANGE_ME  # Configure no Central/env

dashboard:
  basic_auth:
    username: "$DASH_USER"
    password_hash: "$DASH_PASS_HASH"
    secret: "$DASH_SECRET"
    session_ttl_seconds: 43200

agent:
  max_turns: 90
  gateway_timeout: 1800

toolsets:
  - hermes-cli
EOF

chmod 600 "$HERMES_HOME/config.yaml"

# ============================================
# TRAEFIK LOCAL (HTTP ONLY - Central termina TLS)
# ============================================
log "Configurando Traefik local..."

mkdir -p /etc/traefik/dynamic /var/log/traefik /var/lib/traefik

cat > /etc/traefik/traefik.yaml << 'EOF'
global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: false

entryPoints:
  web:
    address: ":80"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log
  format: common

accessLog:
  filePath: /var/log/traefik/access.log
  format: common
EOF

cat > /etc/traefik/dynamic/hermes.yaml << EOF
http:
  routers:
    hermes:
      rule: "Host(\`$DOMAIN\`)"
      entryPoints:
        - web
      service: hermes-svc

  services:
    hermes-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9119"
        passHostHeader: true
EOF

# ============================================
# SERVIÇOS (OpenRC ou systemd)
# ============================================
log "Criando serviços..."

if [ "$INIT" = "openrc" ]; then
    # Hermes
    cat > /etc/init.d/hermes-dashboard << 'EOF'
#!/sbin/openrc-run
name="hermes-dashboard"
description="Hermes Agent Web Dashboard"
command="/usr/bin/hermes"
command_args="dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build"
command_background=true
pidfile="/run/hermes-dashboard.pid"
output_log="/var/log/hermes-dashboard.log"
error_log="/var/log/hermes-dashboard.log"

depend() { need net; after firewall; }

start_pre() {
    checkpath -f -m 0644 -o root:root /var/log/hermes-dashboard.log
    checkpath -d -m 0755 -o root:root /run
}
EOF

    # Traefik
    cat > /etc/init.d/traefik << 'EOF'
#!/sbin/openrc-run
name="traefik"
description="Traefik Reverse Proxy (HTTP only - Central terminates TLS)"
command="/usr/sbin/traefik"
command_args="--configfile=/etc/traefik/traefik.yaml"
command_background=true
pidfile="/run/traefik.pid"
output_log="/var/log/traefik/traefik.log"
error_log="/var/log/traefik/traefik.log"

depend() { need net; after firewall; }

start_pre() {
    checkpath -f -m 0644 -o traefik:traefik /var/log/traefik/traefik.log
    checkpath -f -m 0644 -o traefik:traefik /var/log/traefik/access.log
    checkpath -d -m 0755 -o traefik:traefik /run
}
EOF

    chmod +x /etc/init.d/hermes-dashboard /etc/init.d/traefik
    rc-update add hermes-dashboard default
    rc-update add traefik default
    rc-service hermes-dashboard start
    rc-service traefik start

else
    # systemd
    cat > /etc/systemd/system/hermes-dashboard.service << EOF
[Unit]
Description=Hermes Agent Web Dashboard
After=network.target

[Service]
Type=simple
User=root
Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$DASH_USER
Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$DASH_PASS
Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=$DASH_SECRET
ExecStart=/usr/local/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/hermes-dashboard.log
StandardError=append:/var/log/hermes-dashboard.log

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/traefik.service << EOF
[Unit]
Description=Traefik Reverse Proxy
After=network.target

[Service]
Type=simple
User=traefik
ExecStart=/usr/local/bin/traefik --configfile=/etc/traefik/traefik.yaml
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/traefik/traefik.log
StandardError=append:/var/log/traefik/traefik.log

[Install]
WantedBy=multi-user.target
EOF

    useradd -r -s /bin/false traefik 2>/dev/null || true
    chown -R traefik:traefik /var/log/traefik /var/lib/traefik /etc/traefik

    systemctl daemon-reload
    systemctl enable --now hermes-dashboard traefik
fi

# ============================================
# AGUARDAR SUBIR
# ============================================
log "Aguardando serviços subirem..."
sleep 10

# ============================================
# VERIFICAÇÕES
# ============================================
log "Verificando..."

# Hermes
if curl -sf http://127.0.0.1:9119/ >/dev/null; then
    log "Hermes dashboard: OK (porta 9119)"
else
    warn "Hermes dashboard pode não estar pronto ainda"
fi

# Traefik local
if curl -sf -H "Host: $DOMAIN" http://127.0.0.1/ >/dev/null; then
    log "Traefik local: OK (porta 80, Host: $DOMAIN)"
else
    warn "Traefik local pode não estar roteando ainda"
fi

# ============================================
# INSTRUÇÕES PARA CENTRAL
# ============================================
SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')

echo
echo "============================================"
echo "  INSTALAÇÃO CONCLUÍDA"
echo "============================================"
echo
echo "Servidor: $SERVER_IP"
echo "Domínio: $DOMAIN"
echo "Dashboard: http://$SERVER_IP:9119 (local)"
echo "Via Traefik local: http://$DOMAIN (precisa Central)"
echo
echo "--------------------------------------------"
echo "ADICIONE NO TRAEFIK CENTRAL (servers.yml):"
echo "--------------------------------------------"
cat << EOF

  # Router para $DOMAIN (Central termina TLS)
  ${DOMAIN//./-}:
    rule: "Host(\`$DOMAIN\`)"
    entryPoints:
      - websecure
    service: ${DOMAIN//./-}-svc
    tls:
      certResolver: letsencrypt
      domains:
        - main: $DOMAIN

  services:
    ${DOMAIN//./-}-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://$SERVER_IP"   # HTTP na porta 80 do servidor
EOF

echo
echo "--------------------------------------------"
echo "DEPOIS: docker service update --force traefik-central_traefik-central"
echo "--------------------------------------------"
echo
echo "Credenciais Dashboard:"
echo "  User: $DASH_USER"
echo "  Pass: (a que você digitou)"
echo
echo "Arquivos importantes:"
echo "  Config Hermes: $HERMES_HOME/config.yaml"
echo "  Traefik static: /etc/traefik/traefik.yaml"
echo "  Traefik dynamic: /etc/traefik/dynamic/hermes.yaml"
echo "  Logs: /var/log/hermes-dashboard.log /var/log/traefik/"