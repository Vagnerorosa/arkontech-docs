# Backups de banco — casagora_router e Evolution (agenciadeia)

Documenta a rotina de backup diário pro Cloudflare R2 já em produção
(`casagora_router`) e a cobertura nova adicionada em 19/07/2026
(`agenciadeia`, banco do Evolution API). Mitigação confirmada para a P5 do
`DECISOES.md` (schema de produção só existe organicamente — agora tem
snapshot diário fora da VPS).

## Como funciona

Dois timers `systemd`, um por banco, mesmo padrão:

1. `docker exec` no container do Postgres, `pg_dump` direto pra `stdout`.
2. `gzip -9`, salva local em `/root/backups/db-daily/`.
3. `rclone copy` pro bucket R2 `arkontech`, pasta `daily/`.
4. Se for domingo (UTC), copia também pra pasta `weekly/`.
5. Retenção: local 7 dias; R2 `daily/` 7 dias; R2 `weekly/` 35 dias
   (`rclone delete --min-age`).

Nome do arquivo: `<banco>_YYYY-MM-DD_HHMMSS.sql.gz` — `casagora_router_...`
ou `agenciadeia_...`, mesma pasta no bucket, distinguíveis pelo prefixo.

### casagora_router (existente, não alterado nesta sessão)

| | |
|---|---|
| Script | `/usr/local/bin/casagora-db-backup.sh` (`700`, root) |
| Timer | `casagora-db-backup.timer` → `casagora-db-backup.service` |
| Agenda | `03:00:00` UTC (`00:00` BRT) diário |
| Credenciais | `/etc/casagora-db-backup.env` (`600`, root) — `DATABASE_URL`, `R2_BUCKET=arkontech` |
| Container fonte | `arkontech_postgres` (banco `casagora_router`) |
| Autenticação no Postgres | via `DATABASE_URL` (usuário `arkontech`) |

### agenciadeia / Evolution (nova, adicionada 19/07/2026)

| | |
|---|---|
| Script | `/usr/local/bin/agenciadeia-db-backup.sh` (`700`, root) |
| Timer | `agenciadeia-db-backup.timer` → `agenciadeia-db-backup.service` |
| Agenda | `03:15:00` UTC (`00:15` BRT) diário — 15 min depois do outro, de propósito, pra não disputar I/O |
| Credenciais | **nenhuma armazenada** — `pg_dump -U postgres` roda dentro do próprio container via socket unix (trust auth local), sem senha guardada em lugar nenhum |
| Container fonte | `agenciadeia_evolution-api-db` (banco `agenciadeia`, ~241 MB) |
| Autenticação no Postgres | usuário `postgres`, trust auth local (mesmo padrão já usado por `casagora-router-refresh-dev-db.sh`) |

Testado manualmente em 19/07/2026 (`systemctl start agenciadeia-db-backup.service`):
rodou com sucesso, arquivo confirmado nas duas pastas do R2
(`daily/agenciadeia_2026-07-19_022335.sql.gz` e a cópia semanal
correspondente, já que caiu num domingo).

Antes desta sessão o Evolution **não tinha nenhum backup** — nem nesta
rotina, nem em outra encontrada na VPS (varredura completa em crontabs,
`/etc/cron.d` e timers systemd, ver "Achados — crontabs" no
`segredos-relatorio.md`).

### Falha transitória conhecida (não é bug, não precisa ação)

Os dois scripts ocasionalmente logam:
```
ERROR : <arquivo>: Failed to copy: NotImplemented: Not Implemented (status code: 501)
ERROR : Attempt 1/3 failed ...
ERROR : Attempt 2/3 succeeded
```
É um erro 501 transitório do endpoint R2 no primeiro upload; o retry
automático do `rclone` (3 tentativas) resolve sozinho — confirmado nos logs
de 15, 16, 17 e 18/07 (`casagora-db-backup`) e na execução manual de teste
de hoje (`agenciadeia-db-backup`): sempre "Attempt 2/3 succeeded", nunca
falhou as 3 tentativas. Não trocar nada por causa disso; só vale investigar
se algum dia falhar as 3 tentativas seguidas (aí sim o backup do dia não
sobe).

## Teste de restauração (feito e validado em 19/07/2026)

Passo a passo usado, com um Postgres 17 **descartável** (nunca toca em
produção nem no dev existente):

```bash
# 1. Baixar o dump mais recente do R2 (lista pra achar o nome exato)
rclone lsl r2:arkontech/daily/ | sort -k4 | tail -5
rclone copy r2:arkontech/daily/casagora_router_YYYY-MM-DD_HHMMSS.sql.gz /caminho/temp/

# 2. Subir um Postgres 17 vazio, descartável, só pro teste
docker run --rm -d --name restore-test-pg \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=casagora_restore_test \
  -p 127.0.0.1:55433:5432 postgres:17-alpine
sleep 4

# 3. Descomprimir e restaurar
gunzip -k casagora_router_YYYY-MM-DD_HHMMSS.sql.gz
docker exec -i restore-test-pg psql -U postgres -d casagora_restore_test \
  < casagora_router_YYYY-MM-DD_HHMMSS.sql

# 4. Validar
docker exec restore-test-pg psql -U postgres -d casagora_restore_test -c "\dt"
docker exec restore-test-pg psql -U postgres -d casagora_restore_test -c "
  select 'tenants', count(*) from tenants
  union all select 'deals', count(*) from deals
  union all select 'lead_events', count(*) from lead_events
  union all select 'lead_crm_import', count(*) from lead_crm_import
  union all select 'app_users', count(*) from app_users;"

# 5. Derrubar (--rm já limpa o container sozinho)
docker stop restore-test-pg
rm -rf /caminho/temp/  # apaga o dump baixado, não deixar lixo
```

### Resultado do teste (dump `casagora_router_2026-07-18_030001.sql.gz`)

- Restauração completa: **exit code 0**, único tipo de erro no log foi
  `ERROR: role "arkontech" does not exist` (repetido ~40x) — **esperado e
  inofensivo**: são os `ALTER TABLE ... OWNER TO arkontech` do dump, e o
  Postgres descartável só tem o superusuário `postgres`. Não afeta dados
  nem schema, só a dona das tabelas (fica `postgres` em vez de
  `arkontech`). Nenhum outro tipo de erro apareceu.
- **37 tabelas** restauradas (bate com a contagem esperada do schema atual).
- Contagens (todas plausíveis, nenhuma zerada):

  | Tabela | Linhas |
  |---|---|
  | tenants | 2 |
  | deals | 2.367 |
  | lead_events | 9.818 |
  | lead_crm_import | 14.340 |
  | app_users | 50 |
  | agents | 42 |

- **`app_users` e `lead_crm_import` presentes e com dados** — confirma que
  a lacuna da P5 (`ensureSchema()` não cria essas tabelas do zero) é só
  sobre bootstrapar um banco **vazio**; o dado real de produção está
  íntegro e completo no backup, e é assim que dev/staging deveriam nascer
  (restaurando um dump, não rodando `ensureSchema()` contra um banco
  vazio — aliás é exatamente isso que `casagora-router-refresh-dev-db.sh`
  já faz todo dia às 02:30 UTC, só que clonando direto do container de
  produção em vez de um dump do R2).

### Importante para uma restauração real (não só o smoke test)

O teste acima usa um Postgres genérico sem o usuário `arkontech` — resolve
pra validar que o dump está íntegro, mas **numa recuperação de desastre de
verdade**, criar o role `arkontech` (`CREATE ROLE arkontech WITH LOGIN
PASSWORD '...';`) **antes** de restaurar, pra as tabelas ficarem com o
dono certo e as credenciais que a aplicação já usa (`DATABASE_URL`)
funcionarem sem precisar trocar nada na app.

## Cobertura — resumo

| Banco | Container | Backup antes desta sessão | Backup agora |
|---|---|---|---|
| `casagora_router` | `arkontech_postgres` | ✅ diário, R2 | ✅ (sem mudança) |
| `agenciadeia` (Evolution) | `agenciadeia_evolution-api-db` | ❌ nenhum | ✅ diário, R2, mesmo bucket/padrão |

Nenhum outro Postgres relevante identificado na VPS além desses dois
(verificado via `docker ps` — `dbgate` é só uma UI de admin, não um banco
próprio).
