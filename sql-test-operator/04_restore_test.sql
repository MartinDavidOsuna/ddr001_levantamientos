USE [master];
SET NOCOUNT ON;

DECLARE @Backup nvarchar(4000)=
N'C:\Servicios IT\BasesDeDatos\MSSQL\Backup\DDR001_Hidrantes_Prod_COPY_ONLY_20260826_174257.bak';

DECLARE @DataLogical sysname=
N'DDR001_Hidrantes_Prod';

DECLARE @LogLogical sysname=
N'DDR001_Hidrantes_Prod_log';

DECLARE @Mdf nvarchar(4000)=
N'C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST.mdf';

DECLARE @Ldf nvarchar(4000)=
N'C:\Servicios IT\BasesDeDatos\MSSQL\Data\DDR001_Hidrantes_TEST_log.ldf';


IF CONVERT(sysname,SERVERPROPERTY('ServerName'))<>N'WIN-5RQE8N8NQ9V'
    THROW 51030,'STOP: servidor incorrecto.',1;

IF DB_ID(N'DDR001_Hidrantes_TEST') IS NOT NULL
    THROW 51031,'STOP: TEST ya existe.',1;


DECLARE @E table
(
    FileExists int,
    FileIsDirectory int,
    ParentDirectoryExists int
);

INSERT @E
EXEC master.dbo.xp_fileexist @Backup;

IF NOT EXISTS
(
    SELECT 1
    FROM @E
    WHERE FileExists=1
)
    THROW 51033,'STOP: backup inexistente.',1;


DELETE FROM @E;

INSERT @E
EXEC master.dbo.xp_fileexist @Mdf;

IF EXISTS
(
    SELECT 1
    FROM @E
    WHERE FileExists=1
)
    THROW 51034,'STOP: MDF TEST ya existe.',1;


DELETE FROM @E;

INSERT @E
EXEC master.dbo.xp_fileexist @Ldf;

IF EXISTS
(
    SELECT 1
    FROM @E
    WHERE FileExists=1
)
    THROW 51035,'STOP: LDF TEST ya existe.',1;


DECLARE @Sql nvarchar(max)=
N'RESTORE DATABASE [DDR001_Hidrantes_TEST]
FROM DISK=N''' + REPLACE(@Backup,'''','''''') + N'''
WITH
    MOVE N''' + REPLACE(@DataLogical,'''','''''') + N'''
        TO N''' + REPLACE(@Mdf,'''','''''') + N''',
    MOVE N''' + REPLACE(@LogLogical,'''','''''') + N'''
        TO N''' + REPLACE(@Ldf,'''','''''') + N''',
    RECOVERY,
    CHECKSUM,
    STATS=10;';

EXEC sys.sp_executesql @Sql;


IF DB_ID(N'DDR001_Hidrantes_TEST') IS NULL
    THROW 51036,'STOP: restore no creó TEST.',1;


SELECT
    d.name,
    d.state_desc,
    d.recovery_model_desc,
    mf.file_id,
    mf.name AS logical_name,
    mf.type_desc,
    mf.physical_name,
    CAST(mf.size*8.0/1024 AS decimal(18,2)) AS size_mb
FROM sys.databases d
JOIN sys.master_files mf
    ON mf.database_id=d.database_id
WHERE d.name=N'DDR001_Hidrantes_TEST'
ORDER BY mf.file_id;