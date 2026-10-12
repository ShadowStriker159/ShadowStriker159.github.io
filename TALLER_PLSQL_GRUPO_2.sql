--------------------------------------------------------------------------------
-- UNIVERSIDAD EL BOSQUE — INGENIERIA DE SISTEMAS
-- Asignatura: Bases de Datos 2
-- Docente: Ing., Esp., M.Ed. Christian Felipe Duarte
--
-- TALLER PL/SQL — PLANTILLA DE ENTREGA
--
-- GRUPO No.: 2
-- INTEGRANTES: 1) Erik Yulliam Bautista Arevalo
--              2) Felipe Lopez Almanza
--              3) Mariana Camila Durán Piñeros
-- FECHA DE ENTREGA:06/10/2026
--------------------------------------------------------------------------------
--
-- COMO TRABAJAR
--   1. Ejecute primero, completo, el script 01_esquema_inventario.sql
--   2. Desarrolle cada punto en la seccion correspondiente de este archivo
--   3. No borre los encabezados de cada ejercicio ni cambie los nombres de los
--      objetos solicitados. La revision los busca por nombre: un objeto correcto
--      con otro nombre se califica como no entregado.
--   4. Los esqueletos de la Parte 5 no incluyen la clausula de disparo. Definirla
--      hace parte del ejercicio, de modo que esos bloques no compilan tal como se
--      entregan.
--
-- DISTRIBUCION DEL PUNTAJE                                     Total: 50 puntos
--   Parte 1  Procedimientos almacenados .................  8 puntos
--   Parte 2  Funciones ...................................  8 puntos
--   Parte 3  Cursores .................................... 10 puntos
--   Parte 4  Manejo de excepciones .......................  9 puntos
--   Parte 5  Disparadores ................................ 10 puntos
--   Parte 6  Caso integrador .............................  5 puntos
--
-- CRITERIOS DE EVALUACION
--   Correccion tecnica ....... 40%   El objeto compila y cumple el enunciado
--   Justificacion ............ 40%   Las decisiones de diseno estan argumentadas
--   Analisis operacional ..... 20%   Se anticipa el comportamiento ante
--                                    concurrencia, volumen y error
--
--   Cada objeto debe incluir su justificacion en el espacio marcado. Un ejercicio
--   sin justificacion obtiene como maximo el 40% de su puntaje aunque funcione.
--   Una justificacion que confunde la causa con el efecto no obtiene puntaje.
--   Describir lo que hace el codigo, sin argumentar por que se eligio esa
--   construccion y no otra, equivale a no justificar.
--
-- ENTREGA
--   Este archivo renombrado como TALLER_PLSQL_GRUPO_<n>.sql, junto con un
--   documento que contenga las salidas de DBMS_OUTPUT de cada bloque ejecutado.
--   Ambos archivos deben incluir los nombres de los tres integrantes.
--
-- SUSTENTACION
--   20 minutos por grupo. Los tres integrantes deben poder explicar cualquier
--   parte del codigo, no solamente la que desarrollaron.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED

------------------------------------------------------------------- PREPARACION
-- Ejecutar UNA vez despues de 01_esquema_inventario.sql (y otra vez si se vuelve
-- a correr el esquema). El esquema solo sincroniza SEQ_PEDIDO y SEQ_MOVIMIENTO;
-- SEQ_CLIENTE empieza en 500 y SEQ_PRODUCTO en 1000, pero los datos ya usan 501-507
-- y 1001-1015. Sin este paso, el caso 2 de 4.4 y las inserciones de 5.1 fallan con
-- ORA-00001 porque la secuencia entrega un id que ya existe. El salto se hace con
-- ALTER SEQUENCE y la secuencia vuelve a INCREMENT BY 1.
-------------------------------------------------------------------------------
DECLARE
    PROCEDURE SP_sincronizar (
        PARAM_secuencia IN VARCHAR2,
        PARAM_tabla     IN VARCHAR2,
        PARAM_columna   IN VARCHAR2
    ) IS
        vnMax     NUMBER;
        vnActual  NUMBER;
        vnSalto   NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT NVL(MAX(' || PARAM_columna || '), 0) FROM ' || PARAM_tabla INTO vnMax;
        EXECUTE IMMEDIATE 'SELECT ' || PARAM_secuencia || '.NEXTVAL FROM DUAL' INTO vnActual;
        vnSalto := vnMax - vnActual;
        IF vnSalto > 0 THEN
            EXECUTE IMMEDIATE 'ALTER SEQUENCE ' || PARAM_secuencia || ' INCREMENT BY ' || vnSalto;
            EXECUTE IMMEDIATE 'SELECT ' || PARAM_secuencia || '.NEXTVAL FROM DUAL' INTO vnActual;
            EXECUTE IMMEDIATE 'ALTER SEQUENCE ' || PARAM_secuencia || ' INCREMENT BY 1';
        END IF;
        DBMS_OUTPUT.PUT_LINE(PARAM_secuencia || ': maximo en la tabla = ' || vnMax ||
                             ', ultimo valor entregado = ' || vnActual);
    END SP_sincronizar;
BEGIN
    SP_sincronizar('SEQ_CLIENTE',  'CLIENTE',  'id_cliente');
    SP_sincronizar('SEQ_PRODUCTO', 'PRODUCTO', 'id_producto');
END;
/


--==============================================================================
-- PARTE 1 — PROCEDIMIENTOS ALMACENADOS                        (8 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 1.1 (2 pts)
-- SP_REGISTRAR_PRODUCTO
-- Registra un producto nuevo. Debe asignar el identificador desde SEQ_PRODUCTO,
-- validar que el precio de venta supere el costo unitario, verificar que la
-- categoria exista y manejar el caso de codigo duplicado. Devuelve el
-- identificador generado.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- * Las validaciones de negocio (precio > costo, categoria existente) se hacen
--   antes de consumir la secuencia y de insertar. Asi un dato invalido no gasta
--   un numero de SEQ_PRODUCTO ni dispara triggers. Se lanzan con
--   RAISE_APPLICATION_ERROR (-20001 y -20002), de modo que el cliente
--   identifica la causa por el codigo del error.
-- * La categoria se verifica con COUNT(*) en lugar de SELECT INTO. COUNT
--   siempre devuelve una fila, asi que no hay NO_DATA_FOUND que atrapar y el
--   flujo queda lineal. La FK tambien la protegeria (ORA-02291), pero el
--   mensaje propio es mas claro para quien llama.
-- * El codigo duplicado no se resuelve con un SELECT previo, porque otra sesion
--   podria insertar el mismo codigo entre el SELECT y el INSERT (condicion de
--   carrera). Solo la restriccion UK_PRODUCTO_CODIGO lo garantiza; el
--   procedimiento atrapa DUP_VAL_ON_INDEX y lo traduce a -20003.
-- * DUP_VAL_ON_INDEX tambien se dispara por colision de la PK. Por eso el
--   manejador revisa que el mensaje nombre UK_PRODUCTO_CODIGO; si es otra
--   restriccion, relanza con RAISE para no informar "codigo duplicado" cuando
--   el problema es otro.
-- * RETURNING ... INTO entrega el id generado en el mismo INSERT, sin un
--   SELECT SEQ.CURRVAL adicional.
-- * Si el INSERT falla, el numero de secuencia consumido no se recupera y
--   quedan huecos, lo cual es normal en una secuencia. El procedimiento no
--   intenta reutilizar ese numero.
CREATE OR REPLACE PROCEDURE SP_REGISTRAR_PRODUCTO (
    PARAM_codigo       IN   VARCHAR2,
    PARAM_nombre       IN   VARCHAR2,
    PARAM_idCategoria  IN   NUMBER,
    PARAM_precio       IN   NUMBER,
    PARAM_costo        IN   NUMBER,
    PARAM_stockMinimo  IN   NUMBER DEFAULT 0,
    PARAM_idProducto   OUT  NUMBER
) IS
    vnExiste                 NUMBER;
    e_precio_invalido        EXCEPTION;
    e_categoria_inexistente  EXCEPTION;
    e_codigo_duplicado       EXCEPTION;
BEGIN
    PARAM_idProducto := NULL;

    IF PARAM_precio IS NULL OR PARAM_costo IS NULL OR PARAM_precio <= PARAM_costo THEN
        RAISE e_precio_invalido;
    END IF;

    SELECT COUNT(*) INTO vnExiste
    FROM   CATEGORIA
    WHERE  id_categoria = PARAM_idCategoria;

    IF vnExiste = 0 THEN
        RAISE e_categoria_inexistente;
    END IF;

    BEGIN
        INSERT INTO PRODUCTO (id_producto, codigo, nombre, id_categoria,
                              precio_unitario, costo_unitario, stock_minimo, activo)
        VALUES (SEQ_PRODUCTO.NEXTVAL, PARAM_codigo, PARAM_nombre, PARAM_idCategoria,
                PARAM_precio, PARAM_costo, NVL(PARAM_stockMinimo, 0), 'S')
        RETURNING id_producto INTO PARAM_idProducto;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            PARAM_idProducto := NULL;
            IF INSTR(UPPER(SQLERRM), 'UK_PRODUCTO_CODIGO') > 0 THEN
                RAISE e_codigo_duplicado;
            ELSE
                RAISE;  -- otra restriccion (por ejemplo la PK): no mentir
            END IF;
    END;
EXCEPTION
    WHEN e_precio_invalido THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: el precio de venta (' || PARAM_precio ||
                             ') debe ser mayor al costo unitario (' || PARAM_costo || ')');
    WHEN e_categoria_inexistente THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: la categoria ' || PARAM_idCategoria || ' no existe');
    WHEN e_codigo_duplicado THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: ya existe un producto con el codigo ' || PARAM_codigo);
END SP_REGISTRAR_PRODUCTO;
/

-- PRUEBA 1.1  (esperado: 1 exito y 3 rechazos con su mensaje)
DECLARE
    vnId NUMBER;
    PROCEDURE SP_registrar (
        PARAM_codigo       IN VARCHAR2,
        PARAM_idCategoria  IN NUMBER,
        PARAM_precio       IN NUMBER,
        PARAM_costo        IN NUMBER
    ) IS
    BEGIN
        SP_REGISTRAR_PRODUCTO(PARAM_codigo, 'Producto de prueba', PARAM_idCategoria, PARAM_precio, PARAM_costo, 10, vnId);
        DBMS_OUTPUT.PUT_LINE('  -> id devuelto: ' || NVL(TO_CHAR(vnId), 'NULL (rechazado)'));
    END SP_registrar;
BEGIN
    SP_registrar('FG-0003', 4, 15000, 10000);  -- OK
    SP_registrar('FG-0004', 4,  9000, 10000);  -- precio menor al costo
    SP_registrar('FG-0005', 99, 15000, 10000); -- categoria inexistente
    SP_registrar('HM-0001', 1, 45000, 28000);  -- codigo duplicado
    ROLLBACK;
END;
/

------------------------------------------------------------------- 1.2 (3 pts)
-- SP_AJUSTAR_STOCK
-- Registra una ENTRADA, SALIDA o AJUSTE de inventario sobre una bodega.
-- Debe actualizar EXISTENCIA e insertar el registro en MOVIMIENTO_INVENTARIO,
-- devolviendo el saldo resultante.
--   * Si la combinacion bodega-producto no existe y el tipo es ENTRADA, crearla
--   * Si el tipo es SALIDA y no existe la combinacion, rechazar la operacion
--   * Una SALIDA nunca puede dejar la existencia en negativo
-- Proteja la lectura de la existencia frente a modificaciones concurrentes.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- * La existencia se lee con SELECT ... FOR UPDATE para evitar actualizaciones
--   perdidas. Sin el bloqueo, dos sesiones leen 10 unidades, ambas restan 8 y
--   ambas creen que quedan 2. Con FOR UPDATE la segunda sesion espera a que la
--   primera termine y lee el valor ya actualizado. No se usa NOWAIT porque la
--   espera es corta, y fallar por simple contencion seria un error espurio.
-- * La validacion de que la existencia no quede negativa se hace sobre el valor
--   leido bajo bloqueo, asi que es confiable. El CHECK ck_existencia_cantidad
--   queda como respaldo, pero daria un ORA-02290 sin contexto. La excepcion
--   propia e_stock_insuficiente imprime producto, bodega, disponible y
--   solicitado.
-- * Al no haber backend, cada regla es una excepcion nombrada que se levanta
--   con RAISE y se atrapa al final del procedimiento, donde se imprime el
--   motivo. Las excepciones se levantan antes de modificar datos, de modo que
--   un rechazo no deja cambios a medias. Quien llama detecta el fallo porque
--   PARAM_saldoFinal queda en NULL.
-- * El AJUSTE funciona como conteo fisico: la existencia queda exactamente en
--   PARAM_cantidad. MOVIMIENTO_INVENTARIO exige cantidad > 0 y no admite deltas
--   negativos, y el dato de ejemplo trae un AJUSTE con la observacion
--   'Conteo fisico'. La diferencia contra el saldo anterior se guarda en la
--   observacion. Limitacion: no se puede registrar un conteo de 0 unidades.
-- * Un AJUSTE sobre una combinacion inexistente la crea, porque un conteo puede
--   descubrir stock no registrado. Una SALIDA sin combinacion se rechaza
--   (e_sin_combinacion), ya que no hay de donde sacar.
-- * La creacion de la fila es vulnerable a una condicion de carrera, porque si
--   la fila no existe no hay nada que bloquear. Se atrapa DUP_VAL_ON_INDEX y
--   se pide reintentar.
-- * Una ENTRADA a una bodega inactiva se rechaza. SALIDA y AJUSTE se permiten
--   para poder vaciarla.
-- * No hay COMMIT interno: el ajuste forma parte de la transaccion de quien
--   llama.
CREATE OR REPLACE PROCEDURE SP_AJUSTAR_STOCK (
    PARAM_idProducto   IN   NUMBER,
    PARAM_idBodega     IN   NUMBER,
    PARAM_tipo         IN   VARCHAR2,
    PARAM_cantidad     IN   NUMBER,
    PARAM_observacion  IN   VARCHAR2 DEFAULT NULL,
    PARAM_saldoFinal   OUT  NUMBER
) IS
    vvTipo    VARCHAR2(10) := UPPER(TRIM(PARAM_tipo));
    vvActiva  BODEGA.activa%TYPE;
    vnActual  EXISTENCIA.cantidad%TYPE;
    vbExiste  BOOLEAN := TRUE;
    vnNuevo   NUMBER;
    vnConteo  NUMBER;
    vvObs     MOVIMIENTO_INVENTARIO.observacion%TYPE;

    e_tipo_invalido         EXCEPTION;
    e_cantidad_invalida     EXCEPTION;
    e_producto_inexistente  EXCEPTION;
    e_bodega_inexistente    EXCEPTION;
    e_bodega_inactiva       EXCEPTION;
    e_sin_combinacion       EXCEPTION;
    e_stock_insuficiente    EXCEPTION;
    e_conflicto_concurrente EXCEPTION;
BEGIN
    PARAM_saldoFinal := NULL;

    IF vvTipo IS NULL OR vvTipo NOT IN ('ENTRADA', 'SALIDA', 'AJUSTE') THEN
        RAISE e_tipo_invalido;
    END IF;

    IF PARAM_cantidad IS NULL OR PARAM_cantidad <= 0 OR PARAM_cantidad <> TRUNC(PARAM_cantidad) THEN
        RAISE e_cantidad_invalida;
    END IF;

    SELECT COUNT(*) INTO vnConteo FROM PRODUCTO WHERE id_producto = PARAM_idProducto;
    IF vnConteo = 0 THEN
        RAISE e_producto_inexistente;
    END IF;

    BEGIN
        SELECT activa INTO vvActiva FROM BODEGA WHERE id_bodega = PARAM_idBodega;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE e_bodega_inexistente;
    END;

    IF vvTipo = 'ENTRADA' AND vvActiva = 'N' THEN
        RAISE e_bodega_inactiva;
    END IF;

    -- Lectura protegida: bloquea la fila de existencia hasta COMMIT/ROLLBACK
    BEGIN
        SELECT cantidad INTO vnActual
        FROM   EXISTENCIA
        WHERE  id_bodega = PARAM_idBodega
        AND    id_producto = PARAM_idProducto
        FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            vbExiste := FALSE;
    END;

    IF NOT vbExiste THEN
        IF vvTipo = 'SALIDA' THEN
            RAISE e_sin_combinacion;
        END IF;
        BEGIN
            INSERT INTO EXISTENCIA (id_bodega, id_producto, cantidad)
            VALUES (PARAM_idBodega, PARAM_idProducto, PARAM_cantidad);
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE e_conflicto_concurrente;
        END;
        vnNuevo := PARAM_cantidad;
    ELSE
        IF vvTipo = 'ENTRADA' THEN
            vnNuevo := vnActual + PARAM_cantidad;
        ELSIF vvTipo = 'SALIDA' THEN
            IF vnActual < PARAM_cantidad THEN
                RAISE e_stock_insuficiente;
            END IF;
            vnNuevo := vnActual - PARAM_cantidad;
        ELSE -- AJUSTE: la existencia queda igual al conteo fisico
            vnNuevo := PARAM_cantidad;
        END IF;

        UPDATE EXISTENCIA
        SET    cantidad = vnNuevo
        WHERE  id_bodega = PARAM_idBodega
        AND    id_producto = PARAM_idProducto;
    END IF;

    vvObs := PARAM_observacion;
    IF vvTipo = 'AJUSTE' THEN
        vvObs := SUBSTR('Conteo fisico: existencia ' || NVL(vnActual, 0) || ' -> ' || vnNuevo ||
                        CASE WHEN PARAM_observacion IS NOT NULL THEN '. ' || PARAM_observacion ELSE '' END, 1, 200);
    END IF;

    INSERT INTO MOVIMIENTO_INVENTARIO (id_movimiento, id_producto, id_bodega, tipo, cantidad, observacion)
    VALUES (SEQ_MOVIMIENTO.NEXTVAL, PARAM_idProducto, PARAM_idBodega, vvTipo, PARAM_cantidad, vvObs);

    PARAM_saldoFinal := vnNuevo;
EXCEPTION
    WHEN e_tipo_invalido THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: tipo de movimiento invalido (' || PARAM_tipo || '). Use ENTRADA, SALIDA o AJUSTE');
    WHEN e_cantidad_invalida THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: la cantidad debe ser un entero mayor que cero');
    WHEN e_producto_inexistente THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: el producto ' || PARAM_idProducto || ' no existe');
    WHEN e_bodega_inexistente THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: la bodega ' || PARAM_idBodega || ' no existe');
    WHEN e_bodega_inactiva THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: la bodega ' || PARAM_idBodega || ' esta inactiva y no puede recibir entradas');
    WHEN e_sin_combinacion THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: no existe el producto ' || PARAM_idProducto || ' en la bodega ' ||
                             PARAM_idBodega || ': no se puede registrar una SALIDA');
    WHEN e_stock_insuficiente THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: stock insuficiente en bodega ' || PARAM_idBodega || ' para el producto ' ||
                             PARAM_idProducto || ': disponible ' || vnActual || ', solicitado ' || PARAM_cantidad);
    WHEN e_conflicto_concurrente THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: otra sesion creo la misma existencia al mismo tiempo; reintente');
END SP_AJUSTAR_STOCK;
/

-- PRUEBA 1.2  (partiendo de 1001 en bodega 1 = 120 unidades)
DECLARE
    vnSaldo NUMBER;
    PROCEDURE SP_ejecutar (
        PARAM_idProducto  IN NUMBER,
        PARAM_idBodega    IN NUMBER,
        PARAM_tipo        IN VARCHAR2,
        PARAM_cantidad    IN NUMBER
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('>> ' || RPAD(PARAM_tipo, 9) || PARAM_cantidad || ' | prod ' || PARAM_idProducto || ' | bod ' || PARAM_idBodega);
        SP_AJUSTAR_STOCK(PARAM_idProducto, PARAM_idBodega, PARAM_tipo, PARAM_cantidad, 'Prueba taller', vnSaldo);
        DBMS_OUTPUT.PUT_LINE('   saldo final: ' || NVL(TO_CHAR(vnSaldo), 'NULL (rechazado)'));
    END SP_ejecutar;
BEGIN
    SP_ejecutar(1001, 1, 'ENTRADA', 10);   -- 130
    SP_ejecutar(1003, 2, 'ENTRADA',  5);   -- crea la combinacion: 5
    SP_ejecutar(1001, 1, 'SALIDA',  30);   -- 100
    SP_ejecutar(1001, 1, 'AJUSTE',  95);   -- conteo: queda en 95
    SP_ejecutar(1011, 4, 'SALIDA',   1);   -- rechazo: combinacion inexistente
    SP_ejecutar(1005, 1, 'SALIDA',  10);   -- rechazo: solo hay 4
    SP_ejecutar(1001, 5, 'ENTRADA',  1);   -- rechazo: bodega inactiva
    SP_ejecutar(1001, 1, 'TRASLADO', 1);   -- rechazo: tipo invalido
    DBMS_OUTPUT.PUT_LINE('--- movimientos generados ---');
    FOR vrMovimiento IN (SELECT id_movimiento, id_producto, id_bodega, tipo, cantidad, observacion
              FROM MOVIMIENTO_INVENTARIO WHERE id_movimiento > 20 ORDER BY id_movimiento) LOOP
        DBMS_OUTPUT.PUT_LINE(vrMovimiento.id_movimiento || ' | ' || vrMovimiento.id_producto || ' | bod ' || vrMovimiento.id_bodega || ' | ' ||
                             RPAD(vrMovimiento.tipo, 8) || ' | ' || vrMovimiento.cantidad || ' | ' || vrMovimiento.observacion);
    END LOOP;
    ROLLBACK;
END;
/

------------------------------------------------------------------- 1.3 (3 pts)
-- SP_CREAR_PEDIDO
-- Crea la cabecera de un pedido en estado BORRADOR y devuelve el identificador
-- generado. Debe rechazar clientes inactivos y clientes sin cupo de credito
-- disponible, con mensajes distinguibles entre si.
-------------------------------------------------------------------------------
-- Justificacion:
-- * Una sola consulta trae activo y (cupo - saldo) del cliente, de modo que
--   ambas validaciones ven el mismo estado. Las validaciones van en este orden:
--   primero existencia, luego cliente inactivo y por ultimo cupo. Un cliente
--   inactivo con cupo agotado reporta "inactivo", que es la causa principal.
--   Cada rechazo es una excepcion nombrada distinta y imprime un mensaje distinto.
-- * Al no haber backend, las excepciones se levantan con RAISE y se atrapan en
--   el EXCEPTION del procedimiento, que imprime el motivo con DBMS_OUTPUT. Quien
--   llama detecta el fallo porque PARAM_idPedido queda en NULL.
-- * El cupo se calcula en linea en lugar de usar FN_CUPO_DISPONIBLE, porque esa
--   funcion se crea en la Parte 2, despues de este procedimiento, y
--   referenciarla aqui lo dejaria INVALIDO al compilar. La regla es la misma.
-- * "Sin cupo" significa disponible <= 0: el cliente 505, con exactamente cero
--   disponible, tampoco puede abrir pedidos.
-- * Esta verificacion es un filtro temprano y no reserva cupo. Entre el
--   borrador y la facturacion el cupo puede cambiar, por eso PKG_VENTAS vuelve
--   a validar con el cliente bloqueado.
-- * El pedido nace con total 0; el total lo mantiene TRG_DETALLE_TOTAL.
CREATE OR REPLACE PROCEDURE SP_CREAR_PEDIDO (
    PARAM_idCliente  IN   NUMBER,
    PARAM_idPedido   OUT  NUMBER
) IS
    vvActivo      CLIENTE.activo%TYPE;
    vnDisponible  NUMBER;
    e_cliente_inexistente  EXCEPTION;
    e_cliente_inactivo     EXCEPTION;
    e_sin_cupo             EXCEPTION;
BEGIN
    PARAM_idPedido := NULL;

    BEGIN
        SELECT activo, cupo_credito - saldo_pendiente
        INTO   vvActivo, vnDisponible
        FROM   CLIENTE
        WHERE  id_cliente = PARAM_idCliente;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE e_cliente_inexistente;
    END;

    IF vvActivo <> 'S' THEN
        RAISE e_cliente_inactivo;
    END IF;

    IF vnDisponible <= 0 THEN
        RAISE e_sin_cupo;
    END IF;

    INSERT INTO PEDIDO (id_pedido, id_cliente, estado, total)
    VALUES (SEQ_PEDIDO.NEXTVAL, PARAM_idCliente, 'BORRADOR', 0)
    RETURNING id_pedido INTO PARAM_idPedido;
EXCEPTION
    WHEN e_cliente_inexistente THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: el cliente ' || PARAM_idCliente || ' no existe');
    WHEN e_cliente_inactivo THEN
        DBMS_OUTPUT.PUT_LINE('ERROR (CLIENTE INACTIVO): el cliente ' || PARAM_idCliente || ' no puede crear pedidos');
    WHEN e_sin_cupo THEN
        DBMS_OUTPUT.PUT_LINE('ERROR (SIN CUPO): el cliente ' || PARAM_idCliente || ' tiene el cupo de credito agotado');
END SP_CREAR_PEDIDO;
/

-- PRUEBA 1.3  (esperado: 501 OK; 506 inactivo; 505 sin cupo; 999 inexistente)
DECLARE
    vnId NUMBER;
    PROCEDURE SP_crear (
        PARAM_idCliente  IN NUMBER
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('>> cliente ' || PARAM_idCliente);
        SP_CREAR_PEDIDO(PARAM_idCliente, vnId);
        DBMS_OUTPUT.PUT_LINE('   pedido devuelto: ' || NVL(TO_CHAR(vnId), 'NULL (rechazado)'));
    END SP_crear;
BEGIN
    SP_crear(501);
    SP_crear(506);
    SP_crear(505);
    SP_crear(999);
    ROLLBACK;
END;
/


--==============================================================================
-- PARTE 2 — FUNCIONES                                         (8 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 2.1 (2 pts)
-- FN_STOCK_DISPONIBLE
-- Retorna la cantidad disponible de un producto. Si se indica bodega, devuelve
-- el saldo de esa bodega; si PARAM_idBodega llega nulo, el consolidado de todas.
-- Un producto inexistente debe retornar cero y no una excepcion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- * Se usa SUM con NVL en lugar de SELECT cantidad INTO. Un agregado sin
--   GROUP BY siempre devuelve exactamente una fila (con NULL si no hay filas),
--   asi que nunca se produce NO_DATA_FOUND ni TOO_MANY_ROWS. NVL(...,0)
--   convierte ese NULL en cero, que cubre a la vez "producto inexistente",
--   "producto sin existencias" y "combinacion bodega-producto inexistente", sin
--   manejador de excepciones.
-- * Se separan dos consultas con IF en lugar de una sola con
--   "(PARAM_idBodega IS NULL OR id_bodega = PARAM_idBodega)". El OR opcional impide
--   que el optimizador aproveche la llave (id_bodega, id_producto) cuando si
--   llega la bodega, y un solo plan rinde mal en ambos casos.
-- * La funcion solo hace SELECT, por lo que cumple la restriccion para
--   invocarse desde SQL (ver 2.4).
-- * Lee el ultimo dato confirmado y no bloquea. Es un dato informativo: entre
--   la consulta y el despacho el stock puede cambiar, por eso la validacion
--   definitiva esta en SP_AJUSTAR_STOCK y TRG_DETALLE_AI_STOCK.
CREATE OR REPLACE FUNCTION FN_STOCK_DISPONIBLE (
    PARAM_idProducto  IN  NUMBER,
    PARAM_idBodega    IN  NUMBER DEFAULT NULL
) RETURN NUMBER IS
    vnStock NUMBER;
BEGIN
    IF PARAM_idBodega IS NULL THEN
        SELECT NVL(SUM(cantidad), 0) INTO vnStock
        FROM   EXISTENCIA
        WHERE  id_producto = PARAM_idProducto;
    ELSE
        SELECT NVL(SUM(cantidad), 0) INTO vnStock
        FROM   EXISTENCIA
        WHERE  id_producto = PARAM_idProducto
        AND    id_bodega   = PARAM_idBodega;
    END IF;
    RETURN vnStock;
END FN_STOCK_DISPONIBLE;
/

-- PRUEBA 2.1  (esperado: 160 | 120 | 0 | 0 | 0)
SELECT FN_STOCK_DISPONIBLE(1001)       AS consolidado_1001,
       FN_STOCK_DISPONIBLE(1001, 1)    AS bodega1_1001,
       FN_STOCK_DISPONIBLE(1001, 4)    AS bodega4_sin_registro,
       FN_STOCK_DISPONIBLE(1015)       AS producto_sin_existencias,
       FN_STOCK_DISPONIBLE(9999)       AS producto_inexistente
FROM   DUAL;

------------------------------------------------------------------- 2.2 (2 pts)
-- FN_CUPO_DISPONIBLE
-- Retorna el cupo de credito disponible del cliente, entendido como cupo menos
-- saldo pendiente. Un cliente inactivo retorna cero y el resultado nunca puede
-- ser negativo.
-------------------------------------------------------------------------------
-- Justificacion:
-- * GREATEST(cupo - saldo, 0) garantiza que el resultado nunca sea negativo
--   aunque los datos queden inconsistentes (saldo mayor al cupo). El CHECK de
--   la tabla solo prohibe negativos en cada columna por separado, no en la
--   resta de ambas.
-- * La regla del cliente inactivo se resuelve con CASE dentro de la misma
--   consulta, lo que da un solo acceso a la tabla y deja toda la regla junta.
-- * Un cliente inexistente devuelve 0 (se atrapa NO_DATA_FOUND). Devolver
--   "sin cupo" evita que una consulta masiva que llame a la funcion aborte por
--   una sola fila anomala. Es la misma convencion que usa FN_STOCK_DISPONIBLE.
-- * Es una lectura sin bloqueo. Quien vaya a consumir el cupo (PKG_VENTAS)
--   debe bloquear al cliente antes de llamarla; de lo contrario, dos
--   facturaciones simultaneas podrian ver el mismo cupo y sobrepasarlo.
CREATE OR REPLACE FUNCTION FN_CUPO_DISPONIBLE (
    PARAM_idCliente  IN  NUMBER
) RETURN NUMBER IS
    vnCupo NUMBER;
BEGIN
    SELECT CASE WHEN activo = 'S'
                THEN GREATEST(cupo_credito - saldo_pendiente, 0)
                ELSE 0
           END
    INTO   vnCupo
    FROM   CLIENTE
    WHERE  id_cliente = PARAM_idCliente;

    RETURN vnCupo;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END FN_CUPO_DISPONIBLE;
/

-- PRUEBA 2.2  (esperado: 6750000 | 0 (agotado) | 0 (inactivo) | 0 (inexistente))
SELECT FN_CUPO_DISPONIBLE(501) AS c501,
       FN_CUPO_DISPONIBLE(505) AS c505_agotado,
       FN_CUPO_DISPONIBLE(506) AS c506_inactivo,
       FN_CUPO_DISPONIBLE(999) AS c999_inexistente
FROM   DUAL;

------------------------------------------------------------------- 2.3 (3 pts)
-- FN_CALCULAR_DESCUENTO
-- Retorna el VALOR en pesos del descuento aplicable, segun estas reglas
-- acumulables:
--     Monto mayor o igual a 2.000.000 ................. 8%
--     Monto entre 800.000 y 1.999.999 ................. 5%
--     Monto menor a 800.000 ........................... 0%
--     Adicional si el cliente no tiene saldo pendiente . 2%
--     Tope maximo acumulado ........................... 10%
-- La funcion retorna el valor del descuento, no el porcentaje.
-------------------------------------------------------------------------------
-- Justificacion:
-- * Se calcula primero el porcentaje acumulado y al final se convierte a pesos
--   (monto * pct / 100). Separar ambos pasos evita devolver el porcentaje por
--   error, que el enunciado marca explicitamente.
-- * Los tramos se evaluan con ">= 2000000" y luego ">= 800000" en lugar de
--   BETWEEN 800000 AND 1999999. Con BETWEEN, un monto como 1.999.999,50 (la
--   columna tiene 2 decimales) no caeria en ningun tramo; con la comparacion
--   descendente no quedan huecos.
-- * Se interpreta "acumulables" de forma literal: el 2% por no tener saldo se
--   suma al tramo por monto, incluso cuando el tramo es 0% (un monto menor a
--   800.000 sin saldo da 2%). Queda anotado como supuesto.
-- * El tope del 10% se aplica con LEAST. Con estas reglas el maximo alcanzable
--   es 8 + 2 = 10, asi que hoy el tope nunca recorta nada. Se implementa igual
--   porque es una regla de negocio explicita y protege si luego cambian los
--   porcentajes.
-- * Si el cliente no existe, no hay saldo que consultar y solo se aplica el
--   tramo por monto, sin el adicional. Un monto nulo o no positivo devuelve 0.
-- * El resultado se redondea a 2 decimales para ser consistente con las
--   columnas NUMBER(14,2) donde se guardara.
CREATE OR REPLACE FUNCTION FN_CALCULAR_DESCUENTO (
    PARAM_idCliente  IN  NUMBER,
    PARAM_monto      IN  NUMBER
) RETURN NUMBER IS
    cnTopePct       CONSTANT NUMBER := 10;
    cnBonoSinSaldo  CONSTANT NUMBER := 2;
    vnPct           NUMBER := 0;
    vnSaldo         CLIENTE.saldo_pendiente%TYPE;
BEGIN
    IF PARAM_monto IS NULL OR PARAM_monto <= 0 THEN
        RETURN 0;
    END IF;

    IF PARAM_monto >= 2000000 THEN
        vnPct := 8;
    ELSIF PARAM_monto >= 800000 THEN
        vnPct := 5;
    END IF;

    BEGIN
        SELECT saldo_pendiente INTO vnSaldo
        FROM   CLIENTE
        WHERE  id_cliente = PARAM_idCliente;

        IF vnSaldo = 0 THEN
            vnPct := vnPct + cnBonoSinSaldo;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL; -- cliente inexistente: solo aplica el tramo por monto
    END;

    vnPct := LEAST(vnPct, cnTopePct);

    RETURN ROUND(PARAM_monto * vnPct / 100, 2);
END FN_CALCULAR_DESCUENTO;
/

-- PRUEBA 2.3
-- esperado: 254000 (503, sin saldo: 8+2=10%) | 203200 (504, con saldo: 8%)
--           45000 (501, 5%) | 10000 (503, monto bajo pero sin saldo: 2%) | 0 (501, monto bajo)
SELECT FN_CALCULAR_DESCUENTO(503, 2540000) AS d_503_2_54M,
       FN_CALCULAR_DESCUENTO(504, 2540000) AS d_504_2_54M,
       FN_CALCULAR_DESCUENTO(501,  900000) AS d_501_900k,
       FN_CALCULAR_DESCUENTO(503,  500000) AS d_503_500k,
       FN_CALCULAR_DESCUENTO(501,  500000) AS d_501_500k
FROM   DUAL;

------------------------------------------------------------------- 2.4 (1 pt)
-- Escriba una consulta que liste los clientes activos con su cupo disponible,
-- usando la funcion del punto 2.2, ordenados de mayor a menor.
-- Explique por que una funcion definida por el usuario puede invocarse desde
-- una sentencia SQL y que restriccion debe cumplir para poder hacerlo.
-------------------------------------------------------------------------------
-- Respuesta:
-- * Una funcion almacenada puede invocarse desde SQL porque es un objeto del
--   esquema que recibe parametros y devuelve un solo valor de un tipo SQL (aqui
--   NUMBER). Para el motor SQL eso equivale a una expresion escalar, como
--   UPPER() o ROUND(): al evaluar cada fila, el motor cede el control a la
--   maquina virtual de PL/SQL, ejecuta la funcion y recibe el valor de vuelta.
-- * La restriccion principal es que la funcion no puede modificar el estado de
--   la base de datos cuando se llama desde una consulta. No puede ejecutar
--   INSERT, UPDATE, DELETE ni DDL, ni COMMIT/ROLLBACK (ORA-14551 / ORA-14552),
--   y si se invoca desde un DML no puede leer ni modificar la tabla que ese
--   mismo DML esta cambiando (ORA-04091). Ademas solo debe tener parametros IN
--   y devolver un tipo SQL valido (no BOOLEAN). FN_CUPO_DISPONIBLE cumple
--   porque solo hace SELECT.
-- * Cada llamada implica un cambio de contexto entre SQL y PL/SQL por fila. Con
--   7 clientes es irrelevante; con millones de filas conviene un JOIN o una
--   subconsulta escalar en lugar de la funcion.
--
SELECT c.id_cliente,
       c.nombre,
       FN_CUPO_DISPONIBLE(c.id_cliente) AS cupo_disponible
FROM   CLIENTE c
WHERE  c.activo = 'S'
ORDER  BY cupo_disponible DESC;
-- esperado (orden): 504, 501, 507, 503, 502, 505


--==============================================================================
-- PARTE 3 — CURSORES                                         (10 puntos / 90 min)
--==============================================================================

------------------------------------------------------------------- 3.1 (2 pts)
-- Bloque anonimo que recorra, con un CURSOR EXPLICITO, los productos cuyo stock
-- consolidado este por debajo del stock minimo, e imprima un reporte con codigo,
-- nombre, stock actual, stock minimo y unidades faltantes, mas el total de
-- productos en esa condicion.
-- Debe usar OPEN, FETCH y CLOSE de forma explicita. El ciclo FOR implicito no se
-- acepta en este punto.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos la vista V_STOCK_CONSOLIDADO porque el enunciado pide comparar el stock total de cada producto,
-- sumando todas sus bodegas, y la vista ya hace esa suma. Esto es importante porque un producto puede
-- tener pocas unidades en una bodega y estar bien en total. Si compararamos bodega por bodega, saldria en el
-- reporte por error. Usamos un cursor explicito (OPEN, FETCH, CLOSE) porque el enunciado lo exige en este punto.
-- El final de las filas lo detectamos con %NOTFOUND, porque el FETCH no lanza NO_DATA_FOUND cuando se acaban. Ademas,
-- ponemos el EXIT WHEN justo despues del FETCH, para no imprimir la ultima fila dos veces. Como decision
-- nuestra, tambien salen los productos inactivos que esten bajo el minimo, porque el enunciado no dice que se excluyan.

-- Sobre como se comporta: al abrir el cursor, Oracle toma una "foto" de los datos en ese momento,
-- y todo el reporte se imprime con esa foto. Si otra persona registra una entrada o una salida de stock mientras
-- el reporte se imprime, ese cambio no aparece. A cambio, el cursor no bloquea a nadie, es decir, nadie tiene que
-- esperar a que termine el reporte. Para un reporte eso es suficiente. Si ocurre un error dentro del ciclo, el bloque
-- cierra el cursor y vuelve a lanzar el error con RAISE, para no dejar el cursor abierto ni esconder el problema.


DECLARE
    CURSOR cur_bajo_stock IS
        SELECT codigo, producto, stock_total, stock_minimo, stock_minimo - stock_total AS faltantes
        FROM   V_STOCK_CONSOLIDADO
        WHERE  stock_total < stock_minimo
        ORDER BY codigo;

    vrProducto  cur_bajo_stock%ROWTYPE;
    vnContador  NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE(' ------ productos por debajo del stock minimo ------');
    DBMS_OUTPUT.PUT_LINE(RPAD('CODIGO', 10) || RPAD('NOMBRE', 34) || LPAD('STOCK', 8) || LPAD('MINIMO', 8) || LPAD('FALTAN', 8));

    OPEN cur_bajo_stock;
    LOOP
        FETCH cur_bajo_stock INTO vrProducto;
        EXIT WHEN cur_bajo_stock%NOTFOUND;

        vnContador := vnContador + 1;
        DBMS_OUTPUT.PUT_LINE(RPAD(vrProducto.codigo, 10) || RPAD(SUBSTR(vrProducto.producto, 1, 32), 34) || LPAD(vrProducto.stock_total, 8) ||
                             LPAD(vrProducto.stock_minimo, 8) || LPAD(vrProducto.faltantes, 8));
    END LOOP;
    CLOSE cur_bajo_stock;

    DBMS_OUTPUT.PUT_LINE(RPAD('-', 68, '-'));
    DBMS_OUTPUT.PUT_LINE('Total de productos por debajo del minimo: ' || vnContador);
EXCEPTION
    WHEN OTHERS THEN
        IF cur_bajo_stock%ISOPEN THEN
            CLOSE cur_bajo_stock;
        END IF;
        RAISE;
END;
/

------------------------------------------------------------------- 3.2 (2 pts)
-- Bloque anonimo con un CURSOR PARAMETRIZADO que reciba identificador de cliente
-- y un rango de fechas, y muestre los pedidos CONFIRMADOS de ese cliente en ese
-- rango, con su total y la cantidad de lineas de cada pedido.
-- Pruebelo con el cliente 501 entre 2026-01-01 y 2026-12-31.
-- Los parametros deben declararse en el cursor, no tomarse del alcance del bloque.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Declaramos el cursor con parametros (cliente, fecha inicial y fecha final) para usarlo con cualquier
-- valor sin reescribir la consulta. Lo usamos cuatro veces con datos distintos.
-- El rango de fechas lo escribimos como "mayor o igual al inicio y menor que el fin mas un dia", y no con BETWEEN,
-- porque la fecha del pedido guarda tambien la hora. Con BETWEEN, el limite final seria las 00:00 del ultimo dia,
-- y un pedido de ese dia a las 15:30 quedaria fuera. Se implementa LEFT JOIN hacia DETALLE_PEDIDO junto
-- con COUNT(d.linea) para garantizar que pedidos recien confirmados que aun no posean lineas asociadas
-- reporten 0 en lugar de ser descartados. Por ultimo, usamos un ciclo FOR porque en este punto no se exige controlar el OPEN y el FETCH a mano.

-- Sobre como se comporta: el listado es una "foto" del momento en que se abre el cursor y no bloquea a nadie.
-- Si otra persona confirma un pedido mientras se lee, puede no aparecer. La consulta filtra por cliente, estado y fecha.
-- Si hubiera muchisimos pedidos, ayudaria un indice por cliente y fecha.
-- Si ocurre un error, el ciclo FOR cierra el cursor solo. Un cliente sin pedidos no se trata como error; en ese caso muestra un aviso.


DECLARE
    CURSOR cur_pedidos_cliente (
        PARAM_idCliente   NUMBER,
        PARAM_fechaInicio DATE,
        PARAM_fechaFin    DATE
    ) IS
        SELECT p.id_pedido, p.fecha_pedido, p.total, COUNT(d.linea) AS lineas
        FROM   PEDIDO p
        LEFT JOIN DETALLE_PEDIDO d ON d.id_pedido = p.id_pedido
        WHERE  p.id_cliente   = PARAM_idCliente
        AND    p.estado       = 'CONFIRMADO'
        AND    p.fecha_pedido >= PARAM_fechaInicio
        AND    p.fecha_pedido <  PARAM_fechaFin + 1
        GROUP BY p.id_pedido, p.fecha_pedido, p.total
        ORDER BY p.fecha_pedido, p.id_pedido;

    PROCEDURE SP_mostrarPedidos (
        PARAM_idCliente   IN NUMBER,
        PARAM_fechaInicio IN DATE,
        PARAM_fechaFin    IN DATE
    ) IS
        vnContador  NUMBER := 0;
        vnSumaTotal NUMBER := 0;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Cliente ' || PARAM_idCliente || ' | pedidos CONFIRMADOS entre ' || TO_CHAR(PARAM_fechaInicio, 'YYYY-MM-DD') ||
        ' y ' || TO_CHAR(PARAM_fechaFin, 'YYYY-MM-DD'));
        FOR vrPedido IN cur_pedidos_cliente(PARAM_idCliente, PARAM_fechaInicio, PARAM_fechaFin) LOOP
            vnContador  := vnContador + 1;
            vnSumaTotal := vnSumaTotal + vrPedido.total;
            DBMS_OUTPUT.PUT_LINE('   Pedido ' || LPAD(vrPedido.id_pedido, 3) || ' | ' || TO_CHAR(vrPedido.fecha_pedido, 'YYYY-MM-DD HH24:MI') ||
                                 ' | total ' || LPAD(TO_CHAR(vrPedido.total, 'FM999,999,990'), 11) || ' | lineas ' || vrPedido.lineas);
        END LOOP;
        IF vnContador = 0 THEN
            DBMS_OUTPUT.PUT_LINE('   (sin pedidos confirmados en ese rango)');
        ELSE
            DBMS_OUTPUT.PUT_LINE('   Pedidos: ' || vnContador || ' | suma de totales: ' ||
                                 TO_CHAR(vnSumaTotal, 'FM999,999,990'));
        END IF;
    END SP_mostrarPedidos;

BEGIN
    SP_mostrarPedidos(501, TO_DATE('2026-01-01', 'YYYY-MM-DD'), TO_DATE('2026-12-31', 'YYYY-MM-DD'));

    SP_mostrarPedidos(501, TO_DATE('2026-07-01', 'YYYY-MM-DD'), TO_DATE('2026-07-31', 'YYYY-MM-DD'));

    SP_mostrarPedidos(505, TO_DATE('2026-01-01', 'YYYY-MM-DD'), TO_DATE('2026-12-31', 'YYYY-MM-DD'));

    -- Pedido temporal del 31-dic a las 15:30; debe entrar al rango y salir con 0 lineas. Despues se revierte.
    INSERT INTO PEDIDO (id_pedido, id_cliente, fecha_pedido, estado, total)
    VALUES (SEQ_PEDIDO.NEXTVAL, 501, TO_DATE('2026-12-31 15:30', 'YYYY-MM-DD HH24:MI'), 'CONFIRMADO', 100000);

    SP_mostrarPedidos(501, TO_DATE('2026-01-01', 'YYYY-MM-DD'), TO_DATE('2026-12-31', 'YYYY-MM-DD'));
    ROLLBACK;
END;
/

------------------------------------------------------------------- 3.3 (3 pts)
-- Bloque anonimo con un CURSOR FOR UPDATE que recorra los productos de una
-- categoria y ajuste su precio un porcentaje dado, usando WHERE CURRENT OF.
--   * No debe modificar productos inactivos
--   * El precio resultante no puede quedar por debajo del costo mas el margen
--     minimo de la categoria
-- Explique que bloqueo genera FOR UPDATE, cuanto dura, y por que WHERE CURRENT OF
-- es preferible a un UPDATE por clave primaria.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos un cursor FOR UPDATE porque se modifican las filas que leemos. Al abrir el cursor, se bloquean las filas.
-- El bloqueo dura hasta el COMMIT o el ROLLBACK. No hacemos COMMIT dentro del ciclo porque soltaria los bloqueos y el siguiente FETCH fallaria.

-- Modificamos con WHERE CURRENT OF porque actualiza la fila que acabamos de leer, que ademas ya esta bloqueada.
-- Escribimos FOR UPDATE OF p.precio_unitario para bloquear solo las filas de PRODUCTO y no las de CATEGORIA, que solo consultamos.
-- Los productos inactivos se filtran en el WHERE del cursor, asi no se leen ni se bloquean. Como decision nuestra, cuando el precio nuevo queda bajo el minimo,
-- omitimos el producto y lo informamos, en lugar de subirlo al minimo, porque eso aplicaria un porcentaje distinto al pedido.

-- Sobre como se comporta: mientras el cursor esta abierto, quien intente modificar esos productos tiene que esperar a que terminemos.
-- Si alguien ya tenia bloqueado alguno de ellos, nuestro OPEN tambien espera. Si un UPDATE falla, el bloque cierra el cursor y vuelve a lanzar el error.
-- Lo que ya se modifico antes del error no queda confirmado, porque no hacemos COMMIT.



DECLARE
    CURSOR cur_productos_cat (PARAM_idCategoria NUMBER) IS
        SELECT p.codigo, p.precio_unitario, p.costo_unitario, c.margen_minimo
        FROM   PRODUCTO p
        JOIN CATEGORIA c ON c.id_categoria = p.id_categoria
        WHERE  p.id_categoria = PARAM_idCategoria
        AND    p.activo = 'S'
        ORDER BY p.codigo
        FOR UPDATE OF p.precio_unitario;

    vrProducto      cur_productos_cat%ROWTYPE;
    vnIdCategoria         NUMBER := 1;      -- categoria a ajustar
    vnPorcentajeAjuste    NUMBER := -22;
    vnPrecioNuevo         NUMBER;
    vnPrecioMinimo        NUMBER;
    vnActualizados        NUMBER := 0;
    vnOmitidos            NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Ajuste de precios | categoria ' || vnIdCategoria || ' | porcentaje ' || vnPorcentajeAjuste || '%');
    DBMS_OUTPUT.PUT_LINE(RPAD('CODIGO', 10) || LPAD('ANTERIOR', 11) || LPAD('NUEVO', 11) || LPAD('MINIMO', 11) || '  RESULTADO');

    OPEN cur_productos_cat(vnIdCategoria);
    LOOP
        FETCH cur_productos_cat INTO vrProducto;
        EXIT WHEN cur_productos_cat%NOTFOUND;

        vnPrecioNuevo  := ROUND(vrProducto.precio_unitario * (1 + vnPorcentajeAjuste / 100), 2);
        vnPrecioMinimo := vrProducto.costo_unitario * (1 + vrProducto.margen_minimo / 100);

        IF vnPrecioNuevo >= vnPrecioMinimo THEN
            UPDATE PRODUCTO
            SET    precio_unitario = vnPrecioNuevo
            WHERE  CURRENT OF cur_productos_cat;
            vnActualizados := vnActualizados + 1;
            DBMS_OUTPUT.PUT_LINE(RPAD(vrProducto.codigo, 10) || LPAD(TO_CHAR(vrProducto.precio_unitario, 'FM999,999,990.00'), 11) ||
                LPAD(TO_CHAR(vnPrecioNuevo, 'FM999,999,990.00'), 11) || LPAD(TO_CHAR(vnPrecioMinimo, 'FM999,999,990.00'), 11) || '  ACTUALIZADO');
        ELSE
            vnOmitidos := vnOmitidos + 1;
            DBMS_OUTPUT.PUT_LINE(RPAD(vrProducto.codigo, 10) || LPAD(TO_CHAR(vrProducto.precio_unitario, 'FM999,999,990.00'), 11) ||
                LPAD(TO_CHAR(vnPrecioNuevo, 'FM999,999,990.00'), 11) || LPAD(TO_CHAR(vnPrecioMinimo, 'FM999,999,990.00'), 11) || '  OMITIDO (quedaria bajo el minimo)');
        END IF;
    END LOOP;
    CLOSE cur_productos_cat;

    DBMS_OUTPUT.PUT_LINE('Actualizados: ' || vnActualizados || ' | Omitidos: ' || vnOmitidos);

    -- Verificacion: precios actuales de toda la categoria (el inactivo no cambia)
    DBMS_OUTPUT.PUT_LINE('Precios despues del ajuste:');
    FOR vrFila IN (SELECT codigo, precio_unitario, activo
                   FROM   PRODUCTO
                   WHERE  id_categoria = vnIdCategoria
                   ORDER BY codigo) LOOP
        DBMS_OUTPUT.PUT_LINE('   ' || RPAD(vrFila.codigo, 10) ||
            LPAD(TO_CHAR(vrFila.precio_unitario, 'FM999,999,990.00'), 11) ||
            '  activo=' || vrFila.activo);
    END LOOP;

    ROLLBACK;
EXCEPTION
    WHEN OTHERS THEN
        IF cur_productos_cat%ISOPEN THEN
            CLOSE cur_productos_cat;
        END IF;
        RAISE;
END;
/

------------------------------------------------------------------- 3.4 (2 pts)
-- SP_LISTAR_MOVIMIENTOS
-- Procedimiento que reciba un identificador de producto y devuelva un
-- SYS_REFCURSOR con los movimientos de inventario de ese producto, ordenados
-- por fecha. Incluya un bloque anonimo que consuma el cursor devuelto y lo cierre.
-------------------------------------------------------------------------------
-- JUSTIFICACION:

-- SYS_REFCURSOR es un tipo de dato que sirve para guardar una consulta que esta abierta. No contiene las filas.
-- Es un puntero que apunta a una consulta lista para ser leida, y puede apuntar a cualquier consulta. Lo usamos porque un procedimiento
-- no puede devolver varias filas. Con un parametro OUT de este tipo, el procedimiento abre la consulta y la entrega, y quien lo llama va leyendo las filas.
-- Devolver una coleccion obligaba a cargar todos los movimientos en memoria, por eso se descarta. Con el cursor, el procedimiento solo prepara los datos
-- y quien lo recibe decide que hacer con ellos.

-- Dentro del procedimiento solo abrimos el cursor y no lo cerramos. Si lo cerraramos antes de devolverlo, quien lo recibe no podria leer ninguna fila. P
-- or eso el CLOSE lo hace el bloque que lo consume. Ordenamos por fecha y, como segundo criterio, por id del movimiento. Respecto a la concurrencia,
-- el cursor muestra los datos tal como estaban en el momento en que se abrio, aunque se lean despues. Si otra sesion registra un movimiento nuevo
-- mientras se esta leyendo, ese movimiento no aparece. Ademas, el cursor no bloquea ninguna fila.
-- En cuanto al volumen, las filas no se cargan todas en memoria. El cursor las entrega a medida que se piden,
-- por eso un producto con muchisimos movimientos no llena la memoria de la sesion.
-- El riesgo principal es que quien reciba el cursor se olvide de cerrarlo.

CREATE OR REPLACE PROCEDURE SP_LISTAR_MOVIMIENTOS (
    PARAM_idProducto IN  NUMBER,
    PARAM_cursor     OUT SYS_REFCURSOR
) IS
BEGIN
    OPEN PARAM_cursor FOR
        SELECT id_movimiento, id_producto, id_bodega, tipo, cantidad, fecha_mov, id_pedido, usuario_bd, observacion
        FROM   MOVIMIENTO_INVENTARIO
        WHERE  id_producto = PARAM_idProducto
        ORDER BY fecha_mov, id_movimiento;
END SP_LISTAR_MOVIMIENTOS;
/
-- Bloque consumidor:
DECLARE
    cur_movimientos  SYS_REFCURSOR;
    vrMovimiento    MOVIMIENTO_INVENTARIO%ROWTYPE;
    vnContador      NUMBER := 0;
BEGIN
    SP_LISTAR_MOVIMIENTOS(1001, cur_movimientos);
     LOOP
        FETCH cur_movimientos INTO vrMovimiento;
        EXIT WHEN cur_movimientos%NOTFOUND;
        vnContador := vnContador + 1;
        DBMS_OUTPUT.PUT_LINE(vrMovimiento.id_movimiento || ' | ' || TO_CHAR(vrMovimiento.fecha_mov, 'YYYY-MM-DD') || ' | ' || vrMovimiento.tipo ||
            ' | bodega ' || vrMovimiento.id_bodega || ' | cantidad ' || vrMovimiento.cantidad || ' | ' || vrMovimiento.observacion);
    END LOOP;
     CLOSE cur_movimientos;
    DBMS_OUTPUT.PUT_LINE('Total: ' || vnContador || ' movimientos');
END;
/

------------------------------------------------------------------- 3.5 (1 pt)
-- Bloque anonimo que cargue con BULK COLLECT los productos de una categoria en
-- una coleccion y use FORALL para actualizar su stock minimo.
-- Explique que costo concreto elimina esta tecnica y a partir de que volumen
-- empieza a notarse.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos BULK COLLECT y FORALL en lugar de un ciclo con un UPDATE por fila porque, en el ciclo, cada lectura y cada UPDATE
-- es una ida y vuelta entre PL/SQL y SQL. En cambio con BULK COLLECT traemos todas las filas a listas en memoria en un solo viaje,
-- y con FORALL mandamos todos los UPDATE en otro solo viaje. Se ahorra viaje pero no se ahorra el trabajo de modificar cada fila y los triggers por fila siguen ejecutandose.
-- Con CEIL redondeamos hacia arriba porque el stock minimo es un numero entero de unidades.
-- Como decision de diseno, el enunciado no dice como actualizar el stock minimo, asi que lo subimos un porcentaje, y tomamos todos los
-- productos de la categoria porque aqui no excluye a los inactivos. En la operacion, con pocas filas no se nota diferencia. Empieza a notarse con miles de filas.
-- BULK COLLECT sin LIMIT guarda todo en la memoria de la sesion, y con millones de filas habria que leer por lotes.
-- El SELECT no bloquea: si otra sesion cambia el stock minimo de un producto entre la carga y el FORALL, nuestro UPDATE lo pisa (gana el ultimo).
-- Para evitarlo habria que leer con FOR UPDATE. Si una fila falla dentro del FORALL, este se detiene en ese punto. Con SAVE EXCEPTIONS se podria seguir y revisar cuales fallaron. Si la categoria no tuviera productos, las listas quedarian vacias y no habria nada que actualizar.

DECLARE
    TYPE tbIdProducto  IS TABLE OF PRODUCTO.id_producto%TYPE;
    TYPE tbStockMinimo IS TABLE OF PRODUCTO.stock_minimo%TYPE;

    vtIdProducto    tbIdProducto; -- lista q guarda id de product
    vtStockAnterior tbStockMinimo;
    vtStockNuevo    tbStockMinimo;
    vnIdCategoria   NUMBER := 1;     -- categoria a ajustar
    vnPorcentaje    NUMBER := 10;    -- aumento del stock minimo, en %
BEGIN
    SELECT id_producto,
           stock_minimo,
           CEIL(stock_minimo * (1 + vnPorcentaje / 100))
    BULK COLLECT INTO vtIdProducto, vtStockAnterior, vtStockNuevo
    FROM   PRODUCTO
    WHERE  id_categoria = vnIdCategoria
    ORDER BY id_producto;

    DBMS_OUTPUT.PUT_LINE('Categoria ' || vnIdCategoria || ' | aumento de stock minimo: ' || vnPorcentaje || '% | productos cargados: ' || vtIdProducto.COUNT);

    IF vtIdProducto.COUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('No hay productos en esa categoria.');
    ELSE
        FOR vnIndice IN 1 .. vtIdProducto.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE('   Producto ' || vtIdProducto(vnIndice) || ': stock minimo ' || vtStockAnterior(vnIndice) || ' -> ' || vtStockNuevo(vnIndice));
        END LOOP;

        -- actualizar todo con un solo FORALL
        FORALL vnIndice IN 1 .. vtIdProducto.COUNT
            UPDATE PRODUCTO
            SET    stock_minimo = vtStockNuevo(vnIndice)
            WHERE  id_producto  = vtIdProducto(vnIndice);
        DBMS_OUTPUT.PUT_LINE('Filas actualizadas por el FORALL: ' || SQL%ROWCOUNT);

        -- Verificacion antes del ROLLBACK
        FOR vrFila IN (SELECT id_producto, stock_minimo
                       FROM   PRODUCTO
                       WHERE  id_categoria = vnIdCategoria
                       ORDER BY id_producto) LOOP
            DBMS_OUTPUT.PUT_LINE('   En la tabla: producto ' || vrFila.id_producto ||' ahora hay stock minimo ' || vrFila.stock_minimo);
        END LOOP;
    END IF;

    ROLLBACK;
END;
/


--==============================================================================
-- PARTE 4 — MANEJO DE EXCEPCIONES                             (9 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 4.1 (2 pts)
-- FN_PRECIO_PRODUCTO
-- Funcion que reciba el CODIGO de un producto y retorne su precio, manejando
-- explicitamente NO_DATA_FOUND y TOO_MANY_ROWS, con retorno de -1 y -2
-- respectivamente, e imprimiendo un mensaje descriptivo en cada caso.
-- Explique en que situacion real se produciria TOO_MANY_ROWS sobre esta tabla,
-- considerando las restricciones que hoy tiene.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos NO_DATA_FOUND y TOO_MANY_ROWS, cada una con su mensaje y su valor de retorno, y no usamos WHEN OTHERS porque
-- cualquier otro error (por ejemplo, de permisos) debe seguir subiendo y no disfrazarse de "producto no encontrado".
-- Los valores -1 y -2 no se confunden con un precio real porque la tabla exige que el precio sea mayor que cero.
-- Un codigo nulo o escrito en minusculas devuelve -1 porque la busqueda es exacta.

-- TOO_MANY_ROWS casi nunca ocurriria hoy en esta tabla, porque la columna codigo tiene una restriccion UNIQUE,
-- que permite una sola fila por codigo. Solo pasaria si la restriccion se desactiva o tambien podria pasar si la busqueda ignora las mayusculas,
-- porque la restriccion distingue "ab-1" de "AB-1" y un UPPER los volveria iguales
-- En la operacion, la funcion solo lee y no bloquea nada, asi que el precio es el del momento de la consulta: si cambia justo despues, se queda con el valor anterior.
-- Con muchos productos la busqueda sigue siendo rapida, porque la restriccion UNIQUE crea un indice sobre el codigo.
-- Los mensajes salen por DBMS_OUTPUT, que solo ve quien ejecuta, asi que para guardarlos de forma permanente habria que usar SP_REGISTRAR_ERROR (4.5).

CREATE OR REPLACE FUNCTION FN_PRECIO_PRODUCTO (
    PARAM_codigo IN VARCHAR2
) RETURN NUMBER IS
    vnPrecio              PRODUCTO.precio_unitario%TYPE;
BEGIN
    SELECT precio_unitario
    INTO   vnPrecio
    FROM   PRODUCTO
    WHERE  codigo = PARAM_codigo;

    RETURN vnPrecio;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('FN_PRECIO_PRODUCTO: no existe ningun producto con el codigo ' || PARAM_codigo || ' (retorna -1)');
        RETURN -1;
    WHEN TOO_MANY_ROWS THEN
        DBMS_OUTPUT.PUT_LINE('FN_PRECIO_PRODUCTO: hay mas de un producto con el codigo ' || PARAM_codigo || ' (retorna -2)');
        RETURN -2;
END FN_PRECIO_PRODUCTO;
/

DECLARE
    PROCEDURE SP_comparar (
        PARAM_titulo    IN VARCHAR2,
        PARAM_obtenido  IN NUMBER,
        PARAM_esperado  IN NUMBER
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(RPAD(PARAM_titulo, 54) || ' obtenido=' || PARAM_obtenido || '  esperado=' || PARAM_esperado ||
            CASE WHEN PARAM_obtenido = PARAM_esperado THEN '  OK' ELSE '  REVISAR' END);
    END SP_comparar;
BEGIN
    SP_comparar('Codigo HM-0001 (existe)',                   FN_PRECIO_PRODUCTO('HM-0001'), 45000);
    SP_comparar('Codigo HE-0001 (existe)',                   FN_PRECIO_PRODUCTO('HE-0001'), 320000);
    SP_comparar('Codigo ZZ-9999 (no existe) -> -1',          FN_PRECIO_PRODUCTO('ZZ-9999'), -1);
    SP_comparar('Codigo en minusculas hm-0001 -> -1',        FN_PRECIO_PRODUCTO('hm-0001'), -1);
    SP_comparar('Codigo nulo -> -1',                         FN_PRECIO_PRODUCTO(NULL), -1);
END;
/

------------------------------------------------------------------- 4.2 (2 pts)
-- SP_VALIDAR_DESPACHO
-- Procedimiento que verifique si puede despacharse una cantidad de un producto
-- desde una bodega. Debe declarar una EXCEPCION PROPIA, levantarla con RAISE
-- cuando la cantidad solicitada supere el disponible, y capturarla en el bloque
-- EXCEPTION.
-- Argumente por que conviene nombrar esa condicion en lugar de resolverla con un
-- condicional.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Nombramos la condicion con una excepcion propia  para separar el momento de detectar el problema del momento de resolverlo
-- el IF solo avisa que falta stock, y que se hace queda en la seccion EXCEPTION. Ademas, el nombre deja claro que regla de
-- negocio se incumplio y nos permite atenderla sin tener que usar WHEN OTHERS, que atraparia cualquier otro error por igual.
-- El manejador, ademas de mostrar el disponible, lanza un error con RAISE_APPLICATION_ERROR. Lo hacemos porque, si solo imprimiera,
-- el procedimiento terminaria "bien" y quien lo llamo pensaria que se puede despachar. Ademas, la excepcion e_stock_insuficiente solo existe
-- dentro del procedimiento: si saliera sola, quien llama veria un error generico (ORA-06510) sin saber que paso, mientras que con el error -20141 sabe que fue por falta de stock.

-- Antes de comparar revisamos que la cantidad y la bodega no vengan vacias. Con la cantidad vacia, la comparacion no da verdadero
--ni falso y el procedimiento aprobaria el despacho sin avisar. Aceptamos pedir exactamente lo que hay, y un producto que no existe se rechaza porque su disponible es 0.

-- En la operacion, este procedimiento solo revisa, no reserva: si entre la revision y el despacho otra persona saca ese stock,
-- el despacho real debe volver a revisar bloqueando la fila, como hace SP_AJUSTAR_STOCK. Cada llamada hace una sola consulta, asi que el volumen no es un problema.

CREATE OR REPLACE PROCEDURE SP_VALIDAR_DESPACHO (
    PARAM_idProducto IN NUMBER,
    PARAM_idBodega   IN NUMBER,
    PARAM_cantidad   IN NUMBER
) IS
    e_stock_insuficiente   EXCEPTION;
    vnDisponible           NUMBER;
BEGIN
    IF PARAM_idBodega IS NULL THEN
        RAISE_APPLICATION_ERROR(-20143, 'Debe indicar la bodega desde la cual se despacha');
    END IF;

    IF PARAM_cantidad IS NULL OR PARAM_cantidad <= 0 THEN
        RAISE_APPLICATION_ERROR(-20142, 'La cantidad a despachar debe ser mayor a cero');
    END IF;
    -- consultar lo disponible en esa bodega
    vnDisponible := FN_STOCK_DISPONIBLE(PARAM_idProducto, PARAM_idBodega);
    IF vnDisponible < PARAM_cantidad THEN
        RAISE e_stock_insuficiente;
    END IF;

    DBMS_OUTPUT.PUT_LINE('OK: se pueden despachar ' || PARAM_cantidad || ' unidades (disponible: ' || vnDisponible || ')');
EXCEPTION
    WHEN e_stock_insuficiente THEN
        DBMS_OUTPUT.PUT_LINE('Disponible: ' || vnDisponible);
        RAISE_APPLICATION_ERROR(-20141, 'Stock insuficiente del producto ' || PARAM_idProducto || ' en la bodega ' || PARAM_idBodega || ': disponible ' || vnDisponible || ', solicitado ' || PARAM_cantidad);
END SP_VALIDAR_DESPACHO;
/

DECLARE
    PROCEDURE SP_probarDespacho (
        PARAM_titulo     IN VARCHAR2,
        PARAM_idProducto IN NUMBER,
        PARAM_idBodega   IN NUMBER,
        PARAM_cantidad   IN NUMBER
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(PARAM_titulo);
        SP_VALIDAR_DESPACHO(PARAM_idProducto, PARAM_idBodega, PARAM_cantidad);
    EXCEPTION
        -- Solo en las pruebas: se captura para MOSTRAR el error
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('   Rechazado. SQLCODE=' || SQLCODE || ' | ' || SQLERRM);
    END SP_probarDespacho;
BEGIN
    SP_probarDespacho('Caso 1: 50 unidades del 1001 en bodega 1 (hay 120)',       1001, 1, 50);
    SP_probarDespacho('Caso 2: exactamente lo disponible, 120 del 1001 en bod. 1', 1001, 1, 120);
    SP_probarDespacho('Caso 3: 121 del 1001 en bodega 1 (hay 120) -> rechazado',   1001, 1, 121);
    SP_probarDespacho('Caso 4: 5 del 1005 en bodega 1 (hay 4) -> rechazado',       1005, 1, 5);
    SP_probarDespacho('Caso 5: producto inexistente 9999 -> disponible 0',         9999, 1, 1);
    SP_probarDespacho('Caso 6: cantidad cero -> rechazado',                        1001, 1, 0);
    SP_probarDespacho('Caso 7: cantidad nula -> rechazado (no debe aprobar)',      1001, 1, NULL);
    SP_probarDespacho('Caso 8: bodega nula -> rechazado',                          1001, NULL, 10);
END;
/

------------------------------------------------------------------- 4.3 (2 pts)
-- SP_ANULAR_PEDIDO
-- Procedimiento que anule un pedido, usando RAISE_APPLICATION_ERROR con estos
-- codigos:
--     -20010  el pedido no existe
--     -20011  el pedido ya esta anulado
--     -20012  el pedido tiene mas de 30 dias
-- Explique la diferencia entre RAISE y RAISE_APPLICATION_ERROR, y en que caso el
-- cliente de la base de datos puede distinguirlos.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos RAISE_APPLICATION_ERROR porque el enunciado pide un codigo propio por situacion: asi quien llama sabe que paso con
-- SQLCODE, que vale -20010, -20011 o -20012, sin leer el texto del mensaje. Validamos en este orden: el pedido existe, luego no
-- esta anulado y al final su antiguedad, porque cada paso depende del anterior; un pedido anulado y viejo responde -20011, que es
-- lo mas util. El UPDATE va al final, asi que si algo falla no se modifica nada. El NO_DATA_FOUND se captura en un bloque interno
-- que cubre solo el SELECT. No usamos WHEN OTHERS, porque esconderia otros errores como un fallo de bloqueo. Un id nulo tambien
-- responde -20010.

-- La antiguedad se compara con TRUNC en los dos lados, por dias de calendario: "mas de 30 dias" significa 31 o mas, asi que un
-- pedido de exactamente 30 dias si se anula. Como decision nuestra, solo se cambia el estado a ANULADO, que es lo unico que pide
-- el enunciado; no se devuelve el stock ni se baja el saldo del cliente. En un sistema real habria que hacerlo, por ejemplo con
-- SP_AJUSTAR_STOCK. Tampoco se hace COMMIT, porque le corresponde a quien llama.

-- Diferencia entre RAISE y RAISE_APPLICATION_ERROR: RAISE solo levanta una excepcion que ya existe, sea predefinida como
-- NO_DATA_FOUND o declarada por nosotros, y no lleva numero ni mensaje propios. RAISE_APPLICATION_ERROR crea el error en el
-- momento, con un numero entre -20000 y -20999 y un texto de hasta 2048 bytes. El cliente las distingue cuando una excepcion
-- propia no se captura: con RAISE recibe ORA-06510, con SQLCODE igual a 1, igual para cualquier excepcion propia y sin decir cual
-- fue; con RAISE_APPLICATION_ERROR recibe ORA-20010, ORA-20011 u ORA-20012 con su mensaje y puede reaccionar distinto a cada uno.
-- Con RAISE de una excepcion predefinida llega su codigo normal, como ORA-01403, y tambien se distingue.

-- En concurrencia, el SELECT ... FOR UPDATE bloquea el pedido hasta el COMMIT o ROLLBACK de quien llama: si dos sesiones lo anulan
-- a la vez, la segunda espera y recibe -20011 en lugar de anularlo dos veces. A cambio, puede quedar esperando sin limite. Con
-- NOWAIT fallaria de inmediato. Cada llamada es una lectura y un UPDATE por llave primaria, asi que el volumen no es un problema.

CREATE OR REPLACE PROCEDURE SP_ANULAR_PEDIDO (
    PARAM_idPedido IN NUMBER
) IS
    vvEstado  PEDIDO.estado%TYPE;
    vdFecha   PEDIDO.fecha_pedido%TYPE;
BEGIN
    -- Paso 1: leer y bloquear el pedido. Si no existe, -20010
    BEGIN
        SELECT estado, fecha_pedido
        INTO   vvEstado, vdFecha
        FROM   PEDIDO
        WHERE  id_pedido = PARAM_idPedido
        FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'El pedido ' || NVL(TO_CHAR(PARAM_idPedido), 'inexistente') || ' no existe');
    END;

    -- Paso 2: ya anulado, -20011
    IF vvEstado = 'ANULADO' THEN
        RAISE_APPLICATION_ERROR(-20011, 'El pedido ' || PARAM_idPedido || ' ya esta anulado');
    END IF;

    -- Paso 3: mas de 30 dias de calendario, -20012
    IF TRUNC(SYSDATE) - TRUNC(vdFecha) > 30 THEN
        RAISE_APPLICATION_ERROR(-20012, 'El pedido ' || PARAM_idPedido || ' tiene mas de 30 dias (' ||
                                        (TRUNC(SYSDATE) - TRUNC(vdFecha)) || ' dias) y no se puede anular');
    END IF;

    -- Paso 4: anular
    UPDATE PEDIDO
    SET    estado = 'ANULADO'
    WHERE  id_pedido = PARAM_idPedido;

    DBMS_OUTPUT.PUT_LINE('OK: el pedido ' || PARAM_idPedido || ' quedo ANULADO');
END SP_ANULAR_PEDIDO;
/

DECLARE
    vnIdPedido  NUMBER;
    vvEstado    PEDIDO.estado%TYPE;

    -- Pedido temporal del cliente 501 con la fecha de hace N dias; se revierte al final
    PROCEDURE SP_crearPedidoPrueba (
        PARAM_diasAtras IN  NUMBER,
        PARAM_idPedido  OUT NUMBER
    ) IS
    BEGIN
        INSERT INTO PEDIDO (id_pedido, id_cliente, fecha_pedido, estado, total)
        VALUES (SEQ_PEDIDO.NEXTVAL, 501, SYSDATE - PARAM_diasAtras, 'BORRADOR', 0)
        RETURNING id_pedido INTO PARAM_idPedido;
    END SP_crearPedidoPrueba;

    PROCEDURE SP_probarAnulacion (
        PARAM_titulo   IN VARCHAR2,
        PARAM_idPedido IN NUMBER
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(PARAM_titulo);
        SP_ANULAR_PEDIDO(PARAM_idPedido);
    EXCEPTION
        -- Solo en las pruebas: se captura para MOSTRAR el error
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('   Rechazado. SQLCODE=' || SQLCODE || ' | ' || SQLERRM);
    END SP_probarAnulacion;
BEGIN
    SP_probarAnulacion('Caso 1: pedido inexistente 999 -> -20010',                    999);
    SP_probarAnulacion('Caso 2: pedido nulo -> -20010',                               NULL);
    SP_probarAnulacion('Caso 3: pedido 7 (ya ANULADO) -> -20011',                     7);
    SP_probarAnulacion('Caso 4: pedido 5 (CONFIRMADO, de agosto) -> -20012',          5);

    SP_crearPedidoPrueba(0, vnIdPedido);
    SP_probarAnulacion('Caso 5: pedido nuevo de hoy -> se anula',                     vnIdPedido);
    SELECT estado INTO vvEstado FROM PEDIDO WHERE id_pedido = vnIdPedido;
    DBMS_OUTPUT.PUT_LINE('   Estado en la tabla: ' || vvEstado);
    SP_probarAnulacion('Caso 6: el mismo pedido otra vez -> -20011',                  vnIdPedido);

    SP_crearPedidoPrueba(30, vnIdPedido);
    SP_probarAnulacion('Caso 7: pedido de exactamente 30 dias -> se anula',           vnIdPedido);

    SP_crearPedidoPrueba(31, vnIdPedido);
    SP_probarAnulacion('Caso 8: pedido de 31 dias -> -20012',                         vnIdPedido);

    ROLLBACK;   -- los pedidos temporales y los cambios de estado se revierten
    SELECT estado INTO vvEstado FROM PEDIDO WHERE id_pedido = 7;
    DBMS_OUTPUT.PUT_LINE('Despues del ROLLBACK, pedido 7 sigue en: ' || vvEstado);
END;
/

------------------------------------------------------------------- 4.4 (2 pts)
-- Bloque anonimo que intente insertar un producto con una categoria inexistente
-- y capture el error de integridad referencial asociando ORA-02291 a una
-- excepcion con nombre.
-- Explique que aporta esa asociacion frente a atrapar el error en un manejador
-- generico.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos PRAGMA EXCEPTION_INIT para ligar el error ORA-02291, que indica llave padre no encontrada, a una excepcion con nombre,
-- e_categoria_inexistente, porque Oracle no le da nombre a ese error. Frente a WHEN OTHERS aporta tres cosas: el manejador solo
-- atrapa ese error y los demas, como llave duplicada o valor nulo, siguen su camino sin disfrazarse de "categoria inexistente"; el
-- codigo se lee solo, pues WHEN e_categoria_inexistente dice que se espera que falle; y el numero -2291 queda escrito una sola
-- vez, en la declaracion. Ademas, un WHEN OTHERS que no vuelve a levantar el error oculta fallos inesperados.

-- Como decision nuestra, el bloque no verifica antes si la categoria existe: deja que la llave foranea lo decida, que es el unico
-- control que no se salta ni con inserciones concurrentes. Usamos la categoria 9999, y el Caso 3 repite un codigo duplicado para
-- mostrar que el manejador con nombre no lo atrapa, pues sale ORA-00001. Todo termina en ROLLBACK. Nota: el trigger 5.3,
-- TRG_PRODUCTO_BIU_MARGEN, debe dejar pasar la categoria inexistente para que este bloque siga recibiendo ORA-02291.

DECLARE
    -- Asociacion del error ORA-02291 a una excepcion con nombre
    e_categoria_inexistente EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_categoria_inexistente, -2291);

    vnIdProducto  PRODUCTO.id_producto%TYPE;
    vnRestantes    NUMBER;

    PROCEDURE SP_insertarProductoPrueba (
        PARAM_titulo       IN VARCHAR2,
        PARAM_idCategoria IN NUMBER,
        PARAM_codigo       IN VARCHAR2
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(PARAM_titulo);
        INSERT INTO PRODUCTO (id_producto, codigo, nombre, id_categoria,
                              precio_unitario, costo_unitario, stock_minimo, activo)
        VALUES (SEQ_PRODUCTO.NEXTVAL, PARAM_codigo, 'Producto de prueba 4.4', PARAM_idCategoria,
                1000, 500, 0, 'S')
        RETURNING id_producto INTO vnIdProducto;
        DBMS_OUTPUT.PUT_LINE('   Insertado, id_producto = ' || vnIdProducto);
    EXCEPTION
        WHEN e_categoria_inexistente THEN
            DBMS_OUTPUT.PUT_LINE('   Capturado por e_categoria_inexistente. La categoria ' ||
                                 PARAM_idCategoria || ' no existe');
            DBMS_OUTPUT.PUT_LINE('   SQLCODE=' || SQLCODE || ' | ' || SQLERRM);
    END SP_insertarProductoPrueba;
BEGIN
    SP_insertarProductoPrueba('Caso 1: categoria inexistente 9999 -> e_categoria_inexistente', 9999, 'TST-44-A');

    SP_insertarProductoPrueba('Caso 2: categoria valida 1 y codigo nuevo -> se inserta',       1,    'TST-44-B');

    BEGIN
        SP_insertarProductoPrueba('Caso 3: mismo codigo otra vez -> NO lo atrapa el manejador con nombre', 1, 'TST-44-B');
    EXCEPTION
        WHEN OTHERS THEN
            -- Solo en las pruebas: se captura para MOSTRAR que el error llega sin disfrazar
            DBMS_OUTPUT.PUT_LINE('   Llego al bloque externo. SQLCODE=' || SQLCODE || ' | ' || SQLERRM);
    END;

    ROLLBACK;   -- se revierten los productos de prueba
    SELECT COUNT(*) INTO vnRestantes FROM PRODUCTO WHERE codigo LIKE 'TST-44-%';
    DBMS_OUTPUT.PUT_LINE('Productos TST-44 despues del ROLLBACK: ' || vnRestantes);
END;
/

------------------------------------------------------------------- 4.5 (1 pt)
-- SP_REGISTRAR_ERROR
-- Procedimiento que reciba el origen y registre en LOG_ERRORES el SQLCODE y el
-- SQLERRM actuales. El registro debe persistir aunque la transaccion principal
-- termine en ROLLBACK.
-- Explique por que se requiere esa independencia transaccional y describa un
-- escenario en el que esa misma independencia oculte informacion en lugar de
-- preservarla.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos una transaccion autonoma porque, sin ella, el INSERT del log seria parte de la transaccion principal,
-- y el ROLLBACK que deshace el fallo borraria tambien la evidencia del fallo. Con la autonoma, el procedimiento corre aparte
-- y su COMMIT confirma solo el log, sin tocar lo que esta pendiente en la transaccion principal.
-- El COMMIT es obligatorio: si la transaccion autonoma termina con cambios sin confirmar ni revertir, Oracle da el error ORA-06519.

-- Esa misma independencia puede ocultar informacion. En un proceso que registra un error de valor repetido y luego lo resuelve con un UPDATE,
-- y la transaccion principal termina bien y confirma. El log queda con un "fallo" permanente de algo que en realidad si se completo.
-- Ademas, mirando solo el log no se puede saber si la transaccion principal se confirmo o se revirtio, porque el registro quedo desligado de ella.

-- Guardamos SQLCODE y SQLERRM en variables al inicio, antes de cualquier otra sentencia, porque no se usa directamente dentro de un SQL,
-- y asi nos aseguramos de leer el error que estamos atendiendo. Tambien guardamos el rastro del error para saber donde ocurrio,
-- no solo que ocurrio. Si el propio INSERT del log falla, hacemos ROLLBACK de la transaccion autonoma

-- En la operacion, como la transaccion es aparte, no ve los cambios sin confirmar de la principal y no bloquea sus filas.
-- Cada error agrega un INSERT y un COMMIT extra, asi que una rafaga de errores sumaria carga. La tabla del log crece con el tiempo y
-- necesitaria una limpieza periodica. Debe llamarse siempre dentro de un manejador de excepciones, porque fuera de uno el SQLCODE vale 0 y no hay nada que registrar.

CREATE OR REPLACE PROCEDURE SP_REGISTRAR_ERROR (
    PARAM_origen  IN VARCHAR2,
    PARAM_detalle IN VARCHAR2 DEFAULT NULL
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;

    vnCodigo      NUMBER;
    vvMensaje     LOG_ERRORES.mensaje%TYPE;
    vvBacktrace   VARCHAR2(4000);
    vvDetalle     LOG_ERRORES.detalle%TYPE;
BEGIN
    -- Paso 1: capturar el error actual ANTES de cualquier otra sentencia
    vnCodigo    := SQLCODE;
    vvMensaje   := SUBSTR(SQLERRM, 1, 500);
    vvBacktrace := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
    vvDetalle   := SUBSTR(TRIM(PARAM_detalle || ' ' || REPLACE(vvBacktrace, CHR(10), ' ')), 1, 500);

    -- Paso 2: registrar en una transaccion aparte
    INSERT INTO LOG_ERRORES (id_log, origen, codigo_error, mensaje, detalle)
    VALUES (SEQ_LOG.NEXTVAL, PARAM_origen, vnCodigo, vvMensaje, vvDetalle);

    COMMIT;   -- obligatorio: confirma solo el registro del log
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;   -- obligatorio para cerrar la transaccion autonoma
        DBMS_OUTPUT.PUT_LINE('SP_REGISTRAR_ERROR: no se pudo registrar el error: ' || SQLERRM);
END SP_REGISTRAR_ERROR;
/

DECLARE
    vnIdPedido  NUMBER;
    vnX         NUMBER;
    vnPedidos   NUMBER;
    vnLogs      NUMBER;
    vnMaxLog    NUMBER;
BEGIN
    -- El log persiste entre ejecuciones: se cuentan solo los registros nuevos
    SELECT NVL(MAX(id_log), 0) INTO vnMaxLog FROM LOG_ERRORES;

    -- Trabajo pendiente en la transaccion principal
    INSERT INTO PEDIDO (id_pedido, id_cliente, estado, total)
    VALUES (SEQ_PEDIDO.NEXTVAL, 501, 'BORRADOR', 0)
    RETURNING id_pedido INTO vnIdPedido;
    DBMS_OUTPUT.PUT_LINE('Pedido temporal creado, sin confirmar: ' || vnIdPedido);

    BEGIN
        vnX := 1 / 0;   -- error provocado: ORA-01476
    EXCEPTION
        WHEN ZERO_DIVIDE THEN
            SP_REGISTRAR_ERROR('PRUEBA_4_5', 'division por cero provocada');
            ROLLBACK;   -- la transaccion principal se revierte
    END;

    SELECT COUNT(*) INTO vnPedidos FROM PEDIDO WHERE id_pedido = vnIdPedido;
    SELECT COUNT(*) INTO vnLogs    FROM LOG_ERRORES WHERE origen = 'PRUEBA_4_5' AND id_log > vnMaxLog;
    DBMS_OUTPUT.PUT_LINE('Despues del ROLLBACK -> pedido temporal: ' || vnPedidos ||
                         ' | registros nuevos en el log: ' || vnLogs);

    FOR vrLog IN (SELECT codigo_error, mensaje, detalle
                  FROM   LOG_ERRORES
                  WHERE  origen = 'PRUEBA_4_5'
                  AND    id_log > vnMaxLog) LOOP
        DBMS_OUTPUT.PUT_LINE('   codigo=' || vrLog.codigo_error || ' | ' || vrLog.mensaje);
        DBMS_OUTPUT.PUT_LINE('   detalle=' || vrLog.detalle);
    END LOOP;
END;
/
-- Limpieza opcional de la prueba:
-- DELETE FROM LOG_ERRORES WHERE origen = 'PRUEBA_4_5'; COMMIT;


--==============================================================================
-- PARTE 5 — DISPARADORES                                     (10 puntos / 90 min)
--==============================================================================
-- Los esqueletos de esta parte no incluyen la clausula de disparo. Definirla
-- hace parte del ejercicio.
--==============================================================================

------------------------------------------------------------------- 5.1 (2 pts)
-- TRG_CLIENTE_BI
-- Al insertar un cliente debe asignar el identificador desde SEQ_CLIENTE si
-- llega nulo, convertir el nombre a mayusculas sin espacios sobrantes y forzar
-- el estado activo a 'S' si no se indica.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos un trigger BEFORE INSERT FOR EACH ROW porque los tres ajustes modifican la fila antes de guardarla, es decir :NEW, y un
-- AFTER no lo permite. Corre antes de las restricciones NOT NULL y CHECK, por eso puede corregir un id o un estado nulos sin que
-- el INSERT falle. El id solo se asigna si llega nulo: si se indica uno, como hace el esquema con 501 a 507, se respeta, porque
-- cambiarlo romperia referencias. El estado se trata igual: solo se fuerza 'S' cuando llega nulo y un 'N' explicito se conserva.
-- Si la columna se omite, Oracle ya aplica el DEFAULT 'S' antes del trigger.

-- Para el nombre usamos TRIM y UPPER y, como decision nuestra, tambien REGEXP_REPLACE para dejar un solo espacio entre palabras.
-- Si el nombre llega nulo no lo tocamos y lo rechaza el NOT NULL. El trigger solo actua en INSERT; un UPDATE posterior no
-- normaliza el nombre, y el enunciado no pide cubrirlo. La secuencia es segura en concurrencia, porque dos sesiones nunca reciben
-- el mismo numero, aunque un INSERT revertido deja un hueco en los id. El costo por fila es minimo y no consulta tablas, asi que
-- no hay riesgo de tabla mutante.

CREATE OR REPLACE TRIGGER TRG_CLIENTE_BI
BEFORE INSERT ON CLIENTE
FOR EACH ROW
BEGIN
    -- Identificador desde la secuencia solo si llega nulo
    IF :NEW.id_cliente IS NULL THEN
        :NEW.id_cliente := SEQ_CLIENTE.NEXTVAL;
    END IF;

    -- Nombre en mayusculas, sin espacios al inicio, al final ni repetidos en medio
    IF :NEW.nombre IS NOT NULL THEN
        :NEW.nombre := UPPER(REGEXP_REPLACE(TRIM(:NEW.nombre), ' {2,}', ' '));
    END IF;

    -- Estado activo por defecto
    IF :NEW.activo IS NULL THEN
        :NEW.activo := 'S';
    END IF;
END TRG_CLIENTE_BI;
/

DECLARE
    vnIdCliente  CLIENTE.id_cliente%TYPE;
    vvNombre      CLIENTE.nombre%TYPE;
    vvActivo      CLIENTE.activo%TYPE;

    PROCEDURE SP_mostrarCliente (
        PARAM_titulo IN VARCHAR2
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(PARAM_titulo);
        DBMS_OUTPUT.PUT_LINE('   id=' || vnIdCliente || ' | nombre=[' || vvNombre || '] | activo=' || vvActivo);
    END SP_mostrarCliente;
BEGIN
    -- Caso 1: id nulo, nombre con minusculas y espacios de sobra, estado nulo
    INSERT INTO CLIENTE (id_cliente, documento, nombre, ciudad, cupo_credito, saldo_pendiente, activo)
    VALUES (NULL, '800000001', '   ferreteria   el  sol  ', 'Bogota', 1000000, 0, NULL)
    RETURNING id_cliente, nombre, activo INTO vnIdCliente, vvNombre, vvActivo;
    SP_mostrarCliente('Caso 1: id nulo, nombre sucio, activo nulo -> id de la secuencia, [FERRETERIA EL SOL], S');

    -- Caso 2: columnas id y activo omitidas, activo toma el DEFAULT
    INSERT INTO CLIENTE (documento, nombre, ciudad, cupo_credito, saldo_pendiente)
    VALUES ('800000002', 'tornillos y mas', 'Cali', 500000, 0)
    RETURNING id_cliente, nombre, activo INTO vnIdCliente, vvNombre, vvActivo;
    SP_mostrarCliente('Caso 2: id y activo omitidos -> siguiente id de la secuencia, [TORNILLOS Y MAS], S');

    -- Caso 3: id y estado indicados, se respetan
    INSERT INTO CLIENTE (id_cliente, documento, nombre, ciudad, cupo_credito, saldo_pendiente, activo)
    VALUES (900, '800000003', 'Cliente Inactivo Sa', 'Medellin', 0, 0, 'N')
    RETURNING id_cliente, nombre, activo INTO vnIdCliente, vvNombre, vvActivo;
    SP_mostrarCliente('Caso 3: id 900 y activo N indicados -> se respetan, solo cambia el nombre a mayusculas');

    ROLLBACK;   -- los clientes de prueba se revierten

    SELECT COUNT(*) INTO vnIdCliente FROM CLIENTE WHERE documento LIKE '80000000%';
    DBMS_OUTPUT.PUT_LINE('Clientes de prueba despues del ROLLBACK: ' || vnIdCliente);
END;
/

------------------------------------------------------------------- 5.2 (2 pts)
-- TRG_PRODUCTO_AU_PRECIO
-- Debe registrar en AUDITORIA_PRECIO todo cambio de precio, calculando la
-- variacion porcentual, y dispararse unicamente cuando el precio efectivamente
-- cambie, resolviendo esa condicion con la clausula WHEN y no dentro del cuerpo.
-- Explique la diferencia entre ambas formas.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos un trigger AFTER UPDATE FOR EACH ROW porque la auditoria solo debe quedar si el cambio de precio se guarda: si otro
-- trigger, como 5.3, o una restriccion rechazan el UPDATE, la fila de auditoria se deshace con el. Es de fila porque cada producto
-- tiene su propio precio anterior y nuevo, y una sentencia puede cambiar muchos. Escribe en AUDITORIA_PRECIO y no en PRODUCTO, asi
-- que no hay tabla mutante. UPDATE OF precio_unitario evita evaluarlo cuando el SET no toca esa columna, pero no distingue si el
-- valor cambio; por ejemplo, un SET precio = precio tambien lo activaria. Por eso la condicion real va en WHEN.

-- Diferencia entre WHEN y un IF dentro del cuerpo: el resultado es el mismo, pero con WHEN Oracle evalua la condicion antes de
-- ejecutar el cuerpo y, si es falsa, el bloque PL/SQL no corre, asi que no se paga el cambio de contexto por cada fila sin cambio
-- de precio. Con IF el cuerpo siempre se ejecuta y solo entonces decide no hacer nada. Ademas la condicion queda visible en la
-- cabecera. En WHEN, :OLD y :NEW se escriben sin los dos puntos y solo existe en triggers de fila.

-- La variacion es la diferencia entre el precio nuevo y el anterior, dividida entre el anterior y multiplicada por 100, redondeada
-- a dos decimales. Un descenso queda negativo, y no hay division por cero porque la restriccion exige precio > 0. El usuario y la
-- fecha los llena la tabla con sus DEFAULT y el id sale de SEQ_AUDITORIA. En concurrencia, si dos sesiones cambian el mismo
-- producto, la segunda espera y su auditoria parte del precio ya cambiado.

CREATE OR REPLACE TRIGGER TRG_PRODUCTO_AU_PRECIO
AFTER UPDATE OF precio_unitario ON PRODUCTO
FOR EACH ROW
WHEN (OLD.precio_unitario <> NEW.precio_unitario)
BEGIN
    INSERT INTO AUDITORIA_PRECIO (id_auditoria, id_producto, precio_anterior, precio_nuevo, variacion_pct)
    VALUES (SEQ_AUDITORIA.NEXTVAL,
            :NEW.id_producto,
            :OLD.precio_unitario,
            :NEW.precio_unitario,
            ROUND((:NEW.precio_unitario - :OLD.precio_unitario) / :OLD.precio_unitario * 100, 2));
END TRG_PRODUCTO_AU_PRECIO;
/

DECLARE
    vnFilasAntes  NUMBER;
    vnFilasAhora  NUMBER;
    vnFilasUpd    NUMBER;
    vnAnterior     AUDITORIA_PRECIO.precio_anterior%TYPE;
    vnNuevo        AUDITORIA_PRECIO.precio_nuevo%TYPE;
    vnVariacion    AUDITORIA_PRECIO.variacion_pct%TYPE;

    FUNCTION FN_contarAuditoria RETURN NUMBER IS
        vnTotal NUMBER;
    BEGIN
        SELECT COUNT(*) INTO vnTotal FROM AUDITORIA_PRECIO;
        RETURN vnTotal;
    END FN_contarAuditoria;

    PROCEDURE SP_comparar (
        PARAM_titulo    IN VARCHAR2,
        PARAM_esperadas IN NUMBER,
        PARAM_reales    IN NUMBER
    ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(PARAM_titulo);
        DBMS_OUTPUT.PUT_LINE('   Filas nuevas en AUDITORIA_PRECIO: ' || PARAM_reales || ' (esperadas ' || PARAM_esperadas || ') -> ' ||
                             CASE WHEN PARAM_esperadas = PARAM_reales THEN 'OK' ELSE 'REVISAR' END);
    END SP_comparar;

    PROCEDURE SP_mostrarUltima IS
    BEGIN
        SELECT precio_anterior, precio_nuevo, variacion_pct
        INTO   vnAnterior, vnNuevo, vnVariacion
        FROM   AUDITORIA_PRECIO
        WHERE  id_producto = 1001
        ORDER  BY id_auditoria DESC
        FETCH FIRST 1 ROW ONLY;
        DBMS_OUTPUT.PUT_LINE('   Ultima fila: ' || vnAnterior || ' -> ' || vnNuevo || ' | variacion = ' || vnVariacion || '%');
    END SP_mostrarUltima;
BEGIN
    -- Caso 1: el precio cambia de 45000 a 49500, sube 10%
    vnFilasAntes := FN_contarAuditoria;
    UPDATE PRODUCTO SET precio_unitario = 49500 WHERE id_producto = 1001;
    SP_comparar('Caso 1: cambia el precio del producto 1001 -> se audita', 1, FN_contarAuditoria - vnFilasAntes);
    SP_mostrarUltima;

    -- Caso 2: se escribe el mismo precio, WHEN lo descarta
    vnFilasAntes := FN_contarAuditoria;
    UPDATE PRODUCTO SET precio_unitario = 49500 WHERE id_producto = 1001;
    SP_comparar('Caso 2: mismo precio otra vez -> no se audita', 0, FN_contarAuditoria - vnFilasAntes);

    -- Caso 3: cambia otra columna, el trigger ni se evalua
    vnFilasAntes := FN_contarAuditoria;
    UPDATE PRODUCTO SET stock_minimo = stock_minimo + 1 WHERE id_producto = 1001;
    SP_comparar('Caso 3: cambia solo stock_minimo -> no se audita', 0, FN_contarAuditoria - vnFilasAntes);

    -- Caso 4: el precio baja de 49500 a 40000, variacion negativa
    vnFilasAntes := FN_contarAuditoria;
    UPDATE PRODUCTO SET precio_unitario = 40000 WHERE id_producto = 1001;
    SP_comparar('Caso 4: baja el precio de 1001 -> se audita con variacion negativa', 1, FN_contarAuditoria - vnFilasAntes);
    SP_mostrarUltima;

    -- Caso 5: una sola sentencia cambia varios productos, una fila de auditoria por cada uno
    vnFilasAntes := FN_contarAuditoria;
    UPDATE PRODUCTO SET precio_unitario = precio_unitario * 1.02 WHERE id_categoria = 1;
    vnFilasUpd := SQL%ROWCOUNT;
    vnFilasAhora := FN_contarAuditoria - vnFilasAntes;
    SP_comparar('Caso 5: sube 2% todos los productos de la categoria 1 (' || vnFilasUpd || ' productos)', vnFilasUpd, vnFilasAhora);

    ROLLBACK;   -- los precios y las filas de auditoria de prueba se revierten
    SELECT precio_unitario INTO vnNuevo FROM PRODUCTO WHERE id_producto = 1001;
    DBMS_OUTPUT.PUT_LINE('Despues del ROLLBACK, precio del producto 1001: ' || vnNuevo || ' (original 45000)');
END;
/

------------------------------------------------------------------- 5.3 (2 pts)
-- TRG_PRODUCTO_BIU_MARGEN
-- Debe impedir que se guarde un producto cuyo precio no alcance el margen minimo
-- de su categoria, segun la formula precio >= costo * (1 + margen/100),
-- rechazando la operacion con el error -20020.
-- Considere que debe ocurrir cuando la categoria indicada no existe, y justifique
-- su decision.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Es un trigger BEFORE INSERT OR UPDATE FOR EACH ROW porque la validacion debe ocurrir antes de escribir la fila. Usamos UPDATE OF
-- precio_unitario, costo_unitario, id_categoria porque la regla depende de esas tres columnas, porque subir el costo o cambiar de
-- categoria tambien puede dejar el precio bajo el margen. Si solo cambia stock_minimo o activo, no se ejecuta. Lee CATEGORIA, otra
-- tabla, por eso no hay tabla mutante. La comparacion es precio >= costo * (1 + margen/100) sin redondear, y el precio minimo que
-- muestra el mensaje se redondea hacia arriba con CEIL a dos decimales para que el valor sugerido siempre sea aceptado.

-- Decision nuestra, categoria inexistente: el trigger no lanza -20020. El SELECT da NO_DATA_FOUND, se captura y el trigger termina
-- sin error; la fila la rechaza despues la llave foranea fk_producto_categoria con ORA-02291. Un margen no se puede evaluar sin
-- categoria porque decir "no alcanza el margen" seria un mensaje falso, la FK ya garantiza esa regla y duplicarla crea dos fuentes
-- de verdad, y el punto 4.4 espera justamente ORA-02291. El riesgo es que, si alguien deshabilita la FK, pasaria un producto sin
-- categoria.

-- Error: RAISE_APPLICATION_ERROR deshace la sentencia completa, asi que si un UPDATE masivo, como el de 3.3, deja un solo producto
-- bajo el margen, ninguno se modifica. Volumen: una lectura de CATEGORIA por llave primaria por fila afectada. Concurrencia: no se
-- bloquea CATEGORIA, y si otra sesion sube el margen despues, los productos ya guardados no se revalidan, es decir, la regla no es
-- retroactiva.
-------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER TRG_PRODUCTO_BIU_MARGEN
BEFORE INSERT OR UPDATE OF precio_unitario, costo_unitario, id_categoria
ON PRODUCTO
FOR EACH ROW
DECLARE
    vnMargen        CATEGORIA.margen_minimo%TYPE;
    vnPrecioMinimo NUMBER;
BEGIN
    BEGIN
        SELECT margen_minimo
          INTO vnMargen
          FROM CATEGORIA
         WHERE id_categoria = :NEW.id_categoria;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Categoria inexistente: la rechaza la FK con ORA-02291, ver JUSTIFICACION.
            RETURN;
    END;

    vnPrecioMinimo := :NEW.costo_unitario * (1 + vnMargen / 100);

    IF :NEW.precio_unitario < vnPrecioMinimo THEN
        RAISE_APPLICATION_ERROR(-20020,
            'Margen insuficiente en producto ' || :NEW.codigo ||
            ': precio ' || :NEW.precio_unitario ||
            ' < minimo ' || (CEIL(vnPrecioMinimo * 100) / 100) ||
            ' (costo ' || :NEW.costo_unitario || ' + margen ' || vnMargen || '%)');
    END IF;
END TRG_PRODUCTO_BIU_MARGEN;
/
SHOW ERRORS TRIGGER TRG_PRODUCTO_BIU_MARGEN

------------------------------------------------------------------- PRUEBA 5.3
-- Categoria 1 = Herramienta manual, margen 25%.
-- Producto 1001: costo 28000 -> precio minimo 35000. Precio actual 45000.
DECLARE
    vnPrecio PRODUCTO.precio_unitario%TYPE;
    PROCEDURE SP_probarMargen (
        PARAM_caso            IN VARCHAR2,
        PARAM_esperado        IN NUMBER,
        PARAM_sql             IN VARCHAR2
    ) IS
        vnCodigo NUMBER := 0;
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE PARAM_sql;
        EXCEPTION
            WHEN OTHERS THEN vnCodigo := SQLCODE;
        END;
        DBMS_OUTPUT.PUT_LINE(PARAM_caso || ' -> codigo=' || vnCodigo ||
            ' (esperado ' || PARAM_esperado || ') ' ||
            CASE WHEN vnCodigo = PARAM_esperado THEN 'OK' ELSE 'REVISAR' END);
    END SP_probarMargen;
BEGIN
    -- Insert exacto en el limite: 10000 * 1.25 = 12500, debe pasar
    SP_probarMargen('Caso 1: INSERT en el limite del margen (12500)', 0,
      'INSERT INTO PRODUCTO VALUES (9001,''TEST-9001'',''Prueba margen'',1,12500,10000,5,''S'')');

    -- Un peso por debajo del limite
    SP_probarMargen('Caso 2: INSERT por debajo del margen (12499)', -20020,
      'INSERT INTO PRODUCTO VALUES (9002,''TEST-9002'',''Prueba margen'',1,12499,10000,5,''S'')');

    -- UPDATE bajando el precio de 1001 por debajo de 35000
    SP_probarMargen('Caso 3: UPDATE precio de 1001 a 30000', -20020,
      'UPDATE PRODUCTO SET precio_unitario = 30000 WHERE id_producto = 1001');

    -- UPDATE subiendo el costo: 40000 * 1.25 = 50000 > precio 45000
    SP_probarMargen('Caso 4: UPDATE costo de 1001 a 40000 (precio queda corto)', -20020,
      'UPDATE PRODUCTO SET costo_unitario = 40000 WHERE id_producto = 1001');

    -- UPDATE cambiando a categoria con mayor margen: cat 4 = 35%, 28000*1.35 = 37800 <= 45000, pasa
    SP_probarMargen('Caso 5: UPDATE de categoria con margen cumplido', 0,
      'UPDATE PRODUCTO SET id_categoria = 4 WHERE id_producto = 1001');

    -- UPDATE de columna que no interviene: el trigger ni se ejecuta
    SP_probarMargen('Caso 6: UPDATE solo de stock_minimo', 0,
      'UPDATE PRODUCTO SET stock_minimo = 21 WHERE id_producto = 1001');

    -- Categoria inexistente: debe responder la FK, no el trigger
    SP_probarMargen('Caso 7: INSERT con categoria 999 (debe fallar la FK)', -2291,
      'INSERT INTO PRODUCTO VALUES (9003,''TEST-9003'',''Prueba cat'',999,50000,10000,5,''S'')');

    ROLLBACK;
    SELECT precio_unitario INTO vnPrecio FROM PRODUCTO WHERE id_producto = 1001;
    DBMS_OUTPUT.PUT_LINE('Precio de 1001 tras ROLLBACK: ' || vnPrecio);
END;
/

------------------------------------------------------------------- 5.4 (2 pts)
-- TRG_DETALLE_AI_STOCK
-- Al insertar una linea de pedido debe descontar el stock de la bodega indicada
-- y registrar el movimiento de SALIDA correspondiente. Si no hay stock suficiente
-- debe abortar la operacion con el error -20030.
-- Explique por que el momento de disparo que eligio es el correcto y que dejaria
-- de funcionar con el contrario.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos AFTER INSERT FOR EACH ROW porque, cuando corre, la linea ya paso las restricciones de la tabla, como cantidad mayor que 0
-- y las llaves foraneas, y sus valores son los definitivos. Con BEFORE se moveria inventario con datos todavia provisionales: una
-- linea con producto o bodega inexistentes ya habria descontado stock y registrado una SALIDA antes de ser rechazada, y el
-- movimiento apuntaria a una linea que aun no existe. Si el trigger lanza -20030, Oracle deshace el INSERT de la linea y todo lo
-- que el trigger alcanzo a hacer, asi que no quedan descuentos a medias.

-- El descuento es un solo UPDATE con la condicion cantidad >= :NEW.cantidad: verificar y descontar en una sentencia evita que dos
-- sesiones vendan la misma unidad, porque con SELECT y luego UPDATE habria una ventana de carrera. Si el UPDATE toca 0 filas, no
-- hay stock suficiente o la combinacion bodega-producto no existe. Decision nuestra: no llamamos a SP_AJUSTAR_STOCK para no
-- acoplar este trigger a otro objeto del taller. No hay tabla mutante porque el trigger es sobre DETALLE_PEDIDO y solo modifica
-- EXISTENCIA y MOVIMIENTO_INVENTARIO.
-------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER TRG_DETALLE_AI_STOCK
AFTER INSERT ON DETALLE_PEDIDO
FOR EACH ROW
DECLARE
    vnDisponible EXISTENCIA.cantidad%TYPE;
BEGIN
    UPDATE EXISTENCIA
       SET cantidad = cantidad - :NEW.cantidad
     WHERE id_bodega   = :NEW.id_bodega
       AND id_producto = :NEW.id_producto
       AND cantidad   >= :NEW.cantidad;

    IF SQL%ROWCOUNT = 0 THEN
        -- Se distingue la causa solo para dar un mensaje claro
        BEGIN
            SELECT cantidad
              INTO vnDisponible
              FROM EXISTENCIA
             WHERE id_bodega   = :NEW.id_bodega
               AND id_producto = :NEW.id_producto;

            RAISE_APPLICATION_ERROR(-20030,
                'Stock insuficiente: producto ' || :NEW.id_producto ||
                ' en bodega ' || :NEW.id_bodega ||
                ', disponible ' || vnDisponible ||
                ', solicitado ' || :NEW.cantidad);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20030,
                    'Sin existencia: el producto ' || :NEW.id_producto ||
                    ' no tiene stock registrado en la bodega ' || :NEW.id_bodega);
        END;
    END IF;

    INSERT INTO MOVIMIENTO_INVENTARIO
        (id_movimiento, id_producto, id_bodega, tipo, cantidad, id_pedido, observacion)
    VALUES
        (SEQ_MOVIMIENTO.NEXTVAL, :NEW.id_producto, :NEW.id_bodega, 'SALIDA',
         :NEW.cantidad, :NEW.id_pedido,
         'Salida por linea ' || :NEW.linea || ' del pedido ' || :NEW.id_pedido);
END TRG_DETALLE_AI_STOCK;
/
SHOW ERRORS TRIGGER TRG_DETALLE_AI_STOCK

------------------------------------------------------------------- PRUEBA 5.4
-- Se usa el pedido 6 BORRADOR del cliente 501, que no tiene lineas.
-- Stock inicial: 1001 en bodega 1 = 120 | 1005 en bodega 1 = 4 | 1006 en bodega 4 = 6
DECLARE
    FUNCTION FN_stockDe (
        PARAM_prod            IN NUMBER,
        PARAM_bod             IN NUMBER
    ) RETURN NUMBER IS
        vnValor NUMBER;
    BEGIN
        SELECT cantidad INTO vnValor FROM EXISTENCIA
         WHERE id_producto = PARAM_prod AND id_bodega = PARAM_bod;
        RETURN vnValor;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
    END FN_stockDe;

    FUNCTION FN_movsDe (
        PARAM_prod            IN NUMBER,
        PARAM_bod             IN NUMBER
    ) RETURN NUMBER IS
        vnValor NUMBER;
    BEGIN
        SELECT COUNT(*) INTO vnValor FROM MOVIMIENTO_INVENTARIO
         WHERE id_pedido = 6 AND id_producto = PARAM_prod AND id_bodega = PARAM_bod
           AND tipo = 'SALIDA';
        RETURN vnValor;
    END FN_movsDe;

    PROCEDURE SP_probarSalida (
        PARAM_caso            IN VARCHAR2,
        PARAM_esperado        IN NUMBER,
        PARAM_linea           IN NUMBER,
        PARAM_prod            IN NUMBER,
        PARAM_bod             IN NUMBER,
        PARAM_cant            IN NUMBER,
        PARAM_precio          IN NUMBER,
        PARAM_stockFinal     IN NUMBER,
        PARAM_movsFinal      IN NUMBER
    ) IS
        vnCodigo  NUMBER := 0;
        vnStock   NUMBER;
        vnMovs    NUMBER;
    BEGIN
        BEGIN
            INSERT INTO DETALLE_PEDIDO
                (id_pedido, linea, id_producto, id_bodega, cantidad, precio_unitario, subtotal)
            VALUES (6, PARAM_linea, PARAM_prod, PARAM_bod, PARAM_cant, PARAM_precio, PARAM_cant * PARAM_precio);
        EXCEPTION
            WHEN OTHERS THEN vnCodigo := SQLCODE;
        END;
        vnStock := FN_stockDe(PARAM_prod, PARAM_bod);
        vnMovs := FN_movsDe(PARAM_prod, PARAM_bod);
        DBMS_OUTPUT.PUT_LINE(PARAM_caso);
        DBMS_OUTPUT.PUT_LINE('   codigo=' || vnCodigo || ' (esperado ' || PARAM_esperado ||
            ') | stock=' || NVL(TO_CHAR(vnStock), 'sin fila') || ' (esperado ' ||
            NVL(TO_CHAR(PARAM_stockFinal), 'sin fila') || ') | movimientos=' || vnMovs ||
            ' (esperado ' || PARAM_movsFinal || ') -> ' ||
            CASE WHEN vnCodigo = PARAM_esperado
                  AND (vnStock = PARAM_stockFinal OR (vnStock IS NULL AND PARAM_stockFinal IS NULL))
                  AND vnMovs = PARAM_movsFinal
                 THEN 'OK' ELSE 'REVISAR' END);
    END SP_probarSalida;
BEGIN
    -- Caso 1: venta normal, 120 - 10 = 110 y un movimiento
    SP_probarSalida('Caso 1: 10 uds de 1001 en bodega 1', 0, 1, 1001, 1, 10, 45000, 110, 1);

    -- Caso 2: vende justo todo lo que hay en 1005, que son 4, queda en 0
    SP_probarSalida('Caso 2: 4 uds de 1005 en bodega 1 (todo el stock)', 0, 2, 1005, 1, 4, 285000, 0, 1);

    -- Caso 3: ahora no queda nada, una unidad mas debe rechazarse
    SP_probarSalida('Caso 3: 1 ud mas de 1005 (stock 0)', -20030, 3, 1005, 1, 1, 285000, 0, 1);

    -- Caso 4: pide mas de lo que hay, 1006 en bodega 4 tiene 6 y pide 7
    SP_probarSalida('Caso 4: 7 uds de 1006 en bodega 4 (hay 6)', -20030, 3, 1006, 4, 7, 480000, 6, 0);

    -- Caso 5: la combinacion producto-bodega no existe, 1001 no esta en bodega 3
    SP_probarSalida('Caso 5: 1001 en bodega 3 (sin existencia)', -20030, 3, 1001, 3, 1, 45000, NULL, 0);

    ROLLBACK;

    DBMS_OUTPUT.PUT_LINE('Tras ROLLBACK: 1001/b1=' || FN_stockDe(1001, 1) ||
        ' | 1005/b1=' || FN_stockDe(1005, 1) ||
        ' | 1006/b4=' || FN_stockDe(1006, 4) ||
        ' | movimientos 1001/b1=' || FN_movsDe(1001, 1));
END;
/

------------------------------------------------------------------- 5.5 (1 pt)
-- TRG_DETALLE_TOTAL
-- Debe recalcular el total de la cabecera del pedido despues de cualquier
-- insercion, actualizacion o borrado de sus lineas.
-- Documente el error que obtiene en su primer intento, en que momento aparece,
-- y como lo resuelve la construccion que finalmente utilizo.
-- Este punto no se califica sin esa explicacion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Primer intento: un trigger normal AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW que en cada fila hacia un UPDATE de PEDIDO con
-- el total calculado por un SELECT con SUM de subtotal sobre DETALLE_PEDIDO. Compila bien, pero al ejecutar un UPDATE o DELETE
-- sobre DETALLE_PEDIDO falla con ORA-04091, tabla mutante. Ese es el error: mientras la sentencia todavia esta modificando la
-- tabla, un trigger de fila no puede leerla, porque veria una tabla a medias, con unas filas ya cambiadas y otras no, y el
-- resultado dependeria del orden en que Oracle procese las filas. Aparece en tiempo de ejecucion, no al crear el trigger.

-- Como lo evita el COMPOUND TRIGGER: agrupa varios momentos de disparo en un objeto que comparte variables. En AFTER EACH ROW no
-- consulta la tabla: solo anota en una coleccion en memoria el id_pedido de cada linea tocada, porque leer :NEW y :OLD si es
-- permitido. En AFTER STATEMENT la sentencia ya termino de modificar la tabla, asi que ya no esta mutando y el SELECT con SUM de
-- subtotal es legal y ve el estado final. La coleccion es el puente entre ambos momentos y, al indexarse por id_pedido, cada
-- pedido se recalcula una sola vez por sentencia.

-- Decisiones: en UPDATE se anotan :OLD.id_pedido y :NEW.id_pedido por si una linea cambia de pedido, y NVL deja el total en 0 si
-- se borran todas las lineas. Volumen: un UPDATE de 1000 lineas de 10 pedidos hace 10 recalculos, no 1000. Concurrencia: dos
-- sesiones sobre el mismo pedido actualizan la misma fila de PEDIDO y la segunda espera al COMMIT o ROLLBACK de la primera. Si
-- algo falla, Oracle deshace la sentencia completa. El trigger recalcula sin mirar el estado del pedido, porque el enunciado no
-- pide restringirlo.
-------------------------------------------------------------------------------

------------------------------------------------------------------- PARTE A
-- Evidencia del primer intento con trigger de fila. Sirve para capturar el error
-- real ORA-04091 y citarlo en la justificacion.
CREATE OR REPLACE TRIGGER TRG_DETALLE_TOTAL_INTENTO1
AFTER INSERT OR UPDATE OR DELETE ON DETALLE_PEDIDO
FOR EACH ROW
DECLARE
    vnPedido DETALLE_PEDIDO.id_pedido%TYPE := NVL(:NEW.id_pedido, :OLD.id_pedido);
BEGIN
    UPDATE PEDIDO
       SET total = (SELECT NVL(SUM(subtotal), 0)
                      FROM DETALLE_PEDIDO
                     WHERE id_pedido = vnPedido)
     WHERE id_pedido = vnPedido;
END;
/
SHOW ERRORS TRIGGER TRG_DETALLE_TOTAL_INTENTO1

BEGIN
    -- El trigger compilo bien; el error aparece al ejecutar el UPDATE
    UPDATE DETALLE_PEDIDO SET subtotal = subtotal WHERE id_pedido = 1;
    DBMS_OUTPUT.PUT_LINE('Primer intento: no hubo error (REVISAR)');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Primer intento -> SQLCODE=' || SQLCODE);
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/
ROLLBACK;

-- El intento fallido se elimina para que no quede activo junto al definitivo
DROP TRIGGER TRG_DETALLE_TOTAL_INTENTO1;

------------------------------------------------------------------- PARTE B
-- Solucion definitiva
CREATE OR REPLACE TRIGGER TRG_DETALLE_TOTAL
FOR INSERT OR UPDATE OR DELETE ON DETALLE_PEDIDO
COMPOUND TRIGGER

    TYPE tbIdPedido IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    vtIdPedido tbIdPedido;   -- pedidos afectados por la sentencia, con clave id_pedido

    AFTER EACH ROW IS
    BEGIN
        IF INSERTING OR UPDATING THEN
            vtIdPedido(:NEW.id_pedido) := :NEW.id_pedido;
        END IF;
        IF DELETING OR UPDATING THEN
            vtIdPedido(:OLD.id_pedido) := :OLD.id_pedido;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        vnId PLS_INTEGER;
    BEGIN
        vnId := vtIdPedido.FIRST;
        WHILE vnId IS NOT NULL LOOP
            UPDATE PEDIDO
               SET total = (SELECT NVL(SUM(subtotal), 0)
                              FROM DETALLE_PEDIDO
                             WHERE id_pedido = vnId)
             WHERE id_pedido = vnId;
            vnId := vtIdPedido.NEXT(vnId);
        END LOOP;
        vtIdPedido.DELETE;
    END AFTER STATEMENT;

END TRG_DETALLE_TOTAL;
/
SHOW ERRORS TRIGGER TRG_DETALLE_TOTAL

------------------------------------------------------------------- PRUEBA 5.5
-- Pedido 6: BORRADOR, total inicial 0, sin lineas.
-- Pedidos 1 y 2: CONFIRMADOS, totales 1286500 y 641000.
DECLARE
    FUNCTION FN_totalDe (
        PARAM_pedido          IN NUMBER
    ) RETURN NUMBER IS
        vnValor NUMBER;
    BEGIN
        SELECT total INTO vnValor FROM PEDIDO WHERE id_pedido = PARAM_pedido;
        RETURN vnValor;
    END FN_totalDe;

    PROCEDURE SP_verificar (
        PARAM_caso            IN VARCHAR2,
        PARAM_pedido          IN NUMBER,
        PARAM_esperado        IN NUMBER
    ) IS
        vnValor NUMBER := FN_totalDe(PARAM_pedido);
    BEGIN
        DBMS_OUTPUT.PUT_LINE(PARAM_caso || ' -> pedido ' || PARAM_pedido ||
            ' total=' || vnValor || ' (esperado ' || PARAM_esperado || ') ' ||
            CASE WHEN vnValor = PARAM_esperado THEN 'OK' ELSE 'REVISAR' END);
    END SP_verificar;
BEGIN
    SP_verificar('Inicio', 6, 0);

    -- Caso 1: un solo INSERT de dos lineas: 2*45000 + 1*62000 = 152000
    INSERT INTO DETALLE_PEDIDO
        (id_pedido, linea, id_producto, id_bodega, cantidad, precio_unitario, subtotal)
    SELECT 6, 1, 1001, 1, 2, 45000, 90000 FROM DUAL
    UNION ALL
    SELECT 6, 2, 1002, 1, 1, 62000, 62000 FROM DUAL;
    SP_verificar('Caso 1: INSERT de 2 lineas en una sentencia', 6, 152000);

    -- Caso 2: UPDATE de la linea 1 a 3 unidades: 135000 + 62000 = 197000
    UPDATE DETALLE_PEDIDO
       SET cantidad = 3, subtotal = 135000
     WHERE id_pedido = 6 AND linea = 1;
    SP_verificar('Caso 2: UPDATE de una linea', 6, 197000);

    -- Caso 3: DELETE de la linea 2: queda 135000
    DELETE FROM DETALLE_PEDIDO WHERE id_pedido = 6 AND linea = 2;
    SP_verificar('Caso 3: DELETE de una linea', 6, 135000);

    -- Caso 4: una sola sentencia que toca dos pedidos distintos, +1000 a cada uno
    UPDATE DETALLE_PEDIDO
       SET subtotal = subtotal + 1000
     WHERE id_pedido IN (1, 2) AND linea = 1;
    SP_verificar('Caso 4: UPDATE sobre pedidos 1 y 2 (pedido 1)', 1, 1287500);
    SP_verificar('Caso 4: UPDATE sobre pedidos 1 y 2 (pedido 2)', 2, 642000);

    -- Caso 5: se borran todas las lineas del pedido 6: el total debe quedar en 0
    DELETE FROM DETALLE_PEDIDO WHERE id_pedido = 6;
    SP_verificar('Caso 5: DELETE de todas las lineas', 6, 0);

    ROLLBACK;

    DBMS_OUTPUT.PUT_LINE('Tras ROLLBACK: pedido 1=' || FN_totalDe(1) ||
        ' | pedido 2=' || FN_totalDe(2) || ' | pedido 6=' || FN_totalDe(6));
END;
/

------------------------------------------------------------------- 5.6 (1 pt)
-- TRG_V_STOCK_IO
-- Debe permitir actualizar el precio y el stock minimo del producto a traves de
-- la vista V_STOCK_CONSOLIDADO.
-- Explique por que esa vista no es actualizable de forma directa.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- La vista V_STOCK_CONSOLIDADO no es actualizable de forma directa porque une PRODUCTO, CATEGORIA y EXISTENCIA y agrupa con GROUP
-- BY para calcular stock_total, que es la suma de cantidad. Oracle rechaza el UPDATE con ORA-01732 por tres razones: cada fila de
-- la vista resume varias filas de EXISTENCIA, una por bodega, asi que no hay correspondencia 1 a 1 con una fila de tabla;
-- stock_total es una columna calculada que no existe almacenada; y tras agrupar la vista pierde la preservacion de llave que
-- Oracle exige para modificar a traves de un join. La Parte A deja ese error como evidencia.

-- El trigger INSTEAD OF reemplaza la accion que Oracle no sabe ejecutar: en lugar de modificar la vista, corre su cuerpo, que
-- actualiza PRODUCTO con :OLD.id_producto, que es la llave que la vista si expone. Es de fila y se dispara una vez por cada fila
-- de la vista alcanzada. Decisiones: solo se propagan precio_unitario y stock_minimo, y si el UPDATE intenta cambiar otra columna
-- se rechaza con -20050 en vez de ignorarlo en silencio. Como actua sobre PRODUCTO, siguen aplicando TRG_PRODUCTO_BIU_MARGEN, que
-- da -20020, y TRG_PRODUCTO_AU_PRECIO, y si alguno rechaza el cambio el UPDATE sobre la vista falla completo.

-- Volumen: un UPDATE que alcance N filas ejecuta el trigger N veces; para cambios masivos conviene actualizar PRODUCTO
-- directamente. Concurrencia: cada UPDATE sobre PRODUCTO bloquea esa fila hasta el COMMIT o ROLLBACK. Limitacion: el trigger
-- escribe las dos columnas aunque el UPDATE cambie solo una, con los valores leidos al inicio, asi que podria pisar un cambio
-- confirmado por otra sesion en la otra columna.
-------------------------------------------------------------------------------

------------------------------------------------------------------- PARTE A
-- Evidencia: el UPDATE directo sobre la vista falla, antes de crear el trigger.
-- Si el trigger ya existe de una ejecucion anterior, se elimina primero.
BEGIN
    EXECUTE IMMEDIATE 'DROP TRIGGER TRG_V_STOCK_IO';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -4080 THEN RAISE; END IF;   -- -4080: el trigger no existe
END;
/

BEGIN
    UPDATE V_STOCK_CONSOLIDADO SET precio_unitario = 50000 WHERE id_producto = 1001;
    DBMS_OUTPUT.PUT_LINE('UPDATE directo: no hubo error (REVISAR)');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('UPDATE directo sobre la vista -> SQLCODE=' || SQLCODE);
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/
ROLLBACK;

------------------------------------------------------------------- PARTE B
CREATE OR REPLACE TRIGGER TRG_V_STOCK_IO
INSTEAD OF UPDATE ON V_STOCK_CONSOLIDADO
FOR EACH ROW
BEGIN
    -- Solo precio y stock minimo son modificables a traves de la vista
    IF :NEW.id_producto <> :OLD.id_producto
       OR :NEW.codigo      <> :OLD.codigo
       OR :NEW.producto    <> :OLD.producto
       OR :NEW.categoria   <> :OLD.categoria
       OR :NEW.stock_total <> :OLD.stock_total THEN
        RAISE_APPLICATION_ERROR(-20050,
            'Solo se pueden actualizar precio_unitario y stock_minimo desde V_STOCK_CONSOLIDADO');
    END IF;

    UPDATE PRODUCTO
       SET precio_unitario = :NEW.precio_unitario,
           stock_minimo    = :NEW.stock_minimo
     WHERE id_producto = :OLD.id_producto;
END TRG_V_STOCK_IO;
/
SHOW ERRORS TRIGGER TRG_V_STOCK_IO

------------------------------------------------------------------- PRUEBA 5.6
-- Producto 1001: precio 45000, costo 28000, minimo 35000 en categoria 1,
-- stock_minimo 20. Categoria 'Herramienta manual': 1001, 1002, 1003 y 1015.
DECLARE
    vnFilas    NUMBER;
    vnCodigo   NUMBER;
    vnAudIni  NUMBER;
    vnAudFin  NUMBER;
    vnPrecio   NUMBER;
    vnMinimo   NUMBER;

    FUNCTION FN_auditorias RETURN NUMBER IS
        vnValor NUMBER;
    BEGIN
        SELECT COUNT(*) INTO vnValor FROM AUDITORIA_PRECIO WHERE id_producto = 1001;
        RETURN vnValor;
    END FN_auditorias;

    PROCEDURE SP_leer1001 IS
    BEGIN
        SELECT precio_unitario, stock_minimo INTO vnPrecio, vnMinimo
          FROM PRODUCTO WHERE id_producto = 1001;
    END SP_leer1001;

    PROCEDURE SP_ejecutar (
        PARAM_sql             IN VARCHAR2
    ) IS
    BEGIN
        vnCodigo := 0;
        vnFilas  := 0;
        EXECUTE IMMEDIATE PARAM_sql;
        vnFilas := SQL%ROWCOUNT;
    EXCEPTION
        WHEN OTHERS THEN vnCodigo := SQLCODE;
    END SP_ejecutar;
BEGIN
    -- Caso 1: cambia precio y stock minimo a la vez
    vnAudIni := FN_auditorias;
    SP_ejecutar('UPDATE V_STOCK_CONSOLIDADO SET precio_unitario = 50000, stock_minimo = 25 ' ||
             'WHERE id_producto = 1001');
    SP_leer1001;
    vnAudFin := FN_auditorias;
    DBMS_OUTPUT.PUT_LINE('Caso 1: precio y stock_minimo por la vista -> filas=' || vnFilas ||
        ' precio=' || vnPrecio || ' stock_minimo=' || vnMinimo ||
        ' auditorias nuevas=' || (vnAudFin - vnAudIni) || ' ' ||
        CASE WHEN vnCodigo = 0 AND vnFilas = 1 AND vnPrecio = 50000 AND vnMinimo = 25
                  AND vnAudFin - vnAudIni = 1 THEN 'OK' ELSE 'REVISAR' END);

    -- Caso 2: solo stock minimo, el precio no cambia, no debe auditar
    vnAudIni := FN_auditorias;
    SP_ejecutar('UPDATE V_STOCK_CONSOLIDADO SET stock_minimo = 30 WHERE id_producto = 1001');
    SP_leer1001;
    vnAudFin := FN_auditorias;
    DBMS_OUTPUT.PUT_LINE('Caso 2: solo stock_minimo -> filas=' || vnFilas ||
        ' precio=' || vnPrecio || ' stock_minimo=' || vnMinimo ||
        ' auditorias nuevas=' || (vnAudFin - vnAudIni) || ' ' ||
        CASE WHEN vnCodigo = 0 AND vnFilas = 1 AND vnPrecio = 50000 AND vnMinimo = 30
                  AND vnAudFin - vnAudIni = 0 THEN 'OK' ELSE 'REVISAR' END);

    -- Caso 3: precio bajo el margen -> responde TRG_PRODUCTO_BIU_MARGEN
    SP_ejecutar('UPDATE V_STOCK_CONSOLIDADO SET precio_unitario = 30000 WHERE id_producto = 1001');
    DBMS_OUTPUT.PUT_LINE('Caso 3: precio bajo el margen -> codigo=' || vnCodigo ||
        ' (esperado -20020) ' || CASE WHEN vnCodigo = -20020 THEN 'OK' ELSE 'REVISAR' END);

    -- Caso 4: intento de modificar la columna calculada
    SP_ejecutar('UPDATE V_STOCK_CONSOLIDADO SET stock_total = 999 WHERE id_producto = 1001');
    DBMS_OUTPUT.PUT_LINE('Caso 4: modificar stock_total -> codigo=' || vnCodigo ||
        ' (esperado -20050) ' || CASE WHEN vnCodigo = -20050 THEN 'OK' ELSE 'REVISAR' END);

    -- Caso 5: una sentencia que alcanza varias filas de la vista
    SP_ejecutar('UPDATE V_STOCK_CONSOLIDADO SET stock_minimo = stock_minimo + 1 ' ||
             'WHERE categoria = ''Herramienta manual''');
    DBMS_OUTPUT.PUT_LINE('Caso 5: categoria completa -> filas=' || vnFilas ||
        ' (esperado 4) ' || CASE WHEN vnCodigo = 0 AND vnFilas = 4 THEN 'OK' ELSE 'REVISAR' END);

    -- Caso 6: producto que no existe
    SP_ejecutar('UPDATE V_STOCK_CONSOLIDADO SET stock_minimo = 5 WHERE id_producto = 99999');
    DBMS_OUTPUT.PUT_LINE('Caso 6: producto inexistente -> filas=' || vnFilas ||
        ' (esperado 0) ' || CASE WHEN vnCodigo = 0 AND vnFilas = 0 THEN 'OK' ELSE 'REVISAR' END);

    ROLLBACK;

    SP_leer1001;
    DBMS_OUTPUT.PUT_LINE('Tras ROLLBACK: precio de 1001=' || vnPrecio ||
        ' | stock_minimo=' || vnMinimo || ' | auditorias=' || FN_auditorias);
END;
/


--==============================================================================
-- PARTE 6 — CASO INTEGRADOR                                   (5 puntos / 45 min)
--==============================================================================

-------------------------------------------------------------------------------
-- PKG_VENTAS
-- Construya un PAQUETE que exponga el procedimiento SP_FACTURAR_PEDIDO, el cual,
-- para un pedido en estado BORRADOR, debe:
--
--   1. Validar que el pedido exista y este en BORRADOR
--   2. Recorrer sus lineas con un cursor y acumular el subtotal
--   3. Calcular el descuento con FN_CALCULAR_DESCUENTO
--   4. Validar contra FN_CUPO_DISPONIBLE que el cliente tenga cupo suficiente
--   5. Actualizar el total del pedido y cambiar su estado a CONFIRMADO
--   6. Incrementar el saldo pendiente del cliente
--   7. Usar SAVEPOINT y revertir parcialmente ante cualquier fallo, registrando
--      el error con SP_REGISTRAR_ERROR
--   8. Devolver por parametros OUT el total facturado y el descuento aplicado
--
-- Firma esperada:
--   PKG_VENTAS.SP_FACTURAR_PEDIDO(p_id_pedido IN NUMBER,
--                                 p_total     OUT NUMBER,
--                                 p_descuento OUT NUMBER)
--
-- Se evalua la integracion. El procedimiento debe apoyarse en los objetos de las
-- partes 1 a 5 y no reimplementar su logica: uno que vuelva a codificar el
-- calculo del descuento pierde la mitad del puntaje de esta parte.
-- Defina explicitamente el alcance transaccional y justifique donde decidio
-- ubicar la confirmacion de la transaccion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos un paquete para agrupar el proceso. La especificacion solo expone SP_FACTURAR_PEDIDO y el cursor queda privado en el cuerpo.
-- El procedimiento no recalcula nada que ya exista: el descuento sale de FN_CALCULAR_DESCUENTO, el cupo de FN_CUPO_DISPONIBLE y los
-- errores se guardan con SP_REGISTRAR_ERROR. Tampoco toca el inventario, porque TRG_DETALLE_AI_STOCK ya lo desconto al insertar cada
-- linea y descontarlo otra vez duplicaria la salida. El subtotal lo sumamos con el cursor y no leemos PEDIDO.total, que es un dato derivado.

-- El descuento y el cupo se calculan antes de subir el saldo del cliente. Si el saldo subiera primero, FN_CALCULAR_DESCUENTO ya no
-- veria al cliente sin saldo y perderia el 2% adicional. El cupo se compara con el total ya con descuento, porque eso es lo que el cliente
-- va a deber. Como decision nuestra, PEDIDO.total queda con el valor neto y el descuento sale por el parametro OUT, ya que no hay columna
-- para guardarlo. Un pedido sin lineas se rechaza, porque confirmaria un pedido de 0 pesos. Los errores propios son -20060 pedido
-- inexistente, -20061 pedido que no esta en BORRADOR, -20062 pedido sin lineas y -20063 cupo insuficiente.

-- Alcance transaccional: la unidad de trabajo empieza en el SAVEPOINT sp_facturar, que es la primera sentencia, y termina en el UPDATE
-- del saldo. Ante cualquier error el manejador registra el error, hace ROLLBACK TO SAVEPOINT y relanza con RAISE. Asi se revierte solo
-- lo que hizo este procedimiento y se conserva lo que quien llama hizo antes. El registro del error sobrevive porque SP_REGISTRAR_ERROR
-- es autonoma. El COMMIT no va dentro del procedimiento sino en quien lo llama, porque facturar es un paso de un proceso mayor y quien
-- lo orquesta decide cuando el conjunto es definitivo. Es la misma politica de SP_AJUSTAR_STOCK y SP_ANULAR_PEDIDO y permite probar con
-- ROLLBACK. El costo es que el pedido y el cliente siguen bloqueados hasta que quien llama confirme.

-- Concurrencia: bloqueamos primero el pedido y luego el cliente, siempre en ese orden, para evitar deadlocks. Bloquear el pedido evita
-- facturarlo dos veces, porque la segunda sesion espera, lee CONFIRMADO y recibe -20061. Bloquear al cliente antes de consultar el cupo
-- evita que dos pedidos suyos vean el mismo cupo y lo sobrepasen. Limitacion: TRG_DETALLE_TOTAL no revisa el estado, asi que una linea
-- que otra sesion estaba agregando entra a un pedido ya CONFIRMADO y el trigger pisa el total neto con la suma bruta. Cerrarlo requiere
-- una regla nueva fuera del enunciado. En volumen, cada llamada recorre las lineas de un solo pedido y hace dos UPDATE por llave
-- primaria, asi que es barata. Para un lote se llama en ciclo y se confirma por lotes.

CREATE OR REPLACE PACKAGE PKG_VENTAS IS

    PROCEDURE SP_FACTURAR_PEDIDO (
        PARAM_idPedido  IN  NUMBER,
        PARAM_total     OUT NUMBER,
        PARAM_descuento OUT NUMBER
    );

END PKG_VENTAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_VENTAS IS

    -- Cursor privado con las lineas del pedido
    CURSOR cur_lineas (PARAM_idPedido NUMBER) IS
        SELECT linea, subtotal
        FROM   DETALLE_PEDIDO
        WHERE  id_pedido = PARAM_idPedido
        ORDER BY linea;

    PROCEDURE SP_FACTURAR_PEDIDO (
        PARAM_idPedido  IN  NUMBER,
        PARAM_total     OUT NUMBER,
        PARAM_descuento OUT NUMBER
    ) IS
        vnIdCliente    PEDIDO.id_cliente%TYPE;
        vvEstado       PEDIDO.estado%TYPE;
        vnSaldoPrevio  CLIENTE.saldo_pendiente%TYPE;
        vnSubtotal     NUMBER := 0;
        vnLineas       NUMBER := 0;
        vnDescuento    NUMBER;
        vnTotal        NUMBER;
        vnCupo         NUMBER;
    BEGIN
        -- Inicio de la unidad de trabajo: lo que sigue se puede deshacer sin tocar lo anterior de quien llama
        SAVEPOINT sp_facturar;
        PARAM_total     := NULL;
        PARAM_descuento := NULL;

        -- Paso 1: el pedido debe existir y estar en BORRADOR. Se bloquea su fila
        BEGIN
            SELECT id_cliente, estado
            INTO   vnIdCliente, vvEstado
            FROM   PEDIDO
            WHERE  id_pedido = PARAM_idPedido
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20060, 'El pedido ' || NVL(TO_CHAR(PARAM_idPedido), 'nulo') || ' no existe');
        END;

        IF vvEstado <> 'BORRADOR' THEN
            RAISE_APPLICATION_ERROR(-20061, 'El pedido ' || PARAM_idPedido || ' no se puede facturar: esta ' || vvEstado ||
                                            ' y solo se facturan pedidos en BORRADOR');
        END IF;

        -- Se bloquea al cliente, siempre despues del pedido, antes de consultar su cupo
        SELECT saldo_pendiente
        INTO   vnSaldoPrevio
        FROM   CLIENTE
        WHERE  id_cliente = vnIdCliente
        FOR UPDATE;

        -- Paso 2: recorrer las lineas con el cursor y acumular el subtotal
        FOR vrLinea IN cur_lineas(PARAM_idPedido) LOOP
            vnLineas   := vnLineas + 1;
            vnSubtotal := vnSubtotal + vrLinea.subtotal;
        END LOOP;

        IF vnLineas = 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'El pedido ' || PARAM_idPedido || ' no tiene lineas y no se puede facturar');
        END IF;

        -- Paso 3: descuento en pesos con FN_CALCULAR_DESCUENTO, antes de tocar el saldo
        vnDescuento := FN_CALCULAR_DESCUENTO(vnIdCliente, vnSubtotal);
        vnTotal     := vnSubtotal - vnDescuento;

        -- Paso 4: cupo con FN_CUPO_DISPONIBLE, contra el total que realmente se va a deber
        vnCupo := FN_CUPO_DISPONIBLE(vnIdCliente);
        IF vnTotal > vnCupo THEN
            RAISE_APPLICATION_ERROR(-20063, 'Cupo insuficiente para el cliente ' || vnIdCliente || ': disponible ' ||
                                            TO_CHAR(vnCupo, 'FM999,999,990.00') || ', requerido ' ||
                                            TO_CHAR(vnTotal, 'FM999,999,990.00'));
        END IF;

        -- Paso 5: total neto y estado CONFIRMADO
        UPDATE PEDIDO
        SET    total  = vnTotal,
               estado = 'CONFIRMADO'
        WHERE  id_pedido = PARAM_idPedido;

        -- Paso 6: el cliente debe el total facturado
        UPDATE CLIENTE
        SET    saldo_pendiente = saldo_pendiente + vnTotal
        WHERE  id_cliente = vnIdCliente;

        -- Paso 8: resultados por parametros OUT, solo si todo salio bien
        PARAM_total     := vnTotal;
        PARAM_descuento := vnDescuento;
    EXCEPTION
        WHEN OTHERS THEN
            -- Paso 7: primero se registra en una transaccion autonoma que persiste, luego se revierte solo lo de este procedimiento
            SP_REGISTRAR_ERROR('PKG_VENTAS.SP_FACTURAR_PEDIDO', 'pedido ' || NVL(TO_CHAR(PARAM_idPedido), 'nulo'));
            ROLLBACK TO SAVEPOINT sp_facturar;
            PARAM_total     := NULL;
            PARAM_descuento := NULL;
            RAISE;   -- el error original sube intacto y quien llama se entera del fallo
    END SP_FACTURAR_PEDIDO;

END PKG_VENTAS;
/
SHOW ERRORS PACKAGE BODY PKG_VENTAS

------------------------------------------------------------------- PRUEBA 6 bloque 1
-- Requiere instalados SP_CREAR_PEDIDO, FN_CUPO_DISPONIBLE, FN_CALCULAR_DESCUENTO, SP_REGISTRAR_ERROR y los triggers 5.4 y 5.5.
-- Datos de partida:
--   cliente 501: cupo 8.000.000, saldo 1.250.000
--   cliente 502: cupo 5.000.000, saldo 4.700.000, disponible 300.000
--   cliente 503: cupo 2.000.000, saldo 0
--   producto 1004: precio 320.000, 35 unidades en bodega 1
DECLARE
    vnIdPedido  NUMBER;
    vnLogsIni   NUMBER;

    FUNCTION FN_saldoDe (
        PARAM_cliente         IN NUMBER
    ) RETURN NUMBER IS
        vnValor NUMBER;
    BEGIN
        SELECT saldo_pendiente INTO vnValor FROM CLIENTE WHERE id_cliente = PARAM_cliente;
        RETURN vnValor;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
    END FN_saldoDe;

    FUNCTION FN_estadoDe (
        PARAM_pedido          IN NUMBER
    ) RETURN VARCHAR2 IS
        vvValor PEDIDO.estado%TYPE;
    BEGIN
        SELECT estado INTO vvValor FROM PEDIDO WHERE id_pedido = PARAM_pedido;
        RETURN vvValor;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN '-';
    END FN_estadoDe;

    FUNCTION FN_logsDe RETURN NUMBER IS
        vnValor NUMBER;
    BEGIN
        SELECT COUNT(*) INTO vnValor FROM LOG_ERRORES WHERE origen = 'PKG_VENTAS.SP_FACTURAR_PEDIDO';
        RETURN vnValor;
    END FN_logsDe;

    -- Crea un pedido BORRADOR con SP_CREAR_PEDIDO y, si se indica producto, le agrega una linea que dispara 5.4 y 5.5
    PROCEDURE SP_armarPedido (
        PARAM_cliente         IN  NUMBER,
        PARAM_producto        IN  NUMBER,
        PARAM_cantidad        IN  NUMBER,
        PARAM_idPedido        OUT NUMBER
    ) IS
        vnPrecio NUMBER;
    BEGIN
        SP_CREAR_PEDIDO(PARAM_cliente, PARAM_idPedido);
        IF PARAM_producto IS NOT NULL THEN
            SELECT precio_unitario INTO vnPrecio FROM PRODUCTO WHERE id_producto = PARAM_producto;
            INSERT INTO DETALLE_PEDIDO (id_pedido, linea, id_producto, id_bodega, cantidad, precio_unitario, subtotal)
            VALUES (PARAM_idPedido, 1, PARAM_producto, 1, PARAM_cantidad, vnPrecio, PARAM_cantidad * vnPrecio);
        END IF;
    END SP_armarPedido;

    PROCEDURE SP_probarFactura (
        PARAM_caso            IN VARCHAR2,
        PARAM_idPedido        IN NUMBER,
        PARAM_cliente         IN NUMBER,
        PARAM_codEsperado     IN NUMBER,
        PARAM_totalEsperado   IN NUMBER,
        PARAM_descEsperado    IN NUMBER,
        PARAM_saldoEsperado   IN NUMBER,
        PARAM_estadoEsperado  IN VARCHAR2
    ) IS
        vnCodigo  NUMBER := 0;
        vnTotal   NUMBER;
        vnDesc    NUMBER;
        vnSaldo   NUMBER;
        vvEstado  PEDIDO.estado%TYPE;
    BEGIN
        BEGIN
            PKG_VENTAS.SP_FACTURAR_PEDIDO(PARAM_idPedido, vnTotal, vnDesc);
        EXCEPTION
            -- Solo en las pruebas: se captura para MOSTRAR el error
            WHEN OTHERS THEN vnCodigo := SQLCODE;
        END;
        vnSaldo  := FN_saldoDe(PARAM_cliente);
        vvEstado := FN_estadoDe(PARAM_idPedido);

        DBMS_OUTPUT.PUT_LINE(PARAM_caso);
        DBMS_OUTPUT.PUT_LINE('   codigo=' || vnCodigo || ' (esperado ' || PARAM_codEsperado || ') | total=' ||
            NVL(TO_CHAR(vnTotal), 'NULL') || ' (esperado ' || NVL(TO_CHAR(PARAM_totalEsperado), 'NULL') || ') | descuento=' ||
            NVL(TO_CHAR(vnDesc), 'NULL') || ' (esperado ' || NVL(TO_CHAR(PARAM_descEsperado), 'NULL') || ')');
        DBMS_OUTPUT.PUT_LINE('   saldo cliente=' || NVL(TO_CHAR(vnSaldo), '-') || ' (esperado ' ||
            NVL(TO_CHAR(PARAM_saldoEsperado), '-') || ') | estado=' || vvEstado || ' (esperado ' || PARAM_estadoEsperado ||
            ') -> ' ||
            CASE WHEN vnCodigo = PARAM_codEsperado
                  AND NVL(vnTotal, -1) = NVL(PARAM_totalEsperado, -1)
                  AND NVL(vnDesc, -1)  = NVL(PARAM_descEsperado, -1)
                  AND NVL(vnSaldo, -1) = NVL(PARAM_saldoEsperado, -1)
                  AND vvEstado = PARAM_estadoEsperado
                 THEN 'OK' ELSE 'REVISAR' END);
    END SP_probarFactura;
BEGIN
    vnLogsIni := FN_logsDe;

    -- Caso 1: 501 compra 3 x 1004 = 960.000. Cae en el tramo del 5% y tiene saldo, asi que no hay 2% extra.
    -- Descuento 48.000, total 912.000 y saldo 1.250.000 + 912.000 = 2.162.000
    SP_armarPedido(501, 1004, 3, vnIdPedido);
    SP_probarFactura('Caso 1: factura normal con descuento 5% al cliente 501', vnIdPedido, 501, 0, 912000, 48000, 2162000, 'CONFIRMADO');

    -- Caso 2: el mismo pedido otra vez. Se rechaza y el saldo del caso 1 no se pierde, porque el rollback es parcial
    SP_probarFactura('Caso 2: refacturar el mismo pedido -> -20061', vnIdPedido, 501, -20061, NULL, NULL, 2162000, 'CONFIRMADO');

    -- Caso 3: 503 no tiene saldo. Recibe 5% por monto y 2% adicional, o sea 7% de 960.000 = 67.200. Total 892.800
    SP_armarPedido(503, 1004, 3, vnIdPedido);
    SP_probarFactura('Caso 3: descuento acumulado 7% al cliente 503 sin saldo', vnIdPedido, 503, 0, 892800, 67200, 892800, 'CONFIRMADO');

    -- Caso 4: 502 solo tiene 300.000 disponibles y compra 320.000 sin descuento
    SP_armarPedido(502, 1004, 1, vnIdPedido);
    SP_probarFactura('Caso 4: cupo insuficiente del cliente 502 -> -20063', vnIdPedido, 502, -20063, NULL, NULL, 4700000, 'BORRADOR');

    -- Caso 5: pedido inexistente
    SP_probarFactura('Caso 5: pedido inexistente 999 -> -20060', 999, NULL, -20060, NULL, NULL, NULL, '-');

    -- Casos 6 y 7: pedidos que ya no estan en BORRADOR
    SP_probarFactura('Caso 6: pedido 1 CONFIRMADO -> -20061', 1, NULL, -20061, NULL, NULL, NULL, 'CONFIRMADO');
    SP_probarFactura('Caso 7: pedido 7 ANULADO -> -20061', 7, NULL, -20061, NULL, NULL, NULL, 'ANULADO');

    -- Caso 8: pedido BORRADOR sin lineas
    SP_armarPedido(501, NULL, NULL, vnIdPedido);
    SP_probarFactura('Caso 8: pedido sin lineas -> -20062', vnIdPedido, 501, -20062, NULL, NULL, 2162000, 'BORRADOR');

    DBMS_OUTPUT.PUT_LINE('Registros nuevos en LOG_ERRORES antes del ROLLBACK: ' || (FN_logsDe - vnLogsIni) ||
        ' (esperado 6: casos 2, 4, 5, 6, 7 y 8)');

    ROLLBACK;   -- se revierten pedidos, lineas, stock y saldos de la prueba

    DBMS_OUTPUT.PUT_LINE('Tras ROLLBACK: saldo 501=' || FN_saldoDe(501) || ' (esperado 1250000) | saldo 503=' || FN_saldoDe(503) ||
        ' (esperado 0) | registros nuevos en LOG_ERRORES=' || (FN_logsDe - vnLogsIni) || ' (esperado 6: el log persiste)');
END;
/

------------------------------------------------------------------- PRUEBA 6 bloque 2: SAVEPOINT
-- Se simula una falla en el paso 6 con un trigger temporal que rechaza la actualizacion del saldo del cliente 504.
-- El paso 5 ya habia puesto el pedido en CONFIRMADO y debe quedar revertido. Las lineas que quien llama creo antes se conservan.
-- El CREATE TRIGGER confirma la transaccion, por eso va antes de crear los datos de prueba.
CREATE OR REPLACE TRIGGER TRG_TEST_FALLA_SALDO
BEFORE UPDATE OF saldo_pendiente ON CLIENTE
FOR EACH ROW
WHEN (NEW.id_cliente = 504)
BEGIN
    RAISE_APPLICATION_ERROR(-20999, 'Falla simulada al actualizar el saldo del cliente 504');
END TRG_TEST_FALLA_SALDO;
/
SHOW ERRORS TRIGGER TRG_TEST_FALLA_SALDO

DECLARE
    vnIdPedido  NUMBER;
    vnTotal     NUMBER;
    vnDesc      NUMBER;
    vnCodigo    NUMBER := 0;
    vvEstado    PEDIDO.estado%TYPE;
    vnLineas    NUMBER;
    vnSaldo     NUMBER;
    vnLogsIni   NUMBER;
    vnLogsFin   NUMBER;
BEGIN
    SELECT COUNT(*) INTO vnLogsIni FROM LOG_ERRORES WHERE origen = 'PKG_VENTAS.SP_FACTURAR_PEDIDO';

    SP_CREAR_PEDIDO(504, vnIdPedido);
    INSERT INTO DETALLE_PEDIDO (id_pedido, linea, id_producto, id_bodega, cantidad, precio_unitario, subtotal)
    VALUES (vnIdPedido, 1, 1004, 1, 1, 320000, 320000);

    BEGIN
        PKG_VENTAS.SP_FACTURAR_PEDIDO(vnIdPedido, vnTotal, vnDesc);
    EXCEPTION
        -- Solo en las pruebas: se captura para MOSTRAR el error
        WHEN OTHERS THEN vnCodigo := SQLCODE;
    END;

    SELECT estado          INTO vvEstado  FROM PEDIDO         WHERE id_pedido  = vnIdPedido;
    SELECT COUNT(*)        INTO vnLineas  FROM DETALLE_PEDIDO WHERE id_pedido  = vnIdPedido;
    SELECT saldo_pendiente INTO vnSaldo   FROM CLIENTE        WHERE id_cliente = 504;
    SELECT COUNT(*)        INTO vnLogsFin FROM LOG_ERRORES    WHERE origen = 'PKG_VENTAS.SP_FACTURAR_PEDIDO';

    DBMS_OUTPUT.PUT_LINE('Caso 9: falla simulada en el paso 6 del cliente 504');
    DBMS_OUTPUT.PUT_LINE('   codigo=' || vnCodigo || ' (esperado -20999) | estado=' || vvEstado || ' (esperado BORRADOR) -> ' ||
        CASE WHEN vnCodigo = -20999 AND vvEstado = 'BORRADOR' THEN 'OK' ELSE 'REVISAR' END);
    DBMS_OUTPUT.PUT_LINE('   lineas del pedido=' || vnLineas || ' (esperado 1: lo anterior de quien llama se conserva) | saldo 504=' ||
        vnSaldo || ' (esperado 3400000) -> ' ||
        CASE WHEN vnLineas = 1 AND vnSaldo = 3400000 THEN 'OK' ELSE 'REVISAR' END);
    DBMS_OUTPUT.PUT_LINE('   registros nuevos en LOG_ERRORES=' || (vnLogsFin - vnLogsIni) || ' (esperado 1) -> ' ||
        CASE WHEN vnLogsFin - vnLogsIni = 1 THEN 'OK' ELSE 'REVISAR' END);

    ROLLBACK;
END;
/

-- Limpieza obligatoria: el trigger de prueba no debe quedar en el esquema
DROP TRIGGER TRG_TEST_FALLA_SALDO;

-- Limpieza opcional de los registros de prueba del log:
-- DELETE FROM LOG_ERRORES WHERE origen = 'PKG_VENTAS.SP_FACTURAR_PEDIDO'; COMMIT;


--==============================================================================
-- FIN DE LA PLANTILLA
--==============================================================================
