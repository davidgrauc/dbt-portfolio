select
    id_producto,
    nombre_producto,
    precio_eur
from {{ ref('int_productos_premium') }}