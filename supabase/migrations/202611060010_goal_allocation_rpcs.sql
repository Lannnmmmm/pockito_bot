-- Pockito / Supabase migration 0010
-- Goal allocations are earmarks. Reserve/release do not affect the cash ledger.
-- Spending from a goal creates a real expense and allocation atomically.

alter table public.goal_allocations
  add column idempotency_key text;

create unique index goal_allocations_idempotency_idx
  on public.goal_allocations(workspace_id, idempotency_key)
  where idempotency_key is not null;

create or replace function public.allocate_goal_funds(
  p_workspace_id uuid,
  p_goal_id uuid,
  p_wallet_id uuid,
  p_amount bigint,
  p_occurred_at timestamptz,
  p_kind public.goal_allocation_kind,
  p_notes text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_goal public.goals%rowtype;
  v_existing_id uuid;
  v_existing_kind public.goal_allocation_kind;
  v_existing_goal_id uuid;
  v_existing_wallet_id uuid;
  v_existing_amount bigint;
  v_wallet_id uuid;
  v_wallet_reserved bigint;
  v_allocation_id uuid;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_kind not in ('reserve'::public.goal_allocation_kind, 'release'::public.goal_allocation_kind) then
    raise exception 'Use spend_goal_funds to record actual spending';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;
  if p_occurred_at is null then
    raise exception 'Allocation date is required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 100 then
    raise exception 'A valid idempotency key is required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':goal:' || p_idempotency_key, 0));

  select ga.id, ga.kind, ga.goal_id, ga.wallet_id, ga.amount
    into v_existing_id, v_existing_kind, v_existing_goal_id, v_existing_wallet_id, v_existing_amount
  from public.goal_allocations ga
  where ga.workspace_id = p_workspace_id
    and ga.idempotency_key = p_idempotency_key;
  if v_existing_id is not null then
    if v_existing_kind <> p_kind or v_existing_goal_id <> p_goal_id
       or v_existing_wallet_id <> p_wallet_id or v_existing_amount <> p_amount then
      raise exception 'Idempotency key was already used with different allocation data';
    end if;
    return v_existing_id;
  end if;

  select g.* into v_goal
  from public.goals g
  where g.id = p_goal_id and g.workspace_id = p_workspace_id
  for update;
  if not found then
    raise exception 'Goal not found in this workspace';
  end if;
  if v_goal.status <> 'active' then
    raise exception 'Only active goals can receive or release allocations';
  end if;

  select w.id into v_wallet_id
  from public.wallets w
  where w.id = p_wallet_id
    and w.workspace_id = p_workspace_id
    and w.is_active = true
  for update;
  if v_wallet_id is null then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  if p_kind = 'release' then
    select coalesce(sum(case when ga.kind = 'reserve' then ga.amount else -ga.amount end), 0)
      into v_wallet_reserved
    from public.goal_allocations ga
    where ga.workspace_id = p_workspace_id
      and ga.goal_id = p_goal_id
      and ga.wallet_id = p_wallet_id;

    if p_amount > v_wallet_reserved then
      raise exception 'Release amount exceeds reserved amount in this wallet';
    end if;
  end if;

  insert into public.goal_allocations (
    workspace_id, goal_id, wallet_id, kind, amount, occurred_at,
    notes, created_by, idempotency_key
  ) values (
    p_workspace_id, p_goal_id, p_wallet_id, p_kind, p_amount, p_occurred_at,
    nullif(trim(coalesce(p_notes, '')), ''), v_actor, p_idempotency_key
  ) returning id into v_allocation_id;

  return v_allocation_id;
end;
$$;

create or replace function public.spend_goal_funds(
  p_workspace_id uuid,
  p_goal_id uuid,
  p_wallet_id uuid,
  p_amount bigint,
  p_occurred_at timestamptz,
  p_title text default null,
  p_category_id uuid default null,
  p_notes text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_goal public.goals%rowtype;
  v_existing_id uuid;
  v_existing_transaction_id uuid;
  v_existing_goal_id uuid;
  v_existing_wallet_id uuid;
  v_existing_amount bigint;
  v_existing_kind public.goal_allocation_kind;
  v_wallet_id uuid;
  v_wallet_reserved bigint;
  v_category_type text;
  v_transaction_id uuid;
  v_allocation_id uuid;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;
  if p_occurred_at is null then
    raise exception 'Expense date is required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 100 then
    raise exception 'A valid idempotency key is required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':goal:' || p_idempotency_key, 0));

  select ga.id, ga.transaction_id, ga.goal_id, ga.wallet_id, ga.amount, ga.kind
    into v_existing_id, v_existing_transaction_id, v_existing_goal_id, v_existing_wallet_id, v_existing_amount, v_existing_kind
  from public.goal_allocations ga
  where ga.workspace_id = p_workspace_id
    and ga.idempotency_key = p_idempotency_key;
  if v_existing_id is not null then
    if v_existing_kind <> 'spend'::public.goal_allocation_kind
       or v_existing_goal_id <> p_goal_id or v_existing_wallet_id <> p_wallet_id
       or v_existing_amount <> p_amount or v_existing_transaction_id is null then
      raise exception 'Idempotency key was already used with different goal spending data';
    end if;
    return v_existing_transaction_id;
  end if;

  select g.* into v_goal
  from public.goals g
  where g.id = p_goal_id and g.workspace_id = p_workspace_id
  for update;
  if not found then
    raise exception 'Goal not found in this workspace';
  end if;
  if v_goal.status <> 'active' then
    raise exception 'Only active goals can be spent';
  end if;

  select w.id into v_wallet_id
  from public.wallets w
  where w.id = p_wallet_id
    and w.workspace_id = p_workspace_id
    and w.is_active = true
  for update;
  if v_wallet_id is null then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  select coalesce(sum(case when ga.kind = 'reserve' then ga.amount else -ga.amount end), 0)
    into v_wallet_reserved
  from public.goal_allocations ga
  where ga.workspace_id = p_workspace_id
    and ga.goal_id = p_goal_id
    and ga.wallet_id = p_wallet_id;

  if p_amount > v_wallet_reserved then
    raise exception 'Spend amount exceeds reserved amount in this wallet';
  end if;

  if p_category_id is not null then
    select c.category_type into v_category_type
    from public.categories c
    where c.id = p_category_id and c.workspace_id = p_workspace_id;
    if not found then
      raise exception 'Category not found in this workspace';
    end if;
    if v_category_type not in ('both', 'expense') then
      raise exception 'Category type must support expense';
    end if;
  end if;

  insert into public.transactions (
    workspace_id, wallet_id, category_id, kind, amount, occurred_at,
    title, notes, source, idempotency_key, created_by
  ) values (
    p_workspace_id, p_wallet_id, p_category_id, 'expense'::public.transaction_kind,
    p_amount, p_occurred_at,
    left(coalesce(nullif(trim(p_title), ''), 'Pengeluaran: ' || v_goal.name), 200),
    nullif(trim(coalesce(p_notes, '')), ''),
    'goal_spend', 'goal-spend:' || p_idempotency_key, v_actor
  ) returning id into v_transaction_id;

  insert into public.ledger_entries (
    workspace_id, wallet_id, transaction_id, signed_amount
  ) values (
    p_workspace_id, p_wallet_id, v_transaction_id, -p_amount
  );

  insert into public.goal_allocations (
    workspace_id, goal_id, wallet_id, transaction_id, kind, amount,
    occurred_at, notes, created_by, idempotency_key
  ) values (
    p_workspace_id, p_goal_id, p_wallet_id, v_transaction_id, 'spend'::public.goal_allocation_kind,
    p_amount, p_occurred_at, nullif(trim(coalesce(p_notes, '')), ''),
    v_actor, p_idempotency_key
  ) returning id into v_allocation_id;

  return v_transaction_id;
end;
$$;

revoke all on function public.allocate_goal_funds(uuid,uuid,uuid,bigint,timestamptz,public.goal_allocation_kind,text,text) from public, anon;
revoke all on function public.spend_goal_funds(uuid,uuid,uuid,bigint,timestamptz,text,uuid,text,text) from public, anon;

grant execute on function public.allocate_goal_funds(uuid,uuid,uuid,bigint,timestamptz,public.goal_allocation_kind,text,text) to authenticated;
grant execute on function public.spend_goal_funds(uuid,uuid,uuid,bigint,timestamptz,text,uuid,text,text) to authenticated;

comment on function public.allocate_goal_funds(uuid,uuid,uuid,bigint,timestamptz,public.goal_allocation_kind,text,text)
is 'Reserves or releases earmarked funds for a goal without changing wallet ledger balance.';
comment on function public.spend_goal_funds(uuid,uuid,uuid,bigint,timestamptz,text,uuid,text,text)
is 'Atomically records actual goal spending as an expense, ledger entry, and goal allocation.';
