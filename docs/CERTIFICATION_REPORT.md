# Reporte de certificación de resiliencia

Fecha: 2026-08-30  
Estado: **FIELD_CERTIFICATION_NOT_READY**

## Baseline y rama

- Repositorio: `MartinDavidOsuna/ddr001_levantamientos`.
- Rama: `fix/app-zero-loss-and-resilience-certification`.
- Base remota exacta: `416ff23c4e99783a264fdfe5cc2e3edb94da75be`.
- Merge-base auditado: `f3a6afdfb65a2fb8325a24f9e777b56446f8f7e5`.
- HEAD de implementación antes del commit documental: `91b0c65`.
- HEAD final: consultar `git rev-parse HEAD` en la entrega, porque este reporte forma parte del commit final.

## Cambios y hallazgos

P0 encontrados y corregidos:

1. Reconciliation podía retirar `uploadPhoto` sin dejar `verifyPhotos`: ahora crea verify idempotente o confirma y retira ambos.
2. Captura temporal sin recuperación: ahora prepara journal antes de cámara, usa `retrieveLostData`, staging privado y representaciones `.source/.upload/.thumb`.
3. Escrituras archivo/foto/survey/queue independientes: journal y reconciliador bootstrap reparan estados heredados, enlaces y queue.
4. Delete destruía primero: ahora persiste tombstone, oculta en UI, conserva bytes y purga únicamente tras confirmación remota (o certeza de que nunca fue remoto).

P1 corregidos:

- Polling offline de 3 s a 45 s, principalmente dirigido por `onConnectivityChanged`.
- Transporte y alcance API separados; estado degradado explícito.
- Timer de cooldown único/cancelable.
- GPS y listener se detienen al salir cuando no existe ubicación pendiente.
- 409 estructural queda en `requiresReview`; otros surveys continúan.
- SHA-256 por streaming conservado; upload usa representación determinista y valida tamaño antes de enviar.

Archivos principales: `app_controller.dart`, `photo_capture_service.dart`, `local_store.dart`, `construction_operation_journal.dart`, modelos/scheduler/migración, suites core/integration, fixture de dispositivo y documentación. No se modificó API ni SQL.

## Pruebas automáticas

- `flutter analyze`: PASS, 0 issues.
- `flutter test`: PASS, 120/120 en la corrida completa final.
- Ambiguous upload Android: PASS.
- Matriz verify: confirmed, missing_original, hash_mismatch, not_found, missing_thumbnail, missing_mapping, not_verified, mapping_conflict y deleted: PASS determinista.
- 401 + refresh, timeout de refresh y revocación: PASS.
- Timeout previo a commit, 500, 409 causal y estructural: PASS.
- Journal, huérfano, metadata sin archivo, uploading/verifying heredados y tombstone: PASS.

CI conserva `flutter pub get`, `flutter analyze` y `flutter test`. Cámara física queda como release gate local.

## Android físico y E2E

- Dispositivo: Motorola moto g14.
- Android: 14 / API 34.
- Serial omitido del reporte por privacidad; `adb devices -l` confirmó estado `device`.
- Package TEST/debug: `com.aquafim.ddr001levantamientos`.
- E2E-A arranque: PASS.
- E2E-B sesión: PASS en APK fixture normal tras force-stop/relaunch; el runner `flutter test` desinstala su APK y no sirve para este límite.
- E2E-C offline: PASS; Wi-Fi desactivado temporalmente y restaurado, survey/queue/archivo intactos.
- E2E-D cámara real: PASS; cámara Motorola automatizada, resultado aceptado y tres archivos privados creados.
- E2E-E kill/restart: PASS para evidencia ya aceptada; SHA-256 de source/upload/thumb idéntico antes/después.
- E2E-F sync real: NO EJECUTADO; no había TEST API escuchando en 3003 ni credenciales externas.
- E2E-G interrupción upload: PASS determinista; NO EJECUTADO contra TEST API real.
- E2E-H cooldown: PASS local/fixture.
- E2E-I 20 surveys: PASS físico, 19 avanzaron y uno quedó review.
- E2E-J GPS: PASS observado; solicitud high accuracy presente dentro del detalle y ausente al salir.
- Flujos críticos: tres force-stops consecutivos conservaron 1 survey, 1 queue y SHA `2b0781…b1b2e`.
- Camera process death: kill inmediato después de `Listo` no mostró la captura y no alteró la evidencia aceptada; falta una corrida donde Android entregue positivamente `retrieveLostData`.

## Integridad y recursos

- Foto real: `source`, `upload` y `thumb` conservaron hashes distintos y estables tras force-stop.
- Memoria debug recién iniciada: PSS ~340 MB / RSS ~410 MB.
- Después de cámara/foto: PSS ~325 MB / RSS ~324 MB.
- En otra muestra debug posterior: PSS ~361 MB / RSS ~446 MB.
- CPU inactiva observada: 0.0% en muestra `top`; no se observó loop >1 request/s.
- Logcat: sin FATAL EXCEPTION, ANR u OOM de la app. `DeadObjectException` de WindowManager coincidió con force-stop inducido.
- GPS: registro high-accuracy durante flujo y `ProviderRequest` activo ausente después de salir. Historial de sistema mostró registro/retiro.
- Batería: la estadística agregada del dispositivo no permite atribución limpia por package sin reset destructivo; no se reseteó batterystats.
- Perfil de 10 fotografías, 100 surveys/400 thumbnails, sync real y 10 minutos offline: incompleto.

## Red, recovery y API

- Fallos probados: offline, send/receive timeout, respuesta perdida post-commit, 401/refresh, 409 causal/estructural y 500.
- La cola y sus cooldowns sobreviven serialización; un fallo queda aislado por survey.
- No hay purge automático de originales confirmados.
- API blocker reproducible: no demostrado.
- **API CHANGE REQUIRED: NO**.

## Blockers para READY

1. TEST API real y credenciales externas no disponibles: falta sync/upload/verify remoto e idempotencia real.
2. Falta reinicio completo del teléfono (sólo process death/force-stop).
3. F15 no cubrió kill físico en cada frontera de tombstone.
4. Falta recuperación positiva real mediante `retrieveLostData`.
5. Faltan 20 uploads reales con cinco interrupciones, diez force-stops de persistencia y dataset completo de perfilado.
6. No se ejecutó prueba sostenida offline de 10/30 minutos ni batería aislada.

Por estas brechas no se declara intención como evidencia: **FIELD_CERTIFICATION_NOT_READY**.
