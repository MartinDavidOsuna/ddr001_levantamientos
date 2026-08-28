# Roles and Permissions

## PRODUCTION RELEASE RUNBOOK

Certificar contractor, resident y proyecciones reviewer admin/superadmin. Un Field válido sin `construction.app_users` se autocrea sólo como contractor; nunca se autoasignan privilegios reviewer.

La autoridad de acceso es el perfil validado por API; móvil nunca envía role. La UI
consume capabilities centralizadas, no comparaciones de roles dispersas. El login de
esta release usa exclusivamente Field Auth con nombre, correo y teléfono. Contractor
y resident son roles Construction resueltos después del login; un Field válido sin
perfil se autocrea contractor.

| Capability | Contractor | Resident | Admin | Superadmin |
| --- | --- | --- | --- | --- |
| Ver universo completo | No | Sí | Sí | Sí |
| Revisar/aceptar/rechazar/entregar | No | Sí | Sí | Sí |
| Editar identificador/cuenta/canonical auditado | No | Sí | Sí | Sí |
| Crear o mutar evidencia contractor | Sí, sólo propia y abierta | No | No | No |

`resident`, `admin` y `superadmin` son reviewer-equivalent dentro de Construction.
Resident procede de Field (`rv.users` + `construction.app_users`). Admin y
superadmin proceden del dominio administrativo (`rv.admin_users`) mediante JWT
admin validado; no se copian sus IDs a `construction.app_users`. La proyección
actual es `supervisor → admin` y `admin → superadmin`; `viewer` no obtiene acceso.
Ownership siempre deriva del JWT server, nunca de un `userId` enviado por cliente.
La proyección administrativa de API permanece intacta, pero esta UI móvil no inicia
sesiones Admin. Un reviewer móvil para esta release debe ser usuario Field con rol
Construction `resident`.
