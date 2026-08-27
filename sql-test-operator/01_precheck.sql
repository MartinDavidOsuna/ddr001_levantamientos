SET NOCOUNT ON;

DECLARE @ExpectedServer sysname = N'WIN-5RQE8N8NQ9V';
DECLARE @Prod sysname = N'DDR001_Hidrantes_Prod';
DECLARE @Test sysname = N'DDR001_Hidrantes_TEST';

IF CONVERT(sysname, SERVERPROPERTY('ServerName')) <> @ExpectedServer
    THROW 51000, 'STOP: servidor incorrecto. Debe ser WIN-5RQE8N8NQ9V.', 1;
IF DB_ID(@Prod) IS NULL
    THROW 51001, 'STOP: no existe DDR001_Hidrantes_Prod.', 1;
IF DB_ID(@Test) IS NOT NULL
    THROW 51002, 'STOP: DDR001_Hidrantes_TEST ya existe.', 1;

SELECT
    CASE WHEN CONVERT(sysname, SERVERPROPERTY('ServerName'))=@ExpectedServer THEN 'OK' ELSE 'STOP' END AS server_name_check,
    @@SERVERNAME AS at_at_servername,
    CONVERT(sysname, SERVERPROPERTY('ServerName')) AS server_property_name,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS product_version,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel')) AS product_level,
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS edition,
    @@VERSION AS full_version,
    ORIGINAL_LOGIN() AS original_login,
    SUSER_SNAME() AS current_login;

SELECT name, state_desc, recovery_model_desc, compatibility_level,
       user_access_desc, is_read_only
FROM sys.databases
WHERE name=@Prod;

SELECT DB_NAME(mf.database_id) AS database_name, mf.file_id, mf.name AS logical_name,
       mf.type_desc, mf.physical_name,
       CAST(mf.size*8.0/1024 AS decimal(18,2)) AS size_mb,
       CASE WHEN mf.max_size=-1 THEN NULL ELSE CAST(mf.max_size*8.0/1024 AS decimal(18,2)) END AS max_size_mb,
       CASE WHEN mf.is_percent_growth=1 THEN CONVERT(nvarchar(30),mf.growth)+N'%'
            ELSE CONVERT(nvarchar(30),CAST(mf.growth*8.0/1024 AS decimal(18,2)))+N' MB' END AS growth
FROM sys.master_files mf
WHERE mf.database_id=DB_ID(@Prod)
ORDER BY mf.file_id;

SELECT CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath')) AS default_data_path,
       CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultLogPath')) AS default_log_path,
       CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultBackupPath')) AS default_backup_path;

SELECT permission_name,
       HAS_PERMS_BY_NAME(NULL,NULL,permission_name) AS has_permission
FROM (VALUES ('VIEW SERVER STATE'),('CREATE ANY DATABASE'),('ALTER ANY DATABASE')) p(permission_name);

SELECT HAS_PERMS_BY_NAME(@Prod,'DATABASE','CONNECT') AS can_connect_prod,
       HAS_PERMS_BY_NAME(@Prod,'DATABASE','BACKUP DATABASE') AS can_backup_prod,
       IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin,
       IS_SRVROLEMEMBER('dbcreator') AS is_dbcreator;

-- Espacio visible para el usuario actual. Puede fallar/ser parcial según permisos del SO/servicio.
EXEC master.dbo.xp_fixeddrives;

SELECT 'PRECHECK_OK' AS result;
