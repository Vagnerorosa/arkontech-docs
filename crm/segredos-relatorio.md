# Relatório de varredura de segredos — 19/07/2026 (atualizado 19/07/2026, 2ª passada)

Fase 0, item 4 do `PLANO-ESTRANGULAMENTO.md`. Escopo original: código atual
(working tree do HEAD de `main`) **e** histórico git completo (`git log
--all`, todas as branches/tags) de `casagora-router` e `casagora-sistema`.
2ª passada (tarefa de backups/R2, mesma data): crontabs e `/etc/cron.d` da
VPS.

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

## Achados — crontabs / `/etc/cron.d` da VPS (2ª passada, 19/07/2026)

Escopo: `crontab -l` de todos os usuários do sistema (`/etc/passwd`),
`/var/spool/cron/crontabs/*`, todos os arquivos de `/etc/cron.d/`, e os
scripts diretamente invocados por eles.

### 🟡 MÉDIO — Bearer token do carhauler em texto puro no crontab do root

- **Local**: crontab do usuário `root` (`/var/spool/cron/crontabs/root`),
  job `carhauler-email-import` (roda a cada 10 min), no cabeçalho
  `Authorization: Bearer <token>` de um `curl` para
  `carhauler.arkontech.com.br/api/import/superdispatch/pull-email`.
- **Tipo**: token de API estático (não é senha de banco nem chave de
  provedor externo — é um token da própria API do Carhauler).
- **Desde quando**: arquivo com esse conteúdo desde 19/02/2026 (`mtime` do
  spool file).
- **Severidade**: média, não crítica — diferente dos achados acima, este
  **não está em nenhum histórico git** (crontab não é repositório) e o
  arquivo já tem permissão `600`/dono `root` (não é legível por outros
  usuários do sistema). O risco real é: qualquer coisa que rode como root
  nesta VPS, ou um backup/snapshot do sistema de arquivos que inclua
  `/var/spool/cron/`, expõe o valor. Comparável ao padrão que
  `DIRETRIZES.md §2` já pede pra evitar (segredo fora de um cofre/env
  gerenciado), mas sem o agravante de exposição permanente via git.
- **TROCAR**: a critério do Vagner — não é urgente como os achados acima,
  mas está fora do padrão do resto da VPS (os outros jobs/timers que
  precisam de credencial usam `EnvironmentFile` com permissão `600`, não
  crontab direto — ver `casagora-db-backup.service` em
  `arkontech-docs/crm/backups.md`). Sugestão de higiene, não bloqueante:
  mover para um script + `EnvironmentFile` seguindo o mesmo padrão.

### Resto do escopo: limpo

- Nenhum outro usuário do sistema tem crontab com conteúdo.
- `/etc/cron.d/*` (`casagora-router-refresh-dev-db`, `docker-image-prune`,
  `e2scrub_all`, `sysstat`) — nenhum segredo; o único job de aplicação
  (`casagora-router-refresh-dev-db.sh`) autentica no Postgres via usuário
  local dentro do container (`psql -U arkontech` via `docker exec`,
  trust auth do socket unix), sem senha/connection string armazenada em
  lugar nenhum.
- `casagora-db-backup.service`/`.timer` e `agenciadeia-db-backup.service`/
  `.timer` (novo, ver `backups.md`): credenciais via `EnvironmentFile`
  (`/etc/casagora-db-backup.env`, permissão `600`) ou nenhuma credencial
  armazenada (o novo backup do Evolution usa `pg_dump` local dentro do
  container, mesmo padrão trust-auth do refresh-dev-db).

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

> **Status em 19/07/2026 (execução da rotação):** ver
> `rotacao-credenciais.md` para o passo a passo e o histórico completo de
> execução.

1. ✅ **ROTACIONADO em 19/07/2026.** Senha do usuário `arkontech` no
   Postgres de produção trocada (`ALTER USER`) e os 4 consumidores
   (`casagora_router_api`, `arkontech_api`, `carhauler_app`,
   `carhauler_app_canary`) + `/etc/casagora-db-backup.env` atualizados com
   a senha nova. Validado: os 4 serviços de pé, golden master 0 diffs,
   backup manual bem-sucedido, login real ok, carhauler respondendo.
2. ✅ **ROTACIONADO em 19/07/2026** (secret key apenas — Cenário A do
   runbook). Nova secret key gerada no dashboard Cloudflare Turnstile e
   `TURNSTILE_SECRET` atualizado no `casagora_router_api`. A site key
   pública (`NEXT_PUBLIC_TURNSTILE_SITE_KEY`) **não foi trocada** — a
   documentação oficial do Cloudflare confirma que rotacionar só a
   secret é suportado e suficiente para este achado (a site key não é
   segredo); nenhum rebuild do frontend foi necessário.
3. ✅ Confirmado em produção: login (`app.imovizapp.com`, usa Turnstile)
   e captação de leads via LP continuam funcionando; validado em 3
   navegadores anônimos diferentes.
4. ⏸️ **Adiado** (decisão do Vagner, 19/07/2026): mover o Bearer token do
   carhauler do crontab do root para `EnvironmentFile` — junto com a
   rotação do próprio valor do token, adiado porque o Carhauler vai
   passar por reformulação completa em breve (retrabalho fazer agora).
   Ver nota em `rotacao-credenciais.md` seção 3.

## Achado adicional — 23/07/2026 (exposição em runtime, não em código/git)

Categoria diferente dos achados acima (que vieram de varredura de
código/histórico git/crontab): em 23/07/2026, um comando de investigação
numa sessão não relacionada tentou mascarar as env vars do
`casagora_router_api` antes de exibir, mas a máscara foi escrita pro
formato errado de saída (`docker service inspect --format '{{json
.Spec...Env}}'` retorna array de strings `"CHAVE=valor"`, não objeto
`{"CHAVE":"valor"}` — o regex nunca casou). Resultado: `JWT_SECRET`,
`ADMIN_TOKEN`, `NOCRM_API_KEY`, `NOCRM_WEBHOOK_TOKEN`,
`FACEBOOK_ACCESS_TOKEN`, `FACEBOOK_APP_SECRET`, `EVOLUTION_API_KEY`,
`RESEND_API_KEY`, `TURNSTILE_SECRET`, `TURNSTILE_SECRET_WEBCHAT`,
`SMTP_PASS`, `CHAVES_IMAP_PASS` e a senha do Postgres apareceram em texto
puro no transcript de uma conversa (não em nenhum arquivo/commit/log
persistente do sistema — a exposição foi só naquela conversa).

Causa raiz completa, regra de leitura segura de segredo adotada daqui pra
frente, e o relato integral da rotação de resposta estão em
`rotacao-credenciais.md` (Seção 0 = causa raiz + regra nova; Seções 4/5 =
rotação; "Histórico de execução", entrada 23-24/07/2026 = o que foi
executado, validado e o que ainda fica pendente). Resumo do status:

- ✅ **Rotacionados e validados em produção (23-24/07/2026)**:
  `FACEBOOK_ACCESS_TOKEN` (migrado pra System User de quebra, permissões
  reduzidas de ~50 pro mínimo real de 8), `FACEBOOK_APP_SECRET`,
  `NOCRM_API_KEY`, `RESEND_API_KEY`. Validação incluiu monitorar o próximo
  lead real de campanha do Facebook chegando via webhook sem nenhuma
  rejeição.
- ⏸️ **Pendente, decisão do Vagner**: `EVOLUTION_API_KEY` (chave global de
  infra própria, não SaaS de terceiro — ver `rotacao-credenciais.md` 4.2).
- ⏸️ **Pendente, aguardando janela de madrugada aprovada**: `JWT_SECRET`
  (Seção 5 — achado importante: o frontend guarda uma cópia e verifica a
  assinatura localmente, os dois precisam trocar quase simultâneos) e a
  spec do `arkontech_postgres` (`POSTGRES_PASSWORD` de bootstrap, resíduo
  já identificado em 22/07).
- 🟡 **Residual encontrado e corrigido nesta mesma varredura** (mesmo
  padrão dos achados de código/crontab acima, mas achado por busca
  exaustiva por nome de variável, não pela metodologia original deste
  relatório): arquivo órfão `/etc/casagora-router.secrets.env` com
  permissão `644` (mundo lê) guardando cópias antigas de vários destes
  tokens; 4 scripts em `/root/scripts/` com fallback ou valor hardcoded;
  1 workflow inativo no n8n (`agenciadeia_n8n`) com a chave da Evolution
  hardcoded num node. Detalhe completo em `rotacao-credenciais.md` seção
  4.3.
