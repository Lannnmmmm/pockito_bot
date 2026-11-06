-- Pockito / Supabase migration 0003
-- Invitation records are created/changed only by trusted server-side RPCs.

drop policy if exists "owner create invitations" on public.workspace_invitations;
drop policy if exists "owner update invitations" on public.workspace_invitations;

revoke insert,update,delete on public.workspace_invitations from authenticated;
grant select on public.workspace_invitations to authenticated;

-- Owner-only read policy remains. Later RPCs must independently verify:
-- 1) caller is the active Owner of the target workspace;
-- 2) invited email is normalized and role is not owner;
-- 3) invitation token is random, stored only as a cryptographic hash;
-- 4) pending invitation uniqueness and expiry;
-- 5) email delivery occurs via trusted server-side service.
