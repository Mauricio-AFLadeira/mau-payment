-- ===========================================================================
-- Payment Platform - orders & inventory extension (tickets / finite stock)
-- Extends schema.sql. The platform stays generic: it knows "products" with an
-- optional finite stock, not "events" or "seats" (those live in the consumer
-- app, which maps its ticket types onto products and uses metadata).
-- ===========================================================================

CREATE TYPE reservation_status AS ENUM ('HELD', 'CONFIRMED', 'RELEASED', 'EXPIRED');

-- ---------------------------------------------------------------------------
-- products: generic sellable item with optional finite stock
-- ---------------------------------------------------------------------------
CREATE TABLE products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id          uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  external_ref    text,                      -- ticket-type id in the consumer app
  name            text NOT NULL,
  amount_cents    bigint NOT NULL CHECK (amount_cents >= 0),
  currency        char(3) NOT NULL DEFAULT 'BRL',
  stock_total     integer CHECK (stock_total IS NULL OR stock_total >= 0),      -- NULL = untracked
  stock_available integer CHECK (stock_available IS NULL OR stock_available >= 0),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','sold_out','archived')),
  metadata        jsonb NOT NULL DEFAULT '{}',   -- consumer app stashes event/seat info here
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app_id, external_ref),
  -- if stock is tracked, both columns are set and available never exceeds total
  CONSTRAINT chk_stock_pair CHECK (
    (stock_total IS NULL AND stock_available IS NULL) OR
    (stock_total IS NOT NULL AND stock_available IS NOT NULL AND stock_available <= stock_total)
  )
);
CREATE INDEX idx_products_app ON products(app_id);
CREATE TRIGGER trg_products_updated BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- order_items: line items of an order (order.amount_cents = SUM of these)
-- ---------------------------------------------------------------------------
CREATE TABLE order_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id            uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  order_id          uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id        uuid REFERENCES products(id),   -- NULL = ad-hoc item, no inventory
  description       text NOT NULL,
  unit_amount_cents bigint NOT NULL CHECK (unit_amount_cents >= 0),
  quantity          integer NOT NULL CHECK (quantity > 0),
  amount_cents      bigint NOT NULL CHECK (amount_cents >= 0),   -- unit_amount_cents * quantity
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);

-- ---------------------------------------------------------------------------
-- stock_reservations: temporary holds with TTL, tied to an order
-- ---------------------------------------------------------------------------
CREATE TABLE stock_reservations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id      uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES products(id),
  order_id    uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  quantity    integer NOT NULL CHECK (quantity > 0),
  status      reservation_status NOT NULL DEFAULT 'HELD',
  expires_at  timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_resv_order ON stock_reservations(order_id);
CREATE INDEX idx_resv_product ON stock_reservations(product_id);
-- sweeper index: quickly find holds that must expire
CREATE INDEX idx_resv_sweep ON stock_reservations(expires_at) WHERE status = 'HELD';
CREATE TRIGGER trg_resv_updated BEFORE UPDATE ON stock_reservations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- Row-Level Security (same tenant pattern as schema.sql)
-- ---------------------------------------------------------------------------
ALTER TABLE products           ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_reservations ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON products
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON order_items
  USING (app_id = current_setting('app.current_app_id', true)::uuid);
CREATE POLICY tenant_isolation ON stock_reservations
  USING (app_id = current_setting('app.current_app_id', true)::uuid);

-- ===========================================================================
-- Reservation flow (application layer, all inside the checkout transaction)
-- ===========================================================================
--
-- 1. RESERVE (oversell guard) - run once per item with a tracked product:
--
--      UPDATE products
--         SET stock_available = stock_available - :qty
--       WHERE id = :product_id
--         AND (stock_available IS NULL OR stock_available >= :qty)
--      RETURNING stock_available;
--
--    Zero rows returned  => sold out => abort checkout.
--    One row returned    => insert a stock_reservation (status HELD, expires_at).
--
-- 2. CONFIRM (on charge PAID):
--      UPDATE stock_reservations SET status = 'CONFIRMED' WHERE order_id = :order_id;
--      -- stock_available stays decremented (the sale is final)
--
-- 3. RELEASE (on charge FAILED/CANCELED) or EXPIRE (TTL reached, still HELD):
--      UPDATE stock_reservations SET status = :terminal WHERE id = :resv_id;
--      UPDATE products SET stock_available = stock_available + :qty WHERE id = :product_id;
--
-- Scheduling: enqueue a BullMQ delayed job at expires_at to run step 3 if the
-- reservation is still HELD. A periodic sweeper over idx_resv_sweep is the backstop.
-- ===========================================================================
