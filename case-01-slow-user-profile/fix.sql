/* ============================================================
   Case 01 - Slow user-profile page
   Phase 4-6: Fix (the ONE change) + re-measurement ("after")

   Run on the ISOLATED LAB INSTANCE only.
   Measurement rules: lab-protocol.md (cold cache, 3 runs,
   record steady-state, change exactly one thing between
   before/after).
   ============================================================ */

USE StackOverflow2013;
GO

/* ------------------------------------------------------------
   THE ONE CHANGE - a single nonclustered covering index.

   - Key (OwnerUserId, CreationDate DESC):
       * OwnerUserId  -> turns the full scan into a seek.
       * CreationDate DESC -> rows pre-sorted newest-first, so
         the ORDER BY is satisfied by the index -> no Top N Sort.
   - INCLUDE (PostTypeId, Score, Title, ViewCount):
       covers the SELECT list -> no key lookup.
   - SORT_IN_TEMPDB = ON keeps the build's transient sort out of
     the data filegroup (discovery: ~3.8 GB free; tempdb pre-sized).

   This is deliberately stronger than the missing-index DMV hint,
   which would key on OwnerUserId alone and leave the Top N Sort.
   ------------------------------------------------------------ */
CREATE NONCLUSTERED INDEX IX_Posts_OwnerUserId_CreationDate
ON dbo.Posts (OwnerUserId, CreationDate DESC)
INCLUDE (PostTypeId, Score, Title, ViewCount)
WITH (SORT_IN_TEMPDB = ON);
GO

/* Optional: confirm the index size for the trade-offs section.
   SELECT i.name,
          SUM(ps.used_page_count) * 8 / 1024.0 AS index_mb
   FROM sys.indexes i
   JOIN sys.dm_db_partition_stats ps
     ON ps.object_id = i.object_id AND ps.index_id = i.index_id
   WHERE i.name = 'IX_Posts_OwnerUserId_CreationDate'
   GROUP BY i.name;                       -- expected ~1,203 MB */


/* ------------------------------------------------------------
   RE-MEASURE ("after") - exact same query, same cold-cache
   protocol, SAME UserId (22656) as the baseline run.
   Save the Actual Execution Plan to results/after.sqlplan
   and a screenshot to results/after.png.
   ------------------------------------------------------------ */
DBCC FREEPROCCACHE;        -- lab only
DBCC DROPCLEANBUFFERS;     -- lab only
GO

SET STATISTICS IO, TIME ON;
GO

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
GO

SET STATISTICS IO, TIME OFF;
GO

/*  Expected after the fix (steady state, 3 runs):
      Logical reads : 7
      CPU time (ms) : ~0
      Elapsed (ms)  : 6
      Plan          : Index Seek (IX_Posts_OwnerUserId_CreationDate)
                      -> Top -> SELECT. Serial (DOP 1), TRIVIAL plan,
                      no Sort, no Key Lookup. Est vs actual rows 50/50.
*/


/* ------------------------------------------------------------
   OPTIONAL - reset to the pre-case blank canvas:
   DROP INDEX IX_Posts_OwnerUserId_CreationDate ON dbo.Posts;
   ------------------------------------------------------------ */
