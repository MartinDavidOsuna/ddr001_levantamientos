# Reporte de certificación de resiliencia

Fecha: 2026-08-30  
Estado: **FIELD_CERTIFICATION_NOT_READY**

## Baseline y rama

- Repositorio: `MartinDavidOsuna/ddr001_levantamientos`.
- Rama: `fix/app-zero-loss-and-resilience-certification`.
- Base remota exacta: `416ff23c4e99783a264fdfe5cc2e3edb94da75be`.
- Merge-base auditado: `f3a6afdfb65a2fb8325a24f9e777b56446f8f7e5`.
- HEAD de implementación antes del commit documental: `849eb59`.
- HEAD final: consultar `git rev-parse HEAD` en la entrega, porque este reporte forma parte del commit final.

## Cambios y hallazgos

P0 encontrados y corregidos:

1. Reconciliation podía retirar `uploadPhoto` sin dejar `verifyPhotos`: ahora crea verify idempotente o confirma y retira ambos.
2. Captura temporal sin recuperación: ahora prepara journal antes de cámara, usa `retrieveLostData`, staging privado y representaciones `.source/.upload/.thumb`.
3. Escrituras archivo/foto/survey/queue independientes: journal y reconciliador bootstrap reparan estados heredados, enlaces y queue.
4. Delete destruía primero: ahora persiste tombstone, oculta en UI, conserva bytes y purga únicamente tras confirmación remota (o certeza de que nunca fue remoto).
5. Motorola podía dejar un JPEG aceptado sólo en cache después de process death: recuperación correlacionada con journal y ventana temporal evita pérdida y reutilización/duplicado.
6. Una mutación local de igual tamaño eludía la validación: ahora SHA-256 streaming se recalcula antes de cada upload y la evidencia corrupta queda en review sin enviarse.

P1 corregidos:

- Polling offline de 3 s a 45 s, principalmente dirigido por `onConnectivityChanged`.
- Transporte y alcance API separados; estado degradado explícito.
- Timer de cooldown único/cancelable.
- GPS y listener se detienen al salir cuando no existe ubicación pendiente.
- 409 estructural queda en `requiresReview`; otros surveys continúan.
- SHA-256 por streaming conservado; upload usa representación determinista y valida tamaño y digest exacto antes de enviar.
- Tombstone heredado ya no vuelve a enlazarse durante bootstrap; replay remoto 404 se considera delete idempotente satisfecho.
- Icono Android invertido y con margen seguro para que el sistema muestre el logo completo sin zoom.

Archivos principales: `app_controller.dart`, `photo_capture_service.dart`, `local_store.dart`, `construction_operation_journal.dart`, modelos/scheduler/migración, suites core/integration, fixture de dispositivo y documentación. No se modificó API ni SQL.

## Pruebas automáticas

- `flutter analyze`: PASS, 0 issues.
- `flutter test`: PASS, 127/127 en la corrida completa final.
- Ambiguous upload Android: PASS.
- Matriz verify: confirmed, missing_original, hash_mismatch, not_found, missing_thumbnail, missing_mapping, not_verified, mapping_conflict y deleted: PASS determinista.
- 401 + refresh, timeout de refresh y revocación: PASS.
- Timeout previo a commit, 500, 409 causal y estructural: PASS.
- Journal, huérfano, metadata sin archivo, uploading/verifying heredados, fronteras tombstone y cache de cámara: PASS.

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
- E2E-E kill/restart: PASS para evidencia aceptada y para process death con cámara externa activa; SHA-256 de source/upload/thumb idéntico antes/después.
- E2E-F sync real: NO EJECUTADO; no había TEST API escuchando en 3003 ni credenciales externas.
- E2E-G interrupción upload: PASS determinista; NO EJECUTADO contra TEST API real.
- E2E-H cooldown: PASS local/fixture.
- E2E-I 20 surveys: PASS físico, 19 avanzaron y uno quedó review.
- E2E-J GPS: PASS observado; solicitud high accuracy presente dentro del detalle y ausente al salir.
- Icono Android: PASS visual en launcher Motorola; fondo blanco, símbolo azul completo y margen seguro sin recorte/zoom.
- Flujos críticos: diez force-stops/relaunch consecutivos conservaron 1 survey, 1 queue y SHA `2b0781…b1b2e`.
- Reinicio completo: PASS en APK TEST normal sin reinstalar; sesión, survey, queue, cooldown y SHA reaparecieron después de `boot_completed` y desbloqueo.
- Camera process death: PASS positivo. Se mató Levantamientos con la cámara Motorola activa, se tomó la foto y se accionó el control UIAutomator `done_button`/`Listo`; bootstrap recuperó el JPEG privado, creó una sola terna source/upload/thumb y la UI mostró 2/4. Otro force-stop conservó exactamente tres archivos y los mismos hashes.
- La corrida exploratoria detectó una posible asociación duplicada de cache con un journal antiguo; se corrigió con ventana temporal acotada y la corrida limpia final demostró una sola foto tras restart.

## Integridad y recursos

- Foto real: `source`, `upload` y `thumb` conservaron hashes distintos y estables tras force-stop.
- Memoria debug recién iniciada: PSS ~340 MB / RSS ~410 MB.
- Después de cámara/foto: PSS ~325 MB / RSS ~324 MB.
- En otra muestra debug posterior: PSS ~361 MB / RSS ~446 MB.
- Muestra posterior al reboot: PSS ~329 MB / RSS ~409 MB.
- Después de diez relanzamientos: PSS ~333 MB / RSS ~420 MB y CPU 0.0% tras estabilizar; el pico inmediato de arranque no persistió.
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
2. F15 no cubrió kill físico en cada frontera de tombstone, aunque las fronteras prepared/queued/review y el replay 404 sí pasan de forma determinista.
3. Faltan 20 uploads reales con cinco interrupciones y el dataset completo de perfilado.
4. No se ejecutó prueba sostenida offline de 10/30 minutos ni batería aislada.

Por estas brechas no se declara intención como evidencia: **FIELD_CERTIFICATION_NOT_READY**.
