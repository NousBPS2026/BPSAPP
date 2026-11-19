-- Smoke test for the Sprint 1 migrations (foundation + documents/AP/AR).
-- RUN ONLY AGAINST A LOCAL DATABASE (supabase start), never production:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/foundation_smoke.sql
-- Everything runs inside a transaction that is rolled back at the end.
begin;

-- Users: A and B are clients of different companies, C is a subcontracted accountant
-- assigned only to A, D is the platform admin.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner-a@test.local'),
  ('00000000-0000-0000-0000-00000000000b', 'owner-b@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'accountant@test.local'),
  ('00000000-0000-0000-0000-00000000000d', 'admin@test.local');
insert into public.platform_admins (user_id, note) values ('00000000-0000-0000-0000-00000000000d', 'test admin');

create temp table t_ctx (k text primary key, v uuid);
grant all on t_ctx to authenticated;

create function pg_temp.ctx(p_k text) returns uuid language sql as $$ select v from t_ctx where k = p_k $$;
grant execute on function pg_temp.ctx(text) to authenticated;

create function pg_temp.expect_fail(p_sql text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'PASS (blocked as expected): % -> %', p_label, sqlerrm;
    return;
  end;
  raise exception 'FAIL: % was NOT blocked', p_label;
end $$;
grant execute on function pg_temp.expect_fail(text, text) to authenticated;

create function pg_temp.lines(p_org uuid, p_debit text, p_credit text, p_cents bigint) returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('account_id', (select id from public.chart_of_accounts where organization_id = p_org and code = p_debit), 'debit_cents', p_cents),
    jsonb_build_object('account_id', (select id from public.chart_of_accounts where organization_id = p_org and code = p_credit), 'credit_cents', p_cents));
$$;
grant execute on function pg_temp.lines(uuid, text, text, bigint) to authenticated;

set local role authenticated;

-- ==== Client A ============================================================
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
insert into t_ctx values ('org_a', public.create_organization('Acme Florida LLC', '12-3456789', 'fl'));

do $$
declare n int;
begin
  select count(*) into n from public.chart_of_accounts where organization_id = pg_temp.ctx('org_a');
  if n < 50 then raise exception 'FAIL: COA not seeded (% rows)', n; end if;
  raise notice 'PASS: COA seeded with % accounts', n;
end $$;

-- Client can create a draft entry, but cannot post it
insert into t_ctx select 'draft1', public.create_journal_entry(pg_temp.ctx('org_a'), date '2026-11-09', 'Client draft',
  pg_temp.lines(pg_temp.ctx('org_a'), '6350', '1010', 500), false);
do $$ begin raise notice 'PASS: client saved a draft entry'; end $$;
select pg_temp.expect_fail($q$select public.create_journal_entry(pg_temp.ctx('org_a'), date '2026-11-10', 'x',
  pg_temp.lines(pg_temp.ctx('org_a'), '6350', '1010', 1050))$q$, 'client posts an entry');
select pg_temp.expect_fail($q$update public.journal_entries set status = 'posted' where id = pg_temp.ctx('draft1')$q$, 'client posts own draft');

-- Client cannot lock books, edit COA or assign an accountant
select pg_temp.expect_fail($q$update public.organizations set books_locked_through = date '2026-10-31' where id = pg_temp.ctx('org_a')$q$, 'client locks books');
do $$
declare n int;
begin
  update public.chart_of_accounts set name_en = 'x' where organization_id = pg_temp.ctx('org_a');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: client edited COA'; end if;
  raise notice 'PASS: client cannot edit COA (0 rows)';
end $$;
select pg_temp.expect_fail($q$insert into public.organization_members (organization_id, user_id, role)
  values (pg_temp.ctx('org_a'), '00000000-0000-0000-0000-00000000000c', 'accountant_admin')$q$, 'client assigns accountant');

insert into t_ctx select 'acct_a_6350', id from public.chart_of_accounts where code = '6350' and organization_id = pg_temp.ctx('org_a');

-- ==== Client B: tenant isolation ==========================================
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
insert into t_ctx values ('org_b', public.create_organization('Beta Texas LLC'));

-- ==== Platform admin: sees all, assigns accountant C to A only ==========
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000d';
do $$
declare n int;
begin
  select count(*) into n from public.organizations where id in (pg_temp.ctx('org_a'), pg_temp.ctx('org_b'));
  if n <> 2 then raise exception 'FAIL: platform admin sees % of 2 orgs', n; end if;
  raise notice 'PASS: platform admin sees every organization';
end $$;
insert into public.organization_members (organization_id, user_id, role)
values (pg_temp.ctx('org_a'), '00000000-0000-0000-0000-00000000000c', 'accountant_admin');
do $$ begin raise notice 'PASS: platform admin assigned accountant C to company A'; end $$;
insert into t_ctx values ('org_admin', public.create_organization('Onboarded By Admin LLC'));
do $$
declare n int;
begin
  select count(*) into n from public.organization_members where organization_id = pg_temp.ctx('org_admin');
  if n <> 0 then raise exception 'FAIL: admin became a member of the org it created'; end if;
  raise notice 'PASS: org created by admin, admin not added as member';
end $$;

-- ==== Accountant C (assigned to A only) ===================================
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';
do $$
declare n int;
begin
  select count(*) into n from public.organizations;
  if n <> 1 then raise exception 'FAIL: accountant sees % orgs, expected 1', n; end if;
  raise notice 'PASS: subcontracted accountant sees only the assigned company';
end $$;

insert into t_ctx select 'je1', public.create_journal_entry(pg_temp.ctx('org_a'), date '2026-11-10', 'Office supplies',
  pg_temp.lines(pg_temp.ctx('org_a'), '6350', '1010', 1050));
do $$ begin raise notice 'PASS: accountant posted a balanced entry'; end $$;
update public.journal_entries set status = 'posted' where id = pg_temp.ctx('draft1');
do $$ begin raise notice 'PASS: accountant posted the client draft'; end $$;

select pg_temp.expect_fail($q$select public.create_journal_entry(pg_temp.ctx('org_a'), date '2026-11-11', 'Bad', jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.ctx('acct_a_6350'), 'debit_cents', 1000),
    jsonb_build_object('account_id', (select id from public.chart_of_accounts where code = '1010' and organization_id = pg_temp.ctx('org_a')), 'credit_cents', 999)))$q$,
  'unbalanced entry');
select pg_temp.expect_fail($q$update public.journal_entries set description = 'hacked' where id = pg_temp.ctx('je1')$q$, 'update posted entry');
select pg_temp.expect_fail($q$delete from public.journal_entries where id = pg_temp.ctx('je1')$q$, 'delete posted entry');
select pg_temp.expect_fail($q$update public.journal_lines set debit_cents = 1 where journal_entry_id = pg_temp.ctx('je1') and debit_cents > 0$q$, 'update posted line');

insert into public.journal_entries (organization_id, entry_date, description) values (pg_temp.ctx('org_a'), date '2026-11-12', 'no lines');
do $$
declare blocked boolean := false;
begin
  begin
    set constraints all immediate;
    update public.journal_entries set status = 'posted' where description = 'no lines' and organization_id = pg_temp.ctx('org_a');
  exception when check_violation then
    blocked := true;
    raise notice 'PASS (blocked as expected): post an entry with no lines -> %', sqlerrm;
  end;
  if not blocked then raise exception 'FAIL: entry with no lines was posted'; end if;
end $$;
set constraints all deferred;
delete from public.journal_entries where description = 'no lines';

insert into t_ctx select 'rev1', public.reverse_journal_entry(pg_temp.ctx('je1'), date '2026-11-15', 'test');
select pg_temp.expect_fail($q$select public.reverse_journal_entry(pg_temp.ctx('je1'))$q$, 'second reversal');
do $$
declare b bigint;
begin
  select balance_cents into b from public.v_trial_balance where organization_id = pg_temp.ctx('org_a') and code = '6350';
  if b <> 500 then raise exception 'FAIL: expected 500 on 6350 after reversal, got %', b; end if;
  raise notice 'PASS: reversal netted out (6350 = 500 from the client draft)';
end $$;

update public.organizations set books_locked_through = date '2026-10-31' where id = pg_temp.ctx('org_a');
do $$ begin raise notice 'PASS: accountant locked books through 2026-10-31'; end $$;
select pg_temp.expect_fail($q$select public.create_journal_entry(pg_temp.ctx('org_a'), date '2026-10-15', 'late',
  pg_temp.lines(pg_temp.ctx('org_a'), '6350', '1010', 100))$q$, 'post into locked period');

-- ==== Client B cannot reach A =============================================
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$
declare n int;
begin
  select count(*) into n from public.journal_entries where organization_id = pg_temp.ctx('org_a');
  if n <> 0 then raise exception 'FAIL: B sees A entries'; end if;
  select count(*) into n from public.audit_log where organization_id = pg_temp.ctx('org_a');
  if n <> 0 then raise exception 'FAIL: B sees A audit log'; end if;
  raise notice 'PASS: tenant isolation (B cannot read A)';
end $$;
select pg_temp.expect_fail($q$insert into public.journal_entries (organization_id, entry_date, description)
  values (pg_temp.ctx('org_a'), current_date, 'intrusion')$q$, 'B writes into A');
select pg_temp.expect_fail($q$insert into public.organization_members (organization_id, user_id, role)
  values (pg_temp.ctx('org_a'), '00000000-0000-0000-0000-00000000000b', 'client_owner')$q$, 'B adds self to A');
select pg_temp.expect_fail($q$insert into public.journal_entries (organization_id, entry_date, description) values (pg_temp.ctx('org_b'), current_date, 'cross');
  insert into public.journal_lines (organization_id, journal_entry_id, account_id, debit_cents)
  select pg_temp.ctx('org_b'), id, pg_temp.ctx('acct_a_6350'), 100 from public.journal_entries where description = 'cross'$q$,
  'B uses an account UUID of A');

-- ==== Document -> AP flow (client A, then accountant C) ==================
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
with x as (
  insert into public.cost_centers (organization_id, code, name) values (pg_temp.ctx('org_a'), 'ADM', 'Administrativo') returning id)
insert into t_ctx select 'cc1', id from x;
with x as (
  insert into public.contacts (organization_id, kind, display_name, is_1099_eligible)
  values (pg_temp.ctx('org_a'), 'vendor', 'Office Depot', false) returning id)
insert into t_ctx select 'vendor1', id from x;
with x as (
  insert into public.documents (organization_id, storage_path, file_name, mime_type)
  values (pg_temp.ctx('org_a'), pg_temp.ctx('org_a')::text || '/doc1/bill.pdf', 'bill.pdf', 'application/pdf') returning id)
insert into t_ctx select 'doc1', id from x;
select pg_temp.expect_fail($q$insert into public.documents (organization_id, storage_path, file_name)
  values (pg_temp.ctx('org_a'), pg_temp.ctx('org_b')::text || '/x/bill.pdf', 'bill.pdf')$q$, 'document path outside own org');

-- AI (here: the client) creates a draft bill with an uncategorized line
with x as (
  insert into public.open_items (organization_id, direction, contact_id, document_id, reference_number, issue_date, due_date, total_cents, created_by_ai, ai_detected_paid)
  values (pg_temp.ctx('org_a'), 'payable', pg_temp.ctx('vendor1'), pg_temp.ctx('doc1'), 'INV-778', date '2026-11-05', date '2026-12-05', 12000, true, true) returning id)
insert into t_ctx select 'bill1', id from x;
insert into public.open_item_lines (organization_id, open_item_id, amount_cents, description)
values (pg_temp.ctx('org_a'), pg_temp.ctx('bill1'), 12000, 'Toner');

-- Submitting with an uncategorized line fails
do $$
declare blocked boolean := false;
begin
  begin
    set constraints all immediate;
    update public.open_items set status = 'pending_review' where id = pg_temp.ctx('bill1');
  exception when check_violation then
    blocked := true;
    raise notice 'PASS (blocked as expected): submit bill with uncategorized line -> %', sqlerrm;
  end;
  if not blocked then raise exception 'FAIL: incomplete bill submitted'; end if;
end $$;
set constraints all deferred;

update public.open_item_lines set account_id = pg_temp.ctx('acct_a_6350'), cost_center_id = pg_temp.ctx('cc1')
 where open_item_id = pg_temp.ctx('bill1');
update public.open_items set status = 'pending_review' where id = pg_temp.ctx('bill1');
set constraints all immediate; set constraints all deferred;
do $$ begin raise notice 'PASS: client categorized (account + cost center) and submitted the bill'; end $$;

select pg_temp.expect_fail($q$update public.open_items set status = 'open' where id = pg_temp.ctx('bill1')$q$, 'client approves own bill');
select pg_temp.expect_fail($q$update public.open_items set total_cents = 1 where id = pg_temp.ctx('bill1')$q$, 'client edits bill under review');

set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';
update public.open_items set status = 'open' where id = pg_temp.ctx('bill1');
do $$
declare r public.open_items;
begin
  select * into r from public.open_items where id = pg_temp.ctx('bill1');
  if r.approved_by is distinct from '00000000-0000-0000-0000-00000000000c'::uuid or r.submitted_by is distinct from '00000000-0000-0000-0000-00000000000a'::uuid then
    raise exception 'FAIL: approval stamps wrong (%/%)', r.submitted_by, r.approved_by;
  end if;
  raise notice 'PASS: accountant approved; submitted_by / approved_by recorded';
end $$;

set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.expect_fail($q$update public.open_item_lines set amount_cents = 1 where open_item_id = pg_temp.ctx('bill1')$q$, 'client edits lines of approved bill');
select pg_temp.expect_fail($q$delete from public.open_items where id = pg_temp.ctx('bill1')$q$, 'client deletes approved bill');

set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$
declare n int;
begin
  select count(*) into n from public.open_items where organization_id = pg_temp.ctx('org_a');
  select n + count(*) into n from public.contacts where organization_id = pg_temp.ctx('org_a');
  select n + count(*) into n from public.documents where organization_id = pg_temp.ctx('org_a');
  if n <> 0 then raise exception 'FAIL: B sees A documents/contacts/bills'; end if;
  raise notice 'PASS: B cannot see A documents, contacts or bills';
end $$;

-- ==== Storage paths ======================================================
do $$
begin
  if private.storage_org_id('not-a-uuid/file.pdf') is not null then raise exception 'FAIL: storage parser'; end if;
  raise notice 'PASS: storage path parser rejects non-UUID folders without error';
end $$;

-- ==== Anonymous ===========================================================
reset role;
set local role anon;
select pg_temp.expect_fail('select * from public.journal_entries', 'anon reads journal');
select pg_temp.expect_fail('select * from public.documents', 'anon reads documents');
select pg_temp.expect_fail($q$select public.create_organization('x')$q$, 'anon creates org');

reset role;
do $$
declare n int;
begin
  select count(*) into n from public.audit_log;
  if n = 0 then raise exception 'FAIL: audit log empty'; end if;
  raise notice 'PASS: audit log has % rows', n;
end $$;

rollback;
