# CLAUDE.md — Regras Globais do Projeto (NOUS Bookkeeping)

## Visão do Produto
Plataforma SaaS bilíngue (PT-BR / EN-US) de Bookkeeping e Tax Filings para pequenas e médias empresas de brasileiros nos EUA (LLCs, S-Corps, C-Corps).
- **Frontoffice (Cliente):** conexão bancária (Plaid), emissão de invoices, upload de recibos e aprovação rápida de conciliação.
- **Backoffice (Contador/Admin):** fila de validação contábil, plano de contas US GAAP, regras automáticas de categorização, fechamento mensal e relatórios (Balance Sheet, P&L/DRE, Cash Flow, Budget vs. Actual) e alertas IRS (Form 5472 + pro forma 1120, 1065, 1120-S, 1120, 1099-NEC).

## Stack Técnica (Padrão Lovable)
- **Frontend:** React, TypeScript, Vite, Tailwind CSS, shadcn/ui, Lucide Icons, TanStack Query.
- **Backend & Banco:** Supabase próprio (PostgreSQL, Auth, Storage, Edge Functions em Deno/TypeScript). Não usar Lovable Cloud.
- **Integrações:** Plaid API (extrato bancário), Stripe (billing do SaaS e invoices).

## Comandos
- `npm install` · `npm run dev` · `npm run build` (obrigatório antes de merge) · `npm run lint`
- Banco local: `supabase start` · `supabase db reset` (reaplica todas as migrations)
- Nova migration: `supabase migration new <nome>` → editar o arquivo em `supabase/migrations/`
- Testes do banco: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/foundation_smoke.sql`
- Projeto Supabase: `us-bookkeeping-saas` · ref `jkpvvvzjprmkwvjxkyvx` · região `us-west-2`. Vincular uma vez: `supabase link --project-ref jkpvvvzjprmkwvjxkyvx`
- Deploy do banco (produção): `supabase db push` · Edge Functions: `supabase functions deploy <nome>`
- Tipos TS do banco: `supabase gen types typescript --local > src/integrations/supabase/types.ts`

## Papéis e Acesso
- **`platform_admins`** (equipe NOUS): vê e administra todas as empresas; é o único que designa ou remove contadores. Cadastro só via service role / SQL editor.
- **`accountant_admin`** (contador subcontratado): vê só as empresas em que foi designado em `organization_members`. Posta lançamentos, aprova AP/AR, edita plano de contas e trava o fechamento.
- **`client_owner`** (cliente): envia documentos, completa categoria / centro de custo / fornecedor ou cliente, confirma sugestões e submete para revisão. Nunca posta no razão.

## Fluxo de Documentos (AP/AR)
Cliente envia documento → IA (Edge Function, service role) extrai os dados e cria rascunho em `open_items` (payable = AP, receivable = AR) com linhas sugeridas → se o documento já estiver pago/recebido (`ai_detected_paid`), a sugestão de vínculo aparece junto ao extrato → cliente completa categoria, centro de custo e cadastra o fornecedor/cliente se faltar → `pending_review` → contador aprova (`open`/`paid`) e o lançamento é postado. Status: `draft`, `pending_client`, `pending_review`, `open`, `paid`, `void`.

## Regras Inegociáveis de Engenharia e Contabilidade
1. **Multi-tenancy estrito:** toda tabela financeira tem `organization_id NOT NULL` e RLS habilitado. Políticas usam `private.is_org_member(org)` / `private.has_org_role(org, role)`. Chaves estrangeiras entre tabelas financeiras são compostas `(organization_id, id)` para impedir referência cruzada entre clientes. Nunca crie tabela financeira sem RLS e sem teste de isolamento.
2. **Partidas dobradas:** nunca altere saldos diretamente. Todo fato contábil vira `journal_entries` + `journal_lines`, com `SUM(debit_cents) = SUM(credit_cents) > 0` e no mínimo 2 linhas (o banco garante via constraint trigger diferido). Cada linha tem débito OU crédito, nunca os dois.
3. **Quem posta:** só `accountant_admin` / platform admin (ou backend com service role) muda um lançamento para `posted`. O cliente gera rascunhos e submissões.
4. **Imutabilidade:** lançamento `posted` não se edita nem se apaga. Correção = lançamento de estorno via `reverse_journal_entry()`. Rascunhos (`draft`) podem ser editados.
5. **Fechamento mensal:** `organizations.books_locked_through` bloqueia lançamentos com data igual ou anterior. Só `accountant_admin` altera a trava.
6. **Precisão monetária:** dinheiro é `BIGINT` em centavos (`1050` = `$10.50`). Nunca `FLOAT`/`REAL`/`number` com casas decimais em cálculo. No frontend, formate com `Intl.NumberFormat` só na exibição.
7. **Trilha de auditoria:** tabelas editáveis têm `created_by/created_at/updated_by/updated_at` (preenchidos por trigger) e passam pelo trigger `private.audit_row()` que grava em `audit_log`. Status de transações bancárias (Sprint 2): `pending_client`, `pending_review`, `reconciled`, `locked`.
8. **Idempotência:** lançamentos automáticos usam `source` + `source_ref` (índice único). Plaid usa `plaid_transaction_id` único.
9. **Segredos:** `service_role key`, `PLAID_SECRET`, `STRIPE_SECRET_KEY` e `access_token` da Plaid só existem em Edge Functions (Supabase secrets / Vault). Nunca no frontend, nunca em tabela legível pelo cliente, nunca no Git. O frontend só usa a `anon key`.
10. **Migrations:** toda mudança de banco é um arquivo novo em `supabase/migrations/`. Nunca edite uma migration já aplicada em produção; crie outra.
11. **i18n:** nenhum texto de interface fixo no código; tudo passa pelos arquivos de tradução PT-BR e EN-US. Nomes de contas têm `name_en` e `name_pt`.

## Fluxo Git & Deploy
- O Lovable sincroniza com a `main`. Trabalhe sempre em branch (`feat/...`, `fix/...`), rode `npm run build` e abra PR; o merge na `main` publica no Lovable.
- Depois de mesclar uma migration ou Edge Function, rode `supabase db push` / `supabase functions deploy` (o Lovable não faz isso sozinho).
- Não edite pelo chat do Lovable os mesmos arquivos que estão abertos numa branch do Claude Code.

## Subagentes
Use `.claude/agents/`: `architect` (banco e motor contábil), `integrations` (Plaid, Stripe, Edge Functions), `frontend` (telas), `reporting-tax` (relatórios e compliance IRS).
