# Ekylibre Qonto

Ekylibre plugin to interact with bank data — and, incrementally, electronic
invoicing — through the [Qonto Business API v2](https://api-doc.qonto.com/docs/business-api/6434cbb9d968d-qonto).

## Features

- **Bank statements & attachments** — import Qonto transactions as
  `BankStatement` / `BankStatementItem`, and download their attachments as
  `Document`s.
- **E-invoicing gateway (in progress)** — a regulatory port
  `EInvoicing::Gateway` decoupled from Qonto (see below), so a change of
  *Plateforme Agréée* stays an adapter swap. Qonto is one implementation.

- **Expenses to justify** (`/qonto/expenses`) — for each unreconciled debit
  line, suggests the purchase behind it: the supplier document Qonto matched,
  an unpaid purchase already entered, or the supplier and shape learned from
  past payments. Documents (Qonto attachments, received invoices) are read
  locally (PyMuPDF, tesseract for scans) to complete date, number, SIRET and
  VAT split. Nothing is created without the accountant validating the core
  "new purchase" form. Needs `python3` and `pymupdf` in the app image (added
  to the Dockerfiles); without them the suggestions still work, minus the
  document reading. Design: `docs/design-expense-to-purchase.md`.

## Configuration

Configure the Qonto integration for the tenant with your API key credentials:

- `client_id` — the Qonto organization login
- `client_secret` — the Qonto secret key

Authentication uses the API-key header `Authorization: <client_id>:<client_secret>`.

## E-invoicing gateway

The port lives in `app/services/e_invoicing/` and speaks a **regulatory**
vocabulary (`submit`, `issued`, `received`), not Qonto's:

| Adapter | Usage |
|---|---|
| `EInvoicing::Adapters::Qonto` | production |
| `EInvoicing::Adapters::Null` | tenant without integration — the UI degrades instead of crashing |
| `EInvoicing::Adapters::Fake` | tests & staging (Qonto e-invoicing does not exist in sandbox) |

`EInvoicing::Gateway.build` returns the Qonto adapter as soon as a Qonto
integration is configured for the tenant (`EInvoicing::Gateway.available?`),
otherwise the Null adapter — a configured integration is the single source of
truth, there is no separate manual toggle. The compliance banner reads the real
reception state from the API (cached) via `Qonto::EInvoicingSettings`.

## Documentation

- Business API: https://api-doc.qonto.com/docs/business-api/6434cbb9d968d-qonto
- E-invoicing endpoints: `GET /v2/einvoicing/settings`, `GET /v2/clients`
  (`e_invoicing_reachable`), `POST /v2/client_invoices`, `GET /v2/supplier_invoices`.
