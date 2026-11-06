# Pockito

**Pockito — Personal Finance Tracker**

Pockito is being rebuilt from its original Google Apps Script implementation into a more secure, maintainable personal finance application.

## Project direction

- Preserve sound legacy features and improve weak or defective implementations.
- Keep the existing Apps Script UI as the primary visual reference.
- Use **Supabase PostgreSQL** for the database and **Supabase Auth** for login.
- Support both **Personal** and **Shared** financial workspaces.
- Use workspace-scoped data, PostgreSQL Row Level Security, and atomic financial operations.
- Host the frontend on **GitHub Pages** (planned).

## Project documentation

See [docs/PROJECT_BLUEPRINT.md](docs/PROJECT_BLUEPRINT.md) for confirmed decisions, the legacy feature migration inventory, the initial database domain map, security principles, implementation sequence, and open product decisions.

## Development status

The project is currently in the architecture and legacy-audit stage. The database schema and application code have not yet been finalized.

## Important

Never commit Supabase `service_role` keys, database passwords, webhook secrets, or other private credentials to this public repository.
