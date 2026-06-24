# Discovery Findings — StackOverflow2013

Phase 1 (Discovery) of the methodology: inventory the database **without changing
anything**. All queries here are read-only and safe to run on production. The
script that produces these results is [`../scripts/discovery.sql`](../scripts/discovery.sql).

Environment: SQL Server 2019 (15.0), default instance, compatibility level 150,
Query Store enabled.

---

## 1. Database size & storage layout

Source: `sp_spaceused` + `sys.database_files`.

### Overall

| Metric             | Value         |
|--------------------|---------------|
| Database size      | 52,249.88 MB (~51 GB) |
| Unallocated space  | 3,835.57 MB   |
| Reserved           | ~47.0 GB (49,320,376 KB) |
| Data               | ~46.9 GB (49,145,592 KB) |
| Index size         | ~163 MB (167,064 KB) |
| Unused             | ~7.5 MB (7,720 KB) |

### Data / log files

| File                 | Type | Size (MB) | Free (MB) |
|----------------------|------|-----------|-----------|
| StackOverflow2013_1  | ROWS | 13,000    | 957.6     |
| StackOverflow2013_2  | ROWS | 13,000    | 959.0     |
| StackOverflow2013_3  | ROWS | 13,000    | 959.0     |
| StackOverflow2013_4  | ROWS | 13,000    | 958.9     |
| StackOverflow2013_log| LOG  | 249.9     | 243.6     |

### Findings

1. **Scale confirmed.** ~51 GB total, matching the engagement scenario of a
   ~50 GB client database restored at full size.

2. **The database is effectively un-indexed.** Index size is ~163 MB against
   ~46.9 GB of data — roughly **0.34% of data volume**. This means storage is
   almost entirely the clustered primary keys (`Id`), with virtually no
   nonclustered indexes. This is the quantitative confirmation of the scenario:
   features were shipped, the database was never tuned. It is the root driver of
   the slow-query cases that follow — predicates on columns such as
   `OwnerUserId`, `PostId`, and `CreationDate` have no supporting index and are
   forced into scans.

3. **Transaction log is healthy.** ~250 MB, mostly free — no sign of bloat or
   large open transactions. Normal for the lab restore.

4. **Storage layout.** Data lives in a 4-file filegroup, 13 GB per file, each
   ~92–93% full (~958 MB free each → ~3.8 GB unallocated total). Allocation-level
   slack is negligible (`unused` ~7.5 MB).

### Space note for the optimization phases

Free space inside the existing files is ~3.8 GB. Rough index-size estimates
(leaf row ≈ key bytes + clustered key `Id` (4 B) + ~9 B overhead, × row count):

| Index on Votes (53M)            | Approx. size |
|---------------------------------|--------------|
| Narrow, single `int` column     | ~0.9 GB      |
| On `CreationDate` (datetime)    | ~1.1 GB      |
| Wide covering (4–5 INCLUDE cols)| ~2.0–2.5 GB  |

Implications, stated precisely:

- A single narrow index will **not** exhaust the 3.8 GB buffer; several fit.
- A **wide covering index on Votes**, or the **cumulative** index footprint
  across multiple cases, can approach or exceed it and trigger autogrowth.
- `CREATE INDEX` also needs **transient sort space**; with `SORT_IN_TEMPDB = OFF`
  that sort lands in this filegroup and the peak exceeds the final index size.

To keep measurements clean: enable `SORT_IN_TEMPDB`, confirm Instant File
Initialization is on (fast data-file growth; the log still zeroes), and run the
measured read-only queries **separately** from index-build operations so file
growth never coincides with a timed query. For read-only SELECT measurements the
main distortion vector is **tempdb** (sort/hash spills), not this data filegroup.

---

## 2. Table sizes & row counts

Source: `sys.dm_db_partition_stats` (row count from `index_id IN (0,1)`; data
vs. index split by clustered/heap vs. nonclustered).

| Table       | Rows        | Total (MB) | Data (MB) | Index (MB) | Share of DB |
|-------------|-------------|------------|-----------|------------|-------------|
| Posts       | 17,142,169  | 37,438.5   | 37,433.8  | 0.0        | ~80%        |
| Comments    | 24,534,730  | 8,035.6    | 8,034.6   | 0.0        | ~17%        |
| Votes       | 52,928,720  | 1,904.2    | 1,904.0   | 0.0        | ~4%         |
| Badges      | 8,042,005   | 388.0      | 387.9     | 0.0        | <1%         |
| Users       | 2,465,713   | 348.6      | 348.4     | 0.0        | <1%         |
| PostLinks   | 1,421,208   | 45.5       | 45.5      | 0.0        | —           |
| LinkTypes   | 2           | 0.0        | 0.0       | 0.0        | lookup      |
| VoteTypes   | 15          | 0.0        | 0.0       | 0.0        | lookup      |
| PostTypes   | 8           | 0.0        | 0.0       | 0.0        | lookup      |

### Findings

1. **`Posts` dominates the database — ~37 GB, roughly 80% of all data.** Despite
   having *fewer* rows than `Votes` (17M vs. 53M), it is by far the largest table
   because of its wide `Body` column (`nvarchar(max)`). Average row ≈ 37,438 MB /
   17.1M ≈ **~2.2 KB**. Lesson for indexing: never include `Body` in a covering
   index; index narrow key columns and accept a key lookup if needed.

2. **`Votes` is huge in rows but narrow in bytes** — 53M rows in only ~1.9 GB
   (~36 bytes/row). Cheap to index (a narrow nonclustered index ≈ 0.9 GB), so it
   offers high return for low storage cost. Strong early-case candidate.

3. **`Comments` is the second-largest by size** (~8 GB, 24.5M rows) — also carries
   a wide text column.

4. **The long tail is trivial.** `LinkTypes`, `VoteTypes`, `PostTypes` are tiny
   lookup tables (2–15 rows); not tuning targets.

### Reconciliation: `index_mb = 0.0` vs. the ~163 MB from Section 1

These do **not** contradict — they use different definitions of "index":

- This query counts `index_mb` as `index_id > 1` only, i.e. **nonclustered**
  indexes. There are **literally zero**.
- `sp_spaceused` (Section 1) also classifies the upper B-tree levels and
  allocation pages of the **clustered** PKs as "index_size". Those ~163 MB are
  clustered-key overhead, **not query-helping indexes**.

Section 2 therefore *strengthens* Section 1: real, query-accelerating indexes
number exactly zero across every table.

### Scan-cost implications ("before" baseline, rough)

Full scan ≈ size / 8 KB per page:

| Table    | Size     | ~Pages (logical reads) |
|----------|----------|------------------------|
| Posts    | ~37.4 GB | ~4.8M                  |
| Comments | ~8.0 GB  | ~1.0M                  |
| Votes    | ~1.9 GB  | ~244K                  |

Any predicate on a non-indexed `Posts` column (`OwnerUserId`, `CreationDate`,
`Score`, …) forces a ~4.8M-read scan. This is the mechanical source of the slow
pages and timeouts in the engagement scenario.

### Priorities for the case studies

- **`Posts`** — largest table and backs most user-facing pages (profiles,
  question lists, tag pages). Primary target, but index carefully (key columns
  only, no `Body`).
- **`Votes`** — many rows, narrow, cheap to index, high impact. Good early case.
- **`Comments`** — 24.5M rows, moderately wide.

---

## 3. Existing index inventory

Source: `sys.indexes` + `sys.index_columns` (key vs. included columns split).

| Table     | Index           | Type      | PK | Unique | Key cols | Included |
|-----------|-----------------|-----------|----|--------|----------|----------|
| Badges    | PK_Badges_Id    | CLUSTERED | 1  | 1      | Id       | NULL     |
| Comments  | PK_Comments_Id  | CLUSTERED | 1  | 1      | Id       | NULL     |
| LinkTypes | PK_LinkTypes_Id | CLUSTERED | 1  | 1      | Id       | NULL     |
| PostLinks | PK_PostLinks_Id | CLUSTERED | 1  | 1      | Id       | NULL     |
| Posts     | PK_Posts_Id     | CLUSTERED | 1  | 1      | Id       | NULL     |
| PostTypes | PK_PostTypes_Id | CLUSTERED | 1  | 1      | Id       | NULL     |
| Users     | PK_Users_Id     | CLUSTERED | 1  | 1      | Id       | NULL     |
| Votes     | PK_Votes_Id     | CLUSTERED | 1  | 1      | Id       | NULL     |
| VoteTypes | PK_VoteType_Id  | CLUSTERED | 1  | 1      | Id       | NULL     |

9 tables → 9 indexes. Exactly one clustered PK on `Id` per table; nothing else.

### Findings

1. **Hypothesis confirmed by name.** Sections 1–2 implied it via sizes; this
   confirms it explicitly: zero `NONCLUSTERED` indexes, zero `INCLUDE` columns.
   Query-accelerating indexes number exactly zero.

2. **No heaps.** Every table is clustered, so there are no heap-specific problems
   (forwarded records, no efficient seek). One potential red flag that did not
   materialize.

3. **Clustered key is `Id` (int, 4 bytes) — narrow.** This is favorable for the
   optimization phases: the row locator carried by every future nonclustered
   index is only 4 bytes, keeping those indexes compact. This validates the
   earlier ~0.9 GB estimate for a narrow index on `Votes`, which assumed `Id` =
   4 bytes as locator.

4. **The only seekable column in the entire database is `Id`.** Any predicate on
   `OwnerUserId`, `PostId`, `UserId`, `CreationDate`, `Score`, etc. has no
   supporting structure and is forced into a scan. This is the mechanical
   starting point for every case study.

### Portfolio note — "blank canvas"

With no competing indexes, every index added in the optimization phase is the
first index on that column. Improvements will be large and cleanly attributable
(no interaction with pre-existing structures), which is ideal for clean
before/after demonstrations.

> Note: `sys.dm_db_index_usage_stats` is empty/reset on a fresh restore, so
> usage-based pruning is not possible yet — it only accumulates under real
> workload.

---

## 4. Foreign keys & relationships

Source: `sys.foreign_keys` + `sys.foreign_key_columns`.

**Result: zero foreign keys.** `fk_count = 0`; the inventory query returns no rows.

### Findings

1. **No declared referential integrity.** Relationships are not enforced at the
   database level — integrity, if any, is handled by the application. Consistent
   with the "features shipped, never tuned, no DBA" scenario.

2. **The optimizer has no FK metadata.** Without trusted constraints it cannot
   perform join elimination or refine join cardinality from declared
   relationships. Every estimate relies purely on column statistics (state
   checked in Section 5).

3. **Relationships exist only conceptually, and all join columns are unindexed.**
   Joins between large tables fall back to hash/merge over full scans of both
   sides. This is the mechanical source of the slow pages that combine data
   (e.g. a profile page = `Users` + `Posts` + `Comments` + `Badges` joined on
   `UserId` / `OwnerUserId`).

### Implicit relationship map (from the StackOverflow schema)

These are not declared, but they are the join/filter columns that will appear in
the slow queries and therefore the candidates for nonclustered indexes:

```
Posts.OwnerUserId    → Users.Id
Posts.ParentId       → Posts.Id   (answers → questions, self-join)
Comments.PostId      → Posts.Id
Comments.UserId      → Users.Id
Votes.PostId         → Posts.Id
Votes.UserId         → Users.Id
Badges.UserId        → Users.Id
PostLinks.PostId     → Posts.Id
```

None of these columns has supporting structure today (only `Id` is seekable, per
Section 3), so each is a forced scan until indexed.

---

## 5. Statistics state

Source: `sys.databases` (DB-level options) + `sys.stats` with
`sys.dm_db_stats_properties`.

### Database-level options

| Option                          | Value |
|---------------------------------|-------|
| `is_auto_create_stats_on`       | 1 (on)  |
| `is_auto_update_stats_on`       | 1 (on)  |
| `is_auto_update_stats_async_on` | 0 (off) |

Auto-create and auto-update are on (defaults). Async update is **off**, so a
stale-stat update is **synchronous** — the triggering query waits for the update
to finish before compiling, rather than using the old stat and refreshing in the
background.

### Statistics inventory

Exactly **9 statistics objects — one per table, all on the clustered key `Id`**
(`PK_..._Id`). Every row shows:

| Property                | Observed                                    |
|-------------------------|---------------------------------------------|
| `auto_created`          | 0 everywhere                                |
| `user_created`          | 0 everywhere                                |
| `sampled_pct`           | 100.00 (full scan — these are index stats)  |
| `modification_counter`  | 0 everywhere (no DML since build)           |
| `last_updated`          | 2018-09-10 (original build/restore time)    |
| `steps`                 | 2–102 (histogram on `Id`)                   |

### Findings

1. **Coverage, not staleness, is the issue.** `modification_counter = 0` means
   nothing is stale, and the existing PK stats are FULLSCAN-accurate. But the
   optimizer has a distribution for exactly **one column per table — `Id`**.
   Every predicate/join column we care about (`OwnerUserId`, `PostId`,
   `CreationDate`, `Score`, `UserId`, …) has **no statistic at all** until a
   query triggers auto-creation — and that will be a *sampled* stat.

2. **All 9 stats are index statistics, not column or user stats.** The
   `auto_created = 0` **and** `user_created = 0` signature is the fingerprint of
   statistics built alongside an index. Auto-created column stats: zero.
   User-created stats: zero.

3. **The `Id` histograms are useless for our queries.** `Id` is a monotonically
   increasing int with a near-uniform distribution (few histogram steps). It
   describes the clustered key, not the skewed columns that drive the slow pages.

4. **Skew risk on first execution.** When a case query first filters a column
   like `OwnerUserId` (skewed — top users have thousands of posts), SQL
   auto-creates a *sampled* stat. Sampled stats on skewed data can mislead the
   optimizer — the mechanical source of the "estimate vs. actual rows" gaps we
   will diagnose.

### Measurement note

Because auto-create is on and updates are synchronous, the first ("cold") run of
a new query includes synchronous stat auto-creation (extra compile time and
reads). The lab protocol (3 runs, steady-state) absorbs this — after run 1 the
stat already exists.

---

## 6. Server & database configuration

Source: `SERVERPROPERTY` + `sys.databases` + `sys.configurations` +
`sys.master_files`.

### Version & context

| Property            | Value |
|---------------------|-------|
| Product version     | 15.0.2000.5 (SQL Server 2019 **RTM**, no CU) |
| Edition             | Enterprise Evaluation (64-bit) |
| Compatibility level | 150 (CE 150) |
| Query Store         | On |

### Instance settings

| Setting                          | Value | Note |
|----------------------------------|-------|------|
| cost threshold for parallelism   | 5     | Default; low → big scans go parallel |
| max degree of parallelism        | 6     | Parallel plans up to 6 threads |
| max server memory (MB)           | 2147483647 | Default = unlimited |
| min server memory (MB)           | 16    | Default |
| optimize for ad hoc workloads    | 0     | Off (default) |

### tempdb layout

8 ROWS data files + 1 log, **8 MB each** (default minimum).

### Findings

1. **Enterprise Evaluation = full feature set.** Online index rebuilds,
   partitioning, etc. are available. Caveats (lab-only, non-blocking): the build
   is RTM with no Cumulative Update, and Evaluation expires after 180 days.

2. **Config favors parallel plans.** `MAXDOP = 6` with `cost threshold = 5`
   means large scans (e.g. `Posts`) almost certainly go parallel. This adds
   **elapsed-time variance** between runs — but **not** logical reads, which is
   why logical reads stays the headline metric. These are server-level settings;
   they are documented, not changed (one-change rule).

3. **`max server memory` unlimited.** Buffer-pool size depends on host RAM and
   affects warm-vs-cold (physical reads), not logical reads. Cold/warm state is
   controlled explicitly via the lab-protocol DBCC commands.

4. **tempdb is correctly *filed* but badly *sized*.** Eight equal data files is
   good practice (reduces allocation-page contention), but 8 MB each is tiny. Any
   sort/hash spill, or `CREATE INDEX ... SORT_IN_TEMPDB = ON`, immediately
   exceeds the ~64 MB total and triggers autogrowth **mid-operation** — the exact
   distortion vector for read-only SELECT measurements.

### Lab-setup action (environment, not a per-query change)

Pre-grow the tempdb data files to a sane fixed size (a few hundred MB to ~1 GB
each, equal-sized) before measuring or building indexes, so autogrowth never
fires during a timed operation. This is environment preparation and does not
violate the one-change-per-measurement rule.

---

## Discovery summary (Phase 1 complete)

The picture the six steps assemble:

- **Scale is real** — ~51 GB, `Posts` alone ~37 GB (~80% of the database) due to
  its wide `Body` column; `Votes` is huge in rows (53M) but narrow in bytes.
- **The database is a blank canvas for indexing** — exactly one clustered PK on
  `Id` per table, **zero nonclustered indexes**, zero heaps. The only seekable
  column anywhere is `Id`.
- **No declared foreign keys** — relationships exist only conceptually; the join
  columns (`OwnerUserId`, `PostId`, `UserId`, `ParentId`, …) are all unindexed.
- **Statistics cover only `Id`** — accurate and not stale, but the predicate
  columns have no statistic until a query auto-creates a *sampled* one (skew risk
  → estimate/actual gaps).
- **Config is parallel-prone with a tiny tempdb** — keep logical reads as the
  deterministic headline metric; pre-size tempdb for clean timings.

**Implication for the case studies:** every slow page in the engagement scenario
traces to forced scans on unindexed predicate/join columns. Each case adds the
*first* index on its target column, so before/after improvements will be large
and cleanly attributable.
