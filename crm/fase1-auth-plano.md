# FASE 1A — Auth unificada: levantamento e plano de execução

> Sessão de levantamento, 19/07/2026. **Nenhum código foi alterado para produzir este
> documento.** Cobre `casagora-router` (backend) e `casagora-sistema/frontend` (Next.js).
> Consumir junto com `crm/PLANO-ESTRANGULAMENTO.md` (Fase 1) e `/root/DIRETRIZES.md` §3
> (desenho-alvo já decidido em 11/07/2026, não redesenhado aqui).

## Achado que muda o ponto de partida

Já existe um plano de implementação **completo, código a código, nunca executado**:
`casagora-sistema/docs/superpowers/plans/2026-07-11-jwt-session-revocation.md` (13 tasks,
checkboxes todos `[ ]`). Ele implementa exatamente o desenho do `DIRETRIZES.md §3`
(access token 15min + refresh token opaco revogável em `app_sessions`, rotação a cada uso,
rate limiting). Conferido linha a linha contra o `src/server.js` atual — **as referências de
linha e os trechos "antes" ainda batem com o código de hoje** (ex.: login em
`src/server.js:10310-10360`, confirmado neste levantamento).

Por isso este documento **não redesenha a arquitetura** — ela já está decidida e detalhada.
O que faltava, e é o foco daqui, é: (1) inventariar o estado atual com precisão, (2) mapear
quem consome cada geração de auth, (3) **resequenciar as 13 tasks em incrementos de deploy
seguros e independentemente testáveis** (a numeração original agrupa por arquivo, não por
"o que dá pra subir em produção sem quebrar nada no meio do caminho" — ver seção 4), e
(4) resolver contradições encontradas entre documentos.

## 1. Inventário do estado atual

### 1.1 Sessão cookie legada (`/app`, `/admin`) — só tenant Casagora

Fluxo: `POST /app/login` (form HTML, `src/server.js:3666`) → valida email/senha
(`scrypt`) → gera token opaco (`crypto.randomBytes(32)`) → grava hash SHA-256 em
`app_sessions(user_id, token_hash, expires_at)` → cookie `cg_session` **httpOnly**, 30 dias.
Isso **já é** o padrão access+refunável (token opaco, revogável, tabela de sessão) — é
justamente o modelo que a migração 1A quer levar para o v2. `POST /app/logout` apaga a linha
de `app_sessions`.

Três funções de guarda distintas, todas lendo `cg_session`/`app_sessions`, com lógica
parcialmente duplicada entre si (não só entre frontend e backend):
- `requireUser` (`server.js:1715`) — qualquer usuário logado; usado em 9 rotas `/app/*`.
- `requireUserAdmin` (`server.js:1710`) — camada extra de `is_admin`; empilhada com
  `requireUser` em 3 dessas 9 rotas (ex.: `/app/dashboard`).
- `requireAdmin` (`server.js:1669`) — aceita `ADMIN_TOKEN` (query/header) **ou** a mesma
  sessão `cg_session`; usado em 65 rotas `/admin/*` (painel, relatórios, exports WhatsApp,
  sync noCRM). Reimplementa a mesma consulta a `app_sessions` que `requireUser` já faz.
- Restrição consciente e documentada (preservar): `requireAdmin` só aceita sessão cujo
  `tenant_id === DEFAULT_TENANT_ID` — o painel `/admin/*` é **single-tenant Casagora**, nunca
  multi-tenant. Comentário no próprio código explica o porquê (vazamento de dado entre
  tenants concorrentes).

**Achado de infraestrutura relevante**: `app_sessions` é usada extensivamente mas **nunca é
criada por `ensureSchema()`** — mesma classe de lacuna já registrada como P5/D9 em
`DECISOES.md`. Não bloqueia nada (a tabela existe em produção), mas confirma que qualquer
migração que dependa dela rodar num ambiente "do zero" precisa partir de um snapshot (a
rotina de backup diário já cobre isso, ver `crm/backups.md`).

### 1.2 JWT v2 (`/api/v2/auth/*`) — multi-tenant, sem revogação

Quatro pontos emitem JWT hoje, todos **assinam um token único de vida longa** (não há
refresh token nem `app_sessions` envolvida):

| Rota | Linha | Expiração | Observação |
|---|---|---|---|
| `POST /api/v2/auth/login` | 10310 | 30d | Login principal do frontend (`app.imovizapp.com`) |
| `POST /api/v2/auth/superadmin-login` | 10364 | 8h | Painel superadmin, sem Turnstile (não é público) |
| `POST /api/v2/auth/change-password` | 10530 | 30d | Reemite token após 1º acesso (ver "duas etapas" abaixo) |
| `GET /api/v2/auth/me` | 10754 | 30d | **Mitigação de 11/07** — reemite token com claims frescas a cada chamada |

Guardas usadas nas rotas v2: `requireJWT` (106 rotas — só confere assinatura/prazo, sem
tocar banco), `requireJWTv2` (5 rotas — igual, mas também exige `tenant_id` no payload salvo
para `SUPERADMIN`), `requireAdminRole` (29 rotas, empilhada sobre `requireJWT` — exige
`role IN (ADMIN, SUPERADMIN)`), `requireSuperadmin` (rotas `/api/v2/admin/tenants/*`).
27 rotas são públicas (webhooks, intake, `/health`, os 4 endpoints de auth de entrada).

**"Login em duas etapas" — o que é, exatamente**: não são duas chamadas ao mesmo endpoint.
É `POST /api/v2/auth/login` (retorna `must_change_password: true` para quem nunca trocou a
senha) → frontend força redirect pra `/change-password` (`middleware.ts:61`) → usuário
submete nova senha → `POST /api/v2/auth/change-password` emite um **segundo JWT**, agora com
`must_change_password: false`. Dois round-trips de rede, dois tokens emitidos, para o mesmo
login. O plano de 11/07 (Task 1) unifica isso: `/api/v2/auth/login` já pode devolver o
access+refresh de uma vez, e o flag `must_change_password` no payload já é suficiente para o
middleware decidir redirecionar — a segunda emissão de token deixa de ser necessária como
"segunda etapa de login", vira só "trocar senha", igual qualquer outra ação autenticada.

**Correção a uma imprecisão do `PLANO-ESTRANGULAMENTO.md`**: o texto da Fase 1 diz "JWT 30
dias em cookie **não-httpOnly**". Não é verdade no código atual — `lib/auth.ts` já seta
`httpOnly: true` desde o commit `e940cc6` (fundação do projeto, 02/2026). O cookie sempre foi
httpOnly. O problema real nunca foi exposição a XSS via `localStorage`/cookie legível — é a
**ausência de revogação** (um JWT de 30 dias, uma vez emitido, não pode ser invalidado antes
de expirar) — é isso que o access+refresh resolve. Atualizar o texto da Fase 1 no
`PLANO-ESTRANGULAMENTO.md` para não repetir essa imprecisão (feito ao final desta sessão).

### 1.3 Frontend: `middleware.ts` + `Sidebar.tsx` — duplicação real, confirmada

`middleware.ts` (`ROLE_ROUTE_RULES`, 13 entradas por prefixo de URL) e `Sidebar.tsx`
(filtro item a item: `brokerOnly`, `managerOnly`, `analystOnly`, arrays de role por seção)
implementam **duas estruturas de dados diferentes** para a mesma pergunta ("quem pode ver
X"). Não é exagero do plano — são literalmente dois formatos incompatíveis mantidos à mão em
paralelo; mudar uma regra de acesso hoje exige lembrar de editar os dois arquivos.

`middleware.ts` também confia em `imoviz_user` (cookie **não-httpOnly**, alterável no
navegador) para os gates de onboarding, `/analises/fila`, suspensão por inadimplência
(`/conta-suspensa`) — só o gate de **role** usa o JWT assinado (`payload.role`, confiável).
Isso não está no escopo original da Fase 1 (que fala de geração de token, não desses gates
específicos), mas é uma superfície de adulteração client-side que vale registrar: um usuário
podendo editar `document.cookie` pode, hoje, se auto-declarar `onboarding_completed: true` ou
apagar `payment_overdue_since` do cookie e passar pelos gates correspondentes (o gate de
*role*, que é o que decide acesso a dados, continua seguro — isso afeta só esses 3 gates de
UX/fluxo). Fora do escopo desta Fase 1A por definição do plano original; listado como
pergunta para o Vagner na seção 5.

## 2. Tabela de consumidores por grupo

O censo formal por rota (203 rotas, 19 grupos) nunca foi persistido como arquivo — ver
`DECISOES.md` D8, regeneração planejada para a Fase 3 item 1. A tabela abaixo agrupa pelo
mecanismo de guarda real encontrado no código (mais confiável agora do que tentar
reconstruir de memória os 19 grupos exatos) — é a granularidade que importa para decidir
*o que este incremento de auth afeta*.

| Grupo (mecanismo de guarda) | Rotas | Tenant-scoped? | Afetado pela Fase 1A? |
|---|---|---|---|
| Cookie legado `/app/*` (`requireUser`/`requireUserAdmin`) | 9 | Não (só Casagora) | Não — DIRETRIZES.md §14 marca como "compatível, não precisa migrar" (ver contradição, seção 5) |
| Painel `/admin/*` (`requireAdmin`, token ou cookie) | 65 | Não (single-tenant, decisão consciente) | Não — mesma nota acima |
| V2 JWT simples (`requireJWT`) | 106 | Parcial (via `req.jwtUser.tenant_id` nas queries, não no middleware) | **Sim, diretamente** — todas essas rotas passam a aceitar o novo access token no lugar do JWT de 30d |
| V2 JWT + admin role (`requireJWT`+`requireAdminRole`) | 29 (subconjunto dos 106) | Idem acima + role | **Sim** — mesma migração, camada extra inalterada |
| V2 JWT estrito (`requireJWTv2`, exige `tenant_id`) | 5 | Sim, no middleware | **Sim** — mesma migração |
| Superadmin (`requireJWTv2`+`requireSuperadmin`) | ~10 (dentro dos 5+106) | N/A (global) | **Sim** — `superadmin-login` também ganha refresh (Task 2 do plano de 11/07) |
| Público (webhooks, intake, `/health`, entrypoints de auth) | 27 | N/A | Não diretamente — só os 4 endpoints de auth mudam de *shape* de resposta (ver seção 4) |

Total de rotas v2 afetadas pela troca de mecanismo de token: **111** (106 + 5). Nenhuma
rota legada (`/app`, `/admin`) muda de comportamento neste plano, por decisão já registrada
em `DIRETRIZES.md` — ver contradição a resolver na seção 5.

## 3. Desenho do estado final

Já decidido em `DIRETRIZES.md §3` (11/07/2026) — resumo, não redesenho:

- **Access token**: JWT, 15 min, stateless (claims: `id`, `email`, `role`, `tenant_id`,
  `is_admin`, `agent_id`, `must_change_password`, `agent_nocrm_user_id` — mesmo shape de
  hoje, só a expiração muda).
- **Refresh token**: string opaca (`crypto.randomBytes(32)`), 30 dias, hash SHA-256 em
  `app_sessions` (reaproveitada — mesma tabela do login legado, **sem migração de schema**).
  Rotacionado a cada uso (token antigo ganha grace period de 10s, depois morre).
- **Revogação real**: `DELETE FROM app_sessions` em logout, desativação de usuário, reset de
  senha. Janela residual aceita: até 15 min (o access token já emitido continua válido até
  expirar — mesmo trade-off do Google/GitHub/Auth0, documentado e aceito).
- **Cookies**: `imoviz_token` (access) e `imoviz_refresh` (novo, refresh) — ambos httpOnly,
  secure em produção, sameSite lax, **em cookies separados**. `imoviz_user` continua não-
  httpOnly (só para exibição client-side, nunca para decisão de acesso).
- **Renovação silenciosa**: `middleware.ts` verifica o access token; se faltar menos de 2 min
  para expirar (ou já expirado), chama `/api/v2/auth/refresh` antes de decidir a rota —
  usuário nunca vê tela de login por causa de expiração natural do access token.
- **Rate limiting**: 10 tentativas/15min por IP nas 4 rotas de login (`express-rate-limit`,
  nova dependência) — achado em 11/07 que não existia em nenhum fluxo.
- **`/admin` e `/app` legados**: **preservados como estão** (sessão `cg_session` +
  `app_sessions`, single-tenant Casagora) — ver contradição na seção 5, é a leitura mais
  recente (`DIRETRIZES.md`, pós-incidente) mas precisa confirmação porque o
  `PLANO-ESTRANGULAMENTO.md` diz o oposto.

## 4. Plano de execução em incrementos pequenos

Reordena as 13 tasks de `docs/superpowers/plans/2026-07-11-jwt-session-revocation.md` (que
já tem o código pronto, revisado linha a linha nesta sessão) em **estágios de deploy**, do
menor ao maior risco. Cada estágio: mudança mínima, critério de validação via golden master,
e rollback explícito.

### Incremento 1 — Rate limiting nas rotas de login
**Escopo**: só backend, Task 7 do plano existente. Não muda formato de request/response de
nenhuma rota.
**Risco**: mínimo — pura adição de middleware, nenhum contrato muda.
**Validação**: golden master atual (login com corpo vazio → mesmo erro de sempre, guarda
inalterada); manual: 11 tentativas seguidas de login errado → 11ª retorna `too_many_attempts`.
**Rollback**: reverter a imagem — sem estado persistente envolvido.

### Incremento 2 — Endpoints novos e inertes: `/api/v2/auth/refresh` e `/api/v2/auth/logout`
**Escopo**: só backend, Tasks 3-4. Rotas **novas**, nada as chama ainda (login continua
emitindo só o token de 30d de sempre). Zero mudança em rota existente.
**Risco**: mínimo — são rotas adicionadas, não modificadas; se algo der errado, só essas 2
rotas ficam com bug, o resto do sistema é indiferente à sua existência.
**Validação**: adicionar as 2 rotas ao golden master (`refresh` sem `refresh_token` → 400;
`logout` sem `refresh_token` → 200 `{ok:true}`, é idempotente por design). Golden master do
resto do sistema continua em 0 diffs.
**Rollback**: reverter a imagem — as 2 rotas somem, nada as consumia.

### Incremento 3 — CRÍTICO: login emite access+refresh, frontend passa a usar
**Escopo**: backend Tasks 1-2 (login e superadmin-login passam a emitir os dois tokens) +
frontend Tasks 8-11 (`lib/auth.ts`, `login/route.ts`, `types/auth.ts`, `middleware.ts` com
renovação silenciosa, `logout/route.ts`). **Este é o único incremento que precisa dos dois
repositórios subindo na mesma janela** — não dá pra separar mais sem reintroduzir
complexidade (backend sozinho quebraria sessões em ~15min, ver análise abaixo).

**Por que não dá pra fatiar mais**: se o backend mudar sozinho primeiro, o frontend antigo
ainda lê `response.data.token` (ignora o novo campo `refresh_token`) e grava esse valor no
cookie `imoviz_token` com `maxAge` de 30 dias — mas agora `token` é o access token de
**15 minutos**. Resultado: todo usuário loga e é deslogado ~15 min depois,
indefinidamente, até o frontend também subir. Testado via leitura de código (Task 1 gera
`token` = access de 15min; `lib/auth.ts` atual não sabe disso). Se o frontend mudar sozinho
primeiro, ele espera `refresh_token` na resposta do login que o backend antigo não manda —
`createSession` quebraria por `undefined`. Ordem de deploy dentro do incremento: backend
primeiro (rotas novas ficam ativas mas o frontend antigo ainda funciona igual, porque ele só
lê `token`/`user`, ignora campos novos), frontend logo em seguida (minutos, não dias, de
diferença) — a janela de risco é só o formato do cookie do usuário que logar exatamente
nesse intervalo, não uma quebra sistêmica.

**Estratégia de transição para sessões já abertas — não é um "corte"**: o JWT antigo de 30
dias, uma vez emitido, continua sendo um JWT válido e assinado pelo mesmo `JWT_SECRET`, com
o mesmo formato de payload que o novo access token. O `middleware.ts` novo verifica o token
do cookie (`jwtVerify`); se o prazo restante for maior que 2 minutos — **o que é o caso de
qualquer sessão antiga recém-logada, já que ela tem até 30 dias de validade** — aceita
normalmente, sem tentar refresh. **Ninguém é deslogado no momento do deploy.** O corte real
acontece de forma passiva e individual: quando o JWT antigo daquele usuário específico
expirar (em até 30 dias, dependendo de quando foi o último login dele), o middleware tenta
renovar via `imoviz_refresh` — que não existe para sessões pré-migração — e só então pede
login de novo, **uma única vez**. Isso é bem menos disruptivo do que o texto do Task 13 do
plano de 11/07 sugere ("quem tiver sessão aberta vai precisar logar de novo uma vez [no
deploy]") — na prática é gradual, não imediato. Vale confirmar com o Vagner se um aviso
(banner "sua sessão será renovada automaticamente") é desejado mesmo assim, ou se passivo
está bom (pergunta na seção 5).

**Validação**: golden master do grupo `auth` precisa de atualização (login passa a retornar
`refresh_token` no corpo — mudança de *shape* esperada e intencional, não um diff a temer;
rodar com `--update-baseline` depois de confirmar que é a mudança certa). Teste manual
completo do Task 12 do plano de 11/07 (login retorna os 2 tokens, expiração de 15min
confere, refresh troca o par, token antigo morre após 10s, logout revoga, rate limit
bloqueia na 11ª tentativa, desativar usuário invalida refresh) — script pronto, só rodar.
**Rollback**: reverter as duas imagens (backend+frontend) juntas. Quem ainda não passou por
um refresh volta a ter só o token antigo válido até expirar (gracioso). Quem já rotacionou
(tem só `imoviz_refresh`, token antigo já descartado) — cenário raro de precisar de rollback
*depois* de já ter rotacionado alguém — perde a sessão e precisa logar de novo; aceitável
para uma janela de rollback de emergência.

### Incremento 4 — Revogação real em desativação/reset de senha
**Escopo**: só backend, Task 6. Depende do Incremento 3 já estar estável em produção (senão
`app_sessions` não está sendo populada pelo fluxo novo ainda).
**Risco**: baixo — muda um efeito colateral interno (delete adicional), nenhuma rota pública
muda de shape de resposta.
**Validação**: golden master sem diffs (nenhuma resposta observável muda). Manual: desativar
usuário de teste → tentativa de refresh com o token dele → `invalid_refresh_token`.
**Rollback**: reverter a imagem — o delete extra simplesmente para de acontecer.

### Incremento 5 — Remover a mitigação de 11/07 (`/auth/me` volta a ser leitura)
**Escopo**: backend + frontend, Task 5. Só fazer depois do Incremento 3 rodar estável por um
tempo (dias, não uma sessão de deploy) — o refresh silencioso já cobre a necessidade que a
mitigação resolvia; manter os dois mecanismos rodando ao mesmo tempo é repetir o problema
original ("dois sistemas de auth coexistindo sem decisão consciente").
**Risco**: baixo-médio — muda o *shape* da resposta de `GET /api/v2/auth/me` (deixa de
retornar `token`). Qualquer código que ainda espere esse campo quebra.
**Validação**: golden master do grupo `auth` precisa de nova atualização de baseline
(`auth.v2-me.get` muda de shape). `grep -rn "auth/me\|/api/profile"` nos dois repos antes de
mexer, para confirmar que nenhum outro consumidor além do já mapeado depende do campo
`token` nessa resposta.
**Rollback**: reverter as duas imagens — a mitigação volta, sem perda de dado (é só
reemissão de token).

### Incremento 6 (decisão pendente, não codar sem resposta) — Unificar `/admin`/`/app`
Descrito no `PLANO-ESTRANGULAMENTO.md` original como passo 3 da Fase 1A, mas
`DIRETRIZES.md §14` marca como "compatível, não precisa migrar". **Não planejado em detalhe
aqui** até a pergunta 5.1 ser respondida — se a resposta for "sim, migrar", este incremento
volta a ser desenhado numa sessão futura (é um escopo grande: 74 rotas, painel inteiro).

## 5. Perguntas para o Vagner antes de codar

1. **Unificar `/admin`/`/app` (74 rotas) para o novo mecanismo de auth, ou manter como
   está?** `PLANO-ESTRANGULAMENTO.md` (Fase 1A, passo 3) e `DIRETRIZES.md` (§14, checklist)
   dizem coisas opostas. Recomendação: manter como está por agora (é single-tenant,
   propositalmente diferente do resto, e já usa um padrão equivalente — token opaco
   revogável em `app_sessions`; o ganho de unificar é baixo frente ao risco de mexer no
   painel operacional da agência). Mas isso muda o escopo real da Fase 1A — precisa decisão
   explícita, não assumida.
2. **Incremento 3 (o dual-deploy): janela de manutenção específica, ou "qualquer hora,
   ninguém percebe" está correto?** A análise acima conclui que sessões abertas não são
   interrompidas no momento do deploy — só confirmar se essa leitura está certa antes de
   tratar isso como "pode subir a qualquer hora sem avisar ninguém".
3. **Vale um aviso passivo (banner) sobre a expiração gradual de sessões antigas**, ou
   deixar 100% silencioso (cada um só percebe quando, individualmente, seu JWT antigo
   expirar em até 30 dias)?
4. **10 tentativas / 15 min de rate limit no login está bom**, ou outro número? (Parâmetro
   do `express-rate-limit`, fácil de ajustar, só confirmar antes de já subir com um valor.)
5. **MFA/Passkeys** (backlog do `DIRETRIZES.md §3`) — confirmar que segue fora do escopo da
   Fase 1A (entendimento atual: sim, é "quando fizer sentido depois", não bloqueia nada aqui).
6. **Os 3 gates do `middleware.ts` que confiam no cookie `imoviz_user` não-httpOnly**
   (onboarding, `/analises/fila`, suspensão por inadimplência) — vale um item de follow-up
   dedicado (fora desta Fase 1A) para movê-los a checar contra o JWT assinado ou uma chamada
   ao backend, ou o risco é aceitável como está (são gates de UX/fluxo, não de dado — o
   backend real de cada tela segue escopado por tenant/role via JWT)?

## Critério de conclusão desta sub-fase (retomado do `PLANO-ESTRANGULAMENTO.md`)
Uma única geração de auth no código v2 (Incrementos 1-5 concluídos); login em um passo já é
efeito colateral do Incremento 3 (must_change_password vira só uma checagem de flag, não uma
segunda emissão de token obrigatória); token de sessão inacessível ao JavaScript (já é
verdade hoje, ver seção 1.2 — não é um critério pendente); logout revoga de verdade
(Incremento 3 + 4). Item de "auth legada removida" **não** se aplica se a resposta da
pergunta 5.1 for "manter como está" — critério original do plano assumia unificação total,
que está em aberto.
