# Runbook — Rotação de credenciais

> Escrito em 19/07/2026, a partir dos achados de `crm/segredos-relatorio.md`
> (Fase 0, item 4). **Nenhum passo deste runbook foi executado nesta
> sessão** — é procedimento frio, revisável, para o Vagner rodar quando
> decidir. Cada seção é independente e pode ser executada separadamente,
> em ordem qualquer.
>
> **Regra geral: nenhum valor de segredo (senha, chave, token) é
> reproduzido neste arquivo**, nem o antigo nem o novo — mesma disciplina
> do `segredos-relatorio.md`. Onde um comando precisa do valor, ele é
> descrito como placeholder (`<NOVA_SENHA>`, `<NOVO_TOKEN>` etc.) para ser
> preenchido na hora, na sessão de execução, nunca commitado.

## Antes de rodar qualquer seção

Os consumidores listados abaixo foram levantados via `grep`/`docker
service inspect`/`docker exec psql` em 19/07/2026. Serviços novos podem
ter sido adicionados desde então — **rerrodar o passo de descoberta
listado em cada seção antes de executar**, não confiar cegamente nesta
lista se muito tempo tiver passado.

---

## 1. Senha do Postgres (usuário `arkontech`)

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

Em 19/07/2026 retornou 4 serviços Swarm (todos gerenciados pelo
**EasyPanel**, `http://31.97.168.24:3000` — não editar `docker service
update --env-add` como método principal, ver nota abaixo):

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

### Como os serviços Swarm recebem `DATABASE_URL` na prática

`docker service inspect` mostra o env já "assado" na spec do serviço —
**não é lido de um `.env` no host** (os arquivos `/etc/casagora-router*.env`
neste servidor só existem pra rodar um container de teste local, como o
usado pra validar golden master; não são a fonte de verdade do serviço em
produção). O EasyPanel grava e gerencia essa env diretamente. **Editar via
`docker service update --env-add` funciona no ato, mas o EasyPanel pode
reverter no próximo deploy/reconciliação disparado pela UI** — sempre
espelhar a mudança na aba de variáveis de ambiente do serviço, no painel
do EasyPanel, mesmo que o CLI tenha sido usado como atalho emergencial.

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
   foram reiniciados com ela):
   - No EasyPanel, para cada um de `casagora_router_api`, `arkontech_api`,
     `carhauler_app`, `carhauler_app_canary`: abrir o serviço → aba de
     variáveis de ambiente → atualizar `DATABASE_URL` (ou
     `POSTGRES_PASSWORD` no caso do `arkontech_api`) com a nova senha →
     salvar (isso já dispara redeploy/restart do serviço pelo próprio
     EasyPanel).
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
2. **Atualizar no `carhauler_app`** (EasyPanel → serviço `carhauler_app`
   → variáveis de ambiente → `IMPORT_EMAIL_CRON_TOKEN` → salvar).
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
5. **Rollback**: reverter `IMPORT_EMAIL_CRON_TOKEN` no EasyPanel para o
   valor antigo E o crontab para o header antigo, juntos (os dois lados
   precisam bater, não é um par com grace period como o Turnstile).
