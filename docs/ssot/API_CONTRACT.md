# API Contract

## PRODUCTION RELEASE RUNBOOK

Compilar con `APP_ENV=production` y `http://cifra.aquafim.com:3002/api/v1`; validar health, auth Field/Admin, RV legacy y Construction antes de distribuir. Cualquier otro HTTP queda rechazado.

Fuente inicial: API SHA `90ee7e770f3a66105220c05a60e3b5ed48c7da1d`.
Extensión cardinal Build 1: `ddade065cb2ca9eb12803e1f6a3ff7bef83eca1c`.

- Field auth: `POST /field-sessions/start`, `POST /field-sessions/refresh`, `POST /field-sessions/:id/end`.
- Login móvil DDR001 Levantamientos: envía nombre normalizado, correo normalizado,
  teléfono de diez dígitos, cuadrilla normalizada y descriptor de dispositivo a
  Field Auth. No captura contraseña, dominio ni rol y jamás intenta Admin Auth.
- `crew` es obligatorio en `/field-sessions/start`, se normaliza en mayúsculas y
  representa la cuadrilla de la sesión de trabajo. La app lo conserva en Secure
  Storage junto con la identidad de sesión y lo muestra en Perfil. No se usa para
  inferir el rol Construction.
- Envía `client_app=ddr001_levantamientos` en cada inicio Field. La identidad de
  sesión servidor es app + installation ID; otras apps y dispositivos del mismo
  usuario conservan sesiones y familias de refresh independientes.
- Logout termina sólo la sesión Field actual. Si el servidor no confirma el cierre,
  la app conserva la sesión local y muestra un error para permitir reintento; no
  simula un logout dejando tokens activos.
- Profile Field: `GET /construction/profile`; devuelve también `crew` de la work
  session actual. Construction Profile sigue siendo la autoridad para rol y
  capabilities.
- Profile admin reviewer: `GET /construction/admin/profile` con JWT admin.
- Contractor: create/list/detail/map; open/patch/complete steps; multipart step/correction photos; corrections.
- Integrity: `POST /construction/photos/verify-batch`, máximo 100 IDs.
- Reviewer: list/map, detail/photo read, patch identifier/account,
  reject/accept/deliver y canonical correction. Acepta JWT Field resident o JWT
  admin explícitamente validado; admin `viewer` recibe 403.

El detalle devuelve `contractor_name` desde
`construction.base_surveys.contractor_user_id → rv.users.full_name`. Las
mutaciones de evidencia conservan autenticación Field y ownership contractor.
La auditoría administrativa usa FKs aditivas a `rv.admin_users`, sin duplicar
identidades ni nombres en Construction.

`POST /construction/base-surveys` no recibe actualmente un snapshot de `crew` del
levantamiento. La cuadrilla soportada por el contrato vigente pertenece a la work
session. Si en el futuro se exige conservar históricamente la cuadrilla exacta de
creación por survey, eso requiere un contrato y persistencia explícitos en API; el
cliente no debe inventar esa relación.

UUIDs móviles e Idempotency-Key hacen reintentables creación/finalización. Un upload 201 nunca es confirmación final.

Los uploads de paso 6 incluyen `photoPurpose`: `north`, `east`, `south`, `west` o `additional`. Es una ampliación aditiva; pasos 1–5 y correcciones no lo envían. El servidor exige las cuatro cardinales confirmadas para completar el paso 6.
