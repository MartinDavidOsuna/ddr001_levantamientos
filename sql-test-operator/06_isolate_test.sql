USE [DDR001_Hidrantes_TEST];
SET NOCOUNT ON;
SET XACT_ABORT ON;

------------------------------------------------------------
-- GUARDAS DE SEGURIDAD
------------------------------------------------------------

IF DB_NAME() = N'DDR001_Hidrantes_Prod'
BEGIN
    RAISERROR('STOP: jamás ejecutar en PROD.', 16, 1);
    RETURN;
END;

IF DB_NAME() <> N'DDR001_Hidrantes_TEST'
BEGIN
    RAISERROR('STOP: contexto debe ser TEST.', 16, 1);
    RETURN;
END;

IF CONVERT(sysname, SERVERPROPERTY('ServerName')) <> N'WIN-5RQE8N8NQ9V'
BEGIN
    RAISERROR('STOP: servidor incorrecto.', 16, 1);
    RETURN;
END;


------------------------------------------------------------
-- VALIDAR ESTRUCTURA DE TABLAS
------------------------------------------------------------

IF OBJECT_ID(N'rv.refresh_tokens', N'U') IS NULL
   OR COL_LENGTH(N'rv.refresh_tokens', N'revoked_at') IS NULL
BEGIN
    RAISERROR('STOP: forma de refresh_tokens desconocida.', 16, 1);
    RETURN;
END;


IF OBJECT_ID(N'rv.work_sessions', N'U') IS NULL
   OR COL_LENGTH(N'rv.work_sessions', N'status') IS NULL
   OR COL_LENGTH(N'rv.work_sessions', N'ended_at') IS NULL
BEGIN
    RAISERROR('STOP: forma de work_sessions desconocida.', 16, 1);
    RETURN;
END;


IF OBJECT_ID(N'rv.admin_users', N'U') IS NULL
   OR COL_LENGTH(N'rv.admin_users', N'is_active') IS NULL
BEGIN
    RAISERROR('STOP: forma de admin_users desconocida.', 16, 1);
    RETURN;
END;


IF OBJECT_ID(N'rv.persistent_field_sessions', N'U') IS NOT NULL
BEGIN
    IF COL_LENGTH(N'rv.persistent_field_sessions', N'status') IS NULL
       OR COL_LENGTH(N'rv.persistent_field_sessions', N'revoked_at') IS NULL
       OR COL_LENGTH(N'rv.persistent_field_sessions', N'revoked_reason') IS NULL
       OR COL_LENGTH(N'rv.persistent_field_sessions', N'revocation_epoch') IS NULL
    BEGIN
        RAISERROR(
            'STOP: forma de persistent_field_sessions desconocida.',
            16,
            1
        );
        RETURN;
    END;
END;


IF OBJECT_ID(N'rv.device_bindings', N'U') IS NOT NULL
BEGIN
    IF COL_LENGTH(N'rv.device_bindings', N'status') IS NULL
       OR COL_LENGTH(N'rv.device_bindings', N'revoked_at') IS NULL
       OR COL_LENGTH(N'rv.device_bindings', N'revoked_reason') IS NULL
       OR COL_LENGTH(N'rv.device_bindings', N'revocation_epoch') IS NULL
    BEGIN
        RAISERROR(
            'STOP: forma de device_bindings desconocida.',
            16,
            1
        );
        RETURN;
    END;
END;


------------------------------------------------------------
-- AISLAMIENTO TRANSACCIONAL
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;


    --------------------------------------------------------
    -- REFRESH TOKENS
    --------------------------------------------------------

    UPDATE rv.refresh_tokens
    SET revoked_at = COALESCE(
        revoked_at,
        SYSUTCDATETIME()
    )
    WHERE revoked_at IS NULL;

    SELECT @@ROWCOUNT AS refresh_tokens_revoked;


    --------------------------------------------------------
    -- WORK SESSIONS
    --------------------------------------------------------

    UPDATE rv.work_sessions
    SET
        status = 'closed',
        ended_at = COALESCE(
            ended_at,
            SYSUTCDATETIME()
        )
    WHERE status = 'open';

    SELECT @@ROWCOUNT AS work_sessions_closed;


    --------------------------------------------------------
    -- PERSISTENT FIELD SESSIONS
    --
    -- CHECK real:
    --
    -- active  + revoked_at IS NULL
    -- revoked + revoked_at IS NOT NULL
    --
    -- status y revoked_at deben cambiar juntos.
    --------------------------------------------------------

    IF OBJECT_ID(N'rv.persistent_field_sessions', N'U') IS NOT NULL
    BEGIN

        UPDATE rv.persistent_field_sessions
        SET
            status = 'revoked',
            revoked_at = COALESCE(
                revoked_at,
                SYSUTCDATETIME()
            ),
            revoked_reason = COALESCE(
                revoked_reason,
                N'Neutralized after TEST restore'
            ),
            revocation_epoch = revocation_epoch + 1
        WHERE status = 'active';

        SELECT @@ROWCOUNT AS persistent_sessions_revoked;

    END
    ELSE
    BEGIN

        SELECT 0 AS persistent_sessions_not_present;

    END;


    --------------------------------------------------------
    -- DEVICE BINDINGS
    --
    -- CHECK real:
    --
    -- active  + revoked_at IS NULL
    -- revoked + revoked_at IS NOT NULL
    --
    -- status y revoked_at deben cambiar juntos.
    --------------------------------------------------------

    IF OBJECT_ID(N'rv.device_bindings', N'U') IS NOT NULL
    BEGIN

        UPDATE rv.device_bindings
        SET
            status = 'revoked',
            revoked_at = COALESCE(
                revoked_at,
                SYSUTCDATETIME()
            ),
            revoked_reason = COALESCE(
                revoked_reason,
                N'Neutralized after TEST restore'
            ),
            revocation_epoch = revocation_epoch + 1
        WHERE status = 'active';

        SELECT @@ROWCOUNT AS device_bindings_revoked;

    END
    ELSE
    BEGIN

        SELECT 0 AS device_bindings_not_present;

    END;


    --------------------------------------------------------
    -- ADMIN USERS
    --------------------------------------------------------

    UPDATE rv.admin_users
    SET is_active = 0
    WHERE is_active = 1;

    SELECT @@ROWCOUNT AS admin_users_deactivated;


    --------------------------------------------------------
    -- COMMIT
    --------------------------------------------------------

    COMMIT TRANSACTION;

END TRY

BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    DECLARE @ErrorMessage nvarchar(4000);
    DECLARE @ErrorSeverity int;
    DECLARE @ErrorState int;

    SELECT
        @ErrorMessage = ERROR_MESSAGE(),
        @ErrorSeverity = ERROR_SEVERITY(),
        @ErrorState = ERROR_STATE();

    RAISERROR(
        @ErrorMessage,
        @ErrorSeverity,
        @ErrorState
    );

    RETURN;

END CATCH;


------------------------------------------------------------
-- VALIDACIÓN POST-AISLAMIENTO
------------------------------------------------------------

SELECT
    (
        SELECT COUNT_BIG(*)
        FROM rv.refresh_tokens
        WHERE revoked_at IS NULL
    ) AS active_refresh_tokens,

    (
        SELECT COUNT_BIG(*)
        FROM rv.work_sessions
        WHERE status = 'open'
    ) AS open_work_sessions,

    (
        SELECT COUNT_BIG(*)
        FROM rv.admin_users
        WHERE is_active = 1
    ) AS active_admin_users;


------------------------------------------------------------
-- VALIDAR REFRESH / WORK / ADMINS
------------------------------------------------------------

IF EXISTS
(
    SELECT 1
    FROM rv.refresh_tokens
    WHERE revoked_at IS NULL
)
OR EXISTS
(
    SELECT 1
    FROM rv.work_sessions
    WHERE status = 'open'
)
OR EXISTS
(
    SELECT 1
    FROM rv.admin_users
    WHERE is_active = 1
)
BEGIN
    RAISERROR(
        'STOP: aislamiento base no quedó en cero.',
        16,
        1
    );
    RETURN;
END;


------------------------------------------------------------
-- VALIDAR PERSISTENT FIELD SESSIONS
------------------------------------------------------------

IF OBJECT_ID(N'rv.persistent_field_sessions', N'U') IS NOT NULL
BEGIN

    SELECT
        status,
        COUNT_BIG(*) AS total
    FROM rv.persistent_field_sessions
    GROUP BY status
    ORDER BY status;


    SELECT
        COUNT_BIG(*) AS active_persistent_field_sessions
    FROM rv.persistent_field_sessions
    WHERE status = 'active';


    IF EXISTS
    (
        SELECT 1
        FROM rv.persistent_field_sessions
        WHERE status = 'active'
    )
    BEGIN
        RAISERROR(
            'STOP: persistent field sessions siguen activas.',
            16,
            1
        );
        RETURN;
    END;


    IF EXISTS
    (
        SELECT 1
        FROM rv.persistent_field_sessions
        WHERE
            (
                status = 'active'
                AND revoked_at IS NOT NULL
            )
            OR
            (
                status = 'revoked'
                AND revoked_at IS NULL
            )
    )
    BEGIN
        RAISERROR(
            'STOP: persistent_field_sessions quedó en estado inconsistente.',
            16,
            1
        );
        RETURN;
    END;

END;


------------------------------------------------------------
-- VALIDAR DEVICE BINDINGS
------------------------------------------------------------

IF OBJECT_ID(N'rv.device_bindings', N'U') IS NOT NULL
BEGIN

    SELECT
        status,
        COUNT_BIG(*) AS total
    FROM rv.device_bindings
    GROUP BY status
    ORDER BY status;


    SELECT
        COUNT_BIG(*) AS active_device_bindings
    FROM rv.device_bindings
    WHERE status = 'active';


    IF EXISTS
    (
        SELECT 1
        FROM rv.device_bindings
        WHERE status = 'active'
    )
    BEGIN
        RAISERROR(
            'STOP: device bindings siguen activos.',
            16,
            1
        );
        RETURN;
    END;


    IF EXISTS
    (
        SELECT 1
        FROM rv.device_bindings
        WHERE
            (
                status = 'active'
                AND revoked_at IS NOT NULL
            )
            OR
            (
                status = 'revoked'
                AND revoked_at IS NULL
            )
    )
    BEGIN
        RAISERROR(
            'STOP: device_bindings quedó en estado inconsistente.',
            16,
            1
        );
        RETURN;
    END;

END;


------------------------------------------------------------
-- RESULTADO FINAL
------------------------------------------------------------

SELECT
    'ISOLATION_COMMITTED' AS result;