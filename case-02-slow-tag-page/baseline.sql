/* ============================================================================
   Case 02 - Slow tag page
   Phase 2: BASELINE (capture "before" metrics + actual execution plan)

   Business symptom (engagement brief):
     "Tag pages load slowly, especially under load."

   Target query: a tag listing page - the 50 newest questions carrying a given
   tag. Tags are stored in dbo.Posts.Tags as a single delimited string, e.g.
   "<javascript><node.js><express>". A tag page therefore filters with a
   substring match against that column.

   Conventions (consistent with lab-protocol.md and Case 01):
     - Literal tag value, NOT a parameter/local variable. Removes parameter
       sniffing as a confounder so the plan reflects this exact predicate.
     - Body (nvarchar(max)) is NOT selected. It is stored off-row, so excluding
       it keeps logical reads attributable to the in-row data we actually read.
     - TOP 50 + ORDER BY CreationDate DESC = "newest first", one page of results.
     - Angle-bracket delimiters in the LIKE pattern ('%<javascript>%') give an
       exact-tag match. '<' and '>' are NOT LIKE metacharacters (unlike '[' ']'),
       so the pattern matches the tag <javascript> and not a substring inside
       another tag such as <unobtrusive-javascript>.

   Measurement: per lab-protocol.md - COLD CACHE, run 3x, report steady state.
   The DBCC commands below are LAB-ONLY. Never run them on a production server.
   Capture the Actual Execution Plan (Ctrl+M in SSMS) -> results/before.sqlplan.
============================================================================ */

USE StackOverflow2013;
GO

-- Lab only: clear plan cache and buffer pool for a fair cold-start comparison.
-- NEVER run these on a production server.
DBCC FREEPROCCACHE;
DBCC DROPCLEANBUFFERS;
GO

SET STATISTICS IO, TIME ON;
GO

-- ---- Target query: tag page (50 newest questions tagged "javascript") --------
SELECT TOP (50)
       p.Id,
       p.Title,
       p.Score,
       p.ViewCount,
       p.AnswerCount,
       p.CreationDate
FROM   dbo.Posts AS p
WHERE  p.Tags LIKE '%<javascript>%'
ORDER  BY p.CreationDate DESC;
-- -----------------------------------------------------------------------------

SET STATISTICS IO, TIME OFF;
GO
