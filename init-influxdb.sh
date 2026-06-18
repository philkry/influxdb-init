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

# Label for the authorization this script creates. The bucket is included so
# the description is unique even when several services share an INFLUXDB_USER.
TOKEN_DESC="service-token-${INFLUXDB_USER}-${INFLUXDB_BUCKET}"

# Return a JSON array of the authorization(s) this script owns. Ownership is
# keyed on *write access to this bucket* (resource.id), which is the only value
# that is reliably unique per service — multiple services often share an
# INFLUXDB_USER (and therefore a description) but each writes its own bucket.
# Matching on the bucket avoids one service deleting another service's token.
fetch_owned_auths() {
    curl -s -X GET "${INFLUXDB_HOST}/api/v2/authorizations" \
      -H "Authorization: Token ${INFLUX_TOKEN}" \
    | jq --arg bid "$BUCKET_ID" \
        '[.authorizations[]? | select(.status == "active") | select(.permissions[]? | .action == "write" and .resource.id == $bid)]' 2>/dev/null || echo '[]'
}

# Create a fresh scoped authorization and echo its token. InfluxDB only ever
# returns a token's secret value in this create response — never on a later
# GET — so this is the ONLY place the value can be captured.
create_service_token() {
    BODY=$(jq -n \
      --arg desc "$TOKEN_DESC" \
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
        jq -r '.token // ""' "$RESPONSE_FILE"
        rm -f "$RESPONSE_FILE"
    else
        echo "Error creating authorization. HTTP status code: $HTTP_CODE" >&2
        rm -f "$RESPONSE_FILE"
        return 1
    fi
}

OWNED_AUTHS=$(fetch_owned_auths)
OWNED_COUNT=$(echo "$OWNED_AUTHS" | jq 'length' 2>/dev/null || echo 0)

# A token's secret is only returned at creation time. An already-existing
# authorization comes back from GET with an empty token, so on restarts this
# is expected to be empty — which is exactly why we must (re)create below
# instead of trusting whatever GET returns.
SERVICE_TOKEN=""
if [ "$OWNED_COUNT" -ge 1 ]; then
    SERVICE_TOKEN=$(echo "$OWNED_AUTHS" | jq -r '.[0].token // ""')
fi

if [ -n "$SERVICE_TOKEN" ]; then
    echo "Reusing existing service authorization."
else
    # Either no authorization exists yet, or one exists but its secret is
    # unrecoverable (InfluxDB never returns it after creation). Delete any
    # stale/duplicate owned authorizations and create a fresh one so we end up
    # holding a token whose value we actually know.
    if [ "$OWNED_COUNT" -ge 1 ]; then
        echo "Existing authorization token is unrecoverable; rotating ($OWNED_COUNT stale)..."
        for AUTH_ID in $(echo "$OWNED_AUTHS" | jq -r '.[].id'); do
            curl -s -o /dev/null -X DELETE \
              "${INFLUXDB_HOST}/api/v2/authorizations/${AUTH_ID}" \
              -H "Authorization: Token ${INFLUX_TOKEN}"
        done
    fi
    echo "Creating service authorization for bucket..."
    SERVICE_TOKEN=$(create_service_token)
    echo "Service authorization created successfully."
fi

# Never write an empty/invalid token to the shared volume. Failing loudly here
# beats silently breaking the consuming service, which would otherwise see
# "token required" / 401 on every write with no obvious cause.
if [ -z "$SERVICE_TOKEN" ] || [ "$SERVICE_TOKEN" = "null" ]; then
    echo "Error: failed to obtain a valid service token." >&2
    exit 1
fi

# Write token to shared volume for the main container
mkdir -p "$TOKEN_DIR"
printf '%s' "$SERVICE_TOKEN" > "${TOKEN_DIR}/token"
chmod 600 "${TOKEN_DIR}/token"
echo "Service token written to shared volume."

echo "InfluxDB initialization completed successfully for host ${INFLUXDB_HOST}."