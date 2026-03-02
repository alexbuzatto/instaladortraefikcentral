# 🚀 Traefik Central — Instalador e Gerenciador

Gerenciador completo para deploy e administração do **Traefik Central** — um gateway inteligente que roteia tráfego HTTP e HTTPS para múltiplos servidores de destino, mantendo os certificados Let's Encrypt nos servidores locais.

## Arquitetura

```
INTERNET → MIKROTIK/FIREWALL → TRAEFIK CENTRAL
                                     │
                    ┌────────────────┤
                    │                │
                porta 80         porta 443
             HTTP Proxy       TCP Passthrough
          (Let's Encrypt)     (TLS inalterado)
                    │                │
              Servidor A       Servidor A
              Servidor B       Servidor B
              Servidor N       Servidor N
```

| Porta | Modo | Função |
|-------|------|--------|
| **80** | HTTP Proxy | Repassa requisições HTTP por `Host` header — essencial para renovação Let's Encrypt |
| **443** | TCP Passthrough | Repassa pacotes TLS por SNI sem decriptar — certificados ficam nos servidores |
| **8080** | Dashboard | Painel do Traefik Central com autenticação BasicAuth |

## Instalação Rápida

```bash
curl -sSL https://raw.githubusercontent.com/alexbuzatto/instaladortraefikcentral/main/traefikcentral.sh | sudo bash
```

Ou em dois passos:

```bash
curl -O https://raw.githubusercontent.com/alexbuzatto/instaladortraefikcentral/main/traefikcentral.sh
chmod +x traefikcentral.sh && sudo ./traefikcentral.sh
```

### Pré-requisitos

- Linux (Ubuntu/Debian recomendado)
- Acesso root
- Portas 80, 443 e 8080 livres
- Docker e Docker Swarm (instalados automaticamente se ausentes)

## Menu Principal

| Opção | Função |
|-------|--------|
| **1** | Instalar Traefik Central |
| **2** | Diagnóstico do sistema (RAM, disco, portas, Docker) |
| **3** | Verificar Traefik(s) instalados |
| **4** | Remover Traefik instalado |
| **5** | Gerenciar servidores e domínios |
| **6** | Listar servidores configurados |
| **7** | 🔧 Corrigir Traefik do servidor destino (`httpchallenge` → `tlschallenge`) |
| **8** | 🔐 Verificar status dos certificados SSL |

## Fluxo de Uso

### 1. Instalar o Central

Execute o script e escolha a **opção 1**. O instalador pedirá:

- **Domínio do dashboard** (ex: `traefik-central.seudominio.com`)
- **Email** para Let's Encrypt
- **Usuário e senha** para o painel
- **Servidores de destino** com seus domínios

### 2. Gerenciar Servidores (opção 5)

Submenu com 4 ações:

| Ação | Descrição |
|------|-----------|
| Vincular servidor | Adiciona IP + domínios de um novo servidor |
| Adicionar domínio | Adiciona subdomínios a servidor existente |
| Remover domínio | Remove subdomínio específico |
| Remover servidor | Remove servidor completo e todas as rotas |

**Exemplo de adição:**

```
Nome: srv1
IP: 192.168.25.102
Domínio base: eclicksolucoes.com.br
Subdomínios: painel n8n typebot unichat
```

Resultado: 4 domínios configurados com rotas TCP (443) e HTTP (80).

### 3. Corrigir Traefik do Servidor Destino (opção 7)

> Execute **no servidor destino**, não no Central.

Converte o Traefik local de `httpchallenge` para `tlschallenge` (TLS-ALPN-01), necessário quando o servidor está atrás do Traefik Central.

**O que faz:**
- Localiza o `traefik.yaml` automaticamente
- Faz backup com timestamp
- Troca `httpchallenge` → `tlschallenge`
- Remove redirect global `80→443` do entrypoint
- Pergunta antes de deletar `acme.json` (com aviso de rate limit)
- Redesploya a stack e monitora certificados por 60s

### 4. Verificar Certificados (opção 8)

Verifica via `openssl` todos os domínios configurados e mostra:

- ✅ Certificado válido (dias restantes)
- ⚠ Certificado padrão do Traefik (Let's Encrypt pendente)
- ⚠ Expirando em breve (< 15 dias)
- ❌ Expirado ou sem resposta

## Arquivos Gerados

```
/root/traefik-central/
├── docker-compose.yml          # Stack do Traefik Central
└── dynamic-config/
    ├── dashboard.yml            # Roteador do painel (porta 8080)
    ├── middlewares.yml           # BasicAuth + Redirect para /dashboard/
    └── servers.yml              # Roteadores TCP e HTTP dos servidores
```

## Comandos Úteis

```bash
# Logs em tempo real
docker service logs traefik-central_traefik-central -f

# Status da stack
docker stack ps traefik-central

# Listar serviços
docker service ls

# Verificar certificado de um domínio
openssl s_client -connect dominio.com:443 -servername dominio.com </dev/null 2>/dev/null | grep issuer

# Remover tudo
docker stack rm traefik-central
```

## Troubleshooting

| Problema | Causa | Solução |
|----------|-------|---------|
| Dashboard não pede senha | Middleware `basicauth` não encontrado | Reinstalar (opção 4 → 1) |
| `TRAEFIK DEFAULT CERT` nos sites | Let's Encrypt não emitiu certificados | Executar opção 7 no servidor destino |
| `mapping key already defined` | Chave YAML duplicada no `servers.yml` | Reinstalar (opção 4 → 1) — corrigido na v23+ |
| Certificados não renovam | `httpchallenge` não funciona atrás do Central | Opção 7 troca para `tlschallenge` |
| Cache do Chrome mostra erro SSL | Chrome memoriza falhas de certificado | Limpar em `chrome://net-internals/#hsts` |

## Licença

MIT
