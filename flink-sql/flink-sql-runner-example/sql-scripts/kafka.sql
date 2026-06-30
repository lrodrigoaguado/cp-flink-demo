-- 1. Register Kafka topics as Flink tables
-- Dimension table sourced from Postgres via JDBC connector
CREATE TABLE vehicle_description (
  `vehicle_id` INT,
  `vehicle_brand` STRING,
  `driver_name` STRING,
  `license_plate` STRING
) WITH (
  'connector' = 'jdbc',
  'url' = 'jdbc:postgresql://host.docker.internal:5432/vehicles',
  'table-name' = 'vehicle_description',
  'username' = 'vehicles',
  'password' = 'vehicles',
  'driver' = 'org.postgresql.Driver',
  'scan.fetch-size' = '200',
  'scan.partition.column' = 'vehicle_id',
  'scan.partition.lower-bound' = '0',
  'scan.partition.upper-bound' = '79',
  'scan.partition.num' = '5',
  'lookup.cache.max-rows' = '200',
  'lookup.cache.ttl' = '600 s'
);

CREATE TABLE vehicle_location (
  `vehicle_id` INT,
  `location` ROW<lat DOUBLE, lon DOUBLE>,
  `ts` BIGINT,
  `event_time` AS TO_TIMESTAMP_LTZ(ts, 3),
  WATERMARK FOR event_time AS event_time - INTERVAL '1' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-location',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'format' = 'avro-confluent',
  'scan.startup.mode' = 'earliest-offset',
  'scan.watermark.idle-timeout' = '5 seconds',
  'avro-confluent.url' = 'https://schemaregistry.confluent.svc.cluster.local:8081',
  'properties.security.protocol' = 'SSL',
  'properties.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'properties.ssl.truststore.password' = 'confluent',
  'properties.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'properties.ssl.keystore.password' = 'confluent',
  'properties.ssl.key.password' = 'confluent',
  'properties.ssl.endpoint.identification.algorithm' = '',
  'avro-confluent.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'avro-confluent.ssl.truststore.password' = 'confluent',
  'avro-confluent.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'avro-confluent.ssl.keystore.password' = 'confluent'
);

CREATE TABLE vehicle_info (
  `vehicle_id` INT,
  `engine_temperature` INT,
  `average_rpm` INT,
  `ts` BIGINT
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-info',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'format' = 'avro-confluent',
  'scan.startup.mode' = 'earliest-offset',
  'avro-confluent.url' = 'https://schemaregistry.confluent.svc.cluster.local:8081',
  'properties.security.protocol' = 'SSL',
  'properties.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'properties.ssl.truststore.password' = 'confluent',
  'properties.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'properties.ssl.keystore.password' = 'confluent',
  'properties.ssl.key.password' = 'confluent',
  'properties.ssl.endpoint.identification.algorithm' = '',
  'avro-confluent.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'avro-confluent.ssl.truststore.password' = 'confluent',
  'avro-confluent.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'avro-confluent.ssl.keystore.password' = 'confluent'
);


-- 2. Calculate the speed of each vehicle using the difference in time and location and generate alerts for those vehicles that travel over 120 km/h
CREATE VIEW vehicle_speed AS
SELECT
  vehicle_id,
  location.lat AS latitude,
  location.lon AS longitude,
  prev_latitude,
  prev_longitude,
  ts,
  prev_ts,
  IF(
    prev_event_time IS NOT NULL,
    2 * 6371 *
      ASIN(
        SQRT(
          POWER(SIN(RADIANS((location.lat - prev_latitude) / 2)), 2) +
          COS(RADIANS(prev_latitude)) * COS(RADIANS(location.lat)) *
          POWER(SIN(RADIANS((location.lon - prev_longitude) / 2)), 2)
        )
      )
      /
      (EXTRACT(EPOCH FROM event_time) - EXTRACT(EPOCH FROM prev_event_time)) * 3600,
    0
  ) AS speed_kmh
FROM (
  SELECT
    vehicle_id,
    location,
    ts,
    event_time,
    LAG(location.lat) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_latitude,
    LAG(location.lon) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_longitude,
    LAG(ts) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_ts,
    LAG(event_time) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_event_time
  FROM vehicle_location
);


-- 2b. Keep the latest known position per vehicle (deduplication keyed by vehicle_id).
-- Used to attach coordinates to engine/RPM alerts, which arrive without location.
CREATE VIEW vehicle_latest_location AS
SELECT vehicle_id, latitude, longitude
FROM (
  SELECT
    vehicle_id,
    location.lat AS latitude,
    location.lon AS longitude,
    ROW_NUMBER() OVER (PARTITION BY vehicle_id ORDER BY event_time DESC) AS row_num
  FROM vehicle_location
)
WHERE row_num = 1;


-- 3. Detect anomalies (engine_temperature > 245 or avg_rpm > 8800).
-- Thresholds sit in the far tail of the sensor distributions so alerts represent
-- genuine, rare exceptions rather than routine readings.
CREATE TABLE vehicle_alerts (
  `vehicle_id` INT,
  `alert_type` STRING,
  `alert_value` INT,
  `ts` BIGINT,
  `location` ROW<`lat` DOUBLE, `lon` DOUBLE>,
  PRIMARY KEY (vehicle_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'vehicle-alerts',
  'key.format' = 'json',
  'value.format' = 'avro-confluent',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.security.protocol' = 'SSL',
  'properties.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'properties.ssl.truststore.password' = 'confluent',
  'properties.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'properties.ssl.keystore.password' = 'confluent',
  'properties.ssl.key.password' = 'confluent',
  'value.avro-confluent.url' = 'https://schemaregistry.confluent.svc.cluster.local:8081',
  'value.avro-confluent.subject' = 'vehicleAlerts-value',
  'value.avro-confluent.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'value.avro-confluent.ssl.truststore.password' = 'confluent',
  'value.avro-confluent.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'value.avro-confluent.ssl.keystore.password' = 'confluent',
  'sink.buffer-flush.max-rows' = '1',
  'sink.buffer-flush.interval' = '1 s'
);


-- 4. Enrich alerts data with description and sensor readings
CREATE TABLE enriched_alerts (
  `vehicle_id` INT,
  `alert_type` STRING,
  `alert_value` INT,
  `ts` BIGINT,
  `vehicle_brand` STRING,
  `driver_name` STRING,
  `license_plate` STRING,
  `location` ROW<`lat` DOUBLE, `lon` DOUBLE>,
  `event_time` AS TO_TIMESTAMP_LTZ(ts, 3),
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND,
  PRIMARY KEY (vehicle_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'vehicle-alerts-enriched',
  'key.format' = 'json',
  'value.format' = 'avro-confluent',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.security.protocol' = 'SSL',
  'properties.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'properties.ssl.truststore.password' = 'confluent',
  'properties.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'properties.ssl.keystore.password' = 'confluent',
  'properties.ssl.key.password' = 'confluent',
  'value.avro-confluent.url' = 'https://schemaregistry.confluent.svc.cluster.local:8081',
  'value.avro-confluent.ssl.truststore.location' = '/mnt/secrets/flink-app1-tls/truststore.jks',
  'value.avro-confluent.ssl.truststore.password' = 'confluent',
  'value.avro-confluent.ssl.keystore.location' = '/mnt/secrets/flink-app1-tls/keystore.jks',
  'value.avro-confluent.ssl.keystore.password' = 'confluent',
  'sink.buffer-flush.max-rows' = '1',
  'sink.buffer-flush.interval' = '1 s'
);


SET 'parallelism.default' = '2';
-- The enriched alerts are stamped with wall-clock detection time (UNIX_TIMESTAMP()),
-- which is non-deterministic. We intentionally append each alert as-produced to
-- Elasticsearch, so the planner's non-deterministic-update check must not reject the
-- plan. IGNORE is the platform default; we set it explicitly to be safe.
SET 'table.optimizer.non-deterministic-update.strategy' = 'IGNORE';
EXECUTE STATEMENT SET
BEGIN

  -- Speed alerts already carry their coordinates (computed from the location stream).
  INSERT INTO vehicle_alerts
  SELECT
    vehicle_id,
    'EXCESSIVE_SPEED' AS alert_type,
    CAST(speed_kmh AS INT) as alert_value,
    ts,
    ROW(latitude, longitude)
  FROM vehicle_speed
  WHERE speed_kmh > 120;

  -- Engine/RPM alerts come from the sensor stream (no location), so attach the
  -- latest known position for the vehicle.
  INSERT INTO vehicle_alerts
  SELECT
    i.vehicle_id,
    'ENGINE_OVERHEAT' AS alert_type,
    i.engine_temperature as alert_value,
    i.ts,
    ROW(l.latitude, l.longitude)
  FROM vehicle_info i
  LEFT JOIN vehicle_latest_location l ON i.vehicle_id = l.vehicle_id
  WHERE i.engine_temperature > 245;

  INSERT INTO vehicle_alerts
  SELECT
    i.vehicle_id,
    'EXCESSIVE_RPM' AS alert_type,
    i.average_rpm as alert_value,
    i.ts,
    ROW(l.latitude, l.longitude)
  FROM vehicle_info i
  LEFT JOIN vehicle_latest_location l ON i.vehicle_id = l.vehicle_id
  WHERE i.average_rpm > 8800;

  INSERT INTO enriched_alerts
  SELECT
    a.vehicle_id,
    a.alert_type,
    a.alert_value,
    -- Stamp the alert with wall-clock detection time (epoch millis) instead of the
    -- simulated source timestamp, so the Kibana map can show a recent, fading time
    -- window of incidents.
    CAST(UNIX_TIMESTAMP() AS BIGINT) * 1000,
    d.vehicle_brand,
    d.driver_name,
    d.license_plate,
    a.location
  FROM `vehicle_alerts` a
  LEFT JOIN `vehicle_description` d ON a.vehicle_id = d.vehicle_id;

END;