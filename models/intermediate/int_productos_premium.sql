select
    id_producto,
    nombre_producto,
    precio_eur
from {{ ref('stg_productos') }}
where precio_eur >= 1000