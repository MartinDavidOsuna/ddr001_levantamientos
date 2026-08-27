USE [master];
SET NOCOUNT ON;
IF CONVERT(sysname,SERVERPROPERTY('ServerName'))<>N'WIN-5RQE8N8NQ9V' THROW 51080,'STOP: servidor incorrecto.',1;
IF DB_ID(N'DDR001_Hidrantes_TEST') IS NULL THROW 51081,'STOP: TEST no existe.',1;
IF N'Agrienlace2001!' LIKE N'<%>' THROW 51082,'STOP: sustituya <MIGRATOR_PASSWORD>.',1;
IF SUSER_ID(N'DDR001_Levantamientos_TEST_Migrator') IS NOT NULL THROW 51083,'STOP: login Migrator ya existe; no se reemplazó.',1;
CREATE LOGIN [DDR001_Levantamientos_TEST_Migrator] WITH PASSWORD=N'Agrienlace2001!',DEFAULT_DATABASE=[DDR001_Hidrantes_TEST],CHECK_POLICY=ON,CHECK_EXPIRATION=OFF;
DENY VIEW ANY DATABASE TO [DDR001_Levantamientos_TEST_Migrator];
USE [DDR001_Hidrantes_TEST];
CREATE USER [DDR001_Levantamientos_TEST_Migrator] FOR LOGIN [DDR001_Levantamientos_TEST_Migrator] WITH DEFAULT_SCHEMA=[dbo];
GRANT CONNECT TO [DDR001_Levantamientos_TEST_Migrator];

-- FASE POSTERIOR: NO EJECUTAR AHORA. Sólo después de autorizar feature/construction-field-app,
-- crear el schema construction bajo control del operador y cambiar default_schema a construction.
-- CREATE SCHEMA [construction] AUTHORIZATION [dbo];
-- ALTER USER [DDR001_Levantamientos_TEST_Migrator] WITH DEFAULT_SCHEMA=[construction];
-- GRANT CREATE TABLE,CREATE VIEW,CREATE PROCEDURE,CREATE FUNCTION TO [DDR001_Levantamientos_TEST_Migrator];
-- GRANT CONTROL ON SCHEMA::[construction] TO [DDR001_Levantamientos_TEST_Migrator];
-- No conceder ALTER sobre rv/dbo, db_ddladmin ni db_owner.

USE [master];
EXECUTE AS LOGIN=N'DDR001_Levantamientos_TEST_Migrator';
BEGIN TRY USE [DDR001_Hidrantes_TEST]; SELECT DB_NAME() database_name,'TEST_ACCESS_OK_DDL_NOT_ENABLED' result; END TRY BEGIN CATCH SELECT ERROR_MESSAGE() error,'TEST_ACCESS_FAILED_STOP' result; END CATCH;
REVERT;
EXECUTE AS LOGIN=N'DDR001_Levantamientos_TEST_Migrator';
BEGIN TRY USE [DDR001_Hidrantes_Prod]; SELECT DB_NAME() database_name,'PROD_ACCESS_UNEXPECTED_STOP' result; END TRY BEGIN CATCH SELECT ERROR_MESSAGE() error,'PROD_ACCESS_DENIED_OK' result; END CATCH;
REVERT;
