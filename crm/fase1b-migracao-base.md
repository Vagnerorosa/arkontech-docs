# FASE 1B — Migração de base do noCRM (leads + comentários + anexos)

> Investigação, 19/07/2026 — só leitura, nenhum código alterado. Escopo definido pela D11
> (`DECISOES.md`): antes de desligar qualquer automação do noCRM, migrar a base histórica
> (comentários e anexos) e ter a equipe operando 100% pelo Imoviz. Este documento é o
> levantamento que embasa esse plano.
>
> **Atualizado no mesmo dia** (19/07/2026, mais tarde) quando os 2 exports que faltavam
> chegaram, completando a série de 3 arquivos (145.619 leads, cobertura total set/2019-jul/2026
> sem buraco). Seção 2 (export CSV) e seção 6 (proposta de corte) foram reescritas com os
> números finais — ver nota "ATUALIZADO 19/07/2026" em cada uma.
>
> **Atualizado em 21/07/2026**: chegou o export com comentários dedicados (3 novos arquivos,
> `nocrm-leads-2026-07-21-*.csv`, ~176MB). **Correção importante**: a seção 2 original dizia
> "`Description` = os comentários" — isso estava **errado**. O export de 21/07 tem colunas
> próprias de comentário (`Comment 1/2/3` + `...`) e, comparando linha a linha, `Description`
> é outra coisa (majoritariamente um link `wa.me/...`, não texto de comentário). Ver seção 2b
> (nova) para os números corretos e seção 8 (nova) para a proposta de script de import — só
> leitura e escrita neste documento, nenhum código alterado.
>
> **Atualizado de novo em 21/07/2026 (mesmo dia, mais tarde)**: Vagner decidiu as 3 perguntas
> em aberto da seção 8.4 — registradas como **D14, D15, D16** em `DECISOES.md`. Seção 8
> reescrita com o de-para de etapas (Step→`deal_stages`, confirmado 1:1) e o cruzamento com
> `lead_crm_import` (quem precisa CRIAR vs só VINCULAR). **Ainda não é código** — só leitura
> (schema de produção, export) e este documento.

## 1. O que já está dentro (`lead_crm_import`)

14.386 linhas, alimentadas pelo sync diário in-process (`nocrmSyncLeads`, mecanismo 3 do
`fase1-nocrm-plano.md`) e pelo worker de webhook (mecanismo 4). Schema: 33 colunas incluindo
`nocrm_lead_id`, `description` (texto livre), `raw` (jsonb — payload bruto do noCRM),
**nenhuma coluna de anexo**.

### Distribuição por ano — cobertura real é muito mais estreita do que o volume sugere

| Ano | Linhas |
|---|---|
| 2019 | 1 |
| 2021 | 2 |
| 2022 | 5 |
| 2023 | 5 |
| 2024 | 44 |
| 2025 | 489 |
| **2026** | **13.840 (96%)** |

O sync incremental nunca fez backfill histórico — ele só captura o que muda a partir do
momento em que passou a rodar. Na prática, `lead_crm_import` é uma foto quase só de 2026,
não uma base histórica.

### Completude dos campos (14.386 linhas)

| Campo | Preenchido | % |
|---|---|---|
| `description` (comentários) | 4.231 | 29% |
| `phone` | 5.127 | 36% |
| `email` | 2.681 | 19% |
| `cpf` | 2.120 | 15% |

### Status

| Status | Linhas |
|---|---|
| cancelled | 10.126 |
| standby | 2.515 |
| todo | 1.572 |
| won | 136 |
| lost | 37 |

### O que o Imoviz consome disso hoje — corrige uma suposição do `fase1-nocrm-plano.md`

O documento anterior especulava que `lead_crm_import` seria "mais histórico/import de dados
legados do que o pipeline vivo". **Não é o caso** — é consultado ativamente por relatórios
legados e v2 (`/admin/report/*`, distribuição por agente, cap35, funil por campanha,
`/api/v2/dashboard/*`), inclusive com um comentário no próprio código dizendo que é a "fonte
de verdade" da lista de campanhas para relatório. **Desligar o sync diário (Incremento 4 do
`fase1-nocrm-plano.md`) não é inofensivo** — os relatórios foram construídos em cima dessa
tabela, não de `deals`. Isso não bloqueia a migração de base, mas muda o critério do
Incremento 4: antes de desligar, confirmar se os relatórios devem passar a ler de `deals`
(a fonte viva) ou se `lead_crm_import` continua existindo só como tabela histórica estática
depois do desligamento (sem sync, mas ainda consultada).

## 2. O export CSV nativo — ATUALIZADO 19/07/2026, base completa

> **Atualização 19/07/2026 (mesmo dia, mais tarde)**: os 2 arquivos que faltavam chegaram
> (`...ODA4NDk.csv` e `...ODA4NTA.csv`), completando a série. Toda esta seção foi reescrita
> com os 3 arquivos somados — os números abaixo substituem a versão anterior (que era baseada
> só no primeiro arquivo, truncado em agosto/2022). Histórico da versão anterior preservado
> via git.

Três arquivos, `/root/nocrm-export/nocrm-leads-2026-07-19-{ODA4NDg,ODA4NDk,ODA4NTA}.csv`,
ISO-8859-1 → UTF-8, `;` como separador. Colunas variam ligeiramente entre arquivos (65, 68 e
69 — noCRM só inclui uma coluna no export quando algum registro daquela fatia tem valor nela;
`Condição`, `Perfil Imóvel Fechado`, `Remind_time` e `Client_folder` aparecem só nos arquivos
mais recentes). Confirmado por parsing real (`csv.DictReader`, não `wc -l` — o arquivo tem
campos com quebra de linha embutida, ex. comentários longos em `Description`, então contagem
de linha crua superestima o total):

| Arquivo | Linhas de dados |
|---|---|
| `...ODA4NDg.csv` | 50.000 |
| `...ODA4NDk.csv` | 50.000 |
| `...ODA4NTA.csv` | 45.619 |
| **Total** | **145.619** |

### Cobertura: completa, sem buraco de período, sem sobreposição de ID

**Zero IDs duplicados entre os 3 arquivos** (145.619 linhas = 145.619 IDs únicos) — apesar de
os arquivos terem faixas de data (`Created_at`) que se sobrepõem entre si (ex.: o 2º arquivo
começa em 2022-02, dentro do intervalo do 1º; o 3º vai de 2020 a 2026). Isso indica que o
noCRM não fatiou por data na exportação (ordem de exportação parece ser por ID/critério
interno, não cronológica) — mas o resultado prático é bom: **nenhum lead apareceu duas vezes**.

Verificação mês a mês da união dos 3 arquivos, de setembro/2019 (o mês mais antigo observado)
até julho/2026 (mês corrente): **83 meses no intervalo, 0 meses faltando**. O buraco de
set/2022–dez/2025 identificado na investigação anterior (quando só o 1º arquivo estava
disponível) **está fechado** — confirmado, não presumido.

### Cruzamento com `lead_crm_import`: cobertura quase total agora

Com os 3 arquivos, **14.372 dos 14.385 registros de `lead_crm_import`** têm o mesmo `ID`
presente no CSV (99,9% — antes, com só o 1º arquivo, eram 6 IDs em comum). Só **13 leads**
existem no banco e não aparecem em nenhum dos 3 CSVs (provavelmente criados/sincronizados
depois do momento exato da exportação — todos com `Created_at` recente, a maioria `todo`).

Dos 14.372 registros em comum, **3.162 (22%) têm `Status` diferente entre o CSV e o banco** —
esperado, não é inconsistência de dado: o CSV é uma foto do momento da exportação, `banco
lead_crm_import` é sincronizado diariamente e reflete o pipeline mais atual. Nas contagens
abaixo (distribuição de status e proposta de corte), **o status do banco tem prioridade sobre
o do CSV quando o lead existe nos dois** — é o valor mais recente disponível.

### Distribuição de status — todos os 145.632 leads (145.619 do CSV + 13 só no banco)

Status efetivo (banco tem prioridade sobre CSV nos 14.372 em comum, CSV usado sozinho pro
resto):

| Status | Leads | % |
|---|---|---|
| cancelled | 139.845 | 96,0% |
| standby | 2.518 | 1,7% |
| todo | 1.631 | 1,1% |
| won | 1.581 | 1,1% |
| lost | 57 | ~0% |
| **Total** | **145.632** | 100% |

### Distribuição por ano × status (union dos 3 arquivos + banco)

| Ano | won | todo | standby | cancelled | lost | Total |
|---|---|---|---|---|---|---|
| 2019 | 79 | 0 | 0 | 3.834 | 0 | 3.913 |
| 2020 | 215 | 0 | 0 | 18.575 | 0 | 18.790 |
| 2021 | 200 | 0 | 0 | 15.851 | 0 | 16.051 |
| 2022 | 283 | 0 | 1 | 18.974 | 0 | 19.258 |
| 2023 | 291 | 0 | 1 | 17.194 | 0 | 17.486 |
| 2024 | 265 | 21 | 9 | 28.946 | 1 | 29.242 |
| 2025 | 164 | 49 | 144 | 26.666 | 19 | 27.042 |
| 2026 | 84 | 1.550 | 2.362 | 9.804 | 37 | 13.837 |
| (sem ano, só banco) | — | — | — | — | — | 13 |

Padrão esperado: `todo`/`standby` concentram quase todo o volume em 2024-2026 (pipeline ativo
é por definição recente — um `todo` de 2020 já teria virado `won`/`cancelled` com o tempo).
`won` é estável ano a ano (79-291), `cancelled` domina em todos os anos.

### Colunas — nenhuma referência a anexo em nenhum dos 3 arquivos

Lista completa: `Lead, ID, Nome Completo, Telefone, Renda Familiar, Minha Renda é, Entrada/
FGTS, Email, CPF, url, Anuncio, Grupo de Anúncios, Campanha, Plataforma, Captador, Origem,
Interesse em, Forma de Comunicação, Indicação, Tipo de Contato, Intenção do Cliente, Quem
Indicou, Imóvel que comprou, Cidade, Bairro, Tipo do Imóvel, Condição do Imóvel, Situação do
imóvel, imóvel que comprou, Ação de Mkt, Motivos Cancelamento Lead, Tipo, Analise` (+
repetição de várias categorias como colunas extras, artefato do noCRM) `, Pipeline, Step,
Step_ID, Status, Amount, Currency, Probability, Percentual Comissão, Amount × Percentual
Comissão, User, Team, Created_by, Starred, Remind_date, Reminder_activity, Reminder_note,
Created_at, First_activity, Closed_at, Estimated_closing_date, Last_update, tags,
Created_from, Description`.

**Nenhuma coluna de anexo, contagem de arquivo, ou nome de arquivo.** Confirma a D11
diretamente no dado real, não só na documentação.

**~~`Description` = os comentários~~ — CORRIGIDO em 21/07/2026, ver seção 2b.** Esta seção
achava que `Description` (94,6% preenchido) era o campo de comentários. Com o export de
21/07/2026 (que tem colunas próprias de comentário), ficou provado que não é — `Description`
é outra coisa (majoritariamente um link `wa.me/...` da origem do lead), sem relação com o
texto de `Comment 1/2/3/...`. O número de 94,6% em si continua correto (é quanto `Description`
está preenchido), só a interpretação "isso são os comentários" estava errada. Ver seção 2b
para os números certos de comentário.

## 2b. Export com comentários dedicados (21/07/2026) — a peça que faltava

Três novos arquivos, `/root/nocrm-export/nocrm-leads-2026-07-21-{ODA5MDI,ODA5MDM,ODA5MDQ}.csv`,
mesmo formato do export de 19/07 (ISO-8859-1 → UTF-8, `;` como separador), convertidos e
analisados linha a linha (`csv.DictReader`, não `wc -l`, mesmo motivo de antes — campos com
quebra de linha embutida).

### Validação da base (item 1)

- **145.719 leads únicos** nos 3 arquivos somados (50.000 + 50.000 + 45.719). **Zero IDs
  duplicados** entre os 3 arquivos.
- Comparado com os 145.619 IDs do export de 19/07: **os 145.619 estão todos presentes** (nenhum
  sumiu) **+ 100 IDs novos**, todos com `Created_at` entre 19/07 01:09 e 21/07 03:45 — exatamente
  a janela entre os dois exports. Não é inconsistência, é o CRM vivo recebendo lead novo
  normalmente (87 `todo`, 11 `cancelled`, 2 `standby`).
- **Período**: setembro/2019 a julho/2026, **83 meses, 0 buracos** — reconfirmado, mesmo
  resultado do export de 19/07.
- Encoding pós-conversão (ISO-8859-1 → UTF-8): checado por amostragem (>20.000 células de
  `Comment N`/`Nome Completo`) — acentuação (á, é, í, ó, ú, ã, õ, ç) presente e correta em
  milhares de células, **nenhum padrão de mojibake encontrado**. Exemplos legíveis:
  `"...cliente não tem como aumentar a renda..."`, `"...cliente tem terreno e vai construir
  no próprio terreno..."`.

### Comparação com o export de 19/07 (item 3, sanity check)

Distribuição ano × status do CSV bruto (sem merge com o banco) comparada arquivo a arquivo:
**2019 a 2023 são byte-a-byte idênticos** entre os dois exports (won/todo/standby/cancelled/lost
por ano, todos os números batem exatamente). Só **2024-2026** mudam — esperado, é onde o
pipeline vivo se move (leads trocando de status a cada dia) — e a movimentação observada é
consistente com 2 dias de operação normal (ex.: 2026 `todo` 1.778→1.994, `standby` 514→329,
`cancelled` 11.422→11.490). **Nenhuma mudança fora do esperado.**

### Comentários: onde estão, de verdade (item 2)

**Colunas dedicadas**: `Comment 1`, `Comment 2`, `Comment 3`, `...` — não existiam no export de
19/07 (só apareceram agora). Cada uma contém **um comentário individual**, formato
`[AAAA-MM-DD HH:MM] <tipo> <texto>` (ex.: `[2024-12-03 08:34] Whats Audio Cliente não tem como
aumentar a renda...`), em **ordem decrescente de data** — `Comment 1` é sempre o mais recente,
`...` é sempre o 4º mais recente (confirmado comparando timestamps dentro da mesma linha em
centenas de exemplos).

**Achado importante — limite de 4 comentários por lead**: a coluna `...` nunca contém mais de
um comentário (nunca há 2 timestamps na mesma célula, verificado nas 145.719 linhas) — ou seja,
o export só traz **os 4 comentários mais recentes**, não o histórico completo. Um lead com 7
comentários reais no noCRM aparece aqui com só os últimos 4; os 3 mais antigos **não estão em
nenhum lugar deste export**. Isso corrige uma suposição da seção 3 ("comentários via API é
redundante com o export nativo") — é redundante **só para leads com ≤3 comentários no total**;
para quem tem mais, o export dá uma janela parcial (as interações mais recentes), não o
histórico completo. Decisão proposta na seção 8.

**Estatísticas gerais (145.719 leads)**:

| Métrica | Valor |
|---|---|
| Leads com ≥1 comentário real | 133.715 (91,8%) |
| Distribuição (0/1/2/3/4 comentários) | 12.004 / 21.246 / 23.462 / 22.025 / 66.982 |
| Média de comentários/lead (todos, incl. 0) | 2,76 |
| Mediana de comentários/lead (todos, incl. 0) | 3 |
| Média entre os que têm ≥1 | 3,01 |
| Mediana entre os que têm ≥1 | 4 |
| **Batendo no teto de 4** (risco de histórico truncado) | 66.982 (46,0% de todos os leads) |

**Estatísticas no corte de migração completa (won+todo+standby)** — o corte real hoje no banco
é **5.763** leads (1.582 won + 1.601 todo + 2.580 standby; 33 a mais que os 5.730 de 19/07 —
churn normal de 2 dias de pipeline, não é uma correção de erro). Dos 5.763, **5.750 têm linha no
CSV de 21/07** (13 são recentes demais, só no banco):

| Métrica | Valor |
|---|---|
| Têm ≥1 comentário real | 5.401 / 5.750 (93,7%) |
| Média de comentários (entre os que têm) | 3,30 |
| Mediana | 4 |
| Volume total de texto de comentários | ~1.955.718 caracteres (~1,9 MB) |
| **Batendo no teto de 4** — por status | **won: 1.518/1.582 (96,0%)** · standby: 1.550/2.579 (60,1%) · todo: 547/1.589 (34,4%) |

O achado de 96% dos leads `won` batendo no teto **é o dado mais relevante desta análise**: é
justamente o grupo com o relacionamento mais longo (ciclo de venda completo) que mais
provavelmente tem histórico de comentário cortado pelo export. `standby` (nutrição ao longo de
meses) também bate alto. `todo` (pipeline mais recente/curto) bate bem menos. Ver proposta na
seção 8 para o que fazer com isso.

## 3. API v2 do noCRM — documentação oficial

Fonte: `nocrm.io/api` (Sources: [nocrm.io API Reference](https://www.nocrm.io/api),
[Lead Attachments](https://www.nocrm.io/help/lead-attachments),
[Exporting Leads](https://www.nocrm.io/help/exporting-leads)).

| Endpoint | Método | Uso aqui |
|---|---|---|
| `/api/v2/leads` | GET | Listar leads (paginado) |
| `/api/v2/leads/{id}` | GET | Detalhe de um lead |
| `/api/v2/leads/{id}/comments` | GET | Comentários — **redundante só para leads com ≤3 comentários no total** (ver seção 2b); para os que batem no teto de 4 do export, é a única forma de pegar o histórico completo |
| `/api/v2/leads/{id}/attachments` | GET | Lista os anexos do lead (metadados) |
| `/api/v2/leads/{id}/attachments/{attachment_id}` | GET | **Download de um anexo — só um de cada vez** |

Autenticação: header `X-API-KEY` ou `X-USER-TOKEN` (já temos `NOCRM_API_KEY` configurado no
`casagora-router`, usado hoje pelo sync).

**Rate limit documentado: 2.000 requisições/dia por conta.** Excedente retorna `429` com
headers `API-RETRY-AFTER` e `API-LIMIT-RESET`. Paginação: 100 registros por página
(`limit`/`offset`), total em `X-TOTAL-COUNT`.

**Achado crítico para o esforço**: a documentação de anexos é explícita —
*"Attachments can't be downloaded/exported all at once. To export attachments, you'll need
to do it one by one."* Não existe endpoint de download em lote. Cada anexo = 1 requisição
(mais 1 requisição por lead só para listar quais anexos ele tem). Isso, combinado ao teto de
2.000/dia, é o motivo pelo qual isso precisa ser um job em lotes (n8n), não um script que
roda uma vez e termina.

## 4. Volume de anexos — não dá para saber pelos dados que já temos

Nem `lead_crm_import` nem o export CSV têm qualquer campo de contagem/presença de anexo —
confirmado nos dois (seções 1 e 2). **Não tem como estimar quantos leads têm anexo sem
consultar o noCRM diretamente.** Duas formas, nenhuma feita nesta investigação (que era só
leitura do que já temos localmente):
1. **Painel do noCRM** — verificar visualmente uma amostra de leads (won/standby/todo) para
   ter uma noção qualitativa antes de comprometer o orçamento de API.
2. **Amostra controlada via API** — chamar `GET /leads/{id}/attachments` para um lote
   pequeno (ex.: os 1.581 leads `won` identificados na seção 6, número final pós-atualização
   de 19/07) consome no máximo ~1.600 das 2.000 requisições diárias, dá um número real sem
   comprometer o resto do orçamento do dia — cabe num único dia de orçamento.
   Não executado aqui — usa a credencial de produção (`NOCRM_API_KEY`) para uma finalidade
   nova, fora do escopo de "só leitura do que já existe localmente" desta investigação;
   fica como o primeiro passo prático de execução, não desta sessão.

**Pergunta para o Vagner**: vale um passo manual rápido no painel do noCRM (filtrar por
"tem anexo", se essa opção existir) antes de gastar orçamento de API em uma amostra?

## 5. Estratégia recomendada

### Leads + comentários → export nativo (já provado funcionar)
O export CSV com a caixa de comentários marcada já entrega leads + comentários em lote, sem
tocar rate limit de API. **Precisa de mais exports** para fechar o buraco de
set/2022–dez/2025 (seção 2) — verificar no painel se o export nativo aceita filtro de data
(reduziria o número de arquivos necessários); se não aceitar, exportar por status ou pipeline
para ficar abaixo do teto de 50.000 por arquivo.

### Anexos → só API, em lotes, via n8n
Sem alternativa (seção 3). Desenho do job:
1. Para cada lead no escopo de migração completa (seção 6): `GET /leads/{id}/attachments`
   (lista) → para cada anexo: `GET /leads/{id}/attachments/{attachment_id}` (download).
2. Orçamento diário: 2.000 requisições. Job agendado (n8n, workflow batch) rodando fora de
   horário de pico, salvando o progresso (quais leads já foram processados) para retomar no
   dia seguinte sem repetir trabalho — mesmo padrão de fila com retomada que o
   `casagora-router` já usa em `nocrm_lead_refresh_jobs`.
3. Anexos baixados vão para o mesmo mecanismo de storage que `deal_attachments` já usa
   (Docker volume nomeado, ver Fase 10 "Gestão do Lead") — associados ao `deal` local
   correspondente (criar o deal primeiro, se ainda não existir, a partir do export de leads).

### Esforço estimado — ATUALIZADO 21/07/2026 com o export de comentários em mãos

- **Leads + comentários (export nativo)**: ✅ **totalmente resolvido para leads com ≤3
  comentários no total, e "últimos 4" para o resto** — os 3 exports de comentário (seção 2b)
  chegaram, cobrem o período inteiro sem buraco, e **não dependem de orçamento de API**. O
  import (script novo, proposta na seção 8) pode começar **a qualquer momento** — não há mais
  bloqueio de dado faltando. Esforço do script em si: poucos dias (parser CSV → `deals` +
  `activities`, reaproveitando padrão de upsert existente).
- **Comentários além dos 4 mais recentes (achado da seção 2b)**: opcional, só via API. Afeta
  majoritariamente `won` (96% bate no teto) e `standby` (60%) do corte de migração completa.
  Escopo pequeno se decidido: só os **3.615 leads do corte que bateram no teto** (não os 5.750
  inteiros) precisam de `GET /leads/{id}/comments` — 1 requisição cada, **~2 dias** de orçamento
  de API (bem menor que o job de anexos, pode até ser combinado com ele já que visita os mesmos
  leads). Decisão de fazer ou não fica com o Vagner/Casagora — ver seção 8.
- **Anexos (API + n8n)**: **sem mudança** — continua em **6 a 9 dias corridos** de job para os
  5.730-5.763 leads do corte (2-3 requisições por lead, 1 lista + 1-2 downloads, teto de
  2.000/dia). O gargalo real da migração completa permanece sendo anexos, não comentários.
- **Se o refinamento opcional for adotado** (promover `cancelled` dos últimos 12 meses para
  "completo", ver seção 6) — o corte sobe para **26.526 leads**, ~53.000-80.000 requisições,
  **27 a 40 dias corridos** de job de anexos. Decisão de fazer ou não fica com o Vagner; não é
  o corte recomendado por padrão.

## 6. Proposta de corte: quem ganha migração completa vs. histórico raso — NÚMEROS FINAIS

> **Atualizado 19/07/2026** com a base completa (145.632 leads, seção 2) — os números abaixo
> são exatos (contagem real sobre os 3 exports + `lead_crm_import`), não mais estimativa. A
> versão anterior (~4.900) foi calculada com só 6% dos dados disponíveis (o 1º export,
> truncado em ago/2022) e subestimava o volume real.

Mesmo critério de antes, agora com cobertura total: migrar comentários + anexos completos só
para quem tem valor operacional ou de compliance continuado (`won`, `todo`, `standby`); o
resto (`cancelled`/`lost`, 96% da base) fica só com o registro raso que o export de
leads+comentários já traz.

| Grupo | Critério | Volume real (contagem completa) | Tratamento |
|---|---|---|---|
| **Completo** (comentários + anexos) | `won` (todos os anos) | **1.581** | Migração via API |
| **Completo** | `todo` + `standby` (pipeline ativo/pode reativar) | 1.631 + 2.518 = **4.149** | Migração via API |
| **Raso** (só leads+comentários, sem API) | `cancelled` + `lost` | 139.845 + 57 = **139.902** | Só export nativo (já obtido) |

**Total do corte "completo": 5.730 leads** (contra a estimativa anterior de ~4.900 — a base
real é ~17% maior, mas ainda numa ordem de grandeza tratável para o orçamento de 2.000
req/dia da API, ver seção 5).

> **Nota 21/07/2026**: recontado no banco atual, o corte já é **5.763** (won 1.582 + todo 1.601
> + standby 2.580) — +33 em relação aos 5.730 acima, churn normal de 2 dias de pipeline vivo
> (leads mudando de status, não é correção de erro). O critério e a decisão desta seção
> continuam os mesmos; o número exato do corte só é fixado no dia em que o import realmente
> rodar (seção 8).

### Refinamento (agora quantificado — antes era especulativo)

A ideia registrada na versão anterior ("promover `cancelled` recente pra completo") agora tem
número: dos 139.845 leads `cancelled`, **20.796 (14,9%) foram cancelados nos últimos 12 meses**
(ago/2025-jul/2026). Se o Vagner decidir adotar esse refinamento:

- Corte completo passaria de 5.730 para **26.526 leads** (+20.796).
- Esforço de API sobe de ~6-9 dias corridos para **~27-40 dias corridos** (seção 5).

**Recomendação**: não adotar o refinamento no corte inicial — a base de 5.730 já cobre 100%
do pipeline vivo (`won`+`todo`+`standby`); o refinamento é sobre leads já mortos
(`cancelled`) cuja "chance real de reabordagem" é uma hipótese de negócio, não um requisito
técnico ou de compliance como o resto do corte. Reavaliar depois da migração base completa, se
a equipe comercial pedir reabordagem de cancelados recentes especificamente.

## 7. Esboço do plano de adoção

1. **Operação em paralelo** (durante a migração de base): equipe continua usando o noCRM
   normalmente para negócios já em andamento; leads novos já nascem só no Imoviz (já é o
   caso hoje, `nocrm_create_enabled` à parte). Migração de base roda em background, sem
   pressa artificial.
2. **Extração DELTA antes do Dia D** (registrado 22/07/2026, achado do Vagner: os corretores
   trabalham os leads todo dia — a extração mira um alvo em movimento, não uma foto parada).
   Medido com dado real (`fase1b-job-api.md` seção 8.1): comparando o mesmo `nocrm_lead_id` nos
   exports de 19/07 e 21/07 (145.619 leads em comum), **376 (0,26%) mudaram de status em só 2
   dias** — pequeno em proporção, mas contínuo, e a extração inicial (rodando desde 22/07) vai
   estar defasada pelo tempo que levar pra terminar (dias) e, principalmente, pelo tempo até o
   Dia D (que pode ser semanas/meses depois). Antes de virar o Dia D, rodar uma extração delta
   que cubra dois casos, não só um:
   - **Leads que mudaram de status** desde a extração inicial — tanto quem entrou no corte
     (reativação, raro pelo dado de 19-21/07: só 3 casos de volta em 376 mudanças) quanto quem
     saiu (`todo`/`standby` → `cancelled`, a maioria das mudanças: 59 de 376 no período medido).
     Precisa de um snapshot novo de `Status`/`Step` pra comparar contra o que já foi extraído.
   - **Leads já extraídos que ganharam comentários/anexos novos** desde a extração inicial — o
     trabalho diário dos corretores continua gerando comentário mesmo em quem não mudou de
     status/etapa. Não basta olhar só quem mudou de status; é preciso reprocessar comentários
     de **todo** o corte de novo perto do Dia D, não só o delta de status.
   Viabilidade: a arquitetura já suporta isso sem desenho novo — o job é resumível (fila em
   Postgres) e o import (futuro) é idempotente por `nocrm_lead_id` (D16), então rodar a
   extração delta é re-seedar a mesma fila com os mesmos IDs. **Gap conhecido, não implementado
   ainda**: hoje re-seedar um `nocrm_lead_id` que já está `status='done'` na fila não faz nada
   (o `seed` usa `ON CONFLICT DO NOTHING`) — pra forçar reprocessamento no delta, vai precisar
   de um comando novo (`reset` ou equivalente) que volte itens `done` pra `pending` pros leads
   do corte, em vez de reusar `seed` como está. Registrado aqui como pré-requisito técnico do
   Dia D, não construído nesta sessão.
3. **Dia D — noCRM vira somente-leitura**: quando a base completa (seção 5-6) estiver
   migrada e validada (amostra conferida por alguém da Casagora) **e a extração delta (item 2)
   tiver rodado e validado**, desligar a capacidade de criar/editar no noCRM (ou só combinar
   operacionalmente que ninguém mais mexe lá) — todo trabalho novo passa a ser 100% Imoviz. É
   o gatilho que libera os Incrementos 3-5 do `fase1-nocrm-plano.md` (desligar os syncs).
4. **Rede de segurança de 60-90 dias**: manter a assinatura do noCRM ativa, somente-leitura,
   por esse período — cobre qualquer lead/documento que a migração tenha perdido e alguém
   precise consultar. Alinhado ao critério já existente do `fase1-nocrm-plano.md` ("2 semanas
   sem incidente" é o mínimo pros syncs automáticos; a rede de 60-90 dias aqui é mais ampla,
   cobre a base de dados como um todo, não só os jobs).
5. **Cancelamento da assinatura**: só depois da rede de segurança sem nenhum incidente de
   "precisei olhar algo que só existia lá". Decisão final e prazo exato ficam com o Vagner
   (pergunta 3 do `fase1-nocrm-plano.md`, ainda em aberto).

## 8. Proposta de desenho do script de import (21/07/2026, revisado com D14-D16) — PARA APROVAÇÃO, NÃO CODAR AINDA

> Levantamento do schema atual (`casagora_router` produção, só leitura) + leitura do código de
> criação de deal existente (`src/server.js`) + export CSV de 21/07 (colunas `Pipeline`/`Step`)
> + snapshot atual de `lead_crm_import`. Nenhuma tabela criada, nenhuma coluna alterada, nenhum
> código escrito — é proposta para o Vagner (e quem mais precisar) aprovar antes de qualquer
> implementação. As 3 perguntas em aberto da versão anterior desta seção foram respondidas
> (D14, D15, D16 em `DECISOES.md`) e estão incorporadas abaixo.

### 8.1 Onde os leads migrados devem entrar

**Achado central**: `deals` (a tabela viva do Kanban do Imoviz) e `lead_crm_import` (o espelho
do noCRM usado por relatórios) são **estruturas paralelas, sem link entre si hoje** —
`lead_crm_import` tem 14.490 linhas, `deals` tem só **2.515**, e nenhuma delas referencia a
outra. `deals` só é alimentada por dois caminhos: captura manual via Imoviz (`manual_leads` →
`deals`) e leads do Meta Ads (`lead_events` → `deals`). **Nenhum caminho hoje cria `deals` a
partir de leads originados no noCRM** — o que, pela D16, também quer dizer que **nenhum `deal`
existente hoje pode colidir com um lead migrado** (não há dado de origem noCRM em `deals` para
duplicar).

Isso significa que, hoje, migrar só para `lead_crm_import` (como a seção 5 antiga sugeria)
deixaria os 5.730-5.763 leads do corte **invisíveis no Kanban** — apareceriam em relatório, mas
não em nenhuma tela onde um corretor efetivamente trabalha um lead. Para bater com o objetivo
da D11 ("equipe operando 100% pelo Imoviz"), a migração precisa criar linhas em `deals`, não só
em `lead_crm_import`.

**Proposta**:
- Para cada um dos 5.750-5.763 leads do corte (won/todo/standby): **criar uma linha nova em
  `deals`** — sempre criar, nunca checar duplicata por telefone (D16). Identidade única é
  `nocrm_lead_id`.
- `lead_crm_import` recebe os mesmos leads via upsert por `nocrm_lead_id` (já é `UNIQUE` nessa
  tabela) — ver 8.4 para quantos precisam CRIAR vs só atualizar/vincular.
- **Nova coluna proposta**: `deals.nocrm_lead_id` (text, nullable, `UNIQUE` index) — mesmo
  padrão que `lead_crm_import` e `manual_leads` já usam. É a chave de idempotência do import
  (D16): `ON CONFLICT (nocrm_lead_id) DO UPDATE`/`DO NOTHING`, nunca dedup por telefone.
- **Mapeamento de status**: `won` → `deals.status='ganho'`; `todo` → `'para_hoje'`; `standby` →
  `'standby'` (valores já em uso, confirmado no enum real de produção).
- `manual_leads` **não é usado** para a migração — seu schema exige `created_by_user_id` e
  `assigned_agent_id` `NOT NULL` (desenhado para captura humana em tempo real), forçaria valores
  sintéticos sem sentido para um import histórico em lote.
- Campo `Description` do CSV (o link `wa.me/...`, ver seção 2b) → `deals.notes` (texto livre já
  existente), como contexto de origem, não como comentário.

### 8.1.1 De-para de etapas do Kanban (D15) — confirmado 1:1, sem etapa órfã

Todos os 145.719 leads do export estão num único `Pipeline` do noCRM (`Funil de Vendas`), com
exatamente **9 valores distintos de `Step`** — o mesmo número de etapas que `deal_stages` tem
hoje para o tenant Casagora. Comparando nome a nome:

| `Step` (noCRM, export) | Leads no corte (5.750) | `deal_stages` Imoviz (id) | Correspondência |
|---|---|---|---|
| `01 - Lead não Atendido` | 186 | `01 - Lead não Atendido` (7) | Exata |
| `02 - Aguardando Interação` | 1.463 | `02 - Aguardando Interação` (8) | Exata |
| `03 - Em Atendimento` | 1.235 | `03 - Em Atendimento` (9) | Exata |
| `04 - Aguardando Documentação` | 423 | `04 - Aguardando Documentação` (10) | Exata |
| `05 - Enviado para Analise` | 7 | `05 - Enviado para Análise` (11) | Falta acento — normalizar |
| `06 - Em analise` | 7 | `06 - Em Análise` (12) | Falta acento + capitalização — normalizar |
| `07 - Avaliado` | 795 | `07 - Avaliado` (13) | Exata |
| `08 - Proposta Tirada` | 212 | `08 - Proposta Tirada` (14) | Exata |
| `09 - Assinado` | 1.422 | `09 - Assinado` (15) | Exata |

**Nenhum `Step` sem correspondente.** As 2 diferenças (linhas 5 e 6) são só grafia (falta de
acento/capitalização diferente) — o import deve comparar por prefixo numérico (`01`-`09`) em
vez de string exata, ou normalizar acentuação antes de comparar, para não depender de bater
caractere a caractere.

Como bônus, o cruzamento por status confirma que o mapeamento faz sentido operacional: dos
1.582 leads `won`, 1.419 (90%) já estão em `09 - Assinado` e mais 129 em `08 - Proposta
Tirada` — o Step do noCRM reflete de verdade o estágio real da negociação, não é um campo
solto. **Resolve a pergunta em aberto da versão anterior desta seção — mapear de verdade, não
jogar tudo numa etapa default.**

### 8.2 Como os comentários entram

**Achado**: já existe `activities` (FK `deal_id`, colunas `type`, `content`, `user_id`
nullable, `created_at`) — é a tabela que já alimenta o timeline de um deal na tela
(`ActivityFeed.tsx`, ver 8.3). **Não precisa de tabela nova.**

**Proposta**: cada `Comment N`/`...` não-vazio do CSV vira **uma linha em `activities`**:
- `type = 'nocrm_comment'` (valor novo, distinto de `stage_change`/`note`/`task` já em uso —
  permite filtrar/estilizar diferente na tela sem confundir com nota feita dentro do Imoviz).
- `content` = o texto do comentário, sem o prefixo de timestamp (que vira `created_at`).
- `created_at` = a data/hora **original** do comentário (extraída do prefixo `[AAAA-MM-DD
  HH:MM]`), não a data do import — para o timeline ficar cronologicamente correto.
- `user_id` = `NULL` — o CSV só tem o nome do usuário do noCRM em texto livre (coluna `User`),
  sem garantia de bater 1:1 com um `app_users.id`; melhor deixar nulo e, se quiser, guardar o
  nome original em `content` (prefixo "Fulano: ...") do que arriscar associar ao usuário errado.
- Idempotência: como `activities` não tem uma chave natural de origem, a proposta é o script
  verificar antes se já existem `activities` com aquele `deal_id`+`created_at`+`content` (evita
  duplicar comentário se o import rodar 2x) — ou adicionar uma coluna
  `activities.nocrm_comment_key` (hash do lead_id+posição) só para essa finalidade.
- **D14 (histórico completo via API)**: o job de `GET /leads/{id}/comments` para os 3.615
  leads truncados (seção 2b) usa **o mesmo desenho de `activities`** acima — só entra mais
  linhas por `deal_id` (o histórico completo em vez de só os últimos 4). Não exige nenhum
  ajuste de schema além do que já está proposto aqui; pode rodar como um segundo passo,
  depois ou junto do import inicial de leads+comentários, sem retrabalho.

### 8.3 O que o Imoviz precisa de tela

**Achado**: `ActivityFeed.tsx` (`frontend/src/components/pipeline/`) já renderiza qualquer
`activities.type` que não seja especificamente tratado (hoje só `task` tem lógica dedicada,
ver `isTask`/`isDone`/`isOverdue`). Isso quer dizer que comentários migrados **já apareceriam
no timeline sem nenhuma mudança de frontend**, só com um rótulo genérico.

**Ajuste pequeno proposto** (não obrigatório para funcionar, recomendado para clareza): em
`ActivityFeed.tsx`, tratar `type === 'nocrm_comment'` como um caso à parte (ex.: ícone/etiqueta
"📋 Importado do noCRM") — mesmo padrão de código que já existe para `isTask`. Escopo pequeno,
um componente só.

### 8.4 Cruzamento com `lead_crm_import`: quem CRIAR vs quem só VINCULAR (item 2 desta rodada)

Comparado por `nocrm_lead_id`/`ID` (snapshot de `lead_crm_import` de 21/07/2026, 14.490 linhas,
contra o export de 145.719 leads):

| População | Já tem linha em `lead_crm_import` (VINCULAR/atualizar) | Não tem ainda (CRIAR) |
|---|---|---|
| Todos os 145.719 leads do export | 14.473 (9,9%) | 131.246 (90,1%) |
| **Corte de migração completa (5.750 com CSV)** | **4.243 (73,8%)** | **1.507 (26,2%)** |
| + 16 leads do corte que só existem no banco (recentes demais pro export) | já têm linha (VINCULAR) | — |

Para o script de import: **em `lead_crm_import`**, os 4.243+16 leads do corte que já têm linha
levam `UPDATE` (upsert por `nocrm_lead_id`, mesma query do sync diário); os 1.507 restantes
levam `INSERT` novo. **Em `deals`**, a distinção não se aplica da mesma forma — como nenhum
`deal` hoje tem origem no noCRM (8.1), **todos os 5.750-5.763 leads do corte levam `INSERT`
novo em `deals`**, independente de já estarem ou não em `lead_crm_import`. O `ON CONFLICT
(nocrm_lead_id)` em `deals` serve só para o import poder rodar de novo com segurança (idempotência
contra re-execução do próprio script), não para decidir criar-vs-vincular numa primeira
execução.

### 8.5 Riscos e perguntas — RESOLVIDOS (D14, D15, D16 em `DECISOES.md`, 21/07/2026)

1. ~~Duplicata com deal já existente~~ — **resolvido pela D16**: telefone duplicado é regra no
   noCRM (negociações distintas), não deduplicar por telefone. Como nenhum `deal` hoje tem
   origem no noCRM (8.1), não há dado pré-existente para colidir — todo lead do corte gera um
   `deal` novo, sem checagem de duplicata.
2. ~~Comentários truncados em 4~~ — **resolvido pela D14**: buscar histórico completo via API
   para os 3.615 leads truncados (não os 5.750 inteiros), ~2 dias de orçamento, combinável com
   o job de anexos. Ver 8.2.
3. ~~Mapeamento de `stage_id`~~ — **resolvido pela D15**: etapas do Kanban Imoviz e do funil
   noCRM são as mesmas, mapeamento 1:1 confirmado no dado real (8.1.1).
4. **Tenant** (ainda em aberto, não fazia parte desta rodada de decisão): todos os leads do
   corte são da Casagora (`a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11`) — confirmar que nenhum precisa
   ir para outro tenant antes de rodar o import em lote.
