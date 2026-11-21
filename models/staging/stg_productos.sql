select * from (
    values
        ('A', 'Producto A', 490.00),
        ('B', 'Producto B', 1290.00),
        ('C', 'Producto C', 2490.00)
) as t (id_producto, nombre_producto, precio_eur)
