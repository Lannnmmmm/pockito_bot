-- Pockito / Supabase migration 0015
-- Secure goal CRUD and correct reserved-fund accounting.
-- A goal reserve is an earmark, not a wallet ledger movement.

create or replace function public.create_goal(
  p_workspace_id uuid,
  p_name text,
  p_target_amount bigint,
  p_deadline date default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_goal_id uuid;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 120 then
    raise exception 'Goal name must contain 1 to 120 characters';
  end if;
  if p_target_amount is null or p_target_amount <= 0 then
    raise exception 'Target amount must be greater than zero';
  end if;

  insert into public.goals (
    workspace_id, name, target_amount, deadline, notes, created_by
  ) values (
    p_workspace_id, trim(p_name), p_target_amount, p_deadline,
    nullif(trim(coalesce(p_notes, '')), ''), v_actor
  ) returning id into v_goal_id;

  return v_goal_id;
end;
$$;

create or replace function public.update_goal(
  p_workspace_id uuid,
  p_goal_id uuid,
  p_name text,
  p_target_amount bigint,
  p_deadline date default null,
  p_notes text default null,
  p_status text default 'active'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_goal public.goals%rowtype;
  v_reserved bigint;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 120 then
    raise exception 'Goal name must contain 1 to 120 characters';
  end if;
  if p_target_amount is null or p_target_amount <= 0 then
    raise exception 'Target amount must be greater than zero';
  end if;
  if p_status not in ('active','completed','paused','cancelled') then
    raise exception 'Invalid goal status';
  end if;

  select g.* into v_goal
  from public.goals g
  where g.id = p_goal_id and g.workspace_id = p_workspace_id
  for update;
  if not found then
    raise exception 'Goal not found in this workspace';
  end if;

  select coalesce(sum(case
    when ga.kind = 'reserve' then ga.amount
    else -ga.amount
  end), 0)
  into v_reserved
  from public.goal_allocations ga
  where ga.workspace_id = p_workspace_id and ga.goal_id = p_goal_id;

  if p_status = 'completed' and v_reserved < p_target_amount then
    raise exception 'A goal can be completed only after its target amount is fully reserved';
  end if;

  update public.goals
  set name = trim(p_name),
      target_amount = p_target_amount,
      deadline = p_deadline,
      notes = nullif(trim(coalesce(p_notes, '')), ''),
      status = p_status,
      updated_at = now()
  where id = p_goal_id and workspace_id = p_workspace_id;

  return p_goal_id;
end;
$$;

-- Replace allocation RPC: spending now reduces the reserved balance.
-- New reservations cannot exceed unreserved cash in the selected wallet.
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
  v_wallet_balance bigint;
  v_goal_reserved bigint;
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

  perform 1
  from public.wallets w
  where w.id = p_wallet_id
    and w.workspace_id = p_workspace_id
    and w.is_active = true
  for update;
  if not found then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  select w.opening_balance + coalesce(sum(le.signed_amount), 0)
    into v_wallet_balance
  from public.wallets w
  left join public.ledger_entries le
    on le.wallet_id = w.id and le.workspace_id = p_workspace_id
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id
  group by w.id, w.opening_balance;

  select coalesce(sum(case when ga.kind = 'reserve' then ga.amount else -ga.amount end), 0)
    into v_goal_reserved
  from public.goal_allocations ga
  where ga.workspace_id = p_workspace_id
    and ga.goal_id = p_goal_id
    and ga.wallet_id = p_wallet_id;

  if p_kind = 'release' and p_amount > v_goal_reserved then
    raise exception 'Release amount exceeds reserved amount in this wallet';
  end if;

  if p_kind = 'reserve' then
    select coalesce(sum(case when ga.kind = 'reserve' then ga.amount else -ga.amount end), 0)
      into v_wallet_reserved
    from public.goal_allocations ga
    where ga.workspace_id = p_workspace_id and ga.wallet_id = p_wallet_id;

    if p_amount > greatest(v_wallet_balance - v_wallet_reserved, 0) then
      raise exception 'Reservation exceeds unallocated wallet balance';
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

-- Replace spend RPC: spending reduces the goal reserve and cannot overdraw the wallet.
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
  v_wallet_balance bigint;
  v_wallet_id uuid;
  v_wallet_reserved bigint;
  v_goal_reserved bigint;
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

  perform 1
  from public.wallets w
  where w.id = p_wallet_id
    and w.workspace_id = p_workspace_id
    and w.is_active = true
  for update;
  if not found then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  select w.id, w.opening_balance + coalesce(sum(le.signed_amount), 0)
    into v_wallet_id, v_wallet_balance
  from public.wallets w
  left join public.ledger_entries le
    on le.wallet_id = w.id and le.workspace_id = p_workspace_id
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id
  group by w.id, w.opening_balance;
  if p_amount > v_wallet_balance then
    raise exception 'Wallet balance is insufficient for this goal spending';
  end if;

  select coalesce(sum(case when ga.kind = 'reserve' then ga.amount else -ga.amount end), 0)
    into v_goal_reserved
  from public.goal_allocations ga
  where ga.workspace_id = p_workspace_id
    and ga.goal_id = p_goal_id
    and ga.wallet_id = p_wallet_id;
  if p_amount > v_goal_reserved then
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

revoke all on function public.create_goal(uuid,text,bigint,date,text) from public, anon;
revoke all on function public.update_goal(uuid,uuid,text,bigint,date,text,text) from public, anon;
revoke all on function public.allocate_goal_funds(uuid,uuid,uuid,bigint,timestamptz,public.goal_allocation_kind,text,text) from public, anon;
revoke all on function public.spend_goal_funds(uuid,uuid,uuid,bigint,timestamptz,text,uuid,text,text) from public, anon;

grant execute on function public.create_goal(uuid,text,bigint,date,text) to authenticated;
grant execute on function public.update_goal(uuid,uuid,text,bigint,date,text,text) to authenticated;
grant execute on function public.allocate_goal_funds(uuid,uuid,uuid,bigint,timestamptz,public.goal_allocation_kind,text,text) to authenticated;
grant execute on function public.spend_goal_funds(uuid,uuid,uuid,bigint,timestamptz,text,uuid,text,text) to authenticated;

comment on function public.create_goal(uuid,text,bigint,date,text)
is 'Creates a workspace-scoped financial goal after checking edit permission.';
comment on function public.update_goal(uuid,uuid,text,bigint,date,text,text)
is 'Updates goal details and lifecycle status; completion requires the target to be fully reserved.';
comment on function public.allocate_goal_funds(uuid,uuid,uuid,bigint,timestamptz,public.goal_allocation_kind,text,text)
is 'Reserves or releases earmarked funds without changing wallet ledger balance; reservations cannot exceed unallocated cash.';
comment on function public.spend_goal_funds(uuid,uuid,uuid,bigint,timestamptz,text,uuid,text,text)
is 'Atomically records goal spending as an expense and reduces reserved goal funds.';
