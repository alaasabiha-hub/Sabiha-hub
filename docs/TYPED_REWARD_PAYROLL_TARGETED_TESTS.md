> Root local execution update: current-day branch passed on the isolated clone using the genuinely completed new typed receipt and two QA configured rates15/25. Actual owner HR actions changed test rates to31/37 inside a self-rolled-back subtransaction; the current canonical HR SELECT retained frozen commission lines9/15 EGP. Current-day and period-ending-today approval were specifically rejected; payroll, requests, original employment, invoice and frozen lines remained unchanged. Outer transaction also rolled back. Evidence: `typed-reward-payroll-targeted-proof.json`. Full naturally closed-day approval/replay/overlap remains pending; no date or clock change was used. One proof-parser assertion initially counted the claims-context JSON as an extra result; only that new helper was repeated after filtering its explicit self_rollback_verified result. No old payroll suite was repeated.

# Typed reward / HR — new targeted clone-only helpers

Source only: supabase/tests/typed_reward_payroll_targeted_assertions.sql. No DB call/test execution was performed by this author. This does not restart the completed payroll suite and changes no application/HR function, invoice or A/B issuer migration.

Actual source reviewed: canonical HR101954 hr_api delegates hr_execute and returns its result directly. The later172315 hr_execute replacement uses frozen offline_walk_in_commissions.rate_percent/amount for walk_in_frozen_workers; the earlier generic current-rate branch must not be used as the latest implementation. approve_payroll returns a **payroll row**, with commission lines at snapshot.commission_lines, not result.snapshot or a new envelope. The existing retained closed-day helper uses that path correctly.

Root loads the new helper on qa_typed_reward_* only, as postgres with an actual current owner/session configured in request claims, inside an explicit outer BEGIN/ROLLBACK. It also self-rolls back its successful mutating subtransaction and verifies exact HR/request/payroll restoration. It will reject the primary database. No Auth, attendance, invoice date, clock, frozen commission or historical row is edited.

Call:

    select pg_temp.assert_typed_reward_payroll_rate_change(
      <actual completed typed invoice>,
      array[<actual QA worker1>,<actual QA worker2>]::uuid[],
      array[<explicit new test rate1>,<explicit new test rate2>]::numeric[],
      <explicit owner period scheduled minutes>, false);

Root supplies both already configured employments; no salary, date extension, currency conversion or default labor rule is invented. Rates must actually differ from both current and frozen rates, and produce a distinguishable hypothetical amount. The public employment action changes only the explicit rate on the clone, preserving each actual salary/currency/start/end; replay inputs/request IDs remain canonical HR behavior.

The readonly projection helper extracts and executes only the **actual current hr_execute commission SELECT** with its real joins/CASE expressions and bound parameters. It fails closed if that source shape/frozen branch changes. It is not a copied alternative calculator and creates no payroll snapshot. Before/after actual typed invoice line must stay exactly equal despite the legitimate current-rate change, with gross total+discount, frozen rate/amount and exact2 assigned staff. It verifies frozen rows/order/issued document remain unchanged and no cash/payment event appears.

For a receipt genuinely issued today UTC, the helper then calls actual public.hr_action approve_payroll for today and a period ending today, for each worker. It requires the specific canonical closed-date error, not any error, and verifies no successful request/payroll record. A missing permission/configuration cannot masquerade as the date-denial pass. UTC is the HR function's real declared timezone, not a clock override.

## Natural closed-day boundary still pending

The retained clone invoice currently exists only on its actual current UTC day. **No naturally prior-day typed receipt exists yet.** Therefore full successful payroll approval of that typed invoice, frozen commission inclusion in an approved closed period and immutable approved-snapshot replay are not claimed tested today.

When the same genuine invoice naturally becomes prior-UTC-day and actual employment still covers that day, root may call the same helper with the final parameter true. That branch performs actual canonical approval, verifies the direct row/snapshot shape and frozen commission line after the rate change, exact same-request replay, new-nonce overlapping-period rejection and unchanged approved snapshot after restoring the configured employment rate. All changes remain in its rollback subtransaction; payment_status must stay not_transferred.

No invoice/attendance backdating, current_date override, forged earning, primary update or bypass allows running that branch early. Return proof labels observation-only source checks versus actual closed-day approval explicitly. Root should static-check/load and execute only these new helpers, preserving existing accepted payroll proofs.
