#!/bin/sh
set -e

# Set default InfluxDB host if not provided
INFLUXDB_HOST=${INFLUXDB_HOST:-http://influxdb:8086}

# Check if INFLUX_TOKEN is provided
if [ -z "$INFLUX_TOKEN" ]; then
    echo "Error: INFLUX_TOKEN is not set. Please provide an admin token for authentication."
    exit 1
fi

# Wait for InfluxDB to be ready
until curl -s "${INFLUXDB_HOST}/health" > /dev/null; do
    echo "Waiting for InfluxDB to be ready at ${INFLUXDB_HOST}..."
    sleep 1
done

# Check if organization exists
if ! influx org list --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | grep -q "$INFLUXDB_ORG"; then
    # Create organization
    influx org create -n "$INFLUXDB_ORG" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}"
else
    echo "Organization $INFLUXDB_ORG already exists."
fi

# Check if bucket exists
if ! influx bucket list -o "$INFLUXDB_ORG" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | grep -q "$INFLUXDB_BUCKET"; then
    # Create bucket
    influx bucket create -n "$INFLUXDB_BUCKET" -o "$INFLUXDB_ORG" -r 0 --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}"
else
    echo "Bucket $INFLUXDB_BUCKET already exists."
fi

# Check if user exists
if ! influx user list --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | grep -q "$INFLUXDB_USER"; then
    # Create user
    influx user create -n "$INFLUXDB_USER" -p "$INFLUXDB_PASSWORD" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}"
else
    echo "User $INFLUXDB_USER already exists."
fi

# Grant user full access to the bucket
BUCKET_ID=$(influx bucket list -o "$INFLUXDB_ORG" -n "$INFLUXDB_BUCKET" --hide-headers --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | cut -f 1)


# Check if authorization already exists
if ! influx auth list -o "$INFLUXDB_ORG" --user "$INFLUXDB_USER" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | grep -q "$BUCKET_ID"; then
    # Create authorization
    influx auth create -o "$INFLUXDB_ORG" --user "$INFLUXDB_USER" --read-bucket "$BUCKET_ID" --write-bucket "$BUCKET_ID" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}"
else
    echo "Authorization for user $INFLUXDB_USER on bucket $INFLUXDB_BUCKET already exists."
fi

echo "InfluxDB initialization completed successfully for host ${INFLUXDB_HOST}."