# arkontech-docs

Documentação viva do portfólio Arkontech. Este repositório é a **fonte
única de verdade do planejamento** — lido e alimentado por três partes:

- **Vagner** — decide e aprova
- **Claude (chat)** — estratégia, análise, planos, protótipos
- **Claude Code (VPS)** — execução no código, atualização de status

⚠️ Regra de ouro: NUNCA commitar código de produção, credenciais,
tokens, .env, dumps de banco ou dados de clientes aqui. Somente
planejamento. (É isso que permite o repositório ser público.)

## Estrutura

```
ROADMAP.md                    ← o mapa das duas trilhas (leia primeiro)
DECISOES.md                   ← registro de decisões (feitas e pendentes)
crm/
  PLANO-ESTRANGULAMENTO.md    ← fases 0–5 da arrumação do casagora
  DIAGNOSTICO-ROUTER.md       ← (colocar aqui quando o Claude Code gerar)
  DIAGNOSTICO-FRONTEND.md     ← (idem)
disparos/
  ARQUITETURA.md              ← visão do produto de disparos WhatsApp
  schema.sql                  ← schema Postgres multi-tenant completo
```

## Protocolo de trabalho

1. Toda sessão (chat ou Claude Code) começa lendo `ROADMAP.md` e o
   arquivo da trilha em questão.
2. Claude Code, ao concluir um passo: atualiza o STATUS no arquivo da
   fase + commit com mensagem clara (`docs: fase 0 golden master ok`).
3. Decisão nova ou mudança de rumo → registrar em `DECISOES.md` antes
   de executar.
4. Documento gerado no chat → Vagner baixa e commita (ou cola no
   Claude Code para commitar).

## Setup (uma vez)

```bash
# criar o repo público "arkontech-docs" no GitHub, depois:
cd ~/projetos  # na VPS ou na sua máquina
git clone https://github.com/Vagnerorosa/arkontech-docs
# copiar o conteúdo deste kit para dentro, então:
git add -A && git commit -m "docs: kit inicial" && git push
```
