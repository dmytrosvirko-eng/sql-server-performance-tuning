/* ============================================================
   Case 01 - Slow user-profile page
   Phase 2: Baseline measurement ("before")

   Run on the ISOLATED LAB INSTANCE only.
   Measurement rules: lab-protocol.md (cold cache, 3 runs,
   record steady-state, change exactly one thing between
   before/after).
   ============================================================ */

USE StackOverflow2013;
GO

/* ------------------------------------------------------------
   Cold-cache reset.
   LAB ONLY - these commands would hurt a production server.
   For a scan-bound query, logical reads are identical cold or
   warm; the DBCC reset only affects physical reads / elapsed.
   ------------------------------------------------------------ */
DBCC FREEPROCCACHE;
DBCC DROPCLEANBUFFERS;
GO

SET STATISTICS IO, TIME ON;
GO

/* ------------------------------------------------------------
   Query under test - profile "recent activity" list:
   a user's posts, newest first.

   Notes:
   - Literal parameter on purpose -> histogram-based estimate.
     This keeps the ONLY variable between before/after the index
     itself, not parameter sniffing (a candidate for a later case).
   - Body is intentionally not selected (nvarchar(max), ~37 GB
     table) per the discovery indexing lesson.
   - 22656 = a representative high-activity user. Use the SAME
     UserId for the "after" run.
   ------------------------------------------------------------ */
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
/* Capture the Actual Execution Plan (Ctrl+M in SSMS) and save:
     results/before.sqlplan
     results/before.png
   Copy the STATISTICS IO/TIME text (Messages tab) into the case. */

SET STATISTICS IO, TIME OFF;
GO

/* ------------------------------------------------------------
   Run discipline (lab-protocol.md):
   1. Run 3 times; record steady-state numbers.
   2. Run 1 (right after the DBCC block) = cold cache.
      Runs 2-3 = warm. Logical reads should be ~constant across
      all three (deterministic) - that is the headline metric.
   3. Report the same cache mode for before and after.
   ------------------------------------------------------------ */
