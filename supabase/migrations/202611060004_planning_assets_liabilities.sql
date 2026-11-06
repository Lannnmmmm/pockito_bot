-- Pockito / Supabase migration 0004
-- Planning, investments, credit cards/installments, debts and recurring schedules.
-- Monetary columns use BIGINT whole Rupiah. All rows are workspace-scoped.

create type public.goal_allocation_kind as enum ('reserve','release','spend');
create type public.debt_direction as enum ('payable','receivable');
create type public.investment_movement_kind as enum ('contribution','withdrawal','valuation');

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  period_start date not null,
  name text not null default 'Anggaran Bulanan',
  alert_threshold smallint not null default 80 check(alert_threshold between 1 and 100),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique(workspace_id,period_start),
  unique(workspace_id,id)
);

create table public.budget_categories (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  budget_id uuid not null,
  category_id uuid not null,
  limit_amount bigint not null default 0 check(limit_amount >= 0),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,budget_id) references public.budgets(workspace_id,id) on delete cascade,
  foreign key(workspace_id,category_id) references public.categories(workspace_id,id),
  unique(budget_id,category_id),
  unique(workspace_id,id)
);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 120),
  target_amount bigint not null check(target_amount > 0),
  deadline date,
  notes text,
  status text not null default 'active' check(status in ('active','completed','paused','cancelled')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(workspace_id,id)
);

-- Goal allocations are earmarks, not expenses. reserve/release changes earmarked balance;
-- spend records actual consumption and must be linked to a real expense transaction.
create table public.goal_allocations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  goal_id uuid not null,
  wallet_id uuid,
  transaction_id uuid,
  kind public.goal_allocation_kind not null,
  amount bigint not null check(amount > 0),
  occurred_at timestamptz not null default now(),
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,goal_id) references public.goals(workspace_id,id) on delete cascade,
  foreign key(workspace_id,wallet_id) references public.wallets(workspace_id,id),
  foreign key(workspace_id,transaction_id) references public.transactions(workspace_id,id),
  check((kind='spend' and transaction_id is not null) or (kind<>'spend'))
);
create index goal_allocations_goal_date_idx on public.goal_allocations(workspace_id,goal_id,occurred_at);

create table public.investments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 120),
  instrument_type text not null default 'other',
  description text,
  principal_amount bigint not null default 0 check(principal_amount >= 0),
  current_value bigint not null default 0 check(current_value >= 0),
  opened_on date,
  status text not null default 'active' check(status in ('active','closed')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(workspace_id,id)
);

create table public.investment_movements (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  investment_id uuid not null,
  kind public.investment_movement_kind not null,
  amount bigint not null check(amount > 0),
  transaction_id uuid,
  valuation_date date,
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,investment_id) references public.investments(workspace_id,id) on delete cascade,
  foreign key(workspace_id,transaction_id) references public.transactions(workspace_id,id),
  check((kind='valuation' and transaction_id is null and valuation_date is not null)
     or (kind<>'valuation' and transaction_id is not null))
);
create index investment_movements_investment_idx on public.investment_movements(workspace_id,investment_id,created_at);

create table public.credit_cards (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 100),
  credit_limit bigint not null check(credit_limit > 0),
  statement_day smallint check(statement_day between 1 and 31),
  due_day smallint not null check(due_day between 1 and 31),
  notes text,
  is_active boolean not null default true,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(workspace_id,id)
);

create table public.installment_plans (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  credit_card_id uuid not null,
  title text not null check(length(trim(title)) between 1 and 160),
  category_id uuid,
  purchase_date date not null,
  principal_amount bigint not null check(principal_amount > 0),
  tenor smallint not null check(tenor between 1 and 120),
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,credit_card_id) references public.credit_cards(workspace_id,id),
  foreign key(workspace_id,category_id) references public.categories(workspace_id,id),
  unique(workspace_id,id)
);

create table public.installments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  plan_id uuid not null,
  installment_number smallint not null check(installment_number > 0),
  due_date date not null,
  principal_amount bigint not null check(principal_amount > 0),
  fee_amount bigint not null default 0 check(fee_amount >= 0),
  total_amount bigint generated always as (principal_amount + fee_amount) stored,
  created_at timestamptz not null default now(),
  foreign key(workspace_id,plan_id) references public.installment_plans(workspace_id,id) on delete cascade,
  unique(plan_id,installment_number),
  unique(workspace_id,id)
);
create index installments_due_idx on public.installments(workspace_id,due_date);

create table public.installment_payments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  installment_id uuid not null,
  transaction_id uuid not null,
  amount bigint not null check(amount > 0),
  principal_applied bigint not null check(principal_applied >= 0),
  fee_applied bigint not null check(fee_applied >= 0),
  paid_at timestamptz not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,installment_id) references public.installments(workspace_id,id),
  foreign key(workspace_id,transaction_id) references public.transactions(workspace_id,id),
  check(amount = principal_applied + fee_applied)
);
create index installment_payments_installment_idx on public.installment_payments(workspace_id,installment_id,paid_at);

create table public.debts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  counterparty_name text not null check(length(trim(counterparty_name)) between 1 and 120),
  direction public.debt_direction not null,
  principal_amount bigint not null check(principal_amount > 0),
  opened_on date not null,
  due_date date,
  notes text,
  status text not null default 'open' check(status in ('open','settled','cancelled')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(workspace_id,id)
);

create table public.debt_payments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  debt_id uuid not null,
  transaction_id uuid not null,
  amount bigint not null check(amount > 0),
  paid_at timestamptz not null,
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(workspace_id,debt_id) references public.debts(workspace_id,id),
  foreign key(workspace_id,transaction_id) references public.transactions(workspace_id,id)
);
create index debt_payments_debt_idx on public.debt_payments(workspace_id,debt_id,paid_at);

create table public.recurring_transactions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  title text not null check(length(trim(title)) between 1 and 160),
  kind public.transaction_kind not null check(kind in ('income','expense')),
  amount bigint not null check(amount > 0),
  wallet_id uuid not null,
  category_id uuid,
  day_of_month smallint not null check(day_of_month between 1 and 31),
  starts_on date not null default current_date,
  ends_on date,
  is_active boolean not null default true,
  last_processed_period date,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(workspace_id,wallet_id) references public.wallets(workspace_id,id),
  foreign key(workspace_id,category_id) references public.categories(workspace_id,id),
  check(ends_on is null or ends_on >= starts_on),
  unique(workspace_id,id)
);

create table public.recurring_executions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  recurring_transaction_id uuid not null,
  period_start date not null,
  transaction_id uuid not null,
  executed_at timestamptz not null default now(),
  foreign key(workspace_id,recurring_transaction_id) references public.recurring_transactions(workspace_id,id),
  foreign key(workspace_id,transaction_id) references public.transactions(workspace_id,id),
  unique(recurring_transaction_id,period_start)
);
create index recurring_due_idx on public.recurring_transactions(workspace_id,is_active,day_of_month);

-- Enable RLS on every new workspace-scoped table.
alter table public.budgets enable row level security;
alter table public.budget_categories enable row level security;
alter table public.goals enable row level security;
alter table public.goal_allocations enable row level security;
alter table public.investments enable row level security;
alter table public.investment_movements enable row level security;
alter table public.credit_cards enable row level security;
alter table public.installment_plans enable row level security;
alter table public.installments enable row level security;
alter table public.installment_payments enable row level security;
alter table public.debts enable row level security;
alter table public.debt_payments enable row level security;
alter table public.recurring_transactions enable row level security;
alter table public.recurring_executions enable row level security;

-- All active members can read these records; provisional editor role may mutate.
create policy "members read budgets" on public.budgets for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage budgets" on public.budgets for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read budget categories" on public.budget_categories for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage budget categories" on public.budget_categories for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

create policy "members read goals" on public.goals for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage goals" on public.goals for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read goal allocations" on public.goal_allocations for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage goal allocations" on public.goal_allocations for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

create policy "members read investments" on public.investments for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage investments" on public.investments for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read investment movements" on public.investment_movements for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage investment movements" on public.investment_movements for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

create policy "members read cards" on public.credit_cards for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage cards" on public.credit_cards for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read installment plans" on public.installment_plans for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage installment plans" on public.installment_plans for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read installments" on public.installments for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage installments" on public.installments for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read installment payments" on public.installment_payments for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage installment payments" on public.installment_payments for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

create policy "members read debts" on public.debts for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage debts" on public.debts for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read debt payments" on public.debt_payments for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage debt payments" on public.debt_payments for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

create policy "members read recurring definitions" on public.recurring_transactions for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage recurring definitions" on public.recurring_transactions for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));
create policy "members read recurring executions" on public.recurring_executions for select to authenticated using(public.is_workspace_member(workspace_id));
create policy "editors manage recurring executions" on public.recurring_executions for all to authenticated using(public.can_edit_workspace(workspace_id)) with check(public.can_edit_workspace(workspace_id));

-- Read-only direct access. Writes to financial feature tables will be moved behind
-- atomic SECURITY DEFINER RPCs, just like the core ledger.
grant select on public.budgets,public.budget_categories,public.goals,public.goal_allocations,
  public.investments,public.investment_movements,public.credit_cards,public.installment_plans,
  public.installments,public.installment_payments,public.debts,public.debt_payments,
  public.recurring_transactions,public.recurring_executions to authenticated;
