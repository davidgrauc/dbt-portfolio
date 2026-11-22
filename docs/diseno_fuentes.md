# Diseño de las fuentes sintéticas

Qué datos genera `scripts/generar_datos.py`, cómo llegan y qué hará dbt con ellos.

Cada fuente tiene dos partes:
- **Llega así (raw)**: columnas y suciedad intencionada. Es lo que genera el script y carga `dbt seed`.
- **Regla de limpieza**: lo que hacen staging e intermediate para dejarla lista para el modelo.

## Criterios generales

- **Fechas.** En origen, todas en UTC, con sufijo `_utc`. Staging calcula una sola vez la hora y la fecha de Madrid (`_madrid`, `fecha_madrid`). `dim_fecha` y los marts usan siempre la fecha de Madrid.
- **Periodo.**
  - CRM e inversión: del 01/01/2025 al 31/12/2025.
  - Web: solo los últimos 3 meses, del 01/10/2025 al 31/12/2025.
- **Productos.** A, B y C. Importes en euros.
- **Países.** ES, MX, CO, AR y FR.
- **Canales válidos.** `paid_social`, `paid_search`, `paid_video`, `email`, `organic_search`, `organic_social`, `referral`, `directo` y `sin_atribuir`. Son los únicos que pueden llegar a los marts y lo comprueba un `accepted_values`.
- **Datos ficticios.** Nombres, emails (dominios `.test` y `ejemplo.com`), teléfonos, IPs e importes son inventados.

## Relaciones

```
crm_contactos ──< crm_formularios >── map_formularios (producto)
      │                 │
      │                 └── utm_id ──── ads_inversion (id_campana)
      │                 └── id_usuario_web ── web_eventos
      └──< crm_negocios (ventas = negocios ganados)
```

---

## 1. CRM · contactos (`crm_contactos`)

**Grano:** un registro del CRM. No es una persona: la misma persona puede tener varios registros.

### Llega así

| Columna | Tipo | Ejemplo |
|---|---|---|
| `id_contacto` | entero | 100123 |
| `email` | texto | `  Ana.Garcia12@ejemplo.com ` |
| `nombre` | texto | Ana |
| `apellidos` | texto | García Puig |
| `telefono` | texto | `0034 612345678` |
| `ip_primera_interaccion` | texto | 81.42.10.7 |
| `ip_ultima_interaccion` | texto | 34.120.5.9 |
| `creado_en_utc` | timestamp | 2025-03-14 21:05:33 |
| `actualizado_en_utc` | timestamp | 2025-06-02 08:11:02 |

Suciedad intencionada:
- **Emails** con mayúsculas o con espacios alrededor.
- **Teléfonos** en formatos distintos: `+34612345678`, `0034 612345678`, `612 345 678` (sin prefijo) o vacío.
- **Duplicados con el mismo email** escrito de otra forma (`ANA@…` y `ana@…`) y otro id.
- **Duplicados con email distinto** y el mismo teléfono.
- **Teléfonos basura**:
  - patrones conocidos: `600000000`, `666666666`, todos los dígitos iguales;
  - números compartidos por muchos contactos.
- **`ip_ultima_interaccion`** es a veces la IP de la plataforma que actualizó el contacto, no la del usuario.

### Regla de limpieza

1. **Email.** Sin espacios y en minúsculas.
2. **Teléfono.**
   - Se quitan espacios y guiones, y `00` pasa a `+`.
   - Solo es válido con prefijo internacional (`+XX…`). Sin prefijo o vacío queda nulo.
3. **País**, por este orden:
   1. prefijo del teléfono válido (`map_prefijos_pais`);
   2. si no hay, `ip_primera_interaccion` (`map_ip_pais`); no se usa la última, por lo de la IP de la plataforma;
   3. si tampoco hay, `desconocido`.
4. **Deduplicación** (`int_contactos_deduplicados`):
   1. Mismo email normalizado: es la misma persona.
   2. Mismo teléfono normalizado: es la misma persona, salvo si el teléfono es basura.
   3. Un teléfono es basura si:
      - coincide con un patrón de `telefonos_basura`, o
      - lo comparten más de 5 contactos (variable de dbt `umbral_telefono_compartido: 5`).
   4. Sobrevive el contacto más antiguo (`creado_en_utc` y, si empatan, el id menor).
   5. Se genera la correspondencia `id_contacto → id_contacto_maestro`. Formularios y negocios la usan para apuntar al contacto superviviente.

---

## 2. CRM · formularios (`crm_formularios`)

**Grano:** un envío de formulario.

### Llega así

| Columna | Tipo | Ejemplo |
|---|---|---|
| `id_envio` | entero | 55012 |
| `id_contacto` | entero | 100123 |
| `id_usuario_web` | texto | `u_8f3a2c` |
| `id_formulario` | entero | 12 |
| `nombre_formulario` | texto | Webinar producto A |
| `pagina` | texto | `https://ejemplo.com/webinar-a` |
| `url_completa` | texto | `https://ejemplo.com/webinar-a?utm_source=Facebook&utm_medium=paid_social&utm_campaign=a_es_leads_blackfriday&utm_id=2301` |
| `email_respondido` | texto | `ana.garcia12@ejemplo.com` |
| `telefono_respondido` | texto | `+34612345678` |
| `nombre_respondido` | texto | Ana |
| `canal_crm` | texto | Paid Social |
| `enviado_en_utc` | timestamp | 2025-03-14 21:05:33 |

**No lleva producto.** El producto se deduce del formulario.

Suciedad intencionada:
- UTMs con mayúsculas (`Facebook`) y caracteres codificados (`%20`, `%5F`).
- Cerca de un 10 % de envíos sin UTMs:
  - en unos, el CRM da `canal_crm`;
  - en otros no hay ningún dato de canal.
- Algún `utm_campaign` que no sigue la convención de nombre.
- Varios envíos por contacto, a veces de formularios de productos distintos.
- Envíos de contactos duplicados (con el id no superviviente).

### Regla de limpieza

1. Se extraen de `url_completa` los parámetros `utm_source`, `utm_medium`, `utm_campaign` y `utm_id`. Se decodifican y se pasan a minúsculas.
2. **Producto y campaña comercial**: de `map_formularios` por `id_formulario`.
3. **Canal**, por este orden:
   1. mapeo de `utm_source` + `utm_medium` (`map_canales`, tipo `utm`);
   2. si no hay UTMs, mapeo de `canal_crm` (`map_canales`, tipo `crm`);
   3. si tampoco hay, `sin_atribuir`.
4. `id_contacto` pasa a `id_contacto_maestro`.
5. **Unión con la inversión**: por `utm_id = id_campana`. No se usa el nombre, que puede cambiar.

---

## 3. CRM · negocios (`crm_negocios`)

**Grano:** un negocio (oportunidad) del CRM.

### Llega así

| Columna | Tipo | Ejemplo |
|---|---|---|
| `id_negocio` | entero | 9001 |
| `id_contacto` | entero | 100123 |
| `producto` | texto | A |
| `estado` | texto | abierto · ganado · perdido |
| `importe_eur` | decimal | 1290.00 |
| `fuente_ultimo_origen` | texto | formulario · checkout · comercial |
| `id_pago` | texto | `pay_7Kq2` (solo si está ganado) |
| `metodo_pago` | texto | tarjeta · transferencia · financiado |
| `a_plazos` | booleano | true |
| `num_plazos` | entero | 3 |
| `creado_en_utc` | timestamp | 2025-03-20 10:00:00 |
| `cerrado_en_utc` | timestamp | 2025-04-02 17:30:00 (vacío si está abierto) |

Suciedad intencionada:
- **Desincronización entre checkout y CRM.** Para el mismo contacto y producto aparece un negocio abierto y otro que nace ya ganado desde el checkout.
- Negocios de contactos duplicados (con el id no superviviente).
- Un contacto puede tener un negocio nuevo de un producto que ya tuvo cerrado.

### Regla de limpieza

1. `id_contacto` pasa a `id_contacto_maestro`.
2. **Duplicado abierto + ganado** del mismo contacto y producto: se queda el ganado.
3. **Ventas** (`int_ventas`): negocios con estado `ganado`. El revenue es `importe_eur` en la fecha de cierre (Madrid), aunque sea a plazos.

### Ventas

No hay fuente de ventas. Una venta es un negocio ganado. Los datos del pago (`id_pago`, `metodo_pago`, `a_plazos`, `num_plazos`) van en el propio negocio.

---

## 4. Anuncios · inversión (`ads_inversion`)

**Grano:** día × plataforma × campaña.

### Llega así

| Columna | Tipo | Ejemplo |
|---|---|---|
| `fecha` | fecha | 2025-03-14 |
| `plataforma` | texto | meta · google · tiktok |
| `id_campana` | entero | 2301 |
| `nombre_campana` | texto | `a_es_leads_blackfriday` |
| `pais` | texto | ES |
| `coste_eur` | decimal | 152.40 |
| `impresiones` | entero | 20450 |
| `clics` | entero | 380 |
| `conversiones_plataforma` | entero | 21 |
| `conversiones_web` | entero | 17 |
| `extraido_en_utc` | timestamp | 2025-03-16 06:00:00 |

**Convención de nombre:** `producto_pais_objetivo_campana`, separada por guion bajo. Por ejemplo, `a_es_leads_blackfriday`.

Suciedad intencionada:
- **Renombrados**: el mismo `id_campana` con nombres distintos a lo largo del tiempo.
- **Nombres fuera de convención** o con mayúsculas, que no coinciden con `utm_campaign`.
- **Filas duplicadas**: el mismo día, plataforma y campaña exportados dos veces.
- **Correcciones tardías**: la plataforma vuelve a enviar los últimos días con el coste corregido, con otro `extraido_en_utc`.

### Regla de limpieza

1. Para cada día × plataforma × campaña se queda la fila con el `extraido_en_utc` más reciente. Esto resuelve duplicados y correcciones.
2. **Nombre vigente** de cada `id_campana`: el último recibido.
3. **Producto y objetivo**: se sacan del nombre según la convención. Si no la sigue, quedan como `desconocido`.
4. En la semana 6, `fact_inversion` será incremental con `merge` y reprocesará los últimos días para recoger las correcciones.

---

## 5. Web · eventos (`web_eventos`)

**Grano:** un evento web.

### Llega así

| Columna | Tipo | Ejemplo |
|---|---|---|
| `id_evento` | texto | `e_0001a9` |
| `id_sesion` | texto | `s_77c1` |
| `id_usuario_web` | texto | `u_8f3a2c` |
| `nombre_evento` | texto | session_start · page_view · click · scroll · form_submit |
| `ocurrido_en_utc` | timestamp | 2025-11-03 19:42:10 |
| `pais` | texto | ES |
| `url_base` | texto | `https://ejemplo.com/webinar-a` |
| `url_completa` | texto | `https://ejemplo.com/webinar-a?utm_source=google&utm_medium=cpc&utm_id=2307` |
| `canal_plataforma` | texto | Organic Search |

**Volumen.**
- Real: 30.000-40.000 sesiones por semana y varios eventos por sesión. Son unos 2 millones de filas en 3 meses.
- El script tiene el parámetro `ESCALA`. Por defecto vale 0,02 (unas 700 sesiones por semana, cerca de 45.000 eventos), para que el repo y el CI sean ligeros.
- Con `ESCALA=1` se genera a tamaño real en local.

Suciedad intencionada:
- Las mismas de las UTMs que en formularios.
- Sesiones sin UTMs, con o sin `canal_plataforma`.

### Regla de limpieza

1. UTMs extraídas de `url_completa` con la misma macro que en formularios.
2. **Canal de la sesión**: UTMs, luego `canal_plataforma` (`map_canales`, tipo `plataforma`), luego `sin_atribuir`.
3. **Visitas** = sesiones distintas (`id_sesion`), no eventos.
4. **Unión con contactos**: a través de `id_usuario_web` de los formularios. No es necesaria para `fact_visitas`, que agrega por fecha, canal y país.

---

## 6. Mapeos (seeds)

| Seed | Columnas | Para qué |
|---|---|---|
| `productos` | `id_producto`, `nombre_producto`, `precio_eur` | `dim_producto`. |
| `paises` | `codigo_pais`, `nombre_pais`, `mercado` | `dim_pais` (mercado: ES, LATAM, EU). |
| `map_prefijos_pais` | `prefijo`, `codigo_pais` | País por teléfono. |
| `map_ip_pais` | `ip_inicio`, `ip_fin`, `codigo_pais` | País por IP (rangos ficticios). |
| `map_canales` | `tipo_origen` (utm, crm, plataforma), `source`, `medium`, `canal` | Un único mapeo para las tres fuentes de canal. |
| `map_formularios` | `id_formulario`, `nombre_formulario`, `producto`, `campana` | Producto y campaña comercial de cada formulario. |
| `telefonos_basura` | `patron` | Teléfonos que nunca sirven para deduplicar. |

---

## 7. Decisiones

| Decisión | Por qué |
|---|---|
| Origen en UTC y fecha de Madrid calculada en staging. | La conversión se hace una sola vez. Los días del panel cuadran con el horario de negocio. |
| País por prefijo y, si no hay, por la IP de la primera interacción. | La IP de la última interacción puede ser la de la plataforma que actualiza el contacto. |
| Solo teléfonos con prefijo internacional son válidos. | Una sola forma de escribir el teléfono hace fiable el país y la deduplicación. |
| Teléfonos basura por patrón y por umbral (> 5 contactos). | Los patrones cubren lo conocido; el umbral cubre lo que aparezca nuevo. |
| Sobrevive el contacto más antiguo. | Conserva la fecha real del primer lead. |
| El producto del formulario sale de un mapeo, no de una columna. | No todos los formularios llevan producto informado en origen. |
| Unión formularios-inversión por `utm_id`, no por nombre. | El nombre de campaña cambia y se escribe de formas distintas; el id no. |
| Ventas = negocios ganados, con el importe del negocio. | Así funciona el CRM y evita una fuente más. |
| Funnel con una fila por contacto × producto, con las primeras fechas de lead, oportunidad y venta. | Es suficiente para el panel y permite un test de grano claro. Los ciclos repetidos quedan como posible ampliación. |
| Canal: UTMs, luego el CRM o la plataforma, luego `sin_atribuir`. | Aprovecha toda la información de canal disponible y deja visible lo que no se puede atribuir. |
| Web reducida con `ESCALA`. | Ni GitHub ni `dbt seed` están pensados para millones de filas; la lógica es la misma. |
