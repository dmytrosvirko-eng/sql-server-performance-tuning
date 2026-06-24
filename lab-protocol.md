# Lab Protocol — How Measurements Are Taken

Consistent measurement is what makes the before/after numbers in this portfolio
trustworthy. Every case follows these rules.

## Environment

- All work is done on an **isolated lab instance**, never on a production server.
- The `DBCC` commands below clear caches to force a fair comparison. They are
  **safe only on a lab box** — they would hurt a live server. This is stated
  explicitly because knowing *when not* to run something matters as much as
  knowing how.

## Metrics captured

| Metric          | Source                          | Why it matters                                   |
|-----------------|---------------------------------|--------------------------------------------------|
| Logical reads   | `SET STATISTICS IO ON`          | **Primary.** Deterministic, hardware-independent. |
| CPU time        | `SET STATISTICS TIME ON`        | Secondary. Indicates compute cost.               |
| Elapsed time    | `SET STATISTICS TIME ON`        | Secondary. Wall-clock, varies with hardware/load. |
| Execution plan  | Actual plan (saved as `.sqlplan`) | Shows *why* — scan vs seek, estimates, operators. |

Logical reads is the headline number: it does not depend on CPU speed, disk, or
server load, so a reviewer gets the same value on their own machine.

## Procedure for each measurement

```sql
-- Lab only: clear plan cache and buffer pool for a cold-start comparison.
-- NEVER run these on a production server.
DBCC FREEPROCCACHE;
DBCC DROPCLEANBUFFERS;
GO

SET STATISTICS IO, TIME ON;
GO

-- <the query under test goes here>
-- Also capture the Actual Execution Plan (Ctrl+M in SSMS) and save it to results/.

SET STATISTICS IO, TIME OFF;
GO
```

## Run discipline

1. Run the query **3 times** and record the steady-state numbers.
2. Note whether the test is **cold cache** (after the DBCC commands) or
   **warm cache** (repeated execution) — report the same mode for before and after.
3. Change **exactly one thing** between the "before" and "after" runs (one index,
   one rewrite). Mixed changes make the result un-attributable.

## What goes in `results/`

- `before.sqlplan` and `after.sqlplan`
- Screenshots of both plans
- The raw `STATISTICS IO`/`TIME` output (copy-paste from the Messages tab)
- A short metrics table (before → after)
