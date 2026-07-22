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
