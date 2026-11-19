-- =============================================================================
-- NOUS Bookkeeping — Sprint 1 / Prompt 1
-- Foundation: organizations, memberships, US GAAP chart of accounts,
-- double-entry journal (immutable once posted), period lock and audit trail.
--
-- Money: BIGINT cents (1050 = $10.50). Never FLOAT.
-- Tenancy: every financial row carries organization_id and is protected by RLS.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Schemas
-- `private` holds helper functions used by RLS policies and triggers.
-- It is NOT exposed through the Supabase Data API.
-- -----------------------------------------------------------------------------
create schema if not exists private;
grant usage on schema private to authenticated;

-- -----------------------------------------------------------------------------
-- 1. Enums
-- -----------------------------------------------------------------------------
create type public.member_role as enum ('client_owner', 'accountant_admin');

create type public.legal_form as enum ('llc', 'corporation');

-- How the IRS taxes the entity (drives which return is due).
create type public.tax_classification as enum (
  'disregarded',   -- single-member LLC (5472 + pro forma 1120 if foreign-owned)
  'partnership',   -- multi-member LLC -> Form 1065
  's_corp',        -- Form 1120-S (no nonresident-alien shareholders allowed)
  'c_corp'         -- Form 1120 (+ 5472 if 25%+ foreign-owned)
);

create type public.accounting_basis as enum ('cash', 'accrual');

create type public.account_type as enum ('asset', 'liability', 'equity', 'revenue', 'expense');

create type public.account_subtype as enum (
  'cash', 'accounts_receivable', 'current_asset', 'fixed_asset', 'contra_asset', 'other_asset',
  'accounts_payable', 'credit_card', 'current_liability', 'long_term_liability',
  'equity', 'contra_equity', 'retained_earnings',
  'revenue', 'contra_revenue', 'other_income',
  'cogs', 'operating_expense', 'other_expense', 'income_tax'
);

create type public.normal_balance as enum ('debit', 'credit');

create type public.journal_status as enum ('draft', 'posted');

create type public.journal_source as enum (
  'manual', 'bank', 'invoice', 'adjustment', 'opening_balance', 'reversal', 'closing'
);

-- -----------------------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------------------
create table public.organizations (
  id                     uuid primary key default gen_random_uuid(),
  legal_name             text not null check (length(trim(legal_name)) > 0),
  dba_name               text,
  ein                    text check (ein ~ '^\d{2}-\d{7}$'),
  formation_state        char(2) check (formation_state ~ '^[A-Z]{2}$'),
  legal_form             public.legal_form not null default 'llc',
  tax_classification     public.tax_classification not null default 'disregarded',
  is_foreign_owned       boolean not null default true,  -- 25%+ owned by a foreign person
  accounting_basis       public.accounting_basis not null default 'cash',
  fiscal_year_end_month  smallint not null default 12 check (fiscal_year_end_month between 1 and 12),
  base_currency          char(3) not null default 'USD',
  default_locale         text not null default 'pt-BR' check (default_locale in ('pt-BR', 'en-US')),
  -- Month-end close: no posted entry may be dated on/before this date.
  books_locked_through   date,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_by             uuid,
  updated_at             timestamptz not null default now(),
  -- An LLC cannot be "disregarded" AND be a corporation, etc.
  constraint org_form_vs_classification check (
    (legal_form = 'corporation' and tax_classification in ('c_corp', 's_corp'))
    or legal_form = 'llc'
  )
);

create table public.organization_members (
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  role             public.member_role not null,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_by       uuid,
  updated_at       timestamptz not null default now(),
  primary key (organization_id, user_id)
);
create index organization_members_user_idx on public.organization_members (user_id);

-- Platform administrators (the firm running NOUS): see and manage every organization.
-- Subcontracted accountants are NOT here: they are organization_members with role
-- 'accountant_admin' only in the companies assigned to them.
-- Rows are managed only with the service role / SQL editor (no write policies).
create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  note       text,
  created_at timestamptz not null default now()
);

-- Global template (read-only for users), copied into each new organization.
create table public.chart_of_accounts_template (
  code            text primary key,
  name_en         text not null,
  name_pt         text not null,
  account_type    public.account_type not null,
  account_subtype public.account_subtype not null,
  normal_balance  public.normal_balance not null,
  tax_hint        text  -- e.g. '1099-NEC', '50% deductible', '5472-reportable'
);

create table public.chart_of_accounts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code            text not null check (code ~ '^\d{4,6}$'),
  name_en         text not null,
  name_pt         text not null,
  account_type    public.account_type not null,
  account_subtype public.account_subtype not null,
  normal_balance  public.normal_balance not null,
  parent_id       uuid,
  tax_hint        text,
  is_system       boolean not null default false,  -- seeded; cannot be deleted
  is_active       boolean not null default true,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_by      uuid,
  updated_at      timestamptz not null default now(),
  unique (organization_id, code),
  unique (organization_id, id),  -- target for composite FKs (same-tenant guarantee)
  foreign key (organization_id, parent_id)
    references public.chart_of_accounts (organization_id, id) on delete restrict
);

create table public.journal_entries (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete restrict,
  entry_number      bigint generated always as identity,
  entry_date        date not null,
  description       text not null check (length(trim(description)) > 0),
  source            public.journal_source not null default 'manual',
  source_ref        text,   -- e.g. bank_transactions.id / invoices.id (later sprints)
  status            public.journal_status not null default 'draft',
  reverses_entry_id uuid,
  posted_at         timestamptz,
  posted_by         uuid,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_by        uuid,
  updated_at        timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, reverses_entry_id)
    references public.journal_entries (organization_id, id) on delete restrict,
  constraint posted_has_stamp check (status <> 'posted' or posted_at is not null)
);
create index journal_entries_org_date_idx on public.journal_entries (organization_id, entry_date);
create index journal_entries_org_status_idx on public.journal_entries (organization_id, status);
-- An entry can be reversed only once.
create unique index journal_entries_one_reversal_idx
  on public.journal_entries (reverses_entry_id) where reverses_entry_id is not null;
-- Idempotency for automated sources (bank sync, invoices).
create unique index journal_entries_source_ref_idx
  on public.journal_entries (organization_id, source, source_ref) where source_ref is not null;

create table public.journal_lines (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null,
  journal_entry_id uuid not null,
  line_no          smallint not null default 1,
  account_id       uuid not null,
  debit_cents      bigint not null default 0 check (debit_cents >= 0),
  credit_cents     bigint not null default 0 check (credit_cents >= 0),
  memo             text,
  created_at       timestamptz not null default now(),
  -- exactly one side per line
  constraint one_side_only check ((debit_cents > 0) <> (credit_cents > 0)),
  -- line, entry and account must all belong to the same organization
  foreign key (organization_id, journal_entry_id)
    references public.journal_entries (organization_id, id) on delete cascade,
  foreign key (organization_id, account_id)
    references public.chart_of_accounts (organization_id, id) on delete restrict
);
create index journal_lines_entry_idx on public.journal_lines (journal_entry_id);
create index journal_lines_org_account_idx on public.journal_lines (organization_id, account_id);

create table public.audit_log (
  id              bigint generated always as identity primary key,
  organization_id uuid,
  table_name      text not null,
  record_id       text,
  action          text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data        jsonb,
  new_data        jsonb,
  actor           uuid,
  at              timestamptz not null default now()
);
create index audit_log_org_at_idx on public.audit_log (organization_id, at desc);
create index audit_log_record_idx on public.audit_log (table_name, record_id);

-- -----------------------------------------------------------------------------
-- 3. Helper functions (SECURITY DEFINER -> no RLS recursion)
-- -----------------------------------------------------------------------------
create or replace function private.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_admins a where a.user_id = (select auth.uid()));
$$;

-- Member of the organization, or platform admin.
create or replace function private.is_org_member(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = p_org and m.user_id = (select auth.uid())
  ) or private.is_platform_admin();
$$;

-- Has the given role in the organization. A platform admin counts as accountant_admin
-- everywhere (but never as client_owner).
create or replace function private.has_org_role(p_org uuid, p_role public.member_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.role = p_role
  ) or (p_role = 'accountant_admin' and private.is_platform_admin());
$$;

revoke all on function private.is_platform_admin() from public;
grant execute on function private.is_platform_admin() to authenticated;
revoke all on function private.is_org_member(uuid) from public;
revoke all on function private.has_org_role(uuid, public.member_role) from public;
grant execute on function private.is_org_member(uuid) to authenticated;
grant execute on function private.has_org_role(uuid, public.member_role) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Generic triggers: who/when stamps + audit trail
-- -----------------------------------------------------------------------------
create or replace function private.stamp_row()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce((select auth.uid()), new.created_by);
    new.created_at := now();
  end if;
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  new.updated_at := now();
  return new;
end $$;

create or replace function private.audit_row()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_rec jsonb := coalesce(v_new, v_old);
begin
  insert into public.audit_log (organization_id, table_name, record_id, action, old_data, new_data, actor)
  values (
    case when tg_table_name = 'organizations' then (v_rec->>'id')::uuid
         else (v_rec->>'organization_id')::uuid end,
    tg_table_name,
    coalesce(v_rec->>'id', v_rec->>'user_id'),
    tg_op, v_old, v_new, (select auth.uid())
  );
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['organizations', 'organization_members', 'chart_of_accounts', 'journal_entries'] loop
    execute format('create trigger %I before insert or update on public.%I
                    for each row execute function private.stamp_row()', t || '_stamp', t);
  end loop;
  foreach t in array array['organizations', 'organization_members', 'chart_of_accounts', 'journal_entries', 'journal_lines'] loop
    execute format('create trigger %I after insert or update or delete on public.%I
                    for each row execute function private.audit_row()', t || '_audit', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 5. Accounting integrity triggers
-- -----------------------------------------------------------------------------

-- 5a. Only accountant_admin may move the month-end lock (service role / migrations allowed).
create or replace function private.guard_books_lock()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.books_locked_through is distinct from old.books_locked_through
     and (select auth.uid()) is not null
     and not private.has_org_role(new.id, 'accountant_admin') then
    raise exception 'Only an accountant_admin can change the books lock date'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

create trigger organizations_guard_lock
  before update on public.organizations
  for each row execute function private.guard_books_lock();

-- 5b. Journal entry lifecycle: drafts are editable; posted entries are immutable.
create or replace function private.guard_journal_entry()
returns trigger language plpgsql set search_path = '' as $$
declare v_locked date;
begin
  if tg_op = 'DELETE' then
    if old.status = 'posted' then
      raise exception 'Posted journal entries cannot be deleted; post a reversing entry instead'
        using errcode = 'integrity_constraint_violation';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if old.status = 'posted' then
      raise exception 'Posted journal entries are immutable; post a reversing entry instead'
        using errcode = 'integrity_constraint_violation';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot change' using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  if new.status = 'posted' then
    -- Clients confirm and submit; only the accountant (or platform admin) posts to the ledger.
    -- Service role / backend jobs (auth.uid() is null) may post automated entries.
    if (select auth.uid()) is not null
       and not private.has_org_role(new.organization_id, 'accountant_admin') then
      raise exception 'Only an accountant can post journal entries; save it as a draft for review'
        using errcode = 'insufficient_privilege';
    end if;
    select o.books_locked_through into v_locked
      from public.organizations o where o.id = new.organization_id;
    if v_locked is not null and new.entry_date <= v_locked then
      raise exception 'Period is locked through %; cannot post an entry dated %', v_locked, new.entry_date
        using errcode = 'integrity_constraint_violation';
    end if;
    new.posted_at := now();
    new.posted_by := (select auth.uid());
  else
    new.posted_at := null;
    new.posted_by := null;
  end if;
  return new;
end $$;

create trigger journal_entries_guard
  before insert or update or delete on public.journal_entries
  for each row execute function private.guard_journal_entry();

-- 5c. Lines of a posted entry cannot be touched.
create or replace function private.guard_journal_line()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and exists (
       select 1 from public.journal_entries e where e.id = old.journal_entry_id and e.status = 'posted') then
    raise exception 'Lines of a posted journal entry are immutable'
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and exists (
       select 1 from public.journal_entries e where e.id = new.journal_entry_id and e.status = 'posted') then
    raise exception 'Cannot add or move lines into a posted journal entry'
      using errcode = 'integrity_constraint_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger journal_lines_guard
  before insert or update or delete on public.journal_lines
  for each row execute function private.guard_journal_line();

-- 5d. Balance check: a posted entry needs >= 2 lines and SUM(debit) = SUM(credit) > 0.
-- DEFERRABLE INITIALLY DEFERRED so lines can be inserted one by one inside a transaction.
create or replace function private.assert_entry_balanced(p_entry uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_status public.journal_status; v_d bigint; v_c bigint; v_n int;
begin
  select status into v_status from public.journal_entries where id = p_entry;
  if v_status is distinct from 'posted' then return; end if;

  select coalesce(sum(debit_cents), 0), coalesce(sum(credit_cents), 0), count(*)
    into v_d, v_c, v_n
    from public.journal_lines where journal_entry_id = p_entry;

  if v_n < 2 or v_d <> v_c or v_d = 0 then
    raise exception 'Unbalanced journal entry %: debits % / credits % / lines %', p_entry, v_d, v_c, v_n
      using errcode = 'check_violation';
  end if;
end $$;

create or replace function private.check_balance_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'journal_entries' then
    perform private.assert_entry_balanced(new.id);
  elsif tg_op = 'DELETE' then
    perform private.assert_entry_balanced(old.journal_entry_id);
  else
    perform private.assert_entry_balanced(new.journal_entry_id);
    if tg_op = 'UPDATE' and old.journal_entry_id <> new.journal_entry_id then
      perform private.assert_entry_balanced(old.journal_entry_id);
    end if;
  end if;
  return null;
end $$;

create constraint trigger journal_entries_balanced
  after insert or update on public.journal_entries
  deferrable initially deferred
  for each row execute function private.check_balance_trigger();

create constraint trigger journal_lines_balanced
  after insert or update or delete on public.journal_lines
  deferrable initially deferred
  for each row execute function private.check_balance_trigger();

-- -----------------------------------------------------------------------------
-- 6. Row Level Security
-- -----------------------------------------------------------------------------
alter table public.organizations              enable row level security;
alter table public.organization_members       enable row level security;
alter table public.platform_admins            enable row level security;
alter table public.chart_of_accounts_template enable row level security;
alter table public.chart_of_accounts          enable row level security;
alter table public.journal_entries            enable row level security;
alter table public.journal_lines              enable row level security;
alter table public.audit_log                  enable row level security;

-- Defense in depth: anonymous users get nothing at all.
revoke all on public.platform_admins from anon;
revoke insert, update, delete on public.platform_admins from authenticated;
revoke all on public.organizations, public.organization_members, public.chart_of_accounts_template,
              public.chart_of_accounts, public.journal_entries, public.journal_lines, public.audit_log
  from anon;
-- Audit log is written only by triggers.
revoke insert, update, delete on public.audit_log from authenticated;
revoke insert, update, delete on public.chart_of_accounts_template from authenticated;

-- organizations: members read; owners/accountants edit; creation only via create_organization().
create policy org_select on public.organizations for select to authenticated
  using (private.is_org_member(id));
create policy org_update on public.organizations for update to authenticated
  using (private.is_org_member(id)) with check (private.is_org_member(id));

-- platform_admins: a user can only see whether they themselves are admin (for the UI).
create policy platform_admins_select_self on public.platform_admins for select to authenticated
  using (user_id = (select auth.uid()));

-- memberships: members see their org's roster.
-- client_owner manages other client_owners; only the platform admin assigns/removes accountants.
create policy members_select on public.organization_members for select to authenticated
  using (private.is_org_member(organization_id));
create policy members_insert on public.organization_members for insert to authenticated
  with check (private.is_platform_admin()
              or (role = 'client_owner' and private.has_org_role(organization_id, 'client_owner')));
create policy members_update on public.organization_members for update to authenticated
  using (private.is_platform_admin()
         or (role = 'client_owner' and private.has_org_role(organization_id, 'client_owner')))
  with check (private.is_platform_admin()
              or (role = 'client_owner' and private.has_org_role(organization_id, 'client_owner')));
create policy members_delete on public.organization_members for delete to authenticated
  using (private.is_platform_admin()
         or (role = 'client_owner' and private.has_org_role(organization_id, 'client_owner')));

-- template: any signed-in user may read.
create policy coa_template_select on public.chart_of_accounts_template for select to authenticated
  using (true);

-- chart of accounts: members read; only accountant_admin edits.
create policy coa_select on public.chart_of_accounts for select to authenticated
  using (private.is_org_member(organization_id));
create policy coa_insert on public.chart_of_accounts for insert to authenticated
  with check (private.has_org_role(organization_id, 'accountant_admin'));
create policy coa_update on public.chart_of_accounts for update to authenticated
  using (private.has_org_role(organization_id, 'accountant_admin'))
  with check (private.has_org_role(organization_id, 'accountant_admin'));
create policy coa_delete on public.chart_of_accounts for delete to authenticated
  using (private.has_org_role(organization_id, 'accountant_admin') and not is_system);

-- journal: any member works on drafts / posts; triggers enforce immutability and balance.
create policy je_select on public.journal_entries for select to authenticated
  using (private.is_org_member(organization_id));
create policy je_insert on public.journal_entries for insert to authenticated
  with check (private.is_org_member(organization_id));
create policy je_update on public.journal_entries for update to authenticated
  using (private.is_org_member(organization_id)) with check (private.is_org_member(organization_id));
create policy je_delete on public.journal_entries for delete to authenticated
  using (private.is_org_member(organization_id));

create policy jl_select on public.journal_lines for select to authenticated
  using (private.is_org_member(organization_id));
create policy jl_insert on public.journal_lines for insert to authenticated
  with check (private.is_org_member(organization_id));
create policy jl_update on public.journal_lines for update to authenticated
  using (private.is_org_member(organization_id)) with check (private.is_org_member(organization_id));
create policy jl_delete on public.journal_lines for delete to authenticated
  using (private.is_org_member(organization_id));

create policy audit_select on public.audit_log for select to authenticated
  using (organization_id is not null and private.is_org_member(organization_id));

-- -----------------------------------------------------------------------------
-- 7. US GAAP chart of accounts template (EN / PT-BR)
-- -----------------------------------------------------------------------------
insert into public.chart_of_accounts_template
  (code, name_en, name_pt, account_type, account_subtype, normal_balance, tax_hint) values
  -- Assets
  ('1010', 'Checking Account',                 'Conta Corrente',                        'asset', 'cash',                'debit',  null),
  ('1020', 'Savings Account',                  'Conta Poupança',                        'asset', 'cash',                'debit',  null),
  ('1050', 'Petty Cash',                       'Caixa Pequeno',                         'asset', 'cash',                'debit',  null),
  ('1090', 'Undeposited Funds',                'Valores a Depositar',                   'asset', 'current_asset',       'debit',  null),
  ('1100', 'Accounts Receivable',              'Contas a Receber',                      'asset', 'accounts_receivable', 'debit',  null),
  ('1150', 'Allowance for Doubtful Accounts',  'Provisão para Devedores Duvidosos',     'asset', 'contra_asset',        'credit', null),
  ('1200', 'Inventory',                        'Estoque',                               'asset', 'current_asset',       'debit',  null),
  ('1300', 'Prepaid Expenses',                 'Despesas Antecipadas',                  'asset', 'current_asset',       'debit',  null),
  ('1400', 'Due from Owner / Related Party',   'Valores a Receber do Sócio / Parte Relacionada', 'asset', 'current_asset', 'debit', '5472-reportable'),
  ('1500', 'Furniture & Equipment',            'Móveis e Equipamentos',                 'asset', 'fixed_asset',         'debit',  null),
  ('1510', 'Computer Equipment',               'Equipamentos de Informática',           'asset', 'fixed_asset',         'debit',  null),
  ('1520', 'Vehicles',                         'Veículos',                              'asset', 'fixed_asset',         'debit',  null),
  ('1530', 'Leasehold Improvements',           'Benfeitorias em Imóveis de Terceiros',  'asset', 'fixed_asset',         'debit',  null),
  ('1590', 'Accumulated Depreciation',         'Depreciação Acumulada',                 'asset', 'contra_asset',        'credit', null),
  ('1700', 'Security Deposits',                'Depósitos Caução',                      'asset', 'other_asset',         'debit',  null),
  -- Liabilities
  ('2000', 'Accounts Payable',                 'Contas a Pagar',                        'liability', 'accounts_payable',    'credit', null),
  ('2100', 'Credit Card Payable',              'Cartão de Crédito a Pagar',             'liability', 'credit_card',         'credit', null),
  ('2200', 'Accrued Liabilities',              'Despesas Provisionadas',                'liability', 'current_liability',   'credit', null),
  ('2250', 'Payroll Liabilities',              'Encargos de Folha a Recolher',          'liability', 'current_liability',   'credit', null),
  ('2300', 'Sales Tax Payable',                'Sales Tax a Recolher',                  'liability', 'current_liability',   'credit', null),
  ('2400', 'Unearned Revenue',                 'Receita Diferida (Adiantamentos de Clientes)', 'liability', 'current_liability', 'credit', null),
  ('2500', 'Short-Term Loans',                 'Empréstimos de Curto Prazo',            'liability', 'current_liability',   'credit', null),
  ('2600', 'Loan from Owner / Related Party',  'Empréstimo do Sócio / Parte Relacionada', 'liability', 'long_term_liability', 'credit', '5472-reportable'),
  ('2700', 'Long-Term Debt',                   'Empréstimos de Longo Prazo',            'liability', 'long_term_liability', 'credit', null),
  -- Equity
  ('3000', 'Owner''s Capital / Common Stock',  'Capital Social',                        'equity', 'equity',            'credit', null),
  ('3100', 'Owner Contributions',              'Aportes do Sócio',                      'equity', 'equity',            'credit', '5472-reportable'),
  ('3200', 'Owner Draws / Distributions',      'Retiradas / Distribuições ao Sócio',    'equity', 'contra_equity',     'debit',  '5472-reportable'),
  ('3800', 'Opening Balance Equity',           'Patrimônio de Saldos Iniciais',         'equity', 'equity',            'credit', null),
  ('3900', 'Retained Earnings',                'Lucros Acumulados',                     'equity', 'retained_earnings', 'credit', null),
  -- Revenue
  ('4000', 'Sales Revenue',                    'Receita de Vendas',                     'revenue', 'revenue',        'credit', null),
  ('4100', 'Service Revenue',                  'Receita de Serviços',                   'revenue', 'revenue',        'credit', null),
  ('4900', 'Sales Returns & Discounts',        'Devoluções e Descontos sobre Vendas',   'revenue', 'contra_revenue', 'debit',  null),
  -- Cost of goods sold
  ('5000', 'Cost of Goods Sold',               'Custo das Mercadorias Vendidas',        'expense', 'cogs', 'debit', null),
  ('5100', 'Subcontractors - COGS',            'Subcontratados - Custo',                'expense', 'cogs', 'debit', '1099-NEC'),
  ('5200', 'Freight & Shipping - COGS',        'Fretes - Custo',                        'expense', 'cogs', 'debit', null),
  ('5300', 'Merchant Processing Fees',         'Taxas de Processamento de Pagamentos',  'expense', 'cogs', 'debit', null),
  -- Operating expenses
  ('6000', 'Advertising & Marketing',          'Publicidade e Marketing',               'expense', 'operating_expense', 'debit', null),
  ('6050', 'Bank Fees & Service Charges',      'Tarifas Bancárias',                     'expense', 'operating_expense', 'debit', null),
  ('6100', 'Contract Labor',                   'Prestadores de Serviço (Contractors)',  'expense', 'operating_expense', 'debit', '1099-NEC'),
  ('6150', 'Dues & Subscriptions',             'Associações e Assinaturas',             'expense', 'operating_expense', 'debit', null),
  ('6200', 'Insurance',                        'Seguros',                               'expense', 'operating_expense', 'debit', null),
  ('6250', 'Legal & Professional Fees',        'Honorários Jurídicos e Contábeis',      'expense', 'operating_expense', 'debit', '1099-NEC'),
  ('6300', 'Meals',                            'Refeições',                             'expense', 'operating_expense', 'debit', '50% deductible'),
  ('6350', 'Office Supplies',                  'Material de Escritório',                'expense', 'operating_expense', 'debit', null),
  ('6400', 'Rent & Lease',                     'Aluguel',                               'expense', 'operating_expense', 'debit', '1099-MISC'),
  ('6450', 'Repairs & Maintenance',            'Reparos e Manutenção',                  'expense', 'operating_expense', 'debit', null),
  ('6500', 'Salaries & Wages',                 'Salários e Ordenados',                  'expense', 'operating_expense', 'debit', 'W-2'),
  ('6550', 'Payroll Taxes',                    'Impostos sobre Folha',                  'expense', 'operating_expense', 'debit', null),
  ('6600', 'Software & SaaS',                  'Software e Assinaturas SaaS',           'expense', 'operating_expense', 'debit', null),
  ('6650', 'Telephone & Internet',             'Telefone e Internet',                   'expense', 'operating_expense', 'debit', null),
  ('6700', 'Travel',                           'Viagens',                               'expense', 'operating_expense', 'debit', null),
  ('6750', 'Utilities',                        'Água, Luz e Gás',                       'expense', 'operating_expense', 'debit', null),
  ('6800', 'Vehicle Expenses',                 'Despesas com Veículos',                 'expense', 'operating_expense', 'debit', null),
  ('6850', 'Depreciation Expense',             'Despesa de Depreciação',                'expense', 'operating_expense', 'debit', null),
  ('6900', 'Taxes & Licenses',                 'Taxas e Licenças (Estaduais/Municipais)', 'expense', 'operating_expense', 'debit', null),
  ('6950', 'Training & Education',             'Treinamento e Capacitação',             'expense', 'operating_expense', 'debit', null),
  -- Other income / expense
  ('7000', 'Interest Income',                  'Receitas Financeiras (Juros)',          'revenue', 'other_income',  'credit', null),
  ('7100', 'Other Income',                     'Outras Receitas',                       'revenue', 'other_income',  'credit', null),
  ('7200', 'Foreign Exchange Gain/Loss',       'Variação Cambial',                      'expense', 'other_expense', 'debit',  null),
  ('8000', 'Interest Expense',                 'Despesas Financeiras (Juros)',          'expense', 'other_expense', 'debit',  null),
  ('8100', 'Income Tax Expense',               'Imposto de Renda (Federal/Estadual)',   'expense', 'income_tax',    'debit',  null);

create or replace function private.seed_chart_of_accounts(p_org uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.chart_of_accounts
    (organization_id, code, name_en, name_pt, account_type, account_subtype, normal_balance, tax_hint, is_system)
  select p_org, t.code, t.name_en, t.name_pt, t.account_type, t.account_subtype, t.normal_balance, t.tax_hint, true
  from public.chart_of_accounts_template t
  on conflict (organization_id, code) do nothing;
$$;
revoke all on function private.seed_chart_of_accounts(uuid) from public;

-- -----------------------------------------------------------------------------
-- 8. RPCs for the app
-- -----------------------------------------------------------------------------

-- Creates an organization and seeds the COA, atomically. A client signing up becomes its
-- client_owner; a platform admin onboarding a client does not become a member (sees it anyway).
create or replace function public.create_organization(
  p_legal_name         text,
  p_ein                text default null,
  p_formation_state    text default null,
  p_legal_form         public.legal_form default 'llc',
  p_tax_classification public.tax_classification default 'disregarded',
  p_is_foreign_owned   boolean default true,
  p_accounting_basis   public.accounting_basis default 'cash',
  p_default_locale     text default 'pt-BR'
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_org uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'insufficient_privilege';
  end if;

  insert into public.organizations
    (legal_name, ein, formation_state, legal_form, tax_classification, is_foreign_owned,
     accounting_basis, default_locale)
  values
    (p_legal_name, nullif(p_ein, ''), upper(nullif(p_formation_state, '')), p_legal_form,
     p_tax_classification, p_is_foreign_owned, p_accounting_basis, p_default_locale)
  returning id into v_org;

  if not private.is_platform_admin() then
    insert into public.organization_members (organization_id, user_id, role)
    values (v_org, v_uid, 'client_owner');
  end if;

  perform private.seed_chart_of_accounts(v_org);
  return v_org;
end $$;
revoke all on function public.create_organization from public, anon;
grant execute on function public.create_organization to authenticated;

-- Creates (and by default posts) a balanced entry in one transaction.
-- p_lines: [{"account_id": "...", "debit_cents": 1050, "credit_cents": 0, "memo": "..."}]
-- SECURITY INVOKER: the caller's RLS applies.
create or replace function public.create_journal_entry(
  p_organization_id uuid,
  p_entry_date      date,
  p_description     text,
  p_lines           jsonb,
  p_post            boolean default true,
  p_source          public.journal_source default 'manual',
  p_source_ref      text default null
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_entry uuid; v_line jsonb; v_no smallint := 0;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal entry needs at least two lines' using errcode = 'check_violation';
  end if;

  insert into public.journal_entries (organization_id, entry_date, description, source, source_ref)
  values (p_organization_id, p_entry_date, p_description, p_source, p_source_ref)
  returning id into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into public.journal_lines
      (organization_id, journal_entry_id, line_no, account_id, debit_cents, credit_cents, memo)
    values
      (p_organization_id, v_entry, v_no, (v_line->>'account_id')::uuid,
       coalesce((v_line->>'debit_cents')::bigint, 0), coalesce((v_line->>'credit_cents')::bigint, 0),
       v_line->>'memo');
  end loop;

  if p_post then
    update public.journal_entries set status = 'posted' where id = v_entry;
    perform private.assert_entry_balanced(v_entry);  -- fail fast with a clear message
  end if;
  return v_entry;
end $$;
revoke all on function public.create_journal_entry from public, anon;
grant execute on function public.create_journal_entry to authenticated;

-- Posts a reversing entry (debits <-> credits). The only way to "undo" a posted entry.
create or replace function public.reverse_journal_entry(
  p_entry_id   uuid,
  p_entry_date date default current_date,
  p_reason     text default null
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_orig public.journal_entries; v_new uuid;
begin
  select * into v_orig from public.journal_entries where id = p_entry_id;
  if not found then
    raise exception 'Journal entry % not found', p_entry_id using errcode = 'no_data_found';
  end if;
  if v_orig.status <> 'posted' then
    raise exception 'Only posted entries can be reversed; delete the draft instead';
  end if;

  insert into public.journal_entries
    (organization_id, entry_date, description, source, reverses_entry_id)
  values
    (v_orig.organization_id, p_entry_date,
     'Reversal of #' || v_orig.entry_number || coalesce(' - ' || p_reason, ''),
     'reversal', v_orig.id)
  returning id into v_new;

  insert into public.journal_lines
    (organization_id, journal_entry_id, line_no, account_id, debit_cents, credit_cents, memo)
  select organization_id, v_new, line_no, account_id, credit_cents, debit_cents, memo
  from public.journal_lines where journal_entry_id = v_orig.id;

  update public.journal_entries set status = 'posted' where id = v_new;
  return v_new;
end $$;
revoke all on function public.reverse_journal_entry from public, anon;
grant execute on function public.reverse_journal_entry to authenticated;

-- Trial balance (signed by normal balance) — useful for checks and the first reports.
create or replace view public.v_trial_balance with (security_invoker = true) as
select a.organization_id, a.id as account_id, a.code, a.name_en, a.name_pt,
       a.account_type, a.account_subtype, a.normal_balance,
       coalesce(sum(l.debit_cents), 0)  as debit_cents,
       coalesce(sum(l.credit_cents), 0) as credit_cents,
       case when a.normal_balance = 'debit'
            then coalesce(sum(l.debit_cents), 0) - coalesce(sum(l.credit_cents), 0)
            else coalesce(sum(l.credit_cents), 0) - coalesce(sum(l.debit_cents), 0) end as balance_cents
from public.chart_of_accounts a
left join public.journal_lines l on l.account_id = a.id
  and exists (select 1 from public.journal_entries e where e.id = l.journal_entry_id and e.status = 'posted')
group by a.id;
revoke all on public.v_trial_balance from anon;
