# PLANO DE ESTRANGULAMENTO — casagora-router
> Baseado no censo de 203 rotas (19 grupos funcionais) de julho/2026.
> Regra de ouro: uma fase por vez. Cada fase tem critério de conclusão
> verificável. Nenhuma fase começa sem a rede de segurança da Fase 0.
> Este arquivo é o contrato entre as sessões do Claude Code — atualize
> o STATUS de cada fase ao concluir.

## Leitura estratégica (contexto para qualquer sessão futura)

O server.js contém DOIS sistemas fundidos:
- **Legado / operação da agência** (grupos 2–8): serve só o tenant
  Casagora. Admin panel, relatórios Meta Ads, exports WhatsApp (PDFs
  diários — função crítica), sync noCRM via systemd timer.
- **Produto v2 multi-tenant** (grupos 9–19): o CRM SaaS novo. Todo o
  desenvolvimento ativo está aqui.

O estrangulamento já está em curso (v2 sobre legado). Este plano o
torna explícito e o conclui. NÃO é uma reescrita: o server.js continua
em produção durante todo o processo.

Decisão pendente de negócio (não bloqueia Fases 0–2): padronizar
billing em Asaas (já integrado, sandbox) vs Stripe — afeta o produto
de disparos, não este repo diretamente.

---

## FASE 0 — Rede de segurança  [STATUS: CONCLUÍDA em 19/07/2026 — pendente só o merge para main, decisão do Vagner]
Sem testes hoje. Nada pode ser refatorado no escuro.

Todo o trabalho está na branch `diagnostico` do `casagora-router`
(commits `7ce37fb` já mergeado via PR #11; `07ccea8`, `2324792`,
`e0e4c79` ainda não mergeados — merge para `main` é decisão consciente
do Vagner, não feito automaticamente por design).

1. ✅ **Golden master das rotas vivas** (concluído 19/07/2026, mergeado
   em `main`): script de testes de caracterização que bate nas rotas
   principais de cada grupo vivo (auth, webhooks intake, v2
   deals/leads/dashboard, exports whatsapp) e grava as respostas como
   snapshot. Objetivo NÃO é testar "certo/errado" — é detectar mudança
   de comportamento.
   Local: `casagora-router/test/golden-master/` (`routes.mjs` +
   `run.mjs` + `README.md` + `snapshots/baseline.json`). 45 rotas nos 4
   grupos. Rotas de mutação/envio real (whatsapp, webhooks) só testam o
   caminho de guarda (sem token/assinatura) por design — nunca criam
   lead real nem disparam WhatsApp real; ver README do script. Uso:
   `npm run golden-master` (opcional `--update-baseline`).
   **Re-executado em 19/07/2026 ao fechar a fase: 0 diffs contra
   produção.**
2. ✅ **Lint mínimo + CI** (concluído 19/07/2026, branch `diagnostico`):
   `eslint.config.js` liga só `no-undef` (error) e `no-unused-vars`
   (warn) — zero regra de estilo. `npm run lint` roda 0 erros / 26
   warnings (variáveis não usadas em `catch`, deixadas como estão,
   conforme combinado). **O lint achou um bug real de escopo**
   (`enriched` referenciado fora do try onde era declarado, no handler
   de `/webhook/facebook` — o alerta de admin em falha de roteamento
   nunca saía com contexto, às vezes nem saía) e uma linha de debug
   morta em `/health` — os dois corrigidos (commit `2324792`).
   `.github/workflows/ci.yml`: roda lint + `node --check src/server.js`
   em todo push nas branches `main`/`diagnostico`. Golden master
   **não** roda em CI, por decisão consciente: bate em produção real e
   o manifesto de rotas é editável em PR — automatizar isso cria vetor
   pra um PR (malicioso ou só com bug) disparar o CI contra produção.
   Continua manual, antes de cada merge (documentado no topo do
   workflow e no README do golden master).
3. ✅ **`npm start` local corrigido** (concluído 19/07/2026, commit
   `07ccea8`): `package.json` apontava `"main"`/`start` para
   `server.js` (inexistente na raiz); corrigido para `src/server.js`.
   Só funcionava no Docker porque o `Dockerfile` copia
   `src/server.js` → `/app/server.js` e o `CMD` chama `node` direto
   (não usa `npm start`) — por isso o bug nunca afetou produção.
   Validado subindo `node src/server.js` contra um Postgres 17
   descartável: conecta e roda migrações reais de `ensureSchema()`.
   **Achado lateral, fora do escopo deste item**: `ensureSchema()` não
   bootstrapa um banco vazio do zero (pelo menos 3 gaps confirmados —
   coluna `app_settings.tenant_id`, tabelas `lead_crm_import` e
   `app_users` nunca criadas pelo próprio código, só existem em
   produção por migração manual fora de banda). Registrado como P5 em
   `DECISOES.md`, não bloqueia este item nem produção.
4. ✅ **Varredura de segredos** (concluído 19/07/2026): código atual +
   histórico git completo (`git log --all`) de `casagora-router` (340
   commits) e `casagora-sistema` (261 commits). `casagora-router`:
   limpo, zero segredo hardcoded em qualquer commit — tudo já lido de
   `process.env`. `casagora-sistema`: **achado crítico** — senha real
   de produção do Postgres (`DATABASE_URL`, usuário `arkontech`) e
   chave secreta real do Cloudflare Turnstile expostas em texto puro
   num doc de planejamento (`docs/superpowers/plans/2026-07-02-lp-captacao-leads-plan.md`,
   commit `d52c8b4`, 02/07/2026). Redigido no arquivo atual (commit
   `5d96f00` nesse repo, branch `diagnostico`, **não pushado** — fora
   do escopo de push desta sessão). Ambas as credenciais **precisam
   ser trocadas manualmente pelo Vagner** (histórico git é permanente).
   Relatório completo, sem nenhum valor de segredo:
   `arkontech-docs/crm/segredos-relatorio.md`.

Critério de conclusão original ("golden master roda verde no CI") foi
ajustado na prática: golden master roda **verde manualmente** (0 diffs
confirmado 19/07/2026), CI cobre lint + smoke de sintaxe — ver item 2
para o porquê de golden master ter ficado fora do CI. Deploy de uma
mudança trivial ainda não foi testado ponta a ponta pelo pipeline
(só existe desde hoje); primeira vez que alguém fizer um deploy real
depois do merge serve como validação.

---

## FASE 1 — Terminar as migrações paradas  [STATUS: pendente]
Regra: terminar antes de começar coisa nova. São duas:

### 1A — Auth (a maior dívida)
Hoje: sessões cookie legadas (/app, /admin) + JWT v2 sem refresh
revogável + no frontend, JWT 30 dias em cookie não-httpOnly + login
em duas etapas + regras duplicadas em middleware.ts e Sidebar.tsx.

Passos:
1. Backend: implementar refresh token revogável no v2 (tabela de
   sessões no Postgres, rotação, logout real).
2. Frontend: migrar para cookie httpOnly + fluxo único de login
   (elimina as duas etapas). Unificar as regras de acesso em um só
   lugar consumido por middleware e Sidebar.
3. Migrar /admin e /app para o mesmo mecanismo (mantendo o escopo
   "tenant Casagora only" do admin — é decisão consciente, preservar).
4. Remover o código da auth legada quando nenhum caminho a usar.

Critério: uma única geração de auth no código; login em um passo;
token de sessão inacessível ao JavaScript; logout revoga de verdade.

### 1B — noCRM (migração 10 do frontend)
1. Levantar o que falta da migração (o .planning/phases/10-* documenta).
2. Concluir, validar o desligamento com nocrm_create_enabled OFF e o
   fluxo de leads 100% interno (commit 4ebaaf9 já removeu a dependência
   de deal creation — confirmar o resto).
3. Aposentar o sync/reconcile do noCRM (grupo 4) quando nada mais
   depender — com cuidado: hoje é infra crítica (timer 15min).

Critério: sistema opera com noCRM desligado por 2 semanas sem
incidente; jobs de sync removidos do systemd.

---

## FASE 2 — Matar a duplicação de relatórios  [STATUS: pendente]
Grupos 5/6 (legado, 18 rotas) e grupo 12 (v2, 12 rotas) expõem a mesma
lógica duas vezes.

1. Extrair a lógica de relatório para um módulo interno único
   (`src/reports/` — primeira quebra física do monolito).
2. Fazer as rotas legadas e as v2 consumirem o mesmo módulo.
3. Golden master garante respostas idênticas antes/depois.
4. Deprecar as rotas legadas quando o admin panel consumir as v2.

Critério: uma implementação de relatórios; contagem de linhas do
server.js cai de forma mensurável.

---

## FASE 3 — Confirmar mortes e limpar anomalias  [STATUS: pendente]
1. **Regerar o censo completo das rotas** (grupo, método, path, auth,
   evidência vivo/morto) e salvar em `arkontech-docs/crm/censo-rotas.md`.
   O censo original de julho/2026 (203 rotas, 19 grupos, citado no
   cabeçalho deste plano) nunca foi persistido como arquivo — só o
   resumo condensado sobreviveu (ver DECISOES.md, decisão resolvida
   19/07/2026). Este passo produz o substituto definitivo, já no
   lugar certo.
2. **Grupo 2 (app legado)**: instrumentar com contador de acessos por
   rota durante 2 semanas. Zero acessos → remover. Houve acesso →
   descobrir quem e migrar para o v2 equivalente.
3. **PATCH /api/v2/crm/tasks/:id órfão**: confirmar se algo cria
   tasks por outro mecanismo; senão, remover.
4. **Role ANALYST**: formalizar nas DIRETRIZES (§3) ou remover do
   código — sincronizar a lista canônica de roles.
5. Atualizar ARCHITECTURE.md / API_ROUTES.md / DATABASE.md para a
   realidade (ou substituí-los por um doc gerado do censo do item 1).

Critério: nenhum grupo "incerto" no censo; docs batem com o código.

---

## FASE 4 — Modularizar o server.js  [STATUS: pendente]
Só agora, com testes, auth única e sem duplicação, quebrar o arquivo:

1. Um diretório por grupo funcional vivo (auth/, webhooks/, crm/,
   reports/, admin/, billing/...), extraindo na ordem: do menos
   acoplado (webhooks intake) ao mais central (auth por último —
   já estará limpa da Fase 1).
2. Uma extração por PR, golden master verde em cada uma.
3. server.js termina como composição de routers (~centenas de linhas,
   não milhares).

Critério: nenhum arquivo > 1.000 linhas; navegação por estrutura,
não por grep.

---

## FASE 5 — Fronteira com a plataforma de disparos  [STATUS: pendente]
(Depende do produto novo existir — ver projeto separado.)

1. **Exports WhatsApp (grupo 7)** migra para workflow n8n da
   plataforma de disparos (agendado, gera PDF, envia via Evolution).
   O CRM chama a plataforma por API — vira o primeiro cliente dela.
2. **Webhooks de intake (grupo 8)** passam a alimentar também a base
   de contatos da plataforma (tags de origem: facebook, webchat, lp).
3. Avaliar unificação de billing (Asaas vs Stripe) entre os produtos.

Critério: WhatsApp do CRM roda pela plataforma; um só lugar para
evoluir tudo que é mensagem.

---

## Regras permanentes (valem em toda sessão)
- Trabalhar sempre em branch; main é produção.
- Golden master ANTES e DEPOIS de cada mudança de comportamento.
- Banco de produção: somente leitura, salvo migração planejada e
  com backup tirado no momento.
- Preservar decisões conscientes documentadas (admin panel single-
  tenant; escopos do DIRETRIZES.md).
- Ao concluir uma fase: atualizar STATUS aqui + registrar no CHANGELOG.
