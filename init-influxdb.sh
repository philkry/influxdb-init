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
    influx user create -n "$INFLUXDB_USER" -p "$INFLUXDB_PASSWORD" -o "$INFLUXDB_ORG" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}"
else
    echo "User $INFLUXDB_USER already exists."
fi

# Get bucket ID for permissions
BUCKET_ID=$(influx bucket list -o "$INFLUXDB_ORG" -n "$INFLUXDB_BUCKET" --hide-headers --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | cut -f 1)

# Token output directory (shared emptyDir volume with main container)
TOKEN_DIR=${TOKEN_DIR:-/shared/influxdb}

# Get the organization ID
ORG_ID=$(influx org list --name "$INFLUXDB_ORG" --hide-headers --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | cut -f 1)

# Fetch all authorizations and find ones that grant write access to our bucket
AUTH_RESPONSE=$(curl -s -X GET "${INFLUXDB_HOST}/api/v2/authorizations" \
  -H "Authorization: Token ${INFLUX_TOKEN}")

MATCHING_AUTHS=$(echo "$AUTH_RESPONSE" | jq --arg bid "$BUCKET_ID" \
  '[.authorizations[] | select(.status == "active") | select(.permissions[]? | .action == "write" and .resource.id == $bid)]')

MATCHING_COUNT=$(echo "$MATCHING_AUTHS" | jq 'length')

# Clean up duplicates — keep only the first matching authorization
if [ "$MATCHING_COUNT" -gt 1 ]; then
    echo "Found $MATCHING_COUNT authorizations for bucket — cleaning up duplicates..."
    KEEP_ID=$(echo "$MATCHING_AUTHS" | jq -r '.[0].id')
    for AUTH_ID in $(echo "$MATCHING_AUTHS" | jq -r '.[1:][].id'); do
        echo "  Removing duplicate authorization..."
        curl -s -o /dev/null -X DELETE \
          "${INFLUXDB_HOST}/api/v2/authorizations/${AUTH_ID}" \
          -H "Authorization: Token ${INFLUX_TOKEN}"
    done
    # Re-fetch after cleanup
    AUTH_RESPONSE=$(curl -s -X GET "${INFLUXDB_HOST}/api/v2/authorizations" \
      -H "Authorization: Token ${INFLUX_TOKEN}")
    MATCHING_AUTHS=$(echo "$AUTH_RESPONSE" | jq --arg bid "$BUCKET_ID" \
      '[.authorizations[] | select(.status == "active") | select(.permissions[]? | .action == "write" and .resource.id == $bid)]')
    MATCHING_COUNT=$(echo "$MATCHING_AUTHS" | jq 'length')
fi

if [ "$MATCHING_COUNT" -eq 1 ]; then
    echo "Authorization for bucket already exists."
    SERVICE_TOKEN=$(echo "$MATCHING_AUTHS" | jq -r '.[0].token')
elif [ "$MATCHING_COUNT" -eq 0 ]; then
    echo "Creating service authorization for bucket..."

    BODY=$(jq -n \
      --arg desc "service-token-${INFLUXDB_USER}" \
      --arg orgID "$ORG_ID" \
      --arg bucketID "$BUCKET_ID" \
      '{
        description: $desc,
        orgID: $orgID,
        permissions: [
          { action: "read", resource: { type: "buckets", id: $bucketID } },
          { action: "write", resource: { type: "buckets", id: $bucketID } }
        ]
      }')

    RESPONSE_FILE=$(mktemp)
    HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -X POST \
      "${INFLUXDB_HOST}/api/v2/authorizations" \
      -H "Authorization: Token ${INFLUX_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$BODY")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        SERVICE_TOKEN=$(jq -r '.token' "$RESPONSE_FILE")
        echo "Service authorization created successfully."
    else
        echo "Error creating authorization. HTTP status code: $HTTP_CODE"
        rm "$RESPONSE_FILE"
        exit 1
    fi

    rm "$RESPONSE_FILE"
else
    echo "ERROR: Unexpected state resolving authorizations."
    exit 1
fi

# Write token to shared volume for the main container
mkdir -p "$TOKEN_DIR"
printf '%s' "$SERVICE_TOKEN" > "${TOKEN_DIR}/token"
chmod 600 "${TOKEN_DIR}/token"
echo "Service token written to shared volume."

echo "InfluxDB initialization completed successfully for host ${INFLUXDB_HOST}."