# 🚀 Traefik Central — TLS Termination

Gerenciador completo para deploy do **Traefik Central** — um gateway HTTPS que termina TLS e gerencia certificados Let's Encrypt para todos os seus servidores, sem necessidade de configuração SSL nos destinos.

## Arquitetura

```
INTERNET → MIKROTIK/FIREWALL → TRAEFIK CENTRAL
                                     │
                    ┌────────────────┤
                    │                │
                porta 80         porta 443
             redirect HTTPS    TLS Termination
                    │          + Let's Encrypt
                    └──→ HTTPS ──┤
                                 ├── HTTP → Servidor A (:80)
                                 ├── HTTP → Servidor B (:80)
                                 └── HTTP → Servidor N (:80)
```

| Porta | Função |
|-------|--------|
| **80** | Redirect automático para HTTPS |
| **443** | TLS Termination + proxy HTTP para servidores destino |
| **8080** | Dashboard com autenticação BasicAuth |

> **Os servidores destino NÃO precisam de SSL/TLS.** O Central gerencia todos os certificados.

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
| **7** | 🔐 Verificar status dos certificados SSL |

## Fluxo de Uso

### 1. Instalar o Central

Execute o script e escolha a **opção 1**. O instalador pedirá:

- **Domínio do dashboard** (ex: `traefik-central.seudominio.com`)
- **Email** para Let's Encrypt
- **Usuário e senha** para o painel
- **Servidores de destino** com seus domínios

### 2. Gerenciar Servidores (opção 5)

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
Porta HTTP: 80
Domínio base: eclicksolucoes.com.br
Subdomínios: painel n8n typebot unichat
```

Resultado: 4 domínios com certificados Let's Encrypt gerenciados pelo Central.

### 3. Verificar Certificados (opção 7)

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
    └── servers.yml              # Roteadores HTTPS com certResolver
```

## Comandos Úteis

```bash
# Logs em tempo real
docker service logs traefik-central_traefik-central -f

# Status da stack
docker stack ps traefik-central

# Verificar certificado de um domínio
openssl s_client -connect dominio.com:443 -servername dominio.com </dev/null 2>/dev/null | grep issuer

# Remover tudo
docker stack rm traefik-central
```

## Licença

MIT
