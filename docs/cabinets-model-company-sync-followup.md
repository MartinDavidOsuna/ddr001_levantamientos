# Seguimiento: modelo, empresa y borradores

API requerida: rama `fix/cabinet-company-deletion-sync`, basada en `e6f5954`, con migración aditiva `20261023_cabinet_company_and_archive_delete.sql`. No desplegada por esta tarea.

La app conserva operaciones y fotografías pendientes. Se corrige el bloqueo de una corrección de modelo independiente por una eliminación de foto fallida. Se muestra empresa de registro, diferencia entre estado local/servidor y diagnóstico copiable desde Sincronización. El diagnóstico omite respuestas, archivos, coordenadas, series y credenciales. La empresa se envía como expectativa sólo cuando la API anuncia soporte y se valida definitivamente con el perfil del residente en servidor.

AQ26-00001-7 continúa en producción como A1/borrador v1, sin cierre ni corrección confirmados. No se puede concluir la causa exacta del teléfono de David sin su primera operación pendiente. No se convierte en A3 ni se completa por intervención SQL. Los otros borradores requieren la misma revisión; registro local completo no equivale a confirmación del servidor.

La suite completa móvil pasó 259 pruebas (HTTP omitida al no suministrar fixture en esa ejecución). Analyze sin incidencias. Se reprodujo conservación de respuestas presente=false/observación, cierre, A1→A3 y orden de comandos tras reabrir Hive y perder una respuesta. SQL/API real se verificó en 19 pruebas del backend; la eliminación con archivo usa dos directorios TEST y ledger real, sin NAS productivo.

No se compiló/distribuyó otra APK, no se modificó el Pixel y no se borraron datos de campo. La APK 1.5.19 previamente copiada no contiene estos últimos cambios. Revisar/integrar la API y aplicar su migración antes de validar la siguiente versión de app. El script de recuperación histórica de empresa viene separado y arranca en modo consulta; sólo seis UID tienen evidencia consistente, los dos casos ambiguos quedan intactos.

Prueba adicional Dart/Hive → HTTP → API commit `986b948` → SQL TEST aprobada: registro con `expectedCrewId`, instantánea de empresa confirmada, 45 piezas, seis fotos verificadas por dos residentes, instalación y dictamen Entregable v12. Fixture sintético `AQ26-77982-5`; no se usó el Pixel.
