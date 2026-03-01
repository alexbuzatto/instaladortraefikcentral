#!/bin/bash

# ============================================================================
# 🚀 INSTALADOR DO TRAEFIK CENTRAL - OPÇÃO A
# ============================================================================
# Estratégia: HTTP Passthrough (porta 80) + TCP Passthrough (porta 443)
#
# Fluxo:
#   INTERNET → MIKROTIK → TRAEFIK CENTRAL
#                              ├─ porta 80  → roteamento HTTP por domínio → servidor correto
#                              └─ porta 443 → TCP Passthrough por SNI     → servidor correto
#
# ✅ Os servidores de destino continuam gerando seus próprios certificados
# ✅ Renovação automática do Let's Encrypt não é afetada
# ✅ Zero alterações nas stacks existentes (Traefik, Portainer, Chatwoot, etc.)
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

verificar_logs_recentes() {
    local LINES="${1:-10}"
    echo -e "\n${CYAN}📄 ÚLTIMOS LOGS DO TRAEFIK CENTRAL (L${LINES}):${NC}"
    separador
    if docker stack ls 2>/dev/null | grep -q "traefik-central"; then
        docker service logs --tail "$LINES" traefik-central_traefik 2>/dev/null || warn "Não foi possível ler logs do serviço."
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "traefik-central"; then
        docker logs --tail "$LINES" traefik-central 2>/dev/null || warn "Não foi possível ler logs do container."
    else
        warn "Instalação do Traefik Central não encontrada para ler logs."
    fi
    separador
}

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
# DIAGNÓSTICO
# ============================================================================
diagnostico_sistema() {
    header "🔍 DIAGNÓSTICO DO SISTEMA"

    step "Sistema Operacional"
    [ -f /etc/os-release ] && { . /etc/os-release; ok "OS: $PRETTY_NAME"; } || warn "OS não identificado"
    ok "Arquitetura: $(uname -m)"

    step "Memória RAM"
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_LIVRE=$(free -m | awk '/^Mem:/{print $4}')
    MEM_TOTAL=${MEM_TOTAL:-0}
    MEM_LIVRE=${MEM_LIVRE:-0}
    [ "$MEM_LIVRE" -lt 256 ] && warn "RAM: ${MEM_LIVRE}MB livre / ${MEM_TOTAL}MB total (recomendado mínimo 256MB)" || ok "RAM: ${MEM_LIVRE}MB livre / ${MEM_TOTAL}MB total"

    step "Espaço em Disco"
    DISCO_LIVRE=$(df -BM / | awk 'NR==2{print $4}' | sed 's/M//')
    [ "$DISCO_LIVRE" -lt 1024 ] && warn "Disco livre: ${DISCO_LIVRE}MB" || ok "Disco livre: ${DISCO_LIVRE}MB"

    step "IP do servidor"
    IP_LOCAL=$(hostname -I | awk '{print $1}')
    ok "IP local: $IP_LOCAL"

    step "Portas críticas (80, 443, 8080)"
    for PORT in 80 443 8080; do
        USANDO=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | awk '{print $NF}' | grep -oP 'pid=\K[0-9]+' | head -1)
        if [ -n "$USANDO" ]; then
            PROC=$(cat /proc/$USANDO/comm 2>/dev/null || echo "desconhecido")
            warn "Porta $PORT em uso por: $PROC (PID: $USANDO)"
        else
            ok "Porta $PORT: livre"
        fi
    done

    step "Docker"
    if command -v docker &>/dev/null; then
        ok "Docker: v$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
        systemctl is-active --quiet docker && ok "Serviço Docker: ativo" || warn "Docker inativo (será iniciado)"
    else
        warn "Docker não instalado (será instalado automaticamente)"
    fi

    step "Docker Swarm"
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        ok "Swarm: ativo"
        ok "Nodes ativos: $(docker node ls 2>/dev/null | grep -c "Ready" || echo 0)"
    else
        warn "Swarm não inicializado (será inicializado automaticamente)"
    fi

    step "Dependências"
    for DEP in curl openssl; do
        command -v $DEP &>/dev/null && ok "$DEP: disponível" || warn "$DEP: ausente (será instalado)"
    done
}

# ============================================================================
# DETECTAR TRAEFIK EXISTENTE
# ============================================================================
verificar_traefik_existente() {
    header "🔎 VERIFICANDO TRAEFIK(S) INSTALADOS"
    TRAEFIK_ENCONTRADO=false

    step "Docker Stacks com Traefik..."
    STACKS=$(docker stack ls 2>/dev/null | grep -i traefik | awk '{print $1}' || true)
    if [ -n "$STACKS" ]; then
        TRAEFIK_ENCONTRADO=true
        while IFS= read -r STACK; do
            warn "Stack: $STACK"
            docker stack services "$STACK" 2>/dev/null | tail -n +2 | while IFS= read -r l; do info "  → $l"; done
        done <<< "$STACKS"
    else
        ok "Nenhuma stack Traefik"
    fi

    step "Containers standalone..."
    CONTAINERS=$(docker ps -a --filter "name=traefik" --format "{{.Names}}|{{.Status}}|{{.Image}}" 2>/dev/null || true)
    if [ -n "$CONTAINERS" ]; then
        TRAEFIK_ENCONTRADO=true
        while IFS= read -r l; do
            warn "Container: $(echo $l | cut -d'|' -f1) | $(echo $l | cut -d'|' -f2) | $(echo $l | cut -d'|' -f3)"
        done <<< "$CONTAINERS"
    else
        ok "Nenhum container standalone"
    fi

    step "Imagens locais..."
    IMAGENS=$(docker images --filter "reference=traefik*" --format "{{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null || true)
    [ -n "$IMAGENS" ] && while IFS= read -r img; do info "Imagem: $img"; done <<< "$IMAGENS" || ok "Nenhuma imagem local"

    step "Redes relacionadas..."
    REDES=$(docker network ls --format "{{.Name}}|{{.Driver}}" 2>/dev/null | grep -i traefik || true)
    [ -n "$REDES" ] && while IFS= read -r r; do info "Rede: $(echo $r | cut -d'|' -f1) ($(echo $r | cut -d'|' -f2))"; done <<< "$REDES" || ok "Nenhuma rede"

    step "Volumes relacionados..."
    VOLUMES=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep -i traefik || true)
    [ -n "$VOLUMES" ] && while IFS= read -r v; do info "Volume: $v"; done <<< "$VOLUMES" || ok "Nenhum volume"

    step "Binário no sistema..."
    if command -v traefik &>/dev/null; then
        warn "Binário: $(traefik version 2>/dev/null | grep Version | head -1) em $(which traefik)"
        TRAEFIK_ENCONTRADO=true
    else
        ok "Nenhum binário"
    fi

    step "Serviço systemd..."
    if systemctl list-units --type=service 2>/dev/null | grep -q traefik; then
        warn "systemd traefik: $(systemctl is-active traefik 2>/dev/null || echo inativo)"
        TRAEFIK_ENCONTRADO=true
    else
        ok "Nenhum serviço systemd"
    fi

    separador
    if [ "$TRAEFIK_ENCONTRADO" = true ]; then
        echo -e "\n${YELLOW}⚠ Instalação(ões) do Traefik detectada(s) neste servidor.${NC}"
    else
        echo -e "\n${GREEN}✔ Nenhum Traefik encontrado. Ambiente limpo!${NC}"
    fi
}

# ============================================================================
# MENU REMOÇÃO
# ============================================================================
menu_remocao() {
    header "🗑️ REMOÇÃO DE TRAEFIK INSTALADO"
    echo -e "${RED}${BOLD}ATENÇÃO: Irreversível.${NC}\n"
    echo -e "  ${CYAN}1)${NC} Remover stack traefik-central"
    echo -e "  ${CYAN}2)${NC} Remover stack específica"
    echo -e "  ${CYAN}3)${NC} Remover container standalone"
    echo -e "  ${CYAN}4)${NC} Remover TUDO (stacks + containers + redes + volumes + imagens)"
    echo -e "  ${CYAN}5)${NC} Remover binário + systemd"
    echo -e "  ${CYAN}0)${NC} Voltar\n"
    read -p "Escolha: " OPCAO_REMOVE < /dev/tty

    case "$OPCAO_REMOVE" in
        1) remover_stack "traefik-central" ;;
        2)
            docker stack ls 2>/dev/null || true
            read -p "Nome da stack: " NS < /dev/tty; remover_stack "$NS" ;;
        3)
            docker ps -a --filter "name=traefik" --format "{{.Names}} | {{.Status}}" 2>/dev/null || true
            read -p "Nome do container: " NC_REM < /dev/tty; remover_container "$NC_REM" ;;
        4) remover_tudo ;;
        5) remover_binario_systemd ;;
        0) return ;;
        *) erro "Opção inválida" ;;
    esac
}

remover_stack() {
    local STACK="$1"
    read -p "Remover stack '$STACK'? Digite 'sim': " C < /dev/tty
    if [ "$C" = "sim" ]; then
        docker stack rm "$STACK" 2>/dev/null && ok "Stack removida" || erro "Não encontrada"
        sleep 8
        read -p "Remover redes e volumes relacionados? (s/N): " RE < /dev/tty
        if [[ "$RE" =~ ^[Ss]$ ]]; then
            docker network ls --format "{{.Name}}" | grep -i traefik | xargs -r docker network rm 2>/dev/null && ok "Redes removidas" || warn "Nenhuma rede"
            docker volume ls --format "{{.Name}}" | grep -i traefik | xargs -r docker volume rm 2>/dev/null && ok "Volumes removidos" || warn "Nenhum volume"
        fi
        ok "Concluído!"
    else
        warn "Cancelado."
    fi
}

remover_container() {
    read -p "Remover container '$1'? Digite 'sim': " C < /dev/tty
    [ "$C" = "sim" ] && { docker stop "$1" 2>/dev/null || true; docker rm "$1" 2>/dev/null && ok "Removido!" || erro "Erro"; } || warn "Cancelado."
}

remover_tudo() {
    echo -e "\n${RED}${BOLD}Remove TUDO com 'traefik' no nome. Outros serviços NÃO são afetados.${NC}"
    read -p "Digite 'REMOVER TUDO' para confirmar: " C < /dev/tty
    if [ "$C" = "REMOVER TUDO" ]; then
        docker stack ls 2>/dev/null | grep -i traefik | awk '{print $1}' | xargs -r docker stack rm 2>/dev/null && ok "Stacks removidas" || warn "Nenhuma"
        sleep 10
        docker ps -a --filter "name=traefik" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null && ok "Containers removidos" || warn "Nenhum"
        docker network ls --format "{{.Name}}" | grep -i traefik | xargs -r docker network rm 2>/dev/null && ok "Redes removidas" || warn "Nenhuma"
        docker volume ls --format "{{.Name}}" | grep -i traefik | xargs -r docker volume rm 2>/dev/null && ok "Volumes removidos" || warn "Nenhum"
        docker images --filter "reference=traefik*" --format "{{.ID}}" | xargs -r docker rmi -f 2>/dev/null && ok "Imagens removidas" || warn "Nenhuma"
        rm -rf /root/traefik-central 2>/dev/null && ok "Diretório removido" || warn "Não encontrado"
        ok "Remoção completa!"
    else
        warn "Cancelado."
    fi
}

remover_binario_systemd() {
    read -p "Remover binário + systemd? Digite 'sim': " C < /dev/tty
    if [ "$C" = "sim" ]; then
        systemctl stop traefik 2>/dev/null && ok "Parado" || warn "Não estava ativo"
        systemctl disable traefik 2>/dev/null && ok "Desabilitado" || true
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
    header "📦 INSTALANDO DEPENDÊNCIAS"

    for DEP in curl openssl; do
        step "$DEP"
        if ! command -v $DEP &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq $DEP
            ok "$DEP instalado"
        else
            ok "$DEP: OK"
        fi
    done

    step "Docker"
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | bash
        ok "Docker instalado"
    else
        ok "Docker: OK"
    fi

    if ! systemctl is-active --quiet docker; then
        systemctl enable docker && systemctl start docker
        ok "Docker iniciado"
    fi

    step "Docker Swarm"
    if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
        IP=$(hostname -I | awk '{print $1}')
        docker swarm init --advertise-addr "$IP"
        ok "Swarm inicializado: $IP"
    else
        ok "Swarm: já ativo"
    fi
}

# ============================================================================
# COLETAR CONFIGURAÇÕES
# ============================================================================
coletar_configuracoes() {
    header "⚙️ CONFIGURAÇÃO DO TRAEFIK CENTRAL"

    echo -e "${YELLOW}🔐 Dashboard do Traefik Central:${NC}\n"
    echo -e "${CYAN}  O dashboard do Central é acessado via HTTPS na porta 8080.${NC}"
    echo -e "${CYAN}  Ele precisa de um domínio próprio (diferente dos servidores de destino).${NC}\n"

    while true; do
        read -p "  Domínio do dashboard (ex: traefik-central.seudominio.com): " DASH_DOMAIN < /dev/tty
        [ -n "$DASH_DOMAIN" ] && break
        erro "Domínio não pode ser vazio."
    done

    while true; do
        read -p "  Email para Let's Encrypt: " EMAIL < /dev/tty
        [[ "$EMAIL" == *"@"* ]] && break
        erro "Email inválido."
    done

    read -p "  Usuário do dashboard [admin]: " DASH_USER < /dev/tty
    DASH_USER="${DASH_USER:-admin}"

    while true; do
        read -s -p "  Senha do dashboard: " DASH_PASS < /dev/tty; echo
        read -s -p "  Confirme a senha: " DASH_PASS_CONF < /dev/tty; echo
        [ "$DASH_PASS" = "$DASH_PASS_CONF" ] && [ -n "$DASH_PASS" ] && break
        erro "Senhas não conferem ou vazias."
    done

    HASH=$(openssl passwd -apr1 "$DASH_PASS")
    HASH_ESCAPED=$(echo "$HASH" | sed 's/\$/\$\$/g')
    ok "Dashboard configurado: https://${DASH_DOMAIN}:8080"

    # -------------------------------------------------------------------------
    # SERVIDORES DESTINO
    # -------------------------------------------------------------------------
    separador
    echo -e "\n${YELLOW}🖥️ SERVIDORES DESTINO:${NC}"
    echo -e "${CYAN}  Estratégia: HTTP Passthrough (porta 80) + TCP Passthrough (porta 443)${NC}"
    echo -e "${CYAN}  → Os certificados continuam sendo gerados pelos Traefiks locais.${NC}"
    echo -e "${CYAN}  → Para cada servidor, informe os domínios que ele atende.${NC}"
    echo -e "${WHITE}  → Exemplo do seu ambiente atual:${NC}"
    echo -e "    ${WHITE}Servidor 1: painel.eclicksolucoes.com.br, unichat.eclicksolucoes.com.br, traefik.eclicksolucoes.com.br${NC}\n"

    ROUTERS_TCP_CONFIG=""
    SERVICES_TCP_CONFIG=""
    ROUTERS_HTTP_CONFIG=""
    SERVICES_HTTP_CONFIG=""
    SERVER_COUNT=0
    SERVERS_SUMMARY=""

    while true; do
        SERVER_COUNT=$((SERVER_COUNT + 1))
        echo -e "${BLUE}  --- Servidor $SERVER_COUNT ---${NC}"

        read -p "  Nome do servidor (ex: srv1) [vazio para parar]: " SERVER_NAME < /dev/tty
        if [ -z "$SERVER_NAME" ]; then
            SERVER_COUNT=$((SERVER_COUNT - 1))
            break
        fi

        if [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            erro "Nome inválido. Use letras, números, - e _"
            SERVER_COUNT=$((SERVER_COUNT - 1))
            continue
        fi

        echo -e "  ${CYAN}IP do servidor (privado se estiver na mesma LAN, público se for externo):${NC}"
        while true; do
            read -p "  IP do servidor: " SERVER_IP < /dev/tty
            [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
            erro "IP inválido. Formato: 192.168.25.102 ou 1.2.3.4"
        done

        read -p "  Porta HTTPS [443]: " SERVER_PORT_HTTPS < /dev/tty
        SERVER_PORT_HTTPS="${SERVER_PORT_HTTPS:-443}"

        read -p "  Porta HTTP [80]: " SERVER_PORT_HTTP < /dev/tty
        SERVER_PORT_HTTP="${SERVER_PORT_HTTP:-80}"

        echo -e "  ${CYAN}Domínios que este servidor atende (vírgula, sem espaços):${NC}"
        echo -e "  ${WHITE}Ex: painel.eclicksolucoes.com.br,unichat.eclicksolucoes.com.br,traefik.eclicksolucoes.com.br${NC}"

        while true; do
            read -p "  Domínios: " DOMAINS < /dev/tty
            DOMAINS=$(echo "$DOMAINS" | tr -d ' ')
            [ -n "$DOMAINS" ] && break
            erro "Informe pelo menos um domínio."
        done

        # ---- Formatar domínios para as Rules ----
        IFS=',' read -ra DOM_ARRAY <<< "$DOMAINS"
        RULE_TCP=""
        RULE_HTTP=""
        for dom in "${DOM_ARRAY[@]}"; do
            [ -n "$RULE_TCP" ] && RULE_TCP="${RULE_TCP} || "
            [ -n "$RULE_HTTP" ] && RULE_HTTP="${RULE_HTTP} || "
            
            if [[ "$dom" == \*.* ]]; then
                base=${dom#*.}
                RULE_TCP="${RULE_TCP}HostSNIRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || HostSNI(\`${base}\`)"
                RULE_HTTP="${RULE_HTTP}HostRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || Host(\`${base}\`)"
            else
                RULE_TCP="${RULE_TCP}HostSNI(\`${dom}\`)"
                RULE_HTTP="${RULE_HTTP}Host(\`${dom}\`)"
            fi
        done

        # ---- Acumular config TCP (porta 443 - passthrough) ----
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

        # ---- Acumular config HTTP (porta 80 - proxy reverso) ----
        ROUTERS_HTTP_CONFIG="${ROUTERS_HTTP_CONFIG}
    ${SERVER_NAME}-http:
      rule: \"${RULE_HTTP}\"
      entryPoints:
        - web
      service: ${SERVER_NAME}-http-svc
      priority: 10
"
        SERVICES_HTTP_CONFIG="${SERVICES_HTTP_CONFIG}
    ${SERVER_NAME}-http-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: \"http://${SERVER_IP}:${SERVER_PORT_HTTP}\"
"

        ok "Servidor '${SERVER_NAME}' configurado:"
        info "  HTTPS (443 TCP Passthrough): ${SERVER_IP}:${SERVER_PORT_HTTPS}"
        info "  HTTP  (80 Proxy):            ${SERVER_IP}:${SERVER_PORT_HTTP}"
        info "  Domínios: ${DOMAINS}"
        SERVERS_SUMMARY="${SERVERS_SUMMARY}\n  • ${SERVER_NAME}: ${DOMAINS} → ${SERVER_IP}"
        echo

        read -p "  Adicionar outro servidor? (s/N): " CONTINUE < /dev/tty
        [[ "$CONTINUE" =~ ^[Ss]$ ]] || break
    done
}

# ============================================================================
# CRIAR ARQUIVOS
# ============================================================================
criar_arquivos() {
    header "📝 CRIANDO ARQUIVOS DE CONFIGURAÇÃO"

    BASE_DIR="/root/traefik-central"
    mkdir -p "$BASE_DIR/dynamic-config"
    cd "$BASE_DIR"

    # ------------------------------------------------------------------
    # docker-compose.yml
    # ------------------------------------------------------------------
    step "docker-compose.yml..."
    cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.8"

# ============================================================================
# TRAEFIK CENTRAL
# ============================================================================
# Estratégia: HTTP Proxy (80) + TCP Passthrough (443)
# Os servidores de destino continuam gerando seus próprios certificados.
# ============================================================================

services:
  traefik-central:
    image: traefik:v3.3
    command:
      # Dashboard
      - "--api.dashboard=true"
      - "--api.insecure=false"

      # EntryPoints
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.dashboard.address=:8080"

      # Estratégia Orion: O tráfego HTTP na porta 80 precisa chegar aos servidores destino
      # para que o Let's Encrypt deles consiga renovar os certificados (HTTP Challenge).
      # O redirecionamento para HTTPS deve ocorrer APENAS nos servidores de destino.

      # Provider: Swarm
      - "--providers.swarm=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--providers.swarm.network=traefik-central-net"

      # Provider: File (rotas TCP e HTTP para os servidores)
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"

      # Let's Encrypt SOMENTE para o dashboard do Central (via TLS-ALPN-01 para não interferir na porta 80)
      - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.email=${EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/etc/traefik/certificates/acme.json"

      # Logs
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
    ok "docker-compose.yml criado"

    # ------------------------------------------------------------------
    # dashboard.yml (HTTP com ACME)
    # ------------------------------------------------------------------
    step "dynamic-config/dashboard.yml..."
    cat > "$BASE_DIR/dynamic-config/dashboard.yml" <<EOF
# Dashboard do Traefik Central
# Acesso: https://${DASH_DOMAIN}:8080
http:
  routers:
    dashboard:
      rule: "Host(\`${DASH_DOMAIN}\`)"
      entryPoints:
        - dashboard
      service: api@internal
      middlewares:
        - basicauth
      tls:
        certResolver: letsencrypt

  middlewares:
    basicauth:
      basicAuth:
        users:
          - "${DASH_USER}:${HASH}"
EOF
    ok "dashboard.yml criado"

    # ------------------------------------------------------------------
    # servers.yml (TCP passthrough 443 + HTTP proxy 80)
    # ------------------------------------------------------------------
    step "dynamic-config/servers.yml..."

    if [ "$SERVER_COUNT" -gt 0 ]; then
        cat > "$BASE_DIR/dynamic-config/servers.yml" <<EOF
# ============================================================================
# ROTEAMENTO - TRAEFIK CENTRAL
# ============================================================================
#
# PORTA 443 — TCP Passthrough (HostSNI)
#   O Traefik Central identifica o servidor pelo SNI do TLS e encaminha
#   o pacote SEM descriptografar. Os certificados ficam nos servidores locais.
#
# PORTA 80 — HTTP Proxy (Host header)
#   O Traefik Central faz proxy do HTTP para o servidor correto.
#   Isso é ESSENCIAL para que o Let's Encrypt dos servidores de destino
#   consiga renovar certificados via HTTP Challenge.
#
# ⚠️ Para adicionar novos servidores: edite este arquivo.
#    O Traefik recarrega automaticamente (watch=true).
# ============================================================================

# ---- PORTA 443: TCP PASSTHROUGH ----
tcp:
  routers:
${ROUTERS_TCP_CONFIG}
  services:
${SERVICES_TCP_CONFIG}

# ---- PORTA 80: HTTP PROXY (para Let's Encrypt funcionar) ----
http:
  routers:
${ROUTERS_HTTP_CONFIG}
  services:
${SERVICES_HTTP_CONFIG}
EOF
    else
        cat > "$BASE_DIR/dynamic-config/servers.yml" <<EOF
# ============================================================================
# ROTEAMENTO - TRAEFIK CENTRAL
# ============================================================================
# Nenhum servidor configurado ainda. Adicione abaixo seguindo o padrão:
#
# tcp:
#   routers:
#     srv1-https:
#       rule: "HostSNI(`app.dominio.com`)"
#       entryPoints: [websecure]
#       service: srv1-https-svc
#       tls:
#         passthrough: true
#   services:
#     srv1-https-svc:
#       loadBalancer:
#         servers:
#           - address: "1.2.3.4:443"
#
# http:
#   routers:
#     srv1-http:
#       rule: "Host(`app.dominio.com`)"
#       entryPoints: [web]
#       service: srv1-http-svc
#       priority: 10
#   services:
#     srv1-http-svc:
#       loadBalancer:
#         passHostHeader: true
#         servers:
#           - url: "http://1.2.3.4:80"
# ============================================================================

# Nenhum servidor configurado ainda.
# Use o menu opção 5 para adicionar servidores.
EOF
    fi
    ok "servers.yml criado"
    info "Arquivos em: $BASE_DIR"
}

# ============================================================================
# CRIAR SCRIPT PYTHON AUXILIAR (usado pela remoção de servidores)
# ============================================================================
criar_script_auxiliar() {

    cat > /tmp/traefik_add.py << 'PYADD'
import sys, re

filepath   = sys.argv[1]
name       = sys.argv[2]
ip         = sys.argv[3]
port_https = sys.argv[4]
port_http  = sys.argv[5]
rule_tcp   = sys.argv[6]
rule_http  = sys.argv[7]

r_tcp  = f"\n    {name}-https:\n      rule: \"{rule_tcp}\"\n      entryPoints:\n        - websecure\n      service: {name}-https-svc\n      tls:\n        passthrough: true\n"
s_tcp  = f"\n    {name}-https-svc:\n      loadBalancer:\n        servers:\n          - address: \"{ip}:{port_https}\"\n"
r_http = f"\n    {name}-http:\n      rule: \"{rule_http}\"\n      entryPoints:\n        - web\n      service: {name}-http-svc\n      priority: 10\n"
s_http = f"\n    {name}-http-svc:\n      loadBalancer:\n        passHostHeader: true\n        servers:\n          - url: \"http://{ip}:{port_http}\"\n"

with open(filepath, "r") as f:
    content = f.read()

has_structure = "tcp:" in content and "http:" in content

if not has_structure:
    new_content = (
        "# ============================================================================\n"
        "# ROTEAMENTO - TRAEFIK CENTRAL\n"
        "# ============================================================================\n\n"
        "# ---- PORTA 443: TCP PASSTHROUGH ----\n"
        "tcp:\n  routers:\n" + r_tcp + "\n  services:\n" + s_tcp + "\n"
        "# ---- PORTA 80: HTTP PROXY (para Lets Encrypt funcionar) ----\n"
        "http:\n  routers:\n" + r_http + "\n  services:\n" + s_http + "\n"
    )
    with open(filepath, "w") as f:
        f.write(new_content)
else:
    content = re.sub(r"(tcp:\n  routers:)(.*?)(  services:)", rf"\1\2{r_tcp}\3", content, flags=re.DOTALL)
    content = re.sub(r"(  services:)(.*?)(# ---- PORTA 80)", rf"\1\2{s_tcp}\n\3", content, flags=re.DOTALL)
    content = re.sub(r"(http:\n  routers:)(.*?)(  services:)", rf"\1\2{r_http}\3", content, flags=re.DOTALL)
    content = content.rstrip() + "\n" + s_http
    with open(filepath, "w") as f:
        f.write(content)

print(f"Servidor adicionado com sucesso.")
PYADD

    cat > /tmp/traefik_remove.py << 'PYREMOVE'
import sys
import re

filepath = sys.argv[1]
name     = sys.argv[2]

with open(filepath, "r") as f:
    lines = f.readlines()

result = []
skip = False
indent_ref = 4

for line in lines:
    if re.match(rf"^    {re.escape(name)}-(https|https-svc|http|http-svc):\s*$", line):
        skip = True
        continue
    if skip:
        stripped = line.rstrip()
        if stripped == "" or (len(stripped) - len(stripped.lstrip()) > indent_ref):
            continue
        else:
            skip = False
    if not skip:
        result.append(line)

content = "".join(result)

# Verificar se ainda ha servidores apos remocao
has_routers = bool(re.search(r"^    [a-zA-Z]", content, re.MULTILINE))

if not has_routers:
    content = (
        "# ============================================\n"
        "# ROTEAMENTO - TRAEFIK CENTRAL\n"
        "# ============================================\n"
        "# Nenhum servidor configurado.\n"
        "# Use o menu opcao 5 para adicionar.\n"
        "# ============================================\n"
    )
else:
    content = re.sub(r"\n{3,}", "\n\n", content)

with open(filepath, "w") as f:
    f.write(content)

print(f"  Servidor '{name}' removido com sucesso.")
PYREMOVE
}

# ============================================================================
# DEPLOY
# ============================================================================
fazer_deploy() {
    header "🚀 DEPLOY DO TRAEFIK CENTRAL"

    # Criar script Python auxiliar para remoção de servidores
    criar_script_auxiliar

    step "Rede overlay traefik-central-net..."
    docker network create --driver overlay --attachable traefik-central-net 2>/dev/null \
        && ok "Rede criada" || warn "Já existe, continuando..."

    step "Volume traefik-certs..."
    docker volume create traefik-certs 2>/dev/null \
        && ok "Volume criado" || warn "Já existe, continuando..."

    step "Deploy da stack..."
    docker stack deploy -c /root/traefik-central/docker-compose.yml traefik-central
    ok "Deploy iniciado!"

    step "Aguardando inicialização (20s)..."
    sleep 20
}

# ============================================================================
# VERIFICAÇÃO PÓS-INSTALAÇÃO
# ============================================================================
verificar_pos_instalacao() {
    header "✅ VERIFICAÇÃO PÓS-INSTALAÇÃO"

    step "Stack..."
    docker stack ls | grep traefik-central && ok "Stack ativa" || erro "Stack não encontrada!"

    step "Serviço..."
    REPLICAS=$(docker service ls --filter "name=traefik-central_traefik-central" --format "{{.Replicas}}" 2>/dev/null || echo "0/0")
    [[ "$REPLICAS" == "1/1" ]] && ok "Serviço: $REPLICAS ✔" || warn "Serviço: $REPLICAS (aguarde alguns segundos)"

    step "Portas..."
    for PORT in 80 443 8080; do
        ss -tlnp | grep -q ":${PORT} " && ok "Porta $PORT: ouvindo" || warn "Porta $PORT: ainda não disponível"
    done
}

# ============================================================================
# RESUMO FINAL
# ============================================================================
resumo_final() {
    header "📋 RESUMO DA INSTALAÇÃO"
    echo -e "\n${GREEN}${BOLD}🎉 TRAEFIK CENTRAL INSTALADO!${NC}\n"

    separador
    echo -e "${WHITE}${BOLD}  FLUXO DE TRÁFEGO${NC}"
    echo -e "  ${CYAN}INTERNET → MIKROTIK → TRAEFIK CENTRAL${NC}"
    echo -e "                              ${CYAN}│${NC}"
    echo -e "                 ${CYAN}┌──────────┴──────────┐${NC}"
    echo -e "              ${CYAN}porta 80            porta 443${NC}"
    echo -e "           ${CYAN}HTTP Proxy          TCP Passthrough${NC}"
    echo -e "        ${CYAN}(Let's Encrypt)       (TLS não quebrado)${NC}"
    echo -e "                ${CYAN}│                     │${NC}"
    echo -e "           ${CYAN}Servidor correto  →  Servidor correto${NC}"
    separador

    echo -e "\n${WHITE}${BOLD}  DASHBOARD DO TRAEFIK CENTRAL${NC}"
    echo -e "  ${CYAN}URL:${NC}     https://${DASH_DOMAIN}:8080"
    echo -e "  ${CYAN}Usuário:${NC} ${DASH_USER}"
    separador

    if [ "$SERVER_COUNT" -gt 0 ]; then
        echo -e "\n${WHITE}${BOLD}  SERVIDORES CONFIGURADOS${NC}"
        echo -e "${SERVERS_SUMMARY}"
    fi

    separador
    echo -e "\n${WHITE}${BOLD}  PRÓXIMOS PASSOS${NC}"
    echo -e "  ${YELLOW}1.${NC} Aponte o DNS/Mikrotik de todos os domínios para o IP deste servidor Central"
    echo -e "  ${YELLOW}2.${NC} Verifique se o dashboard carrega em https://${DASH_DOMAIN}:8080"
    echo -e "  ${YELLOW}3.${NC} Teste o acesso a cada aplicação dos servidores de destino"
    echo -e "  ${YELLOW}4.${NC} Confirme que os certificados dos servidores continuam renovando"
    separador

    echo -e "\n${WHITE}${BOLD}  ARQUIVOS${NC}"
    echo -e "  ${CYAN}/root/traefik-central/docker-compose.yml${NC}"
    echo -e "  ${CYAN}/root/traefik-central/dynamic-config/dashboard.yml${NC}"
    echo -e "  ${CYAN}/root/traefik-central/dynamic-config/servers.yml${NC}  ← edite para adicionar servidores"

    separador
    echo -e "\n${WHITE}${BOLD}  COMANDOS ÚTEIS${NC}"
    echo -e "  ${YELLOW}Logs:${NC}     docker service logs traefik-central_traefik-central -f"
    echo -e "  ${YELLOW}Status:${NC}   docker stack ps traefik-central"
    echo -e "  ${YELLOW}Serviços:${NC} docker service ls"
    echo -e "  ${YELLOW}Remover:${NC}  docker stack rm traefik-central"

    echo -e "\n${GREEN}${BOLD}  LOGS INICIAIS:${NC}"
    docker service logs traefik-central_traefik-central --tail 20 2>/dev/null || true

    echo -e "\n${BLUE}================================================================${NC}"
    echo -e "${GREEN}${BOLD}  ✅ TRAEFIK CENTRAL PRONTO!${NC}"
    echo -e "${BLUE}================================================================${NC}\n"
}

# ============================================================================
# MENU PRINCIPAL
# ============================================================================
# ============================================================================
# GARANTIR QUE servers.yml EXISTE
# ============================================================================
garantir_servers_yml() {
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    local DIR="/root/traefik-central/dynamic-config"

    if [ ! -f "$SERVERS_FILE" ]; then
        warn "servers.yml não encontrado. Recriando..."
        mkdir -p "$DIR"
        cat > "$SERVERS_FILE" << 'SERVERS_EMPTY'
# ============================================================================
# ROTEAMENTO - TRAEFIK CENTRAL
# ============================================================================
# Nenhum servidor configurado.
# Use o menu opcao 5 para adicionar servidores.
# ============================================================================
SERVERS_EMPTY
        ok "servers.yml recriado em: $SERVERS_FILE"
    fi
}

# ============================================================================
# LISTAR SERVIDORES CONFIGURADOS
# ============================================================================
listar_servidores() {
    header "📋 SERVIDORES CONFIGURADOS"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"

    garantir_servers_yml

    step "Roteadores TCP (porta 443 - Passthrough)..."
    ROUTERS=$(grep -E "^\s{4}[a-zA-Z0-9_-]+-https:" "$SERVERS_FILE" | sed 's/://g' | sed 's/^[[:space:]]*//' || true)
    if [ -n "$ROUTERS" ]; then
        while IFS= read -r router; do
            # Pegar a rule (domínios) do router
            RULE=$(awk "/^    ${router}:/{found=1} found && /rule:/{print; exit}" "$SERVERS_FILE" | grep -oP '(?<=HostSNI\().*(?=\))' || echo "domínios não encontrados")
            # Pegar o endereço do service correspondente
            SVC="${router//-https/-https-svc}"
            ADDR=$(awk "/^    ${SVC}:/{found=1} found && /address:/{print; exit}" "$SERVERS_FILE" | grep -oP '"[^"]+"' | tr -d '"' || echo "endereço não encontrado")
            echo -e "  ${GREEN}✔ ${router/-https/}${NC}"
            info "  Domínios: $RULE"
            info "  Endereço: $ADDR"
            echo
        done <<< "$ROUTERS"
    else
        warn "Nenhum servidor configurado ainda."
    fi
}

# ============================================================================
# ADICIONAR SERVIDOR
# ============================================================================
adicionar_servidor() {
    header "➕ ADICIONAR SERVIDOR"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"

    garantir_servers_yml

    echo -e "${CYAN}  Informe os dados do novo servidor:${NC}\n"

    # Nome do servidor
    while true; do
        read -p "  Nome do servidor (ex: srv2): " SERVER_NAME < /dev/tty
        [ -z "$SERVER_NAME" ] && { erro "Nome não pode ser vazio."; continue; }
        [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { erro "Use apenas letras, números, - e _"; continue; }
        grep -q "^    ${SERVER_NAME}-https:" "$SERVERS_FILE" 2>/dev/null && { erro "Servidor '$SERVER_NAME' já existe!"; continue; }
        break
    done

    # IP
    echo -e "  ${CYAN}IP do servidor (privado se mesma LAN, público se externo):${NC}"
    while true; do
        read -p "  IP do servidor: " SERVER_IP < /dev/tty
        [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        erro "IP inválido. Formato: 192.168.25.102"
    done

    # Teste de conectividade opcional
    read -p "  Testar conectividade com $SERVER_IP? (S/n): " TEST_CONN < /dev/tty
    if [[ ! "$TEST_CONN" =~ ^[Nn]$ ]]; then
        step "Testando ping..."
        if ping -c 1 -W 2 "$SERVER_IP" &>/dev/null; then
            ok "Ping: OK"
        else
            warn "Ping falhou (pode ser firewall), tentando porta 80..."
            if timeout 2 bash -c "</dev/tcp/$SERVER_IP/80" 2>/dev/null; then
                ok "Porta 80: Aberta"
            else
                erro "Não foi possível alcançar $SERVER_IP nas portas comuns."
                read -p "Deseja continuar mesmo assim? (s/N): " CONT_ERR < /dev/tty
                [[ "$CONT_ERR" =~ ^[Ss]$ ]] || return
            fi
        fi
    fi

    read -p "  Porta HTTPS [443]: " SERVER_PORT_HTTPS < /dev/tty
    SERVER_PORT_HTTPS="${SERVER_PORT_HTTPS:-443}"

    read -p "  Porta HTTP [80]: " SERVER_PORT_HTTP < /dev/tty
    SERVER_PORT_HTTP="${SERVER_PORT_HTTP:-80}"

    # Coletar domínios por domínio base
    ALL_DOMAINS=()
    separador
    echo -e "\n  ${YELLOW}📋 CONFIGURAÇÃO DE DOMÍNIOS (MODELO ORION)${NC}"
    echo -e "  ${CYAN}Você pode adicionar subdomínios de um ou mais domínios base.${NC}"
    echo -e "  ${WHITE}Isso funcionará com seus certificados atuais sem alteração.${NC}\n"

    while true; do
        # Pedir domínio base
        while true; do
            read -p "  Domínio base (ex: eclicksolucoes.com.br): " BASE_DOMAIN < /dev/tty
            BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            [[ "$BASE_DOMAIN" =~ \. ]] && break
            erro "Domínio inválido. Ex: eclicksolucoes.com.br"
        done

        # Pedir subdomínios
        echo -e "  ${CYAN}Subdomínios para ${WHITE}.${BASE_DOMAIN}${NC}"
        echo -e "  ${WHITE}Ex: n8n unichat painel evolution${NC} ${BLUE}(separados por espaço)${NC}"
        echo -e "  ${YELLOW}DICA: Digite '*' para habilitar CURINGA (Catcher/Wildcard).${NC}"
        echo -e "  ${WHITE}Isso repassará QUALQUER subdomínio novo automaticamente para este servidor!${NC}"
        while true; do
            read -p "  Subdomínios (ou *): " SUBS_INPUT < /dev/tty
            [ -n "$SUBS_INPUT" ] && break
            erro "Informe pelo menos um subdomínio ou *."
        done

        # Montar e mostrar domínios gerados
        echo -e "\n  ${GREEN}Domínios gerados:${NC}"
        for sub in $SUBS_INPUT; do
            if [ "$sub" == "*" ]; then
                FULL="*.${BASE_DOMAIN}"
            else
                sub=$(echo "$sub" | tr -d ' ' | tr -d '.' | tr '[:upper:]' '[:lower:]')
                FULL="${sub}.${BASE_DOMAIN}"
            fi
            ALL_DOMAINS+=("$FULL")
            ok "  $FULL"
        done
        echo

        read -p "  Adicionar subdomínios de outro domínio base? (s/N): " MORE_BASE < /dev/tty
        [[ "$MORE_BASE" =~ ^[Ss]$ ]] || break
        echo
    done

    # Formatar rules completas (TCP e HTTP)
    RULE_TCP=""
    RULE_HTTP=""
    for dom in "${ALL_DOMAINS[@]}"; do
        [ -n "$RULE_TCP" ] && RULE_TCP="${RULE_TCP} || "
        [ -n "$RULE_HTTP" ] && RULE_HTTP="${RULE_HTTP} || "
        
        if [[ "$dom" == \*.* ]]; then
            base=${dom#*.}
            RULE_TCP="${RULE_TCP}HostSNIRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || HostSNI(\`${base}\`)"
            RULE_HTTP="${RULE_HTTP}HostRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || Host(\`${base}\`)"
        else
            RULE_TCP="${RULE_TCP}HostSNI(\`${dom}\`)"
            RULE_HTTP="${RULE_HTTP}Host(\`${dom}\`)"
        fi
    done

    # Resumo final
    separador
    echo -e "\n  ${YELLOW}Resumo — confirmar adição:${NC}"
    info "  Servidor: $SERVER_NAME"
    info "  IP:       ${SERVER_IP}:${SERVER_PORT_HTTPS} (HTTPS) / ${SERVER_IP}:${SERVER_PORT_HTTP} (HTTP)"
    echo -e "  ${WHITE}Domínios:${NC}"
    for dom in "${ALL_DOMAINS[@]}"; do
        echo -e "    ${CYAN}→${NC} $dom"
    done
    echo
    read -p "  Confirmar? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    # Fazer backup
    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak"

    # Gravar no arquivo via Python
    python3 /tmp/traefik_add.py "$SERVERS_FILE" "$SERVER_NAME" "$SERVER_IP" "$SERVER_PORT_HTTPS" "$SERVER_PORT_HTTP" "$RULE_TCP" "$RULE_HTTP"

    ok "Servidor '${SERVER_NAME}' adicionado com sucesso!"
    info "O Traefik recarrega automaticamente (watch=true)."
    info "Backup salvo em: ${SERVERS_FILE}.bak"

    echo -e "
  ${WHITE}Domínios configurados:${NC}"
    for dom in "${ALL_DOMAINS[@]}"; do
        echo -e "    ${CYAN}→${NC} $dom"
    done

    step "Verificando logs..."
    sleep 4
    LOGS=$(docker service logs traefik-central_traefik-central --tail 15 2>/dev/null | grep -v "use of closed network connection" || true)
    if echo "$LOGS" | grep -q "ERR"; then
        erro "Erros detectados:"
        echo "$LOGS" | grep "ERR"
    else
        ok "Nenhum erro nos logs!"
    fi
}


# ============================================================================
# SELECIONAR SERVIDOR (menu numerado reutilizável)
# ============================================================================
selecionar_servidor() {
    # Uso: selecionar_servidor "mensagem"
    # Retorna: $SERVER_NAME_SEL
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    local MSG="${1:-Selecione o servidor:}"

    ROUTERS=$(grep -E "^    [a-zA-Z0-9_-]+-https:" "$SERVERS_FILE" 2>/dev/null | sed 's/://g' | sed 's/^[[:space:]]*//' | sed 's/-https$//' || true)

    if [ -z "$ROUTERS" ]; then
        warn "Nenhum servidor configurado ainda."
        SERVER_NAME_SEL=""
        return 1
    fi

    # Montar array
    mapfile -t SRV_ARRAY <<< "$ROUTERS"

    echo -e "\n  ${YELLOW}${MSG}${NC}\n"
    local i=1
    for srv in "${SRV_ARRAY[@]}"; do
        # Pegar domínios do servidor
        DOMS=$(awk "/^    ${srv}-https:/{found=1} found && /rule:/{print; exit}" "$SERVERS_FILE" | grep -oP "(?<=HostSNI\().*(?=\))" | tr -d '\`' | sed 's/ || HostSNI(/ /g' || echo "")
        echo -e "  ${CYAN}${i})${NC} ${WHITE}${srv}${NC}"
        [ -n "$DOMS" ] && echo -e "     ${BLUE}↳ ${DOMS}${NC}"
        i=$((i+1))
    done
    echo -e "  ${CYAN}0)${NC} Cancelar\n"

    while true; do
        read -p "  Escolha [1-$((i-1))]: " SEL < /dev/tty
        [ "$SEL" = "0" ] && { SERVER_NAME_SEL=""; return 1; }
        [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#SRV_ARRAY[@]}" ] && break
        erro "Opção inválida. Digite um número entre 1 e ${#SRV_ARRAY[@]}."
    done

    SERVER_NAME_SEL="${SRV_ARRAY[$((SEL-1))]}"
    ok "Servidor selecionado: ${SERVER_NAME_SEL}"
}

# ============================================================================
# ADICIONAR DOMÍNIO A SERVIDOR EXISTENTE
# ============================================================================
adicionar_dominio() {
    header "🌐 ADICIONAR DOMÍNIO A SERVIDOR EXISTENTE"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"

    garantir_servers_yml

    # 1. Selecionar servidor
    selecionar_servidor "Qual servidor deseja adicionar domínio?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    # 2. Extrair domínios já existentes (para mostrar base e checar duplicatas)
    mapfile -t EXISTING_DOMS < <(
        awk "/^    ${SERVER_NAME}-https:/,/entryPoints:/" "$SERVERS_FILE" \
        | grep -oP "(?<=HostSNI\(\`)([^\`]+)(?=\`\))" || true
    )

    # Extrair domínios base únicos
    mapfile -t BASE_ARRAY < <(
        printf "%s\n" "${EXISTING_DOMS[@]}" \
        | awk -F. '{OFS="."; $1=""; print substr($0,2)}' | sort -u
    )

    # 3. Escolher domínio base
    echo -e "\n  ${YELLOW}Selecione o domínio base:${NC}\n"
    local i=1
    for base in "${BASE_ARRAY[@]}"; do
        echo -e "  ${CYAN}${i})${NC} ${WHITE}.${base}${NC}"
        i=$((i+1))
    done
    echo -e "  ${CYAN}${i})${NC} Outro (digitar manualmente)\n"

    while true; do
        read -p "  Escolha [1-${i}]: " SEL_BASE < /dev/tty
        [[ "$SEL_BASE" =~ ^[0-9]+$ ]] && [ "$SEL_BASE" -ge 1 ] && [ "$SEL_BASE" -le "$i" ] && break
        erro "Opção inválida."
    done

    # 4. Coletar novos subdomínios
    NEW_DOMAINS_LIST=()
    if [ "$SEL_BASE" -eq "$i" ]; then
        while true; do
            read -p "  Domínio completo (ex: app.outrodominio.com): " FULL_DOMAIN < /dev/tty
            FULL_DOMAIN=$(echo "$FULL_DOMAIN" | tr -d " ")
            [ -n "$FULL_DOMAIN" ] && break
            erro "Domínio não pode ser vazio."
        done
        NEW_DOMAINS_LIST=("$FULL_DOMAIN")
    else
        CHOSEN_BASE="${BASE_ARRAY[$((SEL_BASE-1))]}"
        echo -e "\n  ${CYAN}Subdomínios para ${WHITE}.${CHOSEN_BASE}${NC}"
        echo -e "  ${WHITE}Ex: n8n unichat evolution${NC} ${BLUE}(separados por espaço)${NC}"
        echo -e "  ${YELLOW}DICA: Digite '*' para Curinga (Catcher de todos subdomínios).${NC}\n"
        while true; do
            read -p "  Subdomínios (ou *): " SUBDOMAIN_INPUT < /dev/tty
            [ -n "$SUBDOMAIN_INPUT" ] && break
            erro "Informe pelo menos um subdomínio ou *."
        done
        for sub in $SUBDOMAIN_INPUT; do
            if [ "$sub" == "*" ]; then
                NEW_DOMAINS_LIST+=("*.${CHOSEN_BASE}")
            else
                sub=$(echo "$sub" | tr -d " .")
                NEW_DOMAINS_LIST+=("${sub}.${CHOSEN_BASE}")
            fi
        done
    fi

    # 5. Verificar duplicatas
    ADDED=()
    SKIPPED=()
    for dom in "${NEW_DOMAINS_LIST[@]}"; do
        local FOUND=false
        for existing in "${EXISTING_DOMS[@]}"; do
            [ "$existing" = "$dom" ] && FOUND=true && break
        done
        if $FOUND; then
            SKIPPED+=("$dom")
        else
            ADDED+=("$dom")
        fi
    done

    if [ ${#SKIPPED[@]} -gt 0 ]; then
        echo -e "\n  ${YELLOW}Já existentes (ignorados):${NC}"
        for d in "${SKIPPED[@]}"; do warn "  $d"; done
    fi

    if [ ${#ADDED[@]} -eq 0 ]; then
        warn "Nenhum domínio novo. Todos já estavam cadastrados."
        return
    fi

    # 6. Montar lista COMPLETA (existentes + novos) para reescrever a rule
    ALL_FINAL=("${EXISTING_DOMS[@]}" "${ADDED[@]}")

    echo -e "\n  ${GREEN}Domínios que serão adicionados:${NC}"
    for d in "${ADDED[@]}"; do ok "  $d"; done
    echo -e "\n  ${WHITE}Rule final completa:${NC}"
    for d in "${ALL_FINAL[@]}"; do echo -e "    ${CYAN}→${NC} $d"; done

    read -p "\n  Confirmar? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak"

    # 7. Formatar rules completas (TCP e HTTP)
    RULE_TCP=""
    RULE_HTTP=""
    for dom in "${ALL_FINAL[@]}"; do
        # Trata dominio normal vs wildcard
        [ -n "$RULE_TCP" ] && RULE_TCP="${RULE_TCP} || "
        [ -n "$RULE_HTTP" ] && RULE_HTTP="${RULE_HTTP} || "
        
        if [[ "$dom" == \*.* ]]; then
            base=${dom#*.}
            RULE_TCP="${RULE_TCP}HostSNIRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || HostSNI(\`${base}\`)"
            RULE_HTTP="${RULE_HTTP}HostRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || Host(\`${base}\`)"
        else
            RULE_TCP="${RULE_TCP}HostSNI(\`${dom}\`)"
            RULE_HTTP="${RULE_HTTP}Host(\`${dom}\`)"
        fi
    done

    python3 - "$SERVERS_FILE" "$SERVER_NAME" "$RULE_TCP" "$RULE_HTTP" << 'PYUPDATE'
import sys, re

filepath  = sys.argv[1]
srv_name  = sys.argv[2]
rule_tcp  = sys.argv[3]
rule_http = sys.argv[4]

with open(filepath, "r") as f:
    content = f.read()

# Substituir rule TCP (linha unica com aspas duplas)
content = re.sub(
    rf'(    {re.escape(srv_name)}-https:\n      rule: )"[^"]*"',
    f'    {srv_name}-https:\n      rule: "{rule_tcp}"',
    content
)

# Substituir rule HTTP
content = re.sub(
    rf'(    {re.escape(srv_name)}-http:\n      rule: )"[^"]*"',
    f'    {srv_name}-http:\n      rule: "{rule_http}"',
    content
)

with open(filepath, "w") as f:
    f.write(content)

print("  Arquivo atualizado com sucesso.")
PYUPDATE

    ok "Domínios adicionados ao servidor '${SERVER_NAME}'!"
    info "Backup: ${SERVERS_FILE}.bak"
    verificar_logs_recentes 6
}



# ============================================================================
# REMOVER DOMÍNIO DE SERVIDOR EXISTENTE
# ============================================================================
remover_dominio() {
    header "🗑️ REMOVER DOMÍNIO DE SERVIDOR EXISTENTE"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"

    garantir_servers_yml

    selecionar_servidor "De qual servidor deseja remover um domínio?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    mapfile -t DOM_ARRAY < <(
        awk "/^    ${SERVER_NAME}-https:/,/entryPoints:/" "$SERVERS_FILE" \
        | grep -oP "(?<=HostSNI\(\`)([^\`]+)(?=\`\))" || true
    )

    if [ ${#DOM_ARRAY[@]} -eq 0 ]; then
        erro "Nenhum domínio encontrado para '${SERVER_NAME}'."
        return
    fi

    if [ ${#DOM_ARRAY[@]} -eq 1 ]; then
        warn "Servidor possui apenas 1 domínio. Use 'Remover servidor' para remover."
        return
    fi

    echo -e "\n  ${YELLOW}Domínios atuais:${NC}\n"
    local i=1
    for dom in "${DOM_ARRAY[@]}"; do
        echo -e "  ${CYAN}${i})${NC} ${WHITE}${dom}${NC}"
        i=$((i+1))
    done
    echo -e "  ${CYAN}0)${NC} Cancelar\n"

    while true; do
        read -p "  Qual remover? [1-$((i-1))]: " SEL_DOM < /dev/tty
        [ "$SEL_DOM" = "0" ] && { warn "Cancelado."; return; }
        [[ "$SEL_DOM" =~ ^[0-9]+$ ]] && [ "$SEL_DOM" -ge 1 ] && [ "$SEL_DOM" -le "${#DOM_ARRAY[@]}" ] && break
        erro "Opção inválida."
    done

    local DOM_REMOVER="${DOM_ARRAY[$((SEL_DOM-1))]}"
    read -p "  Remover '${DOM_REMOVER}'? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    local NEW_SNI="" NEW_HOST=""
    for dom in "${DOM_ARRAY[@]}"; do
        [ "$dom" = "$DOM_REMOVER" ] && continue
        
        [ -n "$NEW_SNI" ] && NEW_SNI="${NEW_SNI} || "
        [ -n "$NEW_HOST" ] && NEW_HOST="${NEW_HOST} || "
        
        if [[ "$dom" == \*.* ]]; then
            base=${dom#*.}
            NEW_SNI="${NEW_SNI}HostSNIRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || HostSNI(\`${base}\`)"
            NEW_HOST="${NEW_HOST}HostRegexp(\`{subdomain:[a-zA-Z0-9-_.]+}.${base}\`) || Host(\`${base}\`)"
        else
            NEW_SNI="${NEW_SNI}HostSNI(\`${dom}\`)"
            NEW_HOST="${NEW_HOST}Host(\`${dom}\`)"
        fi
    done

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak"

    python3 - "$SERVERS_FILE" "$SERVER_NAME" "$NEW_SNI" "$NEW_HOST" << 'PYREMDOM'
import sys, re
filepath, srv_name, new_sni, new_host = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(filepath, 'r') as f:
    content = f.read()
content = re.sub(rf'(    {re.escape(srv_name)}-https:\n      rule: )"[^"]*"', f'    {srv_name}-https:\n      rule: "{new_sni}"', content)
content = re.sub(rf'(    {re.escape(srv_name)}-http:\n      rule: )"[^"]*"', f'    {srv_name}-http:\n      rule: "{new_host}"', content)
with open(filepath, 'w') as f:
    f.write(content)
print("  Atualizado.")
PYREMDOM

    ok "'${DOM_REMOVER}' removido!"
    verificar_logs_recentes 6
}

# ============================================================================
# REMOVER SERVIDOR
# ============================================================================
remover_servidor() {
    header "➖ REMOVER SERVIDOR"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"

    garantir_servers_yml
    selecionar_servidor "Qual servidor deseja remover?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    read -p "  Digite 'sim' para confirmar remoção de '${SERVER_NAME}': " CONF < /dev/tty
    [ "$CONF" != "sim" ] && { warn "Cancelado."; return; }

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak"
    python3 /tmp/traefik_remove.py "$SERVERS_FILE" "$SERVER_NAME"

    ok "Servidor '${SERVER_NAME}' removido!"
    echo -e "\n  ${WHITE}servers.yml atual:${NC}"
    cat "$SERVERS_FILE"
    verificar_logs_recentes 6
}

# ============================================================================
# LISTAR SERVIDORES
# ============================================================================
listar_servidores() {
    header "📋 SERVIDORES CONFIGURADOS"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"

    garantir_servers_yml

    ROUTERS=$(grep -E "^\s{4}[a-zA-Z0-9_-]+-https:" "$SERVERS_FILE" | sed 's/://g' | sed 's/^[[:space:]]*//' | sed 's/-https$//' || true)
    if [ -n "$ROUTERS" ]; then
        while IFS= read -r router; do
            ADDR=$(awk "/^    ${router}-https-svc:/{found=1} found && /address:/{print; exit}" "$SERVERS_FILE" | grep -oP '"[^"]+"' | tr -d '"' || echo "?")
            DOMS=$(awk "/^    ${router}-https:/{found=1} found && /rule:/{print; exit}" "$SERVERS_FILE" | grep -oP "(?<=HostSNI\().*(?=\))" | tr -d '\`' | sed 's/ || HostSNI(/, /g' || echo "?")
            echo -e "  ${GREEN}✔ ${router}${NC}"
            info "  Endereço: $ADDR"
            info "  Domínios: $DOMS"
            echo
        done <<< "$ROUTERS"
    else
        warn "Nenhum servidor configurado."
    fi
}

# ============================================================================
# MENU GERENCIAR SERVIDORES
# ============================================================================
menu_gerenciar_servidores() {
    header "🖥️ GERENCIAR SERVIDORES (ORION / CLIENTES)"
    echo -e "  ${CYAN}1)${NC} Vincular novo servidor Orion"
    echo -e "  ${CYAN}2)${NC} Adicionar domínio a servidor existente"
    echo -e "  ${CYAN}3)${NC} Remover domínio de servidor existente"
    echo -e "  ${CYAN}4)${NC} Remover servidor completo"
    echo -e "  ${CYAN}0)${NC} Voltar\n"
    read -p "Escolha: " OPCAO_SERV < /dev/tty

    case "$OPCAO_SERV" in
        1) criar_script_auxiliar; adicionar_servidor ;;
        2) adicionar_dominio ;;
        3) remover_dominio ;;
        4) criar_script_auxiliar; remover_servidor ;;
        0) return ;;
        *) erro "Opção inválida." ;;
    esac
}

# ============================================================================
# MENU PRINCIPAL
# ============================================================================
menu_principal() {
    clear
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${GREEN}${BOLD}     🚀 TRAEFIK CENTRAL — GERENCIADOR DE INSTALAÇÃO${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${CYAN}  Estratégia: HTTP Proxy (80) + TCP Passthrough (443)${NC}"
    echo -e "${CYAN}  Os servidores de destino mantêm seus próprios certificados.${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}\n"
    echo -e "  ${CYAN}1)${NC} ${WHITE}Instalar Traefik Central${NC}"
    echo -e "  ${CYAN}2)${NC} ${WHITE}Diagnóstico do sistema${NC}"
    echo -e "  ${CYAN}3)${NC} ${WHITE}Verificar Traefik(s) instalados${NC}"
    echo -e "  ${CYAN}4)${NC} ${RED}Remover Traefik instalado${NC}"
    echo -e "  ${CYAN}5)${NC} ${GREEN}Gerenciar servidores/domínios${NC}"
    echo -e "  ${CYAN}6)${NC} ${WHITE}Listar servidores configurados${NC}"
    echo -e "  ${CYAN}0)${NC} ${WHITE}Sair${NC}\n"
    separador
    read -p "Escolha: " OPCAO_MENU < /dev/tty
    echo
}

# ============================================================================
# FLUXO PRINCIPAL
# ============================================================================
verificar_root

while true; do
    menu_principal
    case "$OPCAO_MENU" in
        1)
            diagnostico_sistema
            pausar
            verificar_traefik_existente
            if [ "${TRAEFIK_ENCONTRADO:-false}" = true ]; then
                echo -e "\n${YELLOW}⚠ Traefik detectado neste servidor.${NC}"
                read -p "Continuar com a instalação mesmo assim? (s/N): " CONT < /dev/tty
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
        5) menu_gerenciar_servidores; pausar ;;
        6) listar_servidores; pausar ;;
        0) echo -e "\n${GREEN}Saindo. Até mais!${NC}\n"; exit 0 ;;
        *) erro "Opção inválida."; sleep 2 ;;
    esac
done
