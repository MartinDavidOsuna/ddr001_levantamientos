# Local Data Model

Schema `1`, boxes: `construction_surveys_v1`, `construction_photos_v1`, `construction_sync_queue_v1`, `construction_metadata_v1`.

- `ConstructionProfile`: identidad RV y rol recibido.
- `BaseSurvey`: UUID, snapshot contractor, identifier/account, estado local/servidor/sync, canonical, steps/corrections.
- `SurveyStep`: 1–6, open/locked/completedLocal/completedServer, comentario y photo IDs.
- `ConstructionPhoto`: UUID, paths, SHA-256, GPS individual, contexto, estado hardened y `purpose` opcional. Paso 6 usa `north`, `east`, `south`, `west` o `additional`; fotos anteriores siguen siendo compatibles con null.
- `CorrectionRound`: round, estado, comentario y fotos.
- `SyncQueueItem`: operación, dependencias, intentos y siguiente ejecución.

Los tokens no forman parte de Hive.
