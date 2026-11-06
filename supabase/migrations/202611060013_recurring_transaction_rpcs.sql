-- Pockito / Supabase migration 0013
-- Recurring schedule management and atomic, period-idempotent execution.
-- Execution is RPC-driven; this migration does not install a background scheduler.

create or replace function public.save_recurring_transaction(
  p_workspace_id uuid,
  p_title text,
  p_kind public.transaction_kind,
  p_amount bigint,
  p_wallet_id uuid,
  p_category_id uuid,
  p_day_of_month smallint,
  p_starts_on date,
  p_ends_on date default null,
  p_is_active boolean default true,
  p_recurring_transaction_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
  v_category_type text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_title is null or length(trim(p_title)) not between 1 and 160 then
    raise exception 'Title must contain 1 to 160 characters';
  end if;
  if p_kind not in ('income'::public.transaction_kind,'expense'::public.transaction_kind) then
    raise exception 'Recurring schedules support income and expense only';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;
  if p_day_of_month is null or p_day_of_month not between 1 and 31 then
    raise exception 'Day of month must be between 1 and 31';
  end if;
  if p_starts_on is null or (p_ends_on is not null and p_ends_on < p_starts_on) then
    raise exception 'Invalid recurring schedule date range';
  end if;

  perform 1 from public.wallets w
  where w.id = p_wallet_id and w.workspace_id = p_workspace_id and w.is_active = true
  for update;
  if not found then
    raise exception 'Wallet not found, inactive, or outside this workspace';
  end if;

  if p_category_id is not null then
    select c.category_type into v_category_type
    from public.categories c
    where c.id = p_category_id and c.workspace_id = p_workspace_id;
    if not found or v_category_type not in ('both',p_kind::text) then
      raise exception 'Category type does not match recurring transaction type';
    end if;
  end if;

  if p_recurring_transaction_id is null then
    insert into public.recurring_transactions(
      workspace_id,title,kind,amount,wallet_id,category_id,day_of_month,
      starts_on,ends_on,is_active,created_by
    ) values (
      p_workspace_id,trim(p_title),p_kind,p_amount,p_wallet_id,p_category_id,
      p_day_of_month,p_starts_on,p_ends_on,coalesce(p_is_active,true),v_actor
    ) returning id into v_id;
  else
    update public.recurring_transactions
    set title=trim(p_title),kind=p_kind,amount=p_amount,wallet_id=p_wallet_id,
        category_id=p_category_id,day_of_month=p_day_of_month,starts_on=p_starts_on,
        ends_on=p_ends_on,is_active=coalesce(p_is_active,true),updated_at=now()
    where id=p_recurring_transaction_id and workspace_id=p_workspace_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Recurring schedule not found in this workspace';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.set_recurring_transaction_active(
  p_workspace_id uuid,
  p_recurring_transaction_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_is_active is null then
    raise exception 'Active state is required';
  end if;
  update public.recurring_transactions
  set is_active=p_is_active,updated_at=now()
  where id=p_recurring_transaction_id and workspace_id=p_workspace_id;
  if not found then
    raise exception 'Recurring schedule not found in this workspace';
  end if;
end;
$$;

create or replace function public.execute_recurring_transaction(
  p_workspace_id uuid,
  p_recurring_transaction_id uuid,
  p_period_start date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_schedule public.recurring_transactions%rowtype;
  v_existing_transaction_id uuid;
  v_transaction_id uuid;
  v_due_date date;
  v_next_period date;
  v_timezone text;
  v_category_type text;
  v_signed_amount bigint;
  v_idempotency_key text;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not public.can_edit_workspace(p_workspace_id) then
    raise exception 'You do not have permission to edit this workspace' using errcode = '42501';
  end if;
  if p_period_start is null or extract(day from p_period_start) <> 1 then
    raise exception 'Period start must be the first day of a month';
  end if;

  select r.* into v_schedule
  from public.recurring_transactions r
  where r.id=p_recurring_transaction_id and r.workspace_id=p_workspace_id
  for update;
  if not found then
    raise exception 'Recurring schedule not found in this workspace';
  end if;
  if not v_schedule.is_active then
    raise exception 'Recurring schedule is paused';
  end if;

  v_due_date := make_date(
    extract(year from p_period_start)::integer,
    extract(month from p_period_start)::integer,
    least(v_schedule.day_of_month,
      extract(day from (p_period_start + interval '1 month - 1 day'))::integer)
  );
  if v_due_date < v_schedule.starts_on then
    raise exception 'This schedule is not due in the selected period';
  end if;
  if v_schedule.ends_on is not null and v_due_date > v_schedule.ends_on then
    raise exception 'Recurring schedule has ended before this period';
  end if;
  if v_due_date > current_date then
    raise exception 'Recurring transaction is not due yet';
  end if;

  select e.transaction_id into v_existing_transaction_id
  from public.recurring_executions e
  where e.recurring_transaction_id=p_recurring_transaction_id
    and e.period_start=p_period_start;
  if v_existing_transaction_id is not null then
    return v_existing_transaction_id;
  end if;

  if v_schedule.last_processed_period is not null
     and p_period_start <= v_schedule.last_processed_period then
    raise exception 'This period is older than or equal to the last processed period';
  end if;

  perform 1 from public.wallets w
  where w.id=v_schedule.wallet_id and w.workspace_id=p_workspace_id and w.is_active=true
  for update;
  if not found then
    raise exception 'Recurring wallet is missing or inactive';
  end if;

  if v_schedule.category_id is not null then
    select c.category_type into v_category_type
    from public.categories c
    where c.id=v_schedule.category_id and c.workspace_id=p_workspace_id;
    if not found or v_category_type not in ('both',v_schedule.kind::text) then
      raise exception 'Recurring category is missing or no longer compatible';
    end if;
  end if;

  select coalesce(s.timezone,'Asia/Jakarta') into v_timezone
  from public.workspace_settings s
  where s.workspace_id=p_workspace_id;
  v_timezone := coalesce(v_timezone,'Asia/Jakarta');

  v_idempotency_key := 'recurring:' || p_recurring_transaction_id::text || ':' || to_char(p_period_start,'YYYY-MM-DD');

  insert into public.transactions(
    workspace_id,wallet_id,category_id,kind,amount,occurred_at,title,notes,
    source,idempotency_key,created_by
  ) values (
    p_workspace_id,v_schedule.wallet_id,v_schedule.category_id,v_schedule.kind,
    v_schedule.amount,(v_due_date::timestamp + time '12:00') at time zone v_timezone,
    v_schedule.title,'Eksekusi transaksi berulang',
    'recurring',v_idempotency_key,v_actor
  ) returning id into v_transaction_id;

  v_signed_amount := case when v_schedule.kind='income' then v_schedule.amount else -v_schedule.amount end;
  insert into public.ledger_entries(workspace_id,wallet_id,transaction_id,signed_amount)
  values(p_workspace_id,v_schedule.wallet_id,v_transaction_id,v_signed_amount);

  insert into public.recurring_executions(
    workspace_id,recurring_transaction_id,period_start,transaction_id
  ) values (
    p_workspace_id,p_recurring_transaction_id,p_period_start,v_transaction_id
  );

  update public.recurring_transactions
  set last_processed_period=p_period_start,updated_at=now()
  where id=p_recurring_transaction_id and workspace_id=p_workspace_id;

  return v_transaction_id;
end;
$$;

revoke all on function public.save_recurring_transaction(uuid,text,public.transaction_kind,bigint,uuid,uuid,smallint,date,date,boolean,uuid) from public,anon;
revoke all on function public.set_recurring_transaction_active(uuid,uuid,boolean) from public,anon;
revoke all on function public.execute_recurring_transaction(uuid,uuid,date) from public,anon;

grant execute on function public.save_recurring_transaction(uuid,text,public.transaction_kind,bigint,uuid,uuid,smallint,date,date,boolean,uuid) to authenticated;
grant execute on function public.set_recurring_transaction_active(uuid,uuid,boolean) to authenticated;
grant execute on function public.execute_recurring_transaction(uuid,uuid,date) to authenticated;

comment on function public.execute_recurring_transaction(uuid,uuid,date)
is 'Atomically posts one due monthly recurring income/expense for a specified first-of-month period. Unique execution records make retries idempotent; this RPC is not a background scheduler.';
