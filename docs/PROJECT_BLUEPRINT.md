# Pockito — Project Blueprint

> Status: living document / initial architecture baseline  
> Repository: https://github.com/Lannnmmmm/pockito_bot  
> Last updated: 2026-11-06

## 1. Product direction

Pockito is a personal finance application being rebuilt from the existing Google Apps Script version. The GitHub repository `Lannnmmmm/pockito_bot` is the canonical repository for project documentation and the future application code.

The rebuild is a modernization, not a feature-reduction exercise:

- Preserve every existing feature whose behavior is sound.
- Fix defects and architectural weaknesses before or during migration.
- Redesign an implementation only when needed; do not remove the user-facing capability without an explicit decision.
- Extend the product after the migrated foundation is stable.
- Keep the existing Apps Script UI as the primary visual and interaction reference. Make targeted adaptations for authentication, workspaces, responsive behavior, and new capabilities rather than redesigning it from scratch.

## 2. Confirmed decisions

| Area | Decision |
|---|---|
| Repository | `Lannnmmmm/pockito_bot` is the canonical repository for documentation and future code. |
| Database | Supabase PostgreSQL. |
| Authentication | Supabase Auth; the application will have a real login system. |
| Hosting | GitHub Pages is the planned frontend hosting target. |
| Account model | Personal + Shared workspaces. |
| Workspace model | A user has a private Personal workspace and can join or create Shared workspaces. |
| Data ownership | Financial records belong to a workspace, not merely to an individual user. |
| Personal privacy | Personal workspace data must remain private from Shared workspace members. |
| Cross-workspace transfer | Personal-to-Shared and Shared-to-Personal movement is a transfer, not ordinary income or expense. |
| UI direction | Preserve the existing Apps Script UI as the baseline; adjust only where necessary. |
| Migration policy | Migrate all existing features unless a bug, weakness, or product decision requires a corrected implementation. |

## 3. Workspace and membership model

### Personal workspace
- Created automatically when a user account is provisioned.
- Has one active member: its owner.
- Its financial data is private to that user.
- Must not become visible to members or owners of any Shared workspace.

### Shared workspace
- Can contain multiple users.
- Uses workspace membership and role-based permissions.
- Shared financial data is scoped to that workspace.
- Membership removal must not delete the workspace's historical financial records.

### Proposed roles (to be finalized)
- `owner`: full control and ownership.
- `admin`: administrative actions permitted by policy.
- `editor`: create and edit financial records.
- `viewer`: read-only access.

Role permissions must be enforced by PostgreSQL Row Level Security (RLS) and server-side functions, not only by frontend visibility.

## 4. Financial data and accounting principles

1. Store monetary values as integer minor units (for IDR, whole Rupiah using PostgreSQL `BIGINT`); do not use floating-point values for money.
2. A wallet belongs to one workspace.
3. Transactions and their ledger entries must be committed atomically.
4. Ledger entries are the source of truth for wallet movement. A cached or materialized balance may be added for performance, but it must be rebuildable from the ledger.
5. Transfers must have linked, traceable sides and must not inflate income or expense reports.
6. Goal allocations are reserved/earmarked funds, not automatically consumption expenses. A reservation must not reduce net worth by itself.
7. If funds are physically moved between two wallets in the same workspace, represent the movement as a transfer.
8. Payment allocations for installments and debts must preserve partial-payment history and prevent duplicate application.
9. Corrections and reversals should be traceable; avoid silently overwriting financial history.

### Cross-workspace transfer

A transfer between workspaces should be performed by a database transaction/RPC that:
- Verifies the actor is allowed to transact in both source and destination workspaces.
- Creates linked source and destination records with a shared transfer identifier.
- Creates the corresponding ledger movements.
- Commits both sides together or rolls back both sides.
- Does not classify the movement as ordinary expense/income.
- Retains audit information about the initiating user and both workspaces.

A cross-workspace transfer changes each workspace's balance independently. It should not create or destroy money in a combined view of both workspaces.

## 5. Existing feature migration inventory

The following feature inventory comes from the review of the legacy Apps Script project. Each feature is to be audited against its current behavior before implementation is ported.

| Legacy capability | Migration direction |
|---|---|
| Multiple wallets/accounts | Preserve; workspace-scoped. |
| Income and expenses | Preserve; use consistent transaction and ledger rules. |
| Transfers | Preserve; strengthen atomicity and traceability. |
| Budgets | Preserve; verify period and category calculations. |
| Investments | Preserve; distinguish contributions, withdrawals, and valuation changes. |
| Credit cards | Preserve; audit statement, payment, and outstanding-balance logic. |
| Installments | Preserve; support schedules, partial payments, and payment history. |
| Recurring transactions | Preserve; add idempotent execution records. |
| Savings goals | Preserve; correct allocation accounting so reserving funds is not counted as spending. |
| Debts and receivables | Preserve; strengthen payment history and consistency. |
| Notifications/email | Preserve capability; redesign delivery and preferences. |
| PIN lock | Optional secondary application lock, never a replacement for account authentication. |
| Webhook/notification ingestion | Preserve only after token handling, validation, deduplication, and retry behavior are hardened. |
| Reports/analytics | Preserve existing useful reports and verify their accounting definitions. |

Do not assume that a legacy feature is correct merely because it exists. Record its behavior, test it, and classify it as:
- **Keep** — behavior and implementation are sound enough to migrate.
- **Fix then migrate** — capability is valid but implementation has a defect or weakness.
- **Redesign implementation** — same capability, safer or more reliable architecture.
- **Open decision** — product behavior needs confirmation.

## 6. Initial database domain map

This is a logical domain map, not yet a final SQL schema. Column definitions, constraints, indexes, foreign keys, and RLS policies must be specified in versioned migrations.

### Identity and workspaces
- `profiles`
- `workspaces`
- `workspace_members`
- `workspace_invitations`

### Financial core
- `wallets`
- `categories`
- `transactions`
- `transaction_entries`
- `transfer_groups` (or an equivalent explicit linked-transfer model)

### Planning
- `budgets`
- `budget_categories`
- `goals`
- `goal_allocations`

### Assets and liabilities
- `investments`
- `investment_movements` (contributions, withdrawals, and valuations)
- `credit_cards`
- `installment_plans`
- `installments`
- `installment_payments`
- `debts`
- `debt_payments`

### Automation and audit
- `recurring_transactions`
- `recurring_executions`
- `notifications`
- `notification_preferences`
- `webhook_integrations`
- `webhook_events`
- `activity_logs`

### Preferences
- `workspace_settings`
- `user_preferences`

The schema may be normalized differently after the detailed legacy audit. Avoid creating redundant tables solely to mirror old Google Sheets tabs.

## 7. Security baseline

- Use Supabase Auth for identity and session management.
- Enable RLS on every exposed table containing user or financial data.
- Scope access through workspace membership and role.
- Keep Supabase `service_role` credentials and webhook secrets out of frontend code and the public repository.
- A Supabase publishable/anon key may be used in the frontend only with correctly designed RLS and safe database functions.
- Validate authorization inside database functions for sensitive operations.
- Never expose webhook secrets to ordinary browser sessions.
- Store only a hash of invitation tokens and other bearer secrets where practical.
- Use rate limits and safe retry/idempotency controls for authentication-adjacent and webhook operations.
- Treat PIN as optional secondary lock, not authentication.

## 8. Frontend and UI direction

- Keep the old Apps Script `index.html` as the visual and interaction reference.
- Preserve its information architecture, dashboard patterns, forms, navigation, visual character, and useful interaction behavior.
- Separate frontend concerns incrementally (API access, state, rendering, forms, finance calculations, styles) without requiring an unnecessary framework rewrite.
- Add login, registration, workspace switcher, membership management, and role-aware controls.
- Ensure the active workspace is explicit in the UI to reduce accidental entry into the wrong financial space.
- Test desktop and mobile layouts.

## 9. Proposed implementation sequence

1. Complete legacy feature and data-flow audit.
2. Finalize product rules and database schema.
3. Add versioned Supabase SQL migrations, constraints, indexes, and RLS tests. (Initial workspace/ledger migrations committed; SQL still requires execution and policy tests.)
4. Implement Supabase Auth and automatic Personal workspace provisioning.
5. Implement Shared workspace creation, invitations, membership, and roles.
6. Implement wallets, categories, transactions, ledger, and atomic transfers.
7. Migrate budgets and goals.
8. Migrate investments, credit cards, installments, and debts.
9. Migrate recurring transactions, notifications, webhooks, and audit logs.
10. Adapt the preserved UI to the new backend.
11. Build a migration/import process for legacy data and reconcile balances.
12. Run regression, security, concurrency, and accounting tests before release.

## 10. Open product decisions

These are deliberately not treated as confirmed until the product owner decides:

- Exact role permission matrix, including who can delete or reverse financial records.
- Whether Shared workspaces support multiple owners or exactly one owner.
- Whether a transfer can be initiated from a workspace when the actor has different roles in the source and destination workspaces.
- Whether a cross-workspace transfer requires approval by the destination workspace.
- Whether currency conversion/multi-currency is in scope; initial currency is IDR unless later changed.
- Exact notification channels and scheduling mechanism.

## 11. Confirmed workspace rules

- Every active Shared workspace member can read every transaction in that workspace.
- Only the Owner may invite members; Admin cannot invite.
- Invitations are email-only. Email delivery is handled by a trusted server-side function, not PostgreSQL itself.
- Personal workspace data remains private from all other users.
- See [WORKSPACE_RULES.md](WORKSPACE_RULES.md) for implementation details.

## 12. Legacy feature mapping notes

The advanced-feature schema is based on the legacy Apps Script sheet headers and code paths:

- `Anggaran`: monthly category quota and alert threshold; actual spend should be calculated from expense transactions, not stored as a mutable counter.
- `Target`: target amount, deadline, and notes. Deposits become `goal_allocations` with reserve/release semantics, not automatic expense transactions. Actual goal spending links to a real expense transaction.
- `Investasi`: instrument name/type, principal, current value, and description. Contributions/withdrawals link to wallet transactions; valuations are recorded separately from cash movement.
- `Kartu` and `Cicilan`: credit limit, due day, installment plan, schedule rows, principal, fees, and partial payment allocations. The legacy behavior allocates partial payments oldest-due-first and proportionally splits principal/fee.
- `Hutang`: payable/receivable direction, original principal, opened date, due date, and payment history. Outstanding balance is derived from payments.
- `Berulang`: monthly day-of-month schedule. `recurring_executions` has a unique recurring-item/period pair to make processing idempotent.

Migration 0004 creates the planning, asset/liability, and recurring tables. Direct client writes are not granted; write operations still need atomic RPCs and tests.


### Core transaction RPCs (migration 0005)

- `post_financial_transaction` posts only ordinary income/expense. It validates the authenticated actor, workspace role, active wallet, category scope/type, positive BIGINT amount, timestamp, title, and mandatory idempotency key. The transaction and signed ledger entry are written in one database transaction.
- Repeating the same workspace/idempotency key returns the original transaction ID rather than creating a duplicate.
- `reverse_financial_transaction` creates a compensating transaction and opposite ledger entry, then marks the original as reversed. It does not delete or overwrite the financial event. Repeating a reversal request returns the already-created reversal ID.
- For operational income/expense reports, exclude both rows where `reversed_at is not null` and rows where `reverses_transaction_id is not null`. For wallet balances, sum all ledger entries; the compensating entry cancels the original movement.
- These RPCs do not implement wallet transfers, asset movements, installment/debt payments, or goal/investment allocations. Those require dedicated atomic operations and remain future work.
- Migration 0005 is committed but has not been executed against a Supabase project or runtime-tested.


### Same-workspace wallet transfers (migration 0006)

- `post_wallet_transfer` moves a positive amount between two distinct active wallets in the same workspace.
- It checks the caller's workspace edit permission, validates both wallet records, locks wallet rows in stable ID order, and uses a workspace-scoped idempotency key.
- One `transfer_groups` row, one `transfer_out` transaction, one `transfer_in` transaction, and two ledger entries are committed atomically.
- The source ledger entry is negative and the destination ledger entry is positive for the same amount. Their combined effect inside the workspace is zero.
- Transfers must be excluded from income/expense totals and category spending reports. Wallet balances still include their ledger movements.
- Migration 0006 allows `transfer_groups.source_workspace_id` and `destination_workspace_id` to be equal. The same RPC does not support cross-workspace transfers.
- Transfer reversal is not implemented yet. Do not use the income/expense reversal RPC to reverse a transfer; a dedicated paired-transfer reversal operation is required.
- Migration 0006 is committed but has not been executed against Supabase or runtime-tested.


### Installment and debt payments (migration 0007)

- `pay_installment_plan` creates one expense transaction for the cash payment and allocates it across the plan's installments in due-date / installment-number order.
- Partial installment payments are split proportionally between the remaining principal and fee of the current installment. The integer rounding remainder is assigned to the fee; a fully paid installment receives its exact remaining principal and fee.
- The payment cannot exceed the plan's outstanding total. The plan row and installment rows are locked during allocation to serialize concurrent payments.
- `pay_debt` supports partial repayment and collection. A `payable` debt creates an expense; a `receivable` debt creates income. The payment cannot exceed the remaining principal, and the debt becomes `settled` when the final amount is paid.
- Both functions create their transaction, feature-payment record(s), and ledger entry in one database transaction. They require workspace edit permission and an idempotency key.
- Payment amounts are whole Rupiah BIGINT values. Installment fees are included in the cash expense total.
- Important: payment-specific reversal is not implemented. The general income/expense reversal operation must not be used for installment/debt payment transactions until a dedicated reversal routine also restores the related payment allocation and debt/installment status.
- Migration 0007 is committed but has not been executed against Supabase or runtime-tested.


### Payment reversal safety guard (migration 0008)

- The general `reverse_financial_transaction` RPC now rejects transactions whose source is `installment_payment` or `debt_payment`.
- This prevents a cash-ledger reversal from leaving installment allocations or debt balances falsely marked as paid.
- Dedicated feature-aware reversal RPCs are still required before those payment records can be cancelled or reversed safely.
- Migration 0008 is committed but has not been executed against Supabase or runtime-tested.

## 13. Engineering guardrails

- Keep SQL changes in versioned migration files; do not rely on manual dashboard-only schema edits.
- Never rewrite or replace the legacy UI before comparing the result against the reference.
- Do not migrate a financial operation until its expected balance effects and rollback behavior are tested.
- Use idempotency keys for operations that may be retried.
- Use database constraints and transactions for integrity; frontend validation is supplementary.
- Keep sample/test data separate from real personal financial data.
- Document decisions in this repository so future work does not depend on chat history.
- Update this blueprint when a decision is confirmed or the architecture changes.
