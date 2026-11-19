# Revisão do Blueprint — Sprint 1 (18/11/2026)

## Como usar este kit
Copie para a raiz do repositório criado pelo Lovable, mantendo as pastas:

```
CLAUDE.md
.claude/agents/architect.md · integrations.md · frontend.md · reporting-tax.md
supabase/migrations/20261118000000_foundation.sql
supabase/migrations/20261118000100_documents_ap_ar.sql
supabase/tests/foundation_smoke.sql
```

Depois: `supabase start` → `supabase db reset` → rodar o teste (comando no CLAUDE.md). Só então `supabase link --project-ref jkpvvvzjprmkwvjxkyvx` (uma vez) e `supabase db push` para o projeto `us-bookkeeping-saas` (us-west-2).

## O que a migration entrega (Prompt 1)
- `organizations` já com os campos do Prompt 2 (EIN, estado, forma jurídica, classificação fiscal, dono estrangeiro, regime cash/accrual, idioma, trava de fechamento).
- `organization_members` com papéis `client_owner` e `accountant_admin`.
- Plano de contas US GAAP com 61 contas em EN e PT, copiado automaticamente ao criar a empresa (`create_organization()`), com dicas fiscais (1099-NEC, 5472, refeições 50%).
- `journal_entries` / `journal_lines` em centavos, com balanceamento obrigatório, imutabilidade após `posted`, estorno (`reverse_journal_entry()`), trava de período e `audit_log` automático.
- Testado num Postgres 16 local: 20 de 20 checagens passaram (isolamento entre empresas, lançamento desbalanceado, edição de lançamento postado, trava de período, permissões por papel, acesso anônimo).

## Lacunas que encontrei no blueprint (e como tratei)
1. **"Trigger que bloqueia desbalanceados"** precisa ser *diferido*: um trigger comum rejeitaria a primeira linha do lançamento. Usei constraint trigger `DEFERRABLE INITIALLY DEFERRED` + RPC `create_journal_entry()` que grava tudo numa transação.
2. **Imutável, mas sem caminho de correção.** Adicionei rascunho vs. postado e estorno. Lançamento postado nunca é editado nem apagado.
3. **Fechamento mensal sem mecanismo no banco.** Adicionei `books_locked_through`; só o contador mexe.
4. **Vazamento entre clientes por referência.** RLS sozinho não impede usar o ID de uma conta de outra empresa. Usei FKs compostas `(organization_id, id)`; o teste confirma o bloqueio.
5. **Status misturados.** `pending_client / pending_review / reconciled / locked` são status da transação bancária (Sprint 2). O lançamento contábil usa `draft / posted`.
6. **1099-NEC "> $600" está desatualizado.** A lei OBBBA (2025) elevou o limite para $2.000 para pagamentos a partir de 2026, com correção pela inflação depois. Deixei como parâmetro por ano no agente `reporting-tax`. Vale confirmar com sua fonte fiscal.
7. **S-Corp e brasileiros:** S-Corp não pode ter sócio nonresident alien. Muitos clientes-alvo não podem eleger S-Corp; o sistema deve alertar no cadastro.
8. **Form 5472:** além de LLC single-member estrangeira, também vale para C-Corp com 25%+ de dono estrangeiro. Multa a partir de $25.000 por formulário. Aportes, retiradas e empréstimos do sócio estão marcados como reportáveis no plano de contas.
9. **Segredos da Plaid/Stripe:** o blueprint não diz onde guardar o `access_token`. Regra no CLAUDE.md: só em Edge Function / Vault, nunca legível pelo frontend. Webhooks com verificação de assinatura.
10. **Conflito Lovable x Claude Code:** acrescentei a regra de não editar pelo chat do Lovable os arquivos de uma branch aberta.

## Decisões tomadas (18/11/2026)
- **Acesso:** o admin da plataforma (`platform_admins`) vê todas as empresas e é quem designa contadores. O contador subcontratado (`accountant_admin`) vê só as empresas designadas a ele.
- **Lançamentos:** o cliente envia documentos e confirma sugestões, mas não posta. A IA cria rascunhos de AP/AR; o contador aprova e posta.
- Implementado na migration `20261118000100_documents_ap_ar.sql`: `documents` (bucket privado), `open_items` + `open_item_lines` (AP/AR com categoria e centro de custo), `contacts` (fornecedores/clientes, com flag 1099), `cost_centers` e centro de custo nas linhas do razão.
- Testes: 40 de 40 checagens passaram no Postgres 16 local.

## Plano dos próximos sprints (ajustado)
- **Sprint 1 (nov):** Prompt 2 inclui também a tela de admin (todas as empresas, designar contador) e o cadastro de centros de custo.
- **Sprint 2 (dez):** Plaid + `bank_transactions`; tabela `match_suggestions` (transação ↔ documento/AP/AR) para o cliente confirmar; RPC `approve_open_item` que posta o lançamento (accrual: D despesa / C 2000 A/P; recebível: D 1100 A/R / C receita; cash: lança na baixa bancária).
- **Sprint 2/3:** Edge Function `process-document` com a API do Claude (extração estruturada), telas de envio e revisão de documentos, fila do contador.
- **Sprint 3 (jan):** invoices emitidas pela plataforma (Stripe) entram como `open_items` receivable; relatórios por centro de custo; 1099-NEC a partir de `contacts.is_1099_eligible`.

## Pendências conhecidas para os próximos prompts
- Convite de membros por e-mail (hoje o dono adiciona por `user_id`) e proteção para não remover o último `client_owner`.
- Numeração de lançamentos por empresa (hoje é sequencial global).
- Contas de cartão e bancos criadas a partir da conexão Plaid (subcontas de 1010/2100).
- Política de segurança da informação: quem guarda dados fiscais de clientes nos EUA está sujeito à FTC Safeguards Rule e o IRS exige um plano escrito (WISP) de quem prepara declarações. Vale prever antes do beta.
