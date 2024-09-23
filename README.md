# InfluxDB 2 Init Container

This init container bootstraps an InfluxDB 2 instance in a Kubernetes environment. It creates an organization, a bucket, and a user with full access to that bucket. All configuration is done through environment variables.

## Building the Docker Image

1. Clone this repository and navigate to the directory containing the Dockerfile.

2. Build the Docker image:
   ```bash
   docker build -t influxdb-init:latest .
   ```

3. Push the image to your container registry:
   ```bash
   docker tag influxdb-init:latest your-registry/influxdb-init:latest
   docker push your-registry/influxdb-init:latest
   ```

   Replace `your-registry` with your actual container registry.

## Using the Init Container

To use this init container in your Kubernetes deployment:

1. Ensure you have a Kubernetes secret containing the necessary credentials:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: influxdb-secrets
   type: Opaque
   stringData:
     admin-username: your-admin-username
     admin-password: your-admin-password
     admin-token: your-admin-token
   ```

2. In your InfluxDB deployment, add the init container specification:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: influxdb
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: influxdb
     template:
       metadata:
         labels:
           app: influxdb
       spec:
         initContainers:
         - name: init-influxdb
           image: your-registry/influxdb-init:latest
           env:
           - name: INFLUXDB_HOST
             value: "http://localhost:8086"
           - name: INFLUXDB_ORG
             value: "your-org"
           - name: INFLUXDB_BUCKET
             value: "your-bucket"
           - name: INFLUXDB_USER
             valueFrom:
               secretKeyRef:
                 name: influxdb-secrets
                 key: admin-username
           - name: INFLUXDB_PASSWORD
             valueFrom:
               secretKeyRef:
                 name: influxdb-secrets
                 key: admin-password
           - name: INFLUX_TOKEN
             valueFrom:
               secretKeyRef:
                 name: influxdb-secrets
                 key: admin-token
         containers:
         - name: influxdb
           image: influxdb:2.7
           # ... (rest of your InfluxDB container configuration)
   ```

## Environment Variables

The init container requires the following environment variables:

- `INFLUXDB_HOST`: The URL of the InfluxDB instance (default: http://localhost:8086)
- `INFLUXDB_ORG`: The name of the organization to create
- `INFLUXDB_BUCKET`: The name of the bucket to create
- `INFLUXDB_USER`: The username for the new user
- `INFLUXDB_PASSWORD`: The password for the new user
- `INFLUX_TOKEN`: An admin token for authentication (required)

## What the Init Container Does

1. Waits for the InfluxDB instance to be ready
2. Authenticates using the provided admin token
3. Creates the specified organization
4. Creates the specified bucket
5. Creates a user with the given username and password
6. Grants the user full access to the created bucket

The init container runs to completion before the main InfluxDB container starts, ensuring that the InfluxDB instance is properly initialized with the desired configuration.

## Note

Ensure that the InfluxDB instance is configured to use the same organization, bucket, and credentials that you specify in the init container's environment variables.