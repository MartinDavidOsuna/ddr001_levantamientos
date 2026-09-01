# Project Truth

## PRODUCTION RELEASE RUNBOOK

El candidato `1.0.0+1` usa por decisión operacional `http://cifra.aquafim.com:3002/api/v1`, con cleartext Android limitado a ese dominio. Requiere firma Android definitiva y E2E físico. La app no acepta otro HTTP ni endpoint TEST en producción.

## UUID identity

SQL Server puede serializar `UNIQUEIDENTIFIER` en mayúsculas. Flutter usa siempre
lowercase como representación canónica para todos los UUID Construction. Una
diferencia de case jamás crea otra entidad. Storage schema v3 repara de forma
silenciosa instalaciones legacy sin borrar carpetas ni archivos fotográficos.

- Proyecto: `ddr001_levantamientos`, versión `1.0.0+1`.
- Android applicationId e iOS bundle id: `com.aquafim.ddr001levantamientos`.
- Nombre visible: DDR001 Levantamientos.
- Flutter 3.44.8, Dart 3.12.2, Android/iOS únicamente.
- Auth móvil: una sola pantalla Field con `name`, `email`, `phone` y `crew`, sin
  contraseña, selector de dominio ni selector de rol. `name` se normaliza y corresponde
  a `rv.users.full_name`; correo se normaliza en minúsculas, teléfono conserva los
  diez dígitos exigidos y cuadrilla se normaliza en mayúsculas según Field Auth.
  Installation ID, device binding, takeover, refresh, restore y logout siguen usando
  Field Auth.
- `crew` representa la cuadrilla de la work session actual. Se envía en
  `/field-sessions/start`, se conserva en Secure Storage y se muestra en Perfil. No
  determina rol ni capabilities Construction.
- Cada login declara `client_app=ddr001_levantamientos`. Installation ID es propio
  de esta app; el servidor permite al mismo usuario otras apps y otros dispositivos
  simultáneos. Logout revoca únicamente la sesión de esta instalación.
- El login móvil no crea sesiones Admin. La lectura técnica de sesiones Admin antiguas
  permanece sólo para que una sesión ya almacenada pueda restaurarse o cerrarse sin
  romper compatibilidad; no existe control visible que permita iniciar una nueva.
- Las sesiones persistidas por builds anteriores que no contienen `crew` siguen siendo
  legibles; la actualización de APK no borra Secure Storage ni obliga a limpiar datos.
- `POST /construction/base-surveys` no persiste actualmente un snapshot histórico de
  cuadrilla por survey. No se inventa esa relación en cliente; si se convierte en un
  requisito funcional deberá añadirse explícitamente al contrato de API.
- Offline: Hive CE schema 3. Tokens: Secure Storage.
- API configurable por `APP_ENV` y `API_BASE_URL`; producción acepta HTTPS o la única excepción HTTP oficial exacta.
- Evidencia: cámara exclusivamente, GPS individual obligatorio, originales retenidos.
- Los listados de levantamientos disponen de **Actualizar** y pull-to-refresh; ambos
  usan reconciliación por UUID y nunca sustituyen destructivamente el estado local.

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
