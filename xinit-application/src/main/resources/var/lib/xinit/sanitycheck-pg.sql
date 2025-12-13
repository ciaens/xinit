-- PostgreSQL Sanity Check for XWiki Database
-- Xinit 2.0

\echo ''
\echo '=========================================='
\echo 'XWiki Database Sanity Check (PostgreSQL)'
\echo '=========================================='
\echo ''

\echo 'Database Size:'
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;

\echo ''
\echo 'XWiki Tables Count:'
SELECT COUNT(*) AS xwiki_tables_count
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name LIKE 'xwiki%';

\echo ''
\echo 'Total Documents:'
SELECT COUNT(*) AS total_documents FROM xwikidoc;

\echo ''
\echo 'Total Attachments:'
SELECT COUNT(*) AS total_attachments FROM xwikiattachment;

\echo ''
\echo 'Total Objects:'
SELECT COUNT(*) AS total_objects FROM xwikiobjects;

\echo ''
\echo 'Attachment Storage Size:'
SELECT pg_size_pretty(SUM(LENGTH(xwa_content::bytea))::bigint) AS attachment_size
FROM xwikiattachment_content;

\echo ''
\echo 'Orphaned Objects (objects without documents):'
SELECT COUNT(*) AS orphaned_objects
FROM xwikiobjects o
LEFT JOIN xwikidoc d ON o.xwo_name = d.xwd_fullname
WHERE d.xwd_fullname IS NULL;

\echo ''
\echo 'Orphaned Attachments (attachments without documents):'
SELECT COUNT(*) AS orphaned_attachments
FROM xwikiattachment a
LEFT JOIN xwikidoc d ON a.xda_docid = d.xwd_id
WHERE d.xwd_id IS NULL;

\echo ''
\echo 'Documents by Space (Top 10):'
SELECT SUBSTRING(xwd_fullname FROM 1 FOR POSITION('.' IN xwd_fullname) - 1) AS space,
       COUNT(*) AS doc_count
FROM xwikidoc
WHERE POSITION('.' IN xwd_fullname) > 0
GROUP BY space
ORDER BY doc_count DESC
LIMIT 10;

\echo ''
\echo 'Largest Documents (by content size, Top 10):'
SELECT xwd_fullname,
       pg_size_pretty(LENGTH(xwd_content::text)::bigint) AS content_size
FROM xwikidoc
ORDER BY LENGTH(xwd_content::text) DESC
LIMIT 10;

\echo ''
\echo 'Recent Activity (Last 20 document updates):'
SELECT xwd_fullname,
       xwd_author,
       TO_CHAR(TO_TIMESTAMP(xwd_date / 1000), 'YYYY-MM-DD HH24:MI:SS') AS last_modified
FROM xwikidoc
ORDER BY xwd_date DESC
LIMIT 20;

\echo ''
\echo 'Sanity check complete.'
\echo ''
