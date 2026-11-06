-- Pockito / Supabase migration 0012
-- Investment metadata, cash movements and market valuation.
-- Principal tracks net contributed capital; current_value tracks latest market value.

alter table public.investment_movements
  add column idempotency_key text;

alter table public.investment_movements
  drop constraint investment_movements_amount_check;

alter table public.investment_movements
  add constraint investment_movements_amount_check
  check (
    (kind = 'valuation'::public.investment_movement_kind and amount >= 0)
    or (kind <> 'valuation'::public.investment_movement_kind and amount > 0)
  );

create unique index investment_movements_idempotency_idx
  on public.investment_movements(workspace_id, idempotency_key)
  where idempotency_key is not null;

create or replace function public.save_investment(
  p_workspace_id uuid,
  p_investment_id uuid default null,
  p_name text default null,
  p_instrument_type text default 'other',
  p_description text default null,
  p_opened_on date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 120 then
    raise exception 'Investment name must contain 1 to 120 characters';
  end if;
  if p_instrument_type is null or length(trim(p_instrument_type)) not between 1 and 60 then
    raise exception 'Instrument type must contain 1 to 60 characters';
  end if;

  if p_investment_id is null then
    insert into public.investments (
      workspace_id, name, instrument_type, description, opened_on, created_by
    ) values (
      p_workspace_id, trim(p_name), trim(p_instrument_type),
      nullif(trim(coalesce(p_description, '')), ''), p_opened_on, v_actor
    ) returning id into v_id;
  else
    update public.investments
    set name = trim(p_name),
        instrument_type = trim(p_instrument_type),
        description = nullif(trim(coalesce(p_description, '')), ''),
        opened_on = p_opened_on,
        updated_at = now()
    where id = p_investment_id
      and workspace_id = p_workspace_id
      and status = 'active'
    returning id into v_id;

    if v_id is null then
      raise exception 'Active investment not found in this workspace';
    end if;
  end if;

  return v_id;
end;
$$;

create or replace function public.record_investment_contribution(
  p_workspace_id uuid,
  p_investment_id uuid,
  p_wallet_id uuid,
  p_amount bigint,
  p_occurred_at timestamptz,
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
  v_investment public.investments%rowtype;
  v_wallet_id uuid;
  v_existing public.investment_movements%rowtype;
  v_existing_tx public.transactions%rowtype;
  v_tx_id uuid;
  v_movement_id uuid;
  v_key text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_occurred_at is null then
    raise exception 'Contribution amount and date are required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 100 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_key := 'investment:contribution:' || trim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || v_key, 0));

  select im.* into v_existing
  from public.investment_movements im
  where im.workspace_id = p_workspace_id and im.idempotency_key = v_key;
  if found then
    if v_existing.kind <> 'contribution'::public.investment_movement_kind
       or v_existing.investment_id <> p_investment_id
       or v_existing.amount <> p_amount
       or v_existing.transaction_id is null then
      raise exception 'Idempotency key was already used with different investment data';
    end if;
    select t.* into v_existing_tx
    from public.transactions t
    where t.id = v_existing.transaction_id and t.workspace_id = p_workspace_id;
    if not found or v_existing_tx.wallet_id <> p_wallet_id
       or v_existing_tx.occurred_at <> p_occurred_at
       or coalesce(v_existing_tx.notes, '') <> coalesce(nullif(trim(coalesce(p_notes, '')), ''), '') then
      raise exception 'Idempotency key was already used with different contribution details';
    end if;
    return v_existing.transaction_id;
  end if;

  select i.* into v_investment
  from public.investments i
  where i.id = p_investment_id and i.workspace_id = p_workspace_id
  for update;
  if not found or v_investment.status <> 'active' then
    raise exception 'Active investment not found in this workspace';
  end if;

  select w.id into v_wallet_id
  from public.wallets w
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id and w.is_active = true
  for update;
  if v_wallet_id is null then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  insert into public.transactions (
    workspace_id, wallet_id, kind, amount, occurred_at, title, notes,
    source, idempotency_key, created_by
  ) values (
    p_workspace_id, p_wallet_id, 'expense'::public.transaction_kind, p_amount,
    p_occurred_at, left('Setor investasi: ' || v_investment.name, 200),
    nullif(trim(coalesce(p_notes, '')), ''), 'investment_contribution', v_key, v_actor
  ) returning id into v_tx_id;

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,p_wallet_id,v_tx_id,-p_amount);

  insert into public.investment_movements (
    workspace_id, investment_id, kind, amount, transaction_id,
    notes, created_by, idempotency_key
  ) values (
    p_workspace_id, p_investment_id, 'contribution'::public.investment_movement_kind,
    p_amount, v_tx_id, nullif(trim(coalesce(p_notes, '')), ''), v_actor, v_key
  ) returning id into v_movement_id;

  update public.investments
  set principal_amount = principal_amount + p_amount,
      current_value = current_value + p_amount,
      updated_at = now()
  where id = p_investment_id and workspace_id = p_workspace_id;

  return v_tx_id;
end;
$$;

create or replace function public.record_investment_withdrawal(
  p_workspace_id uuid,
  p_investment_id uuid,
  p_wallet_id uuid,
  p_amount bigint,
  p_occurred_at timestamptz,
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
  v_investment public.investments%rowtype;
  v_wallet_id uuid;
  v_existing public.investment_movements%rowtype;
  v_existing_tx public.transactions%rowtype;
  v_tx_id uuid;
  v_movement_id uuid;
  v_principal_reduction bigint;
  v_key text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_occurred_at is null then
    raise exception 'Withdrawal amount and date are required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 100 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_key := 'investment:withdrawal:' || trim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || v_key, 0));

  select im.* into v_existing
  from public.investment_movements im
  where im.workspace_id = p_workspace_id and im.idempotency_key = v_key;
  if found then
    if v_existing.kind <> 'withdrawal'::public.investment_movement_kind
       or v_existing.investment_id <> p_investment_id
       or v_existing.amount <> p_amount
       or v_existing.transaction_id is null then
      raise exception 'Idempotency key was already used with different investment data';
    end if;
    select t.* into v_existing_tx
    from public.transactions t
    where t.id = v_existing.transaction_id and t.workspace_id = p_workspace_id;
    if not found or v_existing_tx.wallet_id <> p_wallet_id
       or v_existing_tx.occurred_at <> p_occurred_at
       or coalesce(v_existing_tx.notes, '') <> coalesce(nullif(trim(coalesce(p_notes, '')), ''), '') then
      raise exception 'Idempotency key was already used with different withdrawal details';
    end if;
    return v_existing.transaction_id;
  end if;

  select i.* into v_investment
  from public.investments i
  where i.id = p_investment_id and i.workspace_id = p_workspace_id
  for update;
  if not found or v_investment.status <> 'active' then
    raise exception 'Active investment not found in this workspace';
  end if;
  if p_amount > v_investment.current_value then
    raise exception 'Withdrawal exceeds current investment value';
  end if;

  select w.id into v_wallet_id
  from public.wallets w
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id and w.is_active = true
  for update;
  if v_wallet_id is null then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  if p_amount = v_investment.current_value then
    v_principal_reduction := v_investment.principal_amount;
  elsif v_investment.current_value > 0 then
    v_principal_reduction := least(
      v_investment.principal_amount,
      round(v_investment.principal_amount::numeric * p_amount::numeric / v_investment.current_value::numeric)::bigint
    );
  else
    v_principal_reduction := 0;
  end if;

  insert into public.transactions (
    workspace_id, wallet_id, kind, amount, occurred_at, title, notes,
    source, idempotency_key, created_by
  ) values (
    p_workspace_id, p_wallet_id, 'asset_in'::public.transaction_kind, p_amount,
    p_occurred_at, left('Pencairan investasi: ' || v_investment.name, 200),
    nullif(trim(coalesce(p_notes, '')), ''), 'investment_withdrawal', v_key, v_actor
  ) returning id into v_tx_id;

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,p_wallet_id,v_tx_id,p_amount);

  insert into public.investment_movements (
    workspace_id, investment_id, kind, amount, transaction_id,
    notes, created_by, idempotency_key
  ) values (
    p_workspace_id, p_investment_id, 'withdrawal'::public.investment_movement_kind,
    p_amount, v_tx_id, nullif(trim(coalesce(p_notes, '')), ''), v_actor, v_key
  ) returning id into v_movement_id;

  update public.investments
  set principal_amount = greatest(0, principal_amount - v_principal_reduction),
      current_value = current_value - p_amount,
      updated_at = now()
  where id = p_investment_id and workspace_id = p_workspace_id;

  return v_tx_id;
end;
$$;

create or replace function public.record_investment_valuation(
  p_workspace_id uuid,
  p_investment_id uuid,
  p_current_value bigint,
  p_valuation_date date,
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
  v_investment public.investments%rowtype;
  v_existing public.investment_movements%rowtype;
  v_movement_id uuid;
  v_key text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_current_value is null or p_current_value < 0 or p_valuation_date is null then
    raise exception 'A non-negative valuation and valuation date are required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 100 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_key := 'investment:valuation:' || trim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || v_key, 0));

  select im.* into v_existing
  from public.investment_movements im
  where im.workspace_id = p_workspace_id and im.idempotency_key = v_key;
  if found then
    if v_existing.kind <> 'valuation'::public.investment_movement_kind
       or v_existing.investment_id <> p_investment_id
       or v_existing.amount <> p_current_value
       or v_existing.valuation_date <> p_valuation_date then
      raise exception 'Idempotency key was already used with different valuation data';
    end if;
    return v_existing.id;
  end if;

  select i.* into v_investment
  from public.investments i
  where i.id = p_investment_id and i.workspace_id = p_workspace_id
  for update;
  if not found or v_investment.status <> 'active' then
    raise exception 'Active investment not found in this workspace';
  end if;

  insert into public.investment_movements (
    workspace_id, investment_id, kind, amount, valuation_date,
    notes, created_by, idempotency_key
  ) values (
    p_workspace_id, p_investment_id, 'valuation'::public.investment_movement_kind,
    p_current_value, p_valuation_date, nullif(trim(coalesce(p_notes, '')), ''),
    v_actor, v_key
  ) returning id into v_movement_id;

  update public.investments
  set current_value = p_current_value, updated_at = now()
  where id = p_investment_id and workspace_id = p_workspace_id;

  return v_movement_id;
end;
$$;

create or replace function public.close_investment(
  p_workspace_id uuid,
  p_investment_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_investment public.investments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;

  select i.* into v_investment
  from public.investments i
  where i.id = p_investment_id and i.workspace_id = p_workspace_id
  for update;
  if not found then
    raise exception 'Investment not found in this workspace';
  end if;
  if v_investment.current_value <> 0 or v_investment.principal_amount <> 0 then
    raise exception 'Investment can only be closed after all value and principal are withdrawn';
  end if;

  update public.investments
  set status = 'closed', updated_at = now()
  where id = p_investment_id and workspace_id = p_workspace_id;
end;
$$;

-- A contribution is an expense in cash, but its investment principal must also be
-- restored if reversed. Block generic reversal until a dedicated reversal exists.
create or replace function public.reverse_financial_transaction(
  p_workspace_id uuid,
  p_transaction_id uuid,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_original public.transactions%rowtype;
  v_existing_reversal uuid;
  v_reversal_id uuid;
  v_original_signed bigint;
  v_reversal_kind public.transaction_kind;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;

  select t.* into v_original
  from public.transactions t
  where t.id = p_transaction_id and t.workspace_id = p_workspace_id
  for update;
  if not found then
    raise exception 'Transaction not found in this workspace';
  end if;
  if v_original.kind not in ('income'::public.transaction_kind, 'expense'::public.transaction_kind) then
    raise exception 'Only ordinary income/expense transactions can be reversed here';
  end if;
  if v_original.source in ('installment_payment','debt_payment','goal_spend','investment_contribution') then
    raise exception 'This transaction source requires a feature-aware reversal operation';
  end if;
  if v_original.reverses_transaction_id is not null then
    raise exception 'A reversal transaction cannot itself be reversed';
  end if;

  select t.id into v_existing_reversal
  from public.transactions t
  where t.workspace_id = p_workspace_id and t.reverses_transaction_id = p_transaction_id;
  if v_existing_reversal is not null then
    return v_existing_reversal;
  end if;
  if v_original.reversed_at is not null then
    raise exception 'Transaction is already marked as reversed';
  end if;

  select le.signed_amount into v_original_signed
  from public.ledger_entries le
  where le.workspace_id = p_workspace_id and le.transaction_id = p_transaction_id;
  if v_original_signed is null then
    raise exception 'Original ledger entry is missing; reversal aborted';
  end if;

  perform 1 from public.wallets w
  where w.id = v_original.wallet_id and w.workspace_id = p_workspace_id
  for update;
  if not found then
    raise exception 'Original wallet no longer exists';
  end if;

  v_reversal_kind := case
    when v_original.kind = 'income'::public.transaction_kind then 'expense'::public.transaction_kind
    else 'income'::public.transaction_kind
  end;

  insert into public.transactions (
    workspace_id, wallet_id, category_id, kind, amount, occurred_at,
    title, notes, source, idempotency_key, created_by, reverses_transaction_id
  ) values (
    p_workspace_id, v_original.wallet_id, v_original.category_id, v_reversal_kind,
    v_original.amount, now(), left('Pembatalan: ' || v_original.title, 200),
    nullif(trim(coalesce(p_reason, '')), ''), 'reversal',
    'reverse:' || p_transaction_id::text, v_actor, p_transaction_id
  ) returning id into v_reversal_id;

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,v_original.wallet_id,v_reversal_id,-v_original_signed);

  update public.transactions
  set reversed_at = now(), reversed_by = v_actor, updated_at = now()
  where id = p_transaction_id and workspace_id = p_workspace_id;

  return v_reversal_id;
end;
$$;

revoke all on function public.save_investment(uuid,uuid,text,text,text,date) from public, anon;
revoke all on function public.record_investment_contribution(uuid,uuid,uuid,bigint,timestamptz,text,text) from public, anon;
revoke all on function public.record_investment_withdrawal(uuid,uuid,uuid,bigint,timestamptz,text,text) from public, anon;
revoke all on function public.record_investment_valuation(uuid,uuid,bigint,date,text,text) from public, anon;
revoke all on function public.close_investment(uuid,uuid) from public, anon;

grant execute on function public.save_investment(uuid,uuid,text,text,text,date) to authenticated;
grant execute on function public.record_investment_contribution(uuid,uuid,uuid,bigint,timestamptz,text,text) to authenticated;
grant execute on function public.record_investment_withdrawal(uuid,uuid,uuid,bigint,timestamptz,text,text) to authenticated;
grant execute on function public.record_investment_valuation(uuid,uuid,bigint,date,text,text) to authenticated;
grant execute on function public.close_investment(uuid,uuid) to authenticated;

comment on function public.record_investment_contribution(uuid,uuid,uuid,bigint,timestamptz,text,text)
is 'Atomically records a cash expense, ledger debit, investment contribution and principal/value increase.';
comment on function public.record_investment_withdrawal(uuid,uuid,uuid,bigint,timestamptz,text,text)
is 'Atomically records an asset inflow, ledger credit, investment withdrawal and proportional principal reduction.';
comment on function public.record_investment_valuation(uuid,uuid,bigint,date,text,text)
is 'Records a non-cash market valuation; it does not create a wallet transaction or ledger entry.';
