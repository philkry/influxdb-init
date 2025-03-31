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
    
    # Check if our specific token already exists
    # We'll create a temporary file to store the response
    TOKEN_RESPONSE=$(mktemp)
    
    # Get all authorizations
    curl -s -X GET "${INFLUXDB_HOST}/api/v2/authorizations" \
      -H "Authorization: Token ${INFLUX_TOKEN}" > "$TOKEN_RESPONSE"
    
    # Look for our specific token value in the response
    # We can't directly check the token value as it's hidden in API responses
    # Instead, check if a token with our specific description exists for the user
    TOKEN_EXISTS=$(grep -c "\"description\":\"service-token-${INFLUXDB_USER}\"" "$TOKEN_RESPONSE" || true)
    rm "$TOKEN_RESPONSE"
    
    if [ "$TOKEN_EXISTS" -eq 0 ]; then
        # Create token with specific permissions and predefined value using the HTTP API
        echo "Creating service token for user ${INFLUXDB_USER}..."
        
        # Create a temporary file to store the response
        RESPONSE_FILE=$(mktemp)
        HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -X POST "${INFLUXDB_HOST}/api/v2/authorizations" \
          -H "Authorization: Token ${INFLUX_TOKEN}" \
          -H "Content-Type: application/json" \
          -d '{
            "description": "service-token-'"${INFLUXDB_USER}"'",
            "orgID": "'"${ORG_ID}"'",
            "permissions": [
              {
                "action": "read",
                "resource": {
                  "type": "buckets",
                  "id": "'"${BUCKET_ID}"'"
                }
              },
              {
                "action": "write",
                "resource": {
                  "type": "buckets",
                  "id": "'"${BUCKET_ID}"'"
                }
              }
            ],
            "token": "'"${USER_TOKEN}"'"
          }')
        
        # Check if the request was successful (2xx status code)
        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            echo "Predefined service token created successfully."
        else
            echo "Error creating token. HTTP status code: $HTTP_CODE"
            echo "Response: $(cat "$RESPONSE_FILE")"
            rm "$RESPONSE_FILE"
            exit 1
        fi
        
        rm "$RESPONSE_FILE"
    else
        echo "Service token already exists."
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