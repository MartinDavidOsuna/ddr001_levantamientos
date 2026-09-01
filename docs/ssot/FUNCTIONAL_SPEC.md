# Functional Specification

## PRODUCTION RELEASE RUNBOOK

El smoke recorre contractor crear/foto/GPS/offline/sync y reviewer rechazar/corregir/aceptar/entregar; pendientes, UUID duplicados o evidencia falsamente confirmada bloquean promoción.

El acceso móvil muestra, en este orden, Nombre, Correo y Teléfono. No utiliza
contraseña, cuadrilla ni selector de dominio/rol. Field Auth vincula la identidad al
dispositivo y Construction Profile decide contractor o resident. La sesión se restaura
sin repetir el formulario y logout conserva la política de pendientes locales.

Contractor usa Inicio, Levantamientos, Mapa y Perfil. Crea UUID, `displayIdentifier` y una cuenta opcional offline; la app bloquea duplicados propios normalizados conocidos. Pasos 1–5 requieren 1–4 fotos. Paso 6 requiere Norte, Este, Sur y Oeste con clasificación persistente; después admite fotos adicionales ilimitadas que no sustituyen una cardinal. Comentarios son opcionales. Finalizar localmente cierra evidencia, muestra confirmación de guardado local, desbloquea el siguiente paso y no depende de Internet. Paso 6 produce `executedLocal` hasta confirmación remota.

Mis levantamientos mezcla local/servidor por UUID, busca identificador/cuenta y filtra estados. Rechazo muestra motivo y usa Correction Round sin modificar evidencia original.

Resident/Admin/Superadmin comparten Inicio, Revisión de base, listados y mapa
global. Pueden aceptar/rechazar/entregar, cambiar identificador/cuenta y corregir
canonical mediante API, pero no evidencia. La revisión identifica explícitamente
base, cuenta, contratista, estado, etapa y fechas. Aceptar cambia `executed` a
`accepted`, mostrado como **Entregable**; rechazar exige motivo multiline sin sólo
espacios. Todas las mutaciones muestran progreso, éxito o error y actualizan el
estado en memoria sin reiniciar. Registrar instalación permanece “Próximamente”.

Todos los estados se muestran mediante un mapper único: Creado, En proceso,
Ejecutado, Rechazado, Entregable y Entregado. Los valores wire no cambian.

## Location Evidence Model

Entrar a un levantamiento inicia prewarm de ubicación de alta precisión. La cámara
no espera GPS: conserva `capturedAt` inmediatamente y la app selecciona el mejor
fix buffered entre 60 s antes y 120 s después. Un fix excelente (≤10 m) dentro de
±30 s se confirma temprano; los demás permanecen provisionales y mejorables.

Finalizar exige ubicación confirmada en toda evidencia conservada, incluidas las
cardinales y adicionales del paso 6. Una foto expirada sin fix queda `unresolved`,
se conserva y debe reemplazarse; nunca se le asigna la ubicación actual tardía.
Un outlier respecto del canonical tampoco permite finalizar.
