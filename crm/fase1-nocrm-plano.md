# FASE 1B — Concluir a migração do noCRM: levantamento e plano

> Sessão de levantamento, 19/07/2026. **Nenhum código foi alterado para produzir este
> documento.** Escopo: `casagora-router` (onde toda a integração com noCRM realmente vive) e
> `casagora-sistema` (só para confirmar o que `.planning/phases/10-*` documenta de verdade).

## Achado principal: "migração 10" não é sobre o noCRM

O `PLANO-ESTRANGULAMENTO.md` (Fase 1B, passo 1) manda "levantar o que falta da migração
(o `.planning/phases/10-*` documenta)". **Esse diretório não documenta uma migração do
noCRM.** `10-CONTEXT.md` (05/06/2026) é explícito:

> ⚠ Escopo alterado: Phase 10 foi redefinida de "Migração noCRM" para "Gestão do Lead". A
> migração de dados do noCRM (importação gradual on-demand) foi adiada para fase futura.

O que a Fase 10 real entregou (confirmado nos 4 `SUMMARY.md` + evidência direta no banco de
produção, ver seção seguinte) é: steps reais do Kanban da casagora, status do lead, valor do
negócio, tags por tenant, anexos de documento, vínculo com análise de crédito, tela do
Analista, gerador de proposta. **Nenhuma dessas entregas desliga ou substitui o noCRM** — é
uma fase de funcionalidade do CRM que aconteceu em paralelo, com nome de diretório
desatualizado (a pasta ficou com o nome antigo `10-migracao-nocrm` mesmo depois do
re-escopo; `ROADMAP.md` tem os dois nomes coexistindo — linha 141 já diz "Gestao do Lead",
linha 215 (índice) ainda diz "Migracao noCRM"; `STATE.md` também ainda usa a chave antiga).

**Nota à parte sobre confiabilidade do `STATE.md`**: `last_updated` nele é `2026-06-22`
(quase um mês atrás) e ele lista a Fase 10 como "não iniciado" — mas as tabelas que a Fase
10 real cria (`deal_tags`, `deal_tags_catalog`, `deal_attachments`) **existem e têm dados em
produção**, confirmado no teste de restauração de backup desta semana (`crm/backups.md`).
`STATE.md` está desatualizado como painel de status; não usar como fonte de verdade sem
cruzar com o código/banco real, igual foi feito aqui.

**Conclusão prática**: o trabalho real de "terminar a migração do noCRM" nunca foi um
plano formal do GSD — aconteceu como uma série de commits pontuais direto no
`casagora-router`, ao longo de várias semanas, resolvendo sintomas conforme apareciam (leads
perdidos, rate limit do noCRM, etc.). Não existe um documento prévio para conferir "o que já
foi feito vs. o que faltava" — o levantamento abaixo foi feito lendo o código e o histórico
git diretamente.

## 1. Estado real: o que ainda depende do noCRM hoje

### 1.1 Flag `nocrm_create_enabled` — ainda LIGADA para a Casagora

```
tenant_id (Casagora)  | nocrm_create_enabled = true
```

Único registro na tabela `app_settings` para essa chave — todo tenant novo (Imoviz/outros
clientes) já nasce com o padrão `false` (nunca dependeu do noCRM). **A Casagora, o único
tenant que historicamente usava noCRM, continua com a criação automática de lead no noCRM
LIGADA.** O passo "validar o desligamento com `nocrm_create_enabled` OFF" que o
`PLANO-ESTRANGULAMENTO.md` menciona **ainda não começou** — é a próxima ação concreta, não
algo já em andamento.

Efeito de desligar (`false`): confirmado no código (commit `4ebaaf9`, 08/07/2026) que o
roteamento de lead e a criação do `deal` local **já não dependem** desse flag — ele só
controla se, **além** disso, o lead também é criado no noCRM. Desligar não interrompe
nenhum fluxo de captação (Facebook, LP, webchat, manual); só para de espelhar o lead novo
para dentro do noCRM.

### 1.2 Quatro mecanismos automáticos ainda rodando, todos dependentes do noCRM

Mais do que o "timer 15min" que o `PLANO-ESTRANGULAMENTO.md` menciona — são quatro
mecanismos distintos, dois via `systemd`, dois internos ao processo Node:

| # | Mecanismo | Frequência | O que faz | Rota(s) HTTP envolvida(s) |
|---|---|---|---|---|
| 1 | `casagora-nocrm-users-sync.timer` (systemd) | ~15 min | Sincroniza `agents` (corretores) a partir do noCRM + reconcilia filas (desativa agente/campanha que sumiu do noCRM) | `POST /admin/sync/nocrm/users`, `POST /admin/reconcile/queues` |
| 2 | `casagora-nocrm-app-users-sync.timer` (systemd) | diário, 04:00 UTC | Sincroniza `app_users` (contas de login) a partir dos agentes do noCRM — cria BROKER/ADMIN novos, desativa quem saiu | `POST /admin/sync/nocrm/app-users` |
| 3 | `scheduleDailyNocrmSync` (in-process, `server.js`) | diário, ~02:30 UTC (`NOCRM_SYNC_DAILY_ENABLED`, default ligado) | Puxa leads/deals do noCRM incrementalmente para `lead_crm_import` | chama `nocrmSyncLeads()` direto, sem rota HTTP |
| 4 | Worker de refresh (in-process) | a cada 5 min (`NOCRM_WEBHOOK_WORKER_INTERVAL_MS`, gated por `NOCRM_WEBHOOK_ENABLED`, default ligado) | Processa a fila `nocrm_lead_refresh_jobs`, populada pelo webhook `POST /webhooks/nocrm` — refaz o fetch de um lead específico quando o noCRM avisa que ele mudou | consome fila interna, popula via `POST /webhooks/nocrm` (sempre recebe, guarda no banco independente do worker estar ligado) |

Mais 3 rotas administrativas de sync sob demanda (não agendadas, disparadas manualmente hoje
ou historicamente por script): `POST /admin/sync/nocrm/leads` (+ variantes `/async`,
`/bootstrap/async`), `POST /admin/sync/nocrm/resolve-owners/async`.

E uma rota **não relacionada às automações acima, e que não deve ser removida**:
`POST /api/v2/admin/users/import-nocrm` — ferramenta de onboarding self-service (tela
`/integracoes`) para um tenant importar seus usuários do noCRM manualmente, sob demanda. É
diferente dos 4 mecanismos automáticos: existe para qualquer tenant que decida usar, não é
infra interna da Casagora. Fora do escopo de "desligar o noCRM da Casagora".

### 1.3 Por que isso é "infra crítica" (citação do plano original) — detalhado

Mecanismos 1 e 2 são hoje a **única forma de provisionar corretor/usuário** para o tenant
Casagora — um corretor novo contratado pela imobiliária só aparece no Imoviz depois que o
admin da agência o cadastra no noCRM e o sync roda. Não existe (ainda) um cadastro manual
equivalente sendo usado na prática para a Casagora — a tela `/admin/usuarios` já existe e
funciona (usada pra outros tenants), mas o hábito operacional da Casagora é "cadastra no
noCRM, o Imoviz sincroniza sozinho". Desligar os mecanismos 1-2 sem antes confirmar que o
time da Casagora vai cadastrar corretores manualmente no Imoviz é o principal risco
operacional desta fase — não é um risco técnico, é um risco de **processo**.

## 2. Plano de conclusão em incrementos

### Incremento 1 — Confirmar o estado do fluxo de leads sem `nocrm_create_enabled` (validação, não código)
Não é uma mudança de código — commit `4ebaaf9` já fez a mudança necessária em 08/07/2026.
Falta só **exercitar** com o flag desligado:
1. Desligar `nocrm_create_enabled` para a Casagora (via `/admin/ui` ou `PATCH` direto na
   `app_settings`) em horário de baixo tráfego.
2. Golden master antes e depois (grupo `webhooks_intake` do
   `casagora-router/test/golden-master/` — as respostas de guarda não mudam, mas vale rodar
   para registrar o estado).
3. Observação ativa por alguns dias: leads do Facebook/LP/webchat continuam criando `deal`
   local normalmente (já é o comportamento hoje, independente do flag); confirmar que
   **nenhum fluxo do dia a dia da equipe da Casagora dependia de o lead também aparecer
   dentro do noCRM** (ex.: algum corretor que só olha lead pelo app do noCRM, não pelo
   Imoviz — pergunta de processo, não técnica, ver seção 4).
**Critério de validação**: nenhum lead "perdido" (todo lead que chega por qualquer canal
aparece no Kanban do Imoviz — isso o golden master de webhooks já cobre indiretamente, mas o
critério real aqui é operacional: ninguém da Casagora reporta lead sumido).
**Rollback**: religar o flag — imediato, é só uma linha em `app_settings`.

### Incremento 2 — Confirmar cadastro manual de corretor/usuário como caminho suportado
Antes de tocar nos mecanismos 1-2 (sync de agentes/usuários), confirmar com o Vagner (ou
direto com a operação da Casagora) que cadastrar corretor novo via `/admin/usuarios` é
aceitável como substituto do fluxo "cadastra no noCRM → sync automático". Não tem código
novo aqui — as telas já existem (ver `reference_admin_panels_urls.md`). É um incremento de
**processo/combinado**, não de código; listado como pré-requisito explícito para o
Incremento 3.

### Incremento 3 — Desligar os mecanismos 1 e 2 (sync de agentes/usuários)
Só depois do Incremento 2 confirmado. Duas opções, do menos ao mais definitivo:
- **3a (reversível)**: `systemctl disable --now casagora-nocrm-users-sync.timer
  casagora-nocrm-app-users-sync.timer`. Para os timers sem apagar nada — religar é uma linha.
- **3b (definitivo, só depois de 3a rodar sem incidente por um tempo)**: remover os arquivos
  de timer/service e os dois scripts em `/usr/local/bin/`.
**Risco**: baixo tecnicamente (não afeta nenhuma rota pública, golden master não muda — são
jobs internos), médio operacionalmente (é exatamente o risco de processo da seção 1.3).
**Critério de validação**: 1-2 semanas sem ninguém reportar "corretor novo não apareceu no
sistema" ou "usuário desativado no noCRM continua ativo no Imoviz".
**Rollback**: `systemctl enable --now` de novo (3a) ou restaurar os arquivos do backup/git
history do servidor (3b — mais motivo para preferir esperar bastante entre 3a e 3b).

### Incremento 4 — Desligar o mecanismo 3 (sync diário de leads/deals)
`NOCRM_SYNC_DAILY_ENABLED=0` na env do serviço. Como o roteamento de lead novo já não
depende do noCRM (Incremento 1), esse sync serve hoje só para trazer *atualizações* feitas
manualmente dentro do noCRM (alguém edita um lead lá) de volta pro `lead_crm_import` do
Imoviz — cada vez menos relevante conforme a equipe migra o hábito de trabalhar pelo Imoviz.
**Critério de validação**: confirmar que `lead_crm_import` não é mais consultado por
nenhuma tela ativa como fonte principal (hoje ele parece ser mais um histórico/import de
dados legados do que o pipeline vivo, que já é `deals` — checar com uma sessão de código
dedicada antes de desligar, não assumido aqui).
**Rollback**: variável de ambiente, reverte com um redeploy.

### Incremento 5 — Desligar o mecanismo 4 (worker de refresh via webhook) e o webhook em si
Último a desligar — só depois dos outros estáveis. `NOCRM_WEBHOOK_ENABLED=0` para o worker;
o endpoint `POST /webhooks/nocrm` em si pode continuar existindo (é inofensivo receber e
não processar) ou ser desativado no lado do noCRM (parar de mandar webhook) quando a conta
for encerrada — depende da resposta à pergunta da seção 4.
**Critério de validação**: nenhum efeito observável — é o mecanismo mais isolado dos quatro.
**Rollback**: variável de ambiente.

## 3. Critério de desligamento completo (do `PLANO-ESTRANGULAMENTO.md`)

"Sistema opera com noCRM desligado por 2 semanas sem incidente; jobs de sync removidos do
systemd." Com o plano acima, isso se traduz em: Incrementos 1-3 concluídos e estáveis por
2 semanas corridas, mecanismo 3b (remoção definitiva dos arquivos de timer) executado só
depois dessa janela. Incrementos 4-5 podem seguir em paralelo ou depois, são de menor risco.

## 4. O que precisa de decisão do Vagner

> **Atualização 19/07/2026 (ver D11 em DECISOES.md):** a pergunta 1 abaixo já foi
> respondida, e a resposta muda o escopo desta fase. A equipe da Casagora **ainda gerencia
> negócios pelo noCRM no dia a dia** — não por hábito, mas porque a base histórica
> (comentários e anexos por lead) nunca foi trazida pro Imoviz. Os incrementos 3-5 desta
> fase (desligar sync de agentes/usuários/leads/webhook) ficam **bloqueados** até essa base
> ser migrada. Novo plano de migração de base: `crm/fase1b-migracao-base.md`. A pergunta 4
> (uso real de `lead_crm_import`) também é respondida lá.

1. ✅ **Confirmar que a equipe da Casagora está OK operando 100% pelo Imoviz?** Respondida:
   **não ainda** — falta a base histórica (comentários/anexos). Ver `fase1b-migracao-base.md`.
2. **Cadastro de corretor novo vai passar a ser manual (`/admin/usuarios`) na Casagora?**
   Pré-requisito do Incremento 3 (seção 1.3) — segue em aberto, mas o Incremento 3 já está
   bloqueado pela pergunta 1 de qualquer forma, não é urgente responder agora.
3. **O que acontece com a assinatura/conta do noCRM depois do desligamento completo?**
   Cancelar, manter como arquivo histórico read-only, ou manter ativa por algum tempo como
   rede de segurança? Segue em aberto — esboço de prazo (rede de 60-90 dias antes de
   cancelar) proposto em `fase1b-migracao-base.md`, mas a decisão final é do Vagner.
4. ✅ **`lead_crm_import` ainda é consultado por alguma tela ativa?** Investigado — ver
   `fase1b-migracao-base.md`.
5. **O que fazer com o webhook `/webhooks/nocrm` no encerramento** — desativar do lado do
   noCRM (parar de enviar) antes ou depois de cancelar a conta? Depende da resposta à
   pergunta 3, segue em aberto.
