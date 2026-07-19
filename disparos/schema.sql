-- ============================================================
-- SISTEMA DE DISPAROS WHATSAPP MULTI-TENANT — ARKONTECH
-- PostgreSQL 14+
-- Convenções: E.164 para telefones, timestamps em UTC (timestamptz),
--             fuso aplicado na camada de aplicação (n8n) por tenant.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid()

-- ------------------------------------------------------------
-- ENUMS
-- ------------------------------------------------------------
CREATE TYPE status_assinatura AS ENUM ('trial', 'ativa', 'inadimplente', 'cancelada');
CREATE TYPE status_campanha   AS ENUM ('rascunho', 'agendada', 'em_andamento', 'pausada', 'concluida', 'cancelada');
CREATE TYPE status_envio      AS ENUM ('pendente', 'enviando', 'enviado', 'entregue', 'lido', 'respondido', 'erro', 'cancelado');
CREATE TYPE status_conexao    AS ENUM ('desconectado', 'aguardando_qr', 'conectado');
CREATE TYPE canal_envio       AS ENUM ('whatsapp', 'sms');            -- sms reservado p/ futuro (Twilio)
CREATE TYPE direcao_mensagem  AS ENUM ('recebida', 'enviada');
CREATE TYPE acao_triagem      AS ENUM ('responder', 'qualificar', 'handoff', 'ignorar');

-- ------------------------------------------------------------
-- 1. TENANTS (seus clientes: imobiliária, loja de carros, restaurante...)
-- ------------------------------------------------------------
CREATE TABLE clientes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nome                text NOT NULL,
    slug                text NOT NULL UNIQUE,             -- ex.: 'imobiliaria-horizonte'
    email               text NOT NULL UNIQUE,
    pais                char(2) NOT NULL DEFAULT 'BR',    -- ISO 3166-1 alpha-2
    timezone            text NOT NULL DEFAULT 'America/Sao_Paulo',
    moeda               char(3) NOT NULL DEFAULT 'BRL',   -- BRL, USD...
    idioma              text NOT NULL DEFAULT 'pt-BR',
    ativo               boolean NOT NULL DEFAULT true,
    criado_em           timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 2. USUÁRIOS DO PAINEL (login por tenant; um tenant pode ter vários)
-- ------------------------------------------------------------
CREATE TABLE usuarios (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id          uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    nome                text NOT NULL,
    email               text NOT NULL UNIQUE,
    senha_hash          text NOT NULL,                    -- bcrypt/argon2
    papel               text NOT NULL DEFAULT 'admin',    -- admin | operador
    ultimo_login_em     timestamptz,
    criado_em           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_usuarios_cliente ON usuarios(cliente_id);

-- ------------------------------------------------------------
-- 3. ASSINATURAS (Stripe) + PLANOS
-- ------------------------------------------------------------
CREATE TABLE planos (
    id                  text PRIMARY KEY,                 -- 'essencial' | 'profissional' | 'premium'
    nome                text NOT NULL,
    limite_envios_mes   integer NOT NULL,
    max_numeros         integer NOT NULL DEFAULT 1,
    ia_variacoes        boolean NOT NULL DEFAULT true,
    ia_triagem          boolean NOT NULL DEFAULT false,
    ia_avaliacao        boolean NOT NULL DEFAULT false,
    preco_centavos      integer NOT NULL,                 -- na moeda base do plano
    moeda               char(3) NOT NULL DEFAULT 'BRL',
    stripe_price_id     text                              -- price_xxx (pode haver 1 por moeda; ver planos_precos)
);

-- preços multi-moeda do mesmo plano (BRL p/ Brasil, USD p/ EUA)
CREATE TABLE planos_precos (
    plano_id            text NOT NULL REFERENCES planos(id),
    moeda               char(3) NOT NULL,
    preco_centavos      integer NOT NULL,
    stripe_price_id     text NOT NULL,
    PRIMARY KEY (plano_id, moeda)
);

CREATE TABLE assinaturas (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id              uuid NOT NULL UNIQUE REFERENCES clientes(id) ON DELETE CASCADE,
    plano_id                text NOT NULL REFERENCES planos(id),
    status                  status_assinatura NOT NULL DEFAULT 'trial',
    stripe_customer_id      text UNIQUE,
    stripe_subscription_id  text UNIQUE,
    ciclo_inicio            timestamptz,
    ciclo_fim               timestamptz,
    envios_usados_ciclo     integer NOT NULL DEFAULT 0,   -- resetado a cada ciclo via webhook invoice.paid
    atualizado_em           timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 4. CONFIGURAÇÕES POR TENANT (limites de segurança + IA)
-- ------------------------------------------------------------
CREATE TABLE configuracoes (
    cliente_id              uuid PRIMARY KEY REFERENCES clientes(id) ON DELETE CASCADE,
    limite_envios_dia       integer NOT NULL DEFAULT 200,     -- teto diário (aquecimento)
    intervalo_min_seg       integer NOT NULL DEFAULT 25,
    intervalo_max_seg       integer NOT NULL DEFAULT 60,
    janela_inicio           time NOT NULL DEFAULT '09:00',    -- no timezone do tenant
    janela_fim              time NOT NULL DEFAULT '18:00',
    enviar_fim_de_semana    boolean NOT NULL DEFAULT false,
    rodape_optout           boolean NOT NULL DEFAULT true,    -- anexa "Responda SAIR..."
    -- IA
    ia_tom_de_voz           text DEFAULT 'cordial e profissional',
    ia_prompt_contexto      text,                             -- infos do negócio p/ triagem (horários, FAQ...)
    ia_bot_ativo            boolean NOT NULL DEFAULT false,   -- triagem ligada?
    ia_minutos_sem_resposta integer NOT NULL DEFAULT 60,      -- gatilho do alerta
    telefone_alerta         text                              -- E.164: p/ onde vai o aviso de não respondida
);

-- ------------------------------------------------------------
-- 5. INSTÂNCIAS EVOLUTION (números de WhatsApp conectados)
-- ------------------------------------------------------------
CREATE TABLE instancias (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id          uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    nome_instancia      text NOT NULL UNIQUE,             -- nome usado na API da Evolution
    telefone            text,                             -- E.164 do número conectado
    status              status_conexao NOT NULL DEFAULT 'desconectado',
    ultimo_qr_em        timestamptz,
    conectado_em        timestamptz,
    criado_em           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_instancias_cliente ON instancias(cliente_id);

-- ------------------------------------------------------------
-- 6. CONTATOS (com internacionalização e opt-out)
-- ------------------------------------------------------------
CREATE TABLE contatos (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id          uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    nome                text,
    telefone            text NOT NULL,                    -- SEMPRE E.164: +5541..., +1415...
    pais                char(2),                          -- derivado do prefixo na importação
    whatsapp_jid        text,                             -- JID retornado pela verificação (formato real de envio)
    tem_whatsapp        boolean,                          -- null = não verificado ainda
    tags                jsonb NOT NULL DEFAULT '[]',      -- ["apartamento","nao_comprou"]
    campos_extras       jsonb NOT NULL DEFAULT '{}',      -- {"bairro":"Ecoville","modelo":"SUV"}
    descadastrado       boolean NOT NULL DEFAULT false,   -- opt-out GLOBAL e irreversível por campanha
    descadastrado_em    timestamptz,
    origem              text,                             -- 'csv' | 'triagem' | 'manual' | 'crm'
    criado_em           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (cliente_id, telefone)
);
CREATE INDEX idx_contatos_cliente        ON contatos(cliente_id);
CREATE INDEX idx_contatos_tags           ON contatos USING gin(tags);
CREATE INDEX idx_contatos_descadastrado  ON contatos(cliente_id) WHERE descadastrado = false;

-- ------------------------------------------------------------
-- 7. CAMPANHAS + VARIAÇÕES GERADAS POR IA
-- ------------------------------------------------------------
CREATE TABLE campanhas (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id          uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    instancia_id        uuid REFERENCES instancias(id),
    nome                text NOT NULL,
    canal               canal_envio NOT NULL DEFAULT 'whatsapp',
    mensagem_base       text NOT NULL,                    -- com variáveis {nome}, {bairro}...
    filtro_tags         jsonb NOT NULL DEFAULT '[]',      -- tags exigidas (AND)
    status              status_campanha NOT NULL DEFAULT 'rascunho',
    agendada_para       timestamptz,
    iniciada_em         timestamptz,
    concluida_em        timestamptz,
    total_contatos      integer NOT NULL DEFAULT 0,
    criado_em           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_campanhas_cliente ON campanhas(cliente_id);
CREATE INDEX idx_campanhas_status  ON campanhas(status) WHERE status IN ('agendada','em_andamento');

CREATE TABLE variacoes_mensagem (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campanha_id     uuid NOT NULL REFERENCES campanhas(id) ON DELETE CASCADE,
    texto           text NOT NULL,                        -- mantém as variáveis {nome} etc.
    aprovada        boolean NOT NULL DEFAULT false,       -- só aprovadas entram no sorteio
    gerada_por_ia   boolean NOT NULL DEFAULT true,
    criado_em       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_variacoes_campanha ON variacoes_mensagem(campanha_id) WHERE aprovada = true;

-- ------------------------------------------------------------
-- 8. ENVIOS (a fila — coração do sistema)
-- ------------------------------------------------------------
CREATE TABLE envios (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id      uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    campanha_id     uuid NOT NULL REFERENCES campanhas(id) ON DELETE CASCADE,
    contato_id      uuid NOT NULL REFERENCES contatos(id) ON DELETE CASCADE,
    variacao_id     uuid REFERENCES variacoes_mensagem(id),
    texto_final     text,                                 -- variação com variáveis já preenchidas (auditoria)
    status          status_envio NOT NULL DEFAULT 'pendente',
    tentativas      integer NOT NULL DEFAULT 0,
    erro_detalhe    text,
    enviado_em      timestamptz,
    entregue_em     timestamptz,
    respondido_em   timestamptz,
    UNIQUE (campanha_id, contato_id)                      -- nunca 2x o mesmo contato na mesma campanha
);
CREATE INDEX idx_envios_fila ON envios(cliente_id, status) WHERE status = 'pendente';
CREATE INDEX idx_envios_campanha ON envios(campanha_id);

-- ------------------------------------------------------------
-- 9. CONVERSAS + MENSAGENS (monitor de não respondidas + triagem)
-- ------------------------------------------------------------
CREATE TABLE conversas (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id              uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    contato_id              uuid NOT NULL REFERENCES contatos(id) ON DELETE CASCADE,
    ultima_msg_recebida_em  timestamptz,
    ultima_msg_enviada_em   timestamptz,
    aguardando_resposta     boolean NOT NULL DEFAULT false,   -- true = cliente falou por último
    alerta_enviado_em       timestamptz,                      -- evita alertar 2x a mesma pendência
    bot_ativo               boolean NOT NULL DEFAULT true,    -- false após handoff p/ humano
    criado_em               timestamptz NOT NULL DEFAULT now(),
    UNIQUE (cliente_id, contato_id)
);
CREATE INDEX idx_conversas_pendentes
    ON conversas(cliente_id, ultima_msg_recebida_em)
    WHERE aguardando_resposta = true AND alerta_enviado_em IS NULL;

CREATE TABLE mensagens (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversa_id     uuid NOT NULL REFERENCES conversas(id) ON DELETE CASCADE,
    direcao         direcao_mensagem NOT NULL,
    texto           text,
    enviada_por_ia  boolean NOT NULL DEFAULT false,
    -- resultado da triagem (quando direcao = 'recebida' e bot ativo)
    ia_intencao     text,                                 -- 'compra' | 'duvida' | 'reclamacao'...
    ia_acao         acao_triagem,
    recebida_em     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_mensagens_conversa ON mensagens(conversa_id, recebida_em);

-- ------------------------------------------------------------
-- 10. AVALIAÇÕES DE ATENDIMENTO (módulo premium, gerado por IA)
-- ------------------------------------------------------------
CREATE TABLE avaliacoes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id          uuid NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    conversa_id         uuid NOT NULL REFERENCES conversas(id) ON DELETE CASCADE,
    periodo_ref         date NOT NULL,                    -- dia/semana avaliado
    nota_qualidade      smallint CHECK (nota_qualidade BETWEEN 1 AND 10),
    sentimento          text,                             -- 'positivo' | 'neutro' | 'negativo'
    intencao_compra     boolean,
    oportunidade_perdida boolean,
    resumo              text,                             -- 2 linhas geradas pela IA
    criado_em           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_avaliacoes_cliente ON avaliacoes(cliente_id, periodo_ref);

-- ------------------------------------------------------------
-- 11. LOG DE EVENTOS (auditoria: webhooks Stripe, conexões, erros)
-- ------------------------------------------------------------
CREATE TABLE eventos (
    id          bigserial PRIMARY KEY,
    cliente_id  uuid REFERENCES clientes(id) ON DELETE SET NULL,
    tipo        text NOT NULL,        -- 'stripe.invoice.paid' | 'evolution.desconectado' | 'optout' ...
    payload     jsonb,
    criado_em   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_eventos_cliente_tipo ON eventos(cliente_id, tipo, criado_em);

-- ============================================================
-- SEEDS: PLANOS
-- ============================================================
INSERT INTO planos (id, nome, limite_envios_mes, max_numeros, ia_variacoes, ia_triagem, ia_avaliacao, preco_centavos, moeda) VALUES
    ('essencial',    'Essencial',    1000,  1, true, false, false,  9700, 'BRL'),
    ('profissional', 'Profissional', 3000,  1, true, true,  false, 19700, 'BRL'),
    ('premium',      'Premium',      10000, 2, true, true,  true,  39700, 'BRL');

INSERT INTO planos_precos (plano_id, moeda, preco_centavos, stripe_price_id) VALUES
    ('essencial',    'BRL',  9700, 'price_TROCAR_essencial_brl'),
    ('essencial',    'USD',  4900, 'price_TROCAR_essencial_usd'),
    ('profissional', 'BRL', 19700, 'price_TROCAR_profissional_brl'),
    ('profissional', 'USD',  9900, 'price_TROCAR_profissional_usd'),
    ('premium',      'BRL', 39700, 'price_TROCAR_premium_brl'),
    ('premium',      'USD', 19900, 'price_TROCAR_premium_usd');

-- ============================================================
-- QUERIES DE REFERÊNCIA (usar nos workflows do n8n)
-- ============================================================

-- (A) Montar a fila de uma campanha (respeita opt-out, whatsapp válido e tags):
-- INSERT INTO envios (cliente_id, campanha_id, contato_id)
-- SELECT c.cliente_id, :campanha_id, c.id
-- FROM contatos c
-- WHERE c.cliente_id = :cliente_id
--   AND c.descadastrado = false
--   AND (c.tem_whatsapp IS DISTINCT FROM false)
--   AND c.tags @> (SELECT filtro_tags FROM campanhas WHERE id = :campanha_id)
-- ON CONFLICT DO NOTHING;

-- (B) Próximo lote da fila (com trava p/ execuções concorrentes do n8n):
-- SELECT e.id, e.contato_id FROM envios e
-- WHERE e.cliente_id = :cliente_id AND e.status = 'pendente'
-- ORDER BY e.id
-- LIMIT 5
-- FOR UPDATE SKIP LOCKED;

-- (C) Conversas pendentes para o alerta de não respondidas:
-- SELECT cv.id, ct.nome, ct.telefone, cv.ultima_msg_recebida_em
-- FROM conversas cv
-- JOIN contatos ct ON ct.id = cv.contato_id
-- JOIN configuracoes cf ON cf.cliente_id = cv.cliente_id
-- WHERE cv.aguardando_resposta = true
--   AND cv.alerta_enviado_em IS NULL
--   AND cv.ultima_msg_recebida_em < now() - make_interval(mins => cf.ia_minutos_sem_resposta);

-- (D) Verificar saldo do plano antes de disparar:
-- SELECT (p.limite_envios_mes - a.envios_usados_ciclo) AS saldo
-- FROM assinaturas a JOIN planos p ON p.id = a.plano_id
-- WHERE a.cliente_id = :cliente_id AND a.status IN ('ativa','trial');
