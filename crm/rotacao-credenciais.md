# Runbook — Rotação de credenciais

> Escrito em 19/07/2026, a partir dos achados de `crm/segredos-relatorio.md`
> (Fase 0, item 4). **Seções 1 (Postgres) e 2 (Turnstile) foram
> executadas em produção em 19/07/2026** — ver `## Histórico de
> execução` no fim deste arquivo para o relato completo, achados e
> correções feitas durante a execução. A Seção 3 (token do Carhauler)
> foi adiada, não executada — ver nota na própria seção. Procedimento
> revisado e corrigido com base na execução real; reaplicar as seções
> 1/2 no futuro (nova rotação) deve seguir a versão corrigida do texto
> abaixo, não a suposição original.
>
> **Regra geral: nenhum valor de segredo (senha, chave, token) é
> reproduzido neste arquivo**, nem o antigo nem o novo — mesma disciplina
> do `segredos-relatorio.md`. Onde um comando precisa do valor, ele é
> descrito como placeholder (`<NOVA_SENHA>`, `<NOVO_TOKEN>` etc.) para ser
> preenchido na hora, na sessão de execução, nunca commitado.
>
> **Atualizado em 23/07/2026** — incidente de segredos expostos no
> transcript de uma sessão motivou rotação de emergência de 4 tokens de
> API (Seção 4, nova) + preparo da rotação de `JWT_SECRET` (Seção 5, nova)
> + reforço da Seção 1 (Postgres, item pendente da varredura de 22/07
> ainda em aberto). Ver `## 0. Incidente` para a causa raiz e a regra nova
> de leitura segura de segredo — **leia antes de rodar qualquer comando
> que toque em segredo neste servidor**.

## 0. Incidente (23/07/2026) — segredos expostos em texto puro no transcript

### O que aconteceu

Durante uma sessão de auditoria (não relacionada a rotação), um comando
rodado para inspecionar as env vars do serviço `casagora_router_api`
tentou mascarar os valores sensíveis antes de exibir o resultado, mas a
máscara **não bateu com o formato real da saída** — o comando imprimiu
`JWT_SECRET`, `ADMIN_TOKEN`, `NOCRM_API_KEY`, `NOCRM_WEBHOOK_TOKEN`,
`FACEBOOK_ACCESS_TOKEN`, `FACEBOOK_APP_SECRET`, `EVOLUTION_API_KEY`,
`RESEND_API_KEY`, `TURNSTILE_SECRET`, `TURNSTILE_SECRET_WEBCHAT`,
`SMTP_PASS`, `CHAVES_IMAP_PASS` e a senha do Postgres em texto puro no
transcript da conversa.

### Causa raiz confirmada (não suposição — testado)

O comando usado foi da forma:
```bash
docker service inspect <serviço> --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' \
  | python3 -m json.tool \
  | sed -E 's/("CHAVE"|...)(: ")[^"]*/\1\2***/'
```
`docker service inspect --format '{{json ...ContainerSpec.Env}}'` retorna
uma **lista JSON de strings no formato `"CHAVE=valor"`** (confirmado por
teste: `type([...])` é `list`, cada elemento contém `=`), **não** um
objeto `{"CHAVE": "valor"}`. O regex de máscara foi escrito assumindo o
formato de objeto (procura o padrão `"CHAVE": "` — dois-pontos, espaço,
aspas — antes do valor, pra saber onde cortar). Nesse formato de lista,
esse padrão **nunca aparece** (é só `"CHAVE=valor",` — sinal de igual,
sem dois-pontos) — o regex não casa nada, nada é mascarado, e o
`json.tool` já tinha pretty-printed cada `CHAVE=valor` em uma linha
própria, pronta pra vazar inteira.

### Regra nova — ler segredo sem imprimir, não mascarar depois de imprimir

**Mascarar depois de gerar o output é frágil por construção** — qualquer
divergência de formato (lista vs. objeto, aspas simples vs. duplas,
quebra de linha inesperada) faz a máscara silenciosamente não bater, e o
valor sai em texto puro sem nenhum aviso de que a máscara falhou. A partir
desta rotação, a prática neste projeto passa a ser:

1. **Nunca formatar `.Env`/env dumps inteiros para exibição.** Se só
   precisa saber *se* uma variável existe ou comparar nomes, filtrar por
   **nome**, nunca por valor:
   ```bash
   docker service inspect <serviço> --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' \
     | cut -d= -f1 | sort   # só os NOMES, nunca o valor depois do "="
   ```
2. **Se precisa do valor pra usar em outro comando** (ex.: montar uma nova
   `DATABASE_URL`, assinar algo), extrair pra uma variável de shell **sem
   nunca imprimir** — nem em texto puro, nem "mascarado":
   ```bash
   VAL=$(docker service inspect <serviço> --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' | grep '^CHAVE=' | cut -d= -f2-)
   # usar $VAL diretamente no próximo comando, nunca com echo/print/cat no meio
   ```
3. **Se realmente precisa confirmar visualmente que um valor está
   correto** (comparar com o que está no gerenciador de credenciais, por
   exemplo), mostrar só um prefixo/sufixo curto (ex. 4 caracteres) ou o
   tamanho da string — nunca o valor inteiro:
   ```bash
   echo "tamanho: ${#VAL} chars, prefixo: ${VAL:0:4}..."
   ```
4. **Comandos que despejam env inteiro em stdout são proibidos por
   padrão** neste tipo de investigação — `docker inspect`/`docker service
   inspect --format '{{json .Spec...Env}}'` sem filtro, `env`, `printenv`
   sem grep por nome, `cat /etc/*.env` sem grep por nome. Se a ferramenta
   que gerou o comando (humana ou IA) sentir necessidade de "mascarar
   depois", isso já é o sinal de que devia ter filtrado por nome **antes**
   de gerar output, não depois.

### Consequência prática desta sessão

Como o transcript já continha os valores em texto puro (não é possível
"apagar" isso retroativamente de uma conversa já ocorrida), a decisão foi
tratar como incidente real e rotacionar as credenciais afetadas — ver
Seções 1, 4 e 5. Nenhum uso indevido identificado nos valores expostos
antes da rotação.

---

## Antes de rodar qualquer seção

Os consumidores listados abaixo foram levantados via `grep`/`docker
service inspect`/`docker exec psql` em 19/07/2026. Serviços novos podem
ter sido adicionados desde então — **rerrodar o passo de descoberta
listado em cada seção antes de executar**, não confiar cegamente nesta
lista se muito tempo tiver passado.

---

## 1. Senha do Postgres (usuário `arkontech`)

> **Nota 23/07/2026**: a próxima execução desta seção deve incluir o item
> pendente da varredura de 22/07 (ver `## Histórico de execução`) — a
> spec do próprio serviço Swarm `arkontech_postgres` (env
> `POSTGRES_PASSWORD`, usada só como bootstrap se o volume for recriado do
> zero) ainda está com a senha **anterior a 19/07** (nem a senha rotacionada
> em 19/07 chegou a ser aplicada ali). Não é risco operacional ativo, mas
> é gap de disaster recovery — incluir na mesma janela desta vez, não
> adiar de novo. Comando já pronto na nota do Histórico de 22/07.

### Achado crítico que muda o escopo do que o `segredos-relatorio.md` presumia

A instância Postgres (`arkontech_postgres`) tem **um único role de login,
`arkontech`, dono de todos os bancos**: `arkontech`, `casagora_router`,
`casagora_router_dev`, `carhauler_ops`, `carhauler_ops_canary`, `postgres`.
Não é "a senha do casagora_router" isolada — é **a senha compartilhada por
todo serviço que fala com este Postgres**. Rotacionar sem atualizar todos
os consumidores ao mesmo tempo derruba mais do que o CRM.

Confirmado com:
```bash
PGC=$(docker ps -q -f name=arkontech_postgres)
docker exec "$PGC" psql -U arkontech -tAc "select rolname from pg_roles where rolcanlogin;"
docker exec "$PGC" psql -U arkontech -tAc "select datname from pg_database where not datistemplate;"
```

### Consumidores (rerrodar antes de executar)

```bash
for svc in $(docker service ls --format '{{.Name}}'); do
  docker service inspect "$svc" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -qi "arkontech_postgres" && echo "$svc"
done
```

Em 19/07/2026 retornou 4 serviços Swarm:

1. **`casagora_router_api`** — env `DATABASE_URL` (aponta pro banco
   `casagora_router`).
2. **`arkontech_api`** — env `POSTGRES_USER`/`POSTGRES_PASSWORD`/
   `POSTGRES_HOST`/`POSTGRES_DB` (banco `arkontech`, o painel
   admin/superadmin da Arkontech, não confundir com o CRM).
3. **`carhauler_app`** — env `DATABASE_URL` (banco `carhauler_ops`).
4. **`carhauler_app_canary`** — env `DATABASE_URL` (banco
   `carhauler_ops_canary`).

Mais dois consumidores fora do Swarm:

5. **`/etc/casagora-db-backup.env`** (permissão `600`) — `DATABASE_URL`,
   lido pelo `systemd` (`casagora-db-backup.service`/`.timer`, backup
   diário pro R2). Arquivo plano no host, edição direta.
6. **`casagora-router-refresh-dev-db.sh`** (`/etc/cron.d/`) — **NÃO
   consome a senha**. Autentica via `docker exec ... psql -U arkontech`
   dentro do container do Postgres, usando o socket Unix local
   (`trust` auth no `pg_hba.conf` para conexão local) — confirmado que
   não há senha armazenada nesse script. Não precisa de nenhuma ação
   nesta rotação.

Confirmar que nenhum novo serviço apareceu desde 19/07 antes de seguir
(rerrodar o loop acima).

### Como os serviços Swarm recebem `DATABASE_URL` na prática — CORRIGIDO em 19/07/2026 (execução)

> **A suposição original deste runbook estava errada.** Escrito antes de
> verificar: presumia que os 4 serviços (`casagora_router_api`,
> `arkontech_api`, `carhauler_app`, `carhauler_app_canary`) eram
> projetos EasyPanel e que a edição devia ser feita pela UI
> (`http://31.97.168.24:3000`). Na execução da Seção 2 (Turnstile),
> conferido diretamente no host que isso não é o caso:
> - `docker service inspect <serviço> --format '{{json .Spec.Labels}}'`
>   retorna `{}` para os 4 — nenhum label do EasyPanel.
> - `/etc/easypanel/projects/` no disco só contém `agenciadeia` e
>   `eufernandasimoes` — `casagora`, `carhauler` e `arkontech` não
>   existem como projetos EasyPanel, nem aparecem na busca da UI.
>
> Ou seja: são serviços Swarm puros, criados/atualizados diretamente via
> `docker service create`/`update`, sem registro no EasyPanel — mesmo
> com o Traefik (que É gerenciado pelo EasyPanel) roteando pra eles.
> **`docker service update --env-add` é o mecanismo real e único** para
> os 4, não um atalho emergencial — não há painel EasyPanel que possa
> reverter a mudança, porque o EasyPanel não sabe que esses serviços
> existem. O comando já dispara o rolling restart sozinho (Swarm
> reinicia a task quando a spec muda).
>
> `docker service inspect` mostra o env já "assado" na spec do serviço —
> **não é lido de um `.env` no host** (os arquivos
> `/etc/casagora-router*.env` neste servidor só existem pra rodar um
> container de teste local, como o usado pra validar golden master; não
> são a fonte de verdade do serviço em produção).

### Passos

1. **Pré-checagem**: confirmar que a senha atual funciona e anotar (fora
   deste arquivo, num gerenciador de credenciais) o valor atual — é o que
   permite rollback imediato.

2. **Gerar a nova senha** (32+ caracteres, sem caracteres que precisem de
   escape em connection string — evitar `@`, `/`, `:`, espaço):
   ```bash
   openssl rand -base64 24 | tr -d '/+=' 
   ```

3. **Trocar no Postgres**:
   ```bash
   PGC=$(docker ps -q -f name=arkontech_postgres)
   docker exec -it "$PGC" psql -U arkontech -c "ALTER USER arkontech WITH PASSWORD '<NOVA_SENHA>';"
   ```
   Efeito imediato: conexões **já abertas** continuam funcionando (pool
   não é derrubado). Qualquer conexão **nova** a partir deste momento
   (reconexão de pool, restart de container) já exige a senha nova — a
   partir daqui existe uma janela de risco até o passo 4 terminar em
   todos os consumidores.

4. **Atualizar os 4 serviços Swarm, em sequência rápida** (minimizar a
   janela em que alguns consumidores têm a senha nova e outros ainda não
   foram reiniciados com ela) — via CLI, mecanismo real (ver correção
   acima, não é EasyPanel):
   ```bash
   docker service update --env-add "DATABASE_URL=<nova_connection_string>" casagora_router_api
   docker service update --env-add "DATABASE_URL=<nova_connection_string>" carhauler_app
   docker service update --env-add "DATABASE_URL=<nova_connection_string>" carhauler_app_canary
   docker service update --env-add "POSTGRES_PASSWORD=<NOVA_SENHA>" arkontech_api
   ```
   - Confirmar cada serviço voltou saudável antes de passar pro próximo:
     ```bash
     docker service ps <nome_do_serviço> --no-trunc | head -5
     ```

5. **Atualizar o backup**:
   ```bash
   nano /etc/casagora-db-backup.env   # ou vim — trocar DATABASE_URL
   ```

6. **Validação**:
   - Golden master local (não bate em produção com escrita, mas confirma
     que `casagora_router_api` está de pé e respondendo):
     ```bash
     GOLDEN_MASTER_BASE_URL=https://api.imovizapp.com node test/golden-master/run.mjs
     ```
   - Backup manual (valida `arkontech_api`... não, valida o backup do
     `casagora_router` especificamente):
     ```bash
     systemctl start casagora-db-backup.service
     journalctl -u casagora-db-backup.service --since "5 minutes ago"
     ```
   - Login real: `https://app.imovizapp.com` (CRM/Imoviz — valida
     `casagora_router_api`), painel superadmin da Arkontech (valida
     `arkontech_api`), `https://carhauler.arkontech.com.br` (valida
     `carhauler_app`).

7. **Se tudo validou**: apagar a senha antiga anotada no passo 1.

### Rollback (por passo)

- **Depois do passo 3, antes do 4 terminar**: reverter é o mesmo comando
  do passo 3 com a senha antiga —
  `ALTER USER arkontech WITH PASSWORD '<SENHA_ANTIGA>';` — restaura todos
  os consumidores de uma vez, sem precisar mexer nos serviços que já
  tinham sido atualizados (eles voltam a usar a senha nova só na próxima
  reconexão; se algum já reconectou com a senha nova, esse serviço
  específico vai falhar até ser atualizado de volta — janela pequena,
  aceitável em rollback de emergência).
- **Depois do passo 6 (tudo validado)**: não há rollback — a senha antiga
  já devia ter sido descartada no passo 7. Se um problema aparecer depois
  disso, é uma nova rotação, não um rollback.

---

## 2. Cloudflare Turnstile (par login/LP — `TURNSTILE_SECRET`)

### Escopo — não confundir com o par do webchat

Existem **dois pares Turnstile isolados** neste sistema (decisão
consciente, ver `arkontech-docs` histórico de sessão de 05/07/2026):

| Par | Secret (backend) | Site key (client) | Usado em |
|---|---|---|---|
| **Login/LP** — este runbook | `TURNSTILE_SECRET` (`casagora_router_api`) | `NEXT_PUBLIC_TURNSTILE_SITE_KEY` (build-arg do `imoviz_frontend`) | `/api/v2/auth/login`, formulário de LP |
| Webchat — **fora de escopo, não tocar** | `TURNSTILE_SECRET_WEBCHAT` (`casagora_router_api`) | hardcoded em `casagora-router/webchat/widget-casagora.js`, copiado pra `assets/widget-casagora.js` no commit (`TURNSTILE_SITE_KEY`) | widget do site `casagora.com.br` |

O achado do `segredos-relatorio.md` (🟠 ALTO) é especificamente o par
login/LP, exposto em `docs/superpowers/plans/2026-07-02-lp-captacao-leads-plan.md`
do `casagora-sistema`. **Rotacionar só esse par.**

### Cloudflare permite rotacionar só a secret, mantendo a site key

Confirmado na documentação oficial (Cloudflare Turnstile, consultada
19/07/2026): o dashboard tem **Turnstile → widget → Settings → Rotate
Secret Key** — troca só a chave secreta (privada), a site key pública
**não muda**. Grace period de 2h (a secret antiga continua válida por 2h
depois da rotação, a menos que "invalidate immediately" seja marcado).
Existe também endpoint de API equivalente
(`POST /accounts/{account_id}/challenges/widgets/{sitekey}/rotate_secret`),
não necessário aqui — a UI resolve.

Fonte: [Rotate secret key · Cloudflare Turnstile docs](https://developers.cloudflare.com/turnstile/troubleshooting/rotate-secret-key/).

### Cenário A (recomendado) — rotacionar só a secret key

Site key não muda → **nenhum rebuild do frontend necessário** (a site key
já está embutida no build atual do `imoviz_frontend` e continua válida).

1. Cloudflare dashboard → Turnstile → localizar o widget do login/LP
   (conferir pelo nome/domínio associado, não pelo do webchat) → Settings
   → **Rotate Secret Key**. Decidir se marca "invalidate immediately" —
   recomendado **não marcar**, para ter o grace period de 2h como
   respaldo caso o passo 2 demore.
2. No EasyPanel, serviço `casagora_router_api` → variáveis de ambiente →
   atualizar `TURNSTILE_SECRET` com o novo valor → salvar (redeploy).
   **Não tocar em `TURNSTILE_SECRET_WEBCHAT`.**
3. Validação: login real em `https://app.imovizapp.com` (completa o
   desafio Turnstile normalmente) e envio de teste pelo formulário de LP
   (`casagora.com.br`, captação de leads).
4. Rollback: dentro do grace period de 2h, a secret antiga ainda
   autentica — reverter `TURNSTILE_SECRET` no EasyPanel pro valor antigo
   funciona sem re-rotacionar no Cloudflare. Depois das 2h, só rotacionar
   de novo (não dá pra "desfazer" do lado Cloudflare).

### Cenário B — se for preciso trocar o par inteiro (site key também)

Só necessário se a suspeita for de que a **site key** também precisa
mudar (não é o caso identificado no achado atual — a site key não é
segredo, mas documentar para completude):

1. Cloudflare dashboard → criar um widget novo (novo par site+secret) ou
   usar "Rotate Secret" não serve aqui — troca de site key exige widget
   novo.
2. Atualizar `TURNSTILE_SECRET` no `casagora_router_api` (EasyPanel, como
   no Cenário A).
3. **Rebuild + redeploy obrigatório do frontend** (a site key é
   `NEXT_PUBLIC_*`, embutida no JS no momento do build — ver
   `casagora-sistema/CLAUDE.md`, seção "Deploy do Frontend"):
   ```bash
   cd /root/casagora-sistema/frontend
   docker build \
     --build-arg NEXT_PUBLIC_API_URL=https://api.imovizapp.com \
     --build-arg NEXT_PUBLIC_TURNSTILE_SITE_KEY=<NOVA_SITE_KEY> \
     --no-cache \
     -t imoviz-frontend:latest .
   docker service update --force --image imoviz-frontend:latest imoviz_frontend
   ```
4. Validação/rollback: mesma do Cenário A, mais confirmar visualmente que
   o widget Turnstile aparece na tela de login (site key errada = widget
   não carrega, login falha com `turnstile_failed`).

---

## 3. Bearer token do Carhauler (crontab do `root`)

### Status — adiado (decisão de 19/07/2026)

> **Não executar por ora.** Decisão do Vagner na sessão de execução
> (19/07/2026): o Carhauler vai passar por uma reformulação completa em
> breve — rotacionar este token agora seria retrabalho, já que a
> reformulação provavelmente muda onde/como o token é armazenado. Fica
> como está (token atual continua válido) até a reformulação acontecer.
> Reavaliar este item quando a reformulação for planejada.
>
> **Não afeta a Seção 1 deste runbook (Postgres)**: `carhauler_app` e
> `carhauler_app_canary` continuam na lista de consumidores da senha do
> Postgres e recebem a senha nova normalmente — é um segredo diferente
> (`IMPORT_EMAIL_CRON_TOKEN` vs. a senha do role `arkontech`), este
> adiamento é só do Bearer token do crontab.

### Onde o token é gerado/validado

O token não vem de um provedor externo — é um valor estático que o
próprio `carhauler_app` valida contra a env `IMPORT_EMAIL_CRON_TOKEN`.
Confirmado no código-fonte (`carhauler-ops`,
`app/api/import/superdispatch/pull-email/route.ts`):
```
const token = process.env.IMPORT_EMAIL_CRON_TOKEN;
...
if (auth !== `Bearer ${token}`) { ... }
```
Ou seja, "gerar o novo token" é só decidir um valor novo — não há painel
externo envolvido.

### Onde está hoje (achado do `segredos-relatorio.md`, 🟡 MÉDIO)

`/var/spool/cron/crontabs/root`, job `carhauler-email-import` (a cada 10
min), cabeçalho `Authorization: Bearer <token>` de um `curl` para
`carhauler.arkontech.com.br/api/import/superdispatch/pull-email`. Não é
crítico (permissão `600`, dono `root`, não está em histórico git), mas
destoa do padrão do resto da VPS (outros jobs usam `EnvironmentFile` com
permissão `600`, não valor direto no crontab).

### Passos

1. **Gerar o novo token**:
   ```bash
   openssl rand -hex 32
   ```
2. **Atualizar no `carhauler_app`** — **correção pós-execução (19/07/2026):
   não é EasyPanel**, mesmo achado da Seção 1 (Postgres) — `carhauler_app`
   também é serviço Swarm puro, sem label EasyPanel. Usar:
   ```bash
   docker service update --env-add "IMPORT_EMAIL_CRON_TOKEN=<NOVO_TOKEN>" carhauler_app
   ```
   Confirmar se `carhauler_app_canary` também precisa do mesmo valor —
   só se algum job/teste chamar a URL do canary com esse token; o
   crontab atual do `root` só chama o domínio de produção
   (`carhauler.arkontech.com.br`), então por padrão **não** precisa
   tocar no canary.
3. **Atualizar o crontab** (aproveitar pra migrar pro padrão do resto da
   VPS, já que o item é sugestão de higiene no relatório original):
   ```bash
   crontab -e -u root
   # trocar o header Authorization: Bearer <TOKEN_ANTIGO>
   # pelo novo valor, OU (recomendado) migrar para EnvironmentFile:
   ```
   Opção recomendada — criar `/etc/carhauler-cron.env` (permissão `600`,
   dono `root`) com `CARHAULER_CRON_TOKEN=<NOVO_TOKEN>`, e trocar a linha
   do crontab por um script wrapper que faz `source
   /etc/carhauler-cron.env` antes do `curl`, mesmo padrão do
   `casagora-db-backup.service`. Fora do escopo obrigatório desta
   rotação — fazer junto se for conveniente, não é bloqueante.
4. **Validação**: aguardar o próximo ciclo de 10 min (ou disparar manual,
   se houver como) e conferir:
   ```bash
   tail -20 /tmp/carhauler-email-import.log
   ```
   Esperado: sem erro `401`/`unauthorized`, log de execução normal do
   import de e-mail.
5. **Rollback**: reverter `IMPORT_EMAIL_CRON_TOKEN` via
   `docker service update --env-add` (não EasyPanel, ver correção acima)
   para o valor antigo E o crontab para o header antigo, juntos (os dois
   lados precisam bater, não é um par com grace period como o Turnstile).

---

## 4. Tokens de API (Facebook, noCRM, Evolution, Resend) — 23/07/2026

> Motivada pelo incidente da Seção 0. **Rotaciona sem derrubar sessão de
> usuário nenhuma e sem restart de banco** — os 4 tokens são lidos por
> processo (não por conexão persistente com handshake), então um
> `docker service update --env-add` troca o valor e o próximo request já
> usa o novo, sem downtime perceptível. Descoberta de consumidores feita
> em 23/07/2026 pelo método corrigido da Seção 1 (busca exaustiva, não só
> "quem eu acho que usa isso") — grep por nome de variável em **todos** os
> serviços Swarm + `/etc` inteiro + crontabs + `/root` (scripts soltos) +
> unit files do systemd.

### 4.1 Onde gerar cada um (o painel que você acessa)

| Credencial | Painel | Observação |
|---|---|---|
| `FACEBOOK_ACCESS_TOKEN` | **Business Settings** (business.facebook.com/settings) → Usuários → **Usuários do sistema** → criar um novo → ver 4.8 pra permissões exatas | **Confirmado via introspecção ao vivo** (`GET /admin/facebook/token-status`, 23/07/2026): o token atual é um **token de usuário pessoal** (`/me` retorna "Vagner Rosa", não um System User) com ~50 permissões concedidas — bem mais amplo do que o código realmente usa. Migrar pra System User (decisão do Vagner) é uma melhoria real, não só manter o padrão — não expira por login/senha, e dá a chance de reduzir o escopo pro mínimo necessário (ver 4.8) |
| `NOCRM_API_KEY` | painel do noCRM (`https://casagora.nocrm.io`, `NOCRM_SUBDOMAIN=casagora`) → Configurações/Integrações → API | Confirmar que o novo key tem o mesmo escopo de acesso do atual (leitura+escrita de leads/comentários/anexos) |
| `RESEND_API_KEY` | [resend.com](https://resend.com/) → API Keys | Recomendo criar a nova ANTES de revogar a antiga (Resend permite múltiplas chaves ativas simultaneamente) — evita janela sem envio de e-mail |
| `FACEBOOK_APP_SECRET` | Meta for Developers → app `FACEBOOK_APP_ID` → App Settings → Basic → App Secret → "Show"/"Reset" | Resetar invalida o secret anterior imediatamente (sem grace period, diferente do Turnstile) — coordenar com a Seção 4.5, aplicar no servidor logo em seguida |
| `FACEBOOK_VERIFY_TOKEN` | **Não precisa gerar no painel** — valor arbitrário nosso, só colado no Meta na hora de (re)verificar o webhook | Já gerado (`facebook_verify_token.txt`), ver 4.6 pra ordem correta |
| `NOCRM_WEBHOOK_TOKEN` | **Não precisa gerar no painel** — valor arbitrário nosso, só colado na config do webhook do noCRM | Já gerado (`nocrm_webhook_token.txt`), ver 4.6 pra ordem correta — este tem janela de risco real, ler antes de trocar |
| `EVOLUTION_API_KEY` | **Não tem painel externo** — ver 4.2, é diferente dos outros |

### 4.2 Evolution — caso à parte, ler antes de rotacionar

**Achado importante desta descoberta**: `EVOLUTION_API_KEY` (env
`AUTHENTICATION_API_KEY` no serviço `agenciadeia_evolution-api`) **não é
uma credencial de terceiro** — é uma chave global que o **nosso próprio**
servidor Evolution usa pra autenticar qualquer chamada de API contra
qualquer instância que ele hospeda. O nome do serviço
(`agenciadeia_evolution-api`) sugere que essa instância é **compartilhada
por mais projetos além da Casagora** (o Swarm também tem
`agenciadeia_n8n` rodando ao lado, mesmo prefixo) — não confirmado com
certeza que outros projetos a usam hoje, mas o grep por nome de variável
só alcança consumidores que guardam a chave em env var visível; se algum
workflow do `agenciadeia_n8n` guarda a chave nas próprias credenciais
internas (banco do n8n, não env var), esse grep **não alcança** e a
rotação quebraria aquele workflow sem aviso.

**Recomendação original**: confirmar com quem administra `agenciadeia_n8n`
antes de rotacionar — decisão do Vagner (23/07/2026): ele mesmo administra
o n8n, e pediu pra eu levantar o lado técnico (consumidores detectáveis
no servidor + consulta ao banco do n8n) enquanto ele confirma o resto.

### 4.2.1 Investigação do lado do servidor (23/07/2026) — resultado: risco bem menor do que a suposição inicial

n8n (`agenciadeia_n8n`) usa **SQLite local** (`/home/node/.n8n/database.sqlite`
dentro do volume `agenciadeia_n8n_data`), não um Postgres separado — dá pra
consultar direto (`node:sqlite`, modo `readOnly`, sem escrever nada) sem
precisar abrir a UI do n8n. Consultado (só nomes/contagens, nenhum dado de
credencial foi lido — o campo `data` de `credentials_entity` é criptografado
pelo próprio n8n e nunca foi acessado):

- **Existe 1 credencial cadastrada do tipo `evolutionApi`** ("Evolution
  account") — mas **0 workflows a referenciam** pelo mecanismo estruturado
  de credencial do n8n.
- **1 workflow** ("FACEBOOK CAPTAÇÃO LEADS") tem um node `httpRequest`
  ("Envia Whats corretor2") que chama `https://evolution.arkontech.com.br`
  com a API key **hardcoded direto no parâmetro do header** (`apikey`,
  35 caracteres, não é uma expressão/variável do n8n) — não usa a
  credencial estruturada, é um valor colado direto no node. Confirmado
  que não é vazio/placeholder (tamanho bate com um key real), mas **não
  lido o valor em si**.
- **Todos os 5 workflows desta instância n8n estão INATIVOS** (`active=0`
  em todos, incluindo o que tem o hardcode de Evolution) — nada está
  rodando de verdade neste n8n agora. Confirmado consultando
  `workflow_entity` inteira, não só os que mencionam Evolution/Facebook.
- De bônus (relevante pra Seção 4 como um todo, não só Evolution): esse
  mesmo workflow inativo também usa **2 credenciais Facebook Graph API**
  próprias do n8n ("Facebook Graph Leads Casagora", "Facebook Graph
  account - n8n CASAGORA") — dado criptografado pelo n8n, não lido, mas
  a existência delas sugere que **se esse workflow for reativado no
  futuro**, vai precisar de credenciais Facebook próprias atualizadas
  também (independentes do `FACEBOOK_ACCESS_TOKEN` do `casagora_router_api`
  — n8n guarda a própria cópia). Não é urgente (workflow inativo), mas
  registrado aqui pra não ser esquecido se alguém reativar esse workflow
  sem saber que as credenciais internas podem estar defasadas.

**Conclusão prática**: como nenhum workflow está ativo, rotacionar a
chave global da Evolution agora **não derruba nada em produção no n8n**
— o único ponto de atenção é higiene (o valor hardcoded no workflow
inativo fica desatualizado depois da rotação; se o workflow for
reativado algum dia, alguém vai precisar notar e trocar esse header
manualmente, mesma lógica dos scripts hardcoded do host). Decisão final
de prosseguir com a rotação, mesmo assim, é do Vagner — ele está
confirmando separadamente se há mais algum uso da Evolution fora do que
esse levantamento técnico alcança (ex.: uso manual/pontual não registrado
em nenhum workflow salvo).

**Valor novo já gerado e reservado** (`/root/secrets/rotation-20260723/evolution_api_key.txt`,
`600`, `openssl rand -hex 32`) — **NÃO aplicado em lugar nenhum ainda**,
aguardando confirmação final antes do passo 4.4.

### 4.3 Consumidores confirmados (grep exaustivo, 23/07/2026)

**Ativos (precisam do valor novo pra continuar funcionando):**

| Consumidor | Como recebe | `FACEBOOK_ACCESS_TOKEN` | `NOCRM_API_KEY` | `EVOLUTION_API_KEY` | `RESEND_API_KEY` |
|---|---|---|---|---|---|
| `casagora_router_api` (serviço Swarm) | `docker service update --env-add` (não é EasyPanel — mesmo achado da Seção 1) | ✓ | ✓ | ✓ | ✓ |
| `/etc/nocrm-extraction.env` (`EnvironmentFile` dos jobs `nocrm-extraction-comments/attachments.service`) | editar arquivo direto (permissão `600`, já correta) | — | ✓ | ✓ | ✓ |

**Residual — achado nesta varredura, NÃO estava documentado antes (mesmo
padrão da varredura de 22/07 pro Postgres):**

| Arquivo | Problema | O que tem |
|---|---|---|
| `/etc/casagora-router.secrets.env` | Órfão (datado de 07/02, meses antes de qualquer commit relevante — nada no host/repos referencia esse caminho hoje) **e com permissão `644`** (mundo pode ler, diferente do padrão `600` do resto da VPS) | `FACEBOOK_ACCESS_TOKEN`, `FACEBOOK_APP_SECRET`, `FACEBOOK_VERIFY_TOKEN`, `NOCRM_API_KEY`, `EVOLUTION_API_KEY`, `ADMIN_TOKEN` — valores antigos, possivelmente já defasados de rotações anteriores, mas ainda legíveis por qualquer usuário do sistema |
| `/root/scripts/reprocess_lead.mjs` | Fallback hardcoded (`process.env.NOCRM_API_KEY \|\| '<valor antigo>'`, mesmo padrão já visto com a senha do Postgres em 22/07) | `NOCRM_API_KEY`, `EVOLUTION_API_KEY` |
| `/root/scripts/reprocess_batch.mjs` | Mesmo padrão de fallback hardcoded | `NOCRM_API_KEY`, `EVOLUTION_API_KEY` |
| `/root/scripts/recover_leads_2026_05_13.mjs` | Valor hardcoded direto (sem `process.env`, nem fallback — a constante É o valor) | `FACEBOOK_ACCESS_TOKEN`, `NOCRM_API_KEY` |
| `/root/scripts/reprocess_unrouted_batch_20260524.mjs` | Valor hardcoded direto (mesmo padrão) | `NOCRM_API_KEY`, `EVOLUTION_API_KEY` |
| n8n (`agenciadeia_n8n`), workflow "FACEBOOK CAPTAÇÃO LEADS" (**inativo**), node "Envia Whats corretor2" | Valor hardcoded direto no parâmetro do node (não é o mecanismo de credencial do n8n) — achado via consulta direta ao `database.sqlite` do n8n (ver 4.2.1), não por grep de arquivo | `EVOLUTION_API_KEY` |

**Confirmado seguro (só lê de `process.env`, sem fallback nem valor
hardcoded)**: `mystery_shopper_interactive.js`, `mystery_shopper_leads.js`,
`mystery_shopper_leads_2026_06_11.js`, `mystery_shopper_test.js` — usam
`process.env.NOCRM_API_KEY`/`process.env.EVOLUTION_API_KEY` normalmente,
nenhuma ação necessária além de continuarem funcionando com o valor novo
(já pegam do ambiente na hora de rodar).

**Fora de escopo, confirmado isolado**: `painel-trafego` (projeto
Mapaapolar/Apolar, `/opt/painel-trafego/clientes/apolar/config.json`) tem
seu próprio token de Meta, em arquivo de config separado por cliente —
não referencia nenhuma das env vars acima, cliente diferente, app Meta
provavelmente diferente. Não tocado.

### 4.4 Diretório de secrets desta rotação (já criado)

`/root/secrets/rotation-20260723/` (permissão `700`, dono `root`) — 7 arquivos,
um por credencial, todos `600`:

| Arquivo | Estado | Quem preenche |
|---|---|---|
| `facebook_access_token.txt` | vazio | **Você** — cole o valor gerado no Meta for Developers |
| `facebook_app_secret.txt` | vazio | **Você** — cole o valor gerado/resetado no Meta for Developers |
| `facebook_verify_token.txt` | **já preenchido** (`openssl rand -hex 32`, gerado por mim) | Nada a fazer — só copiar esse valor pro painel do Meta na hora (ver 4.5) |
| `nocrm_api_key.txt` | vazio | **Você** — cole o valor gerado no painel do noCRM |
| `nocrm_webhook_token.txt` | **já preenchido** (`openssl rand -hex 32`, gerado por mim) | Nada a fazer — só copiar esse valor pro painel do noCRM na hora (ver 4.5) |
| `resend_api_key.txt` | vazio | **Você** — cole o valor gerado no resend.com |
| `evolution_api_key.txt` | **já preenchido**, mas **não aplicar ainda** (ver 4.2.1) | Aguardando sua confirmação final |

Pra preencher um arquivo vazio, direto na VPS, nunca no chat:
```bash
nano /root/secrets/rotation-20260723/facebook_access_token.txt   # cole o valor, Ctrl+O, Enter, Ctrl+X
```

### 4.5 Passos — credenciais simples (Facebook access token, App Secret, noCRM key, Resend)

Essas 4 não têm o problema de "outro lado também precisa saber o valor
antes de aceitar chamada" (diferente dos 2 tokens de webhook, ver 4.6) —
rotacionam com uma folga maior.

1. Depois de cada arquivo preenchido (ver 4.4), aplicar no serviço Swarm
   sem nunca imprimir o valor no terminal:
   ```bash
   docker service update --env-add "FACEBOOK_ACCESS_TOKEN=$(cat /root/secrets/rotation-20260723/facebook_access_token.txt)" casagora_router_api
   docker service update --env-add "FACEBOOK_APP_SECRET=$(cat /root/secrets/rotation-20260723/facebook_app_secret.txt)" casagora_router_api
   docker service update --env-add "NOCRM_API_KEY=$(cat /root/secrets/rotation-20260723/nocrm_api_key.txt)" casagora_router_api
   docker service update --env-add "RESEND_API_KEY=$(cat /root/secrets/rotation-20260723/resend_api_key.txt)" casagora_router_api
   docker service ps casagora_router_api --no-trunc | head -5   # confirma saudável depois de cada um
   ```
2. Atualizar `/etc/nocrm-extraction.env` (editor direto, arquivo já `600`)
   com o `NOCRM_API_KEY`/`RESEND_API_KEY` novos (esse arquivo não guarda
   Facebook).
3. Corrigir o residual (mesmo espírito da correção do Postgres em 22/07 —
   mais barato corrigir do que confiar que "ninguém lê isso"):
   - `/etc/casagora-router.secrets.env`: atualizar os valores E corrigir a
     permissão pra `600` (`chmod 600`) — ou, se confirmado que não é usado
     por nada, apagar.
   - Os 4 scripts em `/root/scripts/`: trocar o valor hardcoded/fallback
     pelo novo, ou (melhor, já que são scripts de recuperação de
     incidentes antigos de maio/2026, prováveis de não rodar de novo)
     remover o hardcode e exigir só `process.env`.
   - Se a Evolution for rotacionada (4.2.1): o node "Envia Whats
     corretor2" no workflow inativo do n8n também precisa do valor novo
     colado manualmente (não tem `process.env` pra puxar sozinho).
4. Validação:
   - Facebook: `GET /admin/report/leads` ou próximo lead do roteador
     processando sem erro `190`/`OAuthException` nos logs.
   - noCRM: próximo sync (`nocrm-sync` scheduled) ou chamada manual a
     `/admin/sync/nocrm/leads` sem erro `401`.
   - Resend: `node scripts/nocrm-extraction-job.js test-alert` (dispara
     o canal real de alerta, já usado antes nesta mesma investigação).
   - Evolution (se rotacionado): próxima notificação de WhatsApp de lead
     novo saindo sem erro nos logs do `casagora_router_api`.

### 4.6 Passos — tokens de webhook (`FACEBOOK_VERIFY_TOKEN`, `NOCRM_WEBHOOK_TOKEN`): ORDEM IMPORTA

Diferente dos 4 acima, estes dois são conferidos **a cada chamada de
webhook recebida** (não é só "nós chamamos alguém", é "alguém nos chama e
inclui o token") — trocar na ordem errada rejeita webhooks de verdade
(leads/eventos perdidos) até corrigir.

#### `FACEBOOK_VERIFY_TOKEN` — risco baixo, é só handshake

Confirmado no código (`src/server.js`): esse token só é conferido no
momento em que o Meta faz o **handshake de verificação da assinatura do
webhook** (botão "Verify and Save" no painel) — **não** é enviado em cada
evento de webhook normal depois disso. Ou seja, trocar o valor no nosso
servidor não rejeita nenhum evento em trânsito; só importa bater os dois
lados na hora de clicar "Verify and Save".

**Ordem segura**:
1. Aplicar no servidor **primeiro** (usa o valor já gerado, `facebook_verify_token.txt`):
   ```bash
   docker service update --env-add "FACEBOOK_VERIFY_TOKEN=$(cat /root/secrets/rotation-20260723/facebook_verify_token.txt)" casagora_router_api
   ```
2. **Depois**, no Meta for Developers → App → Webhooks → editar a
   subscrição → colar o mesmo valor no campo "Verify Token" → clicar
   "Verify and Save". O Meta chama nosso endpoint na hora — se o servidor
   já tiver o valor novo (passo 1 primeiro), verifica de primeira.
3. Validação: o próprio botão "Verify and Save" já confirma (fica verde/
   sem erro). Não precisa de teste adicional.

#### `NOCRM_WEBHOOK_TOKEN` — risco real, minimizar a janela

Esse **é** conferido em toda chamada (`POST /webhooks/nocrm`, checagem
`token !== NOCRM_WEBHOOK_TOKEN` a cada request, `src/server.js` linha
~2320) — troca fora de sincronia rejeita (401) qualquer webhook do noCRM
que chegar na janela entre os dois lados mudarem.

**Ordem que minimiza a janela** (mesmo princípio da "sequência rápida" já
usada pro Postgres/JWT — os dois lados o mais simultâneo possível):
1. Ter os dois lados prontos pra trocar **ao mesmo tempo**: painel do
   noCRM aberto na tela de configuração do webhook, valor novo
   (`nocrm_webhook_token.txt`) já gerado e à mão.
2. Aplicar no servidor:
   ```bash
   docker service update --env-add "NOCRM_WEBHOOK_TOKEN=$(cat /root/secrets/rotation-20260723/nocrm_webhook_token.txt)" casagora_router_api
   ```
3. **Imediatamente em seguida** (não esperar validar o passo 2 antes —
   quanto mais rápido, menor a janela), atualizar a URL do webhook
   configurada no painel do noCRM com o novo `token=` (querystring) ou
   header, usando o mesmo valor do arquivo.
4. **Rede de segurança já existente, nenhuma construída nova**: mesmo que
   algum evento seja rejeitado nessa janela (tipicamente poucos segundos),
   o sync diário (`nocrm-sync`, mecanismo 3) e o `nocrm-webhook-worker`
   (fila com retomada) já existentes cobrem a reconciliação de qualquer
   lead/comentário que o webhook tenha perdido nesse intervalo — não é
   perda permanente, só atraso até o próximo sync.
5. Validação: `journalctl`/logs do `casagora_router_api` sem `401` em
   `/webhooks/nocrm` nos minutos seguintes; ou, mais direto, gerar um
   evento de teste no noCRM (comentário novo num lead de teste) e
   confirmar que chega.

### 4.7 Encerramento

Depois de tudo validado e os valores salvos no seu gerenciador de
credenciais: `shred -u -z /root/secrets/rotation-20260723/*.txt && rmdir
/root/secrets/rotation-20260723` — mesmo procedimento de 19/07.

### 4.8 System User + permissões exatas do `FACEBOOK_ACCESS_TOKEN` (23/07/2026)

**Onde criar o System User** (Business Manager, não o Meta for Developers
direto — o gerador de token de System User vive dentro do Business
Settings):
1. `business.facebook.com/settings` → menu esquerdo **Usuários** →
   **Usuários do sistema** ("System Users").
2. **Adicionar** → nome (ex. "casagora-router-api") → papel **Admin**
   (mais simples pra acessar todos os ativos abaixo sem ficar ajustando
   um por um; "Employee" funciona também se preferir escopo mais restrito
   e atribuir os 3 ativos manualmente).
3. Com o usuário criado, **Atribuir ativos** → adicionar os 3 ativos que
   o código realmente usa (ver `FACEBOOK_AD_ACCOUNT_ID`/`FACEBOOK_PAGE_ID`/
   `FACEBOOK_IG_ID` já configurados no `casagora_router_api`, você
   reconhece qual é qual no painel):
   - **Conta de anúncios** — acesso "Visualizar" já basta (só leitura,
     ver 4.8.1).
   - **Página** — "Acesso total" ou ao menos os controles que cobrem
     leitura de conteúdo/insights e leads (a granularidade exata de
     "Página" no Business Settings varia com a versão da UI — se só
     tiver a opção total, use total, é mais simples que sub-permissão).
   - **Conta do Instagram** — vinculada à Página acima, deveria vir
     junto automaticamente.
4. No mesmo usuário → **Gerar novo token** → selecionar o **app**
   (o mesmo `FACEBOOK_APP_ID` que o `casagora_router_api` já usa) →
   marcar as permissões da lista 4.8.1 → **Gerar token**.

#### 4.8.1 Permissões — levantadas direto do código, não da lista de ~50 do token atual

O token em uso hoje tem quase 50 permissões concedidas (confirmado via
`GET /admin/facebook/token-status` em produção) — a maioria delas
(`whatsapp_business_management`, `catalog_management`, `publish_video`,
`manage_fundraisers`, os vários `commerce_*`/`instagram_branded_content_*`,
etc.) **não é usada em nenhum lugar do código** (`fbGet`, único cliente
Graph API do projeto, é só leitura — nenhum `fbPost` existe, confirmado
por busca no arquivo inteiro). É sobra de um token pessoal provavelmente
gerado uma vez via Graph API Explorer marcando mais caixas do que o
necessário. Migrar pra System User é a oportunidade de reduzir pro
mínimo real, levantado direto dos endpoints chamados
(`src/server.js`, função `fbGet` e chamadas em `fbGet('/...')`):

| Permissão | Por quê (endpoint que usa) |
|---|---|
| `leads_retrieval` | `/{leadgen_id}` — puxar o dado do lead do formulário (o core da integração) |
| `ads_read` | `/{ad_account_id}`, `/{ad_account_id}/insights`, `/{ad_account_id}/adsets`, `/{ad_account_id}/campaigns`, `/{ad_id}`, `/{adset_id}`, `/{campaign_id}` — nomes de campanha/adset/ad, saldo, orçamento, gasto (todas leitura, nada cria/edita anúncio) |
| `pages_show_list` | necessário pra resolver o token/acesso da própria Página a partir da conta que chama |
| `pages_read_engagement` | `/{form_id}` (nome do formulário de leadgen, objeto da Página) |
| `read_insights` | `/{ad_account_id}/insights`, `/{page_id}/insights` — métricas agregadas |
| `instagram_basic` | `/{instagram_id}` e leitura básica da conta IG vinculada |
| `instagram_manage_insights` | `/{instagram_id}/insights` |
| `business_management` | padrão pra um System User acessar ativos pertencentes a um Business (a conta de anúncios/página são ativos do Business, não pessoais) |

**Não marcar** (não usado em nenhum lugar do código, reduz superfície):
`ads_management` (só lê, não cria/edita anúncio), qualquer
`whatsapp_business_*` (o WhatsApp aqui é só via Evolution API, não a API
oficial do WhatsApp Business), `catalog_management`, `commerce_*`,
`instagram_branded_content_*`, `publish_video`, `manage_fundraisers`,
`instagram_content_publish`/`instagram_manage_comments`/
`instagram_manage_messages`/`instagram_manage_events` (nada no código
publica ou responde no Instagram, só lê insights).

**Se alguma chamada falhar depois da troca com `permission_denied`/erro
`10`**: sinal de que uma permissão real está faltando nesta lista — mais
fácil adicionar uma a mais depois (gerar novo token com a permissão extra)
do que já sair com as ~50 originais. Validação sugerida (4.5, passo 4)
cobre exatamente os pontos onde uma permissão faltando apareceria primeiro
(relatório de leads, sync).

---

## 5. `JWT_SECRET` (sessão de login) — preparado, EXECUÇÃO PENDENTE DE JANELA

> **Não executar sem OK explícito de janela do Vagner.** Seções abaixo
> preparam o procedimento. **Correção importante feita durante o preparo
> (23/07/2026)**: a 1ª versão desta seção presumia "consumidor único" e
> concluía que o impacto real era pequeno — **as duas coisas estavam
> erradas**, corrigido em 5.1/5.2 abaixo com evidência de código, não
> suposição. A cautela original do Vagner ("desloga todos, janela de
> madrugada") era a leitura mais segura desde o início.

### 5.1 NÃO é consumidor único — o frontend guarda uma cópia do mesmo segredo

Descoberta ao rerrodar o grep exaustivo (mesmo método da Seção 4) **por
nome de variável em todos os serviços Swarm**, não só nos que pareciam
óbvios: `JWT_SECRET` existe em **4 lugares**, não 1:

| Onde | Por quê |
|---|---|
| `casagora_router_api` | emite e revalida o access token (`jwt.sign`/`jwt.verify`, `src/server.js`) |
| `imoviz_frontend` | **verifica a assinatura do JWT localmente**, sem chamar o backend — `frontend/src/middleware.ts` importa `jwtVerify` da lib `jose` e chama `jwtVerify(token, JWT_SECRET)` a cada navegação (linhas 95 e 111). **Precisa ser byte-idêntico ao do backend** — não é uma cópia de conveniência, é parte do desenho (o middleware do Next.js decide sozinho, sem round-trip à API, se o token é válido) |
| `arkontech_api` | app **completamente diferente** (painel admin/superadmin da Arkontech, não Imoviz/Casagora) — quase certamente um valor independente só compartilhando o nome genérico da env var; **não confirmado que seja o mesmo valor** (não dá pra comparar sem imprimir os dois) — tratar como secret separado, **não tocar** nesta rotação a menos que confirmado o contrário |
| `arkontech_postgres` | **residual, sem uso** — o container oficial do Postgres não lê essa env var pra nada; presença ali é resíduo de configuração (mesma categoria dos achados da varredura de 22/07), não um consumidor real |
| `/etc/arkontech/.env` | arquivo órfão já identificado na varredura de 22/07 (ver Seção 1) — tem uma cópia antiga também |

### 5.2 Impacto real corrigido: janela de mismatch causa logout real, não é "sem efeito"

Lido o fluxo completo do middleware (`frontend/src/middleware.ts` linhas
93-126): quando a verificação do access token falha (assinatura
inválida), o código tenta renovar via refresh token — **mas a renovação
só é aceita se o token novo, emitido pelo backend, também verificar
localmente contra a cópia do `JWT_SECRET` do PRÓPRIO frontend** (linha
111: `jwtVerify(rotated.accessToken, JWT_SECRET)`). Se essa segunda
verificação falhar, o código **não tenta de novo** — cai direto em
"sessão inválida", apaga os 3 cookies (`imoviz_token`, `imoviz_refresh`,
`imoviz_user`) e redireciona pro login (linhas 119-126).

Ou seja: se o backend (`casagora_router_api`) já estiver com o
`JWT_SECRET` novo e o frontend (`imoviz_frontend`) ainda com o antigo (ou
vice-versa) no momento em que um usuário navega, a renovação silenciosa
**falha e a pessoa é deslogada de verdade** — a suposição original do
Vagner era a correta. A única forma de manter o impacto mínimo é os dois
serviços trocarem o valor **o mais simultâneo possível** (mesma lógica de
"sequência rápida" já usada na Seção 1 pro Postgres com 4 consumidores) —
mesmo assim, alguém navegando exatamente na janela entre um `docker
service update` e o outro convergir (tipicamente alguns segundos) tem
chance real de cair pro login. Não tem como zerar essa janela por
completo com o mecanismo atual (só eliminando de vez com um desenho de
múltiplos secrets válidos simultaneamente, fora de escopo desta rotação).

**Quem não é afetado**: sessão de **superadmin** (`cg_session`, hash em
`app_sessions`, não usa `JWT_SECRET`) e `arkontech_api`/`arkontech_postgres`
(consumidor separado/residual, ver 5.1) — só o par
`casagora_router_api`+`imoviz_frontend` (login do Imoviz/CRM) sente o
impacto.

**Recomendação**: mantém a cautela original — janela de madrugada/baixo
uso, aviso prévio à equipe se possível ("pode precisar logar de novo uma
vez hoje de madrugada"), e os dois serviços atualizados em sequência tão
rápida quanto der (script único que faz os dois `--env-add` de seguida,
não dois comandos manuais separados por tempo de digitação).

### 5.3 Procedimento (quando a janela for aprovada)

1. Gerar o valor novo:
   ```bash
   openssl rand -hex 48
   ```
2. Salvar em arquivo temporário (`/root/secrets/rotation-<data>/jwt_secret.txt`,
   `600`), nunca no chat.
3. Aplicar nos **dois serviços em sequência imediata** (idealmente um
   script só, não dois comandos digitados separadamente):
   ```bash
   VAL=$(cat /root/secrets/rotation-<data>/jwt_secret.txt)
   docker service update --env-add "JWT_SECRET=$VAL" casagora_router_api
   docker service update --env-add "JWT_SECRET=$VAL" imoviz_frontend
   docker service ps casagora_router_api --no-trunc | head -5
   docker service ps imoviz_frontend --no-trunc | head -5
   ```
4. Corrigir a cópia órfã em `/etc/arkontech/.env` e a residual (sem uso
   real, mas mais barato corrigir) em `arkontech_postgres`, mesmo
   procedimento da nota da Seção 1.
5. **Validação imediata, antes de considerar concluído**:
   - Login novo (usuário de teste) — confirma que o backend emite e o
     frontend aceita o token com o secret novo.
   - Testar **um usuário já logado antes da troca**: aba já autenticada,
     navegar pra outra página logo após a troca — esse é o teste que
     mostra se a janela de mismatch pegou alguém ou não.
   - Monitorar logs do `imoviz_frontend`/`casagora_router_api` por um
     pico breve de redirecionamento pro login nos minutos ao redor da
     troca — esperado um pico pequeno, não zero.
6. **Rollback**: mesmo padrão — os dois serviços de volta pro valor
   antigo, em sequência imediata. Sem período de graça (diferente do
   Turnstile).

---

## Histórico de execução

### 19/07/2026 — janela de domingo, baixo uso

Execução seção por seção, com validação e checkpoint do Vagner antes de
cada restart/mudança visível. Nenhum valor de segredo foi escrito neste
arquivo, no chat, ou em qualquer lugar do `arkontech-docs` durante a
execução — os valores novos ficaram só em
`/root/secrets/rotation-20260719/` (permissão `700`/`600`), apagados com
`shred -u -z` ao final, depois que o Vagner confirmou ter salvo a senha
do Postgres e a secret do Turnstile no gerenciador de credenciais dele.

**Decisão antes de começar**: rotação do Bearer token do Carhauler
(Seção 3) **adiada** — o Carhauler vai passar por reformulação completa
em breve, rotacionar agora seria retrabalho. Token atual continua válido.
Ver nota na própria Seção 3.

**Seção 2 (Turnstile) — executada primeiro, por ser menor risco:**
- Achado durante a execução: o runbook presumia que `casagora_router_api`
  (e os outros 3 consumidores do Postgres) eram projetos EasyPanel,
  editáveis pela UI. Verificação direta no host (`docker service inspect
  --format '{{json .Spec.Labels}}'` retornando `{}`, e
  `/etc/easypanel/projects/` no disco só com `agenciadeia` e
  `eufernandasimoes`) mostrou que isso está errado: são serviços Swarm
  puros, sem registro no EasyPanel. `docker service update --env-add` é
  o mecanismo real, não um atalho — corrigido nas Seções 1 e 3 deste
  arquivo.
- `TURNSTILE_SECRET` atualizado via `docker service update --env-add` em
  `casagora_router_api`. Rolling update convergiu (task nova de pé em
  ~10s). `TURNSTILE_SECRET_WEBCHAT` confirmado intocado.
- Validação: login real em `app.imovizapp.com` e envio de teste na LP —
  ok. Revalidado depois, junto com a Seção 1 (Postgres): login testado em
  3 navegadores anônimos diferentes, ok.

**Seção 1 (Postgres) — executada em seguida:**
- Pré-checagem: descoberta de consumidores rerrodada, mesmos 4 serviços
  de 19/07 (nenhum novo). Roles/bancos conferidos batendo com o runbook.
  Backup da senha antiga (4 arquivos, um por serviço) e da senha nova
  salvos em arquivos `600` antes de qualquer mudança, para rollback
  imediato se necessário.
- `ALTER USER arkontech WITH PASSWORD ...` executado às 17:17 UTC.
- Os 4 serviços (`casagora_router_api`, `carhauler_app`,
  `carhauler_app_canary`, `arkontech_api`) atualizados em sequência
  rápida via `docker service update --env-add`, cada um confirmado
  saudável antes do próximo. Todos convergiram sem erro.
- **Incidente durante a validação**: ao atualizar
  `/etc/casagora-db-backup.env`, o arquivo foi sobrescrito só com a
  `DATABASE_URL` nova, perdendo a variável `R2_BUCKET` que também morava
  nesse arquivo (não capturada na checagem inicial de variáveis por um
  regex que não bateu com o formato real do arquivo). O backup manual
  falhou na 1ª tentativa com `R2_BUCKET: unbound variable` — não
  relacionado à senha nova (o dump do Postgres com a senha nova já tinha
  funcionado, 83M, antes do erro do R2). Corrigido reconstruindo o
  arquivo a partir do backup salvo antes da edição, preservando
  `R2_BUCKET` e os comentários, trocando só a `DATABASE_URL`. Backup
  reexecutado com sucesso (dump local, upload diário, cópia semanal, tudo
  ok). **Lição para próximas edições de arquivos de env fora do Swarm**:
  sempre diffar contra o backup antes de considerar a checagem de
  variáveis completa, não confiar em um único padrão de regex.
- Validação, na ordem pedida pelo Vagner:
  1. ✅ 4 serviços de pé, sem tasks falhando (só falhas históricas de 12
     dias atrás, não relacionadas).
  2. ✅ Golden master: 47 snapshots comparados, 0 mudaram.
  3. ✅ Backup manual (após correção do incidente acima).
  4. ✅ Login real confirmado pelo Vagner em 3 navegadores anônimos.
  5. ✅ Carhauler respondendo (`carhauler.arkontech.com.br` → 200, sem
     erro de auth/DB nos logs recentes de `carhauler_app` e
     `carhauler_app_canary`).
- Sem rollback necessário em nenhum passo.

**Resultado final**: Turnstile (secret, Cenário A) e Postgres (senha do
role `arkontech`, 4 consumidores) rotacionados e validados em produção.
Token do Carhauler (crontab) permanece o mesmo, adiado por decisão
consciente. `segredos-relatorio.md` atualizado para refletir o novo
status.

### 22/07/2026 — varredura de resíduos, achados que a lista original não pegou

Motivada por um teste não relacionado (job de extração noCRM) que falhou
com `password authentication failed` ao usar `/etc/casagora-router.env`
— sinal de que a lista de "4 consumidores" de 19/07 estava incompleta.
Vagner pediu varredura completa antes de corrigir só o arquivo que
quebrou.

**Método usado** (diferente do original — ver lição abaixo): em vez de
procurar só por referências ao hostname `arkontech_postgres` (o que o
runbook original fazia, seção "Consumidores"), buscar a **string literal
da senha antiga** (`grep -rlF`) em: `/etc` inteiro, `/root` (excluindo
repos git e caches), crontabs (`/etc/cron.d`, `/etc/crontab`,
`/var/spool/cron`, `crontab -l`), unit files do systemd, e a spec de
**todos** os serviços Swarm (`docker service ls` + `inspect` de cada um,
não só dos 4 já conhecidos).

**Achados novos** (nenhum destes estava na lista de 19/07):

1. **`/etc/casagora-router.env`** (`DATABASE_URL`) — o que quebrou o
   teste. Corrigido, validado (diff contra backup mostra só a senha
   mudando).
2. **`/etc/arkontech/.env`** (`POSTGRES_PASSWORD`, `POSTGRES_DB`,
   `POSTGRES_USER`, `JWT_SECRET`) — arquivo órfão (nada no host/repos
   referencia esse caminho), datado de 29/01, provavelmente resíduo do
   setup inicial do `arkontech_api`. Corrigido do mesmo jeito, mesmo sem
   uso ativo confirmado — mais barato corrigir do que confiar que
   "ninguém lê isso".
3. **4 scripts avulsos em `/root/scripts/`** (`reprocess_batch.mjs`,
   `reprocess_lead.mjs`, `reprocess_unrouted_batch_20260524.mjs`,
   `recover_leads_2026_05_13.mjs`) — scripts de recuperação pontual de
   leads (incidentes de maio/2026), com a senha antiga **hardcoded**
   como fallback de `DATABASE_URL`. Não rodam via cron/systemd (não
   encontrados em nenhum agendador), mas ficaram no disco prontos pra
   serem reexecutados manualmente num incidente futuro — se alguém
   reusasse um desses scripts sem notar o fallback hardcoded, teria uma
   falha de auth confusa. Corrigidos (senha antiga → nova), só a senha
   mudou (diff conferido).
4. **A própria spec do serviço Swarm `arkontech_postgres`** — env
   `POSTGRES_PASSWORD` (bootstrap do container oficial do Postgres)
   ainda com a senha antiga. **Não é risco operacional agora** (o
   Postgres já roda com a senha nova aplicada via `ALTER USER` em
   19/07; a env var de bootstrap só é lida pelo `docker-entrypoint.sh`
   oficial na criação de um data directory **vazio** — com o volume já
   populado, essa env var fica sem efeito nenhum na operação do dia a
   dia). É um risco de **disaster recovery**: se o volume nomeado for
   perdido/recriado algum dia, o container reinicializaria o cluster do
   zero usando essa env var — ou seja, com a senha errada, quebrando os
   4 consumidores de uma vez justo no meio de uma recuperação de
   desastre, o pior momento possível para descobrir isso.

**Pendente, decisão consciente do Vagner (22/07/2026)**: corrigir essa
env exige `docker service update`, que reinicia o container do Postgres
(Swarm não tem outro mecanismo para aplicar mudança de spec). Investigado
antes de decidir:
- Os 5 serviços envolvidos (`casagora_router_api`, `arkontech_api`,
  `carhauler_app`, `carhauler_app_canary`, `arkontech_postgres`) têm
  `RestartPolicy: {Condition: "any", MaxAttempts: 0}` — Swarm reinicia
  sozinho qualquer um que caia, tentativas ilimitadas, ~5s de delay.
  Achado colateral: `casagora_router_api` **não tem** `pool.on('error',
  ...)` registrado no `server.js` — uma conexão ociosa que quebrar
  durante o restart do Postgres pode derrubar o processo por exceção
  não tratada, em vez de reconectar graciosamente. O Swarm cobre esse
  buraco (restart automático), mas é o processo caindo e voltando, não
  reconexão limpa — **registrado como pendência nova no `DECISOES.md`**,
  candidato a PR pequeno numa fase futura.
- Backup manual rodado a pedido antes de decidir: dump de 88MB,
  upload no R2 confirmado (`casagora_router_2026-07-22_122649.sql.gz`),
  sucesso na 2ª tentativa (o 501 transitório de sempre, não é falha).
- **Decisão**: adiar o `docker service update` no `arkontech_postgres`
  para a próxima janela de baixo uso (madrugada/fim de semana, mesmo
  padrão da execução original de 19/07) — o gap é só de disaster
  recovery futuro, não risco ativo, e a equipe estava usando o sistema
  no momento do pedido. Procedimento pronto pra quando a janela abrir:
  ```bash
  docker service update --env-add "POSTGRES_PASSWORD=<senha_atual_do_role_arkontech>" arkontech_postgres
  docker service ps arkontech_postgres --no-trunc | head -5   # confirmar saudável
  # validar os 4 apps voltaram sozinhos (Swarm restart automático):
  for s in casagora_router_api arkontech_api carhauler_app carhauler_app_canary; do
    docker service ps "$s" --no-trunc | head -3
  done
  ```

**Lição para a próxima rotação/varredura**: procurar só por quem
**referencia o hostname/serviço** (`grep -i arkontech_postgres` nos envs
dos serviços Swarm, o método original) encontra os consumidores "óbvios"
mas tem dois pontos cegos que este achado expôs: (1) não olha pra fora do
Swarm — arquivos soltos no host (`/etc/*.env`, scripts em `/root`,
crontabs) nunca aparecem nesse grep porque não têm a palavra
"arkontech_postgres" neles, só a connection string com a senha; (2) não
considera que **o próprio serviço do banco** carrega a senha como
bootstrap, não como "consumo" — fica fora de qualquer busca por "quem
consome". A busca correta, replicável: depois de definir a senha nova,
**grep pela string literal da senha antiga** (não pelo nome do host) em
`/etc` inteiro, `/root`, crontabs, unit files do systemd, e a spec de
**todos** os serviços Swarm (`docker service ls`, não uma lista
pré-definida) — é mais barato rodar essa varredura ampla uma vez do que
confiar numa lista de consumidores levantada por raciocínio ("quem eu
acho que usa isso") em vez de busca exaustiva.
