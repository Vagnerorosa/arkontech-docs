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

## FASE 0 — Rede de segurança  [STATUS: em andamento — item 1 concluído em 19/07/2026, itens 2-4 pendentes]
Sem testes hoje. Nada pode ser refatorado no escuro.

1. ✅ **Golden master das rotas vivas** (concluído 19/07/2026): script de
   testes de caracterização que bate nas rotas principais de cada grupo
   vivo (auth, webhooks intake, v2 deals/leads/dashboard, exports
   whatsapp) e grava as respostas como snapshot. Rodar contra o
   container atual. Objetivo NÃO é testar "certo/errado" — é detectar
   mudança de comportamento.
   Local: `casagora-router/test/golden-master/` (`routes.mjs` + `run.mjs`
   + `README.md` + `snapshots/baseline.json`), commitado na branch
   `diagnostico` desse repo (commit `7ce37fb`, ainda não pushado para
   origin). 45 rotas cobertas nos 4 grupos. Baseline gerado e validado
   contra produção (`https://api.imovizapp.com`): rodou duas vezes,
   0 diffs na segunda. Rotas de mutação/envio real (whatsapp, webhooks)
   só testam o caminho de guarda (sem token/assinatura) por design —
   nunca criam lead real nem disparam WhatsApp real; ver README do
   script para o porquê rota a rota. Uso: `npm run golden-master`
   (opcional `--update-baseline` para aceitar mudança intencional como
   novo baseline).
2. **Pendente — Lint mínimo** (eslint com regras frouxas) + **CI
   simples** que roda golden master (já existe, item 1) e lint em cada
   push.
3. **Pendente — Consertar o `npm start` local**: `package.json` aponta
   `"main"`/`start` para `server.js`, mas o arquivo real é
   `src/server.js` — só funciona no Docker hoje (achado confirmado em
   19/07/2026 ao mexer no golden master).
4. **Pendente — Varredura de segredos**: procurar credenciais hardcoded no código
   e no histórico git. Mover para .env; TROCAR as senhas expostas
   (histórico git é permanente).

Critério de conclusão: golden master roda verde no CI; deploy de uma
mudança trivial passa pelo pipeline.

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
