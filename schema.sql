-- ===========================================================================
-- Payment Platform - initial database schema (first pass)
-- PostgreSQL 15+. Money is stored as integer cents. Multi-tenant by app_id + RLS.
-- Prose/comments in English to match the codebase.
-- ===========================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- Enums (closed value sets and state-machine states)
-- ---------------------------------------------------------------------------
CREATE TYPE gateway_provider    AS ENUM ('mercado_pago', 'stripe', 'asaas', 'pix');
CREATE TYPE payment_method_type AS ENUM ('card', 'pix', 'boleto');

CREATE TYPE charge_status AS ENUM (
  'PENDING', 'AUTHORIZED', 'PAID',
  'FAILED', 'EXPIRED', 'CANCELED',
  'REFUNDED', 'PARTIALLY_REFUNDED', 'CHARGEBACK'
);

CREATE TYPE transaction_type AS ENUM (
  'CHARGE', 'CAPTURE', 'REFUND', 'CHARGEBACK', 'FEE', 'ADJUSTMENT'
);

CREATE TYPE subscription_status AS ENUM (
  'TRIALING', 'ACTIVE', 'PAST_DUE', 'CANCELED', 'EXPIRED'
);

CREATE TYPE cycle_status AS ENUM ('PENDING', 'PAID', 'FAILED', 'SKIPPED');

-- Shared trigger to maintain updated_at
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- apps: each consumer product (LP / SaaS) that uses the platform
-- ---------------------------------------------------------------------------
CREATE TABLE apps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text NOT NULL UNIQUE,
  name        text NOT NULL,
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_apps_updated BEFORE UPDATE ON apps
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- app_api_keys: credentials per app (store only the hash)
CREATE TABLE app_api_keys (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id       uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  key_prefix   text NOT NULL UNIQUE,       -- shown for identification / lookup
  key_hash     text NOT NULL,              -- hashed secret, never plaintext
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  last_used_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);
CREATE INDEX idx_api_keys_app ON app_api_keys(app_id);

-- ---------------------------------------------------------------------------
-- gateway_accounts: per-app gateway configuration
-- ---------------------------------------------------------------------------
CREATE TABLE gateway_accounts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id      uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  provider    gateway_provider NOT NULL,
  secret_ref  text NOT NULL,               -- pointer to secrets manager, never raw creds
  config      jsonb NOT NULL DEFAULT '{}', -- routing rules, method->gateway mapping
  is_default  boolean NOT NULL DEFAULT false,
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gw_app ON gateway_accounts(app_id);
CREATE UNIQUE INDEX idx_gw_one_default ON gateway_accounts(app_id) WHERE is_default;
CREATE TRIGGER trg_gw_updated BEFORE UPDATE ON gateway_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- customers: payers, scoped per app
-- ---------------------------------------------------------------------------
CREATE TABLE customers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id      uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  external_id text,                         -- id in the consumer app
  email       text,
  name        text,
  tax_id      text,                         -- CPF/CNPJ (needed for PIX/boleto)
  metadata    jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app_id, external_id)
);
CREATE INDEX idx_customers_app ON customers(app_id);
CREATE TRIGGER trg_customers_updated BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- payment_methods: card-on-file tokens (NEVER the PAN)
-- ---------------------------------------------------------------------------
CREATE TABLE payment_methods (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id             uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  customer_id        uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  gateway_account_id uuid NOT NULL REFERENCES gateway_accounts(id),
  type               payment_method_type NOT NULL,
  provider_token     text NOT NULL,         -- token at the gateway
  brand              text,
  last4              text,
  exp_month          smallint,
  exp_year           smallint,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','expired','removed')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_pm_customer ON payment_methods(customer_id);
CREATE TRIGGER trg_pm_updated BEFORE UPDATE ON payment_methods
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- orders: the purchase intent (one-off flow, e.g. tickets)
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id       uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  customer_id  uuid REFERENCES customers(id),
  external_ref text,                         -- order id in the consumer app
  description  text,
  amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
  currency     char(3) NOT NULL DEFAULT 'BRL',
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open','paid','canceled','expired')),
  metadata     jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app_id, external_ref)
);
CREATE INDEX idx_orders_app ON orders(app_id);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- plans + subscriptions + subscription_cycles (recurring flow)
-- ---------------------------------------------------------------------------
CREATE TABLE plans (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id            uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  name              text NOT NULL,
  amount_cents      bigint NOT NULL CHECK (amount_cents >= 0),
  currency          char(3) NOT NULL DEFAULT 'BRL',
  interval          text NOT NULL CHECK (interval IN ('day','week','month','year')),
  interval_count    smallint NOT NULL DEFAULT 1 CHECK (interval_count > 0),
  trial_period_days smallint NOT NULL DEFAULT 0,
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_plans_app ON plans(app_id);
CREATE TRIGGER trg_plans_updated BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE subscriptions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id               uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  plan_id              uuid NOT NULL REFERENCES plans(id),
  customer_id          uuid NOT NULL REFERENCES customers(id),
  payment_method_id    uuid REFERENCES payment_methods(id),
  gateway_account_id   uuid NOT NULL REFERENCES gateway_accounts(id),
  status               subscription_status NOT NULL DEFAULT 'TRIALING',
  current_period_start timestamptz,
  current_period_end   timestamptz,
  trial_end            timestamptz,
  canceled_at          timestamptz,
  ended_at             timestamptz,
  external_ref         text,
  metadata             jsonb NOT NULL DEFAULT '{}',
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_subs_app ON subscriptions(app_id);
CREATE INDEX idx_subs_customer ON subscriptions(customer_id);
CREATE INDEX idx_subs_status ON subscriptions(status);
CREATE TRIGGER trg_subs_updated BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE subscription_cycles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id          uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  subscription_id uuid NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
  sequence        integer NOT NULL,          -- 1, 2, 3, ...
  period_start    timestamptz NOT NULL,
  period_end      timestamptz NOT NULL,
  amount_cents    bigint NOT NULL CHECK (amount_cents >= 0),
  currency        char(3) NOT NULL DEFAULT 'BRL',
  status          cycle_status NOT NULL DEFAULT 'PENDING',
  attempt_count   smallint NOT NULL DEFAULT 0,   -- dunning attempts
  next_retry_at   timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subscription_id, sequence)
);
CREATE INDEX idx_cycles_sub ON subscription_cycles(subscription_id);
CREATE INDEX idx_cycles_retry ON subscription_cycles(next_retry_at) WHERE status = 'FAILED';
CREATE TRIGGER trg_cycles_updated BEFORE UPDATE ON subscription_cycles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- charges: the unified charge primitive (one-off OR one subscription cycle)
-- ---------------------------------------------------------------------------
CREATE TABLE charges (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id                uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  order_id              uuid REFERENCES orders(id),
  subscription_cycle_id uuid REFERENCES subscription_cycles(id),
  customer_id           uuid REFERENCES customers(id),
  gateway_account_id    uuid NOT NULL REFERENCES gateway_accounts(id),
  payment_method_id     uuid REFERENCES payment_methods(id),
  amount_cents          bigint NOT NULL CHECK (amount_cents >= 0),
  currency              char(3) NOT NULL DEFAULT 'BRL',
  method_type           payment_method_type NOT NULL,
  status                charge_status NOT NULL DEFAULT 'PENDING',
  provider_charge_id    text,                 -- id at the gateway
  failure_reason        text,
  expires_at            timestamptz,          -- PIX / boleto expiration
  authorized_at         timestamptz,
  paid_at               timestamptz,
  canceled_at           timestamptz,
  refunded_amount_cents bigint NOT NULL DEFAULT 0 CHECK (refunded_amount_cents >= 0),
  metadata              jsonb NOT NULL DEFAULT '{}',
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  -- a charge belongs to exactly one source: an order OR a subscription cycle
  CONSTRAINT chk_charge_source CHECK (
    (order_id IS NOT NULL) <> (subscription_cycle_id IS NOT NULL)
  ),
  CONSTRAINT chk_refund_le_amount CHECK (refunded_amount_cents <= amount_cents)
);
CREATE INDEX idx_charges_app ON charges(app_id);
CREATE INDEX idx_charges_order ON charges(order_id);
CREATE INDEX idx_charges_cycle ON charges(subscription_cycle_id);
CREATE INDEX idx_charges_status ON charges(status);
CREATE UNIQUE INDEX idx_charges_provider
  ON charges(gateway_account_id, provider_charge_id)
  WHERE provider_charge_id IS NOT NULL;
CREATE TRIGGER trg_charges_updated BEFORE UPDATE ON charges
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- transactions: append-only ledger of money movements
-- ---------------------------------------------------------------------------
CREATE TABLE transactions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id                  uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  charge_id               uuid NOT NULL REFERENCES charges(id),
  type                    transaction_type NOT NULL,
  amount_cents            bigint NOT NULL,     -- signed: >0 money in, <0 money out
  currency                char(3) NOT NULL DEFAULT 'BRL',
  provider_transaction_id text,
  occurred_at             timestamptz NOT NULL DEFAULT now(),
  metadata                jsonb NOT NULL DEFAULT '{}',
  created_at              timestamptz NOT NULL DEFAULT now()
  -- append-only: intentionally no updated_at
);
CREATE INDEX idx_tx_charge ON transactions(charge_id);
CREATE INDEX idx_tx_app ON transactions(app_id);

-- Enforce the append-only ledger at the database level
CREATE RULE transactions_no_update AS ON UPDATE TO transactions DO INSTEAD NOTHING;
CREATE RULE transactions_no_delete AS ON DELETE TO transactions DO INSTEAD NOTHING;

-- ---------------------------------------------------------------------------
-- Operational tables: reliability primitives
-- ---------------------------------------------------------------------------

-- Inbound webhooks from gateways (idempotent ingestion)
CREATE TABLE webhook_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider     gateway_provider NOT NULL,
  external_id  text NOT NULL,                -- event id from the gateway
  app_id       uuid REFERENCES apps(id),
  event_type   text,
  payload      jsonb NOT NULL,
  signature_ok boolean NOT NULL DEFAULT false,
  status       text NOT NULL DEFAULT 'received' CHECK (status IN ('received','processed','failed')),
  received_at  timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  UNIQUE (provider, external_id)              -- dedupe repeated deliveries
);
CREATE INDEX idx_webhooks_status ON webhook_events(status);

-- Outbound domain events delivered to consumer apps (transactional outbox)
CREATE TABLE outbox_events (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id         uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  event_type     text NOT NULL,              -- e.g. 'payment.confirmed'
  aggregate_type text NOT NULL,              -- e.g. 'charge'
  aggregate_id   uuid NOT NULL,
  payload        jsonb NOT NULL,
  status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','published','failed')),
  available_at   timestamptz NOT NULL DEFAULT now(),  -- for delayed retry / backoff
  attempt_count  smallint NOT NULL DEFAULT 0,
  published_at   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_outbox_dispatch ON outbox_events(available_at) WHERE status = 'pending';

-- Idempotency keys for mutating API requests
CREATE TABLE idempotency_keys (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id       uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  key          text NOT NULL,
  request_hash text NOT NULL,                -- detect same key + different body
  status       text NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress','completed')),
  response     jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  UNIQUE (app_id, key)
);

-- ---------------------------------------------------------------------------
-- Row-Level Security (multi-tenant isolation by app_id)
-- The application sets, per request/transaction:
--   SET app.current_app_id = '<uuid>';
-- ---------------------------------------------------------------------------
ALTER TABLE customers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_methods     ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders              ENABLE ROW LEVEL SECURITY;
ALTER TABLE plans               ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE charges             ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions        ENABLE ROW LEVEL SECURITY;

-- Same policy pattern on every tenant-scoped table:
CREATE POLICY tenant_isolation ON customers
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON payment_methods
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON orders
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON plans
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON subscriptions
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON subscription_cycles
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON charges
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON transactions
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
