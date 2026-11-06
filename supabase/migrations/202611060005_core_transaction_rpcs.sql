-- Pockito / Supabase migration 0005
-- Atomic posting and reversal for ordinary income/expense transactions.
-- Transfers are intentionally excluded until same-workspace and cross-workspace
-- authorization rules are finalized.

alter table public.transactions
  add column reverses_transaction_id uuid;

alter table public.transactions
  add constraint transactions_reverses_transaction_fk
  foreign key (workspace_id, reverses_transaction_id)
  references public.transactions(workspace_id, id);

create unique index transactions_one_reversal_idx
  on public.transactions(workspace_id, reverses_transaction_id)
  where reverses_transaction_id is not null;

create or replace function public.post_financial_transaction(
  p_workspace_id uuid,
  p_wallet_id uuid,
  p_kind public.transaction_kind,
  p_amount bigint,
  p_occurred_at timestamptz,
  p_title text,
  p_category_id uuid default null,
  p_notes text default null,
  p_source text default 'manual',
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_wallet_workspace uuid;
  v_category_type text;
  v_existing_id uuid;
  v_transaction_id uuid;
  v_signed_amount bigint;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_kind not in ('income'::public.transaction_kind, 'expense'::public.transaction_kind) then
    raise exception 'Only income and expense can use this function';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;

  if p_occurred_at is null then
    raise exception 'Transaction date is required';
  end if;

  if p_title is null or length(trim(p_title)) not between 1 and 200 then
    raise exception 'Title must contain 1 to 200 characters';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 128 then
    raise exception 'A valid idempotency key is required';
  end if;

  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;

  -- Serialize retries that use the same workspace/key before checking existence.
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || p_idempotency_key, 0));

  select t.id into v_existing_id
  from public.transactions t
  where t.workspace_id = p_workspace_id
    and t.idempotency_key = p_idempotency_key;

  if v_existing_id is not null then
    return v_existing_id;
  end if;

  select w.workspace_id into v_wallet_workspace
  from public.wallets w
  where w.id = p_wallet_id
    and w.workspace_id = p_workspace_id
    and w.is_active = true
  for update;

  if v_wallet_workspace is null then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  if p_category_id is not null then
    select c.category_type into v_category_type
    from public.categories c
    where c.id = p_category_id
      and c.workspace_id = p_workspace_id;

    if not found then
      raise exception 'Category not found in this workspace';
    end if;

    if v_category_type not in ('both', p_kind::text) then
      raise exception 'Category type does not match transaction type';
    end if;
  end if;

  insert into public.transactions (
    workspace_id, wallet_id, category_id, kind, amount, occurred_at,
    title, notes, source, idempotency_key, created_by
  ) values (
    p_workspace_id, p_wallet_id, p_category_id, p_kind, p_amount, p_occurred_at,
    trim(p_title), nullif(trim(coalesce(p_notes, '')), ''),
    coalesce(nullif(trim(p_source), ''), 'manual'), p_idempotency_key, v_actor
  )
  returning id into v_transaction_id;

  v_signed_amount := case when p_kind = 'income' then p_amount else -p_amount end;

  insert into public.ledger_entries (
    workspace_id, wallet_id, transaction_id, signed_amount
  ) values (
    p_workspace_id, p_wallet_id, v_transaction_id, v_signed_amount
  );

  return v_transaction_id;
end;
$$;

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
  where t.id = p_transaction_id
    and t.workspace_id = p_workspace_id
  for update;

  if not found then
    raise exception 'Transaction not found in this workspace';
  end if;

  if v_original.kind not in ('income'::public.transaction_kind, 'expense'::public.transaction_kind) then
    raise exception 'Only ordinary income/expense transactions can be reversed here';
  end if;

  select t.id into v_existing_reversal
  from public.transactions t
  where t.workspace_id = p_workspace_id
    and t.reverses_transaction_id = p_transaction_id;

  if v_existing_reversal is not null then
    return v_existing_reversal;
  end if;

  if v_original.reversed_at is not null then
    raise exception 'Transaction is already marked as reversed';
  end if;

  select le.signed_amount into v_original_signed
  from public.ledger_entries le
  where le.workspace_id = p_workspace_id
    and le.transaction_id = p_transaction_id;

  if v_original_signed is null then
    raise exception 'Original ledger entry is missing; reversal aborted';
  end if;

  perform 1
  from public.wallets w
  where w.id = v_original.wallet_id
    and w.workspace_id = p_workspace_id
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
    v_original.amount, now(),
    left('Pembatalan: ' || v_original.title, 200),
    nullif(trim(coalesce(p_reason, '')), ''),
    'reversal', 'reverse:' || p_transaction_id::text, v_actor, p_transaction_id
  )
  returning id into v_reversal_id;

  insert into public.ledger_entries (
    workspace_id, wallet_id, transaction_id, signed_amount
  ) values (
    p_workspace_id, v_original.wallet_id, v_reversal_id, -v_original_signed
  );

  update public.transactions
  set reversed_at = now(), reversed_by = v_actor, updated_at = now()
  where id = p_transaction_id
    and workspace_id = p_workspace_id;

  return v_reversal_id;
end;
$$;

revoke all on function public.post_financial_transaction(
  uuid, uuid, public.transaction_kind, bigint, timestamptz, text, uuid, text, text, text
) from public, anon;
revoke all on function public.reverse_financial_transaction(uuid, uuid, text) from public, anon;

grant execute on function public.post_financial_transaction(
  uuid, uuid, public.transaction_kind, bigint, timestamptz, text, uuid, text, text, text
) to authenticated;
grant execute on function public.reverse_financial_transaction(uuid, uuid, text) to authenticated;

comment on function public.post_financial_transaction(uuid, uuid, public.transaction_kind, bigint, timestamptz, text, uuid, text, text, text)
is 'Atomically creates an income/expense transaction and its ledger entry. Requires workspace edit permission and an idempotency key.';
comment on function public.reverse_financial_transaction(uuid, uuid, text)
is 'Atomically creates a compensating income/expense transaction and marks the original as reversed; never deletes financial history.';
