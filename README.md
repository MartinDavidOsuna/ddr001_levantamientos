# DDR001 Levantamientos

## PRODUCTION RELEASE RUNBOOK

Release candidato `1.0.0+1`, `com.aquafim.ddr001levantamientos`. El endpoint oficial es exclusivamente `http://cifra.aquafim.com:3002/api/v1`; la excepción HTTP está centralizada y cualquier otro HTTP se rechaza. Android limita cleartext al host `cifra.aquafim.com`. Se requiere firma persistente fuera del repo mediante `android/key.properties`. El procedimiento SQL/API, smoke y rollback vive en `../ddr001_api/docs/DDR001_LEVANTAMIENTOS_PRODUCTION_RUNBOOK.md`.

Por decisión operacional actual, tokens Authorization, fotografías y metadata/GPS viajan sin TLS y pueden ser observados o alterados por la red. Esta exposición se acepta para la liberación actual y queda registrada como deuda técnica para una migración futura a HTTPS; no debe ampliarse la excepción a otro dominio, IP o puerto.

Aplicación Flutter independiente para documentar bases de concreto de nuevos hidrantes. Build 1 prioriza contratistas, operación completamente offline, evidencia cámara+GPS y sincronización endurecida con la API DDR001.

La autenticación móvil usa exclusivamente Field Auth: Nombre, Correo y Teléfono,
sin contraseña, cuadrilla, selector de dominio ni selector de rol. El dispositivo se
vincula mediante Installation ID y el perfil Construction recibido del servidor define
las capabilities. Para revisión móvil, resident debe existir como usuario Field.
El cliente se identifica establemente como `ddr001_levantamientos`; otra app o
instalación del mismo usuario mantiene su propia sesión y familia de refresh.

## Requisitos

- Flutter 3.44.8 / Dart 3.12.2
- Android o iOS con cámara y ubicación
- API `feature/construction-field-app` compatible con `90ee7e770f3a66105220c05a60e3b5ed48c7da1d`

## Ejecutar contra TEST

```sh
flutter run --dart-define=APP_ENV=test --dart-define=API_BASE_URL=http://10.0.2.2:3003/api/v1
```

Para dispositivo físico sustituir `10.0.2.2` por la IP LAN de la Mac. Debug/profile permiten cleartext de desarrollo. Release aplica `network_security_config.xml`: base bloqueada y excepción sólo para `cifra.aquafim.com`.

## Calidad y build

```sh
flutter analyze
flutter test
flutter build apk --debug --dart-define=APP_ENV=test --dart-define=API_BASE_URL=http://10.0.2.2:3003/api/v1
```

## Firma Android productiva

Crear una sola upload key definitiva fuera del repo; el comando solicita las contraseñas y datos del certificado sin fijarlos en Git:

```sh
keytool -genkeypair -v \
  -keystore /RUTA_SEGURA/ddr001-levantamientos-upload.jks \
  -storetype PKCS12 \
  -alias ddr001levantamientos \
  -keyalg RSA -keysize 4096 -validity 36500
```

Copiar `android/key.properties.example` a `android/key.properties`, señalar la ruta absoluta y completar `storePassword`, `keyPassword` y `keyAlias`. El build release se detiene explícitamente si falta el archivo, una propiedad o el keystore. Respaldar key, alias, contraseñas y fingerprint: son necesarios para futuras actualizaciones.

La arquitectura separa configuración/red/seguridad/persistencia/media/location/sync, dominio Construction, API remota y features. Los tokens viven exclusivamente en Secure Storage; Hive CE conserva documentos JSON con versión de schema y colas persistentes.

Consulte [PROJECT_TRUTH](docs/ssot/PROJECT_TRUTH.md) y [plan del Build 1](plans/BASE_CONSTRUCTION_APP_PLAN.md).
