# Case 01 — Slow user-profile page

> The profile page for active contributors takes ~19 seconds to load their recent
> posts and occasionally times out under load.

## 1. Context

The user-profile page lists a member's most recent posts (questions and answers),
newest first — a standard "activity" panel. The heavier a user's contribution
history, the slower the page, which is the worst possible distribution: the
platform's most valuable members get the worst experience. The query underneath
fetches the 50 newest posts for one user, ordered by creation date.

## 2. The query

```sql
SELECT TOP (50)
       p.Id,
       p.PostTypeId,
       p.Title,
       p.CreationDate,
       p.Score,
       p.ViewCount
FROM dbo.Posts AS p
WHERE p.OwnerUserId = 22656
ORDER BY p.CreationDate DESC;
```

Conventions for a clean measurement:

- **Literal `OwnerUserId` (22656, a high-activity user), not a parameter.** This
  isolates the index as the single variable and defers parameter sniffing to a
  later case.
- **`Body` is not selected.** It is an off-row `nvarchar(max)` LOB; excluding it
  keeps logical reads attributable to the in-row data the page actually needs.
- **`TOP 50 ... ORDER BY CreationDate DESC`** = one page of "most recent" posts.

## 3. Baseline (before)

Measured per [`../lab-protocol.md`](../lab-protocol.md) — cold cache, 3 runs,
steady-state shown.

| Metric        | Value |
|---------------|-------|
| Logical reads | 4,186,198 |
| CPU time (ms) | 38,607 |
| Elapsed (ms)  | 19,402 |
| Plan shape    | Parallel Clustered Index Scan on `Posts` (DOP 6) → Top N Sort |

`Scan count 7`, estimated subtree cost 3093.08. Cardinality estimation was
accurate, so the cost is purely structural, not a bad-estimate problem.

Plan: `results/before.sqlplan` · screenshot: `results/before.png`

## 4. Diagnosis

The filter is on `OwnerUserId`, which has **no index** — per Discovery, the only
seekable column anywhere in the database is `Id`. To find one user's posts, the
engine has no choice but to read **every row of `Posts`** — a ~37 GB, ~4.8M-page
table — and only then keep the matches. That full scan *is* the ~4.19M logical
reads.

There is a second cost layered on top: once the rows are found, they are not in
date order, so the plan adds a **Top N Sort** to pull out the 50 newest. So the
baseline pays twice — a full scan to locate the rows, then a sort to order them.
A fix that only removes the scan but leaves the sort would be a half-fix.

## 5. Fix

One change — a single nonclustered **covering** index:

```sql
CREATE NONCLUSTERED INDEX IX_Posts_OwnerUserId_CreationDate
ON dbo.Posts (OwnerUserId, CreationDate DESC)
INCLUDE (PostTypeId, Score, Title, ViewCount)
WITH (SORT_IN_TEMPDB = ON);
```

Each part of the design earns its place:

- **Key column `OwnerUserId`** turns the full scan into a **seek** — the engine
  jumps straight to this user's rows instead of reading all 17M.
- **Second key `CreationDate DESC`** stores those rows already in newest-first
  order, so the `ORDER BY` is satisfied by the index itself — the **Top N Sort
  disappears**.
- **`INCLUDE (PostTypeId, Score, Title, ViewCount)`** carries the remaining
  selected columns in the index leaf, so the query is fully **covered** — no key
  lookup back to the clustered index.

This is deliberately stronger than the missing-index DMV suggestion, which would
key on `OwnerUserId` alone and INCLUDE the rest. That suggestion eliminates the
scan but **leaves the Top N Sort in place**, because the index order would not
match the `ORDER BY`. Putting `CreationDate DESC` in the *key* is what removes the
sort — the central lesson of this case.

## 6. Result (after)

Same query, same literal (22656), same protocol — the only change is the new
index. Logical reads were deterministic at 7 across runs.

| Metric        | Before     | After | Improvement                 |
|---------------|------------|-------|-----------------------------|
| Logical reads | 4,186,198  | 7     | ~598,000× fewer (−99.9998%) |
| CPU time (ms) | 38,607     | ~0    | effectively eliminated      |
| Elapsed (ms)  | 19,402     | 6     | ~3,200× faster              |

Plan: `Index Seek (IX_Posts_OwnerUserId_CreationDate)` → Top → SELECT. Serial
(DOP 1), optimization level **TRIVIAL** (subtree cost 0.0037). **No Sort** — the
index supplies `CreationDate DESC` order — and **no Key Lookup** — the INCLUDE
columns cover the SELECT. Estimated vs actual rows: 50 vs 50 (100%).

Plan: `results/after.sqlplan` · screenshot: `results/after.png`

## 7. Validation & trade-offs

**Storage.** The index adds **~1,203 MB (~1.2 GB)** across 17.1M rows — about
2.4% of the ~51 GB database — measured via `sys.dm_db_partition_stats`. It is the
first nonclustered index on `Posts`, so there is no interaction with existing
structures (Discovery: blank canvas), leaving ~2.6 GB free in the current files.

**Write cost.** Every insert into `Posts` now maintains this index, and — because
`Score` and `ViewCount` are INCLUDE columns — so does every **vote** (`Score`)
and **view** (`ViewCount`) update. On a live Q&A platform those are
high-frequency, so this is the real ongoing cost of *covering* the query. It is
justified here because the profile page is read-dominated; dropping
`Score`/`ViewCount` from the INCLUDE would lighten writes but re-introduce ~50
key lookups per execution (random I/O). The key columns `OwnerUserId` and
`CreationDate` never change after insert, so the index key is stable — no page
splits from key updates.

**Regressions.** None expected on reads — the index can only help other
`OwnerUserId` / `CreationDate` filters on `Posts`. No other query was made worse;
the only cost is the storage and write maintenance above.

## 8. Takeaway

The profile page was scanning the entire 37 GB posts table — millions of pages —
just to find one user's 50 newest posts. A single well-designed index lets the
database jump straight to that user's posts, already in the right order, reading
**7 pages instead of 4.2 million**. The page now returns in milliseconds instead
of ~20 seconds.
