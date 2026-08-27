USE [master];
SET NOCOUNT ON;
IF CONVERT(sysname,SERVERPROPERTY('ServerName'))<>N'WIN-5RQE8N8NQ9V' THROW 51060,'STOP: servidor incorrecto.',1;
IF DB_ID(N'DDR001_Hidrantes_Prod') IS NULL OR DB_ID(N'DDR001_Hidrantes_TEST') IS NULL THROW 51061,'STOP: falta PROD o TEST.',1;
IF (SELECT recovery_model_desc FROM sys.databases WHERE name=N'DDR001_Hidrantes_Prod')<>N'FULL' THROW 51062,'STOP: PROD no está FULL; no se modificó nada.',1;
ALTER DATABASE [DDR001_Hidrantes_TEST] SET RECOVERY SIMPLE;
SELECT name,recovery_model_desc FROM sys.databases WHERE name IN(N'DDR001_Hidrantes_Prod',N'DDR001_Hidrantes_TEST') ORDER BY name;
IF (SELECT recovery_model_desc FROM sys.databases WHERE name=N'DDR001_Hidrantes_TEST')<>N'SIMPLE' THROW 51063,'STOP: TEST no quedó SIMPLE.',1;
