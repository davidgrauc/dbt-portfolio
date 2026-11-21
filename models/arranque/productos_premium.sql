-- Configuración dentro del propio modelo: sobrescribe la de dbt_project.yml.
-- Este se crea como tabla (los datos se guardan) en vez de como vista.
{{ config(materialized='table') }}

-- ref('productos') apunta al otro modelo. dbt lo sustituye por el nombre real
-- de la vista y, sobre todo, sabe que este modelo depende de `productos`,
-- así que siempre construye `productos` antes. Con los ref se dibuja el DAG.
select
    id_producto,
    nombre_producto,
    precio_eur
from {{ ref('productos') }}
where precio_eur >= 1000
