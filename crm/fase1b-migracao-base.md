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

**`Description` = os comentários.** Recontado sobre os 3 arquivos (145.619 linhas): **94,6%**
têm conteúdo (contra 29% no banco, `lead_crm_import`) — texto livre concatenado (respostas de
formulário + notas manuais dos corretores), confirmado lendo amostras. Levemente abaixo dos
99,5% observados só no 1º arquivo (era o recorte com a marcação de "incluir comentários" mais
consistente); ainda assim, uma cobertura muito maior que a do banco.

## 3. API v2 do noCRM — documentação oficial

Fonte: `nocrm.io/api` (Sources: [nocrm.io API Reference](https://www.nocrm.io/api),
[Lead Attachments](https://www.nocrm.io/help/lead-attachments),
[Exporting Leads](https://www.nocrm.io/help/exporting-leads)).

| Endpoint | Método | Uso aqui |
|---|---|---|
| `/api/v2/leads` | GET | Listar leads (paginado) |
| `/api/v2/leads/{id}` | GET | Detalhe de um lead |
| `/api/v2/leads/{id}/comments` | GET | Comentários — **redundante com o export nativo**, não precisa via API |
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

### Esforço estimado — ATUALIZADO 19/07/2026 com a base completa

- **Leads + comentários (export nativo)**: ✅ **concluído nesta etapa** — os 3 exports que
  cobrem o período inteiro (2019-09 a 2026-07, sem buraco) já foram obtidos e validados (seção
  2). Falta só o script de import (parser CSV → upsert em `lead_crm_import` e/ou `deals`,
  reaproveitando o padrão de upsert que já existe pro sync) — poucos dias de trabalho, sem
  dependência de orçamento de API.
- **Anexos (API + n8n)**: com o corte real da seção 6 (**5.730 leads**, não mais a estimativa
  de ~4.900) e o mesmo chute conservador de 2-3 requisições por lead (1 lista + 1-2 downloads),
  fica em **~11.460-17.190 requisições** — **6 a 9 dias corridos** de job rodando no teto
  diário de 2.000/dia, sem contar o tempo de montar o workflow n8n em si.
- **Se o refinamento opcional for adotado** (promover `cancelled` dos últimos 12 meses para
  "completo", ver seção 6) — o corte sobe para **26.526 leads**, ~53.000-80.000 requisições,
  **27 a 40 dias corridos** de job. Decisão de fazer ou não fica com o Vagner; não é o corte
  recomendado por padrão.

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
2. **Dia D — noCRM vira somente-leitura**: quando a base completa (seção 5-6) estiver
   migrada e validada (amostra conferida por alguém da Casagora), desligar a capacidade de
   criar/editar no noCRM (ou só combinar operacionalmente que ninguém mais mexe lá) — todo
   trabalho novo passa a ser 100% Imoviz. É o gatilho que libera os Incrementos 3-5 do
   `fase1-nocrm-plano.md` (desligar os syncs).
3. **Rede de segurança de 60-90 dias**: manter a assinatura do noCRM ativa, somente-leitura,
   por esse período — cobre qualquer lead/documento que a migração tenha perdido e alguém
   precise consultar. Alinhado ao critério já existente do `fase1-nocrm-plano.md` ("2 semanas
   sem incidente" é o mínimo pros syncs automáticos; a rede de 60-90 dias aqui é mais ampla,
   cobre a base de dados como um todo, não só os jobs).
4. **Cancelamento da assinatura**: só depois da rede de segurança sem nenhum incidente de
   "precisei olhar algo que só existia lá". Decisão final e prazo exato ficam com o Vagner
   (pergunta 3 do `fase1-nocrm-plano.md`, ainda em aberto).
