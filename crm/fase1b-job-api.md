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

## 8. Reconciliação do corte real — divergência encontrada e corrigida (22/07/2026)

Ao montar a lista real de IDs pra semear a fila (D12/seção 6 de `fase1b-migracao-base.md`
falava em **5.730-5.763 leads**, won+todo+standby), recontei diretamente os 3 arquivos do
export de 21/07 (`/root/nocrm-export/nocrm-leads-2026-07-21-*.csv`, os mesmos que embasaram
o D12) com um parser real (`xlsx`, respeitando campos com quebra de linha — `wc -l` não serve
nesse CSV, ele conta ~409k linhas para 145.719 registros reais por causa de comentários
multi-linha dentro de células).

**Validação cruzada, bate exato com o doc**: `won` = **1.582** (doc: "1.582") e, dentro dos
`won`, `Step` = "09 - Assinado" em **1.419** e "08 - Proposta Tirada" em **129** — os dois
números citados literalmente na seção 8.1.1 do plano de migração. Confirma que a coluna
`Status`/`Step` identificada é a certa.

**Divergência real**: `todo` = **2.186** e `standby` = **360** (recontagem direta, reproduzível
agora) — bem diferente do `todo` 1.601-1.631 / `standby` 2.518-2.580 do documento. Corte real
verificado: **4.128 leads** (won 1.582 + todo 2.186 + standby 360), não 5.730-5.763. Não foi
possível reconstruir com confiança, no tempo desta sessão, **qual** metodologia gerou os
números antigos de todo/standby (provavelmente um snapshot ou critério diferente) — mas como
`won` e o cruzamento com `Step` batem exatamente, a contagem `Status` atual está correta contra
a fonte primária (os próprios arquivos do export). **Ação**: segui com os 4.128 verificados,
sem tentar restaurar os 5.730-5.763 não reproduzíveis. Recomendo o Vagner revisar essa
divergência quando houver tempo — não bloqueia a extração (ela só fica mais restrita, nunca
processa lead a menos que devesse).

Pelo mesmo motivo (risco de reconstruir errado uma metodologia que não bate mais), **não tentei
isolar os "3.615 truncados"** (D14) dentro desse corte — uma tentativa de replicar o critério
"≥4 comentários visíveis" bateu em **2.988** dos 4.128, mas essa contagem herda a mesma
incerteza de metodologia. Decisão: **semear comentários para os 4.128 leads inteiros do corte**
(não só o subconjunto truncado) — mais simples, sem risco de reconstrução, custo extra pequeno
(~1.140 requisições a mais, menos de 1 dia extra no orçamento de 1.500/dia).

### 8.1 Resolvido com dado: divergência é metodologia, não movimentação real (22/07/2026)

O Vagner apontou corretamente que os corretores trabalham os leads todo dia (mudam etapa e
status), então a extração mira um alvo em movimento — a pergunta certa era separar "diferença
de metodologia" de "movimentação real entre os exports de 19/07 e 21/07" com dado, não
suposição. Comparado **o mesmo `ID` de lead nos dois exports** (145.619 leads presentes nos
dois; 100 novos só em 07-21, nenhum sumiu de 07-19 pra 07-21):

| | 07-19 | 07-21 |
|---|---|---|
| `won` | 1.581 | 1.582 |
| `todo` | 1.965 | 2.186 |
| `standby` | 550 | 360 |
| `cancelled` | 141.464 | 141.532 |
| `lost` | 59 | 59 |
| Corte (não-morto) | **4.096** | **4.128** |

**Só 376 dos 145.619 leads (0,26%) mudaram de status em 2 dias** — movimentação real existe e é
contínua, mas é pequena. Transições dominantes: `standby→todo` (243, corretor avançou o
atendimento), `todo→standby` (71), `todo→cancelled` (39) e `standby→cancelled` (20) — essas
duas últimas são saídas reais do corte (59 no total); só 3 entradas de volta (`cancelled→standby`
1, `cancelled→todo` 1, `standby→won` 1). O saldo líquido do corte (4.096→4.128, +32) bate com
"+100 leads novos, alguns não-vivos" menos "~59 saíram por cancelamento" — **totalmente
explicado por movimentação real pequena**, nada próximo de reconciliar uma diferença de ~1.600
leads.

**Conclusão**: a divergência de ~1.600 leads entre os 4.128 verificados e os 5.730-5.763 do
documento original **é diferença de metodologia**, não movimentação real entre os exports —
a movimentação real no período é ordens de grandeza menor que a divergência. Fica confirmado
que o número certo pra trabalhar é o verificado (4.128 em 07-21); a origem exata do número
antigo continua não reconstruída, mas deixou de ser candidata a explicar a diferença.

### 8.2 Ampliação para "todos os não-cancelados" — sem leads adicionais (verificado)

Pedido: ampliar a fila pra **todo** lead que não seja `cancelled`/`lost` (não só won/todo/
standby), já que o custo de omitir é maior que ~1 requisição de comentário por lead a mais.
Verificado contra o export de 07-21: **só existem 5 valores de `Status`** na base inteira
(`cancelled`, `won`, `todo`, `standby`, `lost` — somam exatamente os 145.719 registros, sem
sobra). Ou seja, "não-cancelado/não-perdido" e "won+todo+standby" são **o mesmo conjunto** hoje
— **4.128, sem leads adicionais pra semear**. A regra de seleção passa a ser, daqui pra frente,
"`status not in ('cancelled','lost')`" (não mais uma lista fixa de 3 valores) — mesmo resultado
agora, mas correta automaticamente se um sexto status aparecer num export futuro.

## 9. ETA recalculado (22/07/2026, com dado verificado + achado de que download não conta na cota)

Esclarecimento primeiro: "o download de anexos não conta na cota" (a busca real do binário via
URL assinada do S3, seção 1) **já estava implicitamente fora** da estimativa original do
`fase1b-migracao-base.md` — o "1 lista + 1-2 downloads" da seção 5 sempre quis dizer "1 lista +
1-2 chamadas de `retrieve-one`" (que geram a URL e **essas sim** contam), não o fetch do S3 em
si. Esse achado **confirma** a metodologia antiga, não muda os números por si só — o que muda
o ETA é o corte real (4.128, não 5.730) e ter uma amostra real medida (seção 6) em vez de só
uma estimativa.

| Fase | Leads | Requisições/lead | Total requisições | A 1.500/dia |
|---|---|---|---|---|
| **Comentários** (todos os 4.128, não só truncados) | 4.128 | 1 (fixo, sem paginação) | 4.128 | **3 dias** |
| **Anexos** — cenário conservador (estimativa original da seção 5) | 4.128 | ~2,5 | ~10.320 | **~7 dias** |
| **Anexos** — cenário observado (amostra real de 5 leads `won`, seção 6) | 4.128 | ~6,4 | ~26.400 | **~18 dias** |

A amostra de 5 leads é pequena e só cobriu `won` (que tende a ter mais documentos por ser
negócio fechado) — o número real só fica claro com volume de verdade. Tratamento: reportar a
taxa real observada no relatório diário (seção 10) assim que a fase de anexos come çar
(depois que comentários esvaziar, ~3 dias) e recalcular o ETA nesse ponto com dado real de
milhares de leads, não 5.

## 10. GO-AHEAD executado (22/07/2026)

Autorizado pelo Vagner após: (a) resíduo da rotação de credenciais fechado em todos os
consumidores exceto a spec do `arkontech_postgres` (adiada pra janela de baixo uso, ver
`rotacao-credenciais.md`); (b) ETA recalculado (seção 9); (c) condições de operação autônoma
definidas — relatório diário consultável + circuit breaker de taxa de erro. Sem necessidade de
novo ok entre comentários e anexos, encadeado via `systemd`.

### Adições ao job antes de rodar em volume

- **Relatório diário** (`nocrm_extraction_daily_report`, `day, task_type, pending, done, error,
  requests_used`): atualizado a cada virada de dia (e ao esgotar orçamento/esvaziar fila) — uma
  linha por dia por tipo, consultável via SQL direta ou `node scripts/nocrm-extraction-job.js
  status` (mostra o dia corrente; histórico fica na tabela).
- **Circuit breaker**: para sozinho se a taxa de erro passar de 30% numa janela dos últimos 20
  processados (com mínimo de 10 antes de julgar) OU 5 falhas seguidas. Ao disparar: grava em
  `nocrm_extraction_alerts`, manda e-mail via Resend (mesmo `RESEND_API_KEY`/`RESEND_FROM_EMAIL`
  que o app já usa) pra `NOCRM_EXTRACTION_ALERT_EMAIL`, e o processo sai com código **42**
  (distinto de sucesso/crash comum) — o `systemd` (`RestartPreventExitStatus=42`) não reinicia
  sozinho nesse caso, fica parado até alguém olhar.

### Infraestrutura de execução

- Imagem dedicada `casagora/nocrm-extraction:latest` (`scripts/nocrm-extraction.Dockerfile`,
  `node:22-alpine` + `rclone` já instalado em build time, não a cada start).
- Dois `systemd services`: `nocrm-extraction-comments.service` e
  `nocrm-extraction-attachments.service`, ambos `Restart=on-failure`, presos à rede Docker
  `easypanel` (alcançam `arkontech_postgres` pelo nome). O de comentários tem
  `OnSuccess=nocrm-extraction-attachments.service` — quando a fila de comentários esvaziar
  (saída limpa, não circuit-breaker), o `systemd` dispara o de anexos **sozinho**, sem
  intervenção manual.
- `/etc/nocrm-extraction.env` (`600`) — credenciais puxadas da spec viva do serviço Swarm
  (`docker service inspect casagora_router_api`), mesmo padrão usado no teste da seção 6.

### Execução

- Filas semeadas: **4.128 leads** em `comments` e **4.128 leads** em `attachments` (mais os 5
  já processados no teste da seção 6 — idempotente, não reprocessou).
- `nocrm-extraction-comments.service` iniciado às 13:08 UTC de 22/07/2026 — confirmado
  processando leads reais nos primeiros segundos (`journalctl -u nocrm-extraction-comments`).
  `attachments.service` habilitado, aguardando o `OnSuccess=` do estágio de comentários.
- ETA revisado: comentários terminam em ~3 dias corridos (~25/07); anexos começam
  automaticamente depois, ETA entre 7-18 dias a confirmar com dado real (seção 9).
- Às ~13:25 UTC, orçamento do dia já em 1.469/1.500 e 1.437 dos 4.128 leads de comentários
  processados (zero erro) — corrida saudável, ritmo bate com o ETA projetado.

## 11. Teste do canal de alerta (22/07/2026)

Antes de precisar do circuit breaker de verdade, disparado manualmente pelo mesmo caminho que
ele usa (`raiseAlert()`, novo subcomando `node scripts/nocrm-extraction-job.js test-alert`) —
não é um envio paralelo/simulado, é o código real. **Achado no processo**: o SDK do Resend não
lança exceção em erro de API (domínio não verificado, chave inválida etc.) — vem como
`{error}` no retorno; o código original só checava exceção, então um envio recusado teria
logado "enviado" incorretamente. Corrigido para checar o campo `error` antes de declarar
sucesso. Reenviado após o fix: aceito de verdade pelo Resend, `id`
`d9357d90-e686-4b7a-bae1-1e06096e3263`, para `voliveirarosa@gmail.com`; linha correspondente
confirmada em `nocrm_extraction_alerts`.

**Confirmado pelo Vagner (22/07/2026)**: os dois e-mails de teste chegaram na caixa de entrada
(não caíram em spam), formato claro, com instruções de recuperação. **Canal de e-mail
validado, ponta fechada.**

## 12. Segundo canal de alerta — WhatsApp via Evolution API (22/07/2026)

Pedido do Vagner: canais redundantes (e-mail permanece; WhatsApp se soma, não substitui),
reaproveitando a instância Evolution que já roda na VPS (projeto `agenciadeia`).

### Descoberta da instância

`GET /instance/fetchInstances` na Evolution API (mesma usada pelo `casagora_router_api` pra
disparo de leads) — **uma única instância**, `"Sistema Casagora"`, estado `open` (conectada).
Sem ambiguidade, nada pra escolher — a mesma instância que o app principal já usa pra falar com
os corretores.

### Implementação

`raiseAlert()` agora dispara os dois canais **em paralelo** via `Promise.allSettled` — uma
exceção ou falha num canal não impede o outro nem derruba o processo (nenhum dos dois `await`
consecutivos que existiam antes; agora são duas promises independentes, cada uma com seu
próprio try/catch interno). O resumo de quem funcionou/falhou (`{email: {ok, info}, whatsapp:
{ok, info}}`) vai junto no `detail` gravado em `nocrm_extraction_alerts`.

WhatsApp usa o mesmo endpoint que o app principal já usa (`POST /message/sendText/{instance}`,
header `apikey`) — implementação própria no script (standalone, não importa de `server.js`
por causa da IIFE, ver `project_whatsapp_fix` nas notas do projeto). **Mesma cautela do bug do
Resend, aplicada de propósito**: não basta checar se a chamada não lançou exceção — a Evolution
pode responder `200` com corpo de erro estrutural, ou HTTP 4xx/5xx; o código checa os dois
(`!resp.ok || body.error`) antes de declarar sucesso.

### Número de destino — só em variável de ambiente

**Nunca no código nem neste documento.** Variável nova: `NOCRM_EXTRACTION_ALERT_WHATSAPP`
(dígitos apenas, com DDI — ex.: formato `55DDNNNNNNNNN`), lida de
`/etc/nocrm-extraction.env` (mesmo arquivo `600` que já guarda `NOCRM_EXTRACTION_ALERT_EMAIL`
e as demais credenciais reaproveitadas). Linha já criada nesse arquivo, **vazia** — o Vagner
preenche o valor diretamente no arquivo (fora deste chat/doc) antes do teste real. As duas
`systemd unit files` (`nocrm-extraction-comments.service`,
`nocrm-extraction-attachments.service`) já foram atualizadas pra repassar
`EVOLUTION_BASE_URL`/`EVOLUTION_API_KEY`/`EVOLUTION_INSTANCE`/`NOCRM_EXTRACTION_ALERT_WHATSAPP`
do env file pro container — só falta o valor do número e um restart do serviço (ou aguardar o
próximo start natural) pra pegar a mudança.

### Teste real — confirmado (22/07/2026)

Número preenchido pelo Vagner em `/etc/nocrm-extraction.env` (fora deste chat/doc, como
combinado). `test-alert` disparado de novo: **os dois canais aceitos pela API**
(e-mail com `id` do Resend; WhatsApp com HTTP 201 e `key` de mensagem da Evolution) — mesma
linha gravada em `nocrm_extraction_alerts` com o resumo `{email:{ok:true}, whatsapp:{ok:true}}`.
**Confirmado pelo Vagner**: a mensagem chegou de verdade no WhatsApp, conteúdo íntegro (texto
completo do alerta, incluindo o passo de recuperação). **Canal WhatsApp validado — os dois
canais de alerta (e-mail + WhatsApp) estão redundantes e confirmados de ponta a ponta.**

`nocrm-extraction-comments.service` reiniciado pra carregar as variáveis novas
(`EVOLUTION_*`/`NOCRM_EXTRACTION_ALERT_WHATSAPP`) — progresso da fila não afetado (estado vive
no Postgres, o restart só recarrega o processo). `nocrm-extraction-attachments.service` já
nasce com a spec atualizada quando o `OnSuccess=` disparar.

## 13. Incidente — job derrubou a produção por estourar a cota (22/07/2026)

### O que aconteceu

Às 13:08 UTC o `nocrm-extraction-comments.service` começou a rodar com o orçamento diário de
1.500 (seção 10). Sem nenhum controle de ritmo **dentro** do dia, ele consumiu **os 1.500 em
13 minutos** (13:08–13:21 UTC, ~115 req/min — confirmado pelos timestamps de
`nocrm_extraction_queue`). Isso deixou só ~500 requisições de folga pra todo o resto das ~23h
do dia — o app principal já vinha usando uma fatia disso desde a meia-noite UTC (sync diário
+ `queue-reconcile` horário), e às **14:05 UTC** (44 minutos depois da rajada) o próprio
`queue-reconcile` tomou 429 tentando `nocrmSyncUsers`. Às **14:04:48 UTC** um lead manual real
(Vinícius Ferreira da Silva, captado via corretor/Instagram) também bateu no 429 ao tentar
criar no noCRM.

Confirmado com uma chamada mínima de teste às 14:13 UTC: a cota da conta **estava mesmo
zerada**, com reset só às **23:59:59 UTC** do mesmo dia (não é uma janela rolante de 24h — é
fixo à meia-noite UTC da conta).

### Impacto real (verificado no banco, não estimado)

- **1 lead** caiu no fallback manual (`manual_leads`, id 799, `nocrm_lead_id is null`,
  `nocrm_error` gravado) — **nenhum dado foi perdido**: o sistema já tinha esse fallback
  desenhado antes deste job (não construído nesta sessão) — o corretor recebeu a mensagem
  clara `"Recebido. O noCRM está com limite de API no momento."`, o payload completo ficou
  salvo pra entrada manual depois, e a Casagora recebeu o alerta de sempre (🚨 WhatsApp,
  `flushNocrm429Alerts`) com o texto pronto pra copiar/colar no noCRM.
- Confirmado que os 3 pontos do código que criam lead no noCRM (Facebook Ads, manual-lead
  atual, manual-lead legado) têm o mesmo fallback — nenhum caminho perde lead silenciosamente,
  mas **qualquer lead novo que precisasse do noCRM entre 14:05 UTC e a meia-noite ficaria no
  mesmo fallback manual** enquanto a cota não resetasse.
- `queue-reconcile` (hourly) ficaria falhando `nocrmSyncUsers` a cada hora até a meia-noite,
  sem efeito visível pro usuário (é só sincronização de cadastro de corretor, não bloqueia
  operação).

### Ação imediata

`nocrm-extraction-comments.service` e `nocrm-extraction-attachments.service` parados e
**desabilitados** (`systemctl stop` + `disable`) assim que o padrão ficou claro — zero consumo
adicional de cota da minha parte a partir daí. Vagner decidiu contatar o suporte do noCRM
pedindo aumento/reset (a própria mensagem de erro sugere isso: *"Please contact the support to
raise your limit"*) — independente da resposta, **a extração não volta hoje**.

### Causa raiz

O orçamento era só **diário** (`NOCRM_EXTRACTION_DAILY_BUDGET=1500`) — nenhum controle de
ritmo dentro do dia. "Sobrar" no total do dia não protege nada se o job gasta tudo de uma vez
logo cedo: a reserva teórica de 500/dia pro app não existia de fato às 14h, porque o job já
tinha queimado a sua parte inteira nos primeiros 13 minutos.

### Correção (`scripts/nocrm-extraction-job.js`, commit `3640b35`)

Dois tetos independentes agora, **o menor sempre vale**:

1. **Reserva diária fixa pro app, calculada ANTES do teto do job** —
   `NOCRM_EXTRACTION_APP_RESERVED_DAILY` (default **1.000** de um limite de conta de **2.000**,
   `NOCRM_ACCOUNT_DAILY_LIMIT`). O teto do job passa a ser `conta - reserva` (hoje: **1.000**),
   não mais um número solto desacoplado do que a conta realmente permite.
2. **Teto por hora** — `NOCRM_EXTRACTION_HOURLY_BUDGET` (default **40/hora**, nova tabela
   `nocrm_extraction_hourly_budget`) — o job nunca mais pode rajar, mesmo que sobre orçamento
   diário. A 40/hora, 24h seguidas dariam 960 — abaixo do teto diário de 1.000, com folga.
   Ao esgotar a hora, o job dorme até a **próxima hora cheia UTC** (não mais um retry de
   15min genérico); ao esgotar o dia, dorme até a meia-noite UTC (ou de hora em hora,
   o que vier primeiro).

`/etc/nocrm-extraction.env` e as duas `systemd unit files` já atualizadas com as variáveis
novas. Reserva de 1.000/dia pro app é deliberadamente generosa (uso medido do app antes desta
sessão era ~100-300/dia) — margem grande de propósito pra nunca mais disputar espaço com
picos de captação de lead.

### Lição

Um job de migração que compartilha `NOCRM_API_KEY` com produção **nunca pode assumir que
"sobra" no agregado diário é proteção suficiente** — o app precisa de uma fatia **sempre
disponível a qualquer hora do dia**, não só "em média". Todo job batch que dispute cota com um
sistema vivo precisa de teto por hora (ou janela menor), não só teto diário — o teto diário
sozinho é compatível com uma rajada que zera tudo de manhã e deixa o resto do dia desprotegido.

## 14. Reserva calibrada com dado real (22/07/2026)

Antes de retomar, medido o consumo histórico real de API do app principal (30 dias) — a
reserva de 1.000/dia da seção 13 era um chute conservador, não uma medição. Fonte: `pg`,
contagem diária de `nocrm_webhook_events` (distinct `lead_id` por dia — cada lead distinto
com evento novo dispara **1** chamada `GET /leads/{id}` no worker de refresh, `server.js`
linha ~2327, `ON CONFLICT (lead_id)` coalesce múltiplos eventos do mesmo lead no mesmo dia
numa só chamada) + `lead_events` (Facebook Ads) + `manual_leads` + `landing_page_leads`
(criação de lead, 1 requisição cada) + overhead fixo diário (124 = 24 de `queue-reconcile`
horário `nocrmSyncUsers` + ~100 do sync incremental diário).

### Achado: o app usa MUITO mais do que a estimativa original de 25h sugeria

| Métrica (30 dias) | Valor |
|---|---|
| Média | 645/dia |
| Mediana | 701/dia |
| P90 | 870/dia |
| **Pico** (30/06/2026) | **1.039/dia** |

A amostra de 25h usada antes (seção 10, "uso medido ~100-300/dia") pegou uma janela
atipicamente calma — o driver real e dominante **não é criação de lead** (Facebook Ads +
manual + LP somam só ~50-100/dia no pico), é o **worker de refresh disparado por webhook**
(corretor mexe no lead dentro do próprio noCRM — muda etapa, adiciona comentário, etc. — isso
dispara um webhook que o app usa pra re-buscar o lead inteiro): até **835 leads distintos por
dia** no pico, e regularmente 400-700/dia em dias normais de operação.

### Reserva nova: pico + 50% (conforme pedido)

`NOCRM_EXTRACTION_APP_RESERVED_DAILY`: 1.039 × 1,5 = 1.558,5 → **1.560**. Isso **reduz** o teto
do job, não aumenta — o pico real está bem mais perto do limite de 2.000 da conta do que a
estimativa original de 1.000 sugeria. **Teto do job cai de 1.000 para 440/dia**
(`2.000 − 1.560`). Não dava pra saber isso sem medir — o pedido de calibrar com dado real
revelou o oposto do que se esperava (mais orçamento pro job), mas é o número que a operação
real sustenta com segurança.

### Teto por hora — variação dia/noite (implementado, simples)

Distribuição por hora UTC dos leads distintos com evento novo (30 dias) mostra uma janela
clara de uso baixo:

| Faixa UTC | Leads distintos/dia (típico) |
|---|---|
| 06h-10h (03h-07h Brasília) | 12-101 — **mínimo do dia** |
| 11h-20h (08h-17h Brasília) | 700-2.071 — horário comercial |
| 21h-05h (18h-02h Brasília) | 57-361 — noite, moderado |

Implementado (`scripts/nocrm-extraction-job.js`, commit `48f8557`): teto por hora com dois
valores — `NOCRM_EXTRACTION_HOURLY_BUDGET_NIGHT=80` na janela `06h-10h UTC`
(`NOCRM_EXTRACTION_NIGHT_START_UTC`/`_END_UTC`) e `NOCRM_EXTRACTION_HOURLY_BUDGET=10` no
resto do dia. **A reserva diária (1.560) continua intocada a qualquer hora** — o par dia/noite
só decide *quando* dentro do teto diário o job pode ir mais rápido, nunca aumenta o total.
Na prática: a maior parte dos 440/dia deve ser consumida nas 4h da janela noturna (até
4×80=320), com um trecho pequeno (~120) de mais desses, quando emerge, sobrando pro comércio
horário como reforço se sobrar orçamento diário.

### ETA recalculado com os números novos

| Fase | Pendente hoje | Requisições/lead | Total | A 440/dia |
|---|---|---|---|---|
| **Comentários** | 2.660 (de 4.128 — 1.468 já feitos) | 1 | 2.660 | **~7 dias** |
| **Anexos** — cenário conservador | 4.123 (de 4.128 — 5 já feitos) | ~2,5 | ~10.308 | **~24 dias** |
| **Anexos** — cenário observado (amostra de 5) | 4.123 | ~6,4 | ~26.387 | **~60 dias** |

ETA de anexos ficou bem mais longo que a estimativa anterior (7-18 dias) — reflexo direto da
reserva maior/mais segura. Mesmo tratamento de antes: reportar taxa real assim que a fase de
anexos começar (relatório diário, seção 10) e recalcular nesse ponto com dado de milhares de
leads, não 5.

### Estado — pronto pra retomar, aguardando ok explícito

`nocrm-extraction-comments.service` e `nocrm-extraction-attachments.service` seguem
`disabled`/`inactive` (confirmado após as mudanças de config). `/etc/nocrm-extraction.env` e
as duas `systemd unit files` já atualizadas com a reserva e o par dia/noite calibrados. Nada
retoma sozinho — precisa de `systemctl enable --now nocrm-extraction-comments.service`
explicitamente autorizado pelo Vagner, começando pelos comentários.

## 16. Limite temporário de 10.000/dia (suporte noCRM) + proteção por cota real (22/07/2026)

O suporte do noCRM **aumentou o limite para 10.000 requisições/dia por 2 semanas**, confirmado
no painel da conta. **Prazo: até ~2026-08-05.** Depois disso o limite volta a 2.000/dia — o
job **não pode assumir sozinho** que o valor elevado continua válido além dessa data (ver
"Proteção de prazo" abaixo).

### 16.1 Recalibração do orçamento

A reserva do app (`APP_RESERVED_DAILY = 1.560`, seção 14) **não muda** — ela protege o
consumo real do app, que não depende de quanto a conta permite no total. O que muda é o teto
do job: `10.000 − 1.560 = 8.440/dia` (era 440/dia).

Teto por hora recalibrado na mesma proporção dia:noite (1:8) da calibração original (seção
14), escalado pro novo orçamento:

| | Antes (limite 2k) | Agora (limite 10k, temporário) |
|---|---|---|
| Teto do job (dia) | 440/dia | **8.440/dia** |
| Teto por hora — diurno | 10/hora | **160/hora** |
| Teto por hora — noturno (06h-10h UTC) | 80/hora | **1.280/hora** |

### 16.2 Achado: teto por hora sozinho não bastava mais — pacing intra-hora

Com tetos por hora desta ordem de grandeza, o mecanismo antigo (buscar até `--limit` linhas do
banco por tick, processar todas de uma vez, dormir só entre ticks) permitiria queimar o teto
da hora inteira em poucos minutos e ficar ocioso o resto da hora — **o mesmo padrão do
incidente de 22/07 (seção 13), só que dentro de 1h em vez do dia inteiro**, e ainda violaria
o princípio "nunca concentrar tudo em minutos". Corrigido: nova função
`interRequestDelayMs()` espaça cada requisição real dentro do lote (`3.600.000 / teto por
hora` ms, mínimo 500ms) — a 160/hora isso dá ~22,5s entre chamadas; a 1.280/hora, ~2,8s.
Confirmado ao vivo pós-deploy: leads processando a cada ~24s no regime diurno, sem rajada.

### 16.3 Proteção nova: cota REAL da conta via header (não só o contador interno do job)

Pedido do Vagner: os corretores trabalham em tempo real, e um dia atipicamente movimentado
(que a média de 30 dias, seção 14, não prevê) pode fazer o app consumir mais do que a reserva
calculada — o contador interno do job (que só sabe o que ELE mesmo gastou) não enxerga isso.

Verificado ao vivo (`curl` de teste, 22/07/2026 ~18h57 UTC): a API do noCRM retorna o header
**`api-requests-left`** em toda resposta (200 e 429), com a cota real restante da conta
inteira — não é uma estimativa, é o número que a própria API está usando pra decidir o 429.

Implementado: `nocrmGet()` lê esse header a cada chamada e grava o valor (memória + tabela
`nocrm_extraction_account_quota`, singleton, sobrevive a restart do processo). Antes de cada
item e a cada início de lote, o job checa: se a cota real da conta ≤ reserva do app (1.560),
**para sozinho** (`exhausted: 'account_reserve'`, mesmo tratamento do teto diário — dorme e
tenta de novo até a virada UTC), **independente do que o contador próprio do job diga**.
Dispara alerta (dual-channel, dedup 1x/dia) avisando que foi um dia atípico do app.

### 16.4 429 real agora é parada dura, não pausa-e-retoma

Antes: um 429 real pausava a corrida (`sleep(retryAfter)`) e tentava de novo sozinho no mesmo
dia. Pedido do Vagner: **isso significa que a proteção inteira falhou** (reserva + pacing por
hora + cota real, as três, teriam que falhar ao mesmo tempo pra um 429 acontecer de verdade) —
não é "esperar passar", é sinal de bug ou premissa errada que precisa de olho humano antes de
voltar a gastar cota. Mudado: 429 real agora **para o processo imediatamente** (não espera o
`API-RETRY-AFTER`), dispara alerta dual-channel, e sai com **exit 42** — mesmo tratamento do
circuit breaker (`RestartPreventExitStatus=42`, `systemd` não reinicia sozinho).

### 16.5 Proteção de prazo — o limite de 10k não pode sobreviver ao próprio prazo

`NOCRM_ACCOUNT_LIMIT_EXPIRES_AT=2026-08-05` (novo, `/etc/nocrm-extraction.env`). O job checa
essa data a cada tick (comparação de string `YYYY-MM-DD`, UTC): passado o prazo, o `NOCRM_
ACCOUNT_DAILY_LIMIT` configurado (10.000) é **ignorado automaticamente** — o cálculo do
orçamento diário cai pro `NOCRM_ACCOUNT_DAILY_LIMIT_FALLBACK` (2.000, default) mesmo que
ninguém tenha limpado a variável no arquivo ainda. Dispara alerta (dedup 1x/dia) avisando da
queda pro fallback, pra caso o Vagner precise pedir renovação ao suporte ou só confirmar que
o valor antigo está certo de novo.

### 16.6 `OnSuccess=` reativado — anexos encadeiam sozinhos de novo

Removido em 22/07 (seção 15) enquanto o ETA de anexos era inviável (24-60 dias) e a fila não
tinha prioridade. Com o limite temporário (ETA de dias, não semanas, seção 16.7) e a fila já
priorizada won→todo→standby (seção 15.1), `OnSuccess=nocrm-extraction-attachments.service`
voltou pro unit de comentários — quando a fila de comentários esvaziar (saída limpa, não
breaker/429), o `systemd` dispara anexos sozinho, sem intervenção manual.

### 16.7 Marcos de progresso — alerta em sucesso, não só em falha

Os alertas existentes (breaker, 429, proteção de reserva/prazo) só cobrem falha — nada avisava
quando a extração progredia normalmente. Adicionado (dedup permanente, um por vida da
migração): alerta quando a fila de comentários esvazia de verdade (junto avisa que anexos vão
disparar via `OnSuccess`) e quando o processo de anexos roda pela primeira vez. Os dois usam o
mesmo canal dual (e-mail + WhatsApp) dos alertas de proteção.

### 16.8 ETA recalculado (22/07/2026, ~19h UTC, com os números desta seção)

| Fase | Pendente | Requisições/lead | Total | Nova taxa | ETA projetado |
|---|---|---|---|---|---|
| **Comentários** | 2.660 (de 4.128) | 1 | 2.660 | ~160-1.280/hora (paceado) | **~23/07, ~06h45 UTC** (03h45 Brasília) — amanhã de manhã |
| **Anexos** — conservador (~2,5 req/lead) | 4.123 | ~2,5 | ~10.308 | idem, a partir do fim dos comentários | **~24/07, meio da manhã UTC** — ~1,5 dia após início |
| **Anexos** — observado (amostra de 5, seção 6, viesada pra `won`) | 4.123 | ~6,4 | ~26.387 | idem | **~26/07, manhã UTC** — ~3,5 dias após início |

Ambos os cenários de anexos terminam com **folga grande** (8-9 dias) antes do prazo do limite
elevado (05/08). Mesmo tratamento de antes: reportar a taxa real observada assim que a fase de
anexos começar (relatório diário, seção 10) e recalcular nesse ponto com dado de milhares de
leads, não 5 — os números acima são projeção, não medição.

### 16.9 Reforço: extração DELTA continua obrigatória antes do Dia D

Nada nesta recalibração substitui a extração delta já registrada em
`fase1b-migracao-base.md` seção 7, item 2 — pelo contrário, o achado do Vagner que motivou
essa recalibração (corretores trabalham os leads em tempo real) é o mesmo motivo pelo qual o
delta é **obrigatório**, não opcional: comentários e anexos continuam sendo criados agora
mesmo em leads já extraídos por este job. Rodar só a extração inicial e nunca mais tocar nela
deixaria o Imoviz permanentemente defasado do noCRM entre o fim desta corrida e o Dia D. O
comando de re-seed (`done` → `pending` pros leads do corte, pra forçar reprocessamento) segue
**não construído** — pré-requisito técnico do Dia D, registrado como gap conhecido em
`fase1b-migracao-base.md` seção 7.

## 15. Retomada autorizada (só comentários) + 3 encaminhamentos (22/07/2026)

Vagner autorizou retomar **só o job de comentários**, após a virada UTC, com o pacing novo.
Anexos ficam pausados até decisão futura (ETA de 24-60 dias considerado inviável por ora).
Vai pedir ao suporte do noCRM aumento temporário de limite (10.000/dia por 2-3 semanas) — se
vier, recalibra tudo de novo.

### Ação: retomado, sem risco de tocar a API antes da virada

`OnSuccess=nocrm-extraction-attachments.service` **removido** de
`nocrm-extraction-comments.service` — a fila de comentários, quando esvaziar (ETA ~7 dias),
não vai mais disparar anexos sozinha. `nocrm-extraction-attachments.service` continua
`disabled`.

`nocrm-extraction-comments.service` **habilitado e iniciado às 14:55 UTC de 22/07/2026** — mas
sem risco de gastar cota hoje: o próprio orçamento diário do job (calendário UTC, mesma
virada da conta) já registrava 1.500 usados hoje (do incidente), acima do novo teto de 440 —
o processo detectou isso na primeira checagem (`orçamento DIÁRIO esgotado (440/dia, reserva
de 1560 pro app) - aguardando virada UTC`) e foi dormir **sem fazer nenhuma chamada real à
API**. Retoma sozinho, automaticamente, quando o contador do dia zerar na virada UTC (mesma
lógica que já existia, sem intervenção manual necessária à meia-noite).

### 15.1 Priorização da fila de anexos por valor (implementado)

Pedido: se o processo precisar ser cortado, o valor deve estar na frente. Nova coluna
`priority` em `nocrm_extraction_queue` (menor valor = processado primeiro;
`order by priority asc, next_run_at asc`, índice recriado). Fila de anexos (já semeada, 4.128
leads) reordenada: **won → todo → standby**, e dentro de cada grupo, `nocrm_lead_id` numérico
decrescente como proxy de recência (IDs do noCRM são sequenciais por criação — maior ID =
lead mais recente). `seed` aceita `--priority N` opcional pra uso futuro (ex.: extração
delta, seção 8 de `fase1b-migracao-base.md`, pode priorizar o que for mais urgente).

### 15.2 Investigação: redundância no worker de refresh por webhook

Pedido: o worker que refaz `GET /leads/{id}` a cada webhook do noCRM tem redundância (mesmo
lead editado várias vezes em minutos = várias chamadas)? Dá pra agrupar/debounce?

**Como funciona hoje** (`server.js`, `/webhooks/nocrm` + `processNocrmLeadRefreshJobs`):
cada webhook com `lead_id` faz `INSERT ... ON CONFLICT (lead_id) DO UPDATE SET next_run_at =
LEAST(next_run_at, now())` em `nocrm_lead_refresh_jobs` (chave única por lead) — múltiplos
webhooks pro mesmo lead **antes** do worker processá-lo já coalescem numa linha só (não cria
duplicata). O worker roda a cada 5 min (`NOCRM_WEBHOOK_WORKER_INTERVAL_MS`), processa até 5
por tick (~60/hora de capacidade se nunca atrasar) e **apaga a linha** ao concluir — não fica
histórico de quantas vezes um lead foi realmente re-processado no mesmo dia.

**Medido (dado real, 7 dias, `nocrm_webhook_events`)**: pra cada lead com mais de um evento,
calculado o intervalo entre eventos consecutivos do mesmo lead — **5.833 pares
consecutivos**, dos quais **3.444 (59%) aconteceram em até 5 minutos** um do outro e **3.548
(61%) em até 10 minutos**. Ou seja: a maioria das re-edições do mesmo lead acontece em
rajada rápida (o corretor mexendo em vários campos/comentários numa única sessão de edição).

**Achado**: o design atual já evita duplicata **enquanto o job ainda não foi processado**
(upsert), mas não garante isso — se o worker pegar o lead **no meio** de uma rajada de
edição (job criado, processado e apagado, e minutos depois vem outra edição), vira uma
**segunda** chamada pra API pra praticamente a mesma sessão de trabalho. Quanto mais rápido o
worker processa (menos atrasado/sem backlog), mais provável isso acontece — o que é um pouco
contraintuitivo (folga de capacidade ajuda a criar mais chamadas, não menos).

**Proposta de PR pequeno** (não implementado — mudança em `server.js`, produção, fora do
escopo desta sessão de migração; desenhado pra revisão separada):

```diff
- `insert into nocrm_lead_refresh_jobs (lead_id, next_run_at, attempts, last_error, updated_at)
-  values ($1, now(), 0, null, now())
-  on conflict (lead_id) do update set
-    next_run_at = least(nocrm_lead_refresh_jobs.next_run_at, now()),
-    updated_at = now()`,
+ // debounce: cada novo webhook empurra o proximo refresh pra frente (nao mais "o mais cedo
+ // possivel") - uma rajada de edicoes no mesmo lead vira 1 chamada, nao N, garantido em vez
+ // de depender de sorte de timing do worker. NOCRM_REFRESH_DEBOUNCE_MINUTES, default 10.
+ `insert into nocrm_lead_refresh_jobs (lead_id, next_run_at, attempts, last_error, updated_at)
+  values ($1, now() + interval '${DEBOUNCE_MIN} minutes', 0, null, now())
+  on conflict (lead_id) do update set
+    next_run_at = now() + interval '${DEBOUNCE_MIN} minutes',
+    updated_at = now()`,
```

**Trade-off**: atraso de até `DEBOUNCE_MIN` (proposto 10min) antes de um lead **isolado** (sem
mais edições) ser refletido no Imoviz — hoje é quase imediato (próximo tick do worker, até
5min). Aceitável: esse dado alimenta relatório/espelho do CRM, não é UI transacional em tempo
real. **Benefício esperado**: coalescer rajadas de edição em 1 chamada em vez de possivelmente
várias — dado o padrão medido (59-61% dos pares em ≤10min), reduziria uma fração real do
volume de refresh, que hoje é o maior driver de consumo do app (seção 14). Medir o ganho real
depois de aplicado é simples: comparar `requests_hoje`/dia (relatório diário já existente,
seção 10) antes/depois do deploy.

**Não implementado nesta sessão** — fica como PR proposto, pendente de decisão/priorização
separada do Vagner (é código de produção do `casagora_router_api`, não do job de migração).

### 15.3 Reserva deve ser reavaliada periodicamente durante a Fase 1B

Registrado: a reserva de 1.560/dia (seção 14) foi calibrada com o **consumo atual** do app —
majoritariamente webhooks de edição de lead **dentro do próprio noCRM**. Conforme a equipe da
Casagora migra pro Imoviz (D11, `DECISOES.md`), menos gente edita lead no noCRM, menos webhook
dispara, e o consumo real do app deve **cair** ao longo da Fase 1B — não é uma constante.
**Ação recomendada**: reavaliar `NOCRM_EXTRACTION_APP_RESERVED_DAILY` periodicamente (ex.: a
cada 2 semanas, ou quando o Dia D dos incrementos de sync se aproximar) usando a mesma
metodologia da seção 14 (dado real de 30 dias, não suposição) — cada requisição que o app
deixar de precisar vira orçamento extra pra migração, sem precisar esperar resposta do
suporte do noCRM.

## 17. Incidente do ExecStop (23/07/2026) + análise de consumo real + watchdog de progresso (24/07/2026)

### 17.1 O que aconteceu (contexto, ver `rotacao-credenciais.md` para o relato completo)

O job de comentários terminou de verdade às 06:59 UTC de 23/07/2026 (marco
`extraction_milestone_complete:comments`), mas um bug nos units systemd
(`ExecStop=/usr/bin/docker stop <nome>` sem o prefixo `-`, que falha porque
o container `--rm` já se autorremoveu, fazendo o systemd marcar a corrida
como "falha" mesmo com exit 0 real) entrou num loop de restart de 30 em
30 segundos **pelo resto do dia** — e, criticamente, **nunca deixou o
`OnSuccess=` disparar a extração de anexos**. Corrigido só na madrugada de
24/07 (durante a rotação de credenciais, seção anterior deste documento).
Resultado prático: **a extração de anexos perdeu quase um dia inteiro**
sem processar nenhum lead, e ficou pausada mais um pouco durante a janela
de troca segura da `NOCRM_API_KEY` (rotação de credenciais, ~15min).

### 17.2 Consumo real vs. orçamento disponível — está sendo desperdiçado, mas não por causa do ritmo configurado

Dado real (`nocrm_extraction_budget`, `nocrm_extraction_hourly_budget`),
consultado 24/07/2026 às ~01:35 UTC:

| Dia | Requisições usadas | % do orçamento disponível (~8.440/dia*) |
|---|---|---|
| 22/07 | 2.181 | 26% |
| 23/07 | 2.269 | 27% |
| 24/07 (parcial, 1ª hora) | 160 | — |

\* `NOCRM_ACCOUNT_DAILY_LIMIT` (10.000) − `NOCRM_EXTRACTION_APP_RESERVED_DAILY`
(1.560) = 8.440/dia é o teto real do job enquanto a janela de 10k/dia
durar (até 05/08).

**Isso confirma desperdício real da janela** — só ~26-27% do orçamento
disponível foi usado nos últimos 2 dias. **Mas a causa não é o ritmo por
hora estar configurado conservador demais**: somando o teto diurno (160/h
× 20h = 3.200) + o teto noturno (1.280/h × 4h, janela 06h-10h UTC = 5.120),
o teto teórico já é **8.320/dia** — a menos de 2% do orçamento real
(8.440). Se o job rodar sem interrupção, batendo o teto por hora
consistentemente, ele **já usa quase todo o orçamento disponível** com a
configuração atual. Confirmado ao vivo: às 01:13 UTC de hoje o job bateu o
teto diurno de 160/h e entrou em espera até a próxima hora (comportamento
esperado, "orcamento POR HORA esgotado... aguardando proxima hora (pacing,
nao e' rajada)").

**Conclusão**: o desperdício dos últimos 2 dias foi 100% causado pelo
incidente do ExecStop (job parado, não rodando) e pela pausa da rotação
de credenciais — **não** por uma configuração de ritmo tímida. Não há
ajuste de `NOCRM_EXTRACTION_HOURLY_BUDGET`/`_NIGHT` que resolva um job que
não está rodando. Com o bug corrigido (23-24/07), a expectativa é que o
consumo diário suba naturalmente para perto do teto teórico de 8.320/dia
a partir de hoje, sem precisar tocar nos números — mas **isso ainda não
foi confirmado com um dia inteiro rodando sem interrupção**, só coisa de
minutos até agora.

### 17.3 ETA — com alerta explícito

Amostra real (24/07/2026, 54 leads já processados): **média de 8,9
requisições/lead** (1 de listagem + ~7,9 de download em média — volume
real bem maior do que uma estimativa grosseira de 2-3/lead). **Ressalva**:
amostra pequena (54 de 4.128) e a fila é processada em ordem de
prioridade (won → todo → standby, seção 6 de `fase1b-migracao-base.md`) —
`won` tem mais chance de ter mais anexos por causa do ciclo de venda mais
longo, então a média real pro restante da fila (mais `todo`/`standby`)
tende a ser **igual ou menor**, não maior. Trata-se de uma estimativa
conservadora (no sentido de "não otimista demais"), não uma medição
definitiva — repetir esse cálculo em alguns dias com amostra maior.

Com 4.074 leads pendentes (24/07, ~01:35 UTC):

| Cenário | Requisições necessárias | Ritmo | Dias | Data estimada | Dentro do prazo (05/08)? |
|---|---|---|---|---|---|
| **Se rodar no teto teórico (8.320/dia) sem mais interrupção** | ~36.259 (4.074 × 8,9) | 8.320/dia | ~4,4 dias | **~28-29/07** | ✅ folga confortável |
| **Se repetir o ritmo médio dos últimos 2 dias (~2.225/dia, com o bug ainda ativo em boa parte)** | ~36.259 | 2.225/dia | ~16,3 dias | **~09/08** | 🔴 **ESTOURA o prazo de 05/08** |

**Recomendação**: não é preciso aumentar os tetos por hora (já calibrados
perto do teto real) — o que importa é o job rodar **continuamente, sem
interrupção**, dali pra frente. Reavaliar esta projeção em 2-3 dias com
dado real de um dia inteiro sem incidente, pra confirmar se o ritmo
efetivo realmente converge pro cenário otimista. Se, depois de corrigido
o bug, o consumo diário real continuar bem abaixo de ~8.000/dia sem
nenhuma interrupção nova, aí sim vale investigar se há outro gargalo
(ex.: `interRequestDelayMs` sendo mais conservador que o necessário) —
não é o caso identificado até agora.

### 17.4 Watchdog de progresso (novo, 24/07/2026) — cobre o buraco que o circuit breaker não cobria

O circuit breaker existente (taxa de erro / falhas consecutivas) **não
detectou o incidente do ExecStop** porque, do ponto de vista do processo
Node, cada corrida terminava com sucesso genuíno (fila vazia, exit 0) —
o problema era inteiramente no nível do systemd, marcando esse sucesso
como falha. Nenhum erro, nenhuma taxa de falha, nada pro circuit breaker
perceber.

**Novo comando**: `node scripts/nocrm-extraction-job.js check-progress`
(commit `d2e011a`, `casagora-router`) — compara o `done` atual da fila
contra um checkpoint da corrida anterior (tabela nova
`nocrm_extraction_progress_checkpoint`, 1 linha por `task_type`). Se
`pending > 0` e `done` não avança há mais de
`NOCRM_EXTRACTION_STALL_ALERT_HOURS` (default **2 horas**), dispara o
mesmo alerta de 2 canais (e-mail + WhatsApp) já usado pelo circuit
breaker, com uma nota específica pro cenário ("processo pode estar
travado sem erro registrado, checar systemctl/journalctl"). Reenvio
suprimido enquanto o problema persistir (só alerta de novo depois de
outro intervalo de 2h) — evita floodar. Quando o progresso volta sozinho,
dispara um alerta de "normalizado".

Rodado via `nocrm-extraction-watchdog.timer` (systemd, `OnUnitActiveSec=30min`) —
ou seja, uma checagem a cada 30 minutos, com limite de alerta em 2h de
estagnação: no pior caso, o Vagner sabe de um travamento em **até ~2h30**,
não em um dia inteiro como aconteceu no incidente do ExecStop.

**Testado ao vivo antes de considerar pronto** (backdatando o checkpoint
artificialmente pra simular 3h sem avanço, contra produção): alerta
disparou corretamente nos dois canais, reenvio imediato foi suprimido
como esperado, e uma pausa real de ~1h por teto de orçamento por hora
(esperada, não é falha) **não** gerou alerta — confirma que o limiar de
2h absorve o ciclo normal de pacing sem falso positivo.

### 17.5 Falso alarme na validação do próprio watchdog (24/07/2026) — lição de disciplina de teste

Ao validar o `check-progress` (seção 17.4) antes de considerar pronto,
o checkpoint de `attachments` foi **backdatado manualmente** (`last_progress_at
= now() - interval '3 hours'`) direto contra o banco de produção pra
confirmar que o alerta dispara de ponta a ponta. Funcionou exatamente
como desenhado — **e por isso mesmo mandou um alerta real** (e-mail +
WhatsApp, os mesmos canais de produção) dizendo "travado há 3h", quando
o job nunca esteve travado de verdade (o último avanço real tinha sido
~26 minutos antes do teste, dentro do ciclo normal de pausa por teto de
orçamento por hora). Diferente do teste do canal via `test-alert`
(seção 11), que já rotula a mensagem como "teste manual... não é um
erro real", este teste do watchdog usou o motivo de alerta real
(`progresso_travado_3.0h`) com dado de produção manipulado — o Vagner
recebeu e tratou como incidente genuíno, com razão (o conteúdo da
mensagem não dava nenhum sinal de ser teste).

**Causa do falso alarme**: teste de um alerta de produção, contra estado
de produção real, sem avisar antes que um disparo estava vindo — ao
contrário do padrão já usado no teste do Resend (seção 11), onde o aviso
"vou disparar um teste, é esperado" veio ANTES do disparo.

**Regra adotada daqui pra frente**: testar um mecanismo de alerta contra
dado de produção real exige, no mínimo, avisar antes que o teste vai
gerar uma notificação real nos canais reais — mesmo que o motivo/detalhe
pareça "óbvio" de ser artificial internamente, do lado de quem recebe
a mensagem não há diferença nenhuma entre um alerta de teste e um real
a menos que o conteúdo diga isso explicitamente. Alternativa mais segura
pra próxima vez: testar contra um `task_type` fictício (não usado por
nenhum job real) ou um ambiente isolado, em vez de manipular o
checkpoint real de produção.
