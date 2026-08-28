#!/bin/bash

# ============================================================================
# 🚀 INSTALADOR DO TRAEFIK CENTRAL — TLS TERMINATION
# ============================================================================
# Estratégia: HTTPS Reverse Proxy com TLS Termination no Central
#
# Fluxo:
#   INTERNET → MIKROTIK → TRAEFIK CENTRAL (certificados Let's Encrypt)
#                              ├─ porta 80  → redirect para HTTPS
#                              └─ porta 443 → TLS termination → HTTP → servidor destino
#
# ✅ Certificados Let's Encrypt gerenciados pelo Central
# ✅ Servidores destino NÃO precisam de SSL/TLS
# ✅ Zero alterações nas stacks existentes
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
# LIMPAR BACKUPS ANTIGOS (mantém só os últimos N)
# ============================================================================
limpar_backups() {
    local MAX=${1:-5}
    local BAK_DIR="/root/traefik-central/dynamic-config"
    local BAKS=($(ls -1t "$BAK_DIR/servers.yml.bak."* "$BAK_DIR/servers.yml.bak.diag."* 2>/dev/null))
    local COUNT=${#BAKS[@]}
    [ "$COUNT" -le "$MAX" ] && return
    local REMOVE=$((COUNT - MAX))
    for bak in "${BAKS[@]:$MAX}"; do rm -f "$bak"; done
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
# GO2RTC / WEBRTC
# ============================================================================
coletar_detalhes_go2rtc() {
    GO2RTC_ENABLED=1
    GO2RTC_PUBLIC_PORT="${GO2RTC_PUBLIC_PORT:-8555}"
    GO2RTC_TARGET_PORT="${GO2RTC_TARGET_PORT:-8555}"
    GO2RTC_IP="${GO2RTC_IP:-}"
    CURRENT_GO2RTC_PUBLIC_PORT="${CURRENT_GO2RTC_PUBLIC_PORT:-}"

    while true; do
        read -p "  IP do go2rtc (ex: 192.168.25.200): " GO2RTC_IP < /dev/tty
        [[ "$GO2RTC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        erro "IP inválido."
    done

    while true; do
        read -p "  Porta publicada no Central [${GO2RTC_PUBLIC_PORT}]: " GO2RTC_PUBLIC_PORT < /dev/tty
        GO2RTC_PUBLIC_PORT="${GO2RTC_PUBLIC_PORT:-8555}"
        [[ "$GO2RTC_PUBLIC_PORT" =~ ^[0-9]+$ ]] && [ "$GO2RTC_PUBLIC_PORT" -ge 1 ] && [ "$GO2RTC_PUBLIC_PORT" -le 65535 ] || { erro "Porta inválida."; continue; }
        [[ "$GO2RTC_PUBLIC_PORT" != "80" && "$GO2RTC_PUBLIC_PORT" != "443" && "$GO2RTC_PUBLIC_PORT" != "8080" ]] || { erro "Essa porta é reservada pelo Traefik Central."; continue; }
        break
    done

    if [ -n "$CURRENT_GO2RTC_PUBLIC_PORT" ] && [ "$GO2RTC_PUBLIC_PORT" = "$CURRENT_GO2RTC_PUBLIC_PORT" ]; then
        :
    elif ss -tln 2>/dev/null | grep -q ":${GO2RTC_PUBLIC_PORT} " || ss -uln 2>/dev/null | grep -q ":${GO2RTC_PUBLIC_PORT} "; then
        erro "A porta ${GO2RTC_PUBLIC_PORT} já está em uso neste servidor. Escolha outra."
        return 1
    fi

    while true; do
        read -p "  Porta do go2rtc no destino [${GO2RTC_TARGET_PORT}]: " GO2RTC_TARGET_PORT < /dev/tty
        GO2RTC_TARGET_PORT="${GO2RTC_TARGET_PORT:-8555}"
        [[ "$GO2RTC_TARGET_PORT" =~ ^[0-9]+$ ]] && [ "$GO2RTC_TARGET_PORT" -ge 1 ] && [ "$GO2RTC_TARGET_PORT" -le 65535 ] && break
        erro "Porta inválida."
    done

    ok "go2rtc/WebRTC: ${GO2RTC_PUBLIC_PORT}/TCP+UDP → ${GO2RTC_IP}:${GO2RTC_TARGET_PORT}"
}

escrever_go2rtc_yml() {
    local BASE_DIR="${1:-/root/traefik-central}"
    cat > "$BASE_DIR/dynamic-config/go2rtc.yml" <<EOF
# ============================================================================
# GO2RTC / WEBRTC
# ============================================================================
# Porta publicada no Central: ${GO2RTC_PUBLIC_PORT}/TCP+UDP
# Destino configurado: ${GO2RTC_IP}:${GO2RTC_TARGET_PORT}
# ============================================================================

tcp:
  routers:
    go2rtc-tcp:
      entryPoints: [go2rtc-tcp]
      rule: "HostSNI(\`*\`)"
      service: go2rtc-tcp
  services:
    go2rtc-tcp:
      loadBalancer:
        servers:
          - address: "${GO2RTC_IP}:${GO2RTC_TARGET_PORT}"

udp:
  routers:
    go2rtc-udp:
      entryPoints: [go2rtc-udp]
      service: go2rtc-udp
  services:
    go2rtc-udp:
      loadBalancer:
        servers:
          - address: "${GO2RTC_IP}:${GO2RTC_TARGET_PORT}"
EOF
}

atualizar_compose_go2rtc() {
    local COMPOSE_FILE="$1"
    local OLD_PUBLIC_PORT="${2:-}"
    local ENABLED="${3:-0}"
    local NEW_PUBLIC_PORT="${4:-8555}"

    python3 - "$COMPOSE_FILE" "$OLD_PUBLIC_PORT" "$ENABLED" "$NEW_PUBLIC_PORT" << 'PYGO2RTC'
import re
import sys

compose_file, old_port, enabled, new_port = sys.argv[1:5]

with open(compose_file, "r", encoding="utf-8") as f:
    content = f.read()

content = re.sub(
    r"\n\s*# BEGIN GO2RTC ENTRYPOINTS.*?# END GO2RTC ENTRYPOINTS\s*",
    "\n",
    content,
    flags=re.DOTALL,
)
content = re.sub(
    r"\n\s*# BEGIN GO2RTC PORTS.*?# END GO2RTC PORTS\s*",
    "\n",
    content,
    flags=re.DOTALL,
)
content = re.sub(
    r'^\s*-\s*"--entrypoints\.go2rtc-(tcp|udp)\.address=.*"\n',
    "",
    content,
    flags=re.MULTILINE,
)

if old_port.isdigit():
    for proto in ("tcp", "udp"):
        pattern = (
            rf'^\s*-\s*target:\s*{re.escape(old_port)}\n'
            rf'\s*published:\s*{re.escape(old_port)}\n'
            rf'\s*protocol:\s*{proto}\n'
            rf'\s*mode:\s*host\n'
        )
        content = re.sub(pattern, "", content, flags=re.MULTILINE)

if enabled == "1":
    entry_anchor = '      - "--entrypoints.dashboard.address=:8080"\n'
    if entry_anchor not in content:
        raise SystemExit("Anchor de entrypoint não encontrado no docker-compose.yml")
    entry_block = (
        "      # BEGIN GO2RTC ENTRYPOINTS\n"
        f'      - "--entrypoints.go2rtc-tcp.address=:{new_port}/tcp"\n'
        f'      - "--entrypoints.go2rtc-udp.address=:{new_port}/udp"\n'
        "      # END GO2RTC ENTRYPOINTS\n"
    )
    content = content.replace(entry_anchor, entry_anchor + entry_block, 1)

    port_anchor = (
        "      - target: 8080\n"
        "        published: 8080\n"
        "        mode: host\n"
    )
    if port_anchor not in content:
        raise SystemExit("Anchor de porta não encontrado no docker-compose.yml")
    port_block = (
        "      # BEGIN GO2RTC PORTS\n"
        f"      - target: {new_port}\n"
        f"        published: {new_port}\n"
        "        protocol: tcp\n"
        "        mode: host\n"
        f"      - target: {new_port}\n"
        f"        published: {new_port}\n"
        "        protocol: udp\n"
        "        mode: host\n"
        "      # END GO2RTC PORTS\n"
    )
    content = content.replace(port_anchor, port_anchor + port_block, 1)

content = re.sub(r"\n{3,}", "\n\n", content)

with open(compose_file, "w", encoding="utf-8") as f:
    f.write(content)
PYGO2RTC
}

restaurar_backup_go2rtc() {
    local GO2RTC_FILE="$1"
    local GO2RTC_BACKUP="$2"

    if [ -n "$GO2RTC_BACKUP" ] && [ -f "$GO2RTC_BACKUP" ]; then
        cp "$GO2RTC_BACKUP" "$GO2RTC_FILE"
    else
        rm -f "$GO2RTC_FILE"
    fi
}

aplicar_stack_com_rollback() {
    local COMPOSE_FILE="$1"
    local COMPOSE_BACKUP="$2"
    local GO2RTC_FILE="$3"
    local GO2RTC_BACKUP="$4"
    local ACTION_LABEL="$5"

    step "Aplicando stack..."
    if ! docker stack deploy -c "$COMPOSE_FILE" traefik-central; then
        warn "Falha no deploy. Restaurando backup..."
        cp "$COMPOSE_BACKUP" "$COMPOSE_FILE"
        restaurar_backup_go2rtc "$GO2RTC_FILE" "$GO2RTC_BACKUP"
        docker stack deploy -c "$COMPOSE_FILE" traefik-central >/dev/null 2>&1 || true
        erro "Não foi possível ${ACTION_LABEL}. Backup restaurado."
        return 1
    fi

    for i in $(seq 1 20); do
        REPLICAS=$(docker service ls --filter "name=traefik-central_traefik-central" --format "{{.Replicas}}" 2>/dev/null | head -1)
        [ "$REPLICAS" = "1/1" ] && return 0
        sleep 1
    done

    warn "A stack não estabilizou após a atualização. Restaurando backup..."
    cp "$COMPOSE_BACKUP" "$COMPOSE_FILE"
    restaurar_backup_go2rtc "$GO2RTC_FILE" "$GO2RTC_BACKUP"
    docker stack deploy -c "$COMPOSE_FILE" traefik-central >/dev/null 2>&1 || true
    erro "Não foi possível ${ACTION_LABEL}. Backup restaurado."
    return 1
}

configurar_go2rtc_existente() {
    header "🎥 CONFIGURAR GO2RTC / WEBRTC"
    local BASE_DIR="/root/traefik-central"
    local COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    local GO2RTC_FILE="$BASE_DIR/dynamic-config/go2rtc.yml"
    local OLD_PUBLIC_PORT="8555"

    [ ! -f "$COMPOSE_FILE" ] && { erro "docker-compose.yml não encontrado em $BASE_DIR"; return; }

    if [ -f "$GO2RTC_FILE" ]; then
        OLD_PUBLIC_PORT=$(grep -oP '(?<=Porta publicada no Central: )\d+' "$GO2RTC_FILE" 2>/dev/null | head -1 || echo "8555")
        info "Configuração atual detectada:"
        info "  Porta pública: ${OLD_PUBLIC_PORT}/TCP+UDP"
        info "  Destino: $(grep -oP '(?<=address: ")[^"]+' "$GO2RTC_FILE" 2>/dev/null | head -1 || echo "?")"
        echo
    fi

    GO2RTC_ENABLED=1
    CURRENT_GO2RTC_PUBLIC_PORT="$OLD_PUBLIC_PORT"
    GO2RTC_PUBLIC_PORT="$OLD_PUBLIC_PORT"
    GO2RTC_TARGET_PORT=$(grep -oP '(?<=address: "[0-9.]+:)\d+' "$GO2RTC_FILE" 2>/dev/null | head -1 || echo "8555")
    GO2RTC_IP=$(grep -oP '(?<=address: ")[0-9.]+' "$GO2RTC_FILE" 2>/dev/null | head -1 || echo "")

    coletar_detalhes_go2rtc || return

    local COMPOSE_BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    local GO2RTC_BACKUP=""
    cp "$COMPOSE_FILE" "$COMPOSE_BACKUP"
    [ -f "$GO2RTC_FILE" ] && { GO2RTC_BACKUP="${GO2RTC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"; cp "$GO2RTC_FILE" "$GO2RTC_BACKUP"; }
    limpar_backups

    atualizar_compose_go2rtc "$COMPOSE_FILE" "$OLD_PUBLIC_PORT" "1" "$GO2RTC_PUBLIC_PORT"
    escrever_go2rtc_yml "$BASE_DIR"
    ok "go2rtc.yml"

    aplicar_stack_com_rollback "$COMPOSE_FILE" "$COMPOSE_BACKUP" "$GO2RTC_FILE" "$GO2RTC_BACKUP" "aplicar a configuração do go2rtc" || return

    ss -tlnp | grep -q ":${GO2RTC_PUBLIC_PORT} " && ok "Porta ${GO2RTC_PUBLIC_PORT}/TCP: ok" || warn "Porta ${GO2RTC_PUBLIC_PORT}/TCP: aguarde"
    ss -ulnp | grep -q ":${GO2RTC_PUBLIC_PORT} " && ok "Porta ${GO2RTC_PUBLIC_PORT}/UDP: ok" || warn "Porta ${GO2RTC_PUBLIC_PORT}/UDP: aguarde"
    verificar_logs_recentes 15
}

remover_go2rtc_existente() {
    header "🗑️ REMOVER GO2RTC / WEBRTC"
    local BASE_DIR="/root/traefik-central"
    local COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    local GO2RTC_FILE="$BASE_DIR/dynamic-config/go2rtc.yml"
    local OLD_PUBLIC_PORT

    [ ! -f "$COMPOSE_FILE" ] && { erro "docker-compose.yml não encontrado em $BASE_DIR"; return; }
    [ ! -f "$GO2RTC_FILE" ] && { warn "go2rtc.yml não encontrado."; return; }

    OLD_PUBLIC_PORT=$(grep -oP '(?<=Porta publicada no Central: )\d+' "$GO2RTC_FILE" 2>/dev/null | head -1 || echo "8555")
    info "Configuração atual: porta ${OLD_PUBLIC_PORT}/TCP+UDP"
    read -p "  Remover configuração do go2rtc? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    local COMPOSE_BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    local GO2RTC_BACKUP="${GO2RTC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$COMPOSE_FILE" "$COMPOSE_BACKUP"
    cp "$GO2RTC_FILE" "$GO2RTC_BACKUP"
    limpar_backups

    atualizar_compose_go2rtc "$COMPOSE_FILE" "$OLD_PUBLIC_PORT" "0" "$OLD_PUBLIC_PORT"
    rm -f "$GO2RTC_FILE"

    aplicar_stack_com_rollback "$COMPOSE_FILE" "$COMPOSE_BACKUP" "$GO2RTC_FILE" "$GO2RTC_BACKUP" "remover a configuração do go2rtc" || return
    ok "Configuração do go2rtc removida."
    verificar_logs_recentes 15
}

gerenciar_go2rtc() {
    header "🎥 GERENCIAR GO2RTC / WEBRTC"
    local GO2RTC_FILE="/root/traefik-central/dynamic-config/go2rtc.yml"

    if [ -f "$GO2RTC_FILE" ]; then
        info "go2rtc já configurado neste Central."
        echo -e "  ${CYAN}1)${NC} Atualizar configuração"
        echo -e "  ${CYAN}2)${NC} Remover configuração"
        echo -e "  ${CYAN}0)${NC} Voltar\n"
        read -p "Escolha: " OP_GO2RTC < /dev/tty
        case "$OP_GO2RTC" in
            1) configurar_go2rtc_existente ;;
            2) remover_go2rtc_existente ;;
            0) return ;;
            *) erro "Inválido." ;;
        esac
    else
        info "go2rtc ainda não está configurado neste Central."
        echo -e "  ${CYAN}1)${NC} Configurar agora"
        echo -e "  ${CYAN}0)${NC} Voltar\n"
        read -p "Escolha: " OP_GO2RTC < /dev/tty
        case "$OP_GO2RTC" in
            1) configurar_go2rtc_existente ;;
            0) return ;;
            *) erro "Inválido." ;;
        esac
    fi
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
        done < <(grep -oP "(?<=Host\(\`)([^\`]+)(?=\`\))" "$SERVERS_FILE" 2>/dev/null || true)
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
    [ "$PADRAO" -gt 0 ]    && warn "Certificado padrão: $PADRAO — acesse o domínio no browser para Let's Encrypt gerar o certificado"
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
    echo -e "${WHITE}O Central gera certificados e conecta aos destinos via HTTPS.${NC}\n"

    ROUTERS_HTTPS_CONFIG=""
    SERVICES_HTTPS_CONFIG=""
    SERVER_COUNT=0
    SERVERS_SUMMARY=""

    while true; do
        SERVER_COUNT=$((SERVER_COUNT + 1))
        echo -e "${BLUE}  --- Servidor $SERVER_COUNT ---${NC}"

        read -p "  Nome (ex: srv-riquest) [vazio para parar]: " SERVER_NAME < /dev/tty
        if [ -z "$SERVER_NAME" ]; then SERVER_COUNT=$((SERVER_COUNT - 1)); break; fi
        [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { erro "Nome inválido."; SERVER_COUNT=$((SERVER_COUNT - 1)); continue; }

        while true; do
            read -p "  IP (ex: 192.168.25.100): " SERVER_IP < /dev/tty
            [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
            erro "IP inválido."
        done

        read -p "  Porta HTTPS do destino [443]: " SERVER_PORT < /dev/tty
        SERVER_PORT="${SERVER_PORT:-443}"

        ALL_DOMAINS=()
        while true; do
            while true; do
                read -p "  Domínio base (ex: empresa.com.br): " BASE_DOMAIN < /dev/tty
                BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                [[ "$BASE_DOMAIN" =~ \. ]] && break
                erro "Inválido."
            done
            echo -e "  ${CYAN}Subdomínios para .${BASE_DOMAIN} (ex: painel n8n api):${NC}"
            while true; do
                read -p "  Subdomínios (separados por espaço): " SUBS_INPUT < /dev/tty
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

        RULE=""
        for dom in "${ALL_DOMAINS[@]}"; do
            [ -n "$RULE" ] && RULE="${RULE} || "
            RULE="${RULE}Host(\`${dom}\`)"
        done

        ROUTERS_HTTPS_CONFIG="${ROUTERS_HTTPS_CONFIG}
    ${SERVER_NAME}:
      rule: \"${RULE}\"
      entryPoints:
        - websecure
      service: ${SERVER_NAME}-svc
      tls:
        certResolver: letsencrypt
"
        SERVICES_HTTPS_CONFIG="${SERVICES_HTTPS_CONFIG}
    ${SERVER_NAME}-svc:
      loadBalancer:
        passHostHeader: true
        serversTransport: insecure@file
        servers:
          - url: \"https://${SERVER_IP}:${SERVER_PORT}\"
"
        DOMS_STR=$(printf '%s, ' "${ALL_DOMAINS[@]}" | sed 's/, $//')
        ok "Servidor '${SERVER_NAME}': ${#ALL_DOMAINS[@]} domínio(s) → ${SERVER_IP}:${SERVER_PORT}"
        SERVERS_SUMMARY="${SERVERS_SUMMARY}\n  • ${SERVER_NAME}: ${DOMS_STR} → ${SERVER_IP}:${SERVER_PORT}"

        read -p "  Outro servidor? (s/N): " CONTINUE < /dev/tty
        [[ "$CONTINUE" =~ ^[Ss]$ ]] || break
    done

    separador
    echo -e "\n${YELLOW}🎥 GO2RTC / WEBRTC${NC}"
    echo -e "${WHITE}Opcional: publica a porta dedicada 8555 em TCP+UDP no Central.${NC}\n"

    GO2RTC_ENABLED=0
    GO2RTC_PUBLIC_PORT=8555
    GO2RTC_TARGET_PORT=8555
    GO2RTC_IP=""

    read -p "  Configurar go2rtc/WebRTC? (s/N): " ENABLE_GO2RTC < /dev/tty
    if [[ "$ENABLE_GO2RTC" =~ ^[Ss]$ ]]; then
        coletar_detalhes_go2rtc || true
    fi
}

# ============================================================================
# CRIAR ARQUIVOS
# ============================================================================
criar_arquivos() {
    header "📝 CRIANDO ARQUIVOS"

    BASE_DIR="/root/traefik-central"
    mkdir -p "$BASE_DIR/dynamic-config"

    local GO2RTC_ENTRYPOINTS=""
    local GO2RTC_PORTS=""
    if [ "${GO2RTC_ENABLED:-0}" = "1" ]; then
        GO2RTC_ENTRYPOINTS=$(cat <<EOF
      # BEGIN GO2RTC ENTRYPOINTS
      - "--entrypoints.go2rtc-tcp.address=:${GO2RTC_PUBLIC_PORT}/tcp"
      - "--entrypoints.go2rtc-udp.address=:${GO2RTC_PUBLIC_PORT}/udp"
      # END GO2RTC ENTRYPOINTS
EOF
)
        GO2RTC_PORTS=$(cat <<EOF
      # BEGIN GO2RTC PORTS
      - target: ${GO2RTC_PUBLIC_PORT}
        published: ${GO2RTC_PUBLIC_PORT}
        protocol: tcp
        mode: host
      - target: ${GO2RTC_PUBLIC_PORT}
        published: ${GO2RTC_PUBLIC_PORT}
        protocol: udp
        mode: host
      # END GO2RTC PORTS
EOF
)
    fi

    cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.8"
services:
  traefik-central:
    image: traefik:v3.3
    command:
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.dashboard.address=:8080"
${GO2RTC_ENTRYPOINTS}
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
${GO2RTC_PORTS}
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
# ROTEAMENTO - TRAEFIK CENTRAL (TLS TERMINATION)
# ============================================================================
# O Central gerencia todos os certificados Let's Encrypt.
# Tráfego para destino via HTTPS (insecureSkipVerify).
# ⚠️ Use o menu opção 5 para gerenciar servidores.
# ============================================================================

http:
  serversTransports:
    insecure:
      insecureSkipVerify: true
  routers:
${ROUTERS_HTTPS_CONFIG}
  services:
${SERVICES_HTTPS_CONFIG}
EOF
    else
        echo "# Use o menu opção 5 para adicionar servidores." > "$BASE_DIR/dynamic-config/servers.yml"
    fi
    ok "servers.yml"

    if [ "${GO2RTC_ENABLED:-0}" = "1" ]; then
        escrever_go2rtc_yml "$BASE_DIR"
        ok "go2rtc.yml"
    else
        rm -f "$BASE_DIR/dynamic-config/go2rtc.yml"
    fi

    info "Arquivos em: $BASE_DIR"
}

# ============================================================================
# SCRIPTS PYTHON AUXILIARES
# ============================================================================
criar_script_auxiliar() {
    cat > /tmp/traefik_add.py << 'PYADD'
import sys, re

filepath, name, ip, port, rule = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

router = f"\n    {name}:\n      rule: \"{rule}\"\n      entryPoints:\n        - websecure\n      service: {name}-svc\n      tls:\n        certResolver: letsencrypt\n"
service = f"\n    {name}-svc:\n      loadBalancer:\n        passHostHeader: true\n        serversTransport: insecure@file\n        servers:\n          - url: \"https://{ip}:{port}\"\n"

with open(filepath, "r") as f:
    content = f.read()

has_http = bool(re.search(r"^http:", content, re.MULTILINE))

if not has_http:
    new_content = (
        "# ROTEAMENTO - TRAEFIK CENTRAL (TLS TERMINATION)\n\n"
        "http:\n  serversTransports:\n    insecure:\n      insecureSkipVerify: true\n  routers:\n" + router + "\n  services:\n" + service + "\n"
    )
    with open(filepath, "w") as f:
        f.write(new_content)
else:
    content = re.sub(r"(  routers:)(.*?)(  services:)", lambda m: f"{m.group(1)}{m.group(2)}{router}{m.group(3)}", content, count=1, flags=re.DOTALL)
    content = content.rstrip() + "\n" + service
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
    if re.match(rf"^    {re.escape(name)}(-svc)?:\s*$", line):
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

    # Regenera tls.domains (1 cert por dominio) de todos os routers com
    # certResolver: letsencrypt, usando os dominios da propria rule.
    # Isso da a "fila" de emissoes independentes (um dominio problematico
    # nao bloqueia os demais, ex.: atras de Cloudflare).
    cat > /tmp/traefik_sync_domains.py << 'PYDOMAINS'
import sys, re
f = sys.argv[1]
c = open(f).read()
block_re = re.compile(
    r"^    ([a-zA-Z0-9_-]+):\n(.*?)(?=^    [a-zA-Z0-9_-]+:|^  services:|\Z)",
    re.MULTILINE | re.DOTALL,
)
def fix(m):
    name, block = m.group(1), m.group(2)
    if "      rule:" not in block or "certResolver: letsencrypt" not in block:
        return m.group(0)
    mrule = re.search(r'      rule: "([^"]*)"', block)
    if not mrule:
        return m.group(0)
    doms = re.findall(r"Host\(`([^`]+)`\)", mrule.group(1))
    if not doms:
        return m.group(0)
    new_domains = "        domains:\n" + "".join(f"          - main: {d}\n" for d in doms)
    marker = "        certResolver: letsencrypt\n"
    idx = block.find(marker)
    if idx < 0:
        return m.group(0)
    prefix = block[: idx + len(marker)]
    return f"    {name}:\n" + prefix + new_domains
out = block_re.sub(fix, c)
out = re.sub(r"(\n  services:)", r"\n\1", out, count=1)
open(f, "w").write(out)
print("tls.domains atualizado")
PYDOMAINS
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
    if [ "${GO2RTC_ENABLED:-0}" = "1" ]; then
        ss -tlnp | grep -q ":${GO2RTC_PUBLIC_PORT} " && ok "Porta ${GO2RTC_PUBLIC_PORT}/TCP: ok" || warn "Porta ${GO2RTC_PUBLIC_PORT}/TCP: aguarde"
        ss -ulnp | grep -q ":${GO2RTC_PUBLIC_PORT} " && ok "Porta ${GO2RTC_PUBLIC_PORT}/UDP: ok" || warn "Porta ${GO2RTC_PUBLIC_PORT}/UDP: aguarde"
    fi
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
    echo -e "\n  ${GREEN}✅ Certificados Let's Encrypt gerenciados pelo Central${NC}"
    echo -e "  ${WHITE}Os servidores destino NÃO precisam de nenhuma configuração SSL.${NC}"
    echo -e "  ${WHITE}Use a opção 7 para verificar o status dos certificados.${NC}"
    if [ "${GO2RTC_ENABLED:-0}" = "1" ]; then
        echo -e "  ${WHITE}go2rtc/WebRTC:${NC} porta ${GO2RTC_PUBLIC_PORT}/TCP+UDP → ${GO2RTC_IP}:${GO2RTC_TARGET_PORT}"
    fi
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
    criar_script_auxiliar
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml

    while true; do
        read -p "  Nome (ex: srv-riquest): " SERVER_NAME < /dev/tty
        [ -z "$SERVER_NAME" ] && { erro "Obrigatório."; continue; }
        [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { erro "Inválido."; continue; }
        grep -q "^    ${SERVER_NAME}:" "$SERVERS_FILE" 2>/dev/null && { erro "Já existe!"; continue; }
        break
    done

    while true; do
        read -p "  IP (ex: 192.168.25.100): " SERVER_IP < /dev/tty
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

    read -p "  Porta HTTPS do destino [443]: " SERVER_PORT < /dev/tty
    SERVER_PORT="${SERVER_PORT:-443}"

    ALL_DOMAINS=()
    echo -e "\n  ${WHITE}O Central gera os certificados. Informe todos os domínios deste servidor.${NC}\n"

    while true; do
        while true; do
            read -p "  Domínio base (ex: empresa.com.br): " BASE_DOMAIN < /dev/tty
            BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            [[ "$BASE_DOMAIN" =~ \. ]] && break
            erro "Inválido."
        done
        echo -e "  ${CYAN}Subdomínios para .${BASE_DOMAIN} (ex: painel n8n api):${NC}"
        while true; do
            read -p "  Subdomínios (separados por espaço): " SUBS_INPUT < /dev/tty
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

    RULE=""
    for dom in "${ALL_DOMAINS[@]}"; do
        [ -n "$RULE" ] && RULE="${RULE} || "
        RULE="${RULE}Host(\`${dom}\`)"
    done

    separador
    info "Servidor: $SERVER_NAME → $SERVER_IP:$SERVER_PORT"
    echo -e "  ${WHITE}Domínios (${#ALL_DOMAINS[@]}):${NC}"
    for dom in "${ALL_DOMAINS[@]}"; do echo -e "    ${CYAN}→${NC} $dom"; done

    read -p "  Confirmar? (s/N): " CONF < /dev/tty
    [[ "$CONF" =~ ^[Ss]$ ]] || { warn "Cancelado."; return; }

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    limpar_backups
    python3 /tmp/traefik_add.py "$SERVERS_FILE" "$SERVER_NAME" "$SERVER_IP" \
            "$SERVER_PORT" "$RULE"
        python3 /tmp/traefik_sync_domains.py "$SERVERS_FILE"

        ok "Servidor '${SERVER_NAME}' adicionado com ${#ALL_DOMAINS[@]} domínio(s)!"
    sincronizar_certificados
}

# ============================================================================
# SINCRONIZAR CERTIFICADOS (auto-refresh após mudanças)
# ============================================================================
sincronizar_certificados() {
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    local ACME_JSON="/etc/traefik/certificates/acme.json"
    local CONTAINER=$(docker ps -q --filter "name=traefik-central" 2>/dev/null | head -1)

    [ -z "$CONTAINER" ] && { warn "Container não encontrado."; return; }

    step "Verificando certificados vs domínios..."

    python3 - "$SERVERS_FILE" "$CONTAINER" << 'PYSYNC'
import sys, subprocess, json, re

servers_file = sys.argv[1]
container = sys.argv[2]

# Extrair domínios por router do servers.yml
with open(servers_file) as f:
    content = f.read()

routers = {}
for match in re.finditer(r'    (\S+):\n      rule: "([^"]+)"', content):
    name = match.group(1)
    if name.endswith('-svc') or name == 'insecure':
        continue
    domains = re.findall(r'Host\(`([^`]+)`\)', match.group(2))
    if domains:
        routers[name] = sorted(domains)

if not routers:
    print("  Nenhum router encontrado."); sys.exit(0)

# Ler acme.json do container
try:
    result = subprocess.run(
        ['docker', 'exec', container, 'cat', '/etc/traefik/certificates/acme.json'],
        capture_output=True, text=True, timeout=10
    )
    acme = json.loads(result.stdout)
    certs = acme.get('letsencrypt', {}).get('Certificates', [])
except:
    print("  ⚠ Não foi possível ler acme.json"); sys.exit(0)

# Comparar domínios
needs_refresh = []
for router_name, router_doms in routers.items():
    main_dom = router_doms[0]
    found_cert = None
    for c in certs:
        if c.get('domain', {}).get('main') == main_dom:
            found_cert = c
            break
        sans = c.get('domain', {}).get('sans', [])
        if main_dom in sans:
            found_cert = c
            break

    if not found_cert:
        print(f"  ⚠ {router_name}: sem certificado → será gerado automaticamente")
        continue

    cert_doms = [found_cert['domain']['main']] + found_cert['domain'].get('sans', [])
    cert_doms_set = set(cert_doms)
    router_doms_set = set(router_doms)

    if router_doms_set != cert_doms_set:
        missing = router_doms_set - cert_doms_set
        extra = cert_doms_set - router_doms_set
        if missing:
            print(f"  ⚠ {router_name}: {len(missing)} domínio(s) novo(s) sem cert: {', '.join(missing)}")
        needs_refresh.append(found_cert['domain']['main'])
    else:
        print(f"  ✅ {router_name}: {len(router_doms)} domínio(s) — certificado OK")

# Remover certs desatualizados para forçar re-emissão
if needs_refresh:
    acme['letsencrypt']['Certificates'] = [
        c for c in certs if c['domain']['main'] not in needs_refresh
    ]
    # Escrever de volta
    new_json = json.dumps(acme, indent=2)
    subprocess.run(
        ['docker', 'exec', '-i', container, 'sh', '-c',
         f"cat > {'/etc/traefik/certificates/acme.json'}"],
        input=new_json, text=True, timeout=10
    )
    print(f"\n  🔄 {len(needs_refresh)} certificado(s) removido(s) — Traefik vai re-emitir com todos os domínios")
    print("  ⏳ Aguardando 15s para re-emissão...")
else:
    print("\n  ✅ Todos os certificados estão sincronizados!")
PYSYNC

    # Se houve mudança, forçar restart e aguardar
    if docker exec "$CONTAINER" cat "$ACME_JSON" 2>/dev/null | python3 -c "
import sys, json
d=json.load(sys.stdin)
c=d.get('letsencrypt',{}).get('Certificates',[])
sys.exit(0 if len(c) == len(open('$SERVERS_FILE').read().split('certResolver')) - 1 else 1)
" 2>/dev/null; then
        : # OK
    else
        docker service update --force traefik-central_traefik-central >/dev/null 2>&1 &
        sleep 15
        # Verificar resultado
        LOGS=$(docker service logs traefik-central_traefik-central --tail 10 2>/dev/null || true)
        echo "$LOGS" | grep -q "Unable to obtain" && {
            erro "Erro ao obter certificado. Verifique DNS dos domínios."
            echo "$LOGS" | grep "Unable to obtain" | grep -oP "NXDOMAIN[^;]+" | head -3
        } || ok "Certificados atualizados!"
    fi
}

# ============================================================================
# SELECIONAR SERVIDOR
# ============================================================================
selecionar_servidor() {
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    ROUTERS=$(grep -E "^    [a-zA-Z0-9_-]+:$" "$SERVERS_FILE" 2>/dev/null | \
        grep -v "\-svc:" | grep -v "^    insecure:" | \
        sed 's/://g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    [ -z "$ROUTERS" ] && { warn "Nenhum servidor."; SERVER_NAME_SEL=""; return 1; }

    mapfile -t SRV_ARRAY <<< "$ROUTERS"
    echo -e "\n  ${YELLOW}${1:-Selecione:}${NC}\n"
    local i=1
    for srv in "${SRV_ARRAY[@]}"; do
        srv=$(echo "$srv" | tr -d ' ')
        RULE=$(grep -A1 "^    ${srv}:" "$SERVERS_FILE" | grep "rule:" | \
            sed -E 's/Host\(`//g; s/`\)//g; s/ \|\| /, /g; s/rule: "//g; s/"$//g' | xargs || echo "?")
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
    SERVER_NAME_SEL=$(echo "${SRV_ARRAY[$((SEL-1))]}" | tr -d ' ')
    ok "Selecionado: $SERVER_NAME_SEL"
}

# ============================================================================
# ADICIONAR DOMÍNIO
# ============================================================================
adicionar_dominio() {
    header "🌐 ADICIONAR DOMÍNIO"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml
    criar_script_auxiliar
    selecionar_servidor "Qual servidor?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    SERVER_NAME=$(echo "$SERVER_NAME_SEL" | tr -d ' ')
    RULE_LINE=$(grep -A1 "^    ${SERVER_NAME}:" "$SERVERS_FILE" | grep "rule:" || echo "")
    mapfile -t EXISTING_DOMS < <(
        echo "$RULE_LINE" | grep -oP "(?<=Host\(\`)([^\`]+)(?=\`\))" || true)

    if [ ${#EXISTING_DOMS[@]} -eq 0 ]; then
        warn "Não foi possível extrair domínios de '${SERVER_NAME}'. Verifique o servers.yml."
        return
    fi

    echo -e "\n  ${WHITE}Domínios atuais de '${SERVER_NAME}':${NC}"
    for d in "${EXISTING_DOMS[@]}"; do info "  $d"; done
    echo

    # Extrair domínios base únicos (tudo após o primeiro segmento)
    mapfile -t BASE_ARRAY < <(
        printf "%s\n" "${EXISTING_DOMS[@]}" | python3 -c "
import sys
bases = set()
for line in sys.stdin:
    parts = line.strip().split('.')
    if len(parts) >= 2:
        bases.add('.'.join(parts[1:]))
for b in sorted(bases): print(b)
" || true)

    if [ ${#BASE_ARRAY[@]} -eq 0 ]; then
        warn "Não foi possível extrair domínios base."
        return
    fi

    echo -e "  ${YELLOW}Selecione o domínio base para os novos subdomínios:${NC}\n"
    local i=1
    for base in "${BASE_ARRAY[@]}"; do
        echo -e "  ${CYAN}${i})${NC} ${WHITE}.${base}${NC}"
        i=$((i+1))
    done
    echo -e "  ${CYAN}${i})${NC} Outro domínio base (digitar manualmente)\n"

    while true; do
        read -p "  Base [1-${i}]: " SEL_BASE < /dev/tty
        [[ "$SEL_BASE" =~ ^[0-9]+$ ]] && [ "$SEL_BASE" -ge 1 ] && [ "$SEL_BASE" -le "$i" ] && break
        erro "Inválido."
    done

    NEW_DOMAINS_LIST=()
    if [ "$SEL_BASE" -eq "$i" ]; then
        while true; do
            read -p "  Dominio base (ex: outrodominio.com.br): " NEW_BASE < /dev/tty
            NEW_BASE=$(echo "$NEW_BASE" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            [[ "$NEW_BASE" =~ \. ]] && break
            erro "Dominio invalido."
        done
        echo -e "  ${CYAN}Subdominios para ${WHITE}.${NEW_BASE}${NC} ${BLUE}(separados por espaco):${NC}"
        echo -e "  ${WHITE}Ex: painel api n8n typebot${NC}"
        while true; do
            read -p "  Subdominios: " SUBS < /dev/tty
            [ -n "$SUBS" ] && break
            erro "Informe pelo menos um."
        done
        for sub in $SUBS; do
            NEW_DOMAINS_LIST+=("$(echo "$sub" | tr -d ' .').${NEW_BASE}")
        done
    else
        CHOSEN_BASE="${BASE_ARRAY[$((SEL_BASE-1))]}"
        echo -e "  ${CYAN}Subdominios para ${WHITE}.${CHOSEN_BASE}${NC} ${BLUE}(separados por espaco):${NC}"
        echo -e "  ${WHITE}Ex: painel api n8n typebot${NC}"
        while true; do
            read -p "  Subdominios: " SUBS < /dev/tty
            [ -n "$SUBS" ] && break
            erro "Informe pelo menos um."
        done
        for sub in $SUBS; do
            NEW_DOMAINS_LIST+=("$(echo "$sub" | tr -d ' .').${CHOSEN_BASE}")
        done
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

    RULE=""
    for dom in "${ALL_FINAL[@]}"; do
        [ -n "$RULE" ] && RULE="${RULE} || "
        RULE="${RULE}Host(\`${dom}\`)"
    done

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    limpar_backups
    python3 - "$SERVERS_FILE" "$SERVER_NAME" "$RULE" << 'PY'
import sys, re
f, s, r = sys.argv[1], sys.argv[2], sys.argv[3]
c = open(f).read()
c = re.sub(rf'(    {re.escape(s)}:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{r}"', c)
open(f, 'w').write(c); print("OK")
PY
    python3 /tmp/traefik_sync_domains.py "$SERVERS_FILE"
    ok "Domínios adicionados!"; sincronizar_certificados
}

# ============================================================================
# REMOVER DOMÍNIO
# ============================================================================
remover_dominio() {
    header "🗑️ REMOVER DOMÍNIO"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml
    criar_script_auxiliar
    selecionar_servidor "Servidor?" || return
    SERVER_NAME="$SERVER_NAME_SEL"

    mapfile -t DOM_ARRAY < <(
        grep -A1 "^    ${SERVER_NAME}:" "$SERVERS_FILE" | \
        grep -oP "(?<=Host\(\`)([^\`]+)(?=\`\))" || true)

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

    NEW_HOST=""
    for dom in "${DOM_ARRAY[@]}"; do
        [ "$dom" = "$DOM_R" ] && continue
        [ -n "$NEW_HOST" ] && NEW_HOST="${NEW_HOST} || "
        NEW_HOST="${NEW_HOST}Host(\`${dom}\`)"
    done

    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    limpar_backups
    python3 - "$SERVERS_FILE" "$SERVER_NAME" "$NEW_HOST" << 'PY'
import sys, re
f, s, nh = sys.argv[1], sys.argv[2], sys.argv[3]
c = open(f).read()
c = re.sub(rf'(    {re.escape(s)}:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{nh}"', c)
open(f, 'w').write(c); print("OK")
PY
    python3 /tmp/traefik_sync_domains.py "$SERVERS_FILE"
    ok "'$DOM_R' removido!"; sincronizar_certificados
}

# ============================================================================
# REMOVER SERVIDOR
# ============================================================================
remover_servidor() {
    header "➖ REMOVER SERVIDOR"
    criar_script_auxiliar
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    garantir_servers_yml
    selecionar_servidor "Remover qual?" || return
    SERVER_NAME="$SERVER_NAME_SEL"
    read -p "  Digite 'sim': " C < /dev/tty
    [ "$C" != "sim" ] && { warn "Cancelado."; return; }
    cp "$SERVERS_FILE" "${SERVERS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    limpar_backups
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

    mapfile -t SRV_NAMES < <(grep -E "^    [a-zA-Z0-9_-]+:$" "$SERVERS_FILE" 2>/dev/null | \
        grep -v "\-svc:" | grep -v "^    insecure:" | \
        sed 's/://g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)

    if [ ${#SRV_NAMES[@]} -gt 0 ]; then
        for r in "${SRV_NAMES[@]}"; do
            r=$(echo "$r" | tr -d ' ')
            URL=$(grep -A3 "^    ${r}-svc:" "$SERVERS_FILE" | grep "url:" | \
                grep -oP '(?<=url: ")[^"]+' || echo "?")
            RULE_LINE=$(grep -A1 "^    ${r}:" "$SERVERS_FILE" | grep "rule:" || echo "")
            DOMS=$(echo "$RULE_LINE" | grep -oP '(?<=Host\(`)([^`]+)(?=`\))' | tr '\n' ',' | sed 's/,$//' || echo "?")
            COUNT=$(echo "$RULE_LINE" | grep -oP '(?<=Host\(`)([^`]+)(?=`\))' | wc -l || echo 0)
            echo -e "  ${GREEN}✔ ${r}${NC}"
            info "  Destino: $URL"
            info "  Domínios ($COUNT): $DOMS"
            info "  TLS: certResolver=letsencrypt (Central)"
            echo
        done
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
    echo -e "  ${CYAN}5)${NC} Configurar go2rtc / WebRTC"
    echo -e "  ${CYAN}0)${NC} Voltar\n"
    read -p "Escolha: " OPCAO_SERV < /dev/tty
    case "$OPCAO_SERV" in
        1) criar_script_auxiliar; adicionar_servidor ;;
        2) adicionar_dominio ;;
        3) remover_dominio ;;
        4) criar_script_auxiliar; remover_servidor ;;
        5) gerenciar_go2rtc ;;
        0) return ;;
        *) erro "Inválido." ;;
    esac
}

# ============================================================================
# DIAGNÓSTICO E CORREÇÃO AUTOMÁTICA (opção 8)
# ============================================================================
diagnosticar_e_corrigir() {
    header "🔧 DIAGNÓSTICO E CORREÇÃO AUTOMÁTICA"
    local SERVERS_FILE="/root/traefik-central/dynamic-config/servers.yml"
    [ ! -f "$SERVERS_FILE" ] && { warn "servers.yml não encontrado."; return; }

    step "1️⃣  Verificando DNS de todos os domínios..."
    echo

    # Fase 1: Diagnóstico DNS via Python
    PY_OUT=$(python3 << 'PYCHECK'
import os, re, socket, json

servers_file = "/root/traefik-central/dynamic-config/servers.yml"

with open(servers_file) as f:
    content = f.read()

routers = {}
for match in re.finditer(r'    (\S+):\n      rule: "([^\"]+)"', content):
    name = match.group(1)
    if name.endswith('-svc') or name in ('insecure',):
        continue
    domains = re.findall(r'Host\(`([^`]+)`\)', match.group(2))
    if domains:
        routers[name] = sorted(set(domains))

if not routers:
    print("ERRO:Nenhum router encontrado.")
    exit(1)

results = []
all_ok = True
for rname in sorted(routers.keys()):
    for dom in routers[rname]:
        try:
            socket.getaddrinfo(dom, 80, socket.AF_INET)
            results.append(f"OK:{rname}:{dom}")
        except socket.gaierror:
            results.append(f"NOK:{rname}:{dom}")
            all_ok = False

if all_ok:
    print("ALL_OK")
else:
    for r in results:
        print(r)
    # Lista de remoções (última seção para o bash parsear)
    print("---PROBLEMAS---")
    for rname in sorted(routers.keys()):
        bad = [d for d in routers[rname] if any(
            r.startswith(f"NOK:{rname}:{d}") for r in results
        )]
        if bad:
            remaining = [d for d in routers[rname] if d not in bad]
            if remaining:
                new_rule = " || ".join(f"Host(`{d}`)" for d in remaining)
                print(f"FIX:{rname}:{new_rule}")
                for d in bad:
                    print(f"REM:{rname}:{d}")
            else:
                print(f"SKIP:{rname}:router ficaria vazio")
PYCHECK
)
    PY_EXIT=$?

    if [ "$PY_EXIT" -ne 0 ]; then
        erro "Erro no diagnóstico: $(echo \"$PY_OUT\" | head -1)"
        return
    fi

    if echo "$PY_OUT" | grep -q "^ALL_OK"; then
        ok "Todos os domínios têm DNS válido! Nada a corrigir."
        step "2️⃣  Verificando certificados expirados no acme.json..."
        # Também verificar certs expirados
        sincronizar_certificados
        return
    fi

    # Mostrar problemas encontrados
    echo -e "\n  ${YELLOW}Domínios com problema de DNS (NXDOMAIN):${NC}\n"
    PROBLEMAS=()
    while IFS= read -r line; do
        [[ "$line" == ---* ]] && break
        if [[ "$line" == NOK:* ]]; then
            ROUTER=$(echo "$line" | cut -d: -f2)
            DOM=$(echo "$line" | cut -d: -f3)
            echo -e "  ${RED}✖${NC} ${WHITE}${DOM}${NC} → ${YELLOW}sem DNS (NXDOMAIN)${NC} ${CYAN}[router: ${ROUTER}]${NC}"
            PROBLEMAS+=("$DOM")
        fi
    done <<< "$PY_OUT"

    echo -e "\n  ${#PROBLEMAS[@]} domínio(s) com DNS inválido encontrado(s)."
    echo -e "  ${WHITE}O Let's Encrypt NÃO consegue emitir certificados para domínios sem DNS,${NC}"
    echo -e "  ${WHITE}e isso BLOQUEIA a renovação de TODOS os domínios do mesmo router.${NC}"

    echo
    read -p "  🔧 Remover automaticamente os domínios sem DNS? (s/N): " CONFIRM < /dev/tty
    [[ ! "$CONFIRM" =~ ^[Ss]$ ]] && { warn "Cancelado."; return; }

    # Fase 2: Aplicar correções
    step "2️⃣  Aplicando correções..."
    local BACKUP_FILE="${SERVERS_FILE}.bak.diag.$(date +%Y%m%d_%H%M%S)"
    cp "$SERVERS_FILE" "$BACKUP_FILE"
    ok "Backup: $BACKUP_FILE"
    limpar_backups

    # Aplicar remoções
    while IFS= read -r line; do
        [[ "$line" == ---* ]] && break
        if [[ "$line" == FIX:* ]]; then
            ROUTER=$(echo "$line" | cut -d: -f2)
            NEW_RULE=$(echo "$line" | cut -d: -f3-)
            ok "Router '$ROUTER': atualizando regra..."
            python3 - "$SERVERS_FILE" "$ROUTER" "$NEW_RULE" << 'PYFIX'
import sys, re
f, r, nr = sys.argv[1], sys.argv[2], sys.argv[3]
c = open(f).read()
c = re.sub(rf'(    {re.escape(r)}:\n      rule: )"[^"]*"', lambda m: f'{m.group(1)}"{nr}"', c)
open(f, 'w').write(c)
print("OK")
PYFIX
        fi
    done <<< "$PY_OUT"

    # Mostrar o que foi removido
    echo
    while IFS= read -r line; do
        [[ "$line" == REM:* ]] && {
            DOM=$(echo "$line" | cut -d: -f3)
            warn "  ✗ $DOM removido"
        }
    done <<< "$PY_OUT"

    echo
    step "3️⃣  Sincronizando certificados..."
    sincronizar_certificados

    echo -e "\n${GREEN}✅ Diagnóstico e correção concluídos!${NC}"
    info "Execute a opção 7 novamente para verificar o status dos certificados."
}

# ============================================================================
# MENU PRINCIPAL
# ============================================================================
menu_principal() {
    clear
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${GREEN}${BOLD}     🚀 TRAEFIK CENTRAL — TLS TERMINATION${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${CYAN}  Certificados Let's Encrypt gerenciados pelo Central${NC}"
    echo -e "${WHITE}  Servidores destino recebem apenas HTTP (sem alterações)${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}\n"
    echo -e "  ${CYAN}1)${NC} ${WHITE}Instalar Traefik Central${NC}"
    echo -e "  ${CYAN}2)${NC} ${WHITE}Diagnóstico do sistema${NC}"
    echo -e "  ${CYAN}3)${NC} ${WHITE}Verificar Traefik(s) instalados${NC}"
    echo -e "  ${CYAN}4)${NC} ${RED}Remover Traefik instalado${NC}"
    echo -e "  ${CYAN}5)${NC} ${GREEN}Gerenciar servidores/domínios${NC}"
    echo -e "  ${CYAN}6)${NC} ${WHITE}Listar servidores configurados${NC}"
    echo -e "  ${CYAN}7)${NC} ${CYAN}🔐 Verificar status dos certificados SSL${NC}"
    echo -e "  ${CYAN}8)${NC} ${GREEN}🔧 Diagnosticar e corrigir certificados${NC}"
    echo -e "  ${CYAN}9)${NC} ${YELLOW}🧹 Limpar backups antigos (manter 5)${NC}"
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
        2)
            diagnostico_sistema
            echo -e "\n  ${CYAN}1)${NC} Ver logs  ${CYAN}0)${NC} Voltar"
            read -p "Escolha: " OPT_LOG < /dev/tty
            [ "$OPT_LOG" = "1" ] && { verificar_logs_recentes 50; }
            pausar
            ;;
        3) verificar_traefik_existente; pausar ;;
        4) verificar_traefik_existente; menu_remocao; pausar ;;
        5) criar_script_auxiliar; menu_gerenciar_servidores; pausar ;;
        6) listar_servidores; pausar ;;
        7) verificar_certificados; pausar ;;
        8) diagnosticar_e_corrigir; pausar ;;
        9) limpar_backups; pausar ;;
        0) echo -e "\n${GREEN}Até mais!${NC}\n"; exit 0 ;;
        *) erro "Inválido."; sleep 2 ;;
    esac
done
