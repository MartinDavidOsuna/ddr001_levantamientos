# Validación de macroetapa móvil 2 — 2026-10-05

## Identidad y alcance

- Repositorio: `MartinDavidOsuna/ddr001_levantamientos`.
- Rama: `feat/ddr001-cabinets-mobile`, worktree independiente.
- Base y HEAD inicial: `0b78ac7decb368dd695ee31e537a635e4d025c3b` (`origin/main`).
- Commit de implementación y pruebas: `4a0b4a0fc7b22813e5453520fedfd51c428c0ede`. El HEAD de entrega agrega
  únicamente esta documentación y se informa en el PR.
- Contrato y API ejecutada: `46b0265b9c8698363f3eca73257bc47382c4d8f2`;
  PR API #15 abierto y en borrador, verificado otra vez al cerrar la validación.
- URL local: `http://127.0.0.1:3003/api/v1`; Android emulador usa `10.0.2.2`.
- SQL consultado realmente: `DDR001_Hidrantes_TEST` / `WIN-5RQE8N8NQ9V`.
- Fotos: `.storage/construction-test` del checkout API local. No producción.

## Resultados ejecutados

| Comprobación | Resultado | Alcance real |
| --- | --- | --- |
| `flutter analyze` | Sin incidencias | Código, pruebas y test de integración |
| `flutter test --reporter expanded` | 188 pasan, 1 omitida explícitamente | Suite de bases existente más gabinetes; HTTP real requiere sesión TEST |
| Test HTTP contra API local | 1 pasa | Cliente Dart, Hive/journal, SQL y almacenamiento reales; capturas sintéticas |
| Android `flutter build apk --debug` TEST | Pasa | Sin firma/distribución productiva |
| Android integración en AVD API 35 | 1 pasa | Navegación, expediente real, revisión final, catálogo, Hive y descarga íntegra de seis fotos |
| iOS `flutter build ios --simulator` | Bloqueado | `connectivity_plus 7.3.1`: `NWPath.isUltraConstrained` no existe en SDK de Xcode 16.4 |

La cobertura nueva incluye permisos y navegación directa, QR/checksum/deduplicación,
ocho variantes y cantidades/series, checklist/política y bloqueos, foto compartida,
revisión final, paginación de 205 bases y 205 expedientes, conflicto de exclusividad
de base, waived no editable, almacenamiento aditivo y reapertura real de Hive,
recuperación de ACK perdido, carga interrumpida, reenvío idempotente, cambio de
usuario/revocación, GPS fallido y archivo faltante, conflictos concurrentes y
reconciliación explícita. Los escenarios de fallas de red/identidad usan dobles
controlados; no se presentan como mediciones físicas.

## Conciliación contra TEST

Resultado persistido por el test HTTP (sin credenciales):

```json
{
  "cabinetId": "d24ef056-bc6f-46e7-b668-74bc0559c09e",
  "uid": "AQ26116053",
  "version": 12,
  "status": "deliverable",
  "parts": 41,
  "photos": 6,
  "historyOperations": 12,
  "approvalInvalidationAndNegativeReviewResolved": true,
  "allPhotosVerified": true
}
```

Se generó un A4-A, se guardó el grafo offline y se enviaron registro, piezas,
evidencia, instalación y dictamen. El mismo residente aprobó. Una corrección
invalidó la aprobación, volvió a validarse/cerrarse, se registró un dictamen
negativo y se resolvió expresamente antes de aprobar. Se compararon documento,
versiones, 41 piezas, series, relaciones, SHA, seis `storageVerified` y doce
operaciones de historia entre cliente y API. Repetir una operación confirmada
recuperó el mismo resultado. Datos sintéticos se conservan en TEST.

El smoke Android abrió ese mismo expediente y descargó sus seis originales con
verificación SHA; se comprobó la pantalla de revisión final mediante captura.
No equivale a completar una inspección física desde la cámara del teléfono.

[Captura de revisión final sobre el AVD TEST](cabinet-final-test.png).

## Preservación y pendientes

El checkout original con cambios de mapas/galería no se modificó. No se tocó
`sources/`, la URL productiva, claves de firma ni SQL de producción. No se
modificaron archivos versionados del backend. No se instaló en el Pixel conectado
ni se escribieron datos de campo.

El runner Flutter desinstaló automáticamente su app en las primeras ejecuciones
sobre el AVD recién creado, únicamente con datos sintéticos. Se detectó y corrigió
el procedimiento con `--no-uninstall`; la ejecución final y las sucesivas conservan
el paquete y sus datos. Esta opción es obligatoria en las instrucciones TEST.
No se utilizó `pm clear`, borrado de Hive ni limpieza de dispositivos como preparación.

Pendientes explícitos antes de certificación/distribución:

1. Compilar/probar iOS con Xcode/SDK compatible con la dependencia indicada.
2. Cámara/QR y GNSS físicos, pérdida del proceso nativo durante cámara, cambio de
   usuario/reconexión en dispositivo y actualización sobre una copia representativa
   con pendientes. Los tests Dart de recuperación no certifican estos eventos nativos.
3. Recorrido concurrente entre dos dispositivos físicos TEST; se cubren conflictos
   controlados por pruebas, pero no se realizó esa sesión de campo.
4. Integración coordinada de API/dashboard/app en las macroetapas siguientes.
   Este PR no activa gabinetes contra producción ni implementa entrega formal.

No se declara certificación E2E física ni iOS. [Instrucciones reproducibles](testing.md)
y [matriz de contrato](contract-matrix.md).
