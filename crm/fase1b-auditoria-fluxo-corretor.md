# FASE 1B — Auditoria do fluxo diário do corretor no Imoviz (23/07/2026)

> Investigação, 23/07/2026 — só leitura/teste, nenhuma mudança em produção. Motivada pelo
> achado do mesmo dia (D17 em `DECISOES.md`): a equipe da Casagora hoje **não usa o
> pipeline/deals do Imoviz** no dia a dia (só roteador + cadastro manual de lead avulso) — o
> import de base do noCRM (4.128 deals/55.284 comentários, ver `fase1b-migracao-base.md` seção
> 8.9) foi **invisível** pra equipe por causa disso. Antes de rodar o piloto com 2-3 corretores
> (D17), esta auditoria simula o dia a dia completo de um corretor operando 100% pelo Imoviz e
> reporta o que já funciona, o que está quebrado e o que não existe — é a lista do que falta
> para o "Imoviz 100%" antes do piloto.

## Método

Clone da produção **pós-import** (`CREATE DATABASE ... WITH TEMPLATE casagora_router`, banco
`casagora_router_audit_test`) — 4.128 deals/55.284 comentários/27 anexos migrados, estado real,
não uma simulação com dado sintético. Instância isolada do `casagora-router` (container Docker
próprio, rede `easypanel` só para resolver o Postgres, porta `3099` só em `127.0.0.1`) apontando
pra esse banco, com todas as integrações externas desligadas (noCRM, Facebook, Evolution/
WhatsApp, e-mail, IMAP) — nenhuma chamada saiu para sistema externo nenhum, nenhuma linha em
produção foi tocada. Testes feitos com o mesmo contrato de API que o frontend real usa (JWT
assinado localmente com um `JWT_SECRET` de teste, papel `BROKER`, usando a conta real da
corretora Karla Martins e, para um item, Josiane Santos — ambas com deals migrados de verdade).
Onde relevante, o código do frontend (`casagora-sistema`) foi lido para confirmar que a tela
correspondente já existe e chama o endpoint testado (não só que o backend responde).

Banco de teste e container derrubados ao final desta sessão — nada fica rodando.

## Resumo executivo

| # | Item | Veredito |
|---|---|---|
| 1 | Lead novo (roteador) aparece no pipeline | ✅ **Funciona** |
| 2 | Mover card entre as 9 etapas do Kanban | ✅ **Funciona** |
| 3 | Comentário num deal, junto com os importados | ✅ **Funciona** |
| 4a | Anexar arquivo **novo** a um deal | ✅ **Funciona** |
| 4b | Baixar anexo **migrado** do noCRM (R2) | 🔴 **Quebrado em produção** (falta infra, já documentada) |
| 5 | Buscar cliente antigo por nome/telefone | ✅ **Funciona** (tela `/leads` já existe) |
| 6 | Tarefa/lembrete de follow-up | 🟡 **Funciona, mas é passivo** — sem lista central nem alerta |
| 7 | Gaps do noCRM sem equivalente | Ver seção 7 — 6 gaps identificados, nenhum bloqueante pro piloto |

**Conclusão para o piloto (D17)**: nenhum gap encontrado impede começar o piloto com 2-3
corretores. O único item realmente quebrado (4b, anexos migrados) tem correção pequena e já
desenhada (`fase1b-migracao-base.md` seção 8.8) — recomendo resolver **antes** do piloto, porque
é exatamente o tipo de coisa que um corretor tentaria fazer no primeiro dia (abrir um documento
de cliente antigo) e o achado seria "o sistema não funciona", não "falta configurar uma
credencial". Os demais gaps (seção 7) são lacunas reais de produto, não bugs — priorizar depois
do piloto, com base no que os corretores-piloto sentirem falta de verdade.

## 1. Lead novo (roteador) aparece no pipeline — ✅ Funciona

Simulado um lead do Facebook Ads chegando (`insert` direto em `lead_events`, mesmo formato que o
webhook real grava) e disparado o mesmo reprocessamento que o webhook chama
(`routeLeadAndCreateNoCrm`, via `POST /admin/lead-events/:id/reprocess`). Resultado:
roteado automaticamente para Karla Martins (regra de campanha real), deal criado na etapa `01 -
Lead não Atendido`, status `para_hoje`, tags herdadas da campanha (`fb, Campanha Teste
Auditoria`). Consultando `GET /api/v2/crm/deals` como a corretora (mesmo endpoint que a tela
`/leads` e o Kanban usam), o lead aparece **no topo da lista**, ordenado por mais recente.

Nenhum gap. O mecanismo (`mirrorLeadEventToDeal`) já existe desde antes desta sessão e não
depende do noCRM estar habilitado — testado aqui com `nocrm_create_enabled=false` no banco de
teste (simulando o estado pós-cutover), que é o cenário relevante pro piloto.

## 2. Mover card entre as 9 etapas do Kanban — ✅ Funciona

`PATCH /api/v2/crm/deals/:id` com `stage_id` novo: moveu o deal de `01 - Lead não Atendido` para
`03 - Em Atendimento` e automaticamente registrou uma `activity` do tipo `stage_change`
("Movido para \"03 - Em Atendimento\"") no timeline — sem chamada extra, é side-effect da mesma
requisição. O de-para de etapas Kanban↔noCRM já tinha sido confirmado 1:1 na análise de dados
(D15); aqui foi confirmado que o **mecanismo de mudança em si** (não só o mapeamento de dado
migrado) funciona de ponta a ponta.

Nenhum gap.

## 3. Comentário num deal, junto com os importados — ✅ Funciona

Adicionado um comentário novo (`POST /api/v2/crm/deals/:id/activities`, `type=note`) num deal
que já tinha 109 comentários migrados do noCRM (`type=nocrm_comment`). O comentário novo aparece
**no mesmo timeline**, ordenado cronologicamente junto com os importados (mais recente primeiro)
— sem nenhuma distinção de tratamento além do rótulo visual que já existe (`ActivityFeed.tsx`,
PR #2, já deployado) para diferenciar "Importado do noCRM" de uma nota feita no Imoviz.

Nenhum gap.

## 4. Anexos — dividido em dois casos com resultado diferente

### 4a. Anexar arquivo novo a um deal — ✅ Funciona

Upload via `POST /api/v2/crm/deals/:id/attachments` (multipart) para um deal migrado: gravou em
`deal_attachments` com `storage_backend` default (`local`), listagem (`GET .../attachments`) e
download (`GET .../attachments/:fileId`) confirmados funcionando de ponta a ponta.

### 4b. Baixar um anexo migrado do noCRM (R2) — 🔴 Quebrado em produção

Os 27 anexos já migrados (seção 8.9 de `fase1b-migracao-base.md`) ficam no R2
(`storage_backend='r2'`), e o download depende de um proxy via `rclone cat` dentro do processo
(seção 8.6/8.8 do mesmo documento). **Testado aqui e confirmado quebrado**: a listagem de anexos
(metadados) funciona normalmente, mas o download retorna `500 server_error` — o binário/
credencial do `rclone` não está disponível (nem no ambiente de teste desta sessão, nem em
produção, pelo mesmo motivo documentado em 8.8: o bind mount de `/root/.config/rclone` no
serviço Swarm ainda não foi feito, e a imagem com `rclone` builda mas não foi deployada).

**Isso não é um achado novo** — já estava registrado como pendência na seção 8.8 de
`fase1b-migracao-base.md` (\"falta montar `/root/.config/rclone` no serviço Swarm antes de
qualquer deploy real\"). O que esta auditoria adiciona é a **confirmação prática**: um corretor
tentando abrir hoje um documento de cliente migrado (RG, comprovante de renda, contrato) recebe
erro, não um arquivo. Como o gatilho mais provável para um corretor-piloto notar isso é
justamente tentar puxar o histórico de um cliente antigo (o caso de uso central do piloto),
recomendo tratar como **bloqueador leve do piloto** — resolver antes, não depois.

**Esforço**: pequeno, já dimensionado no runbook da seção 8.8 (~1-2h) — build da imagem com
`rclone` (Dockerfile já tem o pacote) + `docker service update --mount-add` da credencial + verificação.

## 5. Buscar cliente antigo por nome/telefone — ✅ Funciona (tela já existe)

Testado `GET /api/v2/crm/deals?q=<busca>` (mesmo endpoint que a tela `/leads` chama) com busca
parcial por telefone e por nome de um lead migrado do noCRM (`Simone Carvalho`, deal com
`nocrm_lead_id` preenchido, status `ganho`) — achou em ambos os casos, retornando o deal
completo (tags, valor, notas, etapa). Conferido no código do frontend
(`frontend/src/app/(dashboard)/leads/page.tsx`) que **já existe uma tela de lista com campo de
busca** (\"Buscar por nome, telefone ou e-mail...\") plugada nesse mesmo endpoint, sem filtro de
status por padrão — ou seja, também aparecem leads já `ganho`/`perdido`/`cancelado`, não só o
pipeline ativo.

Nenhum gap — tanto o backend quanto a tela de frontend já estão prontos e cobrem exatamente esse
caso de uso (achar histórico de um cliente antigo migrado do noCRM).

## 6. Tarefa/lembrete de follow-up — 🟡 Existe o conceito, mas é passivo

**O que existe**: `activities` do tipo `task` (`content`, `due_at`, `done_at`) — criado via
`POST /api/v2/crm/deals/:id/activities`, marcado como concluído via
`PATCH /api/v2/crm/tasks/:id`. Testado ao vivo: criei uma tarefa com vencimento no passado
("Ligar pra cliente confirmar visita", `due_at` 3 dias atrás) e marquei como concluída — os dois
passos funcionaram. No frontend, `ActivityFeed.tsx` já colore a tarefa de vermelho quando
`due_at` passou e não foi concluída (`isOverdue`), e existe `TaskForm.tsx` dedicado para criar
uma nova tarefa dentro do deal.

**O que falta** (comparando com `Remind_date`/`Reminder_activity`/`Reminder_note` do export
noCRM, seção 2 de `fase1b-migracao-base.md`):

1. **Sem lista "minhas tarefas" entre deals** — o único jeito de ver uma tarefa vencida hoje é
   abrir o deal específico onde ela foi criada. Não existe endpoint nem tela que junte tarefas
   pendentes/vencidas de **todos** os deals de um corretor num só lugar (tipo "o que preciso
   fazer hoje"). Confirmado por busca no código do backend (índice
   `idx_activities_tenant_due` já existe no schema, pronto pra essa query, mas nenhum endpoint o
   usa) e do frontend (nenhuma tela fora do `ActivityFeed` por-deal referencia `due_at`).
2. **Sem notificação proativa** — o sistema de notificações (`notifications`, já usado para
   `new_lead`/`mention`/`campaign_added`) não tem nenhum tipo de evento para tarefa vencendo/
   vencida. Um corretor só descobre que uma tarefa venceu se abrir aquele deal específico por
   outro motivo.

No noCRM, `Remind_date` + `Reminder_activity`/`Reminder_note` sugerem que o lembrete era um
recurso de primeira classe (provavelmente com alerta central, já que aparecia como coluna
própria no export, distinta de comentário). Sem os itens 1-2 acima, um corretor migrando do
noCRM perde a garantia de "não esquecer de ligar pro cliente" — o dado existe, mas exige
disciplina de abrir cada deal manualmente, ao contrário de hoje.

**Esforço estimado**: médio — endpoint novo (`GET /api/v2/crm/tasks/mine?status=pending&overdue=true`
ou equivalente, já tem o índice certo no schema), tela nova ou seção no `HomeHub.tsx` (dashboard
inicial, hoje sem nada de tarefas), e opcionalmente um novo tipo de `notification`
(`task_due`) gerado por um job diário (mesmo padrão dos jobs `systemd timer` já usados no
projeto). Estimativa: ~2-3 dias — não é um bloqueador técnico do piloto (o dado já é gravado
corretamente), mas é a lacuna de produto mais visível no dia a dia se o piloto rodar sem ela.

## 7. O que o corretor tinha no noCRM sem equivalente hoje no Imoviz

Comparando a lista completa de colunas do export nativo (seção 2 de `fase1b-migracao-base.md`)
com o schema de `deals`/`activities`/`analises_credito` hoje:

| Recurso no noCRM | Estado no Imoviz | Esforço se for adotar |
|---|---|---|
| **CPF, Renda Familiar, Minha Renda é, Entrada/FGTS** | Existe **em outro módulo** (`analises_credito` — `cpf`, `renda`, etc.), mas só quando alguém roda uma análise de crédito formal pra aquele deal; não é um campo do lead em si, visível desde a captação | Pequeno-médio (~1-2 dias) se quiser um snapshot desses dados já na ficha do lead, não só na análise |
| **Motivos Cancelamento Lead** | **Não existe** — `deals.status` vira `perdido`/`cancelado` sem nenhum campo estruturado de motivo; só entra em texto livre se o corretor escrever em `notes`/comentário por iniciativa própria | Pequeno (~1 dia) — campo novo + prompt no frontend ao mudar status pra perdido/cancelado |
| **Probability, Percentual Comissão, Amount×Percentual Comissão** | **Não existe** — `deals.valor` existe (o "Amount"), mas sem % de comissão nem probabilidade de fechamento | Pequeno-médio (~1-2 dias) — 2 colunas novas + campo no formulário do deal |
| **Estimated_closing_date, Closed_at** | **Não existe em `deals`** (só existe em `lead_crm_import`, a tabela espelho do sync antigo, não na tabela viva) — sem data estimada de fechamento nem data real de fechamento estruturada | Pequeno (~1 dia) |
| **Origem, Captador, Indicação/Quem Indicou, Forma de Comunicação, Tipo de Contato, Intenção do Cliente, Cidade, Condição/Situação do Imóvel** | **Sem campo próprio** — hoje só cabem em `notes` (texto livre) ou como `tags` genéricas; não são filtráveis/pesquisáveis como campo estruturado | Médio-grande (~3-5 dias) — exige decidir com o Vagner quais desses campos realmente valem a pena estruturar (nem todos foram usados de forma consistente no noCRM, pelo que a distribuição de preenchimento da seção 1 de `fase1b-migracao-base.md` já sugeria) |
| **Starred** (favoritar um lead) | **Não existe** | Pequeno (poucas horas) — baixa prioridade, nenhum sinal de que era muito usado |
| **Tempo em cada etapa do funil** | **Não existe como métrica** — a mudança de etapa vira um `activity` de texto (`stage_change`), mas não há relatório/consulta de "quanto tempo esse lead ficou em cada etapa" | Médio (~2-3 dias) — precisaria de uma tabela de histórico com timestamps por etapa, hoje só existe como texto solto no timeline |
| **Reminder/tarefa centralizada** | Ver seção 6 (parcial — existe o dado, falta a visão central) | Ver seção 6 |
| **Anexo — histórico migrado** | Ver seção 4b (existe o dado, download quebrado por infra) | Ver seção 4b |

**Nenhum destes gaps é bloqueador técnico do piloto** — todos são lacunas de produto (campos que
faziam parte do dia a dia no noCRM mas ainda não têm equivalente estruturado no Imoviz), não
bugs. Recomendo não tentar fechar todos antes do piloto: a lista é boa candidata a virar backlog
priorizado **depois** que os 2-3 corretores-piloto (D17) sentirem na prática quais desses campos
fazem falta de verdade — em particular, "motivo de cancelamento" e "tempo em cada etapa" parecem
os mais prováveis de aparecer como reclamação real (são os que mais afetam gestão/relatório, não
só o corretor individual), mas isso é uma hipótese a validar com o piloto, não uma decisão a
tomar agora.
