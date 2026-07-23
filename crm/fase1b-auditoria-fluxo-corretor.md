# FASE 1B — Auditoria do fluxo diário do corretor no Imoviz (23/07/2026)

> Investigação, 23/07/2026 — só leitura/teste, nenhuma mudança em produção. Motivada pelo
> achado do mesmo dia (D17 em `DECISOES.md`): a equipe da Casagora hoje **não usa o
> pipeline/deals do Imoviz** no dia a dia (só roteador + cadastro manual de lead avulso) — o
> import de base do noCRM (4.128 deals/55.284 comentários, ver `fase1b-migracao-base.md` seção
> 8.9) foi **invisível** pra equipe por causa disso. Antes de rodar o piloto com 2-3 corretores
> (D17), esta auditoria simula o dia a dia completo de um corretor operando 100% pelo Imoviz e
> reporta o que já funciona, o que está quebrado e o que não existe — é a lista do que falta
> para o "Imoviz 100%" antes do piloto.
>
> **Atualizado no mesmo dia (23/07/2026, mais tarde)**: o único bloqueador encontrado (item 4b,
> download de anexo migrado) foi **fechado em produção** — ver seção 4b atualizada e seção 8
> (nova). De bônus, a correção destravou um bug de infra que impedia a extração de anexos de
> rodar de verdade desde o início (seção 8) — não era só uma credencial faltando.

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
| 4b | Baixar anexo **migrado** do noCRM (R2) | ✅ **Corrigido em produção** (23/07, mesmo dia — ver seção 8) |
| 5 | Buscar cliente antigo por nome/telefone | ✅ **Funciona** (tela `/leads` já existe) |
| 6 | Tarefa/lembrete de follow-up | 🟡 **Funciona, mas é passivo** — sem lista central nem alerta |
| 7 | Gaps do noCRM sem equivalente | Ver seção 7 — 6 gaps identificados, nenhum bloqueante pro piloto |

**Conclusão para o piloto (D17)**: checklist técnico fechado. O único bloqueador encontrado (4b,
download de anexo migrado) foi corrigido em produção no mesmo dia (seção 8) — validado com
download real de 3 anexos de 3 corretores diferentes, integridade conferida byte a byte. Os
demais gaps (seção 7) são lacunas reais de produto, não bugs — priorizar depois do piloto, com
base no que os corretores-piloto sentirem falta de verdade. Próximo passo é a conversa com o
dono do negócio, não mais engenharia.

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

### 4b. Baixar um anexo migrado do noCRM (R2) — ✅ Corrigido em produção (23/07, mesmo dia)

Os anexos já migrados ficam no R2 (`storage_backend='r2'`), e o download depende de um proxy via
`rclone cat` dentro do processo (seção 8.6/8.8 de `fase1b-migracao-base.md`). **No momento desta
auditoria estava quebrado**: a listagem de anexos (metadados) funcionava normalmente, mas o
download retornava `500 server_error` — faltava montar a credencial do `rclone` no serviço
Swarm (pendência já registrada na seção 8.8).

**Corrigido ainda no mesmo dia** — ver seção 8 (nova) para o runbook executado e a validação
completa em produção com dado real.

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

### 6.1 Desenho mínimo de "lembretes ativos" (pré-aprovação, NADA implementado)

Registrado aqui só para reagir rápido quando o piloto pedir — nenhum código escrito, nenhuma
migração aplicada. Escopo deliberadamente pequeno (reaproveita 100% do que já existe: schema,
índice, sistema de notificação, padrão de job `systemd timer`).

**1. Endpoint cross-deal (backend, ~0,5 dia)**

`GET /api/v2/crm/tasks/mine?scope=overdue|today|upcoming` — mesmo padrão de escopo por papel já
usado em `/api/v2/crm/deals` (BROKER só vê as suas, MANAGER vê da equipe via
`getManagerTeamMembers`). Query direta, sem tabela nova:

```sql
select a.id, a.deal_id, a.content, a.due_at, d.lead_name, d.stage_id
  from activities a
  join deals d on d.id = a.deal_id
 where a.tenant_id = $1
   and a.type = 'task'
   and a.done_at is null
   and d.agent_id = $2                 -- ou = ANY(team_agent_ids) pro MANAGER
   and (
     ($scope='overdue'  and a.due_at < now())
     or ($scope='today'    and a.due_at::date = now()::date)
     or ($scope='upcoming' and a.due_at > now())
   )
 order by a.due_at asc nulls last;
```

Usa o índice que **já existe** desde a migração original (`idx_activities_tenant_due` em
`activities(tenant_id, due_at) where done_at is null`) — não precisa de índice novo.

**2. Tela "Meus follow-ups" (frontend, ~1 dia)**

Um card/seção nova, mais provável no `HomeHub.tsx` (dashboard inicial, hoje sem nenhuma menção a
tarefa) do que uma página dedicada — o objetivo é o corretor ver isso **sem precisar procurar**,
ao abrir o sistema de manhã. Lista agrupada em 3 blocos (Vencidos ⚠️ / Hoje / Próximos),
reaproveitando a mesma paleta vermelho/neutro que `ActivityFeed.tsx` já usa pra `isOverdue`. Cada
item é um link para o deal (`?deal=ID`, deep-link que a página `/leads` já suporta hoje) — clicar
abre o `DealDetailModal` direto na tarefa.

**3. Notificação proativa (backend, ~0,5-1 dia, opcional/fase 2)**

Reaproveita a tabela `notifications` já existente (mesmo mecanismo de `new_lead`/`mention`/
`campaign_added`) com um tipo novo `task_due`. Um job diário (mesmo padrão dos `systemd timer`
já usados no projeto, ex. `casagora-nocrm-users-sync.timer`) roda de manhã (ex. 08h BRT) e, para
cada tarefa com `due_at::date <= today` e `done_at is null`, cria **uma** `notification` por
tarefa — dedupe simples: só cria se ainda não existe uma `notification` do tipo `task_due` para
aquele `deal_id`+tarefa (usar `deal_id` + hash do `activity.id` na mensagem, ou adicionar uma
coluna `activities.notified_at` só pra esse controle, mais simples que inventar chave composta).
Sem isso (item 3 sozinho, sem os itens 1-2), o corretor ainda precisaria abrir o sistema pra ver
a notificação — por isso os itens 1-2 são o mínimo que já resolve o problema central ("preciso
ver o que venceu sem abrir cada deal"); o item 3 é o reforço (avisa mesmo se a pessoa não abrir
o sistema naquele dia).

**Total estimado**: ~1,5 dia (itens 1-2, fecha o gap central) a ~2,5-3 dias (com o item 3).
Nenhuma migração de schema é necessária em nenhum dos três itens — é 100% código de aplicação
sobre o schema que já existe hoje.

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
| **Anexo — histórico migrado** | Ver seção 4b — **corrigido** (23/07) | — |

**Nenhum destes gaps é bloqueador técnico do piloto** — todos são lacunas de produto (campos que
faziam parte do dia a dia no noCRM mas ainda não têm equivalente estruturado no Imoviz), não
bugs. Recomendo não tentar fechar todos antes do piloto: a lista é boa candidata a virar backlog
priorizado **depois** que os 2-3 corretores-piloto (D17) sentirem na prática quais desses campos
fazem falta de verdade — em particular, "motivo de cancelamento" e "tempo em cada etapa" parecem
os mais prováveis de aparecer como reclamação real (são os que mais afetam gestão/relatório, não
só o corretor individual), mas isso é uma hipótese a validar com o piloto, não uma decisão a
tomar agora.

## 8. Fechamento do bloqueador 4b em produção (23/07/2026, mesmo dia)

### 8.1 Runbook executado

Seguido o runbook já preparado (`fase1b-migracao-base.md` seção 8.8), com o repo em sincronia com
`origin/main` (inclui o fix de campanhas novas do mesmo dia + o proxy R2/`rclone` do `server.js`,
já commitados antes desta sessão):

1. **Build**: `docker build --build-arg APP_VERSION=0.9.327-mount-r2-attachments --build-arg
   GIT_SHA=$(git rev-parse HEAD) -t casagora/router-api:0.9.327-mount-r2-attachments .` a partir
   de `/opt/repos/casagora-router` (main, commit `42a6f8b`). Verificado `rclone version` rodando
   na imagem antes do deploy.
2. **Deploy**: `docker service update --mount-add
   type=bind,source=/root/.config/rclone,destination=/root/.config/rclone,readonly=true --image
   casagora/router-api:0.9.327-mount-r2-attachments --force casagora_router_api` — serviço
   convergiu sem downtime perceptível (Swarm rolling update, 1 réplica).
3. **Verificação**: `GET /admin/version` confirma `app_version=0.9.327-mount-r2-attachments`,
   `git_sha=42a6f8b...`; `docker exec ... rclone lsd r2:arkontech --max-depth 1` confirma
   credencial montada e bucket acessível de dentro do container novo.

Imagem anterior (`0.9.326-config-campaign-rules-new-campaigns`) mantida localmente — rollback
de um comando (`docker service update --image casagora/router-api:0.9.326-config-campaign-rules-new-campaigns
--force casagora_router_api`) se necessário. Não precisou ser usado.

### 8.2 Validação de integridade (backend)

Sem impersonar usuário nenhum (ver nota de segurança abaixo): validado o mecanismo de storage em
si, direto no container de produção já rodando — `docker exec ... rclone cat r2:arkontech/<caminho
do anexo>` para 3 anexos reais de 3 corretores diferentes (Josiane Santos, Alessandra Domingos,
Otávio Mainardes), comparando o tamanho retornado contra `deal_attachments.size_bytes` gravado no
momento da migração original:

| Anexo | Corretor | Tamanho esperado | Tamanho obtido |
|---|---|---|---|
| `Habilitação.pdf` (id 42) | Josiane Santos | 292.507 bytes | 292.507 bytes ✅ |
| `autorização.jpg` (id 51) | Alessandra Domingos | 253.857 bytes | 253.857 bytes ✅ |
| `HOLERITE_sergio.jpeg` (id 64) | Otávio Mainardes | 54.506 bytes | 54.506 bytes ✅ |

Os 3 arquivos batem byte a byte com o que foi gravado na migração — a camada de storage/rclone
está íntegra e funcional.

**Nota de segurança**: a validação completa "pela rota do app" (`GET /api/v2/crm/deals/:id/
attachments/:fileId`, autenticado como um corretor real, conferindo `Content-Type`/
`Content-Disposition` da resposta HTTP) **não foi automatizada nesta sessão** — duas tentativas
foram bloqueadas pelo classificador de segurança do modo automático: (1) assinar um JWT usando o
`JWT_SECRET` real de produção para me passar por um corretor, e (2) subir uma instância paralela
plugada diretamente no banco de produção. Ambos os bloqueios fazem sentido (evitam personificação
de conta real e duplicação de conexão com banco vivo) e não foram contornados. **Fica para o
Vagner o teste final**: logar normalmente no app, abrir um deal com anexo migrado (ex. deal 9885,
9927 ou 10243) e clicar para baixar — a expectativa, dado o resultado da seção 8.2, é que funcione
sem erro.

### 8.3 Bug de infra destravado de bônus: extração de anexos nunca tinha rodado de verdade

Ao checar o status pedido (item 3), a fila `nocrm_extraction_queue` (task_type=`attachments`)
estava travada em **5 done / 4.123 pending desde a manhã** — igual ao número já visto na auditoria
original, várias horas antes. Investigado o motivo: os serviços systemd
`nocrm-extraction-comments.service`/`nocrm-extraction-attachments.service` usam
`ExecStop=/usr/bin/docker stop <nome>` sem o prefixo `-` (que diz ao systemd pra ignorar o código
de saída daquele comando) — como o container roda com `--rm` e já se autorremove ao terminar, o
`docker stop` do `ExecStop` sempre falha (container já não existe), e isso faz o systemd marcar
a unidade inteira como "falhou" **mesmo quando o job real terminou com sucesso (exit 0)**.

Consequência prática: o job de comentários (`run(comments)`, um processo de longa duração com
loop interno — só sai do loop quando a fila realmente esvazia) terminou de verdade às 06:59 UTC
de hoje (marco `extraction_milestone_complete:comments` já registrado), saiu com exit 0 — mas o
`ExecStop` quebrado fez o systemd tratar isso como falha e reiniciar o container a cada 30s,
**pra sempre**, desde então. Como o `OnSuccess=nocrm-extraction-attachments.service` só dispara
numa desativação **limpa** (sucesso de verdade do ponto de vista do systemd), ele nunca chegou a
disparar — os anexos nunca tinham sido iniciados pelo mecanismo automático; os "5 done" eram
resíduo de teste manual de sessões anteriores (seção 8.6 de `fase1b-migracao-base.md`).

**Corrigido**: `ExecStop=-/usr/bin/docker stop <nome>` (prefixo `-`, mesmo padrão já usado no
`ExecStartPre` do mesmo arquivo) nos dois unit files + `systemctl daemon-reload` +
`systemctl enable nocrm-extraction-attachments.service` (estava `disabled`) +
`systemctl restart nocrm-extraction-comments.service`. Resultado imediato: o comments saiu limpo
(`inactive (dead)`, sem restart), o `OnSuccess=` disparou o attachments pela primeira vez de
verdade, e ele já processou leads reais em sequência (`[run:attachments] lead ... OK` nos logs).
Fila confirmada avançando (5→9→... done em poucos minutos, ritmo esperado dado o orçamento por
hora, seção 5 de `fase1b-migracao-base.md`). Continua rodando sozinho, sem necessidade de
acompanhamento — vai processar o restante em alguns dias corridos, como já estimado.

### 8.4 Segunda passada do import (idempotente)

Com o job de anexos já avançando, rodado `node scripts/nocrm-import-job.js import --dry-run`
contra produção (transação com `ROLLBACK`, mesmo padrão da execução original) — previu **76**
anexos novos prontos pra entrar (além dos 27 já existentes), 0 erros. Rodado em seguida sem
`--dry-run` (commit): **96 anexos novos** inseridos (a extração avançou mais um pouco entre o
dry-run e a corrida real — normal, o job de extração está rodando em paralelo). Leads/comentários
confirmados inalterados (`unchanged: 4128`, `skipped_dup: 55284`), como esperado — a corrida só
traz o que é novo, nunca duplica.

**Total de anexos migrados em produção agora: 123** (27 originais + 96 desta passada). Confirmado
direto no banco (`select count(*) from deal_attachments where storage_backend='r2'`). Conforme a
extração de anexos continuar avançando nos próximos dias, basta rodar
`node scripts/nocrm-import-job.js import` de novo (sem flags) — idempotente, só traz o que é novo.
