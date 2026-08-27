# Project Truth

## UUID identity

SQL Server puede serializar `UNIQUEIDENTIFIER` en mayúsculas. Flutter usa siempre
lowercase como representación canónica para todos los UUID Construction. Una
diferencia de case jamás crea otra entidad. Storage schema v3 repara de forma
silenciosa instalaciones legacy sin borrar carpetas ni archivos fotográficos.

- Proyecto: `ddr001_levantamientos`, versión `0.1.0+1`.
- Android applicationId e iOS bundle id: `com.aquafim.ddr001levantamientos`.
- Nombre visible: DDR001 Levantamientos.
- Flutter 3.44.8, Dart 3.12.2, Android/iOS únicamente.
- Auth: Field conserva sesiones DDR001. Reviewer administrativo usa el login/JWT
  admin existente y un perfil Construction aditivo; no existe conversión de token.
- Offline: Hive CE schema 3. Tokens: Secure Storage.
- API configurable por `APP_ENV` y `API_BASE_URL`; producción requiere HTTPS.
- Evidencia: cámara exclusivamente, GPS individual obligatorio, originales retenidos.

## Construction reviewer-equivalent

La aplicación modela `contractor` frente a capability `reviewer`. Resident Field,
admin administrativo (`supervisor`) y superadmin administrativo (`admin`) tienen
la misma experiencia funcional. El rol administrativo `viewer` no se proyecta.
La evidencia histórica contractor es inmutable para todos los reviewers.

## Location Evidence Model

Geolocator solicita `LocationAccuracy.best`, que permite fused/GNSS/Wi-Fi/celda
según disponibilidad del sistema; no se condiciona a Internet. Prewarm sólo vive
durante flujos de levantamiento o ventanas pending. El buffer retiene fixes breves;
el scoring pondera delta temporal (2 puntos/s) y accuracy (1.5 puntos/m), con
penalizaciones secundarias por salir del radio canonical/vecinos. Ventanas:
pre-captura 60 s, post-captura 120 s, early acceptance ≤10 m y ±30 s.
