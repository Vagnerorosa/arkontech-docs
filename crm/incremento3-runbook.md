# Runbook — Fase 1A, Incremento 3 (login emite access+refresh, renovação silenciosa)

> Escrito em 21/07/2026, registrando a execução real deste incremento — o único
> da Fase 1A que exige `casagora-router` (backend) e `casagora-sistema`
> (frontend) subindo na mesma janela (ver `fase1-auth-plano.md` seção 4).
> Vagner confirmou antes da execução que a equipe da Casagora não estava
> usando o sistema no momento e que uma indisponibilidade curta era aceitável
> — mesmo assim o ritual completo (golden master antes/depois, tags de
> rollback anotadas, validação em produção) foi seguido.

## Escopo do incremento

- **Backend** (`casagora-router` PR#16, branch `fase1a-incremento3-login-refresh`):
  `POST /api/v2/auth/login`, `/superadmin-login` e `/change-password` passam a
  emitir `token` (access, 15min) + `refresh_token` (novo, opaco, hash em
  `app_sessions`, 30d ou 8h conforme a rota) em vez do JWT único de 30d/8h de
  sempre.
- **Frontend** (`casagora-sistema` PR#1, branch
  `fase1a-incremento3-frontend-refresh`): `lib/auth.ts`, `middleware.ts`
  (renovação silenciosa, threshold 120s), `login/route.ts`,
  `change-password/route.ts`, `logout/route.ts`, `profile/route.ts`,
  `types/auth.ts` — consomem o par novo e renovam silenciosamente perto da
  expiração do access token.

## Execução — 21/07/2026

### ETAPA 1 — Preparação e verificação

- **PRs conferidos**: `casagora-router#16` e `casagora-sistema#1`, ambos
  `MERGEABLE`/`CLEAN` contra a `main`/`master` atual (que já tinha os
  Incrementos 1+2 + fix trust-proxy). Diffs lidos linha a linha — batem
  exatamente com o plano (Tasks 1-2 backend, Tasks 8-11 frontend). Nenhum dos
  dois PRs mudou desde a sessão de prep de 19/07.
- **Golden master ANTES** (contra produção real): 47/47, 0 diffs.
- **Tags/rollback anotados**: backend
  `casagora/router-api:0.9.324-fase1a-incrementos-1-2-trustproxy-20260719`;
  frontend `imoviz-frontend:latest` (sem tag versionada — achado registrado
  abaixo).
- **Suíte de testes de transição — re-executada com prova fresca** a pedido
  do Vagner (não bastava o resultado da sessão de prep): ambiente
  `casagora_router_dev` recriado do zero —
  - Banco `casagora_router_dev` refrescado de produção via
    `casagora-router-refresh-dev-db.sh` (14.487 linhas de
    `lead_crm_import`, igual à produção).
  - Imagem de dev construída a partir de um `git worktree` isolado na branch
    `fase1a-incremento3-login-refresh` (tag `dev-incremento3-test`, nunca
    publicada).
  - Container rodando só em `127.0.0.1:3011` (nunca exposto publicamente),
    na network `easypanel` (alcança o Postgres real), com
    `CHAVES_IMAP_ENABLED`, `NOCRM_SYNC_DAILY_ENABLED`,
    `NOCRM_WEBHOOK_ENABLED` e `QUEUE_RECONCILE_HOURLY_ENABLED` desligados
    (zero efeito colateral externo) e `TURNSTILE_SECRET` removido do env
    (bypass de Turnstile só neste container de teste, condicional que já
    existe no próprio código: `if (TURNSTILE_SECRET) { ... }`).
  - Usuário de teste `phototest-a@test.local` (id 60, já existente na base
    real) com senha conhecida setada só no banco de dev.
  - **4 cenários confirmados**:
    1. Login novo emite `token` (JWT, `exp-iat=900s`) + `refresh_token` (64
       hex) — ok.
    2. JWT antigo (30d, sem refresh, assinado com o mesmo `JWT_SECRET`)
       continua aceito normalmente em rota protegida, sem forçar refresh —
       ok.
    3. JWT expirado → 401 `invalid_token`; `/refresh` sem `refresh_token` →
       400 `missing_refresh_token` (força login único, sem "renovação
       mágica") — ok.
    4. `/refresh` com token válido rotaciona o par; token antigo ainda vivo
       dentro da grace period de 10s; morre (`invalid_refresh_token`) depois
       disso; token novo continua válido — ok.
  - `middleware.ts` do PR#1 conferido linha a linha contra esse contrato:
    nomes de campo batem (`access_token`/`refresh_token` do `/refresh`,
    diferente de `token` do `/login`), threshold de 120s confirmado,
    `withRotatedCookies` seta os 3 cookies (`imoviz_token`, `imoviz_refresh`,
    `imoviz_user`) como esperado. Validação do frontend foi estática (leitura
    de código), não um `next dev` real — registrado explicitamente, não
    escondido.
- **Achado de infraestrutura (novo, fora do escopo original)**: o frontend
  não usa tags versionadas — é sempre `imoviz-frontend:latest`, sobrescrita a
  cada build. Rollback por nome de tag não funciona sozinho. Resolvido nesta
  execução re-tageando a imagem atual como
  `imoviz-frontend:rollback-pre-incremento3-20260721` **antes** do rebuild —
  isso não estava coberto pelo `deploy-runbook.md` (que só documenta o
  backend). Recomendação para o próximo deploy de frontend: sempre re-tagear
  a imagem atual antes de rebuildar `:latest`.

### ETAPA 2 — Execução

1. Re-tag do frontend: `imoviz-frontend:latest` →
   `imoviz-frontend:rollback-pre-incremento3-20260721` (alvo de rollback
   real criado antes de qualquer mudança).
2. **Merge backend**: PR#16 mergeado em `main` (`f17e8aa..a4747d5`).
3. **Build + deploy backend**: `casagora/router-api:0.9.325-fase1a-incremento3-login-refresh-20260721`,
   via `./scripts/build-image.sh` + `docker service update --image ...`
   (padrão do `deploy-runbook.md`). Convergiu sem restart loop.
4. **Validação backend**:
   - `/admin/version`: `app_version`/`git_sha` batem com o build.
   - `/health`: 200.
   - Golden master pós-deploy: 47/47, 0 diffs (esperado — o script não
     exercita um login bem-sucedido, então a mudança de shape de
     `refresh_token` não aparece automaticamente; gap já documentado na
     PR#16).
   - Smoke test específico do incremento (sem credenciais reais, produção é
     read-only): login com credencial errada continua retornando erro
     genérico sem `token`/`refresh_token`; `/refresh` sem token → 400
     `missing_refresh_token`; `/logout` sem token → 200 `{ok:true}`
     (idempotente) — nenhuma regressão de shape nos caminhos de falha.
   - Watermarks de intake (`lead_events`, `webchat_leads`,
     `landing_page_leads`, `nocrm_webhook_events`): idênticos antes/depois
     (sem tráfego orgânico na janela — esperado, período de baixo volume).
5. **Merge frontend**: PR#1 mergeado em `master` (`03f4757..d05d28b`).
   `git status` de `frontend/` limpo antes do build (regra `DIRETRIZES.md
   §10`).
6. **Build + deploy frontend**: `docker build --build-arg
   NEXT_PUBLIC_API_URL=... --build-arg NEXT_PUBLIC_TURNSTILE_SITE_KEY=...
   --no-cache -t imoviz-frontend:latest .` (101s) + `docker service update
   --force --image imoviz-frontend:latest imoviz_frontend` (o `--force` é
   obrigatório — Swarm não percebe sozinho que `:latest` mudou de
   conteúdo, ver `CLAUDE.md` do repo). Build do Next.js confirmou o
   `Middleware` novo compilado (33.3 kB, era menor antes — bate com a
   renovação silenciosa adicionada).
7. **Validação final**:
   - Image ID do container rodando confere com `imoviz-frontend:latest`
     (sem cache stale).
   - `https://app.imovizapp.com/login` responde 200.
   - Golden master pós-deploy completo (backend+frontend): 47/47, 0 diffs.

### Smoke test humano (Vagner, 21/07/2026)

Login real testado em **3 navegadores** (Firefox, Edge, Chrome), todos em
**modo anônimo/incógnito**, com **3 papéis diferentes** (Admin, gestor,
corretor) — todos logaram e navegaram normalmente. Nenhum problema
reportado.

### Limpeza pós-execução

- Container `casagora_router_dev`, imagem `dev-incremento3-test` e o `git
  worktree` de teste removidos após a validação dos 4 cenários (eram só
  infra de teste, não fazem parte do histórico do repo).
- Branches `fase1a-incremento3-login-refresh` e
  `fase1a-incremento3-frontend-refresh` **mantidas** (não deletadas ainda —
  aguardando confirmação de estabilidade contínua, por decisão do Vagner).

## Estado final

- Backend em produção: `0.9.325-fase1a-incremento3-login-refresh-20260721`.
- Frontend em produção: `imoviz-frontend:latest` (build de 21/07/2026, PR#1).
- Rollback disponível: backend via tag anotada acima; frontend via
  `imoviz-frontend:rollback-pre-incremento3-20260721`.
- **Nenhum rollback foi necessário.** Zero surpresas em todas as etapas.
- Critério de conclusão do Incremento 3 (`fase1-auth-plano.md` seção 4)
  atingido: login em um passo (`must_change_password` é só uma checagem de
  flag), renovação silenciosa funcionando, sessões antigas migram
  passivamente sem corte.

## Próximo passo

Incremento 4 (revogação real em desativação/reset de senha) depende deste
incremento estar estável em produção — sem prazo definido, aguardar alguns
dias de operação normal antes de planejar.
