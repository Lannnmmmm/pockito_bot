-- Pockito / Supabase migration 0008
-- Prevent generic transaction reversal from desynchronizing installment/debt balances.

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

  if v_original.source in ('installment_payment','debt_payment') then
    raise exception 'Installment/debt payments require a feature-aware reversal operation';
  end if;

  if v_original.reverses_transaction_id is not null then
    raise exception 'A reversal transaction cannot itself be reversed';
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


comment on function public.reverse_financial_transaction(uuid, uuid, text)
is 'Creates a compensating income/expense transaction. Installment/debt payment sources are blocked until feature-aware reversal operations can restore their payment allocations.';
