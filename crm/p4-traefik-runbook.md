# Runbook — P4: corrigir `X-Forwarded-For` no Traefik

> Escrito em 20/07/2026, **antes** de qualquer mudança. Resolve `DECISOES.md`
> P4. **Blast radius máximo**: este Traefik atende TODOS os serviços da VPS —
> um restart derruba TODOS por alguns segundos, e um erro de config pode
> quebrar HTTPS/roteamento de tudo até ser corrigido. Etapa 2 (aplicar) só
> roda depois de aprovação explícita na sessão, seguindo este plano.

## 1. Como o Traefik é gerenciado (achado desta sessão)

Serviço Swarm `easypanel-traefik` (imagem `traefik:3.6.7`, réplica única),
criado pelo EasyPanel. Dois mecanismos de config **completamente separados**
— importante não confundir:

### 1.1 Config dinâmica (roteamento por domínio) — NÃO é o que vamos mexer
Arquivos em `/etc/easypanel/traefik/config/` (bind mount `/data` →
`FILE_DIRECTORY`), formato JSON com extensão `.yaml`:
- `main.yaml` — gerado/regravado automaticamente pelo EasyPanel toda vez que
  um domínio é adicionado/removido pela UI (rotas dos apps hospedados,
  dashboard do Traefik, redis tools, etc.).
- `arkontech.yaml` — mantido manualmente (rotas do `casagora-router`,
  `arkontech_api/app`, Imoviz, Carhauler — os domínios "custom" que não usam
  o padrão `*.7logs5.easypanel.host` do EasyPanel).

Isso é o que já causou incidente antes (nota em `reference_easypanel_novo_subdominio`)
— **não vamos tocar aqui**.

### 1.2 Config estática (entrypoints, TLS, providers) — É AQUI que o bug mora
100% via variáveis de ambiente na spec do serviço Swarm (não existe
`traefik.yml`/`traefik.toml` — confirmado, `docker service inspect
easypanel-traefik` mostra a config inteira em `Spec.TaskTemplate.ContainerSpec.Env`).
As duas variáveis relevantes:

```
TRAEFIK_ENTRYPOINTS_HTTP_FORWARDEDHEADERS_INSECURE=true
TRAEFIK_ENTRYPOINTS_HTTPS_FORWARDEDHEADERS_INSECURE=true
```

Confirmado também via API interna do próprio Traefik (`docker exec
easypanel-traefik wget -qO- http://localhost:8080/api/entrypoints` — porta
`:8080`, não é a pública, não passa pelo forward-auth):

```json
{ "address": ":80",  "forwardedHeaders": { "insecure": true }, "name": "http"  },
{ "address": ":443", "forwardedHeaders": { "insecure": true }, "name": "https" },
{ "address": ":8080","forwardedHeaders": {},                   "name": "traefik" }
```

`insecure: true` é o modo "confia em qualquer `X-Forwarded-*` que o cliente
mandar, não importa quem conectou" — é literalmente a causa do P4. O
entrypoint `:8080` (API interna) já está correto (não expõe isso
publicamente, não precisa de mudança).

### 1.3 Isso é reconciliado pelo EasyPanel ou fica estável após `docker service update`?
Não há indício de um processo de reconciliação ativo para a config estática
do Traefik — o EasyPanel reescreve `main.yaml` (dinâmico) quando você mexe em
domínios pela UI, mas não encontrei nada que regrave as env vars do serviço
`easypanel-traefik` em uso normal (adicionar app, trocar domínio, etc.). Uma
**atualização do próprio EasyPanel** pode, em teoria, redesplegar esse
serviço do zero e reverter a mudança — se isso acontecer no futuro, este
runbook serve pra reaplicar.

## 2. `trustedIPs` corretos — raciocínio

`forwardedHeaders.trustedIPs` no Traefik decide: **de quem Traefik aceita um
`X-Forwarded-For` já preenchido** (porque confia que quem conectou é um proxy
legítimo que já validou o cliente original). De qualquer outro IP, Traefik
deve **descartar** o header que veio e escrever o IP real da conexão TCP.

Não é sobre a rede interna do Swarm — a rede overlay (Traefik → containers)
é uma fronteira de confiança **separada e já resolvida** (cada app trata
isso no próprio código; o `casagora-router` já faz isso com `trust proxy:
['loopback','uniquelocal']`, ver PR #15). Aqui a pergunta é só: **quem
conecta diretamente na porta 80/443 pública desta VPS?**

Testado via `dig` em todos os domínios configurados nos dois arquivos de
config dinâmica (24 hosts):

| Resolve direto pra `31.97.168.24` (VPS, sem Cloudflare) | Resolve pra IP da Cloudflare (proxied) |
|---|---|
| `arkontech.com.br`, `api.arkontech.com.br`, `app.arkontech.com.br` + wildcard `*.arkontech.com.br` (tenants) | `www.arkontech.com.br` (redirect pro apex — anomalia, mas existe) |
| `routercasagora.arkontech.com.br`, `carhauler.arkontech.com.br`, `devroutercasagora.arkontech.com.br` | `api.imovizapp.com`, `app.imovizapp.com`, `imovizapp.com`, `www.imovizapp.com`, `casagora.imovizapp.com` (Imoviz inteiro) |
| `evolution.arkontech.com.br`, `n8n.arkontech.com.br`, `webhook.arkontech.com.br` | |
| `eufernandasimoes.com.br`, `zentara.arkontech.com.br` (⚠️ serviço não existe mais, ver seção 3) | |
| `painel.arkontech.com.br`, `7logs5.easypanel.host`, `traefik.7logs5.easypanel.host` | |
| redis tools (`*.7logs5.easypanel.host`), `trafego-admin.arkontech.com.br` | |

**Conclusão**: `trustedIPs` = só os ranges publicados da Cloudflare (v4+v6,
consultados hoje em `cloudflare.com/ips-v4` e `/ips-v6`, idênticos aos
consultados ontem — estáveis). **Nenhum IP interno precisa entrar na lista**
— não há cenário legítimo de algo conectando na porta pública 80/443 vindo
de dentro da rede overlay.

```
173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32
```

**Efeito esperado por grupo**:
- Domínios **sem** Cloudflare (maioria): hoje vulneráveis a spoof de
  `X-Forwarded-For` (é o que o P4 documentou). Depois da mudança, Traefik
  vai **ignorar** qualquer `X-Forwarded-For` que o cliente mandar e escrever
  o IP real da conexão — corrige o gap pra todos eles, não só o
  `casagora-router`.
- Domínios **com** Cloudflare: sem mudança de comportamento — a Cloudflare já
  está nos `trustedIPs`, então seu `X-Forwarded-For`/`CF-Connecting-IP`
  continuam sendo aceitos como hoje.

## 3. Serviços atrás deste Traefik — checklist de health check

Baseline capturado em 20/07/2026 (`curl -s -o /dev/null -w '%{http_code}'
https://<host>/`, timeout 6s). **Comparar código a código depois da
mudança — qualquer código diferente do "esperado" abaixo é regressão.**

| # | Domínio | Serviço | HTTP esperado | Observação |
|---|---|---|---|---|
| 1 | `painel.arkontech.com.br` | EasyPanel (dashboard) | 200 | |
| 2 | `traefik.7logs5.easypanel.host` | Traefik dashboard | 403 | forward-auth sem token — esperado, não é erro |
| 3 | `evolution.arkontech.com.br` | Evolution API | 200 | |
| 4 | `n8n.arkontech.com.br` | n8n | 200 | |
| 5 | `webhook.arkontech.com.br` | n8n (webhook) | 200 | |
| 6 | `eufernandasimoes.com.br` | WordPress | 200 | |
| 7 | `zentara.arkontech.com.br` | Zentara | **502** | ⚠️ serviço **não existe** no Swarm (`no such service` confirmado) — já quebrado hoje, produto encerrado (ver memória). Não é regressão se continuar 502. |
| 8 | `agenciadeia-redis-rediscommander.7logs5.easypanel.host` | RedisCommander | 403 | forward-auth — esperado |
| 9 | `agenciadeia-redis-dbgate.7logs5.easypanel.host` | DbGate | 403 | forward-auth — esperado |
| 10 | `trafego-admin.arkontech.com.br` | painel-trafego (systemd, fora do EasyPanel) | 401 | auth própria — esperado |
| 11 | `arkontech.com.br` | arkontech_landing | 200 | |
| 12 | `www.arkontech.com.br` | redirect (via Cloudflare) | 301 | |
| 13 | `api.arkontech.com.br` | arkontech_api | 404 | sem rota em `/` — esperado |
| 14 | `app.arkontech.com.br` | arkontech_app | 200 | |
| 15 | `routercasagora.arkontech.com.br` | casagora_router_api | 302 | redirect (login) |
| 16 | `carhauler.arkontech.com.br` | carhauler_app | 200 | |
| 17 | `devroutercasagora.arkontech.com.br` | casagora_router_api_dev | **502** | ⚠️ serviço **não existe** no Swarm — já quebrado hoje, não é regressão |
| 18 | `api.imovizapp.com` | casagora_router_api (via Cloudflare) | 302 | |
| 19 | `app.imovizapp.com` | imoviz_frontend (via Cloudflare) | 307 | middleware Next.js redirect |

**Itens 7 e 17 já estão quebrados antes da mudança** — incluídos só pra não
serem confundidos com regressão nova depois do restart. Não fazem parte do
critério de sucesso.

**Verificação extra de config** (mais precisa que comportamento HTTP):
```bash
docker exec $(docker ps -q -f name=easypanel-traefik) wget -qO- http://localhost:8080/api/entrypoints
```
Esperado depois da mudança: `forwardedHeaders` de `http` e `https` mostra
`"trustedIPs": [...]` (a lista acima) e **não tem mais** `"insecure": true`.

## 4. Mudança exata

```bash
docker service update \
  --env-rm TRAEFIK_ENTRYPOINTS_HTTP_FORWARDEDHEADERS_INSECURE \
  --env-rm TRAEFIK_ENTRYPOINTS_HTTPS_FORWARDEDHEADERS_INSECURE \
  --env-add TRAEFIK_ENTRYPOINTS_HTTP_FORWARDEDHEADERS_TRUSTEDIPS=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32 \
  --env-add TRAEFIK_ENTRYPOINTS_HTTPS_FORWARDEDHEADERS_TRUSTEDIPS=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32 \
  easypanel-traefik
```

Só troca essas 2 variáveis — nenhuma outra env, label, mount ou config
dinâmica é tocada.

## 5. Downtime esperado

`docker service update` em env var força um novo container (não há
"reload" de env em Swarm). Réplica única, `UpdateConfig.Order: stop-first`
→ Traefik **para antes de subir o novo**, então há uma janela real (poucos
segundos, tipicamente 3-8s pela experiência do deploy do `casagora-router`
ontem) em que **nenhum domínio desta VPS responde** — HTTP/HTTPS inteiros
dependem deste único processo. TLS/ACME não deve re-emitir nada (certificados
já armazenados em `/data/acme.json`, só a config de entrypoint muda).

## 6. Validação pós-mudança (ordem de execução)

1. `docker service ps easypanel-traefik` — nova task em `Running`, sem
   restart loop.
2. `docker exec ... /api/entrypoints` — confirma `trustedIPs` presente,
   `insecure` sumiu, nos dois entrypoints (seção 3).
3. Checklist de 19 serviços (seção 3) — código HTTP bate com o esperado
   (itens 7/17 continuam 502, isso é OK).
4. **Teste que prova o fix** — repetir o harness de ontem contra
   `routercasagora.arkontech.com.br` (domínio sem Cloudflare, o que
   expunha o bug):
   ```bash
   # baseline sem spoof
   curl -s -i -X POST "https://routercasagora.arkontech.com.br/api/v2/auth/refresh" \
     -H 'content-type: application/json' -d '{}' | grep -i ratelimit-remaining
   # com XFF forjado — esperado: MESMO bucket agora (remaining decrementa, não reseta)
   curl -s -i -X POST "https://routercasagora.arkontech.com.br/api/v2/auth/refresh" \
     -H 'content-type: application/json' -H 'X-Forwarded-For: 1.1.1.1' -d '{}' | grep -i ratelimit-remaining
   curl -s -i -X POST "https://routercasagora.arkontech.com.br/api/v2/auth/refresh" \
     -H 'content-type: application/json' -H 'X-Forwarded-For: 3.3.3.3' -d '{}' | grep -i ratelimit-remaining
   ```
   Critério de sucesso: os 3 valores de `ratelimit-remaining` formam uma
   sequência decrescente (mesmo bucket) — **diferente** de ontem, onde o
   spoof resetava pra 9 a cada tentativa. **Cuidado com o orçamento
   compartilhado** (10/15min pra todas as 4 rotas de login) — só 3
   requisições neste teste, não repetir sem necessidade.
5. Confirmar `app.imovizapp.com`/`api.imovizapp.com` (via Cloudflare)
   continuam funcionando normalmente (login real rápido, sem forçar
   múltiplas tentativas) — prova que o tráfego real da Cloudflare não foi
   afetado.

## 7. Rollback exato

```bash
docker service update \
  --env-rm TRAEFIK_ENTRYPOINTS_HTTP_FORWARDEDHEADERS_TRUSTEDIPS \
  --env-rm TRAEFIK_ENTRYPOINTS_HTTPS_FORWARDEDHEADERS_TRUSTEDIPS \
  --env-add TRAEFIK_ENTRYPOINTS_HTTP_FORWARDEDHEADERS_INSECURE=true \
  --env-add TRAEFIK_ENTRYPOINTS_HTTPS_FORWARDEDHEADERS_INSECURE=true \
  easypanel-traefik
```
Restaura o estado exato de hoje (mesma janela de downtime de alguns
segundos). Critério pra rollback: qualquer item do checklist da seção 3
sair do esperado (exceto os itens 7/17, já quebrados), ou o teste da seção
6.4 não decrementar (spoof continua funcionando).

## 8. P6 — o que sobra depois do P4 fechar

Resolver o P4 fecha o vetor de bypass do rate limiter via
`X-Forwarded-For` forjado, mas **não adiciona uma segunda camada de defesa
no `superadmin-login`** — ele continua dependendo só do rate limiter (agora
correto) como única barreira. Recomendação a avaliar (decisão futura, não
desta sessão): adicionar Turnstile no `superadmin-login`, mesmo padrão já
usado no login principal — endurece contra o cenário em que o rate limiter
sozinho não é suficiente (ex.: um ataque distribído de IPs reais
diferentes, que o P4 não resolve nem tenta resolver — rate limit por IP
não impede um atacante com muitos IPs reais).

---

## Histórico de execuções

*(preenchido depois da Etapa 2, com o ok explícito do Vagner)*
