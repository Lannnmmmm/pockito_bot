-- Pockito / Supabase migration 0014
-- Prevent an internal transfer from making its source wallet negative.
-- The source and destination wallet rows are locked before reading the balance.

create or replace function public.post_wallet_transfer(
  p_workspace_id uuid,
  p_source_wallet_id uuid,
  p_destination_wallet_id uuid,
  p_amount bigint,
  p_occurred_at timestamptz,
  p_title text,
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
  v_group_id uuid;
  v_existing_group_id uuid;
  v_source_name text;
  v_destination_name text;
  v_wallet_count integer;
  v_source_balance bigint;
  v_key text;
  v_description text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;

  if p_source_wallet_id is null or p_destination_wallet_id is null
     or p_source_wallet_id = p_destination_wallet_id then
    raise exception 'Source and destination wallets must be different';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Transfer amount must be greater than zero';
  end if;

  if p_occurred_at is null then
    raise exception 'Transfer date is required';
  end if;

  if p_title is null or length(trim(p_title)) not between 1 and 200 then
    raise exception 'Transfer title must contain 1 to 200 characters';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 128 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_key := p_workspace_id::text || ':' || trim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(v_key, 0));

  select g.id into v_existing_group_id
  from public.transfer_groups g
  where g.idempotency_key = v_key;

  if v_existing_group_id is not null then
    return v_existing_group_id;
  end if;

  -- Lock both wallets in stable order to serialize concurrent wallet mutations.
  perform w.id
  from public.wallets w
  where w.workspace_id = p_workspace_id
    and w.id in (p_source_wallet_id, p_destination_wallet_id)
    and w.is_active = true
  order by w.id
  for update;

  select count(*) into v_wallet_count
  from public.wallets w
  where w.workspace_id = p_workspace_id
    and w.id in (p_source_wallet_id, p_destination_wallet_id)
    and w.is_active = true;

  if v_wallet_count <> 2 then
    raise exception 'Both wallets must exist, be active, and belong to this workspace';
  end if;

  -- Balance is derived from opening balance plus the immutable ledger.
  select w.opening_balance + coalesce(sum(le.signed_amount), 0)
    into v_source_balance
  from public.wallets w
  left join public.ledger_entries le
    on le.workspace_id = w.workspace_id
   and le.wallet_id = w.id
  where w.workspace_id = p_workspace_id
    and w.id = p_source_wallet_id
  group by w.id, w.opening_balance;

  if v_source_balance < p_amount then
    raise exception 'Insufficient source wallet balance (available: %, requested: %)',
      v_source_balance, p_amount
      using errcode = '23514';
  end if;

  select name into v_source_name
  from public.wallets
  where id = p_source_wallet_id and workspace_id = p_workspace_id;

  select name into v_destination_name
  from public.wallets
  where id = p_destination_wallet_id and workspace_id = p_workspace_id;

  v_description := trim(p_title);

  insert into public.transfer_groups (
    source_workspace_id, destination_workspace_id, initiated_by,
    idempotency_key, amount, description
  ) values (
    p_workspace_id, p_workspace_id, v_actor,
    v_key, p_amount, v_description
  )
  returning id into v_group_id;

  insert into public.transactions (
    workspace_id, wallet_id, kind, amount, occurred_at, title, notes,
    source, transfer_group_id, idempotency_key, created_by
  ) values (
    p_workspace_id, p_source_wallet_id, 'transfer_out', p_amount, p_occurred_at,
    left(v_description || ' → ' || v_destination_name, 200),
    nullif(trim(coalesce(p_notes, '')), ''),
    'wallet_transfer', v_group_id, 'transfer:' || v_group_id::text || ':out', v_actor
  );

  insert into public.transactions (
    workspace_id, wallet_id, kind, amount, occurred_at, title, notes,
    source, transfer_group_id, idempotency_key, created_by
  ) values (
    p_workspace_id, p_destination_wallet_id, 'transfer_in', p_amount, p_occurred_at,
    left(v_description || ' ← ' || v_source_name, 200),
    nullif(trim(coalesce(p_notes, '')), ''),
    'wallet_transfer', v_group_id, 'transfer:' || v_group_id::text || ':in', v_actor
  );

  insert into public.ledger_entries (
    workspace_id, wallet_id, transaction_id, signed_amount
  )
  select t.workspace_id, t.wallet_id, t.id,
         case when t.kind = 'transfer_out' then -t.amount else t.amount end
  from public.transactions t
  where t.workspace_id = p_workspace_id
    and t.transfer_group_id = v_group_id;

  if (select count(*) from public.ledger_entries le
      join public.transactions t on t.id = le.transaction_id
      where t.workspace_id = p_workspace_id
        and t.transfer_group_id = v_group_id) <> 2 then
    raise exception 'Transfer ledger pair could not be completed';
  end if;

  return v_group_id;
end;
$$;

revoke all on function public.post_wallet_transfer(
  uuid, uuid, uuid, bigint, timestamptz, text, text, text
) from public, anon;

grant execute on function public.post_wallet_transfer(
  uuid, uuid, uuid, bigint, timestamptz, text, text, text
) to authenticated;

comment on function public.post_wallet_transfer(uuid, uuid, uuid, bigint, timestamptz, text, text, text)
is 'Atomically transfers funds between two active wallets in the same workspace, rejects insufficient source balance, and records paired transactions and ledger entries.';
