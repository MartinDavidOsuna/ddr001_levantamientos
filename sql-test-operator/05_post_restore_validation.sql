USE [master];
SET NOCOUNT ON;
IF DB_ID(N'DDR001_Hidrantes_Prod') IS NULL OR DB_ID(N'DDR001_Hidrantes_TEST') IS NULL
    THROW 51040,'STOP: PROD o TEST no existe.',1;

DECLARE @Counts table(table_name sysname,prod_count bigint,test_count bigint);
INSERT @Counts VALUES
(N'rv.users',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.users),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.users)),
(N'rv.hydrants',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.hydrants),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.hydrants)),
(N'rv.inspections',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.inspections),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.inspections)),
(N'rv.photos',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.photos),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.photos)),
(N'rv.visual_reports',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.visual_reports),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.visual_reports)),
(N'rv.visual_report_versions',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.visual_report_versions),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.visual_report_versions)),
(N'rv.visual_report_version_photos',(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_Prod.rv.visual_report_version_photos),(SELECT COUNT_BIG(*) FROM DDR001_Hidrantes_TEST.rv.visual_report_version_photos));
SELECT table_name,prod_count,test_count,test_count-prod_count AS difference,
       CASE WHEN prod_count=test_count THEN 'OK' ELSE 'STOP' END AS result
FROM @Counts ORDER BY table_name;
IF EXISTS(SELECT 1 FROM @Counts WHERE prod_count<>test_count)
    THROW 51041,'STOP: conteos PROD/TEST diferentes.',1;
DBCC CHECKDB([DDR001_Hidrantes_TEST]) WITH NO_INFOMSGS,ALL_ERRORMSGS;
SELECT 'COUNTS_EQUAL_CHECKDB_COMPLETED_REVIEW_MESSAGES' AS result;
