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

### P4 — DIAGNOSTICO.md e censo de rotas nunca foram persistidos (19/07/2026)
O censo de 203 rotas citado no cabeçalho do `PLANO-ESTRANGULAMENTO.md` foi
produzido em sessão anterior, mas nunca virou arquivo — busca completa no
filesystem e no histórico git (todas as branches, stashes) de
`casagora-sistema` e `casagora-router` não encontrou `DIAGNOSTICO.md` nem
nenhum arquivo de censo. Só sobrou o resumo condensado já embutido no plano.
O número de rotas (203) foi reconferido em 19/07/2026 contando
`app.<method>(` em `casagora-router/src/server.js` — bate exatamente.
DECIDIR: regerar o censo detalhado (por grupo/rota) como arquivo em
`crm/` ou aceitar o resumo do plano como suficiente e seguir sem ele.

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
