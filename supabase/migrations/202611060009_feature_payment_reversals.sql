-- Pockito / Supabase migration 0009
-- Feature-aware reversal for installment and debt payments.
-- Reversed payment rows remain as audit history but are excluded from balances.

alter table public.installment_payments
  add column reversed_at timestamptz,
  add column reversed_by uuid references auth.users(id),
  add column reversal_transaction_id uuid;

alter table public.installment_payments
  add constraint installment_payment_reversal_tx_fk
  foreign key(workspace_id,reversal_transaction_id)
  references public.transactions(workspace_id,id);

alter table public.debt_payments
  add column reversed_at timestamptz,
  add column reversed_by uuid references auth.users(id),
  add column reversal_transaction_id uuid;

alter table public.debt_payments
  add constraint debt_payment_reversal_tx_fk
  foreign key(workspace_id,reversal_transaction_id)
  references public.transactions(workspace_id,id);

-- Recreate payment functions so reversed payment rows no longer reduce balances.
-- Pockito / Supabase migration 0007
-- Atomic installment and debt payments with linked ledger transactions.

create or replace function public.pay_installment_plan(
  p_workspace_id uuid,
  p_plan_id uuid,
  p_wallet_id uuid,
  p_amount bigint,
  p_paid_at timestamptz,
  p_title text default null,
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
  v_plan public.installment_plans%rowtype;
  v_wallet_id uuid;
  v_category_id uuid;
  v_category_type text;
  v_existing_id uuid;
  v_transaction_id uuid;
  v_key text;
  v_title text;
  v_remaining bigint;
  v_installment record;
  v_paid_principal bigint;
  v_paid_fee bigint;
  v_due_principal bigint;
  v_due_fee bigint;
  v_due_total bigint;
  v_apply bigint;
  v_apply_principal bigint;
  v_apply_fee bigint;
  v_allocated bigint := 0;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;
  if p_paid_at is null then
    raise exception 'Payment date is required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 128 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_key := 'installment:' || trim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || v_key, 0));

  select t.id into v_existing_id
  from public.transactions t
  where t.workspace_id = p_workspace_id and t.idempotency_key = v_key;

  if v_existing_id is not null then
    if exists (
      select 1 from public.installment_payments ip
      join public.installments i on i.workspace_id = ip.workspace_id and i.id = ip.installment_id
      where ip.workspace_id = p_workspace_id
        and ip.transaction_id = v_existing_id
        and ip.reversed_at is null
        and i.plan_id = p_plan_id
    ) then
      return v_existing_id;
    end if;
    raise exception 'Idempotency key is already used by another operation';
  end if;

  select p.* into v_plan
  from public.installment_plans p
  where p.id = p_plan_id and p.workspace_id = p_workspace_id
  for update;

  if not found then
    raise exception 'Installment plan not found in this workspace';
  end if;

  select w.id into v_wallet_id
  from public.wallets w
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id and w.is_active = true
  for update;

  if v_wallet_id is null then
    raise exception 'Payment wallet not found, inactive, or outside this workspace';
  end if;

  v_category_id := v_plan.category_id;
  if v_category_id is not null then
    select c.category_type into v_category_type
    from public.categories c
    where c.id = v_category_id and c.workspace_id = p_workspace_id;
    if not found or v_category_type not in ('both','expense') then
      raise exception 'Installment plan category must be an expense category';
    end if;
  end if;

  -- Lock every installment in this plan. The plan-row lock serializes this
  -- operation against other payments for the same plan.
  perform i.id
  from public.installments i
  where i.workspace_id = p_workspace_id and i.plan_id = p_plan_id
  order by i.due_date, i.installment_number, i.id
  for update;

  select coalesce(sum(i.total_amount - coalesce(paid.amount,0)),0)
    into v_remaining
  from public.installments i
  left join (
    select ip.installment_id, sum(ip.amount)::bigint as amount
    from public.installment_payments ip
    where ip.workspace_id = p_workspace_id and ip.reversed_at is null
    group by ip.installment_id
  ) paid on paid.installment_id = i.id
  where i.workspace_id = p_workspace_id and i.plan_id = p_plan_id;

  if v_remaining <= 0 then
    raise exception 'This installment plan is already fully paid';
  end if;
  if p_amount > v_remaining then
    raise exception 'Payment exceeds the remaining installment balance';
  end if;

  v_title := coalesce(nullif(trim(p_title),''), 'Pembayaran cicilan: ' || v_plan.title);

  insert into public.transactions (
    workspace_id, wallet_id, category_id, kind, amount, occurred_at,
    title, notes, source, idempotency_key, created_by
  ) values (
    p_workspace_id, p_wallet_id, v_category_id, 'expense', p_amount, p_paid_at,
    left(v_title,200), nullif(trim(coalesce(p_notes,'')), ''),
    'installment_payment', v_key, v_actor
  )
  returning id into v_transaction_id;

  v_remaining := p_amount;

  -- Oldest due installment first. A partial installment is split proportionally
  -- between its remaining principal and fee; integer remainder goes to fee.
  for v_installment in
    select i.id, i.principal_amount, i.fee_amount
    from public.installments i
    where i.workspace_id = p_workspace_id and i.plan_id = p_plan_id
    order by i.due_date, i.installment_number, i.id
  loop
    exit when v_remaining = 0;

    select
      coalesce(sum(ip.principal_applied),0)::bigint,
      coalesce(sum(ip.fee_applied),0)::bigint
    into v_paid_principal, v_paid_fee
    from public.installment_payments ip
    where ip.workspace_id = p_workspace_id
      and ip.installment_id = v_installment.id
      and ip.reversed_at is null;

    v_due_principal := v_installment.principal_amount - v_paid_principal;
    v_due_fee := v_installment.fee_amount - v_paid_fee;
    v_due_total := v_due_principal + v_due_fee;

    if v_due_total <= 0 then
      continue;
    end if;

    v_apply := least(v_remaining, v_due_total);

    if v_apply = v_due_total then
      v_apply_principal := v_due_principal;
      v_apply_fee := v_due_fee;
    else
      v_apply_principal := floor(
        (v_apply::numeric * v_due_principal::numeric) / v_due_total::numeric
      )::bigint;
      v_apply_fee := v_apply - v_apply_principal;
    end if;

    insert into public.installment_payments (
      workspace_id, installment_id, transaction_id, amount,
      principal_applied, fee_applied, paid_at, created_by
    ) values (
      p_workspace_id, v_installment.id, v_transaction_id, v_apply,
      v_apply_principal, v_apply_fee, p_paid_at, v_actor
    );

    v_remaining := v_remaining - v_apply;
    v_allocated := v_allocated + v_apply;
  end loop;

  if v_allocated <> p_amount or v_remaining <> 0 then
    raise exception 'Installment allocation did not match payment amount';
  end if;

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,p_wallet_id,v_transaction_id,-p_amount);

  return v_transaction_id;
end;
$$;

create or replace function public.pay_debt(
  p_workspace_id uuid,
  p_debt_id uuid,
  p_wallet_id uuid,
  p_amount bigint,
  p_paid_at timestamptz,
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
  v_debt public.debts%rowtype;
  v_wallet_id uuid;
  v_category_type text;
  v_existing_id uuid;
  v_transaction_id uuid;
  v_key text;
  v_transaction_kind public.transaction_kind;
  v_title text;
  v_paid_total bigint;
  v_outstanding bigint;
  v_signed_amount bigint;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;
  if p_paid_at is null then
    raise exception 'Payment date is required';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 1 and 128 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_key := 'debt:' || trim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(p_workspace_id::text || ':' || v_key, 0));

  select t.id into v_existing_id
  from public.transactions t
  where t.workspace_id = p_workspace_id and t.idempotency_key = v_key;

  if v_existing_id is not null then
    if exists (
      select 1 from public.debt_payments dp
      where dp.workspace_id = p_workspace_id
        and dp.transaction_id = v_existing_id
        and dp.debt_id = p_debt_id
        and dp.reversed_at is null
    ) then
      return v_existing_id;
    end if;
    raise exception 'Idempotency key is already used by another operation';
  end if;

  select d.* into v_debt
  from public.debts d
  where d.id = p_debt_id and d.workspace_id = p_workspace_id
  for update;

  if not found then
    raise exception 'Debt record not found in this workspace';
  end if;
  if v_debt.status = 'cancelled' then
    raise exception 'Cancelled debt cannot receive payments';
  end if;

  select coalesce(sum(dp.amount),0)::bigint into v_paid_total
  from public.debt_payments dp
  where dp.workspace_id = p_workspace_id and dp.debt_id = p_debt_id
    and dp.reversed_at is null;

  v_outstanding := v_debt.principal_amount - v_paid_total;
  if v_outstanding <= 0 then
    raise exception 'This debt is already fully settled';
  end if;
  if p_amount > v_outstanding then
    raise exception 'Payment exceeds the outstanding debt balance';
  end if;

  select w.id into v_wallet_id
  from public.wallets w
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id and w.is_active = true
  for update;

  if v_wallet_id is null then
    raise exception 'Payment wallet not found, inactive, or outside this workspace';
  end if;

  v_transaction_kind := case
    when v_debt.direction = 'payable' then 'expense'::public.transaction_kind
    else 'income'::public.transaction_kind
  end;

  if p_category_id is not null then
    select c.category_type into v_category_type
    from public.categories c
    where c.id = p_category_id and c.workspace_id = p_workspace_id;
    if not found or v_category_type not in ('both', v_transaction_kind::text) then
      raise exception 'Category type does not match debt payment direction';
    end if;
  end if;

  v_title := case
    when v_debt.direction = 'payable' then 'Pembayaran utang: '
    else 'Penerimaan piutang: '
  end || v_debt.counterparty_name;

  insert into public.transactions (
    workspace_id, wallet_id, category_id, kind, amount, occurred_at,
    title, notes, source, idempotency_key, created_by
  ) values (
    p_workspace_id, p_wallet_id, p_category_id, v_transaction_kind, p_amount, p_paid_at,
    left(v_title,200), nullif(trim(coalesce(p_notes,'')), ''),
    'debt_payment', v_key, v_actor
  )
  returning id into v_transaction_id;

  v_signed_amount := case when v_transaction_kind = 'income' then p_amount else -p_amount end;

  insert into public.debt_payments (
    workspace_id, debt_id, transaction_id, amount, paid_at, notes, created_by
  ) values (
    p_workspace_id, p_debt_id, v_transaction_id, p_amount, p_paid_at,
    nullif(trim(coalesce(p_notes,'')), ''), v_actor
  );

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,p_wallet_id,v_transaction_id,v_signed_amount);

  if p_amount = v_outstanding then
    update public.debts
    set status = 'settled', updated_at = now()
    where id = p_debt_id and workspace_id = p_workspace_id;
  end if;

  return v_transaction_id;
end;
$$;

revoke all on function public.pay_installment_plan(uuid,uuid,uuid,bigint,timestamptz,text,text,text) from public, anon;
revoke all on function public.pay_debt(uuid,uuid,uuid,bigint,timestamptz,uuid,text,text) from public, anon;

grant execute on function public.pay_installment_plan(uuid,uuid,uuid,bigint,timestamptz,text,text,text) to authenticated;
grant execute on function public.pay_debt(uuid,uuid,uuid,bigint,timestamptz,uuid,text,text) to authenticated;

comment on function public.pay_installment_plan(uuid,uuid,uuid,bigint,timestamptz,text,text,text)
is 'Atomically posts an expense for a credit-card installment payment, allocating oldest due installments first and splitting partial amounts proportionally between remaining principal and fees.';
comment on function public.pay_debt(uuid,uuid,uuid,bigint,timestamptz,uuid,text,text)
is 'Atomically posts a debt payment as expense for payable debt or income for receivable debt, supports partial settlement, and updates debt status when fully paid.';



create or replace function public.reverse_installment_payment(
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
  v_existing uuid;
  v_reversal_id uuid;
  v_signed bigint;
  v_payment_count integer;
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
  if not found then raise exception 'Payment transaction not found'; end if;
  if v_original.source <> 'installment_payment'
     or v_original.kind <> 'expense'::public.transaction_kind
     or v_original.reverses_transaction_id is not null then
    raise exception 'Transaction is not a reversible installment payment';
  end if;

  select t.id into v_existing
  from public.transactions t
  where t.workspace_id = p_workspace_id
    and t.reverses_transaction_id = p_transaction_id;
  if v_existing is not null then return v_existing; end if;

  if v_original.reversed_at is not null then
    raise exception 'Installment payment is already reversed';
  end if;

  select count(*) into v_payment_count
  from public.installment_payments ip
  where ip.workspace_id = p_workspace_id
    and ip.transaction_id = p_transaction_id
    and ip.reversed_at is null;
  if v_payment_count = 0 then
    raise exception 'Active installment payment allocations are missing';
  end if;

  select le.signed_amount into v_signed
  from public.ledger_entries le
  where le.workspace_id = p_workspace_id
    and le.transaction_id = p_transaction_id;
  if v_signed is null then raise exception 'Original ledger entry is missing'; end if;

  perform 1 from public.wallets w
  where w.id = v_original.wallet_id and w.workspace_id = p_workspace_id
  for update;
  if not found then raise exception 'Original wallet no longer exists'; end if;

  insert into public.transactions (
    workspace_id,wallet_id,category_id,kind,amount,occurred_at,title,notes,
    source,idempotency_key,created_by,reverses_transaction_id
  ) values (
    p_workspace_id,v_original.wallet_id,v_original.category_id,'income',
    v_original.amount,now(),left('Pembatalan cicilan: ' || v_original.title,200),
    nullif(trim(coalesce(p_reason,'')),''),'installment_payment_reversal',
    'reverse-installment:' || p_transaction_id::text,v_actor,p_transaction_id
  ) returning id into v_reversal_id;

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,v_original.wallet_id,v_reversal_id,-v_signed);

  update public.installment_payments
  set reversed_at=now(),reversed_by=v_actor,reversal_transaction_id=v_reversal_id
  where workspace_id=p_workspace_id and transaction_id=p_transaction_id
    and reversed_at is null;

  update public.transactions
  set reversed_at=now(),reversed_by=v_actor,updated_at=now()
  where id=p_transaction_id and workspace_id=p_workspace_id;

  return v_reversal_id;
end;
$$;

create or replace function public.reverse_debt_payment(
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
  v_existing uuid;
  v_reversal_id uuid;
  v_signed bigint;
  v_debt_id uuid;
  v_payment_count integer;
  v_paid_total bigint;
  v_principal bigint;
  v_status text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;

  select t.* into v_original
  from public.transactions t
  where t.id=p_transaction_id and t.workspace_id=p_workspace_id
  for update;
  if not found then raise exception 'Payment transaction not found'; end if;
  if v_original.source <> 'debt_payment'
     or v_original.kind not in ('income'::public.transaction_kind,'expense'::public.transaction_kind)
     or v_original.reverses_transaction_id is not null then
    raise exception 'Transaction is not a reversible debt payment';
  end if;

  select t.id into v_existing
  from public.transactions t
  where t.workspace_id=p_workspace_id and t.reverses_transaction_id=p_transaction_id;
  if v_existing is not null then return v_existing; end if;
  if v_original.reversed_at is not null then raise exception 'Debt payment is already reversed'; end if;

  select dp.debt_id into v_debt_id
  from public.debt_payments dp
  where dp.workspace_id=p_workspace_id and dp.transaction_id=p_transaction_id
    and dp.reversed_at is null
  for update;
  if v_debt_id is null then raise exception 'Active debt payment record is missing'; end if;

  perform 1 from public.debts d
  where d.id=v_debt_id and d.workspace_id=p_workspace_id
  for update;
  if not found then raise exception 'Debt record no longer exists'; end if;

  select le.signed_amount into v_signed
  from public.ledger_entries le
  where le.workspace_id=p_workspace_id and le.transaction_id=p_transaction_id;
  if v_signed is null then raise exception 'Original ledger entry is missing'; end if;

  perform 1 from public.wallets w
  where w.id=v_original.wallet_id and w.workspace_id=p_workspace_id
  for update;
  if not found then raise exception 'Original wallet no longer exists'; end if;

  insert into public.transactions (
    workspace_id,wallet_id,category_id,kind,amount,occurred_at,title,notes,
    source,idempotency_key,created_by,reverses_transaction_id
  ) values (
    p_workspace_id,v_original.wallet_id,v_original.category_id,
    case when v_original.kind='income'::public.transaction_kind
      then 'expense'::public.transaction_kind else 'income'::public.transaction_kind end,
    v_original.amount,now(),left('Pembatalan pembayaran: ' || v_original.title,200),
    nullif(trim(coalesce(p_reason,'')),''),'debt_payment_reversal',
    'reverse-debt:' || p_transaction_id::text,v_actor,p_transaction_id
  ) returning id into v_reversal_id;

  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,v_original.wallet_id,v_reversal_id,-v_signed);

  update public.debt_payments
  set reversed_at=now(),reversed_by=v_actor,reversal_transaction_id=v_reversal_id
  where workspace_id=p_workspace_id and transaction_id=p_transaction_id
    and reversed_at is null;

  update public.transactions
  set reversed_at=now(),reversed_by=v_actor,updated_at=now()
  where id=p_transaction_id and workspace_id=p_workspace_id;

  select d.principal_amount, d.status into v_principal,v_status
  from public.debts d
  where d.id=v_debt_id and d.workspace_id=p_workspace_id;

  select coalesce(sum(dp.amount),0)::bigint into v_paid_total
  from public.debt_payments dp
  where dp.workspace_id=p_workspace_id and dp.debt_id=v_debt_id
    and dp.reversed_at is null;

  update public.debts
  set status=case
    when v_status='cancelled' then 'cancelled'
    when v_paid_total >= v_principal then 'settled'
    else 'open'
  end,
  updated_at=now()
  where id=v_debt_id and workspace_id=p_workspace_id;

  return v_reversal_id;
end;
$$;

revoke all on function public.reverse_installment_payment(uuid,uuid,text) from public,anon;
revoke all on function public.reverse_debt_payment(uuid,uuid,text) from public,anon;
grant execute on function public.reverse_installment_payment(uuid,uuid,text) to authenticated;
grant execute on function public.reverse_debt_payment(uuid,uuid,text) to authenticated;

comment on function public.reverse_installment_payment(uuid,uuid,text)
is 'Atomically reverses an installment payment, restores installment outstanding amounts by excluding its allocations, and writes a compensating ledger transaction.';
comment on function public.reverse_debt_payment(uuid,uuid,text)
is 'Atomically reverses a debt payment, recomputes debt status from active payments, and writes a compensating ledger transaction.';

