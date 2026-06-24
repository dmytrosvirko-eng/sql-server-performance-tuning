# Case 02 — Slow tag page

> The tag listing page (e.g. "newest questions tagged *javascript*") takes
> ~27–37s to load and saturates CPU, getting worse under concurrent load.

## 1. Context

The platform lets users browse questions by tag. Tags are stored on
`dbo.Posts` in a single delimited string column, e.g.
`<javascript><node.js><express>`. The page shows one screen of results — the
50 newest questions that carry a given tag — so the backing query filters
`Posts.Tags` by substring and orders by `CreationDate` descending.

This is a different root cause from Case 01. Case 01 was a *missing index* on a
seekable column. Here the problem is the **shape of the predicate**: a
substring match cannot be satisfied by an index seek at all.

## 2. The query

```sql
SELECT TOP (50)
       p.Id, p.Title, p.Score, p.ViewCount, p.AnswerCount, p.CreationDate
FROM   dbo.Posts AS p
WHERE  p.Tags LIKE '%<javascript>%'
ORDER  BY p.CreationDate DESC;
```

A literal tag value is used (not a parameter) to remove parameter sniffing as a
confounder. `Body` (off-row `nvarchar(max)`) is deliberately not selected. The
angle brackets in the pattern give an exact-tag match — `<` and `>` are not
`LIKE` metacharacters, so `'%<javascript>%'` matches the tag `<javascript>` and
not a substring of another tag such as `<unobtrusive-javascript>`.

## 3. Baseline (before)

Measured per `lab-protocol.md` (cold cache, repeated runs, steady state).
Logical reads are deterministic across runs (run 1: 4,187,249; run 2: 4,186,226).

| Metric        | Value |
|---------------|-------|
| Logical reads | 4,186,226 |
| CPU time (ms) | 63,216 |
| Elapsed (ms)  | 27,181 |
| Plan shape    | Clustered Index Scan (`PK_Posts_Id`) → Top N Sort, parallel (DOP 6) |

Plan: `results/before.sqlplan` · screenshot: `results/before.png`

## 4. Diagnosis

The predicate `Tags LIKE '%<javascript>%'` has a **leading wildcard**, which is
**non-SARGable**: no B-tree index can seek it, because a B-tree is ordered by
prefix and the search term can appear anywhere in the string. The optimizer can
only evaluate it as a *residual* applied to every row it reads.

With zero nonclustered indexes on the table (confirmed in Discovery), the only
access path is the clustered index — i.e. the whole 37 GB table. So the plan is
a full **Clustered Index Scan of all 17.1M rows (~4.19M logical reads)**, with
the `LIKE` applied as a residual that filters to ~489K matching rows, then a
**Top N Sort** to order those by date and take 50.

Crucially, this is **not a statistics problem**. The scan estimated 481,574 rows
versus 489,112 actual — **101% accuracy**. The optimizer estimated the `LIKE`
selectivity correctly; given this predicate it genuinely has no better option.
The cost is inherent to the predicate form, not to a bad estimate. The parallel
plan (DOP 6) is why CPU (~63s) far exceeds elapsed (~27s); logical reads stays
the deterministic headline because it is unaffected by parallelism.

## 5. Fix

Because a seek is impossible, the goal is not to seek — it is to (a) make the
unavoidable scan cheap by scanning a **narrow covering index** instead of the
37 GB clustered index, and (b) exploit index *order* so the `TOP` can stop
early instead of scanning everything and sorting.

**One change — add a covering nonclustered index keyed on `CreationDate DESC`:**

```sql
CREATE NONCLUSTERED INDEX IX_Posts_CreationDate
ON dbo.Posts (CreationDate DESC)
INCLUDE (Tags, Title, Score, ViewCount, AnswerCount)
WITH (SORT_IN_TEMPDB = ON, ONLINE = ON, MAXDOP = 6);
```

Reasoning: the index is pre-ordered by `CreationDate DESC`, so the optimizer
scans it top-down (newest first), applies the `LIKE` as a residual on the
included `Tags`, and **stops as soon as it has collected 50 matches** (ordered
TOP, early exit). No sort is needed, and only a small prefix of the index is
read.

> A naive alternative — keying the index on `Tags` instead
> (`IX_Posts_Tags … INCLUDE (…)`) — was also benchmarked. It shrinks the scan
> (4.19M → 191,901 reads) but, being ordered by `Tags`, **keeps the Top N Sort**.
> It is strictly dominated by the design above (see §7).

## 6. Result (after)

Headline case — the typical "popular tag" page (`javascript`):

| Metric        | Before     | After (`IX_Posts_CreationDate`) | Improvement |
|---------------|------------|---------------------------------|-------------|
| Logical reads | 4,186,226  | **34**                          | ~123,000×   |
| CPU time (ms) | 63,216     | **31**                          | ~2,000×     |
| Elapsed (ms)  | 27,181     | **119**                         | ~228×       |
| Plan shape    | Clustered Scan + Top N Sort (DOP 6) | Ordered NC Index Scan + Top, **no sort** (DOP 1) | — |

The plan dropped to a serial ordered scan with early exit, eliminating both the
table scan and the sort, and reading only 34 pages.

Plan: `results/after.sqlplan` · screenshot: `results/after.png`

## 7. Validation & trade-offs

**The win is selectivity-dependent — characterized empirically, not assumed.**
The early-exit reads however far it must go to collect 50 matches, so the cost
scales with how rare the tag is:

| Tag                       | Logical reads | vs before | DOP | Sort |
|---------------------------|---------------|-----------|-----|------|
| `<javascript>` (popular)  | 34            | ~123,000× | 1   | no   |
| `<malloc>` (niche)        | 5,036         | ~831×     | 6   | no   |
| 0-match tag (worst case)  | 190,234       | ~22×      | 6   | no   |

The worst case (a tag with fewer than 50 matches) degrades to a **full scan of
the narrow index (~190K reads)** — which is the *same* cost as the naive
`Tags`-keyed index. So `IX_Posts_CreationDate` is **never worse than the naive
index, and on real tag pages (which are popular tags) it is orders of magnitude
better**. It also shifts the plan to serial for hot tags, freeing parallel
workers — directly addressing the "worse under load" symptom.

**Naive `Tags` index, for comparison:** 191,901 reads, but retains the Top N
Sort and stays parallel (DOP 6) regardless of tag. Dropped.

**Write cost & maintenance.** The index is ~1.5 GB on 17.1M rows and adds write
overhead to `Posts` inserts/updates. Keying on `CreationDate` is favorable here:
new posts arrive with increasing dates, so they append to one end of the index
(near-sequential inserts, low fragmentation). A `Tags`-keyed index would insert
at random points and fragment over time.

**Storage.** ~1.5 GB against ~3.8 GB free in the filegroup — comfortable for a
single index. Only `IX_Posts_CreationDate` is kept; the benchmark index was
dropped.

**Parameterization (out of scope, noted for production).** This case used a
literal tag. With a parameterized query, parameter sniffing could cache the
serial popular-tag plan and reuse it for a rare tag (or vice versa), giving
unstable performance. Worth addressing at the application layer.

**Algorithmic limit.** No B-tree index makes this a seek. For arbitrary tag
search the algorithmically correct fix is **full-text indexing (`CONTAINS`)** or
a **normalized tag table** — but both require changing the query / application
code, which is out of scope for this engagement (index-only changes). The index
here is the best result achievable without touching application code.

## 8. Takeaway

Not every slow query is a missing index — some are caused by *how the filter is
written*. A "contains this tag" search can't be answered by jumping straight to
the right rows; the database has to read and check rows. By giving it a small,
date-ordered copy of just the needed columns, the newest-first page now returns
in a few milliseconds instead of half a minute, and stops hogging CPU under
load.
