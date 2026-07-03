# Payment Platform — Claude Code Project Memory

Internal, headless, API-first payment platform (a "mini-Stripe" for our own products).
Consumed by our own LPs / SaaS apps over a versioned REST API. TypeScript / Node.js.

Full context lives in ARCHITECTURE.md. Database: schema.sql + orders_inventory.sql.

## Architecture at a glance
- Hexagonal / layered: domain (pure) -> application (use cases) -> infrastructure (adapters) -> API.
- `charge` is the unified primitive: a charge belongs to EITHER an order (one-off) OR a
  subscription_cycle (recurring). The core never branches on "mode".
- Money movements are recorded in `transactions` — an append-only ledger.
- Event-driven via a transactional outbox (`outbox_events`) delivered to consumer apps.
- Payment gateways are ports (`PaymentGatewayPort`); each provider is an adapter.
  Gateway-specific enums/shapes never leak into the domain.

## Hard rules (never violate)
- Money is ALWAYS integer cents (`bigint`) + a `currency` code. Never use floats.
- `transactions` is append-only. Never UPDATE or DELETE a ledger row; a refund is a NEW transaction.
- NEVER store card PANs. Card-on-file = a gateway token stored in `payment_methods`.
- Multi-tenant by `app_id` + Postgres RLS. Every request sets `app.current_app_id`.
- Every mutating endpoint requires an idempotency key.
- The public API is versioned (`/v1`) and treated as a stable contract.
- All code, identifiers, table/column names, enums and events are in ENGLISH.
- The platform stays generic: it knows `products` with optional stock, NOT "events" or "seats".
  Domain specifics live in the consumer app / in metadata.

## Stack
- Runtime: Node.js + TypeScript
- Framework: NestJS (modular, DI — fits the port/adapter pattern)
- Database: PostgreSQL 15+ with Row-Level Security
- Persistence: schema.sql is the SOURCE OF TRUTH (it relies on RLS, RULES and partial indexes
  that ORMs don't fully model). Apply it as the baseline migration; use Prisma or Drizzle for
  typed access on top. Do not let an ORM silently redefine these tables.
- Queue/scheduler: BullMQ over Redis (recurring billing, dunning, webhook processing, outbox delivery)
- Observability: pino (structured logs) + OpenTelemetry
- Secrets: never in the DB; use a secrets manager and store only a `secret_ref`

## Module map (target)
- apps          — app registry, API keys, RLS context middleware
- payments      — charges core + charge state machine + idempotency
- gateways      — PaymentGatewayPort + provider adapters (mercado_pago, stripe, asaas, pix)
- webhooks      — inbound gateway webhooks (idempotent ingestion, signature check)
- events        — outbox dispatch to consumer apps (signed outbound webhooks)
- subscriptions — plans, subscriptions, cycles, dunning
- orders        — orders, order_items, products, stock reservations

## State machines (enforce in the domain layer, reject any other transition)
- charge:  PENDING -> AUTHORIZED -> PAID -> (REFUNDED | PARTIALLY_REFUNDED | CHARGEBACK);
           PENDING/AUTHORIZED -> (FAILED | EXPIRED | CANCELED). PIX/boleto go PENDING -> PAID.
- subscription: TRIALING -> ACTIVE -> PAST_DUE -> (CANCELED | EXPIRED);
                PAST_DUE -> ACTIVE on dunning recovery.
- stock_reservation: HELD -> (CONFIRMED on paid | RELEASED on fail/cancel | EXPIRED on TTL).
                     RELEASED/EXPIRED restore `stock_available`.

## Workflow preferences
- Use plan mode for anything touching money flow, migrations, or the ledger; show the plan first.
- Keep the domain layer free of framework and gateway details (pure, unit-testable).
- Write tests for every state transition and every invariant.
- Prefer the guarded UPDATE for stock (oversell guard) over application-side locking.

## Commands
<!-- Fill these in right after scaffolding so Claude never guesses. -->
- install:
- dev:
- build:
- test:
- lint:
- migrate:
