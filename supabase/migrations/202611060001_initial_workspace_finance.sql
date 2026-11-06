-- Pockito / Supabase migration 0001
-- Identity, workspace tenancy and financial ledger foundation.
create extension if not exists pgcrypto;

create type public.workspace_kind as enum ('personal', 'shared');
create type public.workspace_role as enum ('owner', 'admin', 'editor', 'viewer');
create type public.transaction_kind as enum ('income','expense','transfer_in','transfer_out','asset_in','asset_out','adjustment');
create type public.invitation_status as enum ('pending','accepted','revoked','expired');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  kind public.workspace_kind not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.workspace_role not null default 'viewer',
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  primary key (workspace_id,user_id)
);
create index workspace_members_user_active_idx on public.workspace_members(user_id,workspace_id) where removed_at is null;

create table public.workspace_invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  invited_email text not null check (invited_email = lower(trim(invited_email))),
  invited_role public.workspace_role not null default 'editor' check (invited_role <> 'owner'),
  token_hash text not null unique,
  status public.invitation_status not null default 'pending',
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  accepted_by uuid references auth.users(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index workspace_invitations_pending_email_idx on public.workspace_invitations(workspace_id,invited_email) where status='pending';

create table public.wallets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  wallet_type text not null default 'BANK',
  account_label text,
  opening_balance bigint not null default 0,
  is_active boolean not null default true,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(workspace_id,name),
  unique(workspace_id,id)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  category_type text not null default 'both' check (category_type in ('income','expense','both')),
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  unique(workspace_id,name),
  unique(workspace_id,id)
);

create table public.transfer_groups (
  id uuid primary key default gen_random_uuid(),
  source_workspace_id uuid not null references public.workspaces(id),
  destination_workspace_id uuid not null references public.workspaces(id),
  initiated_by uuid not null references auth.users(id),
  idempotency_key text not null unique,
  amount bigint not null check (amount > 0),
  description text,
  created_at timestamptz not null default now(),
  check(source_workspace_id <> destination_workspace_id)
);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  wallet_id uuid not null,
  category_id uuid,
  kind public.transaction_kind not null,
  amount bigint not null check(amount > 0),
  occurred_at timestamptz not null,
  title text not null check(length(trim(title)) between 1 and 200),
  notes text,
  source text not null default 'manual',
  transfer_group_id uuid references public.transfer_groups(id),
  idempotency_key text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id),
  foreign key(workspace_id,wallet_id) references public.wallets(workspace_id,id),
  foreign key(workspace_id,category_id) references public.categories(workspace_id,id),
  unique(workspace_id,id),
  check((kind in ('transfer_in','transfer_out') and transfer_group_id is not null) or kind not in ('transfer_in','transfer_out'))
);
create unique index transactions_idempotency_idx on public.transactions(workspace_id,idempotency_key) where idempotency_key is not null;
create index transactions_workspace_date_idx on public.transactions(workspace_id,occurred_at desc);
create index transactions_wallet_date_idx on public.transactions(workspace_id,wallet_id,occurred_at desc);
create index transactions_category_date_idx on public.transactions(workspace_id,category_id,occurred_at desc);

-- Positive signed_amount increases wallet cash; negative decreases it.
create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  wallet_id uuid not null,
  transaction_id uuid not null,
  signed_amount bigint not null check(signed_amount <> 0),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,wallet_id) references public.wallets(workspace_id,id),
  foreign key(workspace_id,transaction_id) references public.transactions(workspace_id,id),
  unique(transaction_id)
);
create index ledger_entries_wallet_idx on public.ledger_entries(workspace_id,wallet_id,created_at);

create table public.workspace_settings (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  currency_code char(3) not null default 'IDR',
  timezone text not null default 'Asia/Jakarta',
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create table public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- SECURITY DEFINER helpers avoid recursive RLS membership lookups.
create or replace function public.is_workspace_member(p_workspace_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.workspace_members m where m.workspace_id=p_workspace_id and m.user_id=(select auth.uid()) and m.removed_at is null);
$$;

create or replace function public.workspace_role_for(p_workspace_id uuid)
returns public.workspace_role language sql stable security definer set search_path=''
as $$
 select m.role from public.workspace_members m where m.workspace_id=p_workspace_id and m.user_id=(select auth.uid()) and m.removed_at is null limit 1;
$$;

create or replace function public.can_edit_workspace(p_workspace_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select coalesce(public.workspace_role_for(p_workspace_id) in ('owner','admin','editor'),false);
$$;

create or replace function public.is_workspace_owner(p_workspace_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select coalesce(public.workspace_role_for(p_workspace_id)='owner',false);
$$;

alter table public.profiles enable row level security;
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_invitations enable row level security;
alter table public.wallets enable row level security;
alter table public.categories enable row level security;
alter table public.transfer_groups enable row level security;
alter table public.transactions enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.workspace_settings enable row level security;
alter table public.user_preferences enable row level security;

create policy "profile self read" on public.profiles for select to authenticated using(id=(select auth.uid()));
create policy "profile self update" on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));

create policy "members read workspace" on public.workspaces for select to authenticated using(public.is_workspace_member(id));
create policy "users create workspace" on public.workspaces for insert to authenticated with check(created_by=(select auth.uid()));
create policy "owner update workspace" on public.workspaces for update to authenticated using(public.is_workspace_owner(id)) with check(public.is_workspace_owner(id));

create policy "members read membership" on public.workspace_members for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "owner manage membership" on public.workspace_members for all to authenticated using(public.is_workspace_owner(workspace_id)) with check(public.is_workspace_owner(workspace_id));

-- Owner-only invitation policies. Email delivery and token generation happen server-side.
create policy "owner read invitations" on public.workspace_invitations for select to authenticated using(public.is_workspace_owner(workspace_id));
create policy "owner create invitations" on public.workspace_invitations for insert to authenticated with check(public.is_workspace_owner(workspace_id) and invited_by=(select auth.uid()));
create policy "owner update invitations" on public.workspace_invitations for update to authenticated using(public.is_workspace_owner(workspace_id)) with check(public.is_workspace_owner(workspace_id));

create policy "members read wallets" on public.wallets for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage wallets" on public.wallets for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read categories" on public.categories for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage categories" on public.categories for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

-- Confirmed rule: all active members see all transactions in their Shared workspace.
create policy "members read transactions" on public.transactions for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "members read ledger" on public.ledger_entries for select to authenticated using(public.is_workspace_member(workspace_id));

create policy "members read transfer groups" on public.transfer_groups for select to authenticated using(public.is_workspace_member(source_workspace_id) and public.is_workspace_member(destination_workspace_id));

create policy "members read workspace settings" on public.workspace_settings for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "owner admin manage settings" on public.workspace_settings for all to authenticated using(public.workspace_role_for(workspace_id) in ('owner','admin')) with check(public.workspace_role_for(workspace_id) in ('owner','admin'));
create policy "user manages preferences" on public.user_preferences for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_workspace_id uuid; v_display_name text;
begin
 v_display_name:=coalesce(nullif(new.raw_user_meta_data->>'display_name',''),nullif(new.raw_user_meta_data->>'full_name',''),split_part(coalesce(new.email,'user'),'@',1));
 insert into public.profiles(id,display_name) values(new.id,v_display_name) on conflict(id) do nothing;
 insert into public.workspaces(name,kind,created_by) values(left(v_display_name,70)||' - Personal','personal',new.id) returning id into v_workspace_id;
 insert into public.workspace_members(workspace_id,user_id,role) values(v_workspace_id,new.id,'owner');
 insert into public.workspace_settings(workspace_id) values(v_workspace_id);
 return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

grant usage on schema public to authenticated;
grant select,insert,update on public.profiles to authenticated;
grant select,insert,update on public.workspaces to authenticated;
grant select,insert,update,delete on public.workspace_members to authenticated;
grant select,insert,update on public.workspace_invitations to authenticated;
grant select,insert,update,delete on public.wallets,public.categories to authenticated;
grant select on public.transactions,public.ledger_entries,public.transfer_groups to authenticated;
-- Financial writes are intentionally reserved for validated SECURITY DEFINER RPCs.
-- Do not grant direct client INSERT/UPDATE/DELETE on transactions, ledger_entries or transfer_groups.
grant select,insert,update,delete on public.workspace_settings,public.user_preferences to authenticated;
grant execute on function public.is_workspace_member(uuid),public.workspace_role_for(uuid),public.can_edit_workspace(uuid),public.is_workspace_owner(uuid) to authenticated;
