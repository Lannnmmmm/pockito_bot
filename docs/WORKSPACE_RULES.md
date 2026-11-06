# Confirmed workspace rules

Updated: 2026-11-06

| Rule | Confirmed behavior |
|---|---|
| Shared transaction visibility | Every active member of a Shared workspace can read every transaction in that workspace. |
| Invitation authority | Only the workspace Owner can invite members. Admin cannot invite. |
| Invitation channel | Email only. A trusted server-side Edge Function/service sends invitation email. |
| Personal privacy | Personal workspace data is inaccessible to other users, including members of the same Shared workspace. |

## Implementation notes

- Financial table read policies are based on active workspace membership.
- Invitation read/create/update policies are Owner-only.
- Generate invitation bearer tokens server-side and store only a token hash.
- Invitation acceptance must validate authenticated email, invitation status, and expiry before membership is created.
- Do not send email from a PostgreSQL trigger; use a trusted server-side function.
- Roles remain owner/admin/editor/viewer. The exact permission matrix is not yet fully confirmed. Migration 0001 uses a provisional baseline: Owner/Admin/Editor may edit financial records; Viewer is read-only. Confirm this before production.
- Cross-workspace transfer authorization/approval rules remain open and will be implemented in a later RPC migration.

## Current SQL safety boundary

- Direct browser writes to transactions, ledger entries, transfer groups, and workspace invitations are disabled in the initial migrations.
- Financial writes must be exposed through validated atomic database RPCs. Invitation creation/acceptance must also use trusted RPC/server-side flows.
- The first migrations are a schema foundation, not a deploy-ready application backend. Do not connect the frontend until RPCs, RLS tests, and migration execution are complete.

## Goal allocation rules

- Goal reserve/release operations are earmarks, not income or expenses; they do not create ledger entries or change wallet cash balance.
- Every reserve is attributed to a wallet. Release and actual spending cannot exceed the reserved amount attributed to that same wallet.
- Actual goal spending creates an expense transaction, a negative ledger entry, and a linked `spend` allocation in one atomic RPC.
- Goal spending cannot use the generic transaction reversal path. A dedicated feature-aware reversal is required so the allocation and cash ledger remain consistent.
- Migration 0010 adds `allocate_goal_funds` and `spend_goal_funds`; migration 0011 blocks generic reversal of `goal_spend` transactions.
- Legacy behavior treated every goal deposit as an expense immediately. The new model deliberately corrects this: reserving money is not spending it. Only actual consumption is an expense.

## Investment accounting rules

- `investments.principal_amount` tracks remaining contributed principal; `current_value` tracks the latest estimated market value.
- Creating or editing an investment changes metadata only. Principal and current value are changed through investment movement RPCs.
- A contribution creates an expense transaction and negative wallet ledger entry, then increases principal and current value in the same database transaction.
- A withdrawal creates an `asset_in` transaction and positive wallet ledger entry. It reduces current value by the cash withdrawn and reduces principal proportionally to the withdrawn share of current value (all remaining principal is removed when the full current value is withdrawn).
- A valuation records the new market value and date in `investment_movements`. It does not create a cash transaction, ledger entry, income, or expense. Zero valuation is allowed.
- Investment contribution/withdrawal/valuation movements use idempotency keys. Repeating the same request returns the original result; reusing a key with different details is rejected for cash movements.
- Generic transaction reversal is blocked for investment contributions. Withdrawals use the `asset_in` transaction kind and are not eligible for the generic income/expense reversal path. A dedicated investment reversal flow is required before supporting reversal from the UI.
- Investment metadata and movement writes are exposed through SECURITY DEFINER RPCs; clients retain read-only table access.
- Migration 0012 adds `save_investment`, `record_investment_contribution`, `record_investment_withdrawal`, `record_investment_valuation`, and `close_investment`.
