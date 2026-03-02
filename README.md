# 🚀 Traefik Central — TLS Termination

Gerenciador completo para deploy do **Traefik Central** — um gateway HTTPS que termina TLS, gerencia certificados Let's Encrypt e roteia tráfego para múltiplos servidores, **sem necessidade de configuração SSL nos destinos**.

## Arquitetura

```
                    ┌─────────────────────────────────────────────┐
                    │           TRAEFIK CENTRAL                   │
                    │                                             │
INTERNET ──→ MIKROTIK ──→ :80  → redirect HTTPS                  │
                    │    :443 → TLS Termination (Let's Encrypt)   │
                    │           ├── HTTPS → Servidor A (:443)     │
                    │           ├── HTTPS → Servidor B (:443)     │
                    │           └── HTTPS → Servidor N (:443)     │
                    │    :8080 → Dashboard (BasicAuth)            │
                    └─────────────────────────────────────────────┘
```

### Como funciona

| Etapa | Descrição |
|-------|-----------|
| 1. Cliente acessa `https://painel.empresa.com.br` | DNS aponta para IP público → Mikrotik redireciona para Traefik Central |
| 2. Traefik Central termina TLS | Usa certificado Let's Encrypt gerado automaticamente |
| 3. Central identifica o destino pela regra `Host()` | Cada domínio é roteado para o servidor correto |
| 4. Central envia tráfego via HTTPS para o destino | `insecureSkipVerify: true` ignora o cert interno do destino |
| 5. Servidor destino responde normalmente | Sem redirect loop, sem alterações necessárias |

### Portas

| Porta | Função |
|-------|--------|
| **80** | Redirect automático HTTP → HTTPS |
| **443** | TLS Termination + proxy HTTPS para destinos |
| **8080** | Dashboard Traefik com autenticação BasicAuth |

> **Os servidores destino NÃO precisam de alterações.** O Central gerencia todos os certificados.

## Instalação

```bash
curl -sSL https://raw.githubusercontent.com/alexbuzatto/instaladortraefikcentral/main/traefikcentral.sh | sudo bash
```

### Pré-requisitos

- Linux (Ubuntu/Debian recomendado)
- Acesso root
- Portas 80, 443 e 8080 livres
- Docker e Docker Swarm (instalados automaticamente se ausentes)
- **DNS** de todos os domínios apontando para o IP público do Central

## Menu Principal

| Opção | Função | Detalhes |
|-------|--------|----------|
| **1** | Instalar Traefik Central | Diagnóstico → Configuração → Deploy |
| **2** | Diagnóstico do sistema | RAM, disco, portas, Docker, Swarm |
| **3** | Verificar Traefik(s) instalados | Lista stacks e serviços Traefik |
| **4** | Remover Traefik instalado | Remove stack, volumes e configs |
| **5** | Gerenciar servidores/domínios | Adicionar/remover servidores e domínios |
| **6** | Listar servidores configurados | Mostra IPs, domínios e status dos certs |
| **7** | 🔐 Verificar certificados SSL | Status de cada certificado via openssl |

## Fluxo de Instalação (Opção 1)

1. **Diagnóstico** — verifica SO, RAM, disco, portas, Docker
2. **Configuração** — solicita:
   - Domínio do dashboard (ex: `traefik.empresa.com.br`)
   - Email para Let's Encrypt
   - Usuário e senha do painel
   - Servidores destino com IPs e domínios
3. **Deploy** — cria docker-compose, dynamic configs e faz `docker stack deploy`
4. **Verificação** — testa se o serviço subiu e gera resumo

## Gerenciamento de Servidores (Opção 5)

| Ação | Descrição |
|------|-----------|
| **Vincular servidor** | Adiciona IP + porta + domínios. Ex: `srv-riquest → 192.168.25.103:443` |
| **Adicionar domínio** | Adiciona subdomínios a servidor existente |
| **Remover domínio** | Remove subdomínio específico |
| **Remover servidor** | Remove servidor completo e todas as rotas |

### Exemplo de adição

```
Nome (ex: srv-riquest): eclick
IP (ex: 192.168.25.100): 192.168.25.102
Porta HTTPS do destino [443]: 443
Domínio base (ex: empresa.com.br): eclicksolucoes.com.br
Subdomínios (separados por espaço): painel n8n apievo
```

Resultado: 3 domínios com certificados Let's Encrypt gerenciados pelo Central.

### Auto-Refresh de Certificados 🔄

Após **cada alteração** (adicionar/remover servidor ou domínio), o script automaticamente:

1. Compara domínios do `servers.yml` com certificados do `acme.json`
2. Detecta domínios novos sem certificado
3. Remove o cert antigo e força re-emissão com todos os domínios
4. Aguarda 15s e verifica o resultado
5. Se falhar, mostra qual domínio não tem DNS

```
▶ Verificando certificados vs domínios...
  ✅ riquest: 3 domínio(s) — certificado OK
  ⚠ eclick: 2 domínio(s) novo(s) sem cert: webhook, unichat
  🔄 1 certificado(s) removido(s) — Traefik vai re-emitir
  ✔ Certificados atualizados!
```

## Arquivos Gerados

```
/root/traefik-central/
├── docker-compose.yml              # Stack do Traefik Central
└── dynamic-config/
    ├── dashboard.yml                # Roteador do painel (porta 8080)
    ├── middlewares.yml               # BasicAuth + Redirect /dashboard/
    └── servers.yml                   # Roteadores HTTPS com certResolver
```

### Estrutura do `servers.yml`

```yaml
http:
  serversTransports:
    insecure:
      insecureSkipVerify: true        # Ignora cert interno dos destinos

  routers:
    meu-servidor:
      rule: "Host(`app.empresa.com.br`) || Host(`api.empresa.com.br`)"
      entryPoints: [websecure]
      service: meu-servidor-svc
      tls:
        certResolver: letsencrypt     # Let's Encrypt automático

  services:
    meu-servidor-svc:
      loadBalancer:
        passHostHeader: true
        serversTransport: insecure@file
        servers:
          - url: "https://192.168.25.100:443"
```

## Verificar Certificados (Opção 7)

Verifica via `openssl` todos os domínios configurados:

| Status | Significado |
|--------|-------------|
| ✅ Válido por X dias | Certificado Let's Encrypt ativo |
| ⚠ Certificado padrão Traefik | Let's Encrypt ainda não emitiu (verificar DNS) |
| ⚠ Expirando em < 15 dias | Renovação automática pendente |
| ❌ Expirado ou sem resposta | Problema de DNS ou conectividade |

## Troubleshooting

### Certificado não gera para um domínio

```bash
# Verificar se o DNS aponta para o IP correto
dig +short dominio.com.br

# Ver erros do ACME
docker service logs traefik-central_traefik-central --tail 50 2>&1 | grep -i "acme\|unable"
```

**Causa comum:** O domínio não tem registro DNS A apontando para o IP público do Mikrotik/Central. Se **um** domínio de um router falhar, **todos** os domínios daquele router falham.

### Redirect loop (HTTP 308)

O Central conecta aos destinos via **HTTPS** com `insecureSkipVerify`. Se o destino estiver respondendo com redirect, verifique se a URL no service usa `https://` e porta `443`.

### Dashboard não acessível

O dashboard usa a porta **8080**. Verifique se o Mikrotik/firewall redireciona essa porta para o Central.

## Comandos Úteis

```bash
# Logs em tempo real
docker service logs traefik-central_traefik-central -f

# Status da stack
docker stack ps traefik-central

# Ver certificados armazenados
docker exec $(docker ps -q --filter "name=traefik-central") cat /etc/traefik/certificates/acme.json | python3 -m json.tool | grep main

# Forçar re-emissão de certificados
docker service update --force traefik-central_traefik-central

# Remover tudo
docker stack rm traefik-central
```

## Licença

MIT
