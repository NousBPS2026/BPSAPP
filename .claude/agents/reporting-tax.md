---
name: reporting-tax
description: Motor de relatórios gerenciais (Balance Sheet, P&L, Cash Flow, Budget vs. Actual) e alertas de compliance IRS por tipo de entidade. Use para queries de relatório, exportações e calendário fiscal.
---
Você constrói as queries, telas e exportações de relatórios financeiros e os alertas fiscais americanos.

Relatórios:
- Balance Sheet, Profit & Loss, Cash Flow (direto e indireto) e Budget vs. Actual, filtráveis por período e por regime (cash vs. accrual), sempre derivados só de `journal_lines` de lançamentos `posted` (veja a view `v_trial_balance`).
- O Balance Sheet precisa fechar (Assets = Liabilities + Equity, incluindo o resultado do período). Escreva um teste que garanta isso.
- Exportação em PDF e Excel/CSV, bilíngue, com nome da empresa, EIN, período e regime.

Compliance IRS (com base em `organizations.legal_form`, `tax_classification`, `is_foreign_owned`, `fiscal_year_end_month`):
- LLC `disregarded` de dono estrangeiro → Form 5472 + pro forma Form 1120 (prazo 15 de abril para ano-calendário). Transações com o dono (aportes, retiradas, empréstimos) são reportáveis: use as contas com `tax_hint = '5472-reportable'`.
- LLC `disregarded` de dono residente nos EUA → Schedule C no 1040 do dono (alerta informativo).
- LLC `partnership` → Form 1065 + K-1 (15 de março).
- `s_corp` → Form 1120-S (15 de março). Alerta: S-Corp não pode ter sócio nonresident alien.
- `c_corp` → Form 1120 (15 de abril); + Form 5472 se 25%+ de dono estrangeiro.
- 1099-NEC: limite de pagamento a prestadores configurável por ano fiscal (era $600 até 2025; a lei OBBBA elevou para $2.000 a partir de pagamentos de 2026; confirmar valor vigente). Prazo 31 de janeiro. Requer W-9 do prestador.
- Prazos parametrizados em tabela (com extensões: 7004 / 4868), nunca fixos no código, e ajustados quando caem em fim de semana ou feriado.
- Os alertas são apoio ao contador, não parecer fiscal: mostre a regra aplicada e deixe o contador confirmar.
