--------------------------------------------------------------------------------
-- LABORATORIO: OPTIMIZACIÓN DE CONSULTAS AVANZADAS E ÍNDICES EN ORACLE
-- Nivel: Avanzado — SOLO CASOS RAROS (se asume dominio de EXPLAIN PLAN / DBMS_XPLAN)
-- Motor: Oracle Database (secciones marcadas requieren 12c/19c+ y privilegios DBA)
-- Formato: 100% SQL puro (sin bloques PL/SQL; DBMS_STATS y DBMS_SQLTUNE se invocan
--          con CALL en vez de EXEC/BEGIN...END)
--------------------------------------------------------------------------------
-- ÍNDICE DE CASOS
--  1. NULLs en índices B-tree
--  2. Conversión implícita de tipos
--  3. Estadísticas extendidas (columnas correlacionadas)
--  4. Bind peeking / CURSOR_SHARING
--  5. Bitmap Join Index + Star Transformation
--  6. Planes adaptativos (Adaptive Query Optimization, 12c+)
--  7. Cardinality feedback
--  8. Índices GLOBAL vs LOCAL en tablas particionadas
--  9. SQL Plan Baselines (SPM)
-- 10. Indexación automática (DBMS_AUTO_INDEX, 19c+)
-- 11. SQL Tuning Advisor programático (DBMS_SQLTUNE)
-- 12. OR Expansion (transformación interna VW_ORE_...)
-- 13. Table Expansion (VW_TE_... con partición sin índice)
-- 14. Join Factorization (UNION ALL con tabla repetida)
-- 15. Cursor-Duration Temporary Tables (WITH materializado en memoria)
-- 16. Bloom Filters en hash join paralelo (JOIN FILTER CREATE/USE)
-- 17. Index Skip Scans (índice compuesto sin filtrar la columna líder)
-- 18. NOT IN vs NOT EXISTS con NULLs (antijoin que "desaparece" filas)
-- 19. SQL Plan Directives (corrección persistente, sobrevive flush del shared pool)
-- 20. Real-Time Statistics y modelos de regresión NDV (21c)
-- 21. Hint Usage Reports (detectar hints ignorados silenciosamente)
-- 22. CASO INTEGRADOR FINAL — bug "intermitente" clásico
--------------------------------------------------------------------------------


--================================================================================
-- SECCIÓN 1: NULLs EN ÍNDICES B-TREE
--================================================================================
-- TEORÍA:
-- Un índice B-tree estándar NO almacena entradas para filas donde TODAS las
-- columnas indexadas son NULL. Por eso "col IS NULL" casi nunca usa el índice
-- (no hay nada que buscar ahí), aunque "col IS NOT NULL" sí puede usarlo.
-- Truco: incluir una columna que nunca es NULL (o una constante) en el índice
-- para forzar que la fila SÍ tenga entrada, incluso cuando la columna de interés
-- es NULL.

-- SETUP
CREATE TABLE lab_nulls (
    id          NUMBER PRIMARY KEY,
    fecha_baja  DATE,               -- NULL = empleado activo
    depto       VARCHAR2(20) DEFAULT 'X' NOT NULL
);

INSERT INTO lab_nulls
SELECT LEVEL,
       CASE WHEN MOD(LEVEL, 50) = 0 THEN NULL ELSE SYSDATE - LEVEL END,
       'D' || MOD(LEVEL, 10)
FROM DUAL CONNECT BY LEVEL <= 200000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_NULLS');

CREATE INDEX ix_nulls_fecha ON lab_nulls (fecha_baja);
CREATE INDEX ix_nulls_fecha_dummy ON lab_nulls (fecha_baja, depto);

-- EJERCICIO
-- (a) Este filtro casi seguro NO usará ix_nulls_fecha:
EXPLAIN PLAN FOR
SELECT * FROM lab_nulls WHERE fecha_baja IS NULL;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- (b) Este filtro, apoyándose en el índice compuesto con una columna NOT NULL,
--     sí puede resolver el IS NULL vía índice:
EXPLAIN PLAN FOR
SELECT depto FROM lab_nulls WHERE fecha_baja IS NULL AND depto = 'D0';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Por qué el índice compuesto (fecha_baja, depto) sí puede evaluar IS NULL
--    aunque fecha_baja sea NULL en la fila?
-- 2) ¿Qué pasaría si en vez de un índice compuesto usamos un índice basado en
--    función NVL(fecha_baja, DATE '9999-12-31')? ¿Qué ventaja/desventaja tiene
--    frente al truco de la columna dummy?


--================================================================================
-- SECCIÓN 2: CONVERSIÓN IMPLÍCITA DE TIPOS
--================================================================================
-- TEORÍA:
-- Cuando comparas una columna VARCHAR2 indexada contra un literal NUMBER (o
-- viceversa), Oracle aplica reglas de conversión implícita que a veces envuelven
-- la COLUMNA (no el literal) en una función interna (p.ej. TO_NUMBER(col)).
-- Esto inutiliza el índice SIN lanzar ningún error ni warning visible en el SQL:
-- el plan simplemente cambia a FULL TABLE SCAN silenciosamente.

-- SETUP
CREATE TABLE lab_conversion (
    id          NUMBER PRIMARY KEY,
    codigo_emp  VARCHAR2(10)   -- almacena solo dígitos como texto: '00123'
);

INSERT INTO lab_conversion
SELECT LEVEL, LPAD(LEVEL, 5, '0')
FROM DUAL CONNECT BY LEVEL <= 200000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_CONVERSION');

CREATE INDEX ix_conv_codigo ON lab_conversion (codigo_emp);

-- EJERCICIO
-- (a) Literal numérico contra columna VARCHAR2 -> Oracle convierte la COLUMNA:
EXPLAIN PLAN FOR
SELECT * FROM lab_conversion WHERE codigo_emp = 123;   -- sin comillas
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- (b) La forma correcta, literal como texto, respeta el índice:
EXPLAIN PLAN FOR
SELECT * FROM lab_conversion WHERE codigo_emp = '00123';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca en el Predicate Information del plan (a) la función interna que
--    envuelve a codigo_emp. ¿Qué diferencia hay entre esto y usar UPPER(col)
--    explícitamente en el WHERE?
-- 2) ¿Por qué este bug es más peligroso en producción que un error de sintaxis?


--================================================================================
-- SECCIÓN 3: ESTADÍSTICAS EXTENDIDAS (COLUMNAS CORRELACIONADAS)
--================================================================================
-- TEORÍA:
-- El optimizador asume independencia entre columnas por defecto. Si dos
-- columnas están correlacionadas (p.ej. país y moneda), multiplica sus
-- selectividades y subestima drásticamente la cardinalidad real de filtrar por
-- ambas. Las estadísticas extendidas (column group) le enseñan al optimizador
-- la correlación real.

-- SETUP: país y moneda están correlacionados a propósito (CO->COP, US->USD...)
CREATE TABLE lab_correlacion (
    id      NUMBER PRIMARY KEY,
    pais    VARCHAR2(2),
    moneda  VARCHAR2(3)
);

INSERT INTO lab_correlacion
SELECT LEVEL,
       CASE MOD(LEVEL, 4) WHEN 0 THEN 'CO' WHEN 1 THEN 'US'
                           WHEN 2 THEN 'MX' ELSE 'BR' END,
       CASE MOD(LEVEL, 4) WHEN 0 THEN 'COP' WHEN 1 THEN 'USD'
                           WHEN 2 THEN 'MXN' ELSE 'BRL' END
FROM DUAL CONNECT BY LEVEL <= 400000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_CORRELACION');

-- EJERCICIO
-- (a) Cardinalidad estimada ANTES de estadísticas extendidas (subestimada):
EXPLAIN PLAN FOR
SELECT * FROM lab_correlacion WHERE pais = 'CO' AND moneda = 'COP';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- (b) Crear el grupo de columnas y regenerar estadísticas:
SELECT DBMS_STATS.CREATE_EXTENDED_STATS(USER, 'LAB_CORRELACION', '(pais, moneda)')
FROM DUAL;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_CORRELACION', METHOD_OPT => 'FOR ALL COLUMNS SIZE AUTO');

-- (c) Cardinalidad estimada DESPUÉS (debería acercarse a la real ~100000 filas):
EXPLAIN PLAN FOR
SELECT * FROM lab_correlacion WHERE pais = 'CO' AND moneda = 'COP';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Compara la columna "Rows" estimada en (a) vs (c) contra el conteo real
--    (SELECT COUNT(*) ... WHERE pais='CO' AND moneda='COP'). ¿Qué tan lejos
--    estaba la estimación original?
-- 2) ¿Por qué una mala cardinalidad aquí podría hacer que el optimizador elija
--    NESTED LOOPS cuando debería usar HASH JOIN en una consulta más grande?


--================================================================================
-- SECCIÓN 4: BIND PEEKING / CURSOR_SHARING
--================================================================================
-- TEORÍA:
-- La primera vez que se ejecuta un cursor con bind variables, Oracle "espía"
-- (peek) el valor real del bind para decidir el plan, y luego REUTILIZA ese
-- plan para ejecuciones futuras con el MISMO texto SQL, incluso con binds muy
-- distintos en selectividad. Esto puede generar cursores hijos (child cursors)
-- con planes diferentes para la misma sentencia, visibles en V$SQL_SHARED_CURSOR.

-- SETUP: distribución muy sesgada (skewed): 'D0' es 90% de las filas
CREATE TABLE lab_bindpeek (
    id     NUMBER PRIMARY KEY,
    depto  VARCHAR2(5)
);

INSERT INTO lab_bindpeek
SELECT LEVEL, CASE WHEN MOD(LEVEL, 10) = 0 THEN 'D1' ELSE 'D0' END
FROM DUAL CONNECT BY LEVEL <= 500000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_BINDPEEK', METHOD_OPT => 'FOR ALL COLUMNS SIZE 254');
CREATE INDEX ix_bindpeek_depto ON lab_bindpeek (depto);

-- EJERCICIO
-- (a) Primera ejecución con el valor SELECTIVO ('D1', 10% de filas) —
--     el optimizador "espía" este bind y probablemente elige RANGE SCAN:
VARIABLE b_depto VARCHAR2(5)
EXEC :b_depto := 'D1'
SELECT /*+ bindpeek_demo */ COUNT(*) FROM lab_bindpeek WHERE depto = :b_depto;

-- (b) Segunda ejecución, MISMO texto SQL, ahora con el valor NO selectivo
--     ('D0', 90% de filas) — el cursor puede reutilizar el plan de (a):
EXEC :b_depto := 'D0'
SELECT /*+ bindpeek_demo */ COUNT(*) FROM lab_bindpeek WHERE depto = :b_depto;

-- (c) Inspeccionar si Oracle generó cursores hijos distintos y por qué:
SELECT sql_id, child_number, is_bind_sensitive, is_bind_aware, is_shareable
FROM v$sql
WHERE sql_text LIKE '%bindpeek_demo%';

SELECT sql_id, child_number, reason
FROM v$sql_shared_cursor
WHERE sql_id IN (SELECT sql_id FROM v$sql WHERE sql_text LIKE '%bindpeek_demo%');

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Qué significa IS_BIND_SENSITIVE = 'Y' y qué diferencia hay con
--    IS_BIND_AWARE = 'Y'?
-- 2) ¿Cómo cambiaría este comportamiento CURSOR_SHARING=FORCE en vez de EXACT?
--    (Nota: solo para discusión, no lo cambies en el laboratorio compartido).


--================================================================================
-- SECCIÓN 5: BITMAP JOIN INDEX + STAR TRANSFORMATION
--================================================================================
-- TEORÍA:
-- Un Bitmap Join Index se crea sobre una tabla de hechos, pero indexando una
-- columna de OTRA tabla (dimensión) a través del join. Permite que un filtro
-- sobre la dimensión ("región = 'Andina'") se resuelva como un bitmap sin
-- tocar la tabla de hechos directamente. La Star Transformation combina varios
-- BJI con AND/OR de bitmaps y luego hace un "join-back" a la tabla de hechos
-- solo por las filas que sobrevivieron.

-- SETUP (modelo estrella simplificado)
CREATE TABLE lab_dim_region (
    id_region  NUMBER PRIMARY KEY,
    region     VARCHAR2(20)
);
INSERT INTO lab_dim_region VALUES (1, 'Andina');
INSERT INTO lab_dim_region VALUES (2, 'Caribe');
INSERT INTO lab_dim_region VALUES (3, 'Pacifico');

CREATE TABLE lab_hechos_venta (
    id_venta   NUMBER PRIMARY KEY,
    id_region  NUMBER REFERENCES lab_dim_region(id_region),
    monto      NUMBER
);

INSERT INTO lab_hechos_venta
SELECT LEVEL, MOD(LEVEL, 3) + 1, ROUND(DBMS_RANDOM.VALUE(1000, 500000), 2)
FROM DUAL CONNECT BY LEVEL <= 1000000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_DIM_REGION');
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_HECHOS_VENTA');

CREATE BITMAP INDEX ix_bji_region
    ON lab_hechos_venta (d.region)
    FROM lab_hechos_venta f, lab_dim_region d
    WHERE f.id_region = d.id_region;

-- EJERCICIO
EXPLAIN PLAN FOR
SELECT /*+ STAR_TRANSFORMATION */ SUM(f.monto)
FROM lab_hechos_venta f, lab_dim_region d
WHERE f.id_region = d.id_region
  AND d.region = 'Andina';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca en el plan las operaciones BITMAP INDEX SINGLE VALUE y
--    BITMAP CONVERSION TO ROWIDS. ¿En qué paso ocurre el "join-back" hacia
--    lab_hechos_venta?
-- 2) ¿Por qué un Bitmap Join Index NO es recomendable en una tabla de hechos
--    con alta concurrencia de escritura (OLTP)?


--================================================================================
-- SECCIÓN 6: PLANES ADAPTATIVOS (ADAPTIVE QUERY OPTIMIZATION, 12c+)
--================================================================================
-- ** Requiere Oracle 12c+ **
-- TEORÍA:
-- Desde 12c, el optimizador puede insertar un "punto de decisión" en el plan:
-- arranca con NESTED LOOPS pero, si durante la ejecución detecta que el número
-- real de filas del lado izquierdo supera un umbral, cambia dinámicamente a
-- HASH JOIN en la MISMA ejecución (no en la siguiente). Esto se llama
-- "Adaptive Plan" y solo es visible completo con DBMS_XPLAN.DISPLAY_CURSOR
-- usando el formato 'adaptive'.

-- SETUP
CREATE TABLE lab_adapt_a (id NUMBER PRIMARY KEY, valor VARCHAR2(20));
CREATE TABLE lab_adapt_b (id NUMBER PRIMARY KEY, id_a NUMBER, dato VARCHAR2(20));

INSERT INTO lab_adapt_a SELECT LEVEL, 'A' || LEVEL FROM DUAL CONNECT BY LEVEL <= 500;
INSERT INTO lab_adapt_b
SELECT LEVEL, MOD(LEVEL, 500) + 1, 'B' || LEVEL
FROM DUAL CONNECT BY LEVEL <= 300000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_ADAPT_A');
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_ADAPT_B');

-- EJERCICIO
-- (a) Ejecutar (no solo EXPLAIN PLAN: el plan adaptativo se decide en runtime)
SELECT a.valor, COUNT(*) FROM lab_adapt_a a JOIN lab_adapt_b b ON a.id = b.id_a
GROUP BY a.valor;

-- (b) Ver el plan REAL ejecutado, incluyendo si hubo adaptación:
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ADAPTIVE'));

-- PREGUNTAS DE DISCUSIÓN
-- 1) En la salida de (b), busca la sección "This is an adaptive plan". ¿Qué
--    operación quedó marcada como "- " (descartada) y cuál se usó realmente?
-- 2) ¿Por qué el parámetro OPTIMIZER_ADAPTIVE_PLANS podría desactivarse en
--    ambientes donde se requiere que el plan sea 100% predecible?


--================================================================================
-- SECCIÓN 7: CARDINALITY FEEDBACK
--================================================================================
-- TEORÍA:
-- Si el optimizador detecta, al FINAL de una ejecución, que su estimación de
-- cardinalidad estuvo muy lejos de la real, puede marcar el cursor para que la
-- SIGUIENTE ejecución (del mismo SQL, no la misma) use un plan reoptimizado
-- con la cardinalidad real observada, sin que cambie ni una letra del SQL ni
-- de las estadísticas de la tabla.

-- SETUP: función que el optimizador no puede estimar bien de entrada
CREATE TABLE lab_cardfeed (id NUMBER PRIMARY KEY, texto VARCHAR2(200));
INSERT INTO lab_cardfeed
SELECT LEVEL, RPAD('x', 190, 'x') || MOD(LEVEL, 7)
FROM DUAL CONNECT BY LEVEL <= 400000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_CARDFEED');

-- EJERCICIO
-- (a) Primera ejecución: el optimizador estima mal la selectividad de un
--     predicado con función sobre columna (no puede usar histograma normal):
SELECT /*+ cardfeed_demo */ COUNT(*) FROM lab_cardfeed WHERE SUBSTR(texto, -1) = '0';

-- (b) Ver si el cursor quedó marcado para reoptimización:
SELECT sql_id, child_number, is_reoptimizable
FROM v$sql WHERE sql_text LIKE '%cardfeed_demo%';

-- (c) Segunda ejecución del MISMO SQL: revisar si generó un nuevo child cursor
--     con nota "cardinality feedback" en la explicación:
SELECT /*+ cardfeed_demo */ COUNT(*) FROM lab_cardfeed WHERE SUBSTR(texto, -1) = '0';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Qué diferencia hay entre Cardinality Feedback y un Plan Adaptativo
--    (Sección 6)? ¿Cuál actúa DURANTE una ejecución y cuál ENTRE ejecuciones?
-- 2) ¿Por qué este mecanismo "se olvida" si se hace FLUSH del cursor o si el
--    SQL se reformatea con espacios distintos?


--================================================================================
-- SECCIÓN 8: ÍNDICES GLOBAL VS LOCAL EN TABLAS PARTICIONADAS
--================================================================================
-- TEORÍA:
-- Un índice LOCAL tiene una partición de índice por cada partición de la
-- tabla: operaciones DDL de partición (DROP, TRUNCATE, EXCHANGE) solo afectan
-- esa porción del índice. Un índice GLOBAL es una única estructura sobre TODA
-- la tabla: un DROP PARTITION en la tabla inutiliza (UNUSABLE) el índice
-- GLOBAL COMPLETO, no solo la parte correspondiente.

-- SETUP
CREATE TABLE lab_particiones (
    id     NUMBER,
    fecha  DATE,
    monto  NUMBER
)
PARTITION BY RANGE (fecha) (
    PARTITION p_2024 VALUES LESS THAN (DATE '2025-01-01'),
    PARTITION p_2025 VALUES LESS THAN (DATE '2026-01-01'),
    PARTITION p_2026 VALUES LESS THAN (DATE '2027-01-01')
);

INSERT INTO lab_particiones
SELECT LEVEL, DATE '2024-01-01' + MOD(LEVEL, 900), MOD(LEVEL, 1000)
FROM DUAL CONNECT BY LEVEL <= 300000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_PARTICIONES');

CREATE INDEX ix_part_local  ON lab_particiones (id) LOCAL;
CREATE INDEX ix_part_global ON lab_particiones (monto);   -- GLOBAL por defecto

-- EJERCICIO
-- (a) Estado inicial de ambos índices:
SELECT index_name, status FROM user_indexes WHERE index_name IN ('IX_PART_GLOBAL');
SELECT index_name, partition_name, status FROM user_ind_partitions WHERE index_name = 'IX_PART_LOCAL';

-- (b) Eliminar una partición de la tabla:
ALTER TABLE lab_particiones DROP PARTITION p_2024;

-- (c) Revisar el impacto: el LOCAL solo pierde su partición correspondiente,
--     el GLOBAL completo debería quedar UNUSABLE:
SELECT index_name, status FROM user_indexes WHERE index_name IN ('IX_PART_GLOBAL');
SELECT index_name, partition_name, status FROM user_ind_partitions WHERE index_name = 'IX_PART_LOCAL';

-- (d) Cualquier consulta que dependa del índice global fallará o hará full
--     scan hasta reconstruirlo:
ALTER INDEX ix_part_global REBUILD;

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Por qué UPDATE GLOBAL INDEXES en el DROP PARTITION habría evitado el
--    problema, y qué costo tiene hacerlo en el momento del DDL?
-- 2) En un ambiente con purga mensual de particiones antiguas, ¿qué estrategia
--    de indexación (solo LOCAL, GLOBAL PARTITIONED, o mixta) recomendarías?


--================================================================================
-- SECCIÓN 9: SQL PLAN BASELINES (SPM)
--================================================================================
-- TEORÍA:
-- Un SQL Plan Baseline "congela" uno o más planes aceptados para un SQL
-- específico. Si el optimizador, tras un cambio de estadísticas o de versión,
-- encuentra un plan nuevo, NO lo usará automáticamente: lo guarda como
-- "no aceptado" y sigue usando el baseline hasta que un DBA lo evalúe y
-- apruebe (evolve). Es la defensa principal contra regresiones de plan.

-- SETUP
CREATE TABLE lab_baseline (id NUMBER PRIMARY KEY, categoria VARCHAR2(10));
INSERT INTO lab_baseline
SELECT LEVEL, CASE WHEN MOD(LEVEL, 100) = 0 THEN 'RARA' ELSE 'COMUN' END
FROM DUAL CONNECT BY LEVEL <= 300000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_BASELINE');
CREATE INDEX ix_baseline_cat ON lab_baseline (categoria);

-- EJERCICIO
-- (a) Ejecutar y capturar el plan actual como baseline:
SELECT /*+ baseline_demo */ COUNT(*) FROM lab_baseline WHERE categoria = 'RARA';

SELECT DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(
         sql_id => (SELECT sql_id FROM v$sql WHERE sql_text LIKE '%baseline_demo%' AND ROWNUM = 1))
FROM DUAL;

-- (b) Forzar que las estadísticas "mientan" (simulando drift real):
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_BASELINE', NO_INVALIDATE => FALSE, FORCE => TRUE)

-- (c) Ver los baselines capturados y su estado de aceptación:
SELECT sql_handle, plan_name, enabled, accepted, fixed
FROM dba_sql_plan_baselines
WHERE sql_text LIKE '%baseline_demo%';

-- PREGUNTAS DE DISCUSIÓN
-- 1) Si el optimizador genera un plan nuevo "mejor" pero no aceptado, ¿cómo se
--    evoluciona ese baseline con DBMS_SPM.EVOLVE_SQL_PLAN_BASELINE?
-- 2) ¿Qué diferencia hay entre un SQL Plan Baseline y un SQL Profile
--    (Sección 11)? ¿Cuál "fija" un plan y cuál "corrige" estimaciones?


--================================================================================
-- SECCIÓN 10: INDEXACIÓN AUTOMÁTICA (DBMS_AUTO_INDEX, 19c+)
--================================================================================
-- ** Requiere Oracle 19c+ y licencia Tuning Pack **
-- TEORÍA:
-- Con AUTO_INDEX_MODE activado, Oracle monitorea cargas de trabajo reales,
-- identifica columnas candidatas a indexación, crea índices INVISIBLES con
-- prefijo SYS_AI_ y los valida automáticamente comparando el desempeño real
-- antes/después. Solo los hace visibles si mejoran el rendimiento; si no,
-- los deja o los elimina sin intervención manual.

-- SETUP
CREATE TABLE lab_autoindex (id NUMBER PRIMARY KEY, cliente_id NUMBER, estado VARCHAR2(10));
INSERT INTO lab_autoindex
SELECT LEVEL, MOD(LEVEL, 5000), CASE WHEN MOD(LEVEL, 37) = 0 THEN 'MOROSO' ELSE 'AL_DIA' END
FROM DUAL CONNECT BY LEVEL <= 500000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_AUTOINDEX');

-- EJERCICIO
-- (a) Activar el modo de indexación automática (requiere privilegios DBA):
CALL DBMS_AUTO_INDEX.CONFIGURE('AUTO_INDEX_MODE', 'IMPLEMENT');
CALL DBMS_AUTO_INDEX.CONFIGURE('AUTO_INDEX_SPACE_BUDGET', '50');

-- (b) Generar carga repetitiva del mismo patrón de filtro para que el
--     mecanismo lo detecte (en un lab real esto se corre muchas veces o se
--     espera a la ventana de mantenimiento automática):
SELECT COUNT(*) FROM lab_autoindex WHERE cliente_id = 1234 AND estado = 'MOROSO';

-- (c) Revisar candidatos e índices generados automáticamente:
SELECT index_name, auto, visibility, status
FROM user_indexes
WHERE index_name LIKE 'SYS_AI%';

SELECT * FROM dba_auto_index_config;

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Por qué los índices SYS_AI_... se crean primero INVISIBLES y qué
--    mecanismo decide si pasan a VISIBLE?
-- 2) ¿Qué riesgo operativo tiene delegar la creación de índices en producción
--    a un proceso automático sin revisión de un DBA?


--================================================================================
-- SECCIÓN 11: SQL TUNING ADVISOR PROGRAMÁTICO (DBMS_SQLTUNE)
--================================================================================
-- ** Requiere licencia Tuning Pack **
-- TEORÍA:
-- El SQL Tuning Advisor puede invocarse por línea de comandos (sin Cloud
-- Control) para analizar un SQL problemático, generando recomendaciones que
-- pueden incluir: crear un índice, aceptar un SQL Profile (ajuste de
-- estimaciones sin tocar el SQL), o reescribir la sentencia.

-- SETUP: reutilizamos lab_cardfeed de la Sección 7 (predicado difícil de estimar)

-- EJERCICIO
-- (a) Crear una tarea de tuning sobre el SQL problemático:
SELECT DBMS_SQLTUNE.CREATE_TUNING_TASK(
         sql_text    => 'SELECT COUNT(*) FROM lab_cardfeed WHERE SUBSTR(texto, -1) = ''0''',
         task_name   => 'lab_tuning_task_01')
FROM DUAL;

-- (b) Ejecutar la tarea:
CALL DBMS_SQLTUNE.EXECUTE_TUNING_TASK('lab_tuning_task_01');

-- (c) Obtener el reporte de recomendaciones:
SELECT DBMS_SQLTUNE.REPORT_TUNING_TASK('lab_tuning_task_01') AS recomendacion
FROM DUAL;

-- (d) Si la recomendación es un SQL Profile, aceptarlo:
CALL DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(task_name => 'lab_tuning_task_01', task_owner => USER, replace => TRUE)

-- PREGUNTAS DE DISCUSIÓN
-- 1) En el reporte, ¿la recomendación fue un índice nuevo, un SQL Profile, o
--    una reescritura? ¿Cómo cambia tu respuesta si la tabla ya tiene el
--    índice "ideal" pero las estadísticas siguen siendo engañosas?
-- 2) ¿Por qué aceptar un SQL Profile es menos invasivo que forzar un HINT
--    directamente en el código de la aplicación?


--================================================================================
-- SECCIÓN 12: OR EXPANSION (TRANSFORMACIÓN INTERNA VW_ORE_...)
--================================================================================
-- TEORÍA:
-- Ante un WHERE a = :x OR b = :y, donde a y b tienen índices DISTINTOS, el
-- optimizador puede reescribir internamente la consulta como un UNION ALL de
-- dos ramas (una por cada índice), eliminando duplicados si aplica. Esta
-- transformación es invisible en el SQL original: solo se ve en el plan como
-- vistas internas con nombres VW_ORE_...

-- SETUP
CREATE TABLE lab_orexp (id NUMBER PRIMARY KEY, cod_a VARCHAR2(10), cod_b VARCHAR2(10));
INSERT INTO lab_orexp
SELECT LEVEL, 'A' || MOD(LEVEL, 1000), 'B' || MOD(LEVEL, 1000)
FROM DUAL CONNECT BY LEVEL <= 400000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_OREXP');
CREATE INDEX ix_orexp_a ON lab_orexp (cod_a);
CREATE INDEX ix_orexp_b ON lab_orexp (cod_b);

-- EJERCICIO
EXPLAIN PLAN FOR
SELECT * FROM lab_orexp WHERE cod_a = 'A5' OR cod_b = 'B900';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca en el plan las líneas VW_ORE_... y CONCATENATION. ¿Cuántas ramas
--    de acceso por índice aparecen?
-- 2) ¿Bajo qué condición el optimizador PREFERIRÍA un FULL TABLE SCAN en vez
--    de esta expansión, aunque existan ambos índices?


--================================================================================
-- SECCIÓN 13: TABLE EXPANSION (VW_TE_... CON PARTICIÓN SIN ÍNDICE)
--================================================================================
-- TEORÍA:
-- En una tabla particionada donde el índice LOCAL está UNUSABLE en una sola
-- partición (común cuando se desactiva el índice de la partición "activa" por
-- costo de mantenimiento de carga masiva), el optimizador puede partir la
-- consulta en un UNION ALL interno (Table Expansion): usa el índice en las
-- particiones donde SÍ existe y hace FULL SCAN solo en la partición sin
-- índice, en vez de renunciar al índice para toda la tabla.

-- SETUP
CREATE TABLE lab_texp (
    id     NUMBER,
    fecha  DATE,
    valor  VARCHAR2(20)
)
PARTITION BY RANGE (fecha) (
    PARTITION p_hist  VALUES LESS THAN (DATE '2026-01-01'),
    PARTITION p_activa VALUES LESS THAN (DATE '2027-01-01')
);

INSERT INTO lab_texp
SELECT LEVEL, DATE '2025-01-01' + MOD(LEVEL, 700), 'V' || MOD(LEVEL, 500)
FROM DUAL CONNECT BY LEVEL <= 400000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_TEXP');

CREATE INDEX ix_texp_valor ON lab_texp (valor) LOCAL;

-- Simular que la partición activa tiene el índice deshabilitado (carga masiva
-- reciente sin reconstrucción):
ALTER INDEX ix_texp_valor MODIFY PARTITION p_activa UNUSABLE;

-- EJERCICIO
EXPLAIN PLAN FOR
SELECT /*+ USE_TABLE_SCAN(lab_texp) */ * FROM lab_texp WHERE valor = 'V250';

-- forma real que dispara table expansion (dejar que el optimizador decida):
EXPLAIN PLAN FOR
SELECT * FROM lab_texp WHERE valor = 'V250';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca VW_TE_... en el plan. ¿Qué rama usa INDEX RANGE SCAN y cuál usa
--    TABLE ACCESS FULL (o PARTITION)?
-- 2) ¿En qué escenario de negocio (además de carga masiva reciente) tendría
--    sentido dejar deliberadamente sin índice solo la partición más nueva?


--================================================================================
-- SECCIÓN 14: JOIN FACTORIZATION
--================================================================================
-- TEORÍA:
-- En una consulta con UNION ALL de dos ramas que ambas hacen JOIN contra la
-- MISMA tabla, el optimizador puede "factorizar" ese join: escanear la tabla
-- común UNA sola vez y distribuir el resultado a ambas ramas, en vez de
-- escanearla una vez por rama. Aparece en el plan como VIEW seguido de una
-- operación compartida antes del UNION ALL.

-- SETUP
CREATE TABLE lab_jf_comun (id NUMBER PRIMARY KEY, descripcion VARCHAR2(50));
INSERT INTO lab_jf_comun
SELECT LEVEL, 'DESC_' || LEVEL FROM DUAL CONNECT BY LEVEL <= 100000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_JF_COMUN');

CREATE TABLE lab_jf_rama1 (id NUMBER, id_comun NUMBER, tipo VARCHAR2(10));
CREATE TABLE lab_jf_rama2 (id NUMBER, id_comun NUMBER, tipo VARCHAR2(10));

INSERT INTO lab_jf_rama1 SELECT LEVEL, MOD(LEVEL, 100000), 'TIPO1' FROM DUAL CONNECT BY LEVEL <= 150000;
INSERT INTO lab_jf_rama2 SELECT LEVEL, MOD(LEVEL, 100000), 'TIPO2' FROM DUAL CONNECT BY LEVEL <= 150000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_JF_RAMA1');
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_JF_RAMA2');

-- EJERCICIO
EXPLAIN PLAN FOR
SELECT c.descripcion, r.tipo FROM lab_jf_comun c JOIN lab_jf_rama1 r ON c.id = r.id_comun
UNION ALL
SELECT c.descripcion, r.tipo FROM lab_jf_comun c JOIN lab_jf_rama2 r ON c.id = r.id_comun;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Cuántas veces aparece TABLE ACCESS de lab_jf_comun en el plan? ¿Una o
--    dos? Compara con lo que esperarías de una lectura literal del SQL.
-- 2) ¿Qué característica del UNION ALL (en vez de UNION) hace posible esta
--    optimización?


--================================================================================
-- SECCIÓN 15: CURSOR-DURATION TEMPORARY TABLES
--================================================================================
-- TEORÍA:
-- Cuando una CTE (WITH ...) se referencia MÁS DE UNA VEZ en la misma consulta,
-- Oracle puede materializar su resultado en una tabla temporal invisible que
-- vive solo durante la duración del cursor (no existe en el diccionario de
-- datos como objeto normal). Aparece en el plan como
-- TEMP TABLE TRANSFORMATION / LOAD AS SELECT (CURSOR DURATION MEMORY).

-- SETUP: reutilizamos lab_hechos_venta de la Sección 5

-- EJERCICIO
EXPLAIN PLAN FOR
WITH ventas_agrupadas AS (
    SELECT id_region, SUM(monto) AS total FROM lab_hechos_venta GROUP BY id_region
)
SELECT a.id_region, a.total,
       a.total / (SELECT SUM(total) FROM ventas_agrupadas) AS proporcion
FROM ventas_agrupadas a
WHERE a.total > (SELECT AVG(total) FROM ventas_agrupadas);
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca TEMP TABLE TRANSFORMATION en el plan. ¿Cuántas veces se referencia
--    ventas_agrupadas en el SQL original y cuántas veces se recalcula según
--    el plan?
-- 2) ¿Qué diferencia hay entre esto y usar la hint MATERIALIZE vs INLINE
--    explícitamente en la CTE?


--================================================================================
-- SECCIÓN 16: BLOOM FILTERS EN HASH JOIN PARALELO
--================================================================================
-- ** Requiere ejecución en paralelo (PARALLEL) para ser visible en el plan **
-- TEORÍA:
-- En un hash join paralelo, Oracle puede generar un filtro probabilístico
-- (Bloom filter) sobre las llaves del lado "build" (la tabla más pequeña) y
-- distribuirlo a los procesos paralelos del lado "probe" ANTES de mover los
-- datos por la red interna de PX. Esto descarta filas que con certeza NO
-- van a hacer join, reduciendo el tráfico entre procesos (y en Exadata se
-- empuja hasta el storage). El filtro nunca da falsos negativos, pero sí
-- puede dar falsos positivos raros (una fila pasa el filtro sin realmente
-- hacer join, y se descarta después en el join real).

-- SETUP
CREATE TABLE lab_bloom_chica (id NUMBER PRIMARY KEY, categoria VARCHAR2(10));
INSERT INTO lab_bloom_chica
SELECT LEVEL, 'CAT' || LEVEL FROM DUAL CONNECT BY LEVEL <= 500;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_BLOOM_CHICA');

CREATE TABLE lab_bloom_grande (id NUMBER, id_chica NUMBER, dato VARCHAR2(20));
INSERT INTO lab_bloom_grande
SELECT LEVEL, MOD(LEVEL, 5000) + 1, 'D' || LEVEL   -- solo 10% hará match real
FROM DUAL CONNECT BY LEVEL <= 2000000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_BLOOM_GRANDE');

ALTER TABLE lab_bloom_chica PARALLEL 4;
ALTER TABLE lab_bloom_grande PARALLEL 4;

-- EJERCICIO
EXPLAIN PLAN FOR
SELECT /*+ PARALLEL(4) */ c.categoria, COUNT(*)
FROM lab_bloom_grande g JOIN lab_bloom_chica c ON g.id_chica = c.id
GROUP BY c.categoria;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(FORMAT => 'ALL'));

-- volver las tablas a modo serial tras el ejercicio
ALTER TABLE lab_bloom_chica NOPARALLEL;
ALTER TABLE lab_bloom_grande NOPARALLEL;

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca JOIN FILTER CREATE y JOIN FILTER USE en el plan. ¿Sobre qué tabla
--    se CREA el filtro y sobre cuál se USA?
-- 2) ¿Por qué el Bloom filter ayuda más cuando el join es muy selectivo
--    (como en este caso, solo 10% de match) que cuando casi todas las filas
--    hacen match?


--================================================================================
-- SECCIÓN 17: INDEX SKIP SCANS
--================================================================================
-- TEORÍA:
-- Un Index Skip Scan ocurre cuando la consulta NO filtra por la columna LÍDER
-- de un índice compuesto, pero el optimizador igual puede usarlo: divide
-- lógicamente el índice en subíndices, uno por cada valor distinto de la
-- columna líder (funciona mejor cuando esa columna tiene POCOS valores
-- distintos), y "salta" (skip) los subíndices que no aplican. Es
-- contraintuitivo porque contradice la regla general de "la columna líder
-- del índice compuesto debe estar en el WHERE para que sirva".

-- SETUP: cust_gender (2 valores) como columna líder, cust_email (miles de
-- valores) como columna secundaria — igual al ejemplo de la guía de Oracle
CREATE TABLE lab_skipscan (
    id           NUMBER PRIMARY KEY,
    cust_gender  CHAR(1),
    cust_email   VARCHAR2(60)
);

INSERT INTO lab_skipscan
SELECT LEVEL,
       CASE WHEN MOD(LEVEL, 2) = 0 THEN 'F' ELSE 'M' END,
       LOWER(DBMS_RANDOM.STRING('L', 10)) || LEVEL || '@empresa.com'
FROM DUAL CONNECT BY LEVEL <= 300000;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_SKIPSCAN');

CREATE INDEX ix_skipscan_gender_email ON lab_skipscan (cust_gender, cust_email);

-- EJERCICIO
-- La consulta NO menciona cust_gender en el WHERE, pero el índice compuesto
-- puede seguir siendo más barato que un FULL TABLE SCAN de 300000 filas:
EXPLAIN PLAN FOR
SELECT * FROM lab_skipscan WHERE cust_email = 'nombreinexistente1@empresa.com';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) Busca INDEX SKIP SCAN en el plan. ¿Cuántos "subíndices lógicos" tendría
--    que recorrer el optimizador como máximo, dado que cust_gender solo
--    tiene 2 valores distintos?
-- 2) Si cust_gender tuviera 500 valores distintos en vez de 2, ¿seguiría
--    siendo rentable el skip scan frente a un FULL TABLE SCAN? ¿Por qué el
--    número de valores distintos de la columna líder es el factor decisivo?


--================================================================================
-- SECCIÓN 18: NOT IN VS NOT EXISTS CON NULLs
--================================================================================
-- TEORÍA:
-- IN y EXISTS son equivalentes funcionalmente. NOT IN y NOT EXISTS NO LO SON
-- cuando hay NULLs de por medio. Internamente, "x NOT IN (a, b, c)" se evalúa
-- como "x != a AND x != b AND x != c". Si CUALQUIERA de los valores de la
-- lista (o subconsulta) es NULL, esa comparación "!= NULL" nunca es ni
-- verdadera ni falsa (es UNKNOWN), lo que vuelve FALSO todo el AND, y el
-- NOT IN termina devolviendo CERO FILAS para TODA la consulta, aunque haya
-- coincidencias reales. Este NO es un problema de rendimiento: es un bug
-- silencioso de resultados incorrectos, uno de los errores más comunes y
-- menos detectados en SQL de producción.

-- SETUP
CREATE TABLE lab_notin_dept (id_depto NUMBER PRIMARY KEY, nombre VARCHAR2(30));
CREATE TABLE lab_notin_emp (id_emp NUMBER PRIMARY KEY, id_depto NUMBER);  -- id_depto NULLABLE

INSERT INTO lab_notin_dept VALUES (10, 'Ventas');
INSERT INTO lab_notin_dept VALUES (20, 'IT');
INSERT INTO lab_notin_dept VALUES (30, 'RRHH');  -- este depto no tiene empleados

INSERT INTO lab_notin_emp VALUES (1, 10);
INSERT INTO lab_notin_emp VALUES (2, 20);
INSERT INTO lab_notin_emp VALUES (3, NULL);  -- un solo empleado sin depto asignado

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_NOTIN_DEPT');
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_NOTIN_EMP');

-- EJERCICIO
-- (a) NOT IN: se espera que devuelva el depto 'RRHH' (sin empleados), pero
--     el NULL en lab_notin_emp.id_depto hace que devuelva CERO filas:
SELECT id_depto, nombre FROM lab_notin_dept
WHERE id_depto NOT IN (SELECT id_depto FROM lab_notin_emp);

-- (b) NOT EXISTS: ignora los NULLs de la subconsulta y da el resultado
--     correcto:
SELECT id_depto, nombre FROM lab_notin_dept d
WHERE NOT EXISTS (SELECT 1 FROM lab_notin_emp e WHERE e.id_depto = d.id_depto);

-- (c) Formas de "arreglar" el NOT IN si se insiste en usarlo:
SELECT id_depto, nombre FROM lab_notin_dept
WHERE id_depto NOT IN (SELECT id_depto FROM lab_notin_emp WHERE id_depto IS NOT NULL);

-- (d) Ver el plan de (a): busca la operación ANTI o ANTI NA/SNA
EXPLAIN PLAN FOR
SELECT id_depto, nombre FROM lab_notin_dept
WHERE id_depto NOT IN (SELECT id_depto FROM lab_notin_emp);
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Por qué NOT EXISTS nunca sufre este problema, sin importar cuántos
--    NULLs existan en la tabla referenciada en la subconsulta?
-- 2) Antes de Oracle 11g, el optimizador ni siquiera podía usar un antijoin
--    (índice) cuando existían NULLs posibles. ¿Qué operación ANTI NA / ANTI
--    SNA ves en el plan de (d), y qué gana el optimizador al usarla en vez
--    de simplemente forzar un FULL TABLE SCAN con verificación fila a fila?


--================================================================================
-- SECCIÓN 19: SQL PLAN DIRECTIVES
--================================================================================
-- TEORÍA:
-- Un SQL Plan Directive es una "nota para sí mismo" que el optimizador
-- guarda de forma PERSISTENTE (en SYSAUX, vía DBMS_SPD) cuando detecta que
-- está subestimando la cardinalidad de cierto tipo de predicado (típicamente
-- un join con columnas correlacionadas o sesgadas). A diferencia del
-- Cardinality Feedback de la Sección 7 (que se asocia a UN cursor y se
-- pierde si se hace FLUSH del shared pool), el directive sobrevive el flush,
-- se aplica a NIVEL DE EXPRESIÓN de consulta (no de statement), y por lo
-- tanto puede activar dynamic sampling incluso en SQL de texto DISTINTO que
-- toque las mismas columnas.

-- SETUP: reutilizamos el join sesgado de lab_correlacion (Sección 3), pero
-- ahora unido a otra tabla para forzar un join con estimación difícil
CREATE TABLE lab_directiva_hechos (id NUMBER PRIMARY KEY, pais VARCHAR2(2), monto NUMBER);
INSERT INTO lab_directiva_hechos
SELECT LEVEL,
       CASE MOD(LEVEL, 4) WHEN 0 THEN 'CO' WHEN 1 THEN 'US' WHEN 2 THEN 'MX' ELSE 'BR' END,
       ROUND(DBMS_RANDOM.VALUE(10, 5000), 2)
FROM DUAL CONNECT BY LEVEL <= 400000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_DIRECTIVA_HECHOS');

-- EJERCICIO
-- (a) Requiere OPTIMIZER_ADAPTIVE_STATISTICS = TRUE (por defecto es FALSE en
--     21c; activar solo a nivel de sesión para no afectar a otros):
ALTER SESSION SET OPTIMIZER_ADAPTIVE_STATISTICS = TRUE;

-- (b) Ejecutar un join que combine el filtro sesgado de país con la
--     correlación de la Sección 3 (fuerza al optimizador a "notar" el error):
SELECT c.moneda, SUM(h.monto)
FROM lab_directiva_hechos h JOIN lab_correlacion c ON h.pais = c.pais
WHERE c.pais = 'CO' AND c.moneda = 'COP'
GROUP BY c.moneda;

-- (c) Ver si se creó un directive persistente:
SELECT directive_id, type, state, reason
FROM dba_sql_plan_directives
WHERE reason LIKE '%SINGLE TABLE%' OR reason LIKE '%JOIN%'
ORDER BY directive_id DESC
FETCH FIRST 5 ROWS ONLY;

-- (d) Simular el "olvido" del cardinality feedback normal (flush) y
--     comprobar que el DIRECTIVE, a diferencia del feedback de la Sección 7,
--     sigue existiendo después:
ALTER SYSTEM FLUSH SHARED_POOL;

SELECT directive_id, type, state, reason
FROM dba_sql_plan_directives
WHERE reason LIKE '%SINGLE TABLE%' OR reason LIKE '%JOIN%'
ORDER BY directive_id DESC
FETCH FIRST 5 ROWS ONLY;

-- volver el parámetro a su valor por defecto
ALTER SESSION SET OPTIMIZER_ADAPTIVE_STATISTICS = FALSE;

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Por qué el directive se guarda "a nivel de expresión de consulta" y no
--    a nivel de SQL_ID, y qué gana con eso frente al cardinality feedback?
-- 2) DBMS_SPD permite exportar/importar directives entre bases de datos
--    (p.ej. de PROD a UAT). ¿En qué escenario de migración esto sería
--    valioso, y qué riesgo tiene llevar directives de un ambiente con datos
--    muy distintos?


--================================================================================
-- SECCIÓN 20: REAL-TIME STATISTICS Y MODELOS DE REGRESIÓN NDV (21c)
--================================================================================
-- ** Requiere Oracle 19c+ (real-time statistics) / 21c (modelos de regresión) **
-- TEORÍA:
-- Antes de 19c, las estadísticas solo se actualizaban con un DML masivo
-- (bulk load / direct-path insert) o con un job manual de DBMS_STATS. Un DML
-- CONVENCIONAL (INSERT/UPDATE/DELETE fila a fila) no tocaba las estadísticas
-- hasta el siguiente job. Desde 19c, con OPTIMIZER_REAL_TIME_STATISTICS=TRUE,
-- Oracle calcula en caliente valores esenciales (como el máximo de una
-- columna) durante DML convencional, SIN invalidar los cursores existentes.
-- Desde 21c, además, construye modelos de regresión para predecir el NDV
-- (number of distinct values) de columnas en tablas volátiles. Esto es clave
-- para diagnosticar un plan que "mejora solo" sin que nadie haya corrido
-- DBMS_STATS manualmente.

-- SETUP
CREATE TABLE lab_realtime (id NUMBER PRIMARY KEY, fecha_evento DATE, estado VARCHAR2(10));
INSERT INTO lab_realtime
SELECT LEVEL, SYSDATE - 30 + MOD(LEVEL, 30), 'ABIERTO'
FROM DUAL CONNECT BY LEVEL <= 100000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_REALTIME');

-- EJERCICIO
-- (a) Activar real-time statistics para la sesión:
ALTER SESSION SET OPTIMIZER_REAL_TIME_STATISTICS = TRUE;

-- (b) Plan ANTES de la carga (fecha_evento tope conocido por DBMS_STATS):
EXPLAIN PLAN FOR
SELECT COUNT(*) FROM lab_realtime WHERE fecha_evento > SYSDATE + 5;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- (c) DML CONVENCIONAL (fila a fila, sin APPEND) que desplaza el máximo real
--     de fecha_evento MUCHO más allá de lo que DBMS_STATS registró, sin
--     correr ningún job de estadísticas:
INSERT INTO lab_realtime (id, fecha_evento, estado) VALUES (200001, SYSDATE + 10, 'ABIERTO');
COMMIT;

-- (d) Ejecutar de nuevo: real-time statistics debería ayudar al optimizador
--     a notar el nuevo máximo sin invalidar cursores existentes. Comparar
--     el "Note" al final del plan:
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));

SELECT COUNT(*) FROM lab_realtime WHERE fecha_evento > SYSDATE + 5;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));

-- volver el parámetro a su valor por defecto
ALTER SESSION SET OPTIMIZER_REAL_TIME_STATISTICS = FALSE;

-- PREGUNTAS DE DISCUSIÓN
-- 1) ¿Por qué real-time statistics AUMENTA la información disponible en vez
--    de REEMPLAZAR el trabajo de DBMS_STATS? ¿Qué implica esto para la
--    política de jobs automáticos de estadísticas de tu equipo?
-- 2) En una tabla con altísima concurrencia de escritura (miles de inserts
--    por segundo), ¿qué costo adicional podría tener mantener estadísticas
--    "en vivo" durante cada DML?


--================================================================================
-- SECCIÓN 21: HINT USAGE REPORTS (HINTS IGNORADOS SILENCIOSAMENTE)
--================================================================================
-- TEORÍA:
-- Un hint mal escrito, con un nombre de índice equivocado, en conflicto con
-- otro hint, o invalidado por una transformación de consulta, es IGNORADO
-- por el optimizador SIN generar ningún error ni warning. El desarrollador
-- cree que está forzando un plan, pero el hint nunca se aplicó. Desde
-- Oracle 19c, DBMS_XPLAN.DISPLAY(format => 'ALL') incluye una sección
-- "Hint Report" que indica, hint por hint, si fue usado o no y por qué.

-- SETUP
CREATE TABLE lab_hints (id NUMBER PRIMARY KEY, estado VARCHAR2(10));
INSERT INTO lab_hints
SELECT LEVEL, CASE WHEN MOD(LEVEL, 20) = 0 THEN 'CERRADO' ELSE 'ABIERTO' END
FROM DUAL CONNECT BY LEVEL <= 200000;
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'LAB_HINTS');
CREATE INDEX ix_hints_estado ON lab_hints (estado);

-- EJERCICIO
-- (a) Hint con el NOMBRE DE ÍNDICE MAL ESCRITO (typo deliberado):
EXPLAIN PLAN FOR
SELECT /*+ INDEX(lab_hints ix_hints_estad) */ COUNT(*)
FROM lab_hints WHERE estado = 'CERRADO';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'ALL'));

-- (b) Mismo hint, nombre de índice correcto:
EXPLAIN PLAN FOR
SELECT /*+ INDEX(lab_hints ix_hints_estado) */ COUNT(*)
FROM lab_hints WHERE estado = 'CERRADO';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'ALL'));

-- PREGUNTAS DE DISCUSIÓN
-- 1) Compara la sección "Hint Report" de (a) y (b). ¿Qué texto aparece junto
--    al hint en (a) indicando que no se usó?
-- 2) En una revisión de código, ¿cómo usarías este reporte para detectar
--    hints "muertos" que quedaron de una versión anterior del esquema
--    (por ejemplo, tras un RENAME o DROP de índice)?


--================================================================================
-- SECCIÓN 22: CASO INTEGRADOR FINAL — BUG "INTERMITENTE" CLÁSICO
--================================================================================
-- ENUNCIADO PARA LOS ESTUDIANTES:
-- Un reporte de fin de mes que normalmente corre en 2 segundos, un día tarda
-- 40 minutos. Al día siguiente vuelve a correr rápido, sin que nadie haya
-- tocado el código ni las tablas. El SQL nunca cambió. Deben usar AL MENOS
-- TRES de los mecanismos vistos en este laboratorio para explicar y
-- diagnosticar un escenario donde coexisten:
--   - Un bind variable cuyo valor de "pico" (peek) el primer día del mes es
--     atípico (poquísimos registros) pero el resto del mes es altísimo
--     (Sección 4).
--   - Una columna con estadísticas obsoletas tras la carga masiva de fin de
--     mes, sin re-analizar antes de la primera ejecución (relacionado a
--     Sección 3 y 7).
--   - Un índice LOCAL en la partición del mes actual que fue marcado
--     UNUSABLE por una carga con NOLOGGING y aún no reconstruido
--     (Sección 8 y 13).
--
-- ENTREGABLE:
-- 1) Reproducir el escenario con SETUP propio (tablas/particiones/datos que
--    generen el problema).
-- 2) Capturar con DBMS_XPLAN.DISPLAY_CURSOR el plan "malo" del día del
--    incidente y el plan "bueno" de un día normal.
-- 3) Explicar, citando V$SQL_SHARED_CURSOR, V$SQL (IS_BIND_SENSITIVE,
--    IS_REOPTIMIZABLE) y USER_IND_PARTITIONS (STATUS), cuál de los tres
--    mecanismos fue la causa raíz y cuáles fueron agravantes.
-- 4) Proponer UNA corrección estructural (no un simple "correr stats a
--    mano") que evite que el problema se repita el próximo mes: por ejemplo,
--    un SQL Plan Baseline (Sección 9), estadísticas extendidas con
--    histograma adecuado (Sección 3), o una política de rebuild de índices
--    post-carga.
--
-- EXTENSIÓN OPCIONAL (para grupos avanzados):
-- Añadir una CUARTA capa al mismo incidente: el reporte de fin de mes
-- también usa un NOT IN contra una subconsulta que, ese día, por primera vez
-- trae un NULL (Sección 18) — de modo que el "resultado vacío" que reportó
-- el usuario no era por lentitud sino por corrección de datos, y el equipo
-- perdió tiempo optimizando un plan cuando el bug real era semántico.
-- Combinar esto con Real-Time Statistics (Sección 20): la carga de fin de
-- mes es DML convencional (no bulk), así que las estadísticas "en vivo" dan
-- una pista de que el máximo real de la columna cambió a media jornada,
-- aunque el job nocturno de DBMS_STATS todavía no haya corrido.


--================================================================================
-- LIMPIEZA (ejecutar al finalizar el laboratorio; comentado a propósito)
--================================================================================
/*
DROP TABLE lab_nulls PURGE;
DROP TABLE lab_conversion PURGE;
DROP TABLE lab_correlacion PURGE;
DROP TABLE lab_bindpeek PURGE;
DROP TABLE lab_hechos_venta PURGE;
DROP TABLE lab_dim_region PURGE;
DROP TABLE lab_adapt_a PURGE;
DROP TABLE lab_adapt_b PURGE;
DROP TABLE lab_cardfeed PURGE;
DROP TABLE lab_particiones PURGE;
DROP TABLE lab_baseline PURGE;
DROP TABLE lab_autoindex PURGE;
DROP TABLE lab_orexp PURGE;
DROP TABLE lab_texp PURGE;
DROP TABLE lab_jf_comun PURGE;
DROP TABLE lab_jf_rama1 PURGE;
DROP TABLE lab_jf_rama2 PURGE;
DROP TABLE lab_bloom_chica PURGE;
DROP TABLE lab_bloom_grande PURGE;
DROP TABLE lab_skipscan PURGE;
DROP TABLE lab_notin_dept PURGE;
DROP TABLE lab_notin_emp PURGE;
DROP TABLE lab_directiva_hechos PURGE;
DROP TABLE lab_realtime PURGE;
DROP TABLE lab_hints PURGE;
*/
