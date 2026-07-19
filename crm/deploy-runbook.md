# Runbook — Deploy do `casagora-router` em produção

> Escrito em 19/07/2026, **antes** de executar o primeiro deploy real
> guiado por este documento (Fase 1A, Incrementos 1+2). Depois de rodar
> uma vez, vira o ritual padrão — registrar cada execução na seção
> "Histórico de execuções" no final, sem reescrever o procedimento acima
> a cada vez (só ajustar se algo relevante mudar).

## Mecanismo de deploy (descoberto/confirmado nesta sessão)

Não há CI/CD automatizado nem EasyPanel gerenciando este serviço
especificamente — confirmado via `docker service inspect
casagora_router_api` (labels vazios, spec não referencia stack do
EasyPanel). O processo é manual, documentado em `DEPLOY.md`/`RUNBOOK.md`
do próprio repo, e é o que já foi usado em todo o histórico real de
deploys (`0.9.320` → `0.9.322`, confirmado em `docker service ps`):

1. Build da imagem **a partir do código-fonte no host** (nunca a partir
   de um container rodando): `./scripts/build-image.sh <tag>`.
2. Deploy: `docker service update --image casagora/router-api:<tag>
   casagora_router_api`.
3. Serviço roda com **1 réplica só** (`Replicated, Replicas: 1`) — o
   update é feito com o padrão default do Swarm (derruba a réplica
   antiga, sobe a nova). Existe uma janela curta (segundos) de
   indisponibilidade durante o restart — não é rolling update sem
   downtime, é o que a topologia atual permite.
4. Rollback nativo do Swarm: `docker service update --rollback
   casagora_router_api` — volta pro spec anterior (imagem + env),
   guardado pelo próprio Swarm. **Além disso**, anotar manualmente a tag
   da imagem em produção antes de cada deploy (`docker service inspect
   ... --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'`) como
   segunda fonte de verdade, caso o rollback nativo não seja suficiente
   (ex.: precisar buildar de novo uma tag antiga específica).
5. Verificação pós-deploy: `GET /admin/version?token=$ADMIN_TOKEN` —
   confirma `app_version` (bate com a tag) e `git_sha` (bate com o commit
   buildado).

## Checklist pré-deploy

- [ ] `git status` limpo no repo fonte usado pro build (nunca buildar
      com árvore suja — regra de `DIRETRIZES.md §10`, já causou bug em
      produção antes).
- [ ] Branch/commit a deployar identificado e confirmado (`git log
      --oneline`).
- [ ] Golden master rodado **contra produção**, salvo como baseline
      "antes" — é a rede de segurança que detecta regressão de
      contrato de rota.
- [ ] Tag da imagem atualmente em produção anotada (rollback manual).
- [ ] Nova tag de imagem decidida, seguindo o padrão
      `0.9.NNN-descricao-YYYYMMDD`.
- [ ] **Continuidade de webhooks** (o router recebe leads o tempo todo,
      inclusive durante o deploy): anotar o último `id`/timestamp de
      cada tabela de intake antes do restart —
      ```sql
      select max(id), max(received_at) from lead_events;
      select max(id), max(received_at) from webchat_leads;
      select max(id), max(created_at) from landing_page_leads;
      select max(id), max(received_at) from nocrm_webhook_events;
      ```
      Isso é o ponto de referência pra confirmar depois que nada se
      perdeu na janela de restart (a réplica única fica indisponível por
      alguns segundos — um webhook batendo exatamente nesse instante
      recebe erro de conexão do lado de quem chama, não é enfileirado
      pelo router).

## Deploy

```bash
cd /opt/repos/casagora-router
git checkout main && git pull origin main --ff-only

./scripts/build-image.sh <NOVA_TAG>
docker service update --image casagora/router-api:<NOVA_TAG> casagora_router_api
docker service ps casagora_router_api   # aguardar task nova em "Running"
```

## Validação pós-deploy

- [ ] `GET /admin/version?token=$ADMIN_TOKEN` — `app_version`/`git_sha`
      batem com o que foi buildado.
- [ ] Golden master **contra produção** de novo — comparar com o
      baseline "antes". Rotas pré-existentes: **0 diffs esperado**. Se
      o incremento sendo deployado muda contrato de alguma rota de
      propósito (ex.: Incremento 3, login com novo payload), isso deve
      já estar documentado como diff esperado antes do deploy, não
      descoberto na hora.
- [ ] Smoke test dos endpoints específicos do incremento (definido por
      deploy, ver seção de histórico).
- [ ] Login real em `https://app.imovizapp.com` (validação manual,
      humana — golden master só confirma o *contrato* das rotas de
      auth sem token, não a experiência de login completa).
- [ ] **Webhooks voltaram a processar**: `GET /health` responde `200`
      (confirma o processo novo está de pé e conectado ao banco); e pelo
      menos uma das tabelas de intake recebeu uma linha nova com `id` >
      o anotado no pré-deploy **ou**, na ausência de tráfego orgânico
      dentro da janela de validação, um teste manual no endpoint
      público correspondente (`/webhook/facebook` com payload inválido
      já basta pra confirmar que a rota responde — não precisa de um
      lead de verdade).
- [ ] **Nenhum lead perdido na janela do restart**: comparar o
      `max(id)`/timestamp anotado antes com o de depois — se houver
      salto grande de tempo sem nenhuma linha nova em nenhuma tabela
      *e* alguma fonte externa (Meta Ads Manager, painel do noCRM)
      confirmar que um evento foi disparado nessa janela, investigar
      antes de considerar o deploy concluído. Na prática, um restart de
      poucos segundos tem baixa probabilidade de coincidir com um
      webhook — este passo é sobre confirmar, não presumir.

## Critério de rollback

Rodar `docker service update --rollback casagora_router_api` se
qualquer um destes falhar:
- Task novo não chega a "Running" (`docker service ps` mostra restart
  loop ou "Failed").
- `/admin/version` não atualiza ou o serviço não responde.
- Golden master pós-deploy mostra diff em rota que **não** era esperado
  mudar neste deploy.
- Smoke test dos endpoints novos falha.
- Login real falha.
- `/health` não volta a responder `200`, ou nenhuma tabela de intake
  aceita escrita nova depois do restart (webhook quebrado silenciosamente).

Depois do rollback: confirmar `/admin/version` voltou pra tag anterior,
rodar golden master mais uma vez pra confirmar que voltou ao baseline
"antes".

---

## Histórico de execuções

### 19/07/2026 — Fase 1A, Incrementos 1+2 (rate limiting + refresh/logout)

**Resumo**: primeira execução real deste runbook. Achou e corrigiu um bug crítico
(rate limiter global) e um gap residual de infra (Traefik não sanitiza
`X-Forwarded-For`) no processo — ambos registrados em `DECISOES.md` (P4, P6).
Deploy final bem-sucedido, com o gap residual aceito como follow-up (não
bloqueante, ver P4).

**Linha do tempo**:

1. **Tag anotada antes**: `0.9.322-fix-nocrm-import-name-20260716` (git_sha
   `fb6ef46` — de antes até do Fase 0/item 1, serviço não era atualizado desde
   16/07).
2. **Golden master ANTES**: 45 rotas existentes batendo com o baseline; as 2
   rotas novas (`/refresh`, `/logout`) corretamente 404 (esperado, ainda não
   deployadas). Watermarks de intake anotados (`lead_events` max_id 9984 @
   10:19:01 UTC).
3. **1ª tentativa de deploy** — `0.9.323-fase1a-incrementos-1-2-20260719`
   (main com PRs #13+#14). Build e deploy ok, `/admin/version` e golden master
   pós-deploy (47/47, 0 diffs) passaram. **Smoke test do rate limiter revelou
   bug crítico**: sem `app.set('trust proxy', ...)`, `req.ip` atrás do Traefik
   é sempre o IP interno da rede overlay — "10 tentativas/15min por IP" virava
   "10 tentativas/15min pra produção inteira". Confirmado ao vivo: o próprio
   smoke test consumiu 7 dos 10 slots do budget compartilhado.
4. **Rollback imediato**: `docker service update --rollback` → confirmado de
   volta em `0.9.322`/`fb6ef46`, golden master idêntico ao "antes", nenhum
   lead perdido nos watermarks de intake.
5. **Fix**: `app.set('trust proxy', ['loopback','uniquelocal'])` +
   `clientIpForRateLimit()` (confia em `CF-Connecting-IP` só quando o IP
   resolvido cai numa faixa de borda publicada da Cloudflare — os dois
   domínios de produção têm hop count diferente, `routercasagora...` bate
   direto no Traefik, `api.imovizapp.com` passa pela Cloudflare antes).
   Branch `fase1a-fix-trust-proxy`, PR #15, validado com harness standalone
   (6 cenários incluindo tentativas de spoofing) + golden master local
   (47/47, 0 diffs) antes do merge.
6. **2ª tentativa de deploy** — `0.9.324-fase1a-incrementos-1-2-trustproxy-20260719`.
   Build, deploy, `/admin/version`/`/health` ok, golden master pós-deploy
   47/47 0 diffs.
7. **Validação de comportamento por-IP atrás do proxy real** (não só
   localmente — lição desta execução, ver abaixo): tráfego real sem spoof
   decrementou um único bucket de forma consistente (5→4), confirmando a
   correção do bug crítico. Testes com `X-Forwarded-For` forjado (valores
   diferentes a cada tentativa) sempre resetaram pra um bucket novo
   (`remaining: 9`) — **achado um gap residual**: o Traefik está repassando
   o `X-Forwarded-For` do cliente sem sanitizar, então um atacante
   deliberado ainda contorna o limite variando esse header. Registrado como
   P4 (infra, fora deste repo) e P6 (`superadmin-login` fica exposto
   enquanto P4 não for corrigido) em `DECISOES.md`.
8. **Watermarks de intake pós-deploy**: idênticos aos de antes (sem tráfego
   orgânico no intervalo — período de baixo volume, não indica problema;
   `/health` respondeu 200 imediatamente após cada restart, nos dois
   deploys).
9. **Login real**: confirmado pelo Vagner em `https://app.imovizapp.com` —
   testado em Firefox, Edge e Chrome, todos em modo anônimo. Login e
   navegação funcionando normalmente nos três.

**Lição registrada para o próximo deploy**: qualquer teste de comportamento
por-IP (rate limit, allowlist, geo, auditoria) **precisa ser validado atrás
do proxy real em produção**, não só localmente — um harness local (mesmo
correto) não teria pego o gap do Traefik, porque a lógica de trust-proxy do
Express estava certa; o problema estava um passo antes, no proxy que a
alimenta.

**Estado final**: produção em `0.9.324-fase1a-incrementos-1-2-trustproxy-20260719`,
**validação completa** (golden master, smoke test, comportamento por-IP atrás
do proxy real, login real em 3 navegadores diferentes). Bug crítico corrigido
e validado. Gap residual (P4/P6) documentado, não bloqueante, sem prazo
definido — decisão consciente de não bloquear o deploy de hoje por ele.
Deploy do dia encerrado com sucesso.

### 20/07/2026 — Reconfirmação pós-P4 (checklist de saúde geral)

Depois do P4 ser fechado (Traefik corrigido, ver `crm/p4-traefik-runbook.md`
e D13 em `DECISOES.md`), reconfirmado que o deploy de 19/07 continua
saudável e que a mudança de infra não introduziu nenhuma regressão:

- **19/19 domínios** do checklist do P4 (seção 3 daquele runbook) — status
  HTTP idêntico ao baseline, incluindo os 2 já quebrados antes (Zentara,
  `devroutercasagora`, sem regressão nova).
- **Traefik**: `docker service ps easypanel-traefik` — task estável, sem
  restart loop. `/api/entrypoints` reconfirmado: `insecure: false`,
  `trustedIPs` com 22 ranges nos dois entrypoints (`http`/`https`) —
  config não foi revertida por nenhuma ação do EasyPanel desde ontem.
- **`casagora_router_api`**: `docker service ps` — estável há 6h na imagem
  `0.9.324-fase1a-incrementos-1-2-trustproxy-20260719`, sem restart desde
  o deploy de 19/07.

Nenhuma ação corretiva necessária. Estado de produção confirmado estável
no dia seguinte ao deploy + à mudança de infra do P4.
