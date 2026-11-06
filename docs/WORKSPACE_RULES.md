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
