# DECISÕES — registro vivo

Formato: cada decisão tem contexto, escolha e consequência. Decisões
pendentes ficam no topo até serem resolvidas.

## ⏳ Pendentes

### P1 — Billing do produto de disparos: Asaas ou Stripe?
Contexto: o plano original era Stripe (Checkout + Customer Portal).
O censo do CRM revelou integração Asaas já escrita (grupo 19, em
sandbox). Asaas tem Pix/boleto nativos para o mercado BR; Stripe
facilita cobrança em USD (cliente loja de carros nos EUA).
Tendência: Asaas para BR reaproveitando código; Stripe só se/quando
a cobrança em dólar se concretizar. DECIDIR antes da etapa Painel (s6).

### P2 — Nome definitivo do CRM
"CRM Arkontech" é placeholder. Histórico de marcas no código:
imoviz → casagora. Padronizar nome/domínio/cookie em algum momento
da Fase 3 ou 4.

### P3 — Relação de portfólio CRM × plataforma de disparos
Direção definida (disparos é produto horizontal; CRM é cliente dela
— ver D3), mas o desenho fino da API entre eles será feito na Fase 5.

## ✅ Tomadas

### D1 — Sistema de disparos nasce FORA do CRM (18/07/2026)
Um produto multi-tenant próprio (schema novo no Postgres, workflows
n8n, Evolution), não um módulo do casagora. Motivo: o casagora tem
dívida técnica alta (monolito 15.800 linhas, auth dual); acorrentar
o produto novo a ele contaminaria o que nasce limpo.

### D2 — Estrangulamento gradual, não reescrita (18/07/2026)
O casagora continua em produção e evoluindo; módulos são extraídos
um a um com golden master como rede de segurança. Reescrita total
foi explicitamente descartada.

### D3 — Trilhas em paralelo após a Fase 0 (18/07/2026)
Só a F0 (rede de segurança) bloqueia. O MVP de disparos começa na s2
porque tem clientes pedindo (receita) e é independente por design.

### D4 — Terminar migrações antes de iniciar novas (18/07/2026)
Auth (dual → JWT v2 com refresh revogável) e noCRM vêm antes de
qualquer refatoração estética. Origem do login em duas etapas.

### D5 — Uma instância Evolution por cliente; opt-out global
estrutural; fila com FOR UPDATE SKIP LOCKED; telefones em E.164
(18/07/2026) — decisões de arquitetura do produto de disparos,
detalhadas em disparos/ARQUITETURA.md e schema.sql.

### D6 — LLM: chave única da Arkontech; cliente configura só
conteúdo (tom, contexto), nunca o prompt cru (18/07/2026).

### D7 — Login social: Google + e-mail/senha via Auth.js no
lançamento; Apple/Microsoft adiados (18/07/2026).

### D8 — DIAGNOSTICO.md/censo de rotas: não regerar agora, adiado para
Fase 3 (19/07/2026). Contexto: o censo de 203 rotas citado no
cabeçalho do `PLANO-ESTRANGULAMENTO.md` foi produzido em sessão
anterior mas nunca virou arquivo — busca completa no filesystem e no
histórico git (todas as branches, stashes) de `casagora-sistema` e
`casagora-router` não encontrou `DIAGNOSTICO.md` nem censo nenhum; só
sobreviveu o resumo condensado já embutido no plano. Contagem de
`app.<method>(` em `casagora-router/src/server.js` confirmou as 203
rotas. Escolha: não bloquear a Fase 0/1 regerando agora; o censo
completo (grupo, método, path, auth, vivo/morto) vira o item 1 da
Fase 3, salvo em `crm/censo-rotas.md`, quando fizer mais sentido
(depois da rede de segurança e das migrações, junto da limpeza de
anomalias que já depende de mapear rota por rota).

### D9 — P5 resolvida: aceitar snapshot como ponto de partida, não
consertar `ensureSchema()` para bootstrapar do zero (19/07/2026).
Contexto: P5 (achada 19/07/2026 ao validar o fix do `npm start`) tinha
duas opções — consertar `ensureSchema()` pra criar tudo do zero, ou
aceitar que dev/staging sempre partem de um snapshot real. Ao investigar
a rotina de backup diário (`arkontech-docs/crm/backups.md`), confirmamos
que essa segunda opção **já é a prática real e já funciona**:
`casagora-router-refresh-dev-db.sh` clona produção → dev todo dia às
02:30 UTC, e o backup diário pro R2 (testado com restauração completa em
19/07/2026 — 37 tabelas, dados íntegros, `app_users` e `lead_crm_import`
presentes) garante que existe sempre um snapshot restaurável fora da VPS.
Escolha: não investir em consertar `ensureSchema()` para bootstrap do
zero — o ganho seria só "dev local sem depender de snapshot", algo que
ninguém pediu e que a rotina de refresh diário já resolve de forma mais
realista (schema idêntico à produção, não uma aproximação). Reabrir só
se a Fase 4 (modularização) precisar de fato de um ambiente 100% do
zero para testes automatizados.

### D10 — Fase 1A (auth): respostas do Vagner às perguntas em aberto
(19/07/2026). Resolve as 6 perguntas de `crm/fase1-auth-plano.md`
(seção 5):
- **Q1 — `/admin` e `/app` legados**: manter como estão, **não**
  unificar com o mecanismo v2 novo. Resolve a contradição a favor do
  `DIRETRIZES.md §14` ("compatível, não precisa migrar"); o texto
  original do `PLANO-ESTRANGULAMENTO.md` (Fase 1A, passo 3) fica
  superado. O "Incremento 6" do plano de auth (unificação) não é mais
  "pendente de decisão" — está descartado.
- **Q2 — janela do Incremento 3** (o dual-deploy backend+frontend):
  madrugada de dia útil, com golden master antes e depois. Precaução
  extra mantida mesmo com a leitura de que sessões abertas não seriam
  interrompidas no momento do deploy.
- **Q3 — aviso aos usuários** sobre a expiração gradual de sessões
  antigas: sem banner. Fica silenciosa/individual, em até 30 dias,
  como já descrito no plano.
- **Q4 — rate limit no login**: 10 tentativas / 15 min confirmado,
  sem alteração.
- **Q5 — MFA/Passkeys**: confirmado fora do escopo da Fase 1A —
  continua no backlog do `DIRETRIZES.md §3`.
- **Q6 — os 3 gates de UX no cookie `imoviz_user`** (onboarding,
  `/analises/fila`, suspensão por inadimplência): aceitos como estão
  por ora. Registrado como item de follow-up para **depois** da
  Fase 1A — não bloqueia nada dela.

### D11 — Fase 1B (noCRM): escopo ampliado para migração de base antes
do desligamento (19/07/2026). Contexto: `crm/fase1-nocrm-plano.md`
assumia que bastava confirmar `nocrm_create_enabled=false` e desligar
os 4 mecanismos de sync. O Vagner esclareceu o motivo real de a
Casagora ainda gerenciar negócios pelo noCRM no dia a dia: a base
histórica — principalmente **comentários** e **anexos de documento**
por lead — nunca foi trazida para o Imoviz. Desligar sem isso perderia
o histórico de conversa/documentos de todo lead já trabalhado.
Fato verificado nesta sessão: o export nativo do noCRM (CSV/Excel)
inclui comentários (via checkbox de opção no export), mas **não
inclui anexos** — anexos só são acessíveis via API.
Escolha: novo escopo da Fase 1B passa a ser migração de base (leads
históricos + comentários + anexos) e um plano de adoção da equipe,
**antes** de qualquer desligamento. Os incrementos 3-5 do
`fase1-nocrm-plano.md` (desligar sync de agentes/usuários/leads/
webhook) ficam **bloqueados** até a base estar migrada e a equipe
operando 100% pelo Imoviz — deixam de ser o próximo passo lógico.
Estratégia de migração detalhada em `crm/fase1b-migracao-base.md`.
