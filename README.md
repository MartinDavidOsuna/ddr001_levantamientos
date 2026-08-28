# DDR001 Levantamientos

## PRODUCTION RELEASE RUNBOOK

Release candidato `1.0.0+1`, `com.aquafim.ddr001levantamientos`. Requiere `API_BASE_URL` HTTPS terminado en `/api/v1` y firma persistente fuera del repo mediante `android/key.properties`. El endpoint documentado hoy (`http://cifra.aquafim.com:3002/api/v1`) no cumple el guard; no distribuir hasta confirmar el HTTPS real. El procedimiento SQL/API, smoke y rollback vive en `../ddr001_api/docs/DDR001_LEVANTAMIENTOS_PRODUCTION_RUNBOOK.md`.

Aplicación Flutter independiente para documentar bases de concreto de nuevos hidrantes. Build 1 prioriza contratistas, operación completamente offline, evidencia cámara+GPS y sincronización endurecida con la API DDR001.

## Requisitos

- Flutter 3.44.8 / Dart 3.12.2
- Android o iOS con cámara y ubicación
- API `feature/construction-field-app` compatible con `90ee7e770f3a66105220c05a60e3b5ed48c7da1d`

## Ejecutar contra TEST

```sh
flutter run --dart-define=APP_ENV=test --dart-define=API_BASE_URL=http://10.0.2.2:3003/api/v1
```

Para dispositivo físico sustituir `10.0.2.2` por la IP LAN de la Mac. No hay URL ni secretos embebidos. Cleartext sólo está habilitado en Android debug/profile; producción exige HTTPS en runtime.

## Calidad y build

```sh
flutter analyze
flutter test
flutter build apk --debug --dart-define=APP_ENV=test --dart-define=API_BASE_URL=http://10.0.2.2:3003/api/v1
```

La arquitectura separa configuración/red/seguridad/persistencia/media/location/sync, dominio Construction, API remota y features. Los tokens viven exclusivamente en Secure Storage; Hive CE conserva documentos JSON con versión de schema y colas persistentes.

Consulte [PROJECT_TRUTH](docs/ssot/PROJECT_TRUTH.md) y [plan del Build 1](plans/BASE_CONSTRUCTION_APP_PLAN.md).
