
# InfluxDB 2 Init Container

This project provides an init container for bootstrapping an InfluxDB 2 instance in a Kubernetes environment. It automates the process of creating an organization, a bucket, and a user with full access to that bucket.

## Contents

The project consists of the following main components:

1. Dockerfile
2. README.md
3. init-influxdb.sh
4. GitHub Actions workflow for releases

## Inputs

The init container requires the following environment variables:

- `INFLUXDB_HOST`: The URL of the InfluxDB instance (default: http://localhost:8086)
- `INFLUXDB_ORG`: The name of the organization to create
- `INFLUXDB_BUCKET`: The name of the bucket to create
- `INFLUXDB_USER`: The username for the new user
- `INFLUXDB_PASSWORD`: The password for the new user
- `INFLUX_TOKEN`: An admin token for authentication (required)

## Outputs

The init container does not produce any direct outputs. However, it results in the following actions:

1. Creation of an organization (if it doesn't exist)
2. Creation of a bucket (if it doesn't exist)
3. Creation of a user (if it doesn't exist)
4. Granting full access to the bucket for the user

## Usage

1. Build the Docker image using the provided Dockerfile.
2. Push the image to a container registry.
3. Use the init container in your Kubernetes deployment by adding it to the `initContainers` section of your InfluxDB deployment YAML.
4. Ensure all required environment variables are set, preferably using Kubernetes secrets for sensitive information.

## Key Features

- Idempotent operations: The script checks for the existence of entities before creating them.
- Waits for InfluxDB to be ready before proceeding with operations.
- Uses InfluxDB CLI commands for all operations.
- Provides clear error messages and status updates.

## Automated Releases

The project includes a GitHub Actions workflow (`release.yaml`) that automates the process of building, tagging, and pushing Docker images to GitHub Container Registry (ghcr.io) when a new tag is pushed to the repository. The workflow also signs the Docker image using cosign for enhanced security.

## Best Practices

- Use Kubernetes secrets to manage sensitive information like passwords and tokens.
- Ensure the InfluxDB instance is configured to use the same organization, bucket, and credentials specified in the init container's environment variables.
- Regularly update the base InfluxDB image version in the Dockerfile to ensure you're using the latest features and security updates.

This init container simplifies the process of setting up InfluxDB 2 in a Kubernetes environment, making it easier to deploy and manage InfluxDB instances with consistent configuration across different environments.
