-- Un modelo de dbt es un fichero .sql con un único SELECT.
-- dbt lo envuelve en un CREATE VIEW o CREATE TABLE y lo crea en la base de datos
-- con el nombre del fichero: aquí, la vista `productos`.
-- Modelo provisional de la semana 0: se sustituye por un seed en la semana 2.


select * from (
    values
        ('A', 'Producto A', 490.00),
        ('B', 'Producto B', 1290.00),
        ('C', 'Producto C', 2490.00)
) as t (id_producto, nombre_producto, precio_eur)
