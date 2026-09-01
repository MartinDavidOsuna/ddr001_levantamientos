# DDR001 Levantamientos

Aplicación Flutter independiente para documentar bases de concreto de nuevos
hidrantes, con operación offline, evidencia fotográfica y geográfica, y
sincronización con el dominio Construction de DDR001.

## Estado certificado

- Versión fuente certificada: `1.3.0+4`
- Tag: `v1.3.0+4`
- applicationId Android: `com.aquafim.ddr001levantamientos`
- Flutter: `3.44.8`
- Dart: `3.12.2`

`main` contiene la versión funcional completa certificada. La certificación
incluyó operación offline, persistencia zero-loss, fotografías, GPS, journal,
queue causal, recuperación tras process death y los flujos Field contractor y
resident. También se validaron actualizaciones in-place sin borrar datos.

No se debe usar `uninstall`, `pm clear` ni clear storage como procedimiento
normal de actualización o recuperación: esas operaciones destruyen el estado
local que la aplicación está diseñada para preservar.

La autenticación móvil usa exclusivamente Field Auth: nombre, correo y teléfono,
sin contraseña, selector de dominio ni selector de rol. El dispositivo se
vincula mediante Installation ID y el perfil Construction recibido del servidor
define las capabilities. Para revisión móvil, resident debe existir como usuario
Field. El cliente se identifica establemente como `ddr001_levantamientos`; otra
app o instalación del mismo usuario mantiene su propia sesión y familia de
refresh.

## API utilizada en la certificación

La certificación de `1.3.0+4` se ejecutó contra el entorno **TEST** de
`ddr001_api`, commit:

```text
0ba0d425fe9dfac8cfacfaf73f2a697689901e5a
```

Este SHA es evidencia de la certificación realizada y **no** un pin permanente
de la aplicación. Antes de cada release o deployment se deben verificar
nuevamente:

- `ddr001_api/origin/main`;
- el contrato Construction real;
- la revisión efectivamente desplegada;
- `/api/v1/version`;
- `/health/live`;
- `/health/ready`.

## Fuente certificada y producción

La fuente `1.3.0+4` está certificada. Esto no implica automáticamente que la API
PROD esté desplegada con el backend requerido, que exista una APK productiva
publicada ni que se haya realizado un rollout de campo.

Antes de un release productivo se debe:

1. verificar la API PROD;
2. confirmar que contiene el hardening requerido;
3. ejecutar un smoke productivo de bajo riesgo;
4. construir la APK release;
5. firmarla con la clave histórica;
6. verificar el certificado;
7. verificar `versionName` y `versionCode`;
8. probar la actualización in-place;
9. distribuir sólo después de superar esos gates.

El endpoint productivo configurado actualmente es
`http://cifra.aquafim.com:3002/api/v1`. Android limita cleartext a
`cifra.aquafim.com`; cualquier otro destino HTTP se rechaza en release. El
procedimiento SQL/API, smoke y rollback vive en
`../ddr001_api/docs/DDR001_LEVANTAMIENTOS_PRODUCTION_RUNBOOK.md`.

Authorization, fotografías y metadata/GPS enviados por HTTP sin TLS pueden ser
observados o alterados por la red. Esta exposición permanece registrada como
deuda técnica y debe migrarse a HTTPS; no se debe ampliar la excepción a otros
dominios, IP o puertos.

## TEST y desarrollo local

Ejemplo para un emulador Android:

```sh
flutter run \
  --dart-define=APP_ENV=test \
  --dart-define=API_BASE_URL=http://10.0.2.2:3003/api/v1
```

Ejemplo para un dispositivo físico conectado mediante `adb reverse`:

```sh
adb reverse tcp:3003 tcp:3003
flutter run \
  --dart-define=APP_ENV=test \
  --dart-define=API_BASE_URL=http://127.0.0.1:3003/api/v1
```

Estas URLs son exclusivamente ejemplos de TEST/desarrollo. No justifican
habilitar cleartext global en el producto.

## Calidad

```sh
flutter pub get
flutter analyze
flutter test
```

Como evidencia histórica, la certificación de `1.3.0+4` concluyó con 139/139
tests PASS. Ese número no es un requisito fijo: la suite puede y debe crecer.

## Firma Android

La continuidad de actualización Android depende de reutilizar la clave histórica
de firma de DDR001 Levantamientos. Su alias lógico es
`ddr001levantamientos`. `android/key.properties` permanece fuera del repositorio,
y tanto el keystore como sus credenciales deben mantenerse respaldados de forma
segura.

No se debe generar una clave de reemplazo para actualizar instalaciones
existentes. El build release se detiene si falta la configuración de firma
requerida.

La arquitectura separa configuración, red, seguridad, persistencia, media,
location, sync, dominio Construction, API remota y features. Los tokens viven en
Secure Storage; Hive CE conserva documentos versionados, journal y colas
persistentes.

Consulte [PROJECT_TRUTH](docs/ssot/PROJECT_TRUTH.md) y el
[plan histórico del Build 1](plans/BASE_CONSTRUCTION_APP_PLAN.md).
