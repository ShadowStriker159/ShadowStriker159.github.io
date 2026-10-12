--------------------------------------------------------------------------------
-- LABORATORIO DE SQL TUNING - TRES ESCENARIOS, UN GANADOR CADA UNO
-- Capitulo 9.2 "Joins Methods" - Oracle Database SQL Tuning Guide
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- PASO 0: LIMPIEZA PREVIA
--------------------------------------------------------------------------------
DROP TABLE pedidos PURGE;
DROP TABLE productos PURGE;
DROP TABLE clientes_grande PURGE;
DROP TABLE ciudades_grande PURGE;
DROP TABLE clientes_edad PURGE;
DROP TABLE rangos_edad PURGE;


--------------------------------------------------------------------------------
-- PARTE A: ESCENARIO DONDE GANA NESTED LOOPS
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- PASO 1: Tabla grande
--------------------------------------------------------------------------------
CREATE TABLE productos (
    id_producto     NUMBER PRIMARY KEY,  
    nombre_producto VARCHAR2(50),
    precio          NUMBER
);

INSERT INTO productos
SELECT LEVEL, 'Producto ' || LEVEL, ROUND(DBMS_RANDOM.VALUE(5, 500), 2)
FROM dual
CONNECT BY LEVEL <= 50000;   -- tabla grande de 50.000 productos


--------------------------------------------------------------------------------
-- PASO 2: Tabla chica de pedidos
--------------------------------------------------------------------------------
CREATE TABLE pedidos (
    id_pedido   NUMBER PRIMARY KEY,
    id_producto NUMBER,
    cantidad    NUMBER
);

INSERT INTO pedidos
SELECT LEVEL, TRUNC(DBMS_RANDOM.VALUE(1, 50001)), TRUNC(DBMS_RANDOM.VALUE(1, 5))
FROM dual
CONNECT BY LEVEL <= 200;   -- 200 pedidos en total

COMMIT;

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'PRODUCTOS');
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'PEDIDOS');


--------------------------------------------------------------------------------
-- PASO 3: La consulta clave -> solo 10 pedidos, buscando cada uno
-- su producto en el catalogo de 50.000. 
--------------------------------------------------------------------------------

-- Forzar NESTED LOOPS 
EXPLAIN PLAN FOR
SELECT /*+ USE_NL(pe pr) NO_PARALLEL(pe) NO_PARALLEL(pr) */
       pe.id_pedido, pr.nombre_producto, pr.precio
FROM   pedidos pe
JOIN   productos pr ON pe.id_producto = pr.id_producto
WHERE  pe.id_pedido <= 10;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Forzar HASH JOIN 
EXPLAIN PLAN FOR
SELECT /*+ USE_HASH(pe pr) NO_PARALLEL(pe) NO_PARALLEL(pr) */
       pe.id_pedido, pr.nombre_producto, pr.precio
FROM   pedidos pe
JOIN   productos pr ON pe.id_producto = pr.id_producto
WHERE  pe.id_pedido <= 10;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Forzar SORT MERGE JOIN (tiene que ordenar los 50.000 productos)
EXPLAIN PLAN FOR
SELECT /*+ USE_MERGE(pe pr) NO_PARALLEL(pe) NO_PARALLEL(pr) */
       pe.id_pedido, pr.nombre_producto, pr.precio
FROM   pedidos pe
JOIN   productos pr ON pe.id_producto = pr.id_producto
WHERE  pe.id_pedido <= 10;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

--------------------------------------------------------------------------------
-- PARTE B: ESCENARIO DONDE GANA HASH JOIN
--
-- La receta de Hash Join: las DOS tablas son grandes, NO existe ningun
-- indice util sobre la columna de union, y la condicion es de igualdad (=).
-- Aqui Nested Loops se castiga fuerte ya que sin indice, tiene que escanear la
-- tabla grande una y otra vez y Sort Merge se castiga un poco menos, pero
-- igual tiene que pagar el costo de ordenar la tabla grande completa.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- PASO 1: Dos tablas grandes SIN ningun indice sobre la columna de union
--------------------------------------------------------------------------------
CREATE TABLE ciudades_grande (
    id_ciudad     NUMBER,
    nombre_ciudad VARCHAR2(50)
);

INSERT INTO ciudades_grande
SELECT LEVEL, 'Ciudad ' || LEVEL
FROM dual
CONNECT BY LEVEL <= 50000;   

CREATE TABLE clientes_grande (
    id_cliente NUMBER,
    nombre     VARCHAR2(50),
    id_ciudad  NUMBER
);

INSERT INTO clientes_grande
SELECT LEVEL, 'Cliente ' || LEVEL
FROM dual
CONNECT BY LEVEL <= 5000;  

COMMIT;

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'CIUDADES_GRANDE');
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTES_GRANDE');


--------------------------------------------------------------------------------
-- PASO 2: Join completo, sin filtros, sin indices disponibles
--------------------------------------------------------------------------------

-- Forzar NESTED LOOPS
EXPLAIN PLAN FOR
SELECT /*+ USE_NL(c ci) NO_PARALLEL(c) NO_PARALLEL(ci) */
       c.nombre, ci.nombre_ciudad
FROM   clientes_grande c
JOIN   ciudades_grande ci 
ON c.id_ciudad = ci.id_ciudad;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Forzar HASH JOIN
EXPLAIN PLAN FOR
SELECT /*+ USE_HASH(c ci) NO_PARALLEL(c) NO_PARALLEL(ci) */
       c.nombre, ci.nombre_ciudad
FROM   clientes_grande c
JOIN   ciudades_grande ci 
ON c.id_ciudad = ci.id_ciudad;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Forzar SORT MERGE JOIN 
EXPLAIN PLAN FOR
SELECT /*+ USE_MERGE(c ci) NO_PARALLEL(c) NO_PARALLEL(ci) */
       c.nombre, ci.nombre_ciudad
FROM   clientes_grande c
JOIN   ciudades_grande ci ON c.id_ciudad = ci.id_ciudad;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
--------------------------------------------------------------------------------
-- PARTE C: ESCENARIO DONDE GANA SORT MERGE JOIN
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- PASO 1: Tabla grande de clientes con una columna numerica
--------------------------------------------------------------------------------
CREATE TABLE clientes_edad (
    id_cliente NUMBER,
    nombre     VARCHAR2(50),
    edad       NUMBER
);

INSERT INTO clientes_edad
SELECT LEVEL, 'Cliente ' || LEVEL, TRUNC(DBMS_RANDOM.VALUE(18, 81))
FROM dual
CONNECT BY LEVEL <= 50000;   -- tabla grande: 50.000 filas


--------------------------------------------------------------------------------
-- PASO 2: Tabla chica de rangos de edad (para clasificar por categoria)
--------------------------------------------------------------------------------
CREATE TABLE rangos_edad (
    id_rango  NUMBER,
    edad_min  NUMBER,
    edad_max  NUMBER,
    categoria VARCHAR2(30)
);

INSERT INTO rangos_edad VALUES (1, 18, 25, 'Joven');
INSERT INTO rangos_edad VALUES (2, 26, 35, 'Adulto joven');
INSERT INTO rangos_edad VALUES (3, 36, 50, 'Adulto');
INSERT INTO rangos_edad VALUES (4, 51, 65, 'Adulto mayor');
INSERT INTO rangos_edad VALUES (5, 66, 80, 'Tercera edad');

COMMIT;

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTES_EDAD');
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'RANGOS_EDAD');


--------------------------------------------------------------------------------
-- PASO 3: Join por RANGO (BETWEEN)
--------------------------------------------------------------------------------

-- Forzar NESTED LOOPS
EXPLAIN PLAN FOR
SELECT /*+ USE_NL(c r) NO_PARALLEL(c) NO_PARALLEL(r) */
       c.nombre, r.categoria
FROM   clientes_edad c
JOIN   rangos_edad r ON c.edad BETWEEN r.edad_min AND r.edad_max;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Intentar forzar HASH JOIN
EXPLAIN PLAN FOR
SELECT /*+ USE_HASH(c r) NO_PARALLEL(c) NO_PARALLEL(r) */
       c.nombre, r.categoria
FROM   clientes_edad c
JOIN   rangos_edad r ON c.edad BETWEEN r.edad_min AND r.edad_max;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Forzar SORT MERGE JOIN
EXPLAIN PLAN FOR
SELECT /*+ USE_MERGE(c r) NO_PARALLEL(c) NO_PARALLEL(r) */
       c.nombre, r.categoria
FROM   clientes_edad c
JOIN   rangos_edad r ON c.edad BETWEEN r.edad_min AND r.edad_max;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

--------------------------------------------------------------------------------
-- PASO FINAL ): LIMPIEZA
--------------------------------------------------------------------------------
DROP TABLE pedidos PURGE;
DROP TABLE productos PURGE;
DROP TABLE clientes_grande PURGE;
DROP TABLE ciudades_grande PURGE;
DROP TABLE clientes_edad PURGE;
DROP TABLE rangos_edad PURGE;