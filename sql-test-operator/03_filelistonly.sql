USE [master];
SET NOCOUNT ON;
DECLARE @Backup nvarchar(4000)=N'C:\Servicios IT\BasesDeDatos\MSSQL\Backup\DDR001_Hidrantes_Prod_COPY_ONLY_20260826_174257.bak';
IF @Backup LIKE N'%<BACKUP_FILE>%'
    THROW 51020,'STOP: sustituya <BACKUP_FILE>.',1;
DECLARE @Exists table(FileExists int,FileIsDirectory int,ParentDirectoryExists int);
INSERT @Exists EXEC master.dbo.xp_fileexist @Backup;
IF NOT EXISTS(SELECT 1 FROM @Exists WHERE FileExists=1)
    THROW 51021,'STOP: el backup no existe/no es visible para SQL Server.',1;
DECLARE @Sql nvarchar(max)=N'RESTORE FILELISTONLY FROM DISK=N'''+REPLACE(@Backup,'''','''''')+N''';';
EXEC sys.sp_executesql @Sql;
-- Copiar LogicalName, PhysicalName, Type, FileGroupName, Size, MaxSize y FileId.
-- STOP si no hay exactamente una fila Type=D y una Type=L.
