# Functional Specification

Contractor usa Inicio, Levantamientos, Mapa y Perfil. Crea UUID, `displayIdentifier` y una cuenta opcional offline; la app bloquea duplicados propios normalizados conocidos. Pasos 1–5 requieren 1–4 fotos. Paso 6 requiere Norte, Este, Sur y Oeste con clasificación persistente; después admite fotos adicionales ilimitadas que no sustituyen una cardinal. Comentarios son opcionales. Finalizar localmente cierra evidencia, muestra confirmación de guardado local, desbloquea el siguiente paso y no depende de Internet. Paso 6 produce `executedLocal` hasta confirmación remota.

Mis levantamientos mezcla local/servidor por UUID, busca identificador/cuenta y filtra estados. Rechazo muestra motivo y usa Correction Round sin modificar evidencia original.

Resident ve revisión y mapa global; puede aceptar/rechazar/entregar, cambiar identificador/cuenta y corregir canonical mediante API, pero no evidencia. Registrar instalación permanece “Próximamente”.

## Location Evidence Model

Entrar a un levantamiento inicia prewarm de ubicación de alta precisión. La cámara
no espera GPS: conserva `capturedAt` inmediatamente y la app selecciona el mejor
fix buffered entre 60 s antes y 120 s después. Un fix excelente (≤10 m) dentro de
±30 s se confirma temprano; los demás permanecen provisionales y mejorables.

Finalizar exige ubicación confirmada en toda evidencia conservada, incluidas las
cardinales y adicionales del paso 6. Una foto expirada sin fix queda `unresolved`,
se conserva y debe reemplazarse; nunca se le asigna la ubicación actual tardía.
Un outlier respecto del canonical tampoco permite finalizar.
