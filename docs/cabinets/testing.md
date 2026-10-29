# Ejecución reproducible en TEST

## Preparar API

1. Verificar otra vez PR #15 y checkout API en
   `46b0265b9c8698363f3eca73257bc47382c4d8f2`. No sustituir main ni aplicar esto
   a producción. Las tablas de macroetapa 1 deben existir en TEST.
2. Configurar el archivo ignorado `.env.construction-test.local` del backend:
   `NODE_ENV=test`, `CONFIG_PROFILE=construction-test`, `PORT=3003`,
   `SQL_DATABASE=DDR001_Hidrantes_TEST`, `STORAGE_ROOT` igual al path absoluto
   `.storage/construction-test` del checkout API. Credenciales sólo locales.
3. Ejecutar desde API `npm run dev:construction-test`. Debe pasar preflight y
   mostrar `DB_NAME() = DDR001_Hidrantes_TEST`; comprobar `/api/v1/version`,
   `/api/v1/health/live` y `/api/v1/health/ready`.
4. Desde API, preparar exclusivamente identidades sintéticas:

```sh
CABINETS_API_CHECKOUT=/ruta/ddr001_api \
CABINETS_MOBILE_CHECKOUT=/ruta/ddr001_levantamientos-cabinets \
DOTENV_CONFIG_PATH=.env.construction-test.local \
npx tsx /ruta/ddr001_levantamientos-cabinets/tool/prepare_cabinets_test.mjs
```

El preparador comprueba perfil, SQL real, storage, SHA y feature antes de
crear datos. Hace login Field de una identidad `@example.invalid`, habilita
**sólo esa identidad sintética** como residente y crea una base sintética aceptada.
Conserva resultados en TEST; no borra otras filas ni realiza migraciones.
Crea `.test-cabinets/session.json` (modo 0600, ignorado), con tokens TEST, y
exporta catálogo real a fixture de pruebas. Repetir la preparación crea otro caso
para evitar reutilizar UID/base ya confirmados. No publicar ese archivo privado.

## Análisis, regresión y flujo HTTP real

Desde el worktree móvil:

```sh
flutter pub get
flutter analyze
flutter test --reporter expanded
CABINETS_TEST_SESSION=.test-cabinets/session.json \
  flutter test test/cabinets/cabinet_http_integration_test.dart --reporter expanded
flutter build apk --debug \
  --dart-define=APP_ENV=test \
  --dart-define=API_BASE_URL=http://127.0.0.1:3003/api/v1
```

El test HTTP usa el cliente Dart real, journal/Hive y la API local, con imágenes
y respuestas metrológicas **sintéticas**. El resultado no representa una
inspección física. Comprueba grafo offline completo, envío causal, 41 piezas,
series conservadas, fotos compartidas y verificadas, ACK idempotente, instalación,
aprobación, invalidación, dictamen negativo y resolución posterior; contrasta
documento y 12 operaciones con API. Guarda `.test-cabinets/result.json` sin tokens.
La suite normal omite explícitamente este test si no se proporcionó su sesión.

## Emulador Android dedicado

Se creó un AVD nuevo `DDR001_Cabinets_TEST_20261005`, Android API 35 arm64,
puerto 5580. Antes de instalar se comprobó `adb -s emulator-5580 emu avd name`,
boot completo y ausencia previa del paquete. Nunca dirigir estos comandos al
Pixel ni a un emulador que tenga datos de campo.

`integration_test/cabinets_test_smoke.dart` exige APP_ENV=test y nombre TEST
explícito. Sus defines privados incluyen:

- `API_BASE_URL=http://10.0.2.2:3003/api/v1`;
- `CABINETS_QA_DEVICE=DDR001_Cabinets_TEST_20261005`;
- `CABINETS_QA_UID`: UID de result.json del recorrido real;
- `CABINETS_QA_SESSION`: JSON de FieldSession de la identidad sintética, con
  installationId y tokens de session.json.

Guardar en `.test-cabinets/device-defines.json`, modo 0600; ejecutar:

```sh
flutter test integration_test/cabinets_test_smoke.dart -d emulator-5580 --no-uninstall \
  --dart-define-from-file=.test-cabinets/device-defines.json
```

Este smoke valida navegación residente, descarga real, renderizado y archivos
Hive/imagen sobre Android. No certifica óptica de cámara, exactitud GNSS ni
recuperación del proceso nativo de cámara. Es obligatorio `--no-uninstall`: Flutter desinstala por defecto al terminar sus
tests de integración. No utilizar uninstall/pm clear ni
borrado de storage como preparación. El APK de instrumentación contiene una
sesión sintética y se queda exclusivamente en el emulador TEST; no distribuirlo.

## Verificación física pendiente

En un dispositivo dedicado y con datos respaldados: cámara real/QR repetido,
permisos de cámara/GPS, GPS sin conectividad, finalizar proceso durante cámara,
reiniciar durante upload, sesión expirada, cambiar usuario, reconexión, conflictos
entre dos dispositivos y actualización conservando pendientes representativos.
No usar los datos operativos reales como fixture ni firmar/distribuir release aquí.

iOS: el build de simulador con Xcode 16.4 falla en la dependencia existente
`connectivity_plus 7.3.1` (`NWPath.isUltraConstrained` ausente del SDK). Se necesita
un Xcode/SDK compatible con esa dependencia para terminar la compilación y smoke;
no se parcheó el caché compartido ni se degradaron dependencias para ocultarlo.

## Pixel con paquete TEST aislado (2026-10-06)

Por instrucción del usuario se probó también el Pixel con una instalación separada
`com.aquafim.ddr001levantamientos.cabinetstest`, conservando la aplicación operativa.
El [reporte de QR físico y recuperación](pixel-qa-20261006.md) detalla lo probado,
las correcciones y los casos que siguen sin certificarse.
