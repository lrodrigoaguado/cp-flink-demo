# Realistic Vehicle Data Generation

This project uses a custom Python-based data generator to simulate realistic truck movements on Spanish highways. Unlike simple random data generators, this system uses real road geometries and physics-based movement.

## Overview

The data generator (`generate_data.py`) simulates a fleet of trucks traveling along major Spanish highways (A-1 through A-8). It publishes vehicle location updates to the `vehicle-location` Kafka topic in Avro format.

### Key Features

*   **Real Road Geometries**: Uses a merged dataset of **OpenStreetMap (OSM)** and **DGT** (Dirección General de Tráfico) data.
    *   **High Density**: First 200 km of A-1 to A-6 are sourced from OSM with ~2 points/km (every 500m).
    *   **Extended Coverage**: Remaining highway lengths and A-7/A-8 are sourced from DGT data.
*   **Realistic Physics**:
    *   **Speed**: Each truck is assigned a speed from a **Normal Distribution** (μ=current speed, σ=15 km/h), clamped between 75 and 145 km/h.
    *   **Movement**: Trucks follow the road points sequentially. Time between updates is calculated based on distance and speed ($t = d/v$).
    *   **Bi-directional**: Trucks travel back and forth along their assigned route.
*   **Simulation Time**:
    *   The simulation starts at a fixed timestamp: **January 1, 2025, 09:00:00**.
    *   Timestamps advance based on the simulated movement, not wall-clock time.

## Data Sources

The road points are stored in `etc/road_points_merged.json`.

## Python Script Details

The script `data/generate_data.py` handles the simulation:

*   **Dependencies**: `confluent-kafka`, `fastavro`, `requests` (installed automatically if missing).
*   **Configuration**:
    *   `KAFKA_BOOTSTRAP_SERVERS`: Kafka cluster address.
    *   `SCHEMA_REGISTRY_URL`: Schema Registry address.
    *   `ROAD_POINTS_FILE`: Path to the JSON file with road points.
*   **Logic**:
    *   Loads road points and sorts them by kilometer.
    *   Initializes `N` vehicles (default 50), assigning each a random route and speed.
    *   In a loop, calculates the next position for each vehicle using the Haversine formula.
    *   Publishes `fleet_mgmt_location` Avro records to Kafka.
