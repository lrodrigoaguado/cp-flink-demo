-- 1. Register Kafka topics as Flink tables

CREATE TABLE vehicle_description (
  vehicle_id INT,
  driver_name STRING,
  license_plate STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-description',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'format' = 'json',
  'scan.startup.mode' = 'earliest-offset'
);

CREATE TABLE vehicle_location (
  vehicle_id INT,
  location ROW<latitude DOUBLE, longitude DOUBLE>,
  ts BIGINT, -- epoch millis
  event_time AS TO_TIMESTAMP_LTZ(ts, 3),
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-location',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'format' = 'json',
  'scan.startup.mode' = 'earliest-offset'
);

CREATE TABLE vehicle_info (
  vehicle_id INT,
  engine_temperature INT,
  average_rpm INT
) WITH (
  'connector' = 'kafka',
  'topic' = 'vehicle-info',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'properties.group.id' = 'flink-sql-job',
  'format' = 'json',
  'scan.startup.mode' = 'earliest-offset'
);

-- 2. Enrich location data with description and sensor readings

CREATE TABLE enriched_events (
  vehicle_id INT,
  driver_name STRING,
  license_plate STRING,
  latitude DOUBLE,
  longitude DOUBLE,
  engine_temperature INT,
  average_rpm INT,
  ts BIGINT,
  event_time AS TO_TIMESTAMP_LTZ(ts, 3),
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND,
  PRIMARY KEY (vehicle_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'vehicle-enriched',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format' = 'json',
  'value.format' = 'json'
);

INSERT INTO enriched_events
SELECT
  l.vehicle_id,
  d.driver_name,
  d.license_plate,
  l.location.latitude,
  l.location.longitude,
  s.engine_temperature,
  s.average_rpm,
  l.ts
FROM vehicle_location l
LEFT JOIN vehicle_description d ON l.vehicle_id = d.vehicle_id
LEFT JOIN vehicle_info s ON l.vehicle_id = s.vehicle_id;

-- 3. Detect anomalies (e.g., engine_temperature > 110)

CREATE TABLE vehicle_alerts (
  vehicle_id INT,
  alert_type STRING,
  engine_temperature INT,
  average_rpm INT,
  ts BIGINT,
  PRIMARY KEY (vehicle_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'vehicle-alerts',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format' = 'json',
  'value.format' = 'json'
);

INSERT INTO vehicle_alerts
SELECT
  vehicle_id,
  'ENGINE_OVERHEAT' AS alert_type,
  engine_temperature,
  average_rpm,
  ts
FROM enriched_events
WHERE engine_temperature > 110;


-- 4. Calculate the speed of each vehicle using the difference in time and location and generate alerts for those vehicles that travel over 120 km/h

CREATE TABLE vehicle_speed (
  vehicle_id INT,
  latitude DOUBLE,
  longitude DOUBLE,
  prev_latitude DOUBLE,
  prev_longitude DOUBLE,
  ts BIGINT,
  prev_ts BIGINT,
  speed_kmh DOUBLE,
  PRIMARY KEY (vehicle_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'vehicle-speed',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format' = 'json',
  'value.format' = 'json'
);

INSERT INTO vehicle_speed
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

CREATE TABLE speed_alerts (
  vehicle_id INT,
  speed_kmh DOUBLE,
  ts BIGINT,
  PRIMARY KEY (vehicle_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'vehicle-alerts',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format' = 'json',
  'value.format' = 'json'
);

INSERT INTO speed_alerts
SELECT
  vehicle_id,
  speed_kmh,
  ts
FROM vehicle_speed
WHERE speed_kmh > 120;

-- 5. Aggregate KPIs (average engine_temperature per minute)

CREATE TABLE fleet_kpis (
  window_start TIMESTAMP(3),
  window_end TIMESTAMP(3),
  avg_engine_temp DOUBLE,
  avg_rpm DOUBLE,
  vehicle_count BIGINT,
  PRIMARY KEY (window_start, window_end) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = 'fleet-mgmt-kpis',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format' = 'json',
  'value.format' = 'json'
);

INSERT INTO fleet_kpis
SELECT
  window_start,
  window_end,
  AVG(engine_temperature) AS avg_engine_temp,
  AVG(average_rpm) AS avg_rpm,
  COUNT(DISTINCT vehicle_id) AS vehicle_count
FROM TABLE(
  TUMBLE(TABLE enriched_events, DESCRIPTOR(event_time), INTERVAL '1' MINUTE)
)
GROUP BY window_start, window_end;
