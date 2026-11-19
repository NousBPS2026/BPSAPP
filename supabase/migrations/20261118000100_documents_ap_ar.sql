-- =============================================================================
-- NOUS Bookkeeping — documents, AI extraction, AP/AR, contacts, cost centers
--
-- Flow:
--   1. Client uploads a document (bill, invoice, receipt) -> documents (status 'uploaded').
--   2. AI Edge Function (service role) reads it, fills documents.ai_extraction and creates
--      an open_items draft (payable = AP, receivable = AR), suggesting contact, category
--      (account) and cost center. If the document looks already paid/received, it flags
--      ai_detected_paid so the bank-match suggestion is shown next to the statement (Sprint 2).
--   3. Client reviews: fills category / cost center, creates the vendor/customer if missing,
--      and submits -> 'pending_review'.
--   4. Accountant approves -> 'open' (or 'paid' when matched to the bank), which posts the
--      journal entry. Clients never post to the ledger.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Enums
-- -----------------------------------------------------------------------------
create type public.contact_kind as enum ('vendor', 'customer', 'both');
create type public.document_type as enum ('bill', 'invoice', 'receipt', 'bank_statement', 'other');
create type public.document_status as enum ('uploaded', 'processing', 'extracted', 'failed', 'linked', 'archived');
create type public.open_item_direction as enum ('payable', 'receivable');
create type public.open_item_status as enum (
  'draft',            -- created by AI or by the user, still being filled
  'pending_client',   -- AI needs the client to confirm or complete fields
  'pending_review',   -- client submitted; waiting for the accountant
  'open',             -- approved; AP/AR outstanding
  'paid',             -- settled (matched to a bank transaction)
  'void'
);

-- -----------------------------------------------------------------------------
-- 2. Cost centers
-- -----------------------------------------------------------------------------
create table public.cost_centers (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code            text not null,
  name            text not null,
  is_active       boolean not null default true,
  created_by      uuid, created_at timestamptz not null default now(),
  updated_by      uuid, updated_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (organization_id, id)
);

-- Cost center on ledger lines (optional).
alter table public.journal_lines add column cost_center_id uuid;
alter table public.journal_lines add constraint journal_lines_cost_center_fkey
  foreign key (organization_id, cost_center_id)
  references public.cost_centers (organization_id, id) on delete restrict;
-- MATCH SIMPLE: a NULL cost_center_id skips the FK check, as intended.

-- -----------------------------------------------------------------------------
-- 3. Contacts (vendors / customers)
-- -----------------------------------------------------------------------------
create table public.contacts (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations(id) on delete restrict,
  kind               public.contact_kind not null,
  display_name       text not null check (length(trim(display_name)) > 0),
  legal_name         text,
  email              text,
  phone              text,
  country            char(2) not null default 'US',
  address            jsonb,
  -- Only the last 4 digits live here. Full TIN (EIN/SSN/ITIN) goes to Vault later.
  tin_last4          char(4) check (tin_last4 ~ '^\d{4}$'),
  is_1099_eligible   boolean not null default false,
  w9_received_at     date,
  default_account_id uuid,
  default_cost_center_id uuid,
  is_active          boolean not null default true,
  created_by uuid, created_at timestamptz not null default now(),
  updated_by uuid, updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, default_account_id)
    references public.chart_of_accounts (organization_id, id) on delete restrict,
  foreign key (organization_id, default_cost_center_id)
    references public.cost_centers (organization_id, id) on delete restrict
);
create index contacts_org_name_idx on public.contacts (organization_id, lower(display_name));

-- -----------------------------------------------------------------------------
-- 4. Documents (files live in the private Storage bucket 'documents',
--    path: <organization_id>/<document_id>/<file name>)
-- -----------------------------------------------------------------------------
create table public.documents (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete restrict,
  storage_path     text not null unique,
  file_name        text not null,
  mime_type        text,
  size_bytes       bigint,
  sha256           text,   -- duplicate upload detection
  doc_type         public.document_type,           -- AI guess, user can correct
  status           public.document_status not null default 'uploaded',
  ai_extraction    jsonb,  -- raw structured output from the AI (vendor, dates, totals, lines)
  ai_confidence    numeric(4,3) check (ai_confidence between 0 and 1),
  ai_model         text,
  ai_processed_at  timestamptz,
  ai_error         text,
  created_by uuid, created_at timestamptz not null default now(),
  updated_by uuid, updated_at timestamptz not null default now(),
  unique (organization_id, id),
  constraint storage_path_in_org check (storage_path like organization_id::text || '/%')
);
create index documents_org_status_idx on public.documents (organization_id, status);
create unique index documents_org_sha_idx on public.documents (organization_id, sha256) where sha256 is not null;

-- -----------------------------------------------------------------------------
-- 5. Open items: AP (payable) and AR (receivable)
-- -----------------------------------------------------------------------------
create table public.open_items (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete restrict,
  direction           public.open_item_direction not null,
  status              public.open_item_status not null default 'draft',
  contact_id          uuid,
  document_id         uuid,
  reference_number    text,          -- vendor invoice # / our invoice #
  issue_date          date,
  due_date            date,
  currency            char(3) not null default 'USD',
  total_cents         bigint not null default 0 check (total_cents >= 0),
  description         text,
  created_by_ai       boolean not null default false,
  ai_detected_paid    boolean not null default false,  -- doc shows "PAID" / receipt
  ai_suggested_paid_on date,
  paid_on             date,
  bank_transaction_id uuid,          -- FK added in Sprint 2 (bank_transactions)
  journal_entry_id    uuid,          -- accrual recognition entry
  payment_entry_id    uuid,          -- settlement entry
  submitted_at        timestamptz,
  submitted_by        uuid,
  approved_at         timestamptz,
  approved_by         uuid,
  created_by uuid, created_at timestamptz not null default now(),
  updated_by uuid, updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, contact_id)  references public.contacts (organization_id, id) on delete restrict,
  foreign key (organization_id, document_id) references public.documents (organization_id, id) on delete restrict,
  foreign key (organization_id, journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict,
  foreign key (organization_id, payment_entry_id) references public.journal_entries (organization_id, id) on delete restrict,
  constraint due_after_issue check (due_date is null or issue_date is null or due_date >= issue_date),
  -- Nothing leaves the client's hands without the minimum fields.
  constraint submitted_is_complete check (
    status in ('draft', 'pending_client', 'void')
    or (contact_id is not null and issue_date is not null and total_cents > 0)
  )
);
create index open_items_org_status_idx on public.open_items (organization_id, status);
create index open_items_org_due_idx on public.open_items (organization_id, direction, due_date);
create unique index open_items_vendor_ref_idx
  on public.open_items (organization_id, direction, contact_id, reference_number)
  where reference_number is not null and status <> 'void';

create table public.open_item_lines (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  open_item_id    uuid not null,
  line_no         smallint not null default 1,
  description     text,
  account_id      uuid,          -- expense / revenue category (null while draft)
  cost_center_id  uuid,
  amount_cents    bigint not null check (amount_cents > 0),
  ai_suggested    boolean not null default false,
  foreign key (organization_id, open_item_id) references public.open_items (organization_id, id) on delete cascade,
  foreign key (organization_id, account_id) references public.chart_of_accounts (organization_id, id) on delete restrict,
  foreign key (organization_id, cost_center_id) references public.cost_centers (organization_id, id) on delete restrict
);
create index open_item_lines_item_idx on public.open_item_lines (open_item_id);

-- -----------------------------------------------------------------------------
-- 6. Triggers
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['cost_centers', 'contacts', 'documents', 'open_items'] loop
    execute format('create trigger %I before insert or update on public.%I
                    for each row execute function private.stamp_row()', t || '_stamp', t);
  end loop;
  foreach t in array array['cost_centers', 'contacts', 'documents', 'open_items', 'open_item_lines'] loop
    execute format('create trigger %I after insert or update or delete on public.%I
                    for each row execute function private.audit_row()', t || '_audit', t);
  end loop;
end $$;

-- Workflow guard: clients may only work in draft / pending_client and submit to pending_review.
-- Approval, payment and void are accountant decisions. Approved items are frozen for clients.
create or replace function private.guard_open_item()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_is_acct boolean := (select auth.uid()) is null   -- service role / backend
                       or private.has_org_role(coalesce(new.organization_id, old.organization_id), 'accountant_admin');
  v_client_states public.open_item_status[] := array['draft', 'pending_client', 'pending_review']::public.open_item_status[];
begin
  if tg_op = 'DELETE' then
    if not v_is_acct and old.status <> all (array['draft', 'pending_client']::public.open_item_status[]) then
      raise exception 'Only drafts can be deleted by the client' using errcode = 'insufficient_privilege';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and new.organization_id <> old.organization_id then
    raise exception 'organization_id cannot change' using errcode = 'integrity_constraint_violation';
  end if;

  if not v_is_acct then
    if new.status <> all (v_client_states)
       or (tg_op = 'UPDATE' and old.status <> all (v_client_states)) then
      raise exception 'Status % can only be set by an accountant', new.status
        using errcode = 'insufficient_privilege';
    end if;
    -- once submitted, the client can only pull it back to draft, not edit it in place
    if tg_op = 'UPDATE' and old.status = 'pending_review' and new.status = 'pending_review' then
      raise exception 'Item is under review; move it back to draft to edit'
        using errcode = 'insufficient_privilege';
    end if;
    new.approved_at := case when tg_op = 'UPDATE' then old.approved_at end;
    new.approved_by := case when tg_op = 'UPDATE' then old.approved_by end;
  end if;

  if new.status = 'pending_review' and (tg_op = 'INSERT' or old.status <> 'pending_review') then
    new.submitted_at := now();
    new.submitted_by := (select auth.uid());
  end if;
  if new.status in ('open', 'paid') and (tg_op = 'INSERT' or old.status not in ('open', 'paid')) then
    new.approved_at := now();
    new.approved_by := (select auth.uid());
  end if;
  return new;
end $$;

create trigger open_items_guard
  before insert or update or delete on public.open_items
  for each row execute function private.guard_open_item();

-- Lines follow the parent: clients edit lines only while the item is in draft / pending_client.
create or replace function private.guard_open_item_line()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid := coalesce(new.organization_id, old.organization_id);
        v_item uuid := coalesce(new.open_item_id, old.open_item_id);
        v_status public.open_item_status;
begin
  select status into v_status from public.open_items where id = v_item;
  if v_status is not null
     and v_status not in ('draft', 'pending_client')
     and (select auth.uid()) is not null
     and not private.has_org_role(v_org, 'accountant_admin') then
    raise exception 'Lines can only be edited while the item is a draft' using errcode = 'insufficient_privilege';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger open_item_lines_guard
  before insert or update or delete on public.open_item_lines
  for each row execute function private.guard_open_item_line();

-- Leaving the client's hands requires every line categorized and lines = total.
create or replace function private.assert_open_item_ready(p_item uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_item public.open_items; v_sum bigint; v_uncat int; v_n int;
begin
  select * into v_item from public.open_items where id = p_item;
  if not found or v_item.status in ('draft', 'pending_client', 'void') then return; end if;
  select coalesce(sum(amount_cents), 0), count(*) filter (where account_id is null), count(*)
    into v_sum, v_uncat, v_n
    from public.open_item_lines where open_item_id = p_item;
  if v_n = 0 or v_uncat > 0 or v_sum <> v_item.total_cents then
    raise exception 'Item % is incomplete: % lines, % uncategorized, lines total % vs document total %',
      p_item, v_n, v_uncat, v_sum, v_item.total_cents using errcode = 'check_violation';
  end if;
end $$;

create or replace function private.check_open_item_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'open_items' then
    perform private.assert_open_item_ready(new.id);
  else
    perform private.assert_open_item_ready(coalesce(new.open_item_id, old.open_item_id));
  end if;
  return null;
end $$;

create constraint trigger open_items_ready
  after insert or update on public.open_items
  deferrable initially deferred for each row execute function private.check_open_item_trigger();
create constraint trigger open_item_lines_ready
  after insert or update or delete on public.open_item_lines
  deferrable initially deferred for each row execute function private.check_open_item_trigger();

-- -----------------------------------------------------------------------------
-- 7. RLS
-- -----------------------------------------------------------------------------
alter table public.cost_centers    enable row level security;
alter table public.contacts        enable row level security;
alter table public.documents       enable row level security;
alter table public.open_items      enable row level security;
alter table public.open_item_lines enable row level security;

revoke all on public.cost_centers, public.contacts, public.documents, public.open_items, public.open_item_lines from anon;

-- Members (client, assigned accountant, platform admin) can read and work on these;
-- the triggers above decide which status changes each role may make.
do $$
declare t text;
begin
  foreach t in array array['cost_centers', 'contacts', 'documents', 'open_items', 'open_item_lines'] loop
    execute format('create policy %I on public.%I for select to authenticated using (private.is_org_member(organization_id))', t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.is_org_member(organization_id))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.is_org_member(organization_id)) with check (private.is_org_member(organization_id))', t || '_update', t);
  end loop;
end $$;

-- Deletes: drafts by members (trigger-guarded); master data and documents by accountants only.
create policy open_items_delete on public.open_items for delete to authenticated
  using (private.is_org_member(organization_id));
create policy open_item_lines_delete on public.open_item_lines for delete to authenticated
  using (private.is_org_member(organization_id));
create policy cost_centers_delete on public.cost_centers for delete to authenticated
  using (private.has_org_role(organization_id, 'accountant_admin'));
create policy contacts_delete on public.contacts for delete to authenticated
  using (private.has_org_role(organization_id, 'accountant_admin'));
create policy documents_delete on public.documents for delete to authenticated
  using (private.has_org_role(organization_id, 'accountant_admin'));

-- -----------------------------------------------------------------------------
-- 8. Storage bucket (private) — path must start with the organization id
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 20971520,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/webp'])
on conflict (id) do nothing;

-- Safe parser: returns NULL instead of raising when the first folder is not a UUID.
create or replace function private.storage_org_id(p_name text)
returns uuid language sql immutable set search_path = '' as $$
  select case when split_part(p_name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_name, '/', 1)::uuid end;
$$;
grant execute on function private.storage_org_id(text) to authenticated;

create policy documents_bucket_select on storage.objects for select to authenticated
  using (bucket_id = 'documents'
         and private.is_org_member(private.storage_org_id(name)));
create policy documents_bucket_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents'
              and private.is_org_member(private.storage_org_id(name)));
create policy documents_bucket_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents'
         and private.has_org_role(private.storage_org_id(name), 'accountant_admin'));
