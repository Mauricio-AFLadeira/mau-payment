# Arquitetura — Plataforma de Pagamentos

> Documento de arquitetura da plataforma de pagamentos interna.
> Prosa em português; identificadores de código, tabelas e eventos em inglês.
> Versão viva — atualizar conforme as decisões evoluírem.

---

## 1. Contexto e objetivo

Construir uma **plataforma de pagamentos interna, headless e API-first**, reutilizável entre os produtos próprios (LPs e SaaS) que serão criados ao longo do tempo. Não é um SaaS vendido a terceiros nem um front-end: é um serviço central que os próprios produtos consomem por API — na prática, um "mini-Stripe" interno.

Casos de uso previstos desde o início:

- **Venda avulsa** — ex.: LP de venda de ingressos para um evento (pagamento único, com controle de estoque).
- **Assinatura** — ex.: SaaS com cobrança recorrente (mensal/anual, com dunning e card-on-file).

Requisito central: **um núcleo estável** que nunca muda, com a variação de cada produto entrando por **configuração e eventos**, não por fork de código.

---

## 2. Visão geral: plataforma como serviço interno

A plataforma é o centro; cada produto (LP/SaaS) é um **consumidor** dela.

- Cada produto se registra como um `app`, com **credencial própria** (chave/HMAC) e config atrelada (gateways, taxas, tipos de produto).
- Os produtos **chamam a API** para criar cobranças e **recebem eventos de saída** (webhooks) quando algo acontece (`PaymentConfirmed` → a LP emite o ingresso; o SaaS libera o acesso).
- "Tenant", aqui, é **cada produto seu** (`app_id`), não um cliente externo pagante. Isso simplifica a multi-tenancy: um `app_id` por produto resolve o isolamento, e a fronteira de confiança é amigável.

**Regra do contrato:** mesmo sendo interno, a API é tratada como pública — versionada (`/v1`) desde o dia 1. Quebrar o contrato quebraria todos os produtos que já dependem dela de uma vez.

---

## 3. Modalidades de pagamento

O insight que unifica tudo: separar a **geração da cobrança** (quando/por que cobrar) da **movimentação do dinheiro** (a transação). Assim, ingresso e assinatura viram apenas formas diferentes de gerar a **mesma** `charge`, e o núcleo continua único.

| Modalidade | Entrada | O que adiciona |
|---|---|---|
| Avulso (ingresso) | 1 `charge` na hora do checkout | Reserva de estoque com TTL |
| Assinatura | Agendador gera `charge` por ciclo | Scheduler recorrente, dunning, card-on-file, state machine própria |

Peças exclusivas da assinatura:

- **Agendador recorrente** — dispara uma `charge` a cada ciclo.
- **State machine própria** — descreve o *contrato* (`subscription`), distinta da state machine de uma `charge`.
- **Dunning** — retentativa quando a cobrança recorrente falha (cartão expirado, sem saldo): reagenda, dá período de tolerância, avisa e eventualmente suspende.
- **Card-on-file** — token do meio de pagamento salvo no gateway, para cobrar **sem o cliente presente**.

---

## 4. Camadas e concerns transversais

Backend organizado em camadas (arquitetura hexagonal), com as regras de negócio no centro. Segurança e observabilidade **atravessam** todas as camadas — não são etapas isoladas.

```
┌──────────────────────────────────────────────┐
│  Segurança  (transversal a todas as camadas)  │
├──────────────────────────────────────────────┤
│  API            REST v1 + webhooks in          │
│  Aplicação      casos de uso (orquestração)    │
│  Domínio        regras de negócio (puro)       │
│  Infraestrutura Database · Queue · Gateways    │
├──────────────────────────────────────────────┤
│  Observabilidade  (transversal)                │
└──────────────────────────────────────────────┘
```

- **Domínio (puro):** entidades, value objects, state machines, invariantes. Sem framework, 100% testável, reutilizável entre produtos.
- **Aplicação:** casos de uso (`CreateCharge`, `ConfirmPayment`, `StartSubscription`, `RunBillingCycle`).
- **Infra:** implementa as portas (repositórios, fila, adapters de gateway).
- **API:** a fronteira que os produtos consomem.

---

## 5. Decisões por bloco

### 5.1 Database — PostgreSQL

Escolhido pela integridade transacional, pelo ledger e porque **Row-Level Security** dá o isolamento por `app_id` quase de graça.

Tabelas centrais:

- `apps` — produtos consumidores + chaves/credenciais
- `customers`
- `orders`
- `charges` — cobranças (primitivo unificado avulso/recorrente)
- `transactions` — movimentações de dinheiro; **ledger append-only e imutável**
- `subscriptions`, `subscription_cycles`
- `payment_methods` — tokens de card-on-file
- `gateway_accounts` — config de gateway por app
- `webhook_events` — entrada dos gateways; `external_id` **único** para idempotência
- `outbox_events` — eventos de domínio a publicar (ver outbox pattern)
- `idempotency_keys`

Regras não-negociáveis:

- **Dinheiro** em `bigint` de centavos + `currency` (ISO 4217). Nunca float.
- **Status** como enum string, com a state machine garantida em código (não só constraint).
- **Migrations** versionadas (Prisma Migrate ou Drizzle Kit).

### 5.2 Queue — BullMQ (sobre Redis)

Cobre num pacote só: `repeatable jobs` (ciclos de assinatura), `delayed jobs` com backoff (dunning) e retry nativo (webhooks).

Filas:

- `webhook-inbound` — processa webhooks dos gateways
- `subscription-billing` — gera cobranças por ciclo
- `dunning` — retentativas de cobrança recorrente
- `outbound-events` — entrega eventos aos produtos consumidores

**Transactional outbox:** grava o evento em `outbox_events` na **mesma transação** que muda o estado; um worker publica na fila depois. Garante que nenhum evento se perca nem seja publicado para algo que não commitou. Todo handler de job é **idempotente**.

### 5.3 Backend — NestJS (em camadas)

Injeção de dependência e modularidade que casam com o padrão de adapters.

Módulos: `apps` (registro + auth), `payments`, `subscriptions`, `gateways`, `webhooks`, `events`.

O gateway é uma **porta** (`PaymentGatewayPort`); cada provedor é um **adapter** que a implementa.

### 5.4 Gateways

Interface única para todos os provedores:

```
createCharge · capture · refund · getStatus
tokenizePaymentMethod · chargeSavedMethod · verifyWebhookSignature
```

- Cada adapter **normaliza** a resposta do provedor para os estados internos — o enum da Stripe/Mercado Pago **nunca vaza** para o núcleo.
- Seleção de gateway vem da config do `app` (método → gateway).
- **Recorrência:** motor próprio dispara `chargeSavedMethod` a cada ciclo, mantendo dunning e proração uniformes entre provedores. (Começar delegando ao gateway é possível, desde que o núcleo já modele `charge` como primitivo unificado.)

Provedores previstos: Mercado Pago, Stripe, Asaas, PIX.

### 5.5 Security (transversal)

- **Auth por app**: chave/HMAC, escopo por `app_id`.
- **PCI**: nunca armazenar número de cartão — tokenizar no gateway (escopo cai para SAQ-A). Card-on-file = token do gateway em `payment_methods`.
- **Webhooks**: validar assinatura na entrada; **assinar** os eventos enviados aos produtos.
- **Secrets**: gerenciador dedicado (Doppler / AWS Secrets Manager / Vault); credenciais de gateway criptografadas em repouso.
- **Dados**: RLS por `app_id`; idempotency-key em todo endpoint que muda estado; rate limit por app; LGPD (retenção e exclusão).

### 5.6 Business rules (o domínio)

O coração da plataforma:

- **State machine de `charge`**: `PENDING → AUTHORIZED → PAID → REFUNDED / FAILED / EXPIRED`
- **State machine de `subscription`**: `TRIALING → ACTIVE → PAST_DUE → CANCELED / EXPIRED`
- **Invariantes**: não estornar mais do que foi capturado; não confirmar duas vezes; etc.
- **Reserva de estoque com TTL** (ingressos).
- **Dunning e proração**.

Customização por produto entra como **config e policy objects** — nunca como fork.

### 5.7 API / contrato

- REST **versionada** (`/v1`), especificação **OpenAPI**.
- Header de **idempotência** em operações que mudam estado.
- Modelo de **erro consistente**.
- É o que as LPs consomem: estabilidade é inegociável.

### 5.8 Observabilidade

- Log estruturado (pino), métricas e tracing (OpenTelemetry).
- Alertas em falha de cobrança e dunning.
- **Job diário de reconciliação**: compara `transactions` internas com os registros do gateway. Sem ele, divergência de dinheiro só aparece via reclamação de cliente.

---

## 6. Decisões de arquitetura registradas (ADRs)

| # | Decisão | Motivo |
|---|---|---|
| ADR-01 | Plataforma interna, headless, API-first | Reuso entre múltiplos produtos próprios |
| ADR-02 | Multi-tenancy por `app_id` + RLS | Tenant = produto próprio; isolamento simples |
| ADR-03 | `charge` como primitivo unificado (avulso + recorrente) | Núcleo único; assinatura vira orquestração acima |
| ADR-04 | Abstração de gateways por porta/adapter | Trocar/somar provedor sem tocar no núcleo |
| ADR-05 | Motor de recorrência próprio (gateway só cobra) | Dunning e proração uniformes; customização |
| ADR-06 | Transactional outbox para eventos | Não perder evento nem publicar de estado não commitado |
| ADR-07 | Dinheiro em `bigint` de centavos | Evitar erro de arredondamento em recorrência |
| ADR-08 | Segurança e observabilidade como transversais | Não esquecer em nenhuma camada |
| ADR-09 | API versionada desde `/v1` | Evitar efeito dominó ao evoluir o contrato |

---

## 7. Stack

| Camada | Escolha |
|---|---|
| Linguagem | TypeScript (Node.js) |
| Framework | NestJS |
| Banco | PostgreSQL (+ RLS) |
| ORM / migrations | Prisma ou Drizzle |
| Fila | BullMQ (Redis) |
| Observabilidade | pino + OpenTelemetry |
| Secrets | Doppler / AWS Secrets Manager / Vault |

---

## 8. Próximos passos

1. **Modelagem do banco** (próximo bloco): tabelas, colunas, relacionamentos e as duas state machines em detalhe. Trava o vocabulário que todos os outros blocos usam.
2. Desenho do motor de recorrência com BullMQ.
3. Definição do contrato da API `/v1` (OpenAPI).
