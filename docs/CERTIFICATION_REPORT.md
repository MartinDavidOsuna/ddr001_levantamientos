# Reporte de certificación de resiliencia

Fecha: 2026-08-30  
Estado: **FIELD_CERTIFIED_READY**

## Baseline y rama

- Repositorio: `MartinDavidOsuna/ddr001_levantamientos`.
- Rama: `fix/app-zero-loss-and-resilience-certification`.
- Base remota exacta: `416ff23c4e99783a264fdfe5cc2e3edb94da75be`.
- Merge-base auditado: `f3a6afdfb65a2fb8325a24f9e777b56446f8f7e5`.
- HEAD de entrada a la certificación final: `82295925c10726c0ed02c9839abb92f5ac18563e`.
- HEAD funcional certificado: `761ad9ae3311ab686e47385a2fcb74fe2bf48e59`.
- El commit documental posterior no cambia la build certificada; su SHA se registra en la entrega de consola.

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
- Miniaturas decodificadas a 264 px y galería paginada en bloques de 24; las listas grandes ya no materializan cientos de bitmaps a la vez.
- La finalización local ahora persiste también `openStep(n+1)` y bootstrap repara instalaciones anteriores que omitieron ese comando causal. El defecto se reprodujo físicamente contra TEST antes del fix y quedó cubierto por dos pruebas rojas/verdes.

Archivos principales: `app_controller.dart`, `photo_capture_service.dart`, `local_store.dart`, `construction_operation_journal.dart`, modelos/scheduler/migración, suites core/integration, fixture de dispositivo y documentación. No se modificó API ni SQL.

## Pruebas automáticas

- `flutter analyze`: PASS, 0 issues.
- `flutter test`: PASS, 131/131 en la corrida completa final.
- Ambiguous upload Android: PASS.
- `integration_test/ambiguous_upload_recovery_test.dart` en Motorola/API TEST: PASS, 1/1.
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
- E2E-F sync real: PASS contra API TEST local; 20/20 fotos terminaron `confirmed` en cliente y servidor.
- E2E-G interrupción upload: PASS físico/controlado y determinista; se conservaron UUID, bytes y queue.
- E2E-H cooldown: PASS local/fixture.
- E2E-I 20 surveys: PASS físico, 19 avanzaron y uno quedó review.
- E2E-J GPS: PASS observado; solicitud high accuracy presente dentro del detalle y ausente al salir.
- Icono Android: PASS visual en launcher Motorola; fondo blanco, símbolo azul completo y margen seguro sin recorte/zoom.
- Flujos críticos: diez force-stops/relaunch consecutivos conservaron 1 survey, 1 queue y SHA `2b0781…b1b2e`.
- Reinicio completo: PASS en APK TEST normal sin reinstalar; sesión, survey, queue, cooldown y SHA reaparecieron después de `boot_completed` y desbloqueo.
- Camera process death: PASS positivo. Se mató Levantamientos con la cámara Motorola activa, se tomó la foto y se accionó el control UIAutomator `done_button`/`Listo`; bootstrap recuperó el JPEG privado, creó una sola terna source/upload/thumb y la UI mostró 2/4. Otro force-stop conservó exactamente tres archivos y los mismos hashes.
- La corrida exploratoria detectó una posible asociación duplicada de cache con un journal antiguo; se corrigió con ventana temporal acotada y la corrida limpia final demostró una sola foto tras restart.

### Campaña final contra API TEST

- Survey de 20 fotos: `7dac2265-70d8-4c25-9302-1cb9e597edea`.
- Resultado: 20 intentadas, 20 uploads verificados, 20 estados cliente `PhotoSyncState.confirmed`, 20 estados servidor `integrity_status=confirmed`.
- Unicidad: 20 `photoId` distintos, 20 efectos lógicos, cero filas/mappings/blobs funcionales duplicados por retry.
- I1 offline antes de upload: PASS; queue y evidencia sobrevivieron offline + force-stop.
- I2 corte de transporte en frontera multipart: PASS físico/controlado; el corte exacto de cuerpo se complementó con F06 determinista.
- I3 respuesta/resultado ambiguo: PASS; cuatro operaciones causales conservaron la misma key/UUID y reconciliaron hasta confirmed.
- I4 force-stop con upload pendiente: PASS.
- I5 API TEST caída con evidencia pendiente: PASS; sesión y siete operaciones permanecieron, backoff sin loop y recuperación a queue 0.
- I6 reboot con uploads/verify pendientes: PASS; después de `boot_completed` se recuperaron journal/queue y 16/16 acumuladas quedaron confirmed.
- F15-A request previo a tombstone: PASS; al reiniciar la foto seguía activa.
- F15-B journal `prepared`: PASS; offline quedó oculta, con source/upload/thumb presentes; purge sólo tras delete remoto.
- F15-C delete enqueued: PASS; tombstone visible como 3/∞, servidor aún activo y tres archivos presentes hasta reconciliar.
- F15-D remote pending: PASS; kill antes del request remoto, archivo conservado y delete retomado tras relanzar.
- F15-E remoto 204 antes de purge: PASS; servidor confirmó, kill conservó los tres archivos y replay idempotente completó purge.
- Corridas críticas consecutivas: 3/3 PASS. Cada corrida creó survey, capturó con GPS, subió, verificó, confirmó, cerró etapa, abrió la siguiente, sufrió force-stop y volvió con sesión/queue 0.

| # | photoId | Interrupción | Upload / verify | Cliente / servidor | Duplicados |
|---:|---|---|---|---|---:|
| 01 | `3c551735-dc61-410d-914d-eb8123a192d8` | I3 causal/ambiguo | retry misma key / 1 | confirmed / confirmed | 0 |
| 02 | `9d460393-4c36-482f-9193-ef564afc8147` | I3 causal/ambiguo | retry misma key / 1 | confirmed / confirmed | 0 |
| 03 | `7c3677f5-cdc8-41ce-9ec8-e08f7ceef55a` | I3 causal/ambiguo | retry misma key / 1 | confirmed / confirmed | 0 |
| 04 | `93a7ddbf-2019-4f94-8841-ffad5697cb52` | I3 causal/ambiguo | retry misma key / 1 | confirmed / confirmed | 0 |
| 05 | `67f08c02-24fe-4cc7-977a-130ac3bcee7a` | I1 + I4 | 1 + retry / 1 | confirmed / confirmed | 0 |
| 06 | `46a559a7-5c7b-4b6d-b261-761dd5ca097f` | I2 transporte | 1 + retry / 1 | confirmed / confirmed | 0 |
| 07 | `70abf10b-80d2-4c4d-9254-ec4dadc4ed4b` | control | 1 / 1 | confirmed / confirmed | 0 |
| 08 | `47706caf-0122-42ca-86d1-3a39ba86bac6` | control | 1 / 1 | confirmed / confirmed | 0 |
| 09 | `d31bad7a-fd3d-4213-96a4-f010a239141f` | I5 API caída | 1 + retry / 1 | confirmed / confirmed | 0 |
| 10 | `24b99ddc-b79e-48ee-8fec-429e51f617c1` | I5 API caída | 1 + retry / 1 | confirmed / confirmed | 0 |
| 11 | `1bda7c17-5df6-4e22-a890-c734775c167a` | I5 API caída | 1 + retry / 1 | confirmed / confirmed | 0 |
| 12 | `40148117-9d85-475e-8bc6-29c67146d489` | I5 API caída | 1 + retry / 1 | confirmed / confirmed | 0 |
| 13 | `d595e1c4-c018-4869-b456-67f145b076ee` | I6 reboot | 1 + recovery / 1 | confirmed / confirmed | 0 |
| 14 | `4c383579-1836-4974-8ed2-83f13135e6cf` | I6 reboot | 1 + recovery / 1 | confirmed / confirmed | 0 |
| 15 | `ed488e06-848c-4262-ac11-d6c2f3055d68` | I6 reboot | 1 + recovery / 1 | confirmed / confirmed | 0 |
| 16 | `7a3d2f79-34d7-4d01-9a5a-58c4ac82c067` | I6 reboot | 1 + recovery / 1 | confirmed / confirmed | 0 |
| 17 | `6e0dfbad-4cb1-4160-a953-01e0df9b308b` | control | 1 / 1 | confirmed / confirmed | 0 |
| 18 | `78016cd3-2e34-422f-9953-4fd4689b12c5` | control | 1 / 1 | confirmed / confirmed | 0 |
| 19 | `c3745a04-da1a-40fb-93b1-2b7557143393` | control | 1 / 1 | confirmed / confirmed | 0 |
| 20 | `f4d627b6-0e20-46b3-8e69-c2bb86f3df70` | control | 1 / 1 | confirmed / confirmed | 0 |

## Local API used for certification

- branch: `audit/construction-final-certification-api`
- HEAD: `9c3aff1dd3eb73b4fb6aa6dff7f1a897cf4fc2fb`
- DB: `DDR001_Hidrantes_TEST`
- transporte Android: `adb reverse tcp:3003 tcp:3003`
- storage: TEST local (ruta omitida del reporte público)
- deployed: NO
- production: NOT TOUCHED

## Integridad y recursos

- Foto real: `source`, `upload` y `thumb` conservaron hashes distintos y estables tras force-stop.
- Memoria debug recién iniciada: PSS ~340 MB / RSS ~410 MB.
- Después de cámara/foto: PSS ~325 MB / RSS ~324 MB.
- En otra muestra debug posterior: PSS ~361 MB / RSS ~446 MB.
- Muestra posterior al reboot: PSS ~329 MB / RSS ~409 MB.
- Después de diez relanzamientos: PSS ~333 MB / RSS ~420 MB y CPU 0.0% tras estabilizar; el pico inmediato de arranque no persistió.
- Perfil con 10 fotos: detalle/lista 366–376 MB PSS; al volver al inicio bajó a 143 MB PSS.
- Perfil físico con 100 surveys y 400 archivos de miniatura (60,856 KB): lista 332 MB PSS. La implementación original del perfil llegó a 982 MB PSS al construir 400 bitmaps; tras decode acotado y paginación, la misma etapa quedó en 386 MB PSS con 24 visibles y 434 MB con 48 visibles.
- CPU inactiva observada: 0.0% en muestra `top`; no se observó loop >1 request/s.
- Offline sostenido 10 minutos con Wi-Fi y datos desactivados: PASS. PSS minuto a minuto 402–425 MB sobre la caché del dataset extremo, sin tendencia creciente; CPU puntual 0–5%, sin mensajes `[SYNC]`, crash, ANR u OOM. Wi-Fi y datos quedaron restaurados al terminar.
- Logcat: sin FATAL EXCEPTION, ANR, OOM ni `FileNotFoundException` de la app durante el perfil. Los `DeadObjectException` observados provenían de servicios Android/force-stop inducido, no de un crash de la app.
- GPS: registro high-accuracy durante flujo y `ProviderRequest` activo ausente después de salir. Historial de sistema mostró registro/retiro.
- Batería: la estadística agregada del dispositivo no permite atribución limpia por package sin reset destructivo; no se reseteó batterystats.
- Perfil de 10 fotografías, dataset de 100 surveys/400 thumbnails y 10 minutos offline: PASS físico. La campaña final también observó memoria/CPU durante sync real contra TEST.
- Muestra durante API caída con evidencia pendiente: ~303 MB PSS; no hubo crecimiento sostenido, OOM ni ANR.
- Durante la campaña real no hubo `FATAL EXCEPTION`, ANR, OOM ni loop de retry. Los `SecurityException` de logcat pertenecían a Google Play Services, no al proceso DDR001.
- El historial de `dumpsys location` mostró pares de alta/baja y `ProviderRequest[OFF]` al terminar cada captura; no quedó solicitud GPS de la app al finalizar.

## Red, recovery y API

- Fallos probados: offline, send/receive timeout, respuesta perdida post-commit, 401/refresh, 409 causal/estructural y 500.
- La cola y sus cooldowns sobreviven serialización; un fallo queda aislado por survey.
- No hay purge automático de originales confirmados.
- El blocker de replay causal fue corregido y validado exclusivamente en la API local, sin contrato ni migración. La app real confirmó recuperación same-key.
- Nuevo API blocker: ninguno.
- **API CHANGE REQUIRED AFTER CURRENT FIX: NO**.

## Decisión final

Todos los gates obligatorios quedaron ejecutados: API TEST segura, recuperación causal app/API, 20/20 confirmed, seis interrupciones, cero duplicados, F15-A–E, reboot, sesión, 3/3 corridas, analyze, 131/131 unitarias e integración Android. No se desplegó ni mergeó API o app y producción no fue tocada.

**FIELD_CERTIFIED_READY**
