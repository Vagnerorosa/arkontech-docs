# Relatório de varredura de segredos — 19/07/2026

Fase 0, item 4 do `PLANO-ESTRANGULAMENTO.md`. Escopo: código atual (working
tree do HEAD de `main`) **e** histórico git completo (`git log --all`, todas
as branches/tags) de `casagora-router` e `casagora-sistema`.

**Regra deste relatório: nenhum valor de segredo é reproduzido aqui, nem
parcial.** Onde um segredo foi encontrado, o valor foi redigido no arquivo de
origem (ver "Remediação aplicada") — o próprio valor real só existe agora na
memória do Vagner/no sistema de credenciais e no histórico git (permanente,
por isso a recomendação de troca).

## Metodologia

1. **Arquivos `.env` commitados** — busca em toda a história por qualquer
   arquivo `.env*` (exceto `.env.example`) que tenha sido adicionado. Nenhum
   encontrado em nenhum dos dois repos.
2. **Padrões de formato conhecido** — AWS (`AKIA...`), chaves privadas
   (`-----BEGIN...PRIVATE KEY-----`), Stripe (`sk_live_`/`sk_test_`/`pk_live_`),
   Resend (`re_...`), SendGrid, Google (`AIza...`), Asaas (`$aact_...`),
   connection strings com credenciais embutidas (`postgres://`, `mysql://`,
   `mongodb://`, `redis://`, URLs com `user:pass@host` genérico).
3. **Atribuições a variáveis sensíveis por nome** — `JWT_SECRET`,
   `SESSION_SECRET`, `ADMIN_TOKEN`, `API_KEY`, `SECRET_KEY`, `CLIENT_SECRET`,
   `APP_SECRET`, `WEBHOOK_TOKEN`, `ACCESS_TOKEN`, `AUTH_TOKEN`, `PASSWORD`,
   `DATABASE_URL`, `EVOLUTION_TOKEN`/`EVOLUTION_API_KEY`, `NOCRM_API_KEY`,
   `NOCRM_WEBHOOK_TOKEN`, `FACEBOOK_APP_SECRET`, `FACEBOOK_VERIFY_TOKEN`,
   `FACEBOOK_ACCESS_TOKEN`, `TURNSTILE_SECRET`, `RESEND_API_KEY`,
   `ASAAS_API_KEY`, `STRIPE_SECRET`, `PGPASSWORD` — testado com valor citado
   entre aspas E sem aspas (formato `-e VAR=valor` de `docker run`, comum em
   docs de debug), excluindo `process.env.VAR` (leitura correta) e
   placeholders óbvios (`your_...`, `changeme`, `<...>`, `xxxx`).
4. **Bearer tokens / Authorization headers** hardcoded em exemplos de `curl`
   na documentação.
5. **Histórico**: os mesmos padrões via `git log --all -G'<regex>'`
   (encontra commits que adicionaram ou removeram uma linha correspondente)
   e `git log --all -S'<literal>'` (pickaxe) para os hits confirmados, para
   achar o commit exato de introdução.

Ferramenta: `git grep` + `git log -G/-S`, scripts ad-hoc (sem instalar
ferramenta externa de terceiros).

## Achados — casagora-router

**Nenhum segredo hardcoded encontrado — nem no código atual, nem em nenhum
commit do histórico (340 commits, todas as branches).**

Todas as variáveis sensíveis (`DATABASE_URL`, `ADMIN_TOKEN`, `JWT_SECRET`,
`NOCRM_API_KEY`, `NOCRM_WEBHOOK_TOKEN`, `FACEBOOK_APP_SECRET`,
`FACEBOOK_ACCESS_TOKEN`, `FACEBOOK_VERIFY_TOKEN`, `TURNSTILE_SECRET`)
já são lidas exclusivamente de `process.env.*` em `src/server.js`, sem
nenhum valor literal de fallback (os `||` existentes só cobrem config não
sensível: URLs padrão, feature flags, nome de mailbox IMAP, telefone de
alerta). Nenhum arquivo `.env` real foi commitado em nenhum ponto da
história; `.env` está no `.gitignore`.

Nenhuma ação de código foi necessária neste repo — o sub-passo "mover
segredos do código atual para `.env`" do item 4 é um no-op aqui, já estava
correto.

*Observação fora do escopo de segredos (não é credencial, não requer ação
deste item):* dois arquivos de backup antigos do `server.js` estão
commitados na árvore (`src/server.js.bak.chaves.20260401182436`,
`src/server.prod.snapshot.js`) — código morto, candidato à limpeza da
Fase 3, não contêm segredos (foram varridos junto com o resto).

## Achados — casagora-sistema

### 🔴 CRÍTICO — Senha de banco de produção exposta em doc de planejamento

- **Arquivo**: `docs/superpowers/plans/2026-07-02-lp-captacao-leads-plan.md`
- **Commit de introdução**: `d52c8b4` ("docs: plano de implementação da
  captação de leads via landing pages", 02/07/2026)
- **Tipo**: connection string Postgres completa (usuário + senha) para o
  banco de produção do `casagora-router` (`arkontech_postgres` /
  `casagora_router`), usada como exemplo de comando `docker run` de teste
  local.
- **Ocorrências**: 2 blocos idênticos no mesmo arquivo (linhas ~321 e ~483
  antes da remediação).
- **Severidade**: crítica — é a senha real do usuário de aplicação do banco
  de produção do CRM.
- **TROCAR**: sim. Exposta em texto puro no histórico git desde 02/07/2026;
  histórico é permanente mesmo após redação do arquivo atual.

### 🟠 ALTO — Chave secreta (privada) do Cloudflare Turnstile exposta

- **Arquivo**: mesmo arquivo acima, mesmos commits.
- **Tipo**: `TURNSTILE_SECRET` (chave privada usada pelo backend para
  validar o desafio Turnstile — diferente da site key pública, que é
  esperado estar em código/`NEXT_PUBLIC_*` e não é segredo).
- **Ocorrências**: 3 no mesmo arquivo (2 blocos + 1 menção em texto).
- **Severidade**: alta — permite a um atacante forjar validações de
  Turnstile no lado servidor caso a chave secreta vaze (a site key sozinha
  não permite isso).
- **TROCAR**: sim (gerar novo par site key + secret key no painel
  Cloudflare Turnstile e atualizar nos dois lados — backend `TURNSTILE_SECRET`
  e frontend `NEXT_PUBLIC_TURNSTILE_SITE_KEY`, já que são gerados como par).

### 🟢 Baixo / sem ação — placeholders de desenvolvimento

Três outros commits (`27354d3`, `54f6a00`, `62976b7`) têm linhas como
`JWT_SECRET="dev-secret"`, `JWT_SECRET=your_jwt_secret_here`,
`JWT_SECRET=PLACEHOLDER_MUST_MATCH_BACKEND` em docs de setup local —
claramente placeholders/valores de desenvolvimento, não credenciais reais.
Nenhuma ação necessária.

## Remediação já aplicada (código atual)

- `docs/superpowers/plans/2026-07-02-lp-captacao-leads-plan.md`: os 2 blocos
  de `DATABASE_URL` e as 3 menções a `TURNSTILE_SECRET` foram substituídos
  por `<REDACTED-ver-.env-producao>` — o arquivo continua utilizável como
  runbook (a instrução "pegue o valor real do `.env` de produção" fica
  implícita), só não expõe mais o valor em texto puro na árvore atual.
- Nenhuma outra mudança de código foi necessária (ver achados por repo acima).
- **Nenhuma credencial foi trocada por este processo** — troca é ação
  manual do Vagner, listada acima, porque exige coordenar a atualização
  simultânea de onde a credencial é consumida em produção (variável de
  ambiente do serviço no EasyPanel/Swarm).

## Pendências para o Vagner (ação manual, fora do escopo desta sessão)

1. Trocar a senha do usuário `arkontech` no Postgres de produção
   (`arkontech_postgres` / banco `casagora_router`) e atualizar
   `DATABASE_URL` na env do serviço `casagora_router_api`.
2. Gerar novo par de chaves Cloudflare Turnstile (site key + secret key) e
   atualizar `TURNSTILE_SECRET` (backend) e `NEXT_PUBLIC_TURNSTILE_SITE_KEY`
   (build-arg do frontend, ver `casagora-sistema/CLAUDE.md`) juntos — são
   gerados como par, trocar um sem o outro quebra a validação.
3. Depois de trocar: confirmar login (usa Turnstile) e captação de leads via
   LP (usa Turnstile + `DATABASE_URL`) continuam funcionando em produção.
