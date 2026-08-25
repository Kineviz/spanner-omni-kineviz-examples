-- Tables and the property graph for the fraud-rings demo.
--
-- Applied by scripts/setup.sh via `spanner databases ddl update --ddl-file`,
-- which submits the whole file as one DDL batch. The file
-- is plain Spanner GoogleSQL DDL — the same statements you would run against
-- managed Spanner, because Spanner Omni is the same database.
--
-- Spanner notes worth knowing if you adapt this:
--   * every table needs a PRIMARY KEY, edge tables included
--   * an edge table's SOURCE/DESTINATION KEY must reference a real PK
--   * LABEL is optional, but naming it explicitly is what stops GQL and the
--     table names drifting apart — see connect/README.md's troubleshooting
--
-- No ${PLACEHOLDERS} here: the database name is an argument to the loader, not
-- part of the DDL, so this file is used verbatim.

CREATE TABLE Client (
  id          STRING(32)  NOT NULL,
  name        STRING(128),
  email       STRING(256),
  opened_date DATE,
  risk_tier   STRING(16),
) PRIMARY KEY (id);

CREATE TABLE Device (
  id         STRING(32) NOT NULL,
  kind       STRING(16),
  first_seen DATE,
) PRIMARY KEY (id);

CREATE TABLE Merchant (
  id       STRING(32) NOT NULL,
  name     STRING(128),
  category STRING(32),
) PRIMARY KEY (id);

-- Which accounts signed in from which device. The edge the whole demo turns on.
CREATE TABLE UsedDevice (
  client_id  STRING(32) NOT NULL,
  device_id  STRING(32) NOT NULL,
  first_used DATE,
) PRIMARY KEY (client_id, device_id);

-- Account-to-account transfer.
CREATE TABLE Paid (
  tx_id         STRING(32) NOT NULL,
  src_client_id STRING(32) NOT NULL,
  dst_client_id STRING(32) NOT NULL,
  amount        FLOAT64,
  ts            TIMESTAMP,
) PRIMARY KEY (tx_id);

-- Account-to-merchant payment: where value leaves the P2P network.
CREATE TABLE PaidMerchant (
  tx_id       STRING(32) NOT NULL,
  client_id   STRING(32) NOT NULL,
  merchant_id STRING(32) NOT NULL,
  amount      FLOAT64,
  ts          TIMESTAMP,
) PRIMARY KEY (tx_id);

CREATE PROPERTY GRAPH FraudGraph
  NODE TABLES (
    Client   KEY (id) LABEL Client   PROPERTIES (id, name, email, opened_date, risk_tier),
    Device   KEY (id) LABEL Device   PROPERTIES (id, kind, first_seen),
    Merchant KEY (id) LABEL Merchant PROPERTIES (id, name, category)
  )
  EDGE TABLES (
    UsedDevice
      KEY (client_id, device_id)
      SOURCE KEY (client_id) REFERENCES Client (id)
      DESTINATION KEY (device_id) REFERENCES Device (id)
      LABEL USED_DEVICE PROPERTIES (first_used),

    Paid
      KEY (tx_id)
      SOURCE KEY (src_client_id) REFERENCES Client (id)
      DESTINATION KEY (dst_client_id) REFERENCES Client (id)
      LABEL PAID PROPERTIES (tx_id, amount, ts),

    PaidMerchant
      KEY (tx_id)
      SOURCE KEY (client_id) REFERENCES Client (id)
      DESTINATION KEY (merchant_id) REFERENCES Merchant (id)
      LABEL PAID_MERCHANT PROPERTIES (tx_id, amount, ts)
  );
