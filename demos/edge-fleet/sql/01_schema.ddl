-- Tables and the property graph for the edge-fleet demo.
--
-- Applied by scripts/setup.sh with `spanner databases ddl update --ddl-file`.
-- Plain Spanner GoogleSQL DDL — identical to what you would run against managed
-- Spanner, because Spanner Omni is the same database.
--
-- Spanner notes worth knowing if you adapt this:
--   * every table needs a PRIMARY KEY, edge tables included
--   * an edge table's SOURCE/DESTINATION KEY must reference a real PK
--   * LABEL is optional, but naming it explicitly is what stops GQL and the
--     table names drifting apart
--
-- The database name is a CLI argument, not part of the DDL, so this file is
-- used verbatim with nothing substituted into it.

CREATE TABLE Site (
  id          STRING(32) NOT NULL,
  name        STRING(128),
  region      STRING(32),
  opened_date DATE,
) PRIMARY KEY (id);

CREATE TABLE Gateway (
  id             STRING(32) NOT NULL,
  model          STRING(32),
  installed_date DATE,
) PRIMARY KEY (id);

CREATE TABLE Device (
  id          STRING(32) NOT NULL,
  kind        STRING(32),
  serial      STRING(64),
  criticality STRING(16),
) PRIMARY KEY (id);

CREATE TABLE Firmware (
  id            STRING(32) NOT NULL,
  version       STRING(32),
  released_date DATE,
  advisory      STRING(32),
) PRIMARY KEY (id);

CREATE TABLE Technician (
  id            STRING(32) NOT NULL,
  name          STRING(128),
  certification STRING(32),
) PRIMARY KEY (id);

-- Which gateway stands at which site.
CREATE TABLE HostedAt (
  gateway_id STRING(32) NOT NULL,
  site_id    STRING(32) NOT NULL,
  rack       STRING(16),
) PRIMARY KEY (gateway_id);

-- Every device reaches the network through exactly one gateway. This edge is
-- the one the blast-radius query walks.
CREATE TABLE ConnectedTo (
  device_id  STRING(32) NOT NULL,
  gateway_id STRING(32) NOT NULL,
  port       INT64,
) PRIMARY KEY (device_id);

CREATE TABLE RunsFirmware (
  device_id   STRING(32) NOT NULL,
  firmware_id STRING(32) NOT NULL,
  applied_date DATE,
) PRIMARY KEY (device_id);

-- Who is on call for a site. A site with exactly one is a people-shaped single
-- point of failure, which no inventory table would ever show you.
CREATE TABLE Covers (
  technician_id STRING(32) NOT NULL,
  site_id       STRING(32) NOT NULL,
  since_date    DATE,
) PRIMARY KEY (technician_id, site_id);

-- Device-to-device control dependency: a controller that stops responding takes
-- everything downstream of it with it, however many hops away that is.
CREATE TABLE DependsOn (
  device_id    STRING(32) NOT NULL,
  depends_on_id STRING(32) NOT NULL,
  reason       STRING(32),
) PRIMARY KEY (device_id, depends_on_id);

CREATE PROPERTY GRAPH FleetGraph
  NODE TABLES (
    Site       KEY (id) LABEL Site       PROPERTIES (id, name, region, opened_date),
    Gateway    KEY (id) LABEL Gateway    PROPERTIES (id, model, installed_date),
    Device     KEY (id) LABEL Device     PROPERTIES (id, kind, serial, criticality),
    Firmware   KEY (id) LABEL Firmware   PROPERTIES (id, version, released_date, advisory),
    Technician KEY (id) LABEL Technician PROPERTIES (id, name, certification)
  )
  EDGE TABLES (
    HostedAt
      KEY (gateway_id)
      SOURCE KEY (gateway_id) REFERENCES Gateway (id)
      DESTINATION KEY (site_id) REFERENCES Site (id)
      LABEL HOSTED_AT PROPERTIES (rack),

    ConnectedTo
      KEY (device_id)
      SOURCE KEY (device_id) REFERENCES Device (id)
      DESTINATION KEY (gateway_id) REFERENCES Gateway (id)
      LABEL CONNECTED_TO PROPERTIES (port),

    RunsFirmware
      KEY (device_id)
      SOURCE KEY (device_id) REFERENCES Device (id)
      DESTINATION KEY (firmware_id) REFERENCES Firmware (id)
      LABEL RUNS PROPERTIES (applied_date),

    Covers
      KEY (technician_id, site_id)
      SOURCE KEY (technician_id) REFERENCES Technician (id)
      DESTINATION KEY (site_id) REFERENCES Site (id)
      LABEL COVERS PROPERTIES (since_date),

    DependsOn
      KEY (device_id, depends_on_id)
      SOURCE KEY (device_id) REFERENCES Device (id)
      DESTINATION KEY (depends_on_id) REFERENCES Device (id)
      LABEL DEPENDS_ON PROPERTIES (reason)
  );
