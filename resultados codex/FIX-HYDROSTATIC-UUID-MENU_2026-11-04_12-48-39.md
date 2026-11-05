# FIX — GUID histórico al abrir Pruebas Hidrostáticas

## Causa y recorrido exacto

Rama comprobada: `release/hydrostatic-rc1`, checkout principal `/Users/martino/DEV/ddr001_levantamientos`. No se crearon worktrees ni se tocaron otros repositorios.

El callback en `lib/features/home/home_page.dart:111` consulta `HydrostaticController.accessIssue` antes de navegar a `HydrostaticListPage` con ruta `hydrostatic-list`. `accessIssue` llama al adaptador de acceso, que comprueba residente, sesión field, identidad coincidente y permiso de Gabinetes; luego construye `HydrostaticActorSnapshot` (`lib/data/hydrostatic/hydrostatic_access_adapter.dart:54`).

En RC3, el constructor aplicaba `hydroUuid(userId)`, `hydroUuid(sessionId)` y `hydroUuid(deviceInstallationId)` indiscriminadamente (`lib/domain/hydrostatic/hydrostatic_models.dart`, líneas originales 193–195). `hydroUuid`, línea 17, exige versión 4 y variante RFC con la expresión `...-4xxx-[89ab]xxx-...`; línea 23 produce **UUID v4 canónico requerido.** El error de la tarjeta aparece antes de identificar un gabinete y antes de abrir el repositorio.

`userId` y `sessionId` provienen de `/field-sessions/start`, no del generador UUID de Hidrostáticas (`lib/data/remote/construction_api.dart:141`). El modelo de sesión los conserva y normaliza su representación; no establece que deban ser UUIDv4. Aplicar el requisito de generación local a GUID históricos externos es la incompatibilidad.

La fábrica productiva `createHydrostaticController` está en `lib/core/hydrostatic/hydrostatic_bootstrap.dart:37`, inyectada una sola vez en `lib/main.dart:62`. Con sync habilitado evalúa autorización para inicialización anticipada; ésta fallaba por la misma construcción del actor. La pantalla usa `initialize()`; éste verifica sesión antes de `openRepository()`. `HydrostaticRepository` recibe el actor autorizado, y `HydrostaticStore.open` conserva cajas v1 y recupera journals pendientes. No es un fallo de migración, Hive ni conectividad HTTP.

## Identificador y reproducción sin datos sensibles

Reproducción sintética de `userId`: `12345678-1234-1234-1234-123456789abc`, GUID canónico de 128 bits que no satisface los bits de UUIDv4. La prueba anterior a la corrección falla exactamente en el constructor del actor, línea original 193, con el mensaje reportado. También se comprueba por separado `sessionId` sintético `12345678-1234-11ef-8123-123456789abc`, conservando usuario v4, y viceversa.

Estos valores son inventados. No se extrajeron sesiones privadas, tokens ni identificadores reales del usuario. Por tanto, se demuestra el campo y tipo de fallo con datos equivalentes, pero no se afirma haber identificado cuál de los campos privados concretos del Pixel lo disparó. La nueva validación de GUID inválido identifica el nombre del campo sin imprimir su valor.

| Campo | Origen y regla tras el fix |
| --- | --- |
| `userId` | Identidad externa; GUID hexadecimal canónico no nulo, sin imponer versión/variante v4. |
| `sessionId` | Sesión externa; misma regla de GUID, sin reemplazar el valor. |
| `actorId` en captura/evidencia/video | Referencia al mismo `userId`; aplica la misma validación de identidad. |
| `installationId` / `deviceInstallationId` | El segundo recibe el primero. Generado localmente por `SecureSessionStore.installationId()` con `Uuid().v4()`; mantiene v4 obligatorio. No se regenera. |
| `deviceId` | No es un campo independiente de este snapshot; no se intercambia con instalación. |
| `testId`, `operationId`, captura, evidencia y fuga | Identificadores nuevos locales; conservan UUIDv4 obligatorio. |
| `cabinetId` | Validación anterior sin cambios; no participa en el fallo previo a identificar gabinete. |

## Corrección mínima

- `lib/domain/hydrostatic/hydrostatic_models.dart:31`: nuevo validador `hydroIdentityGuid`, exclusivamente para identidades externas; exige formato hexadecimal minúsculo 8-4-4-4-12, rechaza vacío/nulo lógico/malformado y devuelve exactamente el valor recibido.
- `HydrostaticActorSnapshot`, líneas 208–210: GUID externo para usuario/sesión, UUIDv4 para instalación.
- Líneas 337 y 436 del mismo archivo, y `lib/core/hydrostatic/hydrostatic_contracts.dart:114`: referencias `actorId` consistentes en evidencia, declaración de video e intención de captura. Esto evita trasladar el mismo fallo a la primera foto o al cierre.
- `hydroUuid` no se modificó. Se mantienen validaciones de permisos, propietarios, sesión persistida e identidad durante operaciones.

No se modificaron menú, bootstrap, repositorio, almacenamiento, sincronización, API, Dashboard ni SQL. El único código funcional modificado corresponde a validación de identidades. Versión y script release se actualizaron para producir el nuevo artefacto.

## Preservación

No se reemplazan identidades, no se escriben sesiones, no se regenera installationId y no hay migraciones. Se conservan nombres y esquemas Hive, fotografías, journals, outbox y operaciones pendientes. La apertura no exige HTTP. Los tests usan almacenamiento temporal sintético y solicitudes interceptadas; no se hicieron solicitudes a producción.

Se preservan fuera del commit los cambios previos de Gradle, el harness de Gabinetes y archivos no rastreados existentes. El wrapper release restaura el overlay Gradle previo byte por byte.

## Versión realmente instalada y origen

Lectura de `dumpsys package` del Pixel 7 Pro: `com.aquafim.ddr001levantamientos`, versionCode **41**, versionName **1.5.25-rc.3**, actualización 2026-11-04 12:42:02. Se extrajo únicamente el APK mediante `adb pull`, sin datos privados.

SHA-256 del APK instalado: `f62f6b251424f20639e9c650cc9e7e1f232b73fcec261e36ad0c7533dbafa958`, idéntico al artefacto RC3 construido en esta rama desde `783ed579b88ae341ffa2175df7fd547b6ef75e77`. Esto enlaza el binario instalado con la trazabilidad local; el APK no contiene un nombre de rama verificable por sí solo.

Certificado instalado SHA-256: `780f516576d98fff8edaf34be7af6c4488dd8fd57a2c97500c9ff07e60195544`.

## Pruebas y regresión

Antes del fix, `flutter test test/hydrostatic/identity_guid_test.dart`: tres fallos por el mensaje original al construir el actor histórico, con stack en `hydroUuid` y `HydrostaticActorSnapshot`. La evidencia queda en `fix-hydro-uuid-before.log`.

Después del fix:

- `flutter analyze`: **No issues found**, 8.0 s.
- Suite dirigida de identidad y menú: **19 aprobadas**.
- `flutter test`: **772 aprobadas**, una omitida, cero fallos, 59 s.
- La omisión preexistente requiere `CABINETS_TEST_SESSION` y preparación de identidad TEST; no se alteró ni se ejecutó contra producción.

Cobertura nueva:

1. Entrada desde el menú con residente autorizado y GUID histórico de usuario/sesión.
2. UUIDv4 nuevo válido; GUID inválido, vacío, cero, no canónico y caracteres no hexadecimales rechazados.
3. Usuario histórico con sesión v4, sesión histórica con usuario v4 y ambos históricos.
4. UUIDv4 estricto para instalación, testId, operationId e ID de captura; el repositorio no escribe pruebas ante IDs inválidos.
5. Inicialización real vía fábrica productiva con cero pruebas previas y con preparación persistida, sin conexión y sin peticiones HTTP.
6. Sesión conservada como mismo objeto y mismos valores serializados; caja de Gabinetes, documentos, journal y outbox sintético pendiente sin cambios al abrir el módulo.
7. Actor histórico en intención de captura, fotos, resultado APROBADO y declaración de video; reapertura de Hive con documentos/journal/metadata idénticos y originales fotográficos verificados.
8. La regresión completa incluye Gabinetes, autorización, recuperación, ejecución hidrostática, fugas, resultados, captura y sincronización documental/de evidencias.

No se modificaron expectativas para ocultar errores ni se sustituyeron identificadores en pruebas persistidas. Las pruebas usan fixtures sintéticos; no constituyen una instalación o certificación física de RC4 en el teléfono.

## Commit

`4b4696da63d8eec25c530da5fee2fd8d8d979bba` — `fix(hydrostatic): accept historical server GUID identities`.

Commit local en `release/hydrostatic-rc1`; seis archivos, limitado a validación, pruebas y versión/build. No se hizo push, merge ni despliegue.

## APK RC4 y verificación

[APK: ddr001-1.5.25-rc.4-42.apk](../dist/hydrostatic-uuid/ddr001-1.5.25-rc.4-42.apk) — 77,406,913 bytes.

- Package: `com.aquafim.ddr001levantamientos`.
- VersionName: **1.5.25-rc.4**; versionCode: **42**, superior al **41** leído del dispositivo.
- Build productivo desde el commit indicado: `JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' python3 tool/build_hydrostatic_rc.py`.
- Resultado: **BUILD SUCCESSFUL in 1m 43s**, 518 tareas. Entrypoint `lib/main.dart`; ARM32, ARM64 y x86_64.
- `apksigner verify --verbose --print-certs`: **Verifies**, APK Signature Scheme v2 válido. Certificado SHA-256: `780f516576d98fff8edaf34be7af6c4488dd8fd57a2c97500c9ff07e60195544`, idéntico al APK realmente instalado.
- Se verificaron package/version con aapt y la presencia del nuevo mensaje de validación GUID en el AOT de la APK.
- Overlay Gradle previo restaurado y comparado byte por byte. No hubo cambios adicionales en fuentes productivas después del commit.

SHA-256 de RC4: `877321c5ccf33a93a037e8212d11e9a3586fb6292ee02a4a0725eb837dfe5bc6`.

[Checksum](../dist/hydrostatic-uuid/ddr001-1.5.25-rc.4-42.apk.sha256). [Evidencias y logs](./FIX-HYDROSTATIC-UUID-MENU_2026-11-04_12-48-39_evidencias/).

Configuración productiva autorizada conservada:

```text
APP_ENV=production
API_BASE_URL=http://cifra.aquafim.com:3002/api/v1
HYDROSTATIC_SYNC_ENABLED=true
HYDROSTATIC_PRODUCTION_SYNC_ENABLED=true
```

El endpoint coincide con el contrato productivo existente y aparece en el AOT generado. No se cambiaron los gates ni se habilitaron fixtures QA. Se usó la firma ya configurada, sin generar claves ni incorporar credenciales. La compilación no realiza sincronización contra producción. Las advertencias existentes de herramientas Gradle/Kotlin no impidieron el build.

## Actualización conservadora

La APK **no fue instalada automáticamente**. No se copió sobre datos de la aplicación ni se modificó producción.

1. Verificar el checksum del archivo y que el destino siga usando el package y firma indicados, con versionCode menor que 42.
2. Actualizar sobre la app existente mediante el instalador Android. En una intervención posterior autorizada también puede usarse `adb install -r <APK>`; no se ejecutó aquí.
3. No desinstalar, borrar almacenamiento, cerrar sesión como remedio, regenerar installationId, limpiar Hive ni eliminar fotografías/journals/outbox. Si firma o versión no son compatibles, detenerse sin borrar datos.
4. Comprobar sesión, historial y pendientes previos; abrir Pruebas Hidrostáticas como residente, también sin conexión. Al recuperar conexión se mantienen los gates de sincronización productiva.

La comprobación física de RC4 después de actualizar queda pendiente del operador. El acceso al Pixel durante este trabajo se limitó a metadatos de paquete y extracción del APK público para versión, hash y firma; no se leyeron ni modificaron datos privados.
