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

# If a predefined USER_TOKEN is provided, create that token
if [ -n "$USER_TOKEN" ]; then
    echo "Predefined USER_TOKEN provided, setting up custom token..."

    # Get the organization ID for token creation
    ORG_ID=$(influx org list --name "$INFLUXDB_ORG" --hide-headers --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | cut -f 1)

    # Fetch all authorizations and find ones that grant write access to our bucket
    AUTH_RESPONSE=$(curl -s -X GET "${INFLUXDB_HOST}/api/v2/authorizations" \
      -H "Authorization: Token ${INFLUX_TOKEN}")

    # Find authorization IDs that have write permission on BUCKET_ID
    MATCHING_AUTH_IDS=$(echo "$AUTH_RESPONSE" | jq -r --arg bid "$BUCKET_ID" \
      '[.authorizations[] | select(.permissions[]? | .action == "write" and .resource.id == $bid)] | .[].id')

    MATCHING_COUNT=$(echo "$MATCHING_AUTH_IDS" | grep -c . || true)

    if [ "$MATCHING_COUNT" -gt 0 ]; then
        echo "Found $MATCHING_COUNT existing authorization(s) for bucket $BUCKET_ID."

        # Check if any of them have a token matching USER_TOKEN
        MATCHING_TOKEN_ID=$(echo "$AUTH_RESPONSE" | jq -r --arg bid "$BUCKET_ID" --arg tok "$USER_TOKEN" \
          '[.authorizations[] | select(.token == $tok) | select(.permissions[]? | .action == "write" and .resource.id == $bid)] | .[0].id // empty')

        if [ -n "$MATCHING_TOKEN_ID" ]; then
            echo "Authorization $MATCHING_TOKEN_ID already exists with the correct token. No action needed."

            # Clean up duplicates: remove other auths for the same bucket (keep only the matching one)
            for AUTH_ID in $MATCHING_AUTH_IDS; do
                if [ "$AUTH_ID" != "$MATCHING_TOKEN_ID" ]; then
                    echo "Removing duplicate authorization $AUTH_ID..."
                    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                      "${INFLUXDB_HOST}/api/v2/authorizations/${AUTH_ID}" \
                      -H "Authorization: Token ${INFLUX_TOKEN}")
                    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                        echo "  Deleted duplicate $AUTH_ID."
                    else
                        echo "  Warning: failed to delete $AUTH_ID (HTTP $HTTP_CODE)."
                    fi
                fi
            done
        else
            echo "WARNING: Existing authorization(s) found for bucket $BUCKET_ID but none match the predefined USER_TOKEN."
            echo "This means InfluxDB previously generated a random token instead of using the predefined value."
            echo "Removing stale authorizations and creating a new one..."

            for AUTH_ID in $MATCHING_AUTH_IDS; do
                echo "  Removing stale authorization $AUTH_ID..."
                curl -s -o /dev/null -X DELETE \
                  "${INFLUXDB_HOST}/api/v2/authorizations/${AUTH_ID}" \
                  -H "Authorization: Token ${INFLUX_TOKEN}"
            done

            # Fall through to create a new token below
            MATCHING_COUNT=0
        fi
    fi

    if [ "$MATCHING_COUNT" -eq 0 ]; then
        echo "Creating service token for user ${INFLUXDB_USER}..."

        # Build JSON body safely with jq
        BODY=$(jq -n \
          --arg desc "service-token-${INFLUXDB_USER}" \
          --arg orgID "$ORG_ID" \
          --arg bucketID "$BUCKET_ID" \
          --arg token "$USER_TOKEN" \
          '{
            description: $desc,
            orgID: $orgID,
            permissions: [
              { action: "read", resource: { type: "buckets", id: $bucketID } },
              { action: "write", resource: { type: "buckets", id: $bucketID } }
            ],
            token: $token
          }')

        RESPONSE_FILE=$(mktemp)
        HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -X POST \
          "${INFLUXDB_HOST}/api/v2/authorizations" \
          -H "Authorization: Token ${INFLUX_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "$BODY")

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            # Verify the created token matches the predefined value
            CREATED_TOKEN=$(jq -r '.token' "$RESPONSE_FILE")
            if [ "$CREATED_TOKEN" = "$USER_TOKEN" ]; then
                echo "Service token created successfully and matches predefined value."
            else
                echo "ERROR: InfluxDB did not honor the predefined token value."
                echo "Generated token: $CREATED_TOKEN"
                echo "You must update the secret store with the generated token above."
                rm "$RESPONSE_FILE"
                exit 1
            fi
        else
            echo "Error creating token. HTTP status code: $HTTP_CODE"
            echo "Response: $(cat "$RESPONSE_FILE")"
            rm "$RESPONSE_FILE"
            exit 1
        fi

        rm "$RESPONSE_FILE"
    fi
else
    # Traditional user authorization approach (backward compatibility)
    echo "No predefined USER_TOKEN provided, using standard authorization..."

    # Check if authorization already exists
    if ! influx auth list -o "$INFLUXDB_ORG" --user "$INFLUXDB_USER" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}" | grep -q "$BUCKET_ID"; then
        # Create authorization
        influx auth create -o "$INFLUXDB_ORG" --user "$INFLUXDB_USER" --read-bucket "$BUCKET_ID" --write-bucket "$BUCKET_ID" --host "${INFLUXDB_HOST}" --token "${INFLUX_TOKEN}"
    else
        echo "Authorization for user $INFLUXDB_USER on bucket $INFLUXDB_BUCKET already exists."
    fi
fi

echo "InfluxDB initialization completed successfully for host ${INFLUXDB_HOST}."