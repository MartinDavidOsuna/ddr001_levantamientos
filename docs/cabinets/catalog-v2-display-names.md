# Checklist y catálogo v2 — 2026-10-15

Base de rama: origin/main `a2882944539df0b56e169bc0b70bd7b12e5b9ab3`. Rama: `feat/cabinet-checklist-display-names`.

La pantalla de piezas utiliza `displayName ?? description` del snapshot del gabinete. La identidad de captura, evidencia y sincronización sigue siendo `code`. La app no lee XLSX ni contiene objetivos de producción. La descripción original permanece en el snapshot; ningún serial se convierte a número.

El catálogo descargado se guarda íntegro en Hive por versión. Los nuevos gabinetes usan la versión actual descargada. Un expediente iniciado conserva su `catalogVersion`, nombres y códigos tras descargar otro catálogo, reiniciar o corregir su modelo. No se borra Hive ni se reescriben expedientes.

Fuente del fixture v2: catálogo generado por API desde `A3-A2-A1-A4 - HIDRANTES PARCELARIOS - Material para codigos QR(1).xlsx`, SHA256 `1b1bb2792efc01246ab0ff5ed78a7b8912c884d413b8b2be7fb5015eafec8eb5`. Versión `ddr001-cabinets-20261015-v2`; el fixture antiguo permanece para regresión. Las ocho variantes conservan instancias y reglas de serie. Los extras de automatización ausentes del Excel usan su descripción histórica.

Validación: `flutter test` 227 aprobadas, 1 integración HTTP omitida por configuración; `flutter analyze` sin incidencias. Incluye QR, checklist, fotografías, series, sync, bases, Hive/reinicio y render de nombre visible. La integración real del contrato Field se ejecuta en el PR API contra SQL TEST.

Versión preparada: 1.5.3+14. APK firmado de TEST compilado con `APP_ENV=test` y `API_BASE_URL=http://127.0.0.1:3003/api/v1`. Requiere API TEST local y, cuando se conecte Pixel, redirección USB correspondiente. No se instaló, distribuyó ni probó físicamente: el usuario indicará cuándo conectar Pixel. No representa certificación productiva.

Dependencia: integrar primero API `feat/cabinet-catalog-display-names-production` con migración/rebuild; ningún despliegue ni merge automático forma parte de esta entrega.

API requerida: https://github.com/MartinDavidOsuna/ddr001_api/pull/19.
APK local: `dist/DDR001-Levantamientos-1.5.3+14-TEST.apk`; SHA256 `3262622b3b129930e21510706cddf0f424d6e4558a851bfac8c5e194415099c7`. Firma APK v2 verificada; versionCode 14/versionName 1.5.3. No incluye el Excel en runtime.

## Actualización TEST 1.5.4+15 — 2026-10-16

En Registro se agregó **Eliminar gabinete y fotografías**. Requiere residente,
conexión, capacidad anunciada por API, escribir el UID y confirmar el borrado.
No admite gabinetes instalados o vinculados a una base. La API requiere la
migración `20261016_cabinet_deletions.sql`; sólo soporta almacenamiento local
sin fotografías administradas por el archivador. No se desplegó en producción.

La intención se guarda en el expediente Hive antes del envío, con actor,
operationId, UID y versión estables. Sólo tras confirmar el recibo del servidor
se eliminan el directorio y filas locales de ese UUID. Si se pierde la respuesta,
se conservan las fotos y se recupera el mismo recibo al reintentar. Otros
expedientes y las bases se conservan. Un conflicto de versión permite cancelar
la petición rechazada, actualizar y confirmar otra vez. Tras completarse, el
mismo UID se registra desde Escanear gabinete con un UUID técnico nuevo.
No se borran respaldos ni copias de otros teléfonos desconectados.

Se agregó Reconectar sesión para una sesión de campo que no sea válida para
la API actual. Se exige conservar el mismo userId; los pendientes no cambian de
actor. Nunca se vacían Hive ni Secure Storage para reparar la conexión.

Para reproducir en Pixel dedicado a TEST:

```sh
# API: npm run dev:construction-test en el worktree de backend compatible.
adb -s 27301FDH3004R7 reverse tcp:3003 tcp:3003
flutter build apk --release --dart-define=APP_ENV=test --dart-define=API_BASE_URL=http://127.0.0.1:3003/api/v1
adb -s 27301FDH3004R7 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s 27301FDH3004R7 shell am start -n com.aquafim.ddr001levantamientos/.MainActivity
```

Usar la firma histórica y comprobar el paquete instalado antes de actualizar.
No usar uninstall, clear storage ni pm clear. El túnel USB y la API local deben
seguir activos. La captura permanece disponible sin conexión; el borrado
necesita confirmación remota. No ejecutar el borrado sobre datos reales para
validar el botón: las pruebas automatizadas utilizan expedientes sintéticos.

Resultados: 232 pruebas de app aprobadas y una omitida; análisis estático sin
incidencias. Tras ajustar la presentación de sesión/permisos se repitieron las
12 pruebas focalizadas de borrado y widgets, todas aprobadas. Backend: 837
unitarias y 17 de integración TEST aprobadas.

Pixel 27301FDH3004R7: actualización in-place de 1.5.3+14 a 1.5.4+15 con el mismo
certificado, APK también copiada a Download. Se comprobó que la API local estaba
apagada y faltaba adb reverse; ambos se restablecieron. La sesión anterior tenía
firma inválida; reconectar obtuvo 201 en field-sessions/start y 200 en profile,
conservando el mismo userId. La base TEST devuelve contractor para ese usuario,
por lo que la app debe ocultar gabinetes. Cambiar ese permiso quedó pendiente de
autorización explícita. No se validó el diálogo sobre un expediente del Pixel ni
se eliminó ninguno de sus registros. El borrado real se probó sólo con fixtures
sintéticos en TEST. No se modificaron permisos ni datos productivos.

Seguimiento 2026-10-16: con autorización explícita del usuario, se cambió
únicamente Martin Osuna de contractor a resident en DDR001_Hidrantes_TEST.
Tras reiniciar el proceso (sin borrar almacenamiento), el Pixel mostró
Registrar gabinete, Revisión de Base y Revisión de Hidrante. Se abrió el listado
y el diálogo de eliminación, se verificó su confirmación deshabilitada sin UID
ni aceptación, y se canceló sin eliminar datos. Queda resuelto el bloqueo de
permisos de TEST indicado arriba.

## Captura directa TEST 1.5.5+16 — 2026-10-16

Por solicitud del usuario se retiró la pantalla Revisar fotografía y el botón
Foto legible y correcta, tanto al tomar una foto como al relacionar una ya
existente. La captura con GPS se guarda y asocia directamente al punto. Sin
GPS se conserva el archivo y se muestra su pendiente en el editor, sin abrir
una revisión automáticamente. La consulta manual de fotos sigue disponible.

Para nuevas capturas de gabinetes, la representación destinada a subir a API
es una copia exacta del archivo de cámara; sólo la miniatura se reduce. El
original durable, journal, SHA-256 y comprobación de integridad se mantienen.
No se modifican imágenes ni hashes de operaciones ya pendientes. Las capturas
de bases mantienen su comportamiento anterior.

No se declara automáticamente que una placa de serie sea legible: la
confirmación específica de correspondencia de serie exigida por el contrato
se conserva en el editor de piezas, sin la pantalla adicional de revisión.

Validación: 234 pruebas aprobadas (una omitida), flutter analyze limpio y APK
release TEST compilada. Las nuevas pruebas verifican captura/asociación sin
pantalla de claridad y bytes/SHA-256 idénticos al archivo original de cámara.
Instalada 1.5.5+16 mediante adb install -r, con firma histórica, conservando
almacenamiento. App abierta por ADB; APK copiada a Download del Pixel.

## Registro simplificado TEST 1.5.6+17 — 2026-10-19

En paso 1 se ocultan el detalle técnico de sincronización, versión, catálogo y
fecha del borrador. Se muestra Foto(s) del gabinete, obligación de al menos una,
conteo de fotos y miniaturas que abren la imagen. Se eliminan las leyendas de
fecha/GPS/guardado de las tarjetas. Siguiente conserva la confirmación y comando
registration_close, espera persistencia durable y pasa a Piezas. El botón para
eliminar el gabinete queda después de Siguiente.

Las fotos de registro en borrador pueden eliminarse con confirmación. La
intención queda persistida y las fotos se ocultan del borrador; se borran los
archivos locales sólo tras respuesta de DELETE /construction/cabinets/:id/photos/:photoId.
Un fallo conserva archivos y permite reintento. Se impide reutilizar el UUID de
la foto eliminada. Las fotos que respaldan cierres son inmutables y no se
eliminan desde este flujo. El backend requiere la migración TEST
20261019_cabinet_photo_deletions.sql; no se ejecutó SQL productivo.

Ubicación: antes sólo había una consulta de 15 s posterior a la captura. Ahora
se inicia el proveedor antes de abrir cámara y se usa el búfer de posiciones
válidas; una lectura posterior puede completar automáticamente una foto reciente
y asociarla al registro. Se mantiene la ventana de 120 s y precisión máxima
100 m. No se asigna la coordenada actual a fotos antiguas. El journal añade
photoCapturedAt opcional para distinguir la fecha del archivo de cámara de la
preparación de la captura; los journals anteriores mantienen compatibilidad.
Si la cámara no entrega fecha válida dentro del intervalo, se conserva el
momento de recepción del archivo como referencia; nunca se alteran sus bytes.

En el Pixel se comprobaron ubicación activa y permisos de ubicación precisa.
La foto ya existente carecía de coordenada válida; no hay información suficiente
para atribuir retrospectivamente una posición correcta. Se conserva para consulta
y puede reemplazarse mediante una nueva captura con ubicación disponible.

Pruebas: 237 aprobadas y una omitida; flutter analyze limpio. Se cubrieron
conteo/etiquetas, cierre durable seguido de navegación, captura directa,
borrado diferido sin resurrección al recuperar journal y GPS posterior válido
frente a posiciones fuera de ventana. Backend: 837 unitarias, 17 de integración
SQL/API TEST; análisis de tipos, lint y build correctos.

Pixel: instalada TEST 1.5.6+17 con adb install -r y firma histórica; APK en
Download. Se abrió AQ26-99998-7 y se comprobó visualmente el paso Registro:
contador de una foto conservada, visor completo funcional, botones en el orden
solicitado y ausencia de catálogo/versiones/fecha/GPS en las tarjetas. Se dejó
abierto ese paso. No se borraron fotos ni se cerró el registro del usuario.
La navegación a Piezas se verificó con fixtures en pruebas de widgets; no se
atribuyó una coordenada nueva a la captura anterior sin GPS.

### Registro directo a Piezas — TEST 1.5.7+18

El botón Siguiente guarda el cierre local de registro y abre Piezas sin mostrar el diálogo Confirmar identificación. Se conserva la validación de evidencia requerida antes del cierre. La prueba de widget comprueba la ausencia del diálogo, el estado registrado y la navegación al segundo paso.

### Piezas por lado — TEST 1.5.8+19

Cinco pasos: Registro, Distrito, Productor, Instalación y Revisión final. Las piezas se muestran sin desplegables ni enlaces Revisar pendientes, según lado y orden publicados por la API a partir del Excel revisado. Las casillas nuevas aparecen marcadas; Siguiente persiste esos valores explícitamente. Un faltante ya guardado permanece desmarcado. Sólo se captura serie del flujómetro, sin fotos por componente; fotos y series históricas se conservan.

La distribución se obtiene de `partsReviewPolicy` descargada y conservada en Hive. La adopción viaja en `parts_save.partsReviewPolicyVersion`; no se modifica el snapshot del catálogo. Distrito guarda y avanza a Productor; Productor guarda/valida y avanza a Instalación sólo si no faltan piezas ni la serie. Se corrigió la deduplicación para permitir una nueva validación tras otra operación de guardado. No hay migración destructiva ni eliminación de pendientes.

En el tamaño normal del Pixel las listas completas se muestran en una vista. Con fuente ampliada, teclado o pantalla pequeña se habilita desplazamiento para conservar legibilidad. El primer uso requiere descargar la política desde la API de TEST actualizada.

Validación de esta iteración: análisis limpio; 239 pruebas móviles aprobadas (1 omitida), incluidas visibilidad completa de ambos lados en tamaño Pixel, conservación de faltantes, series y evidencia, y nueva validación posterior a correcciones. API: 838 unitarias; 17 integraciones previas aprobadas y nueva integración de política/sin fotos/reenvío idempotente/consulta SQL aprobada contra DDR001_Hidrantes_TEST. No se certifica un nuevo recorrido completo desde cámara del Pixel hasta instalación.

### Automatización separada — TEST 1.5.9+20

Los modelos automatizados muestran Registro → Distrito → Productor → Automatización → Instalación → Revisión final. Los manuales mantienen cinco pasos sin Automatización. La agrupación utiliza `automatedOnly` del catálogo API: Keller, solenoides y el paquete de automatización se revisan sólo en el paso 4, sin duplicarse en Distrito/Productor. Se conserva el orden publicado por la API dentro de cada lista y todos los conceptos se presentan en mayúsculas, sin alterar las series capturadas.

Cada Siguiente guarda su grupo; la validación de piezas ocurre en el último grupo (Automatización o Productor en manuales). No hay cambios de API ni migración local para esta separación. Las capturas permanecen vinculadas al mismo código físico.

### Listas compactas y solenoides universales — TEST 1.5.10+21

Las filas tienen altura natural y separación fija; no se estiran para llenar la pantalla. La serie del flujómetro se captura inmediatamente debajo de su concepto. El campo conserva el texto y ceros iniciales.

La app consume la política API `ddr001-parts-20261019-v2`: solenoides en Distrito/Productor para todos los modelos, sin duplicarlos en Automatización. Para expedientes manuales antiguos se muestran las instancias adicionales publicadas en `universalParts`, que se persisten al guardar el grupo y se registran en servidor mediante la adopción explícita de política. Keller y el paquete adicional siguen en Automatización. Datos, series y fotos existentes se conservan. Es necesaria una descarga inicial de la nueva política desde la API TEST; después funciona offline.

Validación 1.5.10+21: análisis limpio, 240 pruebas móviles aprobadas (1 omitida), 838 unitarias API aprobadas y prueba focalizada real sobre DDR001_Hidrantes_TEST con A4 manual, siete solenoides, guardado/validación, repetición idempotente y consulta consistente. API lint/build aprobados. APK firmada instalada mediante actualización conservando datos y comprobación visual de Distrito en Pixel; copia en Download.

### Guardar revisión y salir — TEST 1.5.11+22

El último checklist (Productor en manuales, Automatización en automatizados) muestra Guardar y salir. El modal ofrece Guardar gabinete o Continuar revisión. Confirmar guarda/valida localmente mediante la cola existente y vuelve al listado; cancelar permanece en el checklist sin generar operaciones nuevas. Se pueden conservar expedientes incompletos para continuarlos después, sin declararlos validados. No se inicia instalación ni revisión final: se realizan posteriormente en campo.

Validación 1.5.11+22: análisis sin errores y 242 pruebas aprobadas (1 omitida). Pruebas de widget cubren cancelar y guardar/salir en manual y automatizado, conservando Incompleto/Validado y sin crear instalación. APK TEST instalada conservando datos; modal comprobado visualmente en Pixel y descartado con Continuar revisión sin guardar el expediente del usuario.

### Entrada separada para instalación — TEST 1.5.12+23

Registrar gabinete sólo muestra Registro, Distrito, Productor y (si corresponde) Automatización. No hay pestañas de Instalación/Revisión final ni navegación automática a ellas en ese flujo. El acceso principal INSTALAR GABINETE reúne ambas etapas de campo y sustituye el acceso previo Revisión de hidrante. Su listado muestra gabinetes validados/instalados/entregables y no ofrece escáner; al abrir se muestran exclusivamente Instalación y Revisión final. Un gabinete ya instalado abre la revisión final; los validados abren Instalación. Se mantienen las restricciones de residente, validación previa de piezas y cierre previo a revisión final. No se cambia almacenamiento ni estados.

Validación de esta entrada: `flutter analyze` sin incidencias; `flutter test`: 243 aprobadas y 1 omitida. APK TEST 1.5.12+23 compilada e instalada con `adb install -r` en Pixel 7 Pro de TEST, conservando datos. Comprobación visual del botón de inicio, listado de expedientes aptos y las dos pestañas de campo del expediente AQ26-99998-7, sin ejecutar capturas ni cierres. Copia en Download del dispositivo.

### Identificación antes de instalar — TEST 1.5.13+24

INSTALAR GABINETE ahora abre identificación por cámara QR o número de hidrante manual, sustituyendo el listado como entrada. Se valida el UID y se busca primero entre los expedientes locales autorizados. Si no está descargado, se consulta `GET /construction/cabinets/resolve?uid=...`; la respuesta se conserva localmente sin crear comandos. Un expediente existente abre únicamente Instalación y Revisión final; si ya está instalado, comienza en Revisión final. Las condiciones de cierre y validación de piezas siguen vigentes.

Sólo un 404 de la consulta remota muestra el modal «Gabinete no encontrado» y conduce a Registrar gabinete con el UID precargado. El residente elige modelo/automatización antes de crear el registro. Un fallo de red, sesión o servidor no se interpreta como inexistencia. Sin conexión, un expediente local se puede abrir; si falta localmente, se solicita conexión, sin crear un duplicado. La navegación conserva la restricción a residentes y no elimina capturas pendientes.

Pruebas agregadas: prioridad local con QR repetido y conservación de pendientes, recuperación y persistencia desde API, distinción entre ausencia/errores/offline, UID inválido, navegación a etapas de campo y modal con transferencia del UID al formulario de registro.

Validación: `flutter analyze` sin incidencias; 248 pruebas aprobadas, 1 omitida. Compilación release TEST e instalación conservadora en Pixel 7 Pro (1.5.13+24), copia en Download. Verificado en dispositivo: captura manual de AQ26-99998-7 abre instalación existente; consulta de AQ26-88888-9 contra API local TEST muestra ausencia y transfiere el UID al registro, sin crear expediente. La lectura física de QR con cámara no se repitió en esta iteración; su validación y reutilización se cubrieron en pruebas automatizadas.

### Instalación sin accesos azules a pendientes — TEST 1.5.14+25

Se retira la lista azul de pendientes por bloque y su filtro de navegación. Los bloques del checklist permanecen desplegables, con su avance, respuestas y validaciones de cierre intactos. Sin migraciones ni cambios de datos. Análisis sin incidencias y 11 pruebas de widgets aprobadas; APK TEST compilada e instalada conservando datos del Pixel.

### Instalación por temas y distancia estricta — TEST 1.5.15+26

La captura GPS requiere una base seleccionada con coordenadas locales. Persiste la captura propia (nunca sustituye la coordenada por la base), calcula distancia geodésica y confirma sólo si es estrictamente menor de 50 m. Un resultado de 50 m o superior queda conservado para diagnóstico, muestra error y no permite guardar/enviar o cerrar instalación. Se vuelve a comparar al guardar, por lo que cambiar la base no conserva una validación anterior. La precisión no amplía el radio permitido; siguen vigentes los controles existentes de GPS y antigüedad.

El formulario se divide en ubicación/base y los temas aplicables del catálogo, con Anterior/Siguiente y listas abiertas, sin ExpansionTile ni códigos CI visibles. Observaciones y acciones de envío/cierre quedan en el último tema. Las respuestas continúan en guardado local automático.

Por instrucción del usuario, CI029, CI030 y CI031 reciben Sí como valor predeterminado y se ocultan. Los defaults se incorporan a la captura persistida al editar/guardar; CI031 incluye los códigos de componentes con serie conforme al contrato API. No se cambian respuestas históricas: una respuesta previa distinta de Sí conserva su control para corregirla. El resto de comprobaciones físicas permanece sin respuesta inicial y la API conserva su política de cierre. No hay migración ni cambio de API en esta iteración.

Validación: análisis sin incidencias; 251 pruebas aprobadas y 1 omitida; APK TEST 1.5.15+26 instalada con actualización conservadora y copiada a Download. Verificación visual en Pixel del paso ubicación y de Identidad y ubicación, sin códigos CI ni las tres preguntas predeterminadas. La base actualmente seleccionada en AQ26-99998-7 no tiene coordenadas locales: no se certificó una comparación GPS real contra ella ni se alteró su selección o captura. La distancia y el límite estricto se probaron automáticamente; falta comprobación de campo con una base georreferenciada.

### Encabezado fijo de instalación — TEST 1.5.16+27

El encabezado del expediente de campo muestra «Modelo · variante» y deja de mostrar los textos técnicos de guardado/sincronización y última captura. Los errores y el acceso a sincronización permanecen disponibles. El título del paso, las instrucciones y los pendientes/avance se colocan en un panel fijo sobre la lista desplazable. Sólo las preguntas y acciones se desplazan. No se cambian respuestas, persistencia, validación GPS ni comandos API.

Validación: `flutter analyze` sin incidencias; 11 pruebas de widgets aprobadas, incluida posición fija del panel tras desplazar la lista. Compilación TEST e instalación conservadora en Pixel (1.5.16+27); verificación visual del título Modelo, ausencia de textos técnicos y panel fijo al desplazar Identidad y ubicación. No se modificaron respuestas del expediente durante la comprobación.

### Galería por rubro — TEST 1.5.17+28

El editor de evidencia ya no repite la galería completa de instalación en cada rubro. Muestra el botón de captura y un conteo de IDs únicos asociados («1 foto tomada» / «N fotos tomadas»). Tocar el conteo abre una galería filtrada exclusivamente por esas relaciones, con acceso a la foto completa y descarga de evidencia remota dentro de la galería. Un rubro vacío abre su estado vacío; las relaciones cuyo archivo aún falta se muestran pendientes de descarga. Se mantienen los archivos y relaciones existentes, incluidas fotos compartidas explícitamente; no se duplican ni eliminan archivos.

Una captura sin GPS se relaciona con el rubro como no confirmada para que permanezca localizable, sin inventar coordenadas ni aprobar evidencia incompleta. La pantalla mantiene la restricción a residentes. El registro inicial conserva su editor específico.

Validación: análisis sin incidencias y 16 pruebas de captura/widgets aprobadas, incluida galería filtrada con dos fotos de instalación en rubros diferentes y denegación a contratista. Compilación TEST 1.5.17+28 instalada con `adb install -r` y app abierta en Pixel; APK copiada en Download. No se tomaron nuevas fotos del expediente del usuario para esta validación.

### Título de galería por rubro — TEST 1.5.18+29

La galería recibe como título la etiqueta del punto del catálogo que la abrió, en lugar de «Fotos del rubro». La evidencia de correcciones también conserva el nombre de su pregunta; revisión final muestra «Fotografía general de revisión final». Análisis sin incidencias y 5 pruebas de captura aprobadas (incluido título de galería). APK TEST compilada, instalada conservando datos en Pixel y copiada en Download.
