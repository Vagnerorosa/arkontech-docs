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

### P5 (numeração pulada — já usada e resolvida, ver D9)

### P6 — `superadmin-login` sem segunda camada de defesa além do rate limit
Achado em 19/07/2026, junto com o P4 (agora resolvido, ver D13). O vetor
original do P6 (`superadmin-login` contornável via spoof de
`X-Forwarded-For`) **deixou de existir** com a correção do P4 — o rate
limiter agora é efetivamente por IP real. O que **sobra**, registrado em
20/07/2026: `POST /api/v2/auth/superadmin-login` nunca teve Turnstile
(decisão original: "painel interno, não é público") e continua com o
rate limiter (agora correto) como única barreira — um ataque distribuído
por IPs reais diferentes não é resolvido pelo P4 nem por rate limit em
geral. Hardening interino a avaliar (nenhum implementado ainda):
- Adicionar Turnstile também no `superadmin-login` (muda o contrato da
  rota — precisa de golden master atualizado e do frontend do painel
  superadmin ajustado para enviar o token).
- Allowlist de IP de origem pro painel superadmin (mais simples, e agora
  viável — o P4 garante que `req.ip` é confiável).
Sem prazo definido — decisão do Vagner.

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

### D12 — Corte final da migração de base noCRM: 5.730 leads,
refinamento de cancelados recentes NÃO adotado por ora (19/07/2026).
Contexto: com os 3 exports completos (145.619 leads, set/2019-jul/2026
sem buraco, ver `crm/fase1b-migracao-base.md` seção 2), o corte "completo"
(migração via API de comentários+anexos) ficou em **5.730 leads**
(`won` 1.581 + `todo` 1.631 + `standby` 2.518) — os outros 139.902
(`cancelled`+`lost`) ficam só com o registro raso do export nativo,
já obtido. Refinamento cogitado (promover `cancelled` dos últimos 12
meses pra completo, +20.796 leads, corte subiria pra 26.526) foi
**quantificado mas não adotado**: a base de 5.730 já cobre 100% do
pipeline vivo, e o refinamento é sobre leads já mortos cuja "chance de
reabordagem" é hipótese de negócio, não requisito técnico/compliance.
Reavaliar depois da migração base completa, se a equipe comercial pedir
reabordagem de cancelados recentes especificamente.

### D13 — P4 resolvida: Traefik corrigido pra confiar em `X-Forwarded-For`
só da Cloudflare, não de qualquer cliente (20/07/2026). Contexto: P4
(achada 19/07/2026) — o Traefik (`easypanel-traefik`, Swarm) tinha
`forwardedHeaders.insecure=true` nos entrypoints `http`/`https`,
confiando cegamente em qualquer `X-Forwarded-For` que o cliente mandasse,
sem exceção. Investigação (`crm/p4-traefik-runbook.md`) mapeou os 24
domínios atrás deste Traefik via `dig`: só o universo `*.imovizapp.com` +
`www.arkontech.com.br` passa pela Cloudflare — todo o resto (incluindo
`routercasagora.arkontech.com.br`, o domínio que expôs o bug) bate direto
na VPS. Escolha: `trustedIPs` = só os ranges publicados da Cloudflare
(v4+v6, sem incluir rede interna do Swarm — fronteira de confiança
diferente, já resolvida em cada app). Aplicado via `docker service
update` nas env vars do serviço (não há arquivo de config estática,
tudo vive na spec do Swarm). Validado: checklist de 19 serviços 19/19
idênticos ao baseline (2 já quebrados antes, não-regressão registrada);
harness de spoof no domínio direto confirmou bucket estável (9→8→7, era
sempre 9 antes); teste de bypass via domain-fronting contra domínio
Cloudflare confirmou headers forjados sendo ignorados (7→6, não
resetou); login real via Turnstile em `app.imovizapp.com` confirmado
pelo Vagner em 3 navegadores. Zero rollback necessário. Loose end
achado (fora do escopo): Zentara e `casagora_router_api_dev` têm rota
no Traefik apontando pra serviços que não existem mais no Swarm (502
pré-existente) — faxina futura, não bloqueante.

### D14 — Buscar histórico COMPLETO de comentários via API para os leads
truncados do corte de migração (21/07/2026). Contexto: o export nativo do
noCRM só traz os 4 comentários mais recentes por lead (achado em
`crm/fase1b-migracao-base.md` seção 2b) — 3.615 dos 5.750 leads do corte de
migração completa (won+todo+standby) batem nesse teto, incluindo **96% dos
`won`**. Escolha do Vagner: buscar o histórico completo via
`GET /leads/{id}/comments` para esses 3.615 leads especificamente (não os
5.750 inteiros), porque o dado fica **irrecuperável depois que a assinatura
do noCRM for cancelada** (ver plano de adoção, `fase1b-migracao-base.md`
seção 7) — ao contrário de anexos (que já são tratados como job de API por
padrão), esse era um gap que o export sozinho não cobria. Esforço: ~3.615
requisições, ~2 dias corridos de orçamento de API (2.000/dia) — pequeno
comparado ao job de anexos (6-9 dias) e combinável com ele (mesmo lead,
mesma janela de execução, mesmo mecanismo de fila com retomada).

### D15 — Etapas do Kanban do Imoviz são as MESMAS do funil do noCRM,
mapeamento ~1:1 (21/07/2026). Contexto: `deal_stages` do Imoviz (tenant
Casagora) tem 9 etapas (`01 - Lead não Atendido` … `09 - Assinado`); o
export do noCRM tem uma coluna `Step` com exatamente 9 valores distintos,
todos os 145.719 leads num único `Pipeline` (`Funil de Vendas`). Comparação
nome a nome (`crm/fase1b-migracao-base.md` seção 8.1): **os 9 valores batem
1:1** com os 9 `deal_stages`, a menos de acentuação/capitalização em 2 deles
(`05 - Enviado para Analise`/`06 - Em analise` no CSV vs `Análise` com
acento nos `deal_stages`) — normalizar no import (comparação
case/acento-insensível), não é uma etapa sem correspondente. Resolve a
pergunta em aberto da seção 8.1/8.4 (mapear `Step`→etapa vs jogar tudo numa
etapa default): mapear de verdade, é direto e o dado já bate.

### D16 — Telefone duplicado é regra no noCRM (negociações distintas da
mesma pessoa), NÃO deduplicar por telefone (21/07/2026). Contexto: a seção
8.4 antiga levantava risco de duplicata entre um `deal` já existente no
Imoviz e um lead migrado com o mesmo telefone. O Vagner esclareceu que
telefone repetido no noCRM é **intencional** (o mesmo cliente pode ter mais
de uma negociação/lead ativa ao longo do tempo) — deduplicar por telefone
juntaria negociações que devem continuar separadas. **Chave de identidade
do import é `nocrm_lead_id`** (único por construção, já é `UNIQUE` em
`lead_crm_import`) — dedup/idempotência do import é só contra
re-importação do mesmo `nocrm_lead_id`, nunca por telefone. Como nenhum
`deal` existente hoje tem origem no noCRM (achado da seção 8.1: `deals` e
`lead_crm_import` são estruturas paralelas sem link), não há risco de
colisão com dado pré-existente — todo lead do corte de migração gera um
`deal` novo, sem checagem de duplicata por telefone.
