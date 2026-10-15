-- =====================================================================
-- GRANJA DE CERDOS - Esquema v2 (MySQL 8.0)
-- Reemplaza a granja_schema.sql (v1).
--
-- MÓDULOS:
--   1) Gestación  : cerdas, berracos, servicios (cargas), partos/camadas
--   2) Corrales   : lotes por corral, origen de los lechones, etapas de
--                   concentrado, bajas
--   3) Venta      : jornadas de venta, cerdos en pie, mitades de canal,
--                   clientes y precio por libra personalizado
--   4) Alertas    : vistas que calculan qué avisar y cuándo
--
-- PENSADO PARA OFFLINE-FIRST:
--   * id = UUID (CHAR(36)) generado en el cliente
--   * created_at / updated_at / deleted_at en las tablas
--       - updated_at lo asigna el SERVIDOR (evita problemas de reloj)
--       - deleted_at = borrado lógico (para sincronizar borrados)
--   * utf8mb4 en todo
--   * Pesos en LIBRAS (_lb), dinero en QUETZALES
-- =====================================================================

CREATE DATABASE IF NOT EXISTS granja
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE granja;

-- ---------------------------------------------------------------------
-- USUARIOS, DISPOSITIVOS Y PARÁMETROS
-- ---------------------------------------------------------------------
CREATE TABLE usuarios (
  id            CHAR(36) NOT NULL PRIMARY KEY,
  nombre        VARCHAR(120) NOT NULL,
  usuario       VARCHAR(50)  NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  rol           ENUM('admin','operario') NOT NULL DEFAULT 'operario',
  activo        TINYINT(1) NOT NULL DEFAULT 1,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at    DATETIME(3) NULL,
  UNIQUE KEY uq_usuarios_usuario (usuario),
  KEY idx_usuarios_updated (updated_at)
) ENGINE=InnoDB;

CREATE TABLE dispositivos (
  id                    CHAR(36) NOT NULL PRIMARY KEY,
  usuario_id            CHAR(36) NOT NULL,
  nombre                VARCHAR(80) NOT NULL,
  ultima_sincronizacion DATETIME(3) NULL,
  created_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at            DATETIME(3) NULL,
  CONSTRAINT fk_disp_usuario FOREIGN KEY (usuario_id) REFERENCES usuarios(id),
  KEY idx_dispositivos_updated (updated_at)
) ENGINE=InnoDB;

-- Parámetros configurables (clave/valor). Así no quedan "quemados" en el código.
CREATE TABLE parametros (
  clave      VARCHAR(50)  NOT NULL PRIMARY KEY,
  valor      VARCHAR(100) NOT NULL,
  descripcion VARCHAR(255) NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;

INSERT INTO parametros (clave, valor, descripcion) VALUES
  ('gestacion_meses',        '3',  'Gestación: meses a sumar a la fecha de carga'),
  ('gestacion_semanas',      '3',  'Gestación: semanas a sumar'),
  ('gestacion_dias',         '3',  'Gestación: días a sumar'),
  ('dias_hierro',            '3',  'Días después del parto para la vacuna de hierro'),
  ('dias_castracion',        '15', 'Días después del parto para la castración'),
  ('dias_destete',           '28', 'Días después del parto para el destete (CONFIRMAR con el cliente)'),
  ('alerta_dias_parto',      '5',  'Avisar X días antes del parto estimado'),
  ('alerta_dias_eventos',    '1',  'Avisar X días antes de hierro, castración y destete'),
  ('partos_descarte',        '9',  'Al llegar a este número de partos, avisar que la cerda va a descarte');

-- ---------------------------------------------------------------------
-- 1) GESTACIÓN
-- ---------------------------------------------------------------------
CREATE TABLE cerdas (
  id               CHAR(36) NOT NULL PRIMARY KEY,
  numero           INT NOT NULL,                  -- "cocha No. 5"
  nombre           VARCHAR(60) NULL,              -- "Juana"
  arete            VARCHAR(30) NULL,
  raza             VARCHAR(60) NULL,
  fecha_nacimiento DATE NULL,
  partos_previos   INT NOT NULL DEFAULT 0,        -- partos que ya tenía antes de usar el sistema
  estado           ENUM('vacia','gestante','lactante','descartada','muerta','vendida') NOT NULL DEFAULT 'vacia',
  notas            TEXT NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at       DATETIME(3) NULL,
  KEY idx_cerdas_numero (numero),
  KEY idx_cerdas_updated (updated_at)
) ENGINE=InnoDB;

CREATE TABLE berracos (
  id         CHAR(36) NOT NULL PRIMARY KEY,
  numero     INT NULL,
  nombre     VARCHAR(60) NULL,
  arete      VARCHAR(30) NULL,
  raza       VARCHAR(60) NULL,
  estado     ENUM('activo','descartado','muerto','vendido') NOT NULL DEFAULT 'activo',
  notas      TEXT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at DATETIME(3) NULL,
  KEY idx_berracos_updated (updated_at)
) ENGINE=InnoDB;

-- Una "carga" = servicio. La fecha probable de parto se calcula en la app/API:
--   fecha_servicio + gestacion_meses MONTH + gestacion_semanas WEEK + gestacion_dias DAY
-- estado: gestante = cargada | vacia = no quedó preñada | parida = ya tuvo el parto
CREATE TABLE servicios (
  id                   CHAR(36) NOT NULL PRIMARY KEY,
  cerda_id             CHAR(36) NOT NULL,
  berraco_id           CHAR(36) NULL,
  fecha_servicio       DATE NOT NULL,             -- fecha en que fue cargada
  tipo                 ENUM('monta','inseminacion') NOT NULL DEFAULT 'monta',
  estado               ENUM('gestante','vacia','parida') NOT NULL DEFAULT 'gestante',
  fecha_probable_parto DATE NULL,
  notas                VARCHAR(255) NULL,
  created_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at           DATETIME(3) NULL,
  CONSTRAINT fk_serv_cerda   FOREIGN KEY (cerda_id)   REFERENCES cerdas(id),
  CONSTRAINT fk_serv_berraco FOREIGN KEY (berraco_id) REFERENCES berracos(id),
  KEY idx_servicios_cerda (cerda_id),
  KEY idx_servicios_updated (updated_at)
) ENGINE=InnoDB;

-- Un parto = una camada. Aquí viven las fechas de hierro, castración y destete.
-- El berraco se obtiene por servicio_id -> servicios.berraco_id.
-- Las fechas *_prog las calcula la app al registrar el parto (usando parametros);
-- las *_real se llenan cuando se hace el trabajo.
CREATE TABLE partos (
  id                    CHAR(36) NOT NULL PRIMARY KEY,
  cerda_id              CHAR(36) NOT NULL,
  servicio_id           CHAR(36) NULL,
  fecha_parto           DATE NOT NULL,
  nacidos_vivos         INT NOT NULL DEFAULT 0,
  nacidos_muertos       INT NOT NULL DEFAULT 0,
  momificados           INT NOT NULL DEFAULT 0,
  machos                INT NULL,                 -- de los nacidos vivos
  muertos_lactancia     INT NOT NULL DEFAULT 0,   -- murieron antes del destete

  fecha_hierro_prog     DATE NULL,
  fecha_hierro_real     DATE NULL,
  fecha_castracion_prog DATE NULL,
  fecha_castracion_real DATE NULL,
  castrados             INT NULL,
  fecha_destete_prog    DATE NULL,
  fecha_destete_real    DATE NULL,
  destetados            INT NULL,

  notas                 VARCHAR(255) NULL,
  created_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at            DATETIME(3) NULL,
  CONSTRAINT fk_partos_cerda    FOREIGN KEY (cerda_id)    REFERENCES cerdas(id),
  CONSTRAINT fk_partos_servicio FOREIGN KEY (servicio_id) REFERENCES servicios(id),
  KEY idx_partos_cerda (cerda_id),
  KEY idx_partos_updated (updated_at)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2) CORRALES, LOTES Y CONCENTRADO
-- ---------------------------------------------------------------------
CREATE TABLE corrales (
  id          CHAR(36) NOT NULL PRIMARY KEY,
  numero      INT NOT NULL,                       -- "Corral No. 1"
  nombre      VARCHAR(60) NULL,
  capacidad   INT NULL,
  activo      TINYINT(1) NOT NULL DEFAULT 1,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at  DATETIME(3) NULL,
  KEY idx_corrales_updated (updated_at)
) ENGINE=InnoDB;

-- Lote = el grupo de lechones que entra a un corral (ej. 30 lechones).
CREATE TABLE lotes (
  id                   CHAR(36) NOT NULL PRIMARY KEY,
  corral_id            CHAR(36) NOT NULL,
  codigo               VARCHAR(30) NULL,
  fecha_ingreso        DATE NOT NULL,
  cantidad_inicial     INT NOT NULL,
  estado               ENUM('activo','listo_venta','vendido','cerrado') NOT NULL DEFAULT 'activo',
  fecha_listo_venta    DATE NULL,                 -- cuándo se marcó listo para venta
  fecha_estimada_venta DATE NULL,
  notas                TEXT NULL,
  created_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at           DATETIME(3) NULL,
  CONSTRAINT fk_lotes_corral FOREIGN KEY (corral_id) REFERENCES corrales(id),
  KEY idx_lotes_corral (corral_id),
  KEY idx_lotes_updated (updated_at)
) ENGINE=InnoDB;

-- De qué camadas/cerdas vienen los lechones de un lote
-- (ej. 10 de Juana + 10 de Leónida + 10 de Pancha = 30)
CREATE TABLE lote_origenes (
  id         CHAR(36) NOT NULL PRIMARY KEY,
  lote_id    CHAR(36) NOT NULL,
  parto_id   CHAR(36) NOT NULL,                   -- de ahí sale la cerda
  cantidad   INT NOT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at DATETIME(3) NULL,
  CONSTRAINT fk_lo_lote  FOREIGN KEY (lote_id)  REFERENCES lotes(id),
  CONSTRAINT fk_lo_parto FOREIGN KEY (parto_id) REFERENCES partos(id),
  KEY idx_lote_origenes_updated (updated_at)
) ENGINE=InnoDB;

-- Catálogo de etapas de concentrado, en orden
CREATE TABLE etapas_alimento (
  id             CHAR(36) NOT NULL PRIMARY KEY,
  nombre         VARCHAR(40) NOT NULL,
  orden          INT NOT NULL,
  dias_sugeridos INT NULL,                        -- para futuras alertas de cambio de etapa
  created_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at     DATETIME(3) NULL,
  KEY idx_etapas_updated (updated_at)
) ENGINE=InnoDB;

INSERT INTO etapas_alimento (id, nombre, orden) VALUES
  (UUID(), 'Starter 1',     1),
  (UUID(), 'Starter 2',     2),
  (UUID(), 'Starter 3',     3),
  (UUID(), 'Inicio',        4),
  (UUID(), 'Crecimiento',   5),
  (UUID(), 'Desarrollo',    6),
  (UUID(), 'Finalización',  7);

-- Historial de etapas de concentrado por lote.
-- La etapa actual = la fila con fecha_fin NULL.
CREATE TABLE lote_alimentacion (
  id           CHAR(36) NOT NULL PRIMARY KEY,
  lote_id      CHAR(36) NOT NULL,
  etapa_id     CHAR(36) NOT NULL,
  fecha_inicio DATE NOT NULL,
  fecha_fin    DATE NULL,
  notas        VARCHAR(255) NULL,
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at   DATETIME(3) NULL,
  CONSTRAINT fk_la_lote  FOREIGN KEY (lote_id)  REFERENCES lotes(id),
  CONSTRAINT fk_la_etapa FOREIGN KEY (etapa_id) REFERENCES etapas_alimento(id),
  KEY idx_lote_alim_lote (lote_id),
  KEY idx_lote_alim_updated (updated_at)
) ENGINE=InnoDB;

-- Muertes dentro del corral
CREATE TABLE lote_bajas (
  id         CHAR(36) NOT NULL PRIMARY KEY,
  lote_id    CHAR(36) NOT NULL,
  fecha      DATE NOT NULL,
  cantidad   INT NOT NULL DEFAULT 1,
  causa      ENUM('enfermedad','accidente','desconocida','otra') NOT NULL DEFAULT 'desconocida',
  notas      VARCHAR(255) NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at DATETIME(3) NULL,
  CONSTRAINT fk_lb_lote FOREIGN KEY (lote_id) REFERENCES lotes(id),
  KEY idx_lote_bajas_updated (updated_at)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3) VENTA POR CANAL
-- Flujo: jornada de venta (un día, un lote) -> cada cerdo se pesa en pie
--        -> se parte en 2 mitades que se pesan -> cada mitad se vende a un
--        cliente con SU precio por libra.
-- ---------------------------------------------------------------------
CREATE TABLE clientes (
  id         CHAR(36) NOT NULL PRIMARY KEY,
  nombre     VARCHAR(120) NOT NULL,
  telefono   VARCHAR(30) NULL,
  notas      VARCHAR(255) NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at DATETIME(3) NULL,
  KEY idx_clientes_updated (updated_at)
) ENGINE=InnoDB;

CREATE TABLE jornadas_venta (
  id         CHAR(36) NOT NULL PRIMARY KEY,
  fecha      DATE NOT NULL,                       -- ej. 14 de octubre
  lote_id    CHAR(36) NOT NULL,                   -- de qué corral/lote salen
  lugar      VARCHAR(120) NULL,                   -- rastro
  notas      VARCHAR(255) NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at DATETIME(3) NULL,
  CONSTRAINT fk_jv_lote FOREIGN KEY (lote_id) REFERENCES lotes(id),
  KEY idx_jornadas_updated (updated_at)
) ENGINE=InnoDB;

-- Cada cerdo que se sacrifica en la jornada (cerdo 01, 02, ...)
CREATE TABLE cerdos_sacrificados (
  id           CHAR(36) NOT NULL PRIMARY KEY,
  jornada_id   CHAR(36) NOT NULL,
  numero       SMALLINT NOT NULL,                 -- 1, 2, 3...
  peso_pie_lb  DECIMAL(6,2) NOT NULL,             -- ej. 230.00
  notas        VARCHAR(255) NULL,
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at   DATETIME(3) NULL,
  CONSTRAINT fk_cs_jornada FOREIGN KEY (jornada_id) REFERENCES jornadas_venta(id),
  KEY idx_cerdos_sac_jornada (jornada_id),
  KEY idx_cerdos_sac_updated (updated_at)
) ENGINE=InnoDB;

-- Las dos mitades de cada cerdo: aquí está el negocio.
-- total = peso_lb * precio_libra (lo calcula la app/API; se redondea a 2 decimales).
-- cliente_id y precio_libra quedan NULL hasta que decidas a quién y a cuánto se vende.
CREATE TABLE mitades_canal (
  id            CHAR(36) NOT NULL PRIMARY KEY,
  cerdo_id      CHAR(36) NOT NULL,
  mitad         TINYINT NOT NULL,                 -- 1 o 2
  peso_lb       DECIMAL(6,2) NOT NULL,            -- ej. 105.40
  cliente_id    CHAR(36) NULL,
  precio_libra  DECIMAL(8,2) NULL,                -- ej. 16.00 (personalizable por venta)
  total         DECIMAL(12,2) NULL,               -- ej. 1686.40
  estado_pago   ENUM('pendiente','pagado') NOT NULL DEFAULT 'pendiente',
  fecha_pago    DATE NULL,
  notas         VARCHAR(255) NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at    DATETIME(3) NULL,
  CONSTRAINT fk_mc_cerdo   FOREIGN KEY (cerdo_id)   REFERENCES cerdos_sacrificados(id),
  CONSTRAINT fk_mc_cliente FOREIGN KEY (cliente_id) REFERENCES clientes(id),
  CONSTRAINT ck_mc_mitad CHECK (mitad IN (1,2)),
  KEY idx_mitades_cerdo (cerdo_id),
  KEY idx_mitades_cliente (cliente_id),
  KEY idx_mitades_updated (updated_at)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4) VISTAS: RESÚMENES Y ALERTAS
-- ---------------------------------------------------------------------

-- Resumen por cerda: total de partos, fecha de carga y fecha probable de parto
CREATE VIEW v_cerdas_resumen AS
SELECT
  c.id, c.numero, c.nombre, c.estado,
  c.partos_previos + (SELECT COUNT(*) FROM partos p
                      WHERE p.cerda_id = c.id AND p.deleted_at IS NULL) AS total_partos,
  (SELECT s.fecha_servicio FROM servicios s
    WHERE s.cerda_id = c.id AND s.estado = 'gestante' AND s.deleted_at IS NULL
    ORDER BY s.fecha_servicio DESC LIMIT 1) AS fecha_carga,
  (SELECT s.fecha_probable_parto FROM servicios s
    WHERE s.cerda_id = c.id AND s.estado = 'gestante' AND s.deleted_at IS NULL
    ORDER BY s.fecha_servicio DESC LIMIT 1) AS fecha_probable_parto
FROM cerdas c
WHERE c.deleted_at IS NULL;

-- Alertas pendientes: parto próximo, hierro, castración, destete y descarte.
-- Incluye también las ya vencidas que nadie ha marcado como hechas.
CREATE VIEW v_alertas AS
SELECT 'parto' AS tipo, c.id AS cerda_id, c.numero AS cerda_numero, c.nombre AS cerda_nombre,
       s.id AS referencia_id, s.fecha_probable_parto AS fecha_evento
FROM servicios s
JOIN cerdas c ON c.id = s.cerda_id
WHERE s.deleted_at IS NULL AND c.deleted_at IS NULL
  AND s.estado = 'gestante' AND s.fecha_probable_parto IS NOT NULL
  AND s.fecha_probable_parto <= DATE_ADD(CURDATE(), INTERVAL
        CAST((SELECT valor FROM parametros WHERE clave = 'alerta_dias_parto') AS UNSIGNED) DAY)
UNION ALL
SELECT 'hierro', c.id, c.numero, c.nombre, p.id, p.fecha_hierro_prog
FROM partos p
JOIN cerdas c ON c.id = p.cerda_id
WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL
  AND p.fecha_hierro_real IS NULL AND p.fecha_hierro_prog IS NOT NULL
  AND p.fecha_hierro_prog <= DATE_ADD(CURDATE(), INTERVAL
        CAST((SELECT valor FROM parametros WHERE clave = 'alerta_dias_eventos') AS UNSIGNED) DAY)
UNION ALL
SELECT 'castracion', c.id, c.numero, c.nombre, p.id, p.fecha_castracion_prog
FROM partos p
JOIN cerdas c ON c.id = p.cerda_id
WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL
  AND p.fecha_castracion_real IS NULL AND p.fecha_castracion_prog IS NOT NULL
  AND p.fecha_castracion_prog <= DATE_ADD(CURDATE(), INTERVAL
        CAST((SELECT valor FROM parametros WHERE clave = 'alerta_dias_eventos') AS UNSIGNED) DAY)
UNION ALL
SELECT 'destete', c.id, c.numero, c.nombre, p.id, p.fecha_destete_prog
FROM partos p
JOIN cerdas c ON c.id = p.cerda_id
WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL
  AND p.fecha_destete_real IS NULL AND p.fecha_destete_prog IS NOT NULL
  AND p.fecha_destete_prog <= DATE_ADD(CURDATE(), INTERVAL
        CAST((SELECT valor FROM parametros WHERE clave = 'alerta_dias_eventos') AS UNSIGNED) DAY)
UNION ALL
-- Descarte: la cerda llegó (o pasó) el número de partos configurado y aún no se
-- ha marcado como descartada/muerta/vendida. fecha_evento = fecha de su último parto.
SELECT 'descarte', c.id, c.numero, c.nombre, c.id,
       (SELECT MAX(p.fecha_parto) FROM partos p
         WHERE p.cerda_id = c.id AND p.deleted_at IS NULL)
FROM cerdas c
WHERE c.deleted_at IS NULL
  AND c.estado NOT IN ('descartada','muerta','vendida')
  AND c.partos_previos + (SELECT COUNT(*) FROM partos p
                          WHERE p.cerda_id = c.id AND p.deleted_at IS NULL)
      >= CAST((SELECT valor FROM parametros WHERE clave = 'partos_descarte') AS UNSIGNED);

-- Por cada cerdo sacrificado: peso en pie, peso de canal (suma de mitades),
-- rendimiento % y total vendido
CREATE VIEW v_cerdos_canal AS
SELECT
  cs.id, cs.jornada_id, cs.numero, cs.peso_pie_lb,
  SUM(m.peso_lb) AS peso_canal_lb,
  ROUND(SUM(m.peso_lb) / cs.peso_pie_lb * 100, 1) AS rendimiento_pct,
  SUM(m.total) AS total_vendido
FROM cerdos_sacrificados cs
LEFT JOIN mitades_canal m ON m.cerdo_id = cs.id AND m.deleted_at IS NULL
WHERE cs.deleted_at IS NULL
GROUP BY cs.id, cs.jornada_id, cs.numero, cs.peso_pie_lb;

-- ---------------------------------------------------------------------
-- EJEMPLO: cálculo de fechas al registrar una carga y un parto
--   fecha_probable_parto = fecha_servicio + 3 MONTH + 3 WEEK + 3 DAY
--   SELECT DATE_ADD(DATE_ADD(DATE_ADD('2026-06-01', INTERVAL 3 MONTH), INTERVAL 3 WEEK), INTERVAL 3 DAY);
--   fecha_hierro_prog     = fecha_parto + 3 DAY
--   fecha_castracion_prog = fecha_parto + 15 DAY
--   fecha_destete_prog    = fecha_parto + dias_destete DAY
--
-- EJEMPLO: ver alertas de hoy
--   SELECT * FROM v_alertas ORDER BY fecha_evento, tipo;
-- ---------------------------------------------------------------------