USE [master];
SET NOCOUNT ON;

IF CONVERT(sysname,SERVERPROPERTY('ServerName'))<>N'WIN-5RQE8N8NQ9V'
    THROW 51010,'STOP: servidor incorrecto.',1;
IF DB_ID(N'DDR001_Hidrantes_Prod') IS NULL
    THROW 51011,'STOP: producción no existe.',1;
IF DB_ID(N'DDR001_Hidrantes_TEST') IS NOT NULL
    THROW 51012,'STOP: TEST ya existe; no continúe.',1;

DECLARE @Stamp char(15)=CONVERT(char(8),GETDATE(),112)+'_'+REPLACE(CONVERT(char(8),GETDATE(),108),':','');
DECLARE @File nvarchar(4000)=N'C:\Servicios IT\BasesDeDatos\MSSQL\Backup\DDR001_Hidrantes_Prod_COPY_ONLY_'+@Stamp+N'.bak';
DECLARE @Name nvarchar(128)=N'DDR001_Hidrantes_Prod COPY_ONLY '+@Stamp;
DECLARE @Exists table(FileExists int, FileIsDirectory int, ParentDirectoryExists int);
INSERT @Exists EXEC master.dbo.xp_fileexist @File;
IF EXISTS(SELECT 1 FROM @Exists WHERE FileExists=1)
    THROW 51013,'STOP: el archivo target ya existe.',1;
IF NOT EXISTS(SELECT 1 FROM @Exists WHERE ParentDirectoryExists=1)
    THROW 51014,'STOP: el directorio de backup no existe/no es visible para SQL Server.',1;

SELECT @File AS planned_backup_file,@Name AS backup_name;
DECLARE @Sql nvarchar(max)=N'BACKUP DATABASE [DDR001_Hidrantes_Prod] TO DISK=N'''+REPLACE(@File,'''','''''')+N''' WITH COPY_ONLY,CHECKSUM,INIT,NAME=N'''+REPLACE(@Name,'''','''''')+N''',STATS=10;';
EXEC sys.sp_executesql @Sql;

SET @Sql=N'RESTORE VERIFYONLY FROM DISK=N'''+REPLACE(@File,'''','''''')+N''' WITH CHECKSUM;';
EXEC sys.sp_executesql @Sql;
SELECT 'BACKUP_AND_VERIFY_OK' AS result,@File AS backup_file,@Name AS backup_name;
