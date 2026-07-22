# Fase 1B — job de extração via API do noCRM (comentários completos + anexos)

> Escrito em 22/07/2026. Implementa a parte de **extração** (buscar e guardar o dado bruto
> do noCRM) das decisões D14 (histórico completo de comentários) e do job de anexos descrito em
> `fase1b-migracao-base.md` seção 5. **Não inclui o script de import** (transformar o dado bruto
> em `deals`/`activities`/`deal_attachments` do Imoviz) — isso é uma etapa separada, posterior,
> ainda não escrita (ver seção 8 de `fase1b-migracao-base.md`, que segue "para aprovação, não
> codar ainda"). O job aqui só existe para não perder o dado do noCRM antes de qualquer decisão
> de import estar pronta — resolve o requisito de "irrecuperável depois que a assinatura for
> cancelada" independente de quando o import rodar.

## 1. Pesquisa da API oficial (nocrm.io/api)

Extraído com `defuddle` (a página é uma SPA; o WebFetch padrão resumia demais e cortava os
exemplos de JSON — o `defuddle parse --md` trouxe o dump completo, 11k linhas).

### Autenticação
- Header `X-API-KEY: <chave>` (usado por toda a app hoje) ou `X-USER-TOKEN` (alternativa, não
  usada aqui). HTTPS obrigatório.
- Base URL: `https://{NOCRM_SUBDOMAIN}.nocrm.io/api/v2/...`

### Comentários — `GET /leads/{lead_id}/comments`
- **Sem paginação** — retorna o array completo de comentários do lead numa única chamada
  (parâmetro opcional só `direction=asc|desc`). Confirma a premissa da D14: **1 requisição por
  lead** basta para o histórico completo, o export nativo é quem trunca em 4, não a API.
- Schema real (confirmado no teste, seção 6): `id`, `content`, `created_at`, `user{firstname,
  lastname,email,...}`, `attachments[]` (anexos citados dentro do comentário — ex.: link
  Dropbox — **fora do escopo desta extração**, ver seção 7), `activity`/`action_item` (para
  comentários de sistema tipo e-mail, `content` vem `null` e o texto real está em
  `action_item.email.content`).

### Anexos — em duas etapas
1. `GET /leads/{lead_id}/attachments` → lista `{id, name, url, content_type, kind}`. `kind`
   pode ser `attachment` (arquivo real, hospedado no noCRM), ou `business_card`,
   `freshbooks_estimate`, `dropbox` etc. (anexos de integração, não baixáveis por aqui).
   **Filtrar por `kind==='attachment'`** antes de baixar.
2. `GET /leads/{lead_id}/attachments/{id}` → `{url: <URL assinada do S3, válida ~180s>}`. Essa
   URL **não leva `X-API-KEY`** (a assinatura já autentica) e o download em si **não conta**
   no teto de 2000/dia — só a chamada que gera a URL conta. Confirma a estimativa de
   `fase1b-migracao-base.md` ("1 lista + 1-2 downloads por lead").
   **Importante**: por causa da janela de 180s, o job baixa o binário **imediatamente** depois
   de pedir a URL — não separa em duas fases (senão a URL expira e é preciso pedir de novo,
   gastando outra requisição).

### Rate limit (confirmado, texto oficial)
> "2000 requests per day are allowed. Pass this number of requests, all the requests received
> won't be processed and will return an error code 429."
- 429 vem com dois headers: `API-RETRY-AFTER` (segundos até poder tentar de novo) e
  `API-LIMIT-RESET` (timestamp da virada). O job usa os dois para pausar a corrida inteira
  quando um 429 acontece (ver seção 4).
- **O teto é da conta inteira, não desta extração** — o `casagora_router_api` já usa a mesma
  `NOCRM_API_KEY` para sync incremental diário (~50-100 req/dia medido em produção), o worker
  de refresh por webhook (baixo volume) e `queue-reconcile` horário. O orçamento diário do job
  (seção 4) é deliberadamente menor que 2000 pra sobrar folga pro app principal.

## 2. Onde vivem as credenciais hoje

Confirmado nesta sessão, **reaproveitadas, nenhuma nova criada**:
- `NOCRM_SUBDOMAIN` e `NOCRM_API_KEY` existem em **dois lugares consistentes**:
  1. `/etc/casagora-router.secrets.env` no host (`600`, root) — usado por scripts/operações
     manuais fora do container.
  2. Env vars da spec do serviço Swarm `casagora_router_api` (`docker service inspect`) — é o
     que o container em produção realmente usa.
- O job de extração (script novo, seção 4) lê essas mesmas variáveis — não pede nem cria
  credencial nova.

### Achado colateral (fora do escopo, reportado — não corrigido ainda)
`/etc/casagora-router.env` (que guarda `DATABASE_URL`) está **desatualizado**: ainda tem a
senha do Postgres **anterior** à rotação de credenciais de 19/07/2026 (`rotacao-credenciais-
runbook.md`). Descoberto porque o primeiro teste desta sessão falhou com
`password authentication failed` ao usar esse arquivo — o valor correto só estava na spec do
serviço Swarm. Não é um risco de segurança novo (é uma senha já rotacionada, portanto já
inválida), mas é uma armadilha operacional: qualquer script futuro que confie nesse arquivo vai
falhar do mesmo jeito. Recomendo atualizar `/etc/casagora-router.env` com o valor atual antes
que alguém perca tempo com o mesmo erro — não fiz a alteração porque é um arquivo de segredo
fora do escopo pedido nesta sessão.

## 3. Desenho do job

### Por que um script standalone, não dentro do `server.js`
`nocrm_lead_refresh_jobs` (o job de fila já existente no app, ver `server.js`) é uma feature
**permanente** (disparada por webhook, roda pra sempre). Esta extração é o oposto: uma tarefa
**de uma vez só**, que termina quando os 3.615 + 5.750 leads acabarem e nunca mais roda. Botar
lógica de migração histórica dentro do processo Express de produção infla `server.js`
permanentemente por um código que só serve por alguns dias — inconsistente com o resto do app
(nada mais ali é "migração pontual"). Por isso: **processo Node separado**
(`scripts/nocrm-extraction-job.js`, novo, no repo `casagora-router`), rodando fora do container
Swarm, com todo o estado em Postgres — resumível por construção (matar o processo e
recomeçar não perde nem reprocessa nada, o progresso vive no banco, não em memória).

### Tabelas Postgres (criadas automaticamente pelo script, `create table if not exists`)

```sql
-- Fila de trabalho — pending/done/error por lead x tipo de tarefa
create table nocrm_extraction_queue (
  id bigserial primary key,
  nocrm_lead_id text not null,
  task_type text not null check (task_type in ('comments','attachments')),
  status text not null default 'pending' check (status in ('pending','done','error')),
  attempts int not null default 0,
  last_error text,
  result jsonb,
  next_run_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (nocrm_lead_id, task_type)
);

-- Cache bruto do histórico completo de comentários (D14) — staging, não é `activities`
create table nocrm_comments_raw (
  nocrm_lead_id text primary key,
  comments jsonb not null,       -- array completo retornado pela API
  comment_count int not null,
  fetched_at timestamptz not null default now()
);

-- Metadados dos anexos baixados — os bytes ficam no R2, só o metadado no Postgres
create table nocrm_attachments_raw (
  id bigserial primary key,
  nocrm_lead_id text not null,
  nocrm_attachment_id text not null,
  filename text not null,
  content_type text,
  size_bytes bigint,
  storage_backend text not null default 'r2',
  storage_key text not null,
  fetched_at timestamptz not null default now(),
  unique (nocrm_lead_id, nocrm_attachment_id)
);

-- Orçamento diário (contador simples, dia UTC)
create table nocrm_extraction_budget (
  day date primary key,
  requests_used int not null default 0
);
```

`nocrm_comments_raw`/`nocrm_attachments_raw` são **staging**, não as tabelas do Imoviz —
deliberado. O script de import (futuro, seção 8 de `fase1b-migracao-base.md`, ainda não escrito
e não aprovado) é quem vai ler daqui e escrever em `deals`/`activities`/`deal_attachments`. Essa
separação deixa a extração 100% independente de qualquer decisão de import ainda não tomada —
o dado fica seguro no banco/R2 mesmo que o import demore a ser aprovado ou mude de desenho.

### Fluxo por tipo de tarefa

**Comments**: 1 requisição (`GET /leads/{id}/comments`) → upsert em `nocrm_comments_raw` →
`done`. Sem chamadas dependentes, sem laço.

**Attachments**: `GET /leads/{id}/attachments` (1 req) → filtra `kind==='attachment'` → para
cada um: pula se já existe em `nocrm_attachments_raw` (idempotência fina, granular por anexo,
não só por lead — importante porque um lead com 12 anexos pode falhar no 8º e retomar do 8º,
não do 1º) → `GET .../attachments/{id}` (1 req, gera URL assinada) → baixa o binário na hora →
sobe pro R2 via `rclone rcat` → grava metadado.

### Orçamento diário e 429

- `NOCRM_EXTRACTION_DAILY_BUDGET` (env, default **1500**) — deliberadamente abaixo de 2000 pra
  sobrar ~500/dia de folga pro app principal (que hoje usa uma fração disso, mas a folga é
  proposital, não ajustada fino ao consumo medido).
- Contador em `nocrm_extraction_budget`, incrementado a cada chamada real à API (não conta o
  download do S3, que é de graça pro teto). Corte proativo: para de pedir mais trabalho quando
  o contador do dia bate no teto, dorme até a virada UTC.
- **429 de verdade** (sinal autoritativo, não só o autocontrole): pausa a corrida inteira
  (não só o lead atual), loga `API-RETRY-AFTER`/`API-LIMIT-RESET`, espera e retoma sozinho. Não
  conta como falha do lead (não incrementa `attempts` dele).

### Retry com backoff (falhas normais — rede, 5xx, etc., não 429)

Backoff exponencial em minutos, `min(2^tentativas, 60)`, até `NOCRM_EXTRACTION_MAX_ATTEMPTS`
(default 8) — depois disso o item vira `status='error'` (para de tentar sozinho, fica visível
pra alguém olhar via `status`, mas não trava o resto da fila).

### Retomada (parar/continuar sem reprocessar)

Comprovado no teste (seção 6): reseedar os mesmos ids não duplica (`ON CONFLICT DO NOTHING`
na fila, `UNIQUE` em `nocrm_comments_raw`/`nocrm_attachments_raw`); re-rodar sobre itens já
`done` não gasta nenhuma requisição nova (a query só pega `status='pending'`). Matar o processo
no meio de um lote também é seguro: o pior caso é reprocessar o lead que estava em andamento no
momento exato do kill (perde no máximo 1 requisição de comments, ou os anexos de 1 lead em
attachments — nunca o trabalho já commitado no banco).

## 4. Armazenamento dos anexos — R2, não disco local

Considerado disco local (`ATTACHMENTS_DIR`, o mesmo volume Docker nomeado que `deal_attachments`
já usa hoje — 348GB livres no host, uso atual de 13MB, folga enorme mesmo num cenário
pessimista de ~150GB pros 5.750 leads) contra R2 (bucket `arkontech`, já em uso pelo backup
diário, credenciais já testadas em `/root/.config/rclone/rclone.conf`).

**Decisão: R2.** Motivo central não é espaço (sobra dos dois jeitos) — é durabilidade. O
Swarm aqui é **nó único**; o volume `ATTACHMENTS_DIR` não tem réplica e, mais importante,
**não está coberto por nenhum backup hoje** (o `backups.md` só cobre os bancos Postgres via
`pg_dump`, nunca o volume de anexos). Guardar num disco sem backup o dado que o D14 descreve
como "irrecuperável depois que a assinatura do noCRM for cancelada" contradiz o motivo de
fazer a migração. R2 já tem a rotina de retenção provada (`backups.md`) e sobrevive
independente do host.

**Custo dessa escolha**: os anexos migrados **não são servidos automaticamente** pelo endpoint
de download que já existe (`GET .../deal_attachments/...`, que hoje só lê de
`ATTACHMENTS_DIR` local) — isso é esperado e fica para depois, exatamente como o pedido descreve
("precisam ser servidos pelo Imoviz **depois**"). Quando o import (futuro) criar linhas em
`deal_attachments` para os leads migrados, o endpoint de download vai precisar de um branch
pequeno (`storage_backend='r2'` → buscar do bucket em vez do disco) — mudança pontual e
contida, não feita nesta sessão porque está fora do escopo de "só o job de extração".

## 5. Onde o script vive e como roda

- Arquivo: `casagora-router/scripts/nocrm-extraction-job.js` (ESM, consistente com o resto do
  repo — `package.json` tem `"type": "module"`).
- Não roda dentro do container Swarm — precisa da rede `easypanel` (pra alcançar
  `arkontech_postgres` pelo nome) e do `rclone` com o remote `r2` já configurado no host.
- CLI:
  ```
  node scripts/nocrm-extraction-job.js seed comments|attachments --ids 1,2,3 | --file leads.txt
  node scripts/nocrm-extraction-job.js run  comments|attachments [--limit 20] [--once]
  node scripts/nocrm-extraction-job.js status
  ```
- Rodar em volume (dias) é pensado como um `systemd` **service** (não timer — precisa ficar
  vivo, pausando e retomando sozinho por causa do orçamento/429), `Restart=on-failure`, mesmo
  princípio dos backups (`casagora-db-backup.service`). **Unit ainda não criada/habilitada** —
  fica para quando o Vagner autorizar rodar em volume.

## 6. Teste com 5 leads — resultado real (22/07/2026)

Rodado num container `node:22-alpine` descartável, preso à rede `easypanel`, usando as
credenciais atuais da spec do serviço Swarm (seção 2). 5 leads reais de produção, status
`won`, escolhidos arbitrariamente (`38798034, 38793842, 38679973, 38666599, 38664781`).

### Comentários

| Lead | Comentários recebidos |
|---|---|
| 38798034 | 5 |
| 38793842 | 16 |
| 38679973 | 16 |
| 38666599 | 20 |
| 38664781 | 6 |

Todos **acima do teto de 4** do export nativo — prova ao vivo de que a API entrega o histórico
completo (a base do argumento da D14). Gravados em `nocrm_comments_raw`, `jsonb_array_length`
bate exatamente com `comment_count` nos 5 casos.

### Anexos

| Lead | Listados | Baixados | Bytes |
|---|---|---|---|
| 38798034 | 0 | 0 | 0 |
| 38793842 | 6 | 6 | 531.001 |
| 38679973 | 12 | 12 | 7.346.374 |
| 38666599 | 9 | 9 | 2.188.289 |
| 38664781 | 0 | 0 | 0 |

27 arquivos reais (PDF, JPEG, XLSX — RG, comprovantes, simuladores, propostas) confirmados
**de verdade no bucket R2** via `rclone lsl r2:arkontech/nocrm-attachments/`, tamanhos batendo
com o metadado gravado em `nocrm_attachments_raw`.

### Orçamento consumido no teste

**37 requisições** (5 comments + 5 listas de anexos + 27 retrieve-one) — dentro do esperado
(~1 req/lead pra comments, ~1+N req/lead pra attachments) e irrisório frente ao teto de
2000/dia.

### Retomada/idempotência

Reseedar os mesmos 5 ids e rodar de novo: `0 novos` no seed, `processed: 0` no run, orçamento
do dia **inalterado em 37** — confirma que nada é reprocessado nem regravado.

### Conclusão do teste

Os 4 pontos pedidos estão provados com dado real, não simulado: autentica (chave reaproveitada,
sem erro 401), pagina/completa (histórico além do teto de 4), grava corretamente (Postgres +
R2, bytes e contagens conferidos), e é resumível (reseed/rerun não duplica nem gasta
requisição). As 5 filas de teste ficam com `status='done'` no banco — quando a corrida em
volume começar, esses 5 leads específicos (se estiverem no corte de 3.615/5.750) já não serão
reprocessados, sem custo adicional.

## 7. Limitações conhecidas (não resolvidas nesta sessão, deliberado)

1. **Anexos embutidos em comentários** (campo `attachments[]` do objeto de comentário, ex.:
   links do Dropbox) não são capturados por este job — ele só cobre o endpoint dedicado de
   anexos do lead. Achado incidental da pesquisa da API (seção 1), fora do escopo de D11/D14
   (que falam de "anexos de documento por lead", o caso dedicado). Se algum dia importar,
   registrar como item separado.
2. **Serving dos anexos migrados** pelo Imoviz depende de uma mudança pequena no endpoint de
   download existente (branch por `storage_backend`) — não feita agora, ver seção 4.
3. **`/etc/casagora-router.env` desatualizado** (seção 2) — recomendado corrigir, não fiz.

## 8. Próximo passo

Escopo desta sessão terminou no teste de 5 leads. **Nenhuma corrida em volume foi iniciada** —
aguardando autorização explícita para:
(a) montar a lista real dos 3.615 leads truncados (D14) e dos 5.750 do corte (seção 6 de
`fase1b-migracao-base.md`) e semeá-la na fila;
(b) criar e habilitar o `systemd service` pra rodar a corrida de dias sem supervisão manual.
