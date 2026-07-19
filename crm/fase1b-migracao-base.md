# FASE 1B — Migração de base do noCRM (leads + comentários + anexos)

> Investigação, 19/07/2026 — só leitura, nenhum código alterado. Escopo definido pela D11
> (`DECISOES.md`): antes de desligar qualquer automação do noCRM, migrar a base histórica
> (comentários e anexos) e ter a equipe operando 100% pelo Imoviz. Este documento é o
> levantamento que embasa esse plano.

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

## 2. O export CSV nativo (arquivo fornecido, 19/07/2026)

`/root/nocrm-export/nocrm-leads-2026-07-19-ODA4NDg.csv`, ISO-8859-1 → UTF-8, `;` como
separador, **50.000 linhas de dados, 65 colunas**, todas bem formadas (nenhum erro de parse).

### Cobertura real: um recorte truncado, não o histórico completo

O arquivo cobre só **setembro/2019 a agosto/2022**, e a distribuição mensal mostra o corte
claramente:

```
2022-01: 1618   2022-05: 1780
2022-02: 1261   2022-06: 1383
2022-03: 1658   2022-07: 1705
2022-04: 1703   2022-08:  142   ← cai de ~1700/mês pra 142, no meio do mês
```

Isso é uma **truncagem no limite de exportação do noCRM (50.000 linhas)**, não um filtro de
data deliberado — o export simplesmente parou no meio de agosto/2022. **Faltam ~3 anos e
meio** (setembro/2022 até hoje) neste arquivo.

### Cruzamento com `lead_crm_import`: praticamente nenhuma sobreposição

Apenas **6 IDs em comum** entre os 50.000 leads do CSV e os 14.386 registros do banco — as
duas fontes cobrem períodos quase totalmente diferentes (CSV: 2019-ago/2022; banco: quase só
2026). **Existe um buraco real de dado para o período de setembro/2022 a dezembro/2025** —
não coberto nem pelo CSV fornecido, nem pelo sync do banco. Precisa de pelo menos mais um
export (ou uma chamada de API filtrada por data, se o endpoint `GET /leads` suportar) para
cobrir esse intervalo antes de a migração de base ser considerada completa.

### Status no recorte deste arquivo

| Status | Linhas | % |
|---|---|---|
| cancelled | 49.336 | 98,7% |
| won | 663 | 1,3% |
| todo | 1 | ~0% |

(Não aparece `standby`/`lost` neste arquivo — pode ser artefato do recorte 2019-2022, não
necessariamente ausência real desses status no período.)

### Colunas (65) — nenhuma referência a anexo

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

**`Description` = os comentários.** 99,5% das linhas têm conteúdo (contra 29% no banco) —
texto livre concatenado (respostas de formulário + notas manuais dos corretores), confirmado
lendo amostras. É a evidência de que a caixa "incluir comentários" do export nativo estava
marcada neste arquivo.

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
   pequeno (ex.: os 799 leads `won` identificados na seção 5) consome no máximo ~800 das
   2.000 requisições diárias, dá um número real sem comprometer o resto do orçamento do dia.
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

### Esforço estimado

- **Leads + comentários (export nativo)**: baixo — 1-3 exports adicionais, formato já
  conhecido, sem código novo além de um script de import (parser CSV → upsert em
  `lead_crm_import` e/ou `deals`, reaproveitando o padrão de upsert que já existe pro sync).
  Estimativa: poucos dias de trabalho.
- **Anexos (API + n8n)**: depende do volume real (seção 4), mas com o recorte da seção 6
  (~4.900 leads) e um chute conservador de 2-3 requisições por lead (1 lista + 1-2
  downloads), fica em ~10.000-15.000 requisições — **5 a 8 dias corridos** de job rodando no
  teto diário, sem contar o tempo de montar o workflow n8n em si (esse sim precisa de
  estimativa própria, é a parte com código/configuração nova).

## 6. Proposta de corte: quem ganha migração completa vs. histórico raso

Baseado nos status já identificados (CSV + banco), a recomendação é migrar comentários +
anexos completos só para quem tem valor operacional ou de compliance continuado; o resto
(a imensa maioria, `cancelled` de 2019-2022) fica só com o registro raso que o export de
leads+comentários já traz — não vale o orçamento de API neles.

| Grupo | Critério | Volume estimado | Tratamento |
|---|---|---|---|
| **Completo** (comentários + anexos) | `won` (todos os anos — venda concluída, valor de compliance/histórico de documentos) | 663 (CSV, até ago/22) + 136 (banco, ~2026) = **~800** | Migração via API |
| **Completo** | `todo` + `standby` (pipeline ainda ativo/pode reativar) | 1 (CSV) + 1.572 + 2.515 (banco) = **~4.090** | Migração via API |
| **Raso** (só leads+comentários, sem API) | `cancelled`/`lost` — a imensa maioria (98,7% do CSV) | ~59.500+ (CSV truncado + estimativa do restante do período não coberto) | Só export nativo |

**Total do corte "completo"**: ordem de **4.900 leads** — número muito mais tratável para o
orçamento de 2.000 req/dia da API do que tentar migrar tudo.

Refinamento sugerido (não obrigatório): dentro de `cancelled`, considerar promover pra
"completo" quem foi cancelado nos **últimos 12 meses** (chance real de reabordagem) — dado
não quantificado aqui porque o CSV disponível não chega em 2025/2026; ajustar quando os
exports que cobrem esse período existirem.

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
