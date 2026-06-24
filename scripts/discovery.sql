/* ============================================================================
   Phase 1 — DISCOVERY: read-only database inventory.

   Every statement below is read-only and safe to run on production. It produces
   the inventory written up in ../discovery/discovery-findings.md:
     1. Database size & files
     2. Table sizes & row counts
     3. Existing index inventory
     4. Foreign keys / relationships
     5. Statistics state & freshness
     6. Server & database configuration

   Run section by section in SSMS; nothing here modifies data or schema.
   ============================================================================ */


/* ---------------------------------------------------------------------------
   1. Database size & files
   --------------------------------------------------------------------------- */
EXEC sp_spaceused;

SELECT name, type_desc, size/128.0 AS size_mb,
       size/128.0 - CAST(FILEPROPERTY(name,'SpaceUsed') AS int)/128.0 AS free_mb
FROM sys.database_files;


/* ---------------------------------------------------------------------------
   2. Table sizes & row counts
   --------------------------------------------------------------------------- */
SELECT
    t.name AS table_name,
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END) AS [rows],
    CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS DECIMAL(12,1)) AS total_mb,
    CAST(SUM(CASE WHEN ps.index_id IN (0,1)
                  THEN ps.used_page_count ELSE 0 END) * 8 / 1024.0 AS DECIMAL(12,1)) AS data_mb,
    CAST(SUM(CASE WHEN ps.index_id > 1
                  THEN ps.used_page_count ELSE 0 END) * 8 / 1024.0 AS DECIMAL(12,1)) AS index_mb
FROM sys.dm_db_partition_stats ps
JOIN sys.tables t ON ps.object_id = t.object_id
WHERE t.is_ms_shipped = 0
GROUP BY t.name
ORDER BY total_mb DESC;


/* ---------------------------------------------------------------------------
   3. Existing index inventory (key vs. included columns)
   --------------------------------------------------------------------------- */
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name        AS index_name,
    i.type_desc   AS index_type,
    i.is_primary_key,
    i.is_unique,
    STUFF((SELECT ', ' + c.name
           FROM sys.index_columns ic
           JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
             AND ic.is_included_column = 0
           ORDER BY ic.key_ordinal
           FOR XML PATH('')), 1, 2, '') AS key_columns,
    STUFF((SELECT ', ' + c.name
           FROM sys.index_columns ic
           JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
             AND ic.is_included_column = 1
           ORDER BY ic.index_column_id
           FOR XML PATH('')), 1, 2, '') AS included_columns
FROM sys.indexes i
JOIN sys.tables t ON i.object_id = t.object_id
WHERE t.is_ms_shipped = 0
ORDER BY table_name, i.index_id;


/* ---------------------------------------------------------------------------
   4. Foreign keys / relationships
   --------------------------------------------------------------------------- */
SELECT
    fk.name AS fk_name,
    OBJECT_NAME(fk.parent_object_id)     AS child_table,
    cpa.name                             AS child_column,
    OBJECT_NAME(fk.referenced_object_id) AS parent_table,
    cref.name                            AS parent_column,
    fk.is_disabled,
    fk.is_not_trusted
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
JOIN sys.columns cpa  ON fkc.parent_object_id = cpa.object_id     AND fkc.parent_column_id = cpa.column_id
JOIN sys.columns cref ON fkc.referenced_object_id = cref.object_id AND fkc.referenced_column_id = cref.column_id
ORDER BY child_table, fk_name;

-- Quick count:
SELECT COUNT(*) AS fk_count FROM sys.foreign_keys;


/* ---------------------------------------------------------------------------
   5. Statistics state
   --------------------------------------------------------------------------- */
-- 5a. Database-level auto-statistics options
SELECT name,
       is_auto_create_stats_on,
       is_auto_update_stats_on,
       is_auto_update_stats_async_on
FROM sys.databases
WHERE name = DB_NAME();

-- 5b. Statistics inventory + freshness
SELECT
    OBJECT_NAME(s.object_id) AS table_name,
    s.name        AS stat_name,
    s.auto_created,
    s.user_created,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows,0) AS DECIMAL(5,2)) AS sampled_pct,
    sp.modification_counter,
    sp.steps
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
JOIN sys.tables t ON s.object_id = t.object_id
WHERE t.is_ms_shipped = 0
ORDER BY table_name, stat_name;


/* ---------------------------------------------------------------------------
   6. Server & database configuration
   --------------------------------------------------------------------------- */
-- 6a. Version, edition, compat level, Query Store
SELECT
    SERVERPROPERTY('ProductVersion') AS product_version,
    SERVERPROPERTY('Edition')        AS edition,
    SERVERPROPERTY('ProductLevel')   AS product_level,
    d.compatibility_level,
    d.is_query_store_on
FROM sys.databases d
WHERE d.name = DB_NAME();

-- 6b. Key instance settings
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN (
    'max degree of parallelism',
    'cost threshold for parallelism',
    'max server memory (MB)',
    'min server memory (MB)',
    'optimize for ad hoc workloads'
)
ORDER BY name;

-- 6c. tempdb files (spill / SORT_IN_TEMPDB vector)
SELECT name, type_desc, size/128.0 AS size_mb
FROM sys.master_files
WHERE database_id = DB_ID('tempdb');
