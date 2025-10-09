-- 1. Register Kafka topics as Flink tables
CREATE TABLE vehicle_description (
  `vehicle_id` INT,
  `vehicle_brand` STRING,
  `driver_name` STRING,
  `license_plate` STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-description',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'avro-confluent',
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

CREATE TABLE vehicle_location (
  `vehicle_id` INT,
  `location` ROW<latitude DOUBLE, longitude DOUBLE>,
  `ts` BIGINT,
  `event_time` AS TO_TIMESTAMP_LTZ(ts, 3),
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-location',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'format' = 'avro-confluent',
  'scan.startup.mode' = 'earliest-offset',
  'scan.watermark.idle-timeout' = '20 seconds',
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
  location.latitude AS latitude,
  location.longitude AS longitude,
  prev_latitude,
  prev_longitude,
  ts,
  prev_ts,
  IF(
    prev_event_time IS NOT NULL,
    2 * 6371 *
      ASIN(
        SQRT(
          POWER(SIN(RADIANS((location.latitude - prev_latitude) / 2)), 2) +
          COS(RADIANS(prev_latitude)) * COS(RADIANS(location.latitude)) *
          POWER(SIN(RADIANS((location.longitude - prev_longitude) / 2)), 2)
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
    LAG(location.latitude) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_latitude,
    LAG(location.longitude) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_longitude,
    LAG(ts) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_ts,
    LAG(event_time) OVER (PARTITION BY vehicle_id ORDER BY event_time) AS prev_event_time
  FROM vehicle_location
);


-- 3. Detect anomalies (engine_temperature > 110 or avg_rpm > 7500)
CREATE TABLE vehicle_alerts (
  `vehicle_id` INT,
  `alert_type` STRING,
  `alert_value` INT,
  `ts` BIGINT,
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
  'value.avro-confluent.ssl.keystore.password' = 'confluent'
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
  'value.avro-confluent.ssl.keystore.password' = 'confluent'
);



EXECUTE STATEMENT SET
BEGIN

  INSERT INTO vehicle_alerts
  SELECT
    vehicle_id,
    'EXCESSIVE_SPEED' AS alert_type,
    CAST(speed_kmh AS INT) as alert_value,
    ts
  FROM vehicle_speed
  WHERE speed_kmh > 120;

  INSERT INTO vehicle_alerts
  SELECT
    vehicle_id,
    'ENGINE_OVERHEAT' AS alert_type,
    engine_temperature as alert_value,
    ts
  FROM vehicle_info
  WHERE engine_temperature > 210;

  INSERT INTO vehicle_alerts
  SELECT
    vehicle_id,
    'EXCESSIVE_RPM' AS alert_type,
    average_rpm as alert_value,
    ts
  FROM vehicle_info
  WHERE average_rpm > 7500;

  INSERT INTO enriched_alerts
  SELECT
    a.vehicle_id,
    a.alert_type,
    a.alert_value,
    a.ts,
    d.vehicle_brand,
    d.driver_name,
    d.license_plate
  FROM `vehicle_alerts` a
  LEFT JOIN `vehicle_description` d ON a.vehicle_id = d.vehicle_id;

END;
