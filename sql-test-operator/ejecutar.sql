USE [DDR001_Hidrantes_TEST];
GO

SELECT
    cc.name AS constraint_name,
    cc.definition
FROM sys.check_constraints cc
JOIN sys.tables t
    ON cc.parent_object_id = t.object_id
JOIN sys.schemas s
    ON t.schema_id = s.schema_id
WHERE
    s.name = N'rv'
    AND t.name = N'persistent_field_sessions'
    AND cc.name = N'CK_persistent_sessions_revocation';
GO

SELECT
    c.column_id,
    c.name AS column_name,
    TYPE_NAME(c.user_type_id) AS data_type,
    c.max_length,
    c.is_nullable
FROM sys.columns c
JOIN sys.tables t
    ON c.object_id = t.object_id
JOIN sys.schemas s
    ON t.schema_id = s.schema_id
WHERE
    s.name = N'rv'
    AND t.name = N'persistent_field_sessions'
ORDER BY c.column_id;
GO

SELECT TOP (20) *
FROM rv.persistent_field_sessions
ORDER BY created_at DESC;
GO