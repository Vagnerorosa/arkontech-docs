# ARQUITETURA — Plataforma de disparos WhatsApp

Produto SaaS multi-tenant para PMEs: campanhas segmentadas via
WhatsApp, triagem de atendimento com IA e monitor de conversas não
respondidas. Frase-guia do produto: "transforme o WhatsApp do seu
negócio em canal de vendas — atraia, atenda e reative clientes sem
deixar ninguém no vácuo."

## Peças
- **Painel** (Next.js + Auth.js, Google + e-mail/senha) — self-service
- **n8n** — motor: 5 workflows (abaixo)
- **Postgres** — fonte de verdade (ver `schema.sql` nesta pasta)
- **Evolution API** — WhatsApp; 1 instância por tenant
- **LLM (API Anthropic/similar)** — variações, triagem, avaliação;
  chave única nossa, prompt-template nosso + conteúdo do tenant
- **Billing** — Asaas ou Stripe (decisão P1 em DECISOES.md)

## Os 5 workflows n8n
1. **Onboarding** — webhook billing → ativa assinatura → cria
   instância Evolution → QR no painel → connection.update confirma.
2. **Disparo** — agendado 1/min: verificações (janela do fuso do
   tenant, saldo do plano, campanha ativa) → lote da fila
   (`FOR UPDATE SKIP LOCKED`, 5 por vez) → variação sorteada +
   variáveis → envia → intervalo aleatório 25–60 s.
3. **Recebimento** — webhook Evolution: opt-out (SAIR/STOP →
   descadastro global irreversível) → atualiza conversa
   (aguardando_resposta) → triagem IA se ativa (debounce ~20 s,
   JSON: intenção/ação; handoff silencia o bot na conversa).
4. **Monitor** — agendado 15/15 min: conversas aguardando humano
   além do limite → alerta ao telefone do dono; alerta_enviado_em
   evita repetição.
5. **Variações** — webhook do painel: mensagem base → LLM gera 8–12
   variações (regras anti-spam, mantém {variáveis}, JSON) →
   aprovação humana obrigatória antes do sorteio.

## Regras inegociáveis
- Telefones sempre E.164; verificação de WhatsApp na importação.
- Opt-out global estrutural (TCPA/LGPD) + rodapé "responda SAIR".
- Limites de aquecimento por número (teto diário configurável).
- Resposta de IA NÃO zera o relógio de resposta humana.
- Janela de envio no fuso do destinatário/tenant.
- Contrato: número é do cliente; risco de banimento explícito
  (Evolution = API não-oficial; campo `canal` já prevê SMS/oficial).

## Planos (ancoragem, BRL; USD para cliente EUA)
- Essencial R$ 97 — 1.000 envios, variações IA
- Profissional R$ 197 — 3.000 envios, + triagem IA e monitor ⭐
- Premium R$ 397 — 10.000 envios, + avaliação de atendimentos

## Rastreio de origem (ponte com gestão de tráfego)
Mensagens de Click-to-WhatsApp trazem referral (ID do anúncio) →
contato ganha origem/tag da campanha → relatório fecha o funil:
anúncio → conversa → lead qualificado → venda.

## Protótipo aprovável
`prototipo_disparos_arkontech.html` (single-file, identidade
Arkontech) — telas: login, QR, painel, conversas com timers,
campanhas com wizard de variações, contatos com importação simulada,
relatórios, configurações. Hospedar em demo.arkontech.com.br.
