# QA de prevención de error humano — 2026-10-06

## Alcance y entorno

- Móvil: `feat/ddr001-cabinets-mobile`, base `c565e11`, correcciones previas sin commit.
- API local: `46b0265`, `/version` indica `test`; readiness DB/storage/config OK.
- Preparador confirmó SQL `DDR001_Hidrantes_TEST` y storage TEST antes de crear fixtures.
- Pixel 7 Pro: paquete separado `com.aquafim.ddr001levantamientos.cabinetstest`.
- Esta sesión agrega pruebas y documentación; no corrige todavía las brechas siguientes.
- No hubo push, despliegue, migración ni modificación de producción.

## Hallazgos que impiden aprobar toda la matriz

1. **Doble envío local:** dos llamadas simultáneas a `enqueue(registration_close)`
   generan dos operaciones con UUID distintos; se esperaba una. El control de versión
   del servidor no sustituye el bloqueo de doble pulsación. Reproducción con controlador
   y almacenamiento real Hive, red simulada; no se afirma un doble tap físico certificado.
2. **Cambio de modelo:** una corrección real A4-A → A1 conservó seis fotos y el
   historial, pero dejó las piezas en cero, aunque algunas pudieran ser compatibles.
   Requiere decidir qué datos conservar y advertir explícitamente cuáles se reinician.
3. **Base distante:** el dominio backend aceptó guardar una instalación sintética
   en 25,-100 para una base en 20,-103. El backend calcula distancia en su respuesta,
   pero no encontré consumo/advertencia de distancia en el flujo móvil. Prueba de dominio
   sin escritura para este caso; no constituye certificación geográfica en campo.
4. **Accesibilidad:** diálogo de cambio de modelo con superficie 360×640, texto 1.8×
   y teclado de 260 px produjo `RenderFlex overflowed by 42 pixels on the bottom`.
   Es una prueba de widget; el mismo diálogo con tamaño normal y teclado en Pixel fue usable.

Estas observaciones exploratorias no se cuentan como pruebas funcionales aprobadas.

## Matriz del listado solicitado

| Caso | Resultado y evidencia | Nivel |
| --- | --- | --- |
| QR/UID inválido u otro dominio | Último dígito inválido rechazado en Pixel; API devuelve 422 para dígito y dominio incorrectos; sin creación | Pixel + HTTP + unit |
| Modelo equivocado y corrección | Advierte revisión de piezas/checklist y conserva fotos/historial; reinicia todas las piezas, no conserva automáticamente las compatibles | HTTP real + inspección UI; brecha |
| Base ocupada | 409 BASE_CONFLICT, identifica gabinete actual y no cambia vínculo | HTTP real, segundo gabinete validado |
| Base distante | No se encontró advertencia/confirmación de distancia; dominio acepta coordenadas alejadas | Dominio + revisión; brecha |
| GPS no disponible o insuficiente | Captura con fallo o 250 m conserva foto sin GPS; no permite certificar GPS de instalación | Fallo simulado, límites sin prueba GNSS física |
| Faltantes antes de avanzar | Pixel: 14 piezas pendientes, estado Incompleto; instalación y revisión final bloqueadas | Pixel + unit |
| Foto de rubro incorrecto | API rechazó foto de registro en piezas con 422 EVIDENCE_OUT_OF_SCOPE; evidencia no se confirma automáticamente | HTTP real + UI previa |
| Cancelar captura | No agrega evidencia vacía, conserva foto previa y libera bloqueo de captura | Picker simulado |
| Doble pulsación/solicitud | Dos solicitudes rápidas generan dos operaciones locales | Exploratoria: brecha |
| Dos clientes modifican mismo gabinete | Respuestas 200 y 409; sólo una transición de versión 12 a 13; reenvío devuelve replayed=true | HTTP concurrente, no dos teléfonos físicos |
| Cambiar usuario con pendientes | El nuevo actor no ve borrador privado ni envía operación del anterior | Controlador/Hive, sesión simulada |
| Interrumpir envío de fotografía | Conserva identidad/bytes/relaciones y verifica antes del cierre; journal recupera resultados perdidos de cámara | Fallos/reinicio simulados; no kill físico durante upload |
| Servidor guarda y se pierde respuesta | Recuperación por recibo sin reenviar comando; API real reenvía respuesta idempotente sin aumentar versión | Fallo simulado + HTTP real |
| Expira sesión | 401 simulado preserva operación y bytes, revoca acceso local; no se probó login interactivo de recuperación | Simulado |
| Modificar después de aprobación | Flujo HTTP invalidó aprobación, exigió nueva instalación/revisión y resolvió dictamen negativo | HTTP real con respuestas sintéticas |
| Modificar finalizado | Edición instalada sin motivo: 422; con motivo invalida aprobación; controles de rol cubiertos | HTTP real + unit |
| Texto grande/pantalla/teclado | Pixel normal usable; 360×640 / 1.8× / teclado presenta overflow | Pixel + widget; brecha |
| Poco espacio/archivo dañado | ENOSPC inyectado conserva fotos/cola y libera captura; bytes alterados bloquean upload/cierre | Simulado; no se llenó almacenamiento real |

## Ejecuciones

- Suite general final: **209 aprobadas, 1 omitida** (HTTP opt-in se ejecutó aparte).
- Prueba HTTP opt-in: **1 aprobada**, recorrido completo con 12 operaciones,
  seis fotos verificadas, invalidación y resolución de revisión negativa.
- Nuevas pruebas permanentes: cinco casos en
  `test/cabinets/cabinet_human_error_test.dart` (cancelación, GPS débil, sesión,
  archivo alterado y ENOSPC simulado).
- Análisis estático y `git diff --check`: limpios.
- Probes de concurrencia, base ocupada y cambio de modelo ejecutados contra API TEST;
  sus resultados no dependen de mocks de servidor.

## Estado retenido y límites

- Pixel AQ26-99999-5: **Incompleto, versión 4**, 14 piezas pendientes tras comprobar
  la barrera de avance; una foto previa conservada. No se declaró instalación realizada.
- Fixture HTTP nuevo AQ26770692: aprobado inicialmente en el flujo sintético, después
  modificado por pruebas de concurrencia y cambio de modelo; **no usarlo como ejemplo
  de expediente final aprobado**. Versión resultante 14, fotos conservadas.
- Segundo gabinete AQ26591340 quedó validado y su asociación a la base ocupada fue rechazada.
- Fixtures y operaciones rechazadas se conservan como evidencia TEST; no se borraron filas.
- `adb reverse tcp:3003` quedó restaurado y API local disponible.
- Pendientes físicos: dos teléfonos trabajando simultáneamente, matar proceso durante
  cámara/upload real, almacenamiento realmente lleno, recuperación interactiva de sesión
  expirada y exactitud GNSS. La prueba de uso sin ayuda requiere observar a un operador;
  no fue sustituida por pruebas automatizadas.

Logs detallados locales: `/tmp/ddr001-human-error-evidence/`.

## Seguimiento

Los cuatro hallazgos anteriores se atendieron posteriormente en
[prevención de errores humanos](human-error-prevention-20261006.md).
Este reporte conserva los resultados previos a esas correcciones.
