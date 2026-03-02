#!/bin/bash

# ============================================================================
# 🚀 INSTALADOR DO TRAEFIK CENTRAL
# ============================================================================
# Estratégia: HTTP Proxy (porta 80) + TCP Passthrough (porta 443)
#
# Fluxo:
#   INTERNET → MIKROTIK → TRAEFIK CENTRAL
#                              ├─ porta 80  → HTTP Proxy por domínio → servidor correto
#                              └─ porta 443 → TCP Passthrough por SNI → servidor correto
#
# ✅ Os servidores de destino continuam gerando seus próprios certificados
# ✅ Renovação automática do Let's Encrypt via TLS-ALPN-01 (porta 443)
# ✅ Zero alterações nas stacks existentes após correção do challenge
# ============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

header()    { echo -e "\n${BLUE}================================================================${NC}\n${BOLD}${WHITE}  $1${NC}\n${BLUE}================================================================${NC}"; }
step()      { echo -e "\n${CYAN}▶ $1${NC}"; }
ok()        { echo -e "  ${GREEN}✔ $1${NC}"; }
warn()      { echo -e "  ${YELLOW}⚠ $1${NC}"; }
erro()      { echo -e "  ${RED}✖ $1${NC}"; }
info()      { echo -e "  ${WHITE}ℹ $1${NC}"; }
separador() { echo -e "${BLUE}----------------------------------------------------------------${NC}"; }
pausar()    { echo -e "\n${YELLOW}Pressione ENTER para continuar...${NC}"; read -r < /dev/tty; }

# ============================================================================
# ROOT
# ============================================================================
verificar_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✖ Execute como root: sudo bash $0${NC}"
        exit 1
    fi
}

# ============================================================================
# LOGS
# ============================================================================
verificar_logs_recentes() {
    local LINES="${1:-10}"
    echo -e "\n${CYAN}📄 ÚLTIMOS LOGS (${LINES} linhas):${NC}"
    separador
    if docker stack ls 2>/dev/null | grep -q "traefik-central"; then
        docker service logs --tail "$LINES" traefik-central_traefik-central 2>/dev/null || warn "Não foi possível ler logs."
    else
        warn "Nenhum serviço Traefik Central encontrado."
    fi
    separador
}

# ============================================================================
# VERIFICAR STATUS DE CERTIFICADOS (opção 8)
# ============================================================================
verificar_certificados() {
    header "🔐 STATUS DOS CERTIFICADOS SSL"

    DOMINIOS_LIST=()

    # Coletar do servers.yml (servidor central)
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    if [ -f "$SERVERS_FILE" ]; then
        step "Coletando domínios do servers.yml..."
        while IFS= read -r dom; do
            DOMINIOS_LIST+=("$dom")
        done < <(grep -oP "(?<=HostSNI\(\`)([^\`]+)(?=\`\))" "$SERVERS_FILE" 2>/dev/null || true)
    fi

    # Coletar do acme.json local (servidor destino)
    for VOL in volume_swarm_certificates traefik-certs vol_certificates; do
        MP=$(docker volume inspect "$VOL" 2>/dev/null | grep -oP '"Mountpoint": "\K[^"]+' || echo "")
        if [ -n "$MP" ] && [ -f "${MP}/acme.json" ]; then
            step "Coletando domínios do acme.json..."
            while IFS= read -r dom; do
                DOMINIOS_LIST+=("$dom")
            done < <(cat "${MP}/acme.json" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for r in d.values():
        for c in r.get('Certificates',[]):
            main=c.get('domain',{}).get('main','')
            if main: print(main)
            for s in c.get('domain',{}).get('sans',[]): print(s)
except: pass
" 2>/dev/null | sort -u || true)
        fi
    done

    if [ ${#DOMINIOS_LIST[@]} -eq 0 ]; then
        warn "Nenhum domínio encontrado para verificar."
        info "Execute no servidor Central (opção 6 lista os servidores) ou no servidor destino."
        return
    fi

    mapfile -t DOMINIOS_LIST < <(printf '%s\n' "${DOMINIOS_LIST[@]}" | sort -u)
    echo -e "\n  Verificando ${#DOMINIOS_LIST[@]} domínio(s)...\n"
    separador

    local OK=0 PADRAO=0 ERRO=0 EXPIRANDO=0

    for DOM in "${DOMINIOS_LIST[@]}"; do
        RESULT=$(echo | timeout 5 openssl s_client -connect "${DOM}:443" \
            -servername "$DOM" 2>/dev/null | \
            openssl x509 -noout -issuer -dates 2>/dev/null || echo "ERRO")

        if [ "$RESULT" = "ERRO" ] || [ -z "$RESULT" ]; then
            erro "$DOM → sem resposta"
            ERRO=$((ERRO+1))
            continue
        fi

        ISSUER=$(echo "$RESULT" | grep issuer | head -1)
        NOT_AFTER=$(echo "$RESULT" | grep notAfter | sed 's/notAfter=//')

        if echo "$ISSUER" | grep -qi "TRAEFIK DEFAULT"; then
            warn "$DOM → ⚠ CERTIFICADO PADRÃO (Let's Encrypt não obtido ainda)"
            PADRAO=$((PADRAO+1))
            continue
        fi

        if [ -n "$NOT_AFTER" ]; then
            EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [ "$DAYS_LEFT" -lt 0 ]; then
                erro "$DOM → ❌ EXPIRADO há $(( DAYS_LEFT * -1 )) dias"
                ERRO=$((ERRO+1))
            elif [ "$DAYS_LEFT" -lt 15 ]; then
                warn "$DOM → ⚠ Expira em ${DAYS_LEFT} dias!"
                EXPIRANDO=$((EXPIRANDO+1))
            else
                ok "$DOM → ✅ Válido por ${DAYS_LEFT} dias"
                OK=$((OK+1))
            fi
        fi
    done

    separador
    echo -e "\n${WHITE}${BOLD}  RESUMO:${NC}"
    ok "Válidos: $OK"
    [ "$EXPIRANDO" -gt 0 ] && warn "Expirando em breve: $EXPIRANDO — verifique renovação automática"
    [ "$PADRAO" -gt 0 ]    && warn "Certificado padrão: $PADRAO — rode opção 7 no servidor destino"
    [ "$ERRO" -gt 0 ]      && erro "Sem resposta/expirados: $ERRO"
    separador
}

# ============================================================================
# DIAGNÓSTICO
# ============================================================================
diagnostico_sistema() {
    header "🔍 DIAGNÓSTICO DO SISTEMA"

    step "Sistema Operacional"
    [ -f /etc/os-release ] && { . /etc/os-release; ok "OS: $PRETTY_NAME"; } || warn "OS não identificado"
    ok "Arquitetura: $(uname -m)"

    step "Memória RAM"
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
    [ "$MEM_AVAIL" -lt 256 ] && warn "RAM: ${MEM_AVAIL}MB / ${MEM_TOTAL}MB" || ok "RAM: ${MEM_AVAIL}MB / ${MEM_TOTAL}MB"

    step "Disco"
    DISCO_LIVRE=$(df -Pk / | awk 'NR==2 {print int($4/1024)}')
    [ "$DISCO_LIVRE" -lt 1024 ] && warn "Livre: ${DISCO_LIVRE}MB" || ok "Livre: ${DISCO_LIVRE}MB"

    step "IP"
    ok "IP local: $(hostname -I | awk '{print $1}')"

    step "Portas (80, 443, 8080)"
    for PORT in 80 443 8080; do
        USANDO=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | awk '{print $NF}' | grep -oP 'pid=\K[0-9]+' | head -1)
        if [ -n "$USANDO" ]; then
            PROC=$(cat /proc/$USANDO/comm 2>/dev/null || echo "desconhecido")
            warn "Porta $PORT: em uso por $PROC"
        else
            ok "Porta $PORT: livre"
        fi
    done

    step "Docker"
    command -v docker &>/dev/null && ok "Docker: v$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)" || warn "Docker não instalado"

    step "Docker Swarm"
    docker info 2>/dev/null | grep -q "Swarm: active" && ok "Swarm: ativo" || warn "Swarm não inicializado"

    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    if [ -f "$SERVERS_FILE" ]; then
        step "servers.yml atual"
        cat "$SERVERS_FILE" | sed 's/^/  /'
    fi

    echo -e "\n  ${CYAN}1)${NC} Ver logs  ${CYAN}0)${NC} Voltar"
    read -p "Escolha: " OPT_LOG < /dev/tty
    [ "$OPT_LOG" = "1" ] && { verificar_logs_recentes 50; docker service logs -f traefik-central_traefik-central 2>/dev/null || true; }
}

# ============================================================================
# DETECTAR TRAEFIK EXISTENTE
# ============================================================================
verificar_traefik_existente() {
    header "🔎 VERIFICANDO TRAEFIK(S) INSTALADOS"
    TRAEFIK_ENCONTRADO=false

    step "Stacks..."
    STACKS=$(docker stack ls 2>/dev/null | grep -i traefik | awk '{print $1}' || true)
    if [ -n "$STACKS" ]; then
        TRAEFIK_ENCONTRADO=true
        while IFS= read -r STACK; do warn "Stack: $STACK"; done <<< "$STACKS"
    else
        ok "Nenhuma stack Traefik"
    fi

    step "Containers..."
    CONTAINERS=$(docker ps -a --filter "name=traefik" --format "{{.Names}}|{{.Status}}" 2>/dev/null || true)
    if [ -n "$CONTAINERS" ]; then
        TRAEFIK_ENCONTRADO=true
        while IFS= read -r l; do warn "Container: $(echo $l | cut -d'|' -f1) | $(echo $l | cut -d'|' -f2)"; done <<< "$CONTAINERS"
    else
        ok "Nenhum container"
    fi

    step "Redes..."
    REDES=$(docker network ls --format "{{.Name}}" 2>/dev/null | grep -i traefik || true)
    [ -n "$REDES" ] && while IFS= read -r r; do info "Rede: $r"; done <<< "$REDES" || ok "Nenhuma"

    separador
    [ "$TRAEFIK_ENCONTRADO" = true ] && \
        echo -e "\n${YELLOW}⚠ Traefik detectado neste servidor.${NC}" || \
        echo -e "\n${GREEN}✔ Ambiente limpo!${NC}"
}

# ============================================================================
# MENU REMOÇÃO
# ============================================================================
menu_remocao() {
    header "🗑️ REMOÇÃO"
    echo -e "${RED}${BOLD}ATENÇÃO: Irreversível.${NC}\n"
    echo -e "  ${CYAN}1)${NC} Remover stack traefik-central"
    echo -e "  ${CYAN}2)${NC} Remover stack específica"
    echo -e "  ${CYAN}3)${NC} Remover container standalone"
    echo -e "  ${CYAN}4)${NC} Remover TUDO"
    echo -e "  ${CYAN}5)${NC} Remover binário + systemd"
    echo -e "  ${CYAN}0)${NC} Voltar\n"
    read -p "Escolha: " OPCAO_REMOVE < /dev/tty

    case "$OPCAO_REMOVE" in
        1) remover_stack "traefik-central" ;;
        2) docker stack ls; read -p "Nome: " NS < /dev/tty; remover_stack "$NS" ;;
        3) docker ps -a --filter "name=traefik" --format "{{.Names}}"; read -p "Nome: " NC_REM < /dev/tty; remover_container "$NC_REM" ;;
        4) remover_tudo ;;
        5) remover_binario_systemd ;;
        0) return ;;
        *) erro "Inválido" ;;
    esac
}

remover_stack() {
    read -p "Remover '$1'? Digite 'sim': " C < /dev/tty
    if [ "$C" = "sim" ]; then
        docker stack rm "$1" 2>/dev/null && ok "Removida" || erro "Não encontrada"
        sleep 8
        read -p "Remover redes/volumes relacionados? (s/N): " RE < /dev/tty
        if [[ "$RE" =~ ^[Ss]$ ]]; then
            docker network ls --format "{{.Name}}" | grep -i traefik | xargs -r docker network rm 2>/dev/null && ok "Redes removidas" || true
            docker volume ls --format "{{.Name}}" | grep -i traefik | xargs -r docker volume rm 2>/dev/null && ok "Volumes removidos" || true
        fi
    else
        warn "Cancelado."
    fi
}

remover_container() {
    read -p "Remover '$1'? Digite 'sim': " C < /dev/tty
    [ "$C" = "sim" ] && { docker stop "$1" 2>/dev/null || true; docker rm "$1" 2>/dev/null && ok "Removido" || erro "Erro"; } || warn "Cancelado."
}

remover_tudo() {
    read -p "Digite 'REMOVER TUDO': " C < /dev/tty
    if [ "$C" = "REMOVER TUDO" ]; then
        docker stack ls 2>/dev/null | grep -i traefik | awk '{print $1}' | xargs -r docker stack rm 2>/dev/null; sleep 10
        docker ps -a --filter "name=traefik" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
        docker network ls --format "{{.Name}}" | grep -i traefik | xargs -r docker network rm 2>/dev/null || true
        docker volume ls --format "{{.Name}}" | grep -i traefik | xargs -r docker volume rm 2>/dev/null || true
        docker images --filter "reference=traefik*" --format "{{.ID}}" | xargs -r docker rmi -f 2>/dev/null || true
        rm -rf /root/traefik-central 2>/dev/null || true
        ok "Remoção completa!"
    else
        warn "Cancelado."
    fi
}

remover_binario_systemd() {
    read -p "Remover binário + systemd? Digite 'sim': " C < /dev/tty
    if [ "$C" = "sim" ]; then
        systemctl stop traefik 2>/dev/null || true
        systemctl disable traefik 2>/dev/null || true
        rm -f /etc/systemd/system/traefik.service /usr/local/bin/traefik
        rm -rf /etc/traefik
        systemctl daemon-reload 2>/dev/null || true
        ok "Concluído!"
    else
        warn "Cancelado."
    fi
}

# ============================================================================
# DEPENDÊNCIAS
# ============================================================================
instalar_dependencias() {
    header "📦 DEPENDÊNCIAS"

    for DEP in curl openssl python3; do
        command -v $DEP &>/dev/null && ok "$DEP: OK" || {
            apt-get update -qq && apt-get install -y -qq $DEP && ok "$DEP instalado"
        }
    done

    command -v docker &>/dev/null && ok "Docker: OK" || {
        curl -fsSL https://get.docker.com | bash && ok "Docker instalado"
    }

    systemctl is-active --quiet docker || { systemctl enable docker && systemctl start docker && ok "Docker iniciado"; }

    docker info 2>/dev/null | grep -q "Swarm: active" && ok "Swarm: ativo" || {
        IP=$(hostname -I | awk '{print $1}')
        docker swarm init --advertise-addr "$IP" && ok "Swarm inicializado: $IP"
    }
}

# ============================================================================
# COLETAR CONFIGURAÇÕES
# ============================================================================
coletar_configuracoes() {
    header "⚙️ CONFIGURAÇÃO"

    while true; do
        read -p "  Domínio do dashboard: " DASH_DOMAIN < /dev/tty
        [ -n "$DASH_DOMAIN" ] && break
        erro "Obrigatório."
    done

    while true; do
        read -p "  Email Let's Encrypt: " EMAIL < /dev/tty
        [[ "$EMAIL" == *"@"*"."* ]] && break
        erro "Email inválido."
    done

    read -p "  Usuário dashboard [admin]: " DASH_USER < /dev/tty
    DASH_USER="${DASH_USER:-admin}"

    while true; do
        read -s -p "  Senha: " DASH_PASS < /dev/tty; echo
        read -s -p "  Confirme: " DASH_PASS_CONF < /dev/tty; echo
        [ "$DASH_PASS" = "$DASH_PASS_CONF" ] && [ -n "$DASH_PASS" ] && break
        erro "Senhas não conferem."
    done

    HASH=$(openssl passwd -apr1 "$DASH_PASS")
    ok "Dashboard: https://${DASH_DOMAIN}:8080"

    separador
    echo -e "\n${YELLOW}🖥️ SERVIDORES DESTINO${NC}"
    echo -e "${RED}IMPORTANTE: Informe TODOS os domínios de cada servidor.${NC}"
    echo -e "${WHITE}Isso garante que o Let's Encrypt renove todos os certificados.${NC}\n"

    ROUTERS_TCP_CONFIG=""
    SERVICES_TCP_CONFIG=""
    ROUTERS_HTTP_CONFIG=""
    SERVICES_HTTP_CONFIG=""
    SERVER_COUNT=0
    SERVERS_SUMMARY=""

    while true; do
        SERVER_COUNT=$((SERVER_COUNT + 1))
        echo -e "${BLUE}  --- Servidor $SERVER_COUNT ---${NC}"

        read -p "  Nome [vazio para parar]: " SERVER_NAME < /dev/tty
        if [ -z "$SERVER_NAME" ]; then SERVER_COUNT=$((SERVER_COUNT - 1)); break; fi
        [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { erro "Nome inválido."; SERVER_COUNT=$((SERVER_COUNT - 1)); continue; }

        while true; do
            read -p "  IP: " SERVER_IP < /dev/tty
            [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
            erro "IP inválido."
        done

        read -p "  Porta HTTPS [443]: " SERVER_PORT_HTTPS < /dev/tty; SERVER_PORT_HTTPS="${SERVER_PORT_HTTPS:-443}"
        read -p "  Porta HTTP [80]: " SERVER_PORT_HTTP < /dev/tty; SERVER_PORT_HTTP="${SERVER_PORT_HTTP:-80}"

        ALL_DOMAINS=()
        while true; do
            while true; do
                read -p "  Domínio base: " BASE_DOMAIN < /dev/tty
                BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                [[ "$BASE_DOMAIN" =~ \. ]] && break
                erro "Inválido."
            done
            echo -e "  ${CYAN}Subdomínios para .${BASE_DOMAIN} (espaço):${NC}"
            while true; do
                read -p "  Subdomínios: " SUBS_INPUT < /dev/tty
                [ -n "$SUBS_INPUT" ] && break
                erro "Obrigatório."
            done
            for sub in $SUBS_INPUT; do
                FULL="$(echo "$sub" | tr -d ' .' | tr '[:upper:]' '[:lower:]').${BASE_DOMAIN}"
                ALL_DOMAINS+=("$FULL")
                ok "  $FULL"
            done
            read -p "  Mais domínios base? (s/N): " MORE < /dev/tty
            [[ "$MORE" =~ ^[Ss]$ ]] || break
        done

        RULE_TCP=""
        RULE_HTTP=""
        for dom in "${ALL_DOMAINS[@]}"; do
            [ -n "$RULE_TCP" ] && RULE_TCP="${RULE_TCP} || "
            [ -n "$RULE_HTTP" ] && RULE_HTTP="${RULE_HTTP} || "
            RULE_TCP="${RULE_TCP}HostSNI(\`${dom}\`)"
            RULE_HTTP="${RULE_HTTP}Host(\`${dom}\`)"
        done

        ROUTERS_TCP_CONFIG="${ROUTERS_TCP_CONFIG}
    ${SERVER_NAME}-https:
      rule: \"${RULE_TCP}\"
      entryPoints:
        - websecure
      service: ${SERVER_NAME}-https-svc
      tls:
        passthrough: true
"
        SERVICES_TCP_CONFIG="${SERVICES_TCP_CONFIG}
    ${SERVER_NAME}-https-svc:
      loadBalancer:
        servers:
          - address: \"${SERVER_IP}:${SERVER_PORT_HTTPS}\"
"
        ROUTERS_HTTP_CONFIG="${ROUTERS_HTTP_CONFIG}
    ${SERVER_NAME}-http:
      rule: \"${RULE_HTTP}\"
      entryPoints:
        - web
      service: ${SERVER_NAME}-http-svc
      priority: 100
"
        SERVICES_HTTP_CONFIG="${SERVICES_HTTP_CONFIG}
    ${SERVER_NAME}-http-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: \"http://${SERVER_IP}:${SERVER_PORT_HTTP}\"
"
        DOMS_STR=$(printf '%s, ' "${ALL_DOMAINS[@]}" | sed 's/, $//')
        ok "Servidor '${SERVER_NAME}': ${#ALL_DOMAINS[@]} domínio(s) → ${SERVER_IP}"
        SERVERS_SUMMARY="${SERVERS_SUMMARY}\n  • ${SERVER_NAME}: ${DOMS_STR} → ${SERVER_IP}"

        read -p "  Outro servidor? (s/N): " CONTINUE < /dev/tty
        [[ "$CONTINUE" =~ ^[Ss]$ ]] || break
    done
}

# ============================================================================
# CRIAR ARQUIVOS
# ============================================================================
criar_arquivos() {
    header "📝 CRIANDO ARQUIVOS"

    BASE_DIR="/root/traefik-central"
    mkdir -p "$BASE_DIR/dynamic-config"

    cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.8"
services:
  traefik-central:
    image: traefik:v3.3
    command:
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.dashboard.address=:8080"
      - "--providers.swarm=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--providers.swarm.network=traefik-central-net"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.email=${EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/etc/traefik/certificates/acme.json"
      - "--log.level=INFO"
      - "--accesslog=true"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "traefik-certs:/etc/traefik/certificates"
      - "./dynamic-config:/etc/traefik/dynamic:ro"
    networks:
      - traefik-central-net
    ports:
      - target: 80
        published: 80
        mode: host
      - target: 443
        published: 443
        mode: host
      - target: 8080
        published: 8080
        mode: host
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=false"
networks:
  traefik-central-net:
    external: true
volumes:
  traefik-certs:
    external: true
EOF
    ok "docker-compose.yml"

    cat > "$BASE_DIR/dynamic-config/dashboard.yml" <<EOF
http:
  routers:
    dashboard:
      rule: "Host(\`${DASH_DOMAIN}\`)"
      entryPoints: [dashboard]
      service: api@internal
      middlewares: [dashboard-redirect@file, basicauth@file]
EOF
    ok "dashboard.yml"

    cat > "$BASE_DIR/dynamic-config/middlewares.yml" <<EOF
http:
  middlewares:
    dashboard-redirect:
      redirectRegex:
        regex: "^(http|https)://([^/]+)/?\$"
        replacement: "\${1}://\${2}/dashboard/"
    basicauth:
      basicAuth:
        users:
          - "${DASH_USER}:${HASH}"
EOF
    ok "middlewares.yml"

    if [ "$SERVER_COUNT" -gt 0 ]; then
        cat > "$BASE_DIR/dynamic-config/servers.yml" <<EOF
# ============================================================================
# ROTEAMENTO - TRAEFIK CENTRAL
# ============================================================================
# PORTA 443 — TCP Passthrough (SNI): certificados ficam nos servidores locais.
# PORTA 80  — HTTP Proxy: TODOS os domínios aqui para o Let's Encrypt funcionar.
# ⚠️ Use o menu opção 5 para gerenciar servidores.
# ============================================================================

# ---- PORTA 443: TCP PASSTHROUGH ----
tcp:
  routers:
${ROUTERS_TCP_CONFIG}
  services:
${SERVICES_TCP_CONFIG}

# ---- PORTA 80: HTTP PROXY ----
http:
  routers:
${ROUTERS_HTTP_CONFIG}
  services:
${SERVICES_HTTP_CONFIG}
EOF
    else
        echo "# Use o menu opção 5 para adicionar servidores." > "$BASE_DIR/dynamic-config/servers.yml"
    fi
    ok "servers.yml"
    info "Arquivos em: $BASE_DIR"
}

# ============================================================================
# SCRIPTS PYTHON AUXILIARES
# ============================================================================
criar_script_auxiliar() {
    cat > /tmp/traefik_add.py << 'PYADD'
import sys, re

filepath, name, ip, port_https, port_http, rule_tcp, rule_http = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]

r_tcp  = f"\n    {name}-https:\n      rule: \"{rule_tcp}\"\n      entryPoints:\n        - websecure\n      service: {name}-https-svc\n      tls:\n        passthrough: true\n"
s_tcp  = f"\n    {name}-https-svc:\n      loadBalancer:\n        servers:\n          - address: \"{ip}:{port_https}\"\n"
r_http = f"\n    {name}-http:\n      rule: \"{rule_http}\"\n      entryPoints:\n        - web\n      service: {name}-http-svc\n      priority: 100\n"
s_http = f"\n    {name}-http-svc:\n      loadBalancer:\n        passHostHeader: true\n        servers:\n          - url: \"http://{ip}:{port_http}\"\n"

with open(filepath, "r") as f:
    content = f.read()

has_tcp  = bool(re.search(r"^tcp:", content, re.MULTILINE))
has_http = bool(re.search(r"^http:", content, re.MULTILINE))

if not has_tcp or not has_http:
    new_content = (
        "# ROTEAMENTO - TRAEFIK CENTRAL\n\n"
        "# ---- PORTA 443: TCP PASSTHROUGH ----\n"
        "tcp:\n  routers:\n" + r_tcp + "\n  services:\n" + s_tcp + "\n"
        "# ---- PORTA 80: HTTP PROXY ----\n"
        "http:\n  routers:\n" + r_http + "\n  services:\n" + s_http + "\n"
    )
    with open(filepath, "w") as f:
        f.write(new_content)
else:
    content = re.sub(r"(tcp:\n  routers:)(.*?)(  services:)", lambda m: f"{m.group(1)}{m.group(2)}{r_tcp}{m.group(3)}", content, flags=re.DOTALL)
    content = re.sub(r"(  services:)(.*?)(# ---- PORTA 80)", lambda m: f"{m.group(1)}{m.group(2)}{s_tcp}\n{m.group(3)}", content, flags=re.DOTALL)
    content = re.sub(r"(http:\n  routers:)(.*?)(  services:)", lambda m: f"{m.group(1)}{m.group(2)}{r_http}{m.group(3)}", content, flags=re.DOTALL)
    content = content.rstrip() + "\n" + s_http
    with open(filepath, "w") as f:
        f.write(content)
print("OK")
PYADD

    cat > /tmp/traefik_remove.py << 'PYREMOVE'
import sys, re
filepath, name = sys.argv[1], sys.argv[2]
with open(filepath, "r") as f:
    lines = f.readlines()
result = []
skip = False
for line in lines:
    if re.match(rf"^    {re.escape(name)}-(https|https-svc|http|http-svc):\s*$", line):
        skip = True; continue
    if skip:
        stripped = line.rstrip()
        if stripped == "" or (len(stripped) - len(stripped.lstrip()) > 4): continue
        else: skip = False
    if not skip:
        result.append(line)
content = "".join(result)
if not re.search(r"^    [a-zA-Z]", content, re.MULTILINE):
    content = "# Nenhum servidor configurado. Use o menu opção 5.\n"
else:
    content = re.sub(r"\n{3,}", "\n\n", content)
with open(filepath, "w") as f:
    f.write(content)
print(f"Servidor '{name}' removido.")
PYREMOVE
}

# ============================================================================
# DEPLOY
# ============================================================================
fazer_deploy() {
    header "🚀 DEPLOY"
    criar_script_auxiliar

    step "Rede traefik-central-net..."
    docker network create --driver overlay --attachable traefik-central-net 2>/dev/null && ok "Criada" || warn "Já existe"

    step "Volume traefik-certs..."
    docker volume create traefik-certs 2>/dev/null && ok "Criado" || warn "Já existe"

    step "Deploy..."
    docker stack deploy -c /root/traefik-central/docker-compose.yml traefik-central
    ok "Deploy iniciado!"

    step "Aguardando (20s)..."
    for i in $(seq 1 20); do echo -ne "  ${CYAN}[$i/20]${NC}\r"; sleep 1; done; echo
}

# ============================================================================
# PÓS-INSTALAÇÃO
# ============================================================================
verificar_pos_instalacao() {
    header "✅ VERIFICAÇÃO"
    docker stack ls | grep traefik-central && ok "Stack ativa" || erro "Stack não encontrada!"
    REPLICAS=$(docker service ls --filter "name=traefik-central_traefik-central" --format "{{.Replicas}}" 2>/dev/null || echo "0/0")
    [[ "$REPLICAS" == "1/1" ]] && ok "Serviço: $REPLICAS ✔" || warn "Serviço: $REPLICAS"
    for PORT in 80 443 8080; do
        ss -tlnp | grep -q ":${PORT} " && ok "Porta $PORT: ok" || warn "Porta $PORT: aguarde"
    done
}

# ============================================================================
# RESUMO
# ============================================================================
resumo_final() {
    header "📋 INSTALAÇÃO CONCLUÍDA"
    echo -e "\n${GREEN}${BOLD}🎉 TRAEFIK CENTRAL INSTALADO!${NC}\n"
    separador
    echo -e "  ${WHITE}Dashboard:${NC} https://${DASH_DOMAIN}:8080 (${DASH_USER})"
    [ "$SERVER_COUNT" -gt 0 ] && echo -e "\n  ${WHITE}Servidores:${NC}${SERVERS_SUMMARY}"
    separador
    echo -e "\n${RED}${BOLD}  ⚠ PRÓXIMO PASSO OBRIGATÓRIO:${NC}"
    echo -e "  ${YELLOW}Rode a opção 7 em CADA servidor destino!${NC}"
    echo -e "  ${WHITE}Sem isso os certificados não renovarão atrás do Central.${NC}"
    separador
    echo -e "\n${BLUE}================================================================${NC}"
    echo -e "${GREEN}${BOLD}  ✅ PRONTO!${NC}"
    echo -e "${BLUE}================================================================${NC}\n"
}

# ============================================================================
# GARANTIR servers.yml
# ============================================================================
garantir_servers_yml() {
    local F="/root/traefik-central/dynamic-config/servers.yml"
    [ -f "$F" ] && return
    warn "servers.yml não encontrado. Recriando..."
    mkdir -p "/root/traefik-central/dynamic-config"
    echo "# Use o menu opção 5 para adicionar servidores." > "$F"
    ok "servers.yml recriado."
}

# ============================================================================
# ADICIONAR SERVIDOR
# ============================================================================
adicionar_servidor() {
    header "➕ ADICIONAR SERVIDOR"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml

    while true; do
        read -p "  Nome: " SERVER_NAME < /dev/tty
        [ -z "$SERVER_NAME" ] && { erro "Obrigatório."; continue; }
        [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { erro "Inválido."; continue; }
        grep -q "^    ${SERVER_NAME}-https:" "$SERVERS_FILE" 2>/dev/null && { erro "Já existe!"; continue; }
        break
    done

    while true; do
        read -p "  IP: " SERVER_IP < /dev/tty
        [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        erro "IP inválido."
    done

    read -p "  Testar conectividade? (S/n): " T < /dev/tty
    if [[ ! "$T" =~ ^[Nn]$ ]]; then
        ping -c 1 -W 2 "$SERVER_IP" &>/dev/null && ok "Ping OK" || {
            timeout 2 bash -c "</dev/tcp/$SERVER_IP/443" 2>/dev/null && ok "Porta 443 OK" || {
                erro "Sem resposta de $SERVER_IP"
                read -p "Continuar? (s/N): " C < /dev/tty
                [[ "$C" =~ ^[Ss]$ ]] || return
            }
        }
    fi

    read -p "  Porta HTTPS [443]: " SERVER_PORT_HTTPS < /dev/tty; SERVER_PORT_HTTPS="${SERVER_PORT_HTTPS:-443}"
    read -p "  Porta HTTP [80]: " SERVER_PORT_HTTP < /dev/tty; SERVER_PORT_HTTP="${SERVER_PORT_HTTP:-80}"

    ALL_DOMAINS=()
    separador
    echo -e "\n  ${RED}IMPORTANTE: Informe TODOS os domínios deste servidor.${NC}"
    echo -e "  ${WHITE}Domínios ausentes aqui não conseguirão renovar certificado.${NC}\n"

    while true; do
        while true; do
            read -p "  Domínio base: " BASE_DOMAIN < /dev/tty
            BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            [[ "$BASE_DOMAIN" =~ \. ]] && break
            erro "Inválido."
        done
        echo -e "  ${CYAN}Subdomínios para .${BASE_DOMAIN}:${NC}"
        while true; do
            read -p "  Subdomínios: " SUBS_INPUT < /dev/tty
            [ -n "$SUBS_INPUT" ] && break
            erro "Obrigatório."
        done
        for sub in $SUBS_INPUT; do
            FULL="$(echo "$sub" | tr -d ' .' | tr '[:upper:]' '[:lower:]').${BASE_DOMAIN}"
            ALL_DOMAINS+=("$FULL"); ok "  $FULL"
        done
        read -p "  Mais domínios base? (s/N): " M < /dev/tty
        [[ "$M" =~ ^[Ss]$ ]] || break
    done

    RULE_TCP=""
    RULE_HTTP=""
    for dom in "${ALL_DOMAINS[@]}"; do
        [ -n "$RULE_TCP" ] && RULE_TCP="${RULE_TCP} || "
        [ -n "$RULE_HTTP" ] && RULE_HTTP="${RULE_HTTP} || "
        RULE_TCP="${RULE_TCP}HostSNI(\`${dom}\`)"
        RULE_HTTP="${RULE_HTTP}Host(\`${dom}\`)"
    done

    separador
    info "Servidor: $SERVER_NAME → $SERVER_IP"
    echo -e "  ${WHITE}Domínios (${#ALL_DOMAINS[@]}):${NC}"
    for dom in "${ALL_DOMAINS[@]}"; do echo -e "    ${CYAN}→${NC} $dom"; done

    read -p "  Confirmar? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 /tmp/traefik_add.py "$SERVERS_FILE" "$SERVER_NAME" "$SERVER_IP" \
        "$SERVER_PORT_HTTPS" "$SERVER_PORT_HTTP" "$RULE_TCP" "$RULE_HTTP"

    ok "Servidor '${SERVER_NAME}' adicionado com ${#ALL_DOMAINS[@]} domínio(s)!"
    sleep 4
    LOGS=$(docker service logs traefik-central_traefik-central --tail 10 2>/dev/null || true)
    echo "$LOGS" | grep -q "ERR" && { erro "Erros:"; echo "$LOGS" | grep "ERR"; } || ok "Sem erros!"
}

# ============================================================================
# SELECIONAR SERVIDOR
# ============================================================================
selecionar_servidor() {
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    ROUTERS=$(grep -E "^    [a-zA-Z0-9_-]+-https:" "$SERVERS_FILE" 2>/dev/null | \
        sed 's/://g; s/^[[:space:]]//; s/-https$//' || true)
    [ -z "$ROUTERS" ] && { warn "Nenhum servidor."; SERVER_NAME_SEL=""; return 1; }

    mapfile -t SRV_ARRAY <<< "$ROUTERS"
    echo -e "\n  ${YELLOW}${1:-Selecione:}${NC}\n"
    local i=1
    for srv in "${SRV_ARRAY[@]}"; do
        RULE=$(awk "/^    ${srv}-https:/{f=1} f && /rule:/{print; exit}" "$SERVERS_FILE" | \
            sed -E 's/HostSNI\(`//g; s/`\)//g; s/ \|\| /, /g; s/rule: "//g; s/"$//g' | xargs || echo "?")
        echo -e "  ${CYAN}${i})${NC} ${WHITE}${srv}${NC} — ${BLUE}${RULE}${NC}"
        i=$((i+1))
    done
    echo -e "  ${CYAN}0)${NC} Cancelar\n"

    while true; do
        read -p "  Escolha: " SEL < /dev/tty
        [ "$SEL" = "0" ] && { SERVER_NAME_SEL=""; return 1; }
        [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#SRV_ARRAY[@]}" ] && break
        erro "Inválido."
    done
    SERVER_NAME_SEL="${SRV_ARRAY[$((SEL-1))]}"
    ok "Selecionado: $SERVER_NAME_SEL"
}

# ============================================================================
# ADICIONAR DOMÍNIO
# ============================================================================
adicionar_dominio() {
    header "🌐 ADICIONAR DOMÍNIO"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml
    selecionar_servidor "Qual servidor?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    mapfile -t EXISTING_DOMS < <(
        awk "/^    ${SERVER_NAME}-https:/,/entryPoints:/" "$SERVERS_FILE" \
        | grep -oP "(?<=HostSNI\(\`)([^\`]+)(?=\`\))" || true)

    mapfile -t BASE_ARRAY < <(printf "%s\n" "${EXISTING_DOMS[@]}" \
        | awk -F. '{OFS="."; $1=""; print substr($0,2)}' | sort -u)

    local i=1
    for base in "${BASE_ARRAY[@]}"; do echo -e "  ${CYAN}${i})${NC} .${base}"; i=$((i+1)); done
    echo -e "  ${CYAN}${i})${NC} Outro"

    while true; do
        read -p "  Base [1-${i}]: " SEL_BASE < /dev/tty
        [[ "$SEL_BASE" =~ ^[0-9]+$ ]] && [ "$SEL_BASE" -ge 1 ] && [ "$SEL_BASE" -le "$i" ] && break
        erro "Inválido."
    done

    NEW_DOMAINS_LIST=()
    if [ "$SEL_BASE" -eq "$i" ]; then
        read -p "  Domínio completo: " FD < /dev/tty
        NEW_DOMAINS_LIST=("$(echo "$FD" | tr -d ' ')")
    else
        CHOSEN_BASE="${BASE_ARRAY[$((SEL_BASE-1))]}"
        read -p "  Subdomínios para .${CHOSEN_BASE}: " SUBS < /dev/tty
        for sub in $SUBS; do NEW_DOMAINS_LIST+=("$(echo "$sub" | tr -d ' .').${CHOSEN_BASE}"); done
    fi

    ADDED=()
    for dom in "${NEW_DOMAINS_LIST[@]}"; do
        local F=false
        for e in "${EXISTING_DOMS[@]}"; do [ "$e" = "$dom" ] && F=true && break; done
        $F || ADDED+=("$dom")
    done
    [ ${#ADDED[@]} -eq 0 ] && { warn "Já existem."; return; }

    ALL_FINAL=("${EXISTING_DOMS[@]}" "${ADDED[@]}")
    echo -e "\n  ${GREEN}Adicionando:${NC}"; for d in "${ADDED[@]}"; do ok "  $d"; done

    read -p "  Confirmar? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    RULE_TCP=""; RULE_HTTP=""
    for dom in "${ALL_FINAL[@]}"; do
        [ -n "$RULE_TCP" ] && RULE_TCP="${RULE_TCP} || "
        [ -n "$RULE_HTTP" ] && RULE_HTTP="${RULE_HTTP} || "
        RULE_TCP="${RULE_TCP}HostSNI(\`${dom}\`)"
        RULE_HTTP="${RULE_HTTP}Host(\`${dom}\`)"
    done

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$SERVERS_FILE" "$SERVER_NAME" "$RULE_TCP" "$RULE_HTTP" << 'PY'
import sys, re
f, s, rt, rh = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = open(f).read()
c = re.sub(rf'(    {re.escape(s)}-https:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{rt}"', c)
c = re.sub(rf'(    {re.escape(s)}-http:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{rh}"', c)
open(f, 'w').write(c); print("OK")
PY
    ok "Domínios adicionados!"; verificar_logs_recentes 6
}

# ============================================================================
# REMOVER DOMÍNIO
# ============================================================================
remover_dominio() {
    header "🗑️ REMOVER DOMÍNIO"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml
    selecionar_servidor "Servidor?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    mapfile -t DOM_ARRAY < <(
        awk "/^    ${SERVER_NAME}-https:/,/entryPoints:/" "$SERVERS_FILE" \
        | grep -oP "(?<=HostSNI\(\`)([^\`]+)(?=\`\))" || true)

    [ ${#DOM_ARRAY[@]} -eq 0 ] && { erro "Sem domínios."; return; }
    [ ${#DOM_ARRAY[@]} -eq 1 ] && { warn "Só 1 domínio. Use 'Remover servidor'."; return; }

    local i=1
    for dom in "${DOM_ARRAY[@]}"; do echo -e "  ${CYAN}${i})${NC} $dom"; i=$((i+1)); done
    echo -e "  ${CYAN}0)${NC} Cancelar"

    while true; do
        read -p "  Qual? " SEL < /dev/tty
        [ "$SEL" = "0" ] && { warn "Cancelado."; return; }
        [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#DOM_ARRAY[@]}" ] && break
        erro "Inválido."
    done

    DOM_R="${DOM_ARRAY[$((SEL-1))]}"
    read -p "  Remover '$DOM_R'? (s/N): " C < /dev/tty
    [[ "$C" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    NEW_SNI=""; NEW_HOST=""
    for dom in "${DOM_ARRAY[@]}"; do
        [ "$dom" = "$DOM_R" ] && continue
        [ -n "$NEW_SNI" ] && NEW_SNI="${NEW_SNI} || "
        [ -n "$NEW_HOST" ] && NEW_HOST="${NEW_HOST} || "
        NEW_SNI="${NEW_SNI}HostSNI(\`${dom}\`)"
        NEW_HOST="${NEW_HOST}Host(\`${dom}\`)"
    done

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$SERVERS_FILE" "$SERVER_NAME" "$NEW_SNI" "$NEW_HOST" << 'PY'
import sys, re
f, s, ns, nh = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = open(f).read()
c = re.sub(rf'(    {re.escape(s)}-https:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{ns}"', c)
c = re.sub(rf'(    {re.escape(s)}-http:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{nh}"', c)
open(f, 'w').write(c); print("OK")
PY
    ok "'$DOM_R' removido!"; verificar_logs_recentes 6
}

# ============================================================================
# REMOVER SERVIDOR
# ============================================================================
remover_servidor() {
    header "➖ REMOVER SERVIDOR"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml
    selecionar_servidor "Remover qual?" || return
    SERVER_NAME="$SERVER_NAME_SEL"
    read -p "  Digite 'sim': " C < /dev/tty
    [ "$C" != "sim" ] && { warn "Cancelado."; return; }
    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 /tmp/traefik_remove.py "$SERVERS_FILE" "$SERVER_NAME"
    ok "'$SERVER_NAME' removido!"; verificar_logs_recentes 6
}

# ============================================================================
# LISTAR SERVIDORES
# ============================================================================
listar_servidores() {
    header "📋 SERVIDORES"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml

    ROUTERS=$(grep -E "^\s{4}[a-zA-Z0-9_-]+-https:" "$SERVERS_FILE" | \
        sed 's/://g; s/^[[:space:]]//; s/-https$//' || true)

    if [ -n "$ROUTERS" ]; then
        while IFS= read -r r; do
            ADDR=$(awk "/^    ${r}-https-svc:/{f=1} f && /address:/{print; exit}" "$SERVERS_FILE" | \
                grep -oP '"[^"]+"' | tr -d '"' || echo "?")
            RULE=$(awk "/^    ${r}-https:/{f=1} f && /rule:/{print; exit}" "$SERVERS_FILE" | \
                sed -E 's/HostSNI\(`//g; s/`\)//g; s/ \|\| /, /g; s/rule: "//g; s/"$//g' | xargs || echo "?")
            COUNT=$(echo "$RULE" | tr ',' '\n' | wc -l)
            echo -e "  ${GREEN}✔ ${r}${NC}"
            info "  IP: $ADDR | Domínios ($COUNT): $RULE"
            echo
        done <<< "$ROUTERS"
    else
        warn "Nenhum servidor configurado."
    fi
}

# ============================================================================
# MENU GERENCIAR
# ============================================================================
menu_gerenciar_servidores() {
    header "🖥️ GERENCIAR SERVIDORES"
    echo -e "  ${CYAN}1)${NC} Vincular novo servidor"
    echo -e "  ${CYAN}2)${NC} Adicionar domínio"
    echo -e "  ${CYAN}3)${NC} Remover domínio"
    echo -e "  ${CYAN}4)${NC} Remover servidor completo"
    echo -e "  ${CYAN}0)${NC} Voltar\n"
    read -p "Escolha: " OPCAO_SERV < /dev/tty
    case "$OPCAO_SERV" in
        1) criar_script_auxiliar; adicionar_servidor ;;
        2) adicionar_dominio ;;
        3) remover_dominio ;;
        4) criar_script_auxiliar; remover_servidor ;;
        0) return ;;
        *) erro "Inválido." ;;
    esac
}

# ============================================================================
# CORRIGIR TRAEFIK LOCAL (opção 7)
# ============================================================================
corrigir_traefik_local() {
    header "🔧 CORRIGIR TRAEFIK DESTE SERVIDOR"

    echo -e "${CYAN}  Corrige o Traefik LOCAL para funcionar atrás do Traefik Central.${NC}\n"
    echo -e "${WHITE}  Alterações:${NC}"
    echo -e "  ${YELLOW}1.${NC} httpchallenge → tlschallenge"
    echo -e "  ${YELLOW}2.${NC} Remove redirect global 80→443 do entrypoint"
    echo -e "  ${YELLOW}3.${NC} Redesploya o Traefik"
    echo -e "  ${YELLOW}4.${NC} Monitora logs por 60s\n"
    echo -e "  ${RED}${BOLD}⚠ acme.json NÃO será deletado automaticamente.${NC}"
    echo -e "  ${WHITE}  Deletar causa rate limit (bloqueio Let's Encrypt por 1h+).${NC}"
    echo -e "  ${WHITE}  O script perguntará antes de qualquer ação destrutiva.${NC}\n"

    # Localizar yaml
    TRAEFIK_YAML=""
    for f in "/root/traefik.yaml" "/root/traefik/traefik.yaml" "/root/docker/traefik.yaml"; do
        [ -f "$f" ] && { TRAEFIK_YAML="$f"; break; }
    done

    step "Localizando traefik.yaml..."
    if [ -n "$TRAEFIK_YAML" ]; then
        ok "Encontrado: $TRAEFIK_YAML"
    else
        warn "Não encontrado."
        read -p "  Caminho completo: " TRAEFIK_YAML < /dev/tty
        [ ! -f "$TRAEFIK_YAML" ] && { erro "Não encontrado."; return; }
    fi

    # Estado atual
    step "Verificando configuração..."
    JA_TLS=false; TEM_HTTP=false; TEM_REDIRECT=false
    grep -q "tlschallenge=true" "$TRAEFIK_YAML" && JA_TLS=true
    grep -q "httpchallenge" "$TRAEFIK_YAML" && TEM_HTTP=true
    grep -q "redirections.entryPoint" "$TRAEFIK_YAML" && TEM_REDIRECT=true

    if $JA_TLS && ! $TEM_REDIRECT; then
        ok "Já configurado corretamente!"
        read -p "  Forçar redeploy mesmo assim? (s/N): " F < /dev/tty
        [[ "$F" =~ ^[Ss]$ ]] || return
    else
        $TEM_HTTP    && warn "httpchallenge encontrado → será trocado" || ok "httpchallenge: não encontrado"
        $TEM_REDIRECT && warn "redirect global 80→443 → será removido" || ok "redirect global: não encontrado"
    fi

    # Mostrar linhas afetadas
    separador
    echo -e "\n  ${YELLOW}Linhas que serão removidas:${NC}"
    grep -n "httpchallenge\|redirections.entryPoint" "$TRAEFIK_YAML" 2>/dev/null | sed 's/^/    ❌ /' || echo "    (nenhuma)"
    echo -e "\n  ${GREEN}Linha que será adicionada:${NC}"
    echo -e "    ✅ --certificatesresolvers.<resolver>.acme.tlschallenge=true"
    separador

    read -p "  Confirmar? Digite 'sim': " CONF < /dev/tty
    [ "$CONF" != "sim" ] && { warn "Cancelado."; return; }

    # Backup
    BACKUP="${TRAEFIK_YAML}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$TRAEFIK_YAML" "$BACKUP"
    ok "Backup: $BACKUP"

    # Aplicar
    step "Aplicando correções..."
    python3 - "$TRAEFIK_YAML" << 'PYFIX'
import sys, re
f = sys.argv[1]
c = open(f).read()
orig = c
c = re.sub(r'[ \t]*- "--certificatesresolvers\.[^"]*\.acme\.httpchallenge=true"\n', '', c)
c = re.sub(r'[ \t]*- "--certificatesresolvers\.[^"]*\.acme\.httpchallenge\.entrypoint=[^"]*"\n', '', c)
c = re.sub(r'[ \t]*- "--entrypoints\.web\.http\.redirections\.entryPoint\.to=[^"]*"\n', '', c)
c = re.sub(r'[ \t]*- "--entrypoints\.web\.http\.redirections\.entryPoint\.scheme=[^"]*"\n', '', c)
c = re.sub(r'[ \t]*- "--entrypoints\.web\.http\.redirections\.entrypoint\.permanent=[^"]*"\n', '', c)
if "tlschallenge=true" not in c:
    m = re.search(r'( +- "--certificatesresolvers\.([^.]+)\.acme\.storage=[^"]*")', c)
    if m:
        indent = re.match(r'( +)', m.group(1)).group(1)
        tls = f'{indent}- "--certificatesresolvers.{m.group(2)}.acme.tlschallenge=true"\n'
        c = c[:m.start()] + tls + c[m.start():]
c = re.sub(r'\n{3,}', '\n\n', c)
open(f, 'w').write(c)
print("CHANGED" if c != orig else "NOCHANGE")
PYFIX

    ok "Arquivo corrigido!"
    echo -e "\n  ${CYAN}Diff:${NC}"
    diff "$BACKUP" "$TRAEFIK_YAML" | grep "^[<>]" | head -10 | sed 's/^< /  ❌ /; s/^> /  ✅ /' || true

    # acme.json — perguntar com contexto
    separador
    step "Verificando acme.json..."
    ACME_FILE=""
    for VOL in volume_swarm_certificates traefik-certs vol_certificates; do
        MP=$(docker volume inspect "$VOL" 2>/dev/null | grep -oP '"Mountpoint": "\K[^"]+' || echo "")
        [ -n "$MP" ] && [ -f "${MP}/acme.json" ] && { ACME_FILE="${MP}/acme.json"; break; }
    done
    [ -z "$ACME_FILE" ] && ACME_FILE=$(find /var/lib/docker/volumes -name "acme.json" 2>/dev/null | head -1 || echo "")

    if [ -n "$ACME_FILE" ] && [ -f "$ACME_FILE" ]; then
        CERT_COUNT=$(python3 -c "
import sys,json
try:
    d=json.load(open('$ACME_FILE'))
    print(sum(len(r.get('Certificates',[])) for r in d.values()))
except: print(0)
" 2>/dev/null || echo "0")

        if [ "$CERT_COUNT" != "0" ] && [ "$CERT_COUNT" != "" ]; then
            echo -e "\n  ${GREEN}acme.json contém $CERT_COUNT certificado(s) válido(s).${NC}"
            echo -e "  ${WHITE}NÃO é necessário deletar. O Traefik renovará automaticamente via TLS-ALPN.${NC}\n"
            echo -e "  ${RED}Deletar agora causaria:${NC}"
            echo -e "  ${RED}  • Sites sem certificado imediatamente${NC}"
            echo -e "  ${RED}  • Possível bloqueio Let's Encrypt por 1h+ (rate limit)${NC}\n"
            read -p "  Deletar mesmo assim? (não recomendado) (s/N): " DEL < /dev/tty
        else
            warn "acme.json vazio. Deletar é seguro."
            read -p "  Deletar? (S/n): " DEL < /dev/tty
            [[ "$DEL" =~ ^[Nn]$ ]] || DEL="s"
        fi

        if [[ "$DEL" =~ ^[Ss]$ ]]; then
            cp "$ACME_FILE" "${ACME_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
            rm -f "$ACME_FILE"
            ok "acme.json deletado (backup feito)."
        else
            ok "acme.json mantido. Certificados existentes continuam válidos."
        fi
    else
        warn "acme.json não encontrado. Será criado ao subir o Traefik."
    fi

    # Redesployar
    separador
    step "Identificando stack..."
    STACK_NAME=$(docker stack ls 2>/dev/null | grep -i traefik | grep -v "traefik-central" | awk '{print $1}' | head -1 || echo "")
    if [ -z "$STACK_NAME" ]; then
        docker stack ls
        read -p "  Nome da stack [traefik]: " STACK_NAME < /dev/tty
        STACK_NAME="${STACK_NAME:-traefik}"
    else
        ok "Stack: $STACK_NAME"
    fi

    step "Redesployando '$STACK_NAME'..."
    docker stack deploy -c "$TRAEFIK_YAML" "$STACK_NAME"
    ok "Deploy iniciado!"

    step "Aguardando (25s)..."
    for i in $(seq 1 25); do echo -ne "  ${CYAN}[$i/25]${NC}\r"; sleep 1; done; echo

    # Verificar serviço
    SVC_NAME=$(docker service ls --format "{{.Name}}" 2>/dev/null | grep -i "traefik" | grep -v "central" | head -1 || echo "")
    CONTAINER_NAME=$(docker ps --format "{{.Names}}" 2>/dev/null | grep "$SVC_NAME" | head -1 || echo "")

    [ -n "$SVC_NAME" ] && {
        REPLICAS=$(docker service ls --filter "name=${SVC_NAME}" --format "{{.Replicas}}" 2>/dev/null || echo "?")
        [[ "$REPLICAS" == "1/1" ]] && ok "Serviço: ✔" || warn "Serviço: $REPLICAS"
    }

    # Monitorar certificados por 60s
    separador
    echo -e "\n${CYAN}📄 MONITORANDO CERTIFICADOS (60s)...${NC}"
    echo -e "${WHITE}  Aguarde enquanto o Traefik obtém certificados via TLS-ALPN.${NC}\n"

    CERT_OK=false
    for i in $(seq 1 12); do
        echo -ne "  ${CYAN}[${i}/12] aguardando...${NC}\r"
        sleep 5
        if [ -n "$CONTAINER_NAME" ]; then
            LOG=$(docker exec "$CONTAINER_NAME" tail -20 /var/log/traefik/traefik.log 2>/dev/null || \
                  docker logs "$CONTAINER_NAME" 2>&1 | tail -20 || echo "")
            if echo "$LOG" | grep -qi "certificate obtained\|acme: Obtain"; then
                echo; ok "✅ Certificado obtido!"; CERT_OK=true; break
            elif echo "$LOG" | grep -qi "rateLimited\|too many"; then
                echo; erro "⚠ Rate limit do Let's Encrypt detectado!"
                RETRY=$(echo "$LOG" | grep -oP "retry after \K.+UTC" | head -1 || echo "alguns minutos")
                warn "Tente após: $RETRY"
                warn "Comando: docker service update --force $SVC_NAME"
                break
            fi
        fi
    done
    echo

    # Verificar via openssl
    if [ -n "$CONTAINER_NAME" ]; then
        separador
        step "Testando certificados via openssl..."
        DOMS_TEST=$(docker exec "$CONTAINER_NAME" \
            grep -oP 'rule=Host\(`\K[^`]+' /var/log/traefik/traefik.log 2>/dev/null | \
            sort -u | head -5 || echo "")
        for DOM in $DOMS_TEST; do
            RES=$(echo | timeout 5 openssl s_client -connect "${DOM}:443" -servername "$DOM" 2>/dev/null | \
                openssl x509 -noout -issuer 2>/dev/null || echo "ERRO")
            echo "$RES" | grep -qi "TRAEFIK DEFAULT" && warn "$DOM → certificado padrão ainda" || \
            echo "$RES" | grep -qi "Let's Encrypt\|R3\|R10\|R11" && ok "$DOM → ✅ Let's Encrypt!" || \
            [ "$RES" != "ERRO" ] && ok "$DOM → certificado válido" || warn "$DOM → sem resposta"
        done
    fi

    # Resumo
    separador
    echo -e "\n${GREEN}${BOLD}  ✅ CORREÇÃO CONCLUÍDA!${NC}\n"
    ok "Backup: $BACKUP"
    ok "httpchallenge → tlschallenge"
    ok "Redirect global removido"
    ok "Stack '$STACK_NAME' redesployada"
    echo -e "\n  ${CYAN}Monitorar:${NC}"
    [ -n "$CONTAINER_NAME" ] && \
        echo -e "  ${WHITE}docker exec $CONTAINER_NAME tail -f /var/log/traefik/traefik.log${NC}" || \
        echo -e "  ${WHITE}docker service logs -f $SVC_NAME${NC}"
    separador
}

# ============================================================================
# MENU PRINCIPAL
# ============================================================================
menu_principal() {
    clear
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${GREEN}${BOLD}     🚀 TRAEFIK CENTRAL — GERENCIADOR${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${CYAN}  HTTP Proxy (80) + TCP Passthrough (443) + TLS-ALPN${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}\n"
    echo -e "  ${CYAN}1)${NC} ${WHITE}Instalar Traefik Central${NC}"
    echo -e "  ${CYAN}2)${NC} ${WHITE}Diagnóstico do sistema${NC}"
    echo -e "  ${CYAN}3)${NC} ${WHITE}Verificar Traefik(s) instalados${NC}"
    echo -e "  ${CYAN}4)${NC} ${RED}Remover Traefik instalado${NC}"
    echo -e "  ${CYAN}5)${NC} ${GREEN}Gerenciar servidores/domínios${NC}"
    echo -e "  ${CYAN}6)${NC} ${WHITE}Listar servidores configurados${NC}"
    echo -e "  ${CYAN}7)${NC} ${YELLOW}🔧 Corrigir Traefik deste servidor${NC} ${WHITE}← rodar no servidor destino${NC}"
    echo -e "  ${CYAN}8)${NC} ${CYAN}🔐 Verificar status dos certificados SSL${NC}"
    echo -e "  ${CYAN}0)${NC} ${WHITE}Sair${NC}\n"
    separador
    read -p "Escolha: " OPCAO_MENU < /dev/tty
    echo
}

# ============================================================================
# MAIN
# ============================================================================
verificar_root

while true; do
    menu_principal
    case "$OPCAO_MENU" in
        1)
            diagnostico_sistema; pausar
            verificar_traefik_existente
            if [ "${TRAEFIK_ENCONTRADO:-false}" = true ]; then
                read -p "Traefik detectado. Continuar? (s/N): " CONT < /dev/tty
                [[ "$CONT" =~ ^[Ss]$ ]] || { warn "Cancelado."; pausar; continue; }
            fi
            pausar
            instalar_dependencias
            coletar_configuracoes
            criar_arquivos
            fazer_deploy
            verificar_pos_instalacao
            resumo_final
            ;;
        2) diagnostico_sistema; pausar ;;
        3) verificar_traefik_existente; pausar ;;
        4) verificar_traefik_existente; menu_remocao; pausar ;;
        5) criar_script_auxiliar; menu_gerenciar_servidores; pausar ;;
        6) listar_servidores; pausar ;;
        7) corrigir_traefik_local; pausar ;;
        8) verificar_certificados; pausar ;;
        0) echo -e "\n${GREEN}Até mais!${NC}\n"; exit 0 ;;
        *) erro "Inválido."; sleep 2 ;;
    esac
done