# ROADMAP — Arkontech (as duas trilhas)

> Atualizado: 18/07/2026. Horizonte: 12 semanas.
> Princípio: a Fase 0 do CRM é o único pré-requisito bloqueante.
> Depois dela, as trilhas correm em paralelo, em blocos semanais
> (sugestão: seg–qua produto, qui–sex casa).

## Trilha 1 — Arrumar a casa (CRM casagora)
Detalhe em `crm/PLANO-ESTRANGULAMENTO.md`.

| Fase | O quê | Semanas | Status |
|------|-------|---------|--------|
| F0 | Rede de segurança (golden master, lint, segredos) | s1–s2 | pendente |
| F1 | Terminar migrações: auth unificada + noCRM | s3–s6 | pendente |
| F2 | Unificar relatórios (legado × v2) | s7–s9 | pendente |
| F3 | Confirmar mortes, limpar anomalias, docs | s9–s10 | pendente |
| F4 | Modularizar o server.js (15.800 linhas → módulos) | s11+ | pendente |

## Trilha 2 — Produto de disparos WhatsApp
Detalhe em `disparos/ARQUITETURA.md`.

| Etapa | O quê | Semanas | Status |
|-------|-------|---------|--------|
| Reunião | Cliente imobiliária aprova o protótipo | s1 | pendente |
| MVP | Schema no Postgres + 4 workflows n8n, operação manual | s2–s5 | pendente |
| Painel | Front self-service + QR + upload + cobrança | s6–s8 | pendente |
| IA | Triagem, monitor de não respondidas, variações | s9–s11 | pendente |
| F5 | CRM integra a plataforma (exports WhatsApp migram) | s12+ | pendente |

## Marcos de encontro das trilhas
- **s6**: auth unificada (F1) pronta → painel de disparos nasce já no
  padrão novo (Auth.js), que depois o CRM adota.
- **s12+**: Fase 5 — o CRM vira o primeiro cliente da plataforma de
  disparos via API. Uma base de contatos, uma timeline, um WhatsApp.

## Infra existente aproveitada (VPS)
n8n (`agenciadeia_n8n`), Evolution API + Postgres 17 + Redis
(`agenciadeia_*`), Traefik/Swarm/EasyPanel. O produto de disparos NÃO
instala stack nova — cria schema e workflows sobre o que já roda.
