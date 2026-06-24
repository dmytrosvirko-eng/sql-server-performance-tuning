# Case NN — [Short problem title]

> One-line business symptom, e.g. "The user-profile page takes ~8s to load and
> occasionally times out."

## 1. Context

What the query does, which feature/page it backs, and why the client cares
(business impact). Keep it plain-language.

## 2. The query

```sql
-- paste the original, unmodified query here
```

## 3. Baseline (before)

Measured per `lab-protocol.md` (cold cache, 3 runs, steady-state shown).

| Metric        | Value |
|---------------|-------|
| Logical reads | _TBD_ |
| CPU time (ms) | _TBD_ |
| Elapsed (ms)  | _TBD_ |
| Plan shape    | _e.g. Clustered Index Scan on Posts_ |

Plan: `results/before.sqlplan` · screenshot: `results/before.png`

## 4. Diagnosis

Root cause in your own words. What the plan revealed (scan vs seek, key lookups,
estimate vs actual rows, non-SARGable predicate, etc.) and *why* it happens.

## 5. Fix

One change, with the reasoning for it.

```sql
-- the index / rewrite applied
```

## 6. Result (after)

| Metric        | Before | After | Improvement |
|---------------|--------|-------|-------------|
| Logical reads | _TBD_  | _TBD_ | _TBD_       |
| CPU time (ms) | _TBD_  | _TBD_ | _TBD_       |
| Elapsed (ms)  | _TBD_  | _TBD_ | _TBD_       |

Plan: `results/after.sqlplan` · screenshot: `results/after.png`

## 7. Validation & trade-offs

Did the fix create costs elsewhere? Write impact of the new index, storage,
maintenance, any query that got worse. State what you checked.

## 8. Takeaway

One or two sentences a non-DBA client would understand.
