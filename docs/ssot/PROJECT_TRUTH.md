# Project Truth

## UUID identity

SQL Server puede serializar `UNIQUEIDENTIFIER` en mayúsculas. Flutter usa siempre
lowercase como representación canónica para todos los UUID Construction. Una
diferencia de case jamás crea otra entidad. Storage schema v2 repara de forma
silenciosa instalaciones legacy sin borrar carpetas ni archivos fotográficos.

- Proyecto: `ddr001_levantamientos`, versión `0.1.0+1`.
- Android applicationId e iOS bundle id: `com.aquafim.ddr001levantamientos`.
- Nombre visible: DDR001 Levantamientos.
- Flutter 3.44.8, Dart 3.12.2, Android/iOS únicamente.
- Auth: field sessions DDR001 existente; perfil Construction decide `contractor`/`resident`.
- Offline: Hive CE schema 1. Tokens: Secure Storage.
- API configurable por `APP_ENV` y `API_BASE_URL`; producción requiere HTTPS.
- Evidencia: cámara exclusivamente, GPS individual obligatorio, originales retenidos.
