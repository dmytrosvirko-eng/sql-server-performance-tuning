/* ============================================================================
   Case 02 - Slow tag page
   Phase 4: OPTIMIZE (build + measure two index variants)

   We test TWO covering-index designs, each as a single change measured against
   the same no-index baseline (logical reads = 4,186,226; full Clustered Index
   Scan + Top N Sort, DOP 6). To keep each comparison clean we DROP variant A
   before building variant B, so neither index influences the other's plan.

   Why two indexes at all: the predicate `Tags LIKE '%<...>%'` is non-SARGable,
   so NO index can seek. The goal is not a seek - it is to replace the scan of
   the 32 GB clustered index with a scan of a small covering index, and (for B)
   to exploit index order so the TOP can stop early.

     Variant A (naive): key on the filtered column (Tags). Turns the wide
       clustered scan into a narrow index scan, but the index is ordered by Tags,
       so the Top N Sort REMAINS.
     Variant B (ordered): key on CreationDate DESC, Tags carried as INCLUDE. The
       index is pre-ordered by date, so the optimizer can scan top-down, apply
       the LIKE as a residual on the included Tags, and STOP after 50 matches
       (ordered TOP, early exit). No sort; reads collapse to a small prefix.

   Pre-conditions (from Discovery Phase 1, Section 6):
     - tempdb is 8 x 8 MB (too small). SORT_IN_TEMPDB would autogrow it
       mid-build. Pre-grow it first (Step 0) so growth never coincides with work.
     - SORT_IN_TEMPDB = ON keeps the build sort out of the data filegroup.
     - ONLINE = ON (Enterprise/Evaluation) - non-blocking build.

   Measurement: per lab-protocol.md - COLD CACHE, run each query block 3x,
   report steady state. DBCC commands are LAB-ONLY. Save actual plans to
   results/after_A.sqlplan and results/after_B.sqlplan.
============================================================================ */

USE StackOverflow2013;
GO

/* ============================================================================
   STEP 0 - Pre-grow tempdb (environment prep, run ONCE; not a per-query change)

   Confirm the logical file names first; default names are tempdev, temp2..temp8.
   Adjust the ALTER statements below if your names differ.
============================================================================ */
SELECT name, type_desc, size/128.0 AS size_mb
FROM   sys.master_files
WHERE  database_id = DB_ID('tempdb');
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev', SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp2',   SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp3',   SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp4',   SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp5',   SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp6',   SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp7',   SIZE = 1024MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'temp8',   SIZE = 1024MB);
GO


/* ============================================================================
   ===========================  VARIANT A  ====================================
   ============================================================================ */

/* ---- STEP A1: build the naive covering index (key = Tags) ---------------- */
CREATE NONCLUSTERED INDEX IX_Posts_Tags
ON dbo.Posts (Tags)
INCLUDE (Title, Score, ViewCount, AnswerCount, CreationDate)
WITH (SORT_IN_TEMPDB = ON, ONLINE = ON, MAXDOP = 6);
GO

/* ---- STEP A2: MEASURE variant A (run this whole block 3x, cold) ----------- */
DBCC FREEPROCCACHE;        -- lab only, never on production
DBCC DROPCLEANBUFFERS;     -- lab only, never on production
GO
SET STATISTICS IO, TIME ON;
GO
SELECT TOP (50)
       p.Id, p.Title, p.Score, p.ViewCount, p.AnswerCount, p.CreationDate
FROM   dbo.Posts AS p
WHERE  p.Tags LIKE '%<javascript>%'
ORDER  BY p.CreationDate DESC;
GO
SET STATISTICS IO, TIME OFF;
GO
-- Capture the actual plan -> results/after_A.sqlplan

/* ---- STEP A3: drop variant A to return to the clean baseline -------------- */
DROP INDEX IX_Posts_Tags ON dbo.Posts;
GO


/* ============================================================================
   ===========================  VARIANT B  ====================================
   ============================================================================ */

/* ---- STEP B1: build the ordered covering index (key = CreationDate DESC) -- */
CREATE NONCLUSTERED INDEX IX_Posts_CreationDate
ON dbo.Posts (CreationDate DESC)
INCLUDE (Tags, Title, Score, ViewCount, AnswerCount)
WITH (SORT_IN_TEMPDB = ON, ONLINE = ON, MAXDOP = 6);
GO

/* ---- STEP B2: MEASURE variant B (run this whole block 3x, cold) ----------- */
DBCC FREEPROCCACHE;        -- lab only, never on production
DBCC DROPCLEANBUFFERS;     -- lab only, never on production
GO
SET STATISTICS IO, TIME ON;
GO
SELECT TOP (50)
       p.Id, p.Title, p.Score, p.ViewCount, p.AnswerCount, p.CreationDate
FROM   dbo.Posts AS p
WHERE  p.Tags LIKE '%<javascript>%'
ORDER  BY p.CreationDate DESC;
GO
SET STATISTICS IO, TIME OFF;
GO
-- Capture the actual plan -> results/after_B.sqlplan

/* ---- STEP B3 (optional): keep IX_Posts_CreationDate or drop it ------------
   DROP INDEX IX_Posts_CreationDate ON dbo.Posts;
   GO
============================================================================ */
