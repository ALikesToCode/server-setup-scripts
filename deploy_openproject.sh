#!/bin/bash

# Script to deploy or reset OpenProject Docker environment using host bind mounts.

# --- Configuration ---
# Assumes this script is in 'server-setup-scripts' and docker-compose.yml is in 'server-setup-scripts/openproject/'
SCRIPT_DIR_NAME="server-setup-scripts" # Used to form relative paths if needed, or use absolute
PROJECT_ROOT_DIR=$(pwd) # Assuming script is run from server-setup-scripts

# If your script is *inside* server-setup-scripts, adjust OPENPROJECT_DIR logic if needed
# This assumes docker-compose.yml is in a subdirectory named 'openproject'
COMPOSE_FILE_PATH="${PROJECT_ROOT_DIR}/openproject/docker-compose.yml"
OPENPROJECT_COMPOSE_DIR="${PROJECT_ROOT_DIR}/openproject" # Directory containing the docker-compose.yml

# Host paths for data (these MUST match what's in your docker-compose.yml)
HOST_DATA_ROOT="/opt/openproject_data"
POSTGRES_DATA_PATH="${HOST_DATA_ROOT}/postgres"
REDIS_DATA_PATH="${HOST_DATA_ROOT}/redis"
ASSETS_DATA_PATH="${HOST_DATA_ROOT}/assets"

# UIDs/GIDs required by the services inside their containers
# Determined from previous investigation on your Oracle Cloud instance:
POSTGRES_UID=70
POSTGRES_GID=70
REDIS_UID=999
REDIS_GID=1000 # This GID corresponds to the 'opc' group on your host
APP_UID=1000   # This UID corresponds to the 'opc' user on your host
APP_GID=1000   # This GID corresponds to the 'opc' group on your host

# Old Docker named volumes (to be removed if switching to bind mounts)
OLD_POSTGRES_VOLUME="openproject_postgres_data"
OLD_REDIS_VOLUME="openproject_redis_data"
OLD_ASSETS_VOLUME="openproject_openproject_assets"

# --- Helper Functions ---
ensure_docker_daemon() {
    echo "INFO: Checking Docker daemon status..."
    if ! sudo docker info > /dev/null 2>&1; then
        echo "ERROR: Docker daemon is not running or not accessible."
        echo "Attempting to start Docker service..."
        sudo systemctl start docker
        sleep 3 # Give it a moment
        if ! sudo docker info > /dev/null 2>&1; then
            echo "ERROR: Failed to start Docker. Please check Docker installation and ensure it's running."
            exit 1
        fi
        echo "INFO: Docker daemon started successfully."
    else
        echo "INFO: Docker daemon is running."
    fi
}

setup_host_directories() {
    echo "INFO: Creating host directories for OpenProject data in ${HOST_DATA_ROOT}..."
    sudo mkdir -p "${POSTGRES_DATA_PATH}"
    sudo mkdir -p "${REDIS_DATA_PATH}"
    sudo mkdir -p "${ASSETS_DATA_PATH}"
    echo "INFO: Host directories created/ensured."

    echo "INFO: Setting ownership for host directories..."
    sudo chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${POSTGRES_DATA_PATH}"
    sudo chown -R "${REDIS_UID}:${REDIS_GID}" "${REDIS_DATA_PATH}"
    sudo chown -R "${APP_UID}:${APP_GID}" "${ASSETS_DATA_PATH}"
    echo "INFO: Ownership set."

    echo "INFO: Verifying ownership (ls -ld will show names like 'opc' if they map to these UIDs/GIDs):"
    ls -ld "${POSTGRES_DATA_PATH}"
    ls -ld "${REDIS_DATA_PATH}"
    ls -ld "${ASSETS_DATA_PATH}"
}

remove_old_named_volumes() {
    echo "INFO: Attempting to remove old Docker named volumes (errors are okay if volumes don't exist)..."
    sudo docker volume rm "${OLD_POSTGRES_VOLUME}" 2>/dev/null || true
    sudo docker volume rm "${OLD_REDIS_VOLUME}" 2>/dev/null || true
    sudo docker volume rm "${OLD_ASSETS_VOLUME}" 2>/dev/null || true
    echo "INFO: Old named volumes cleanup attempt finished."
}

start_services() {
    echo "INFO: Starting OpenProject services using Docker Compose..."
    # Ensure .env file exists in the OPENPROJECT_COMPOSE_DIR
    if [ ! -f "${OPENPROJECT_COMPOSE_DIR}/.env" ]; then
        echo "WARNING: ${OPENPROJECT_COMPOSE_DIR}/.env file not found!"
        echo "         OpenProject might not start correctly without its environment configurations."
        echo "         Please create it from .env.example and customize it."
    fi
    sudo docker compose -f "${COMPOSE_FILE_PATH}" up -d
    echo "INFO: Docker Compose 'up -d' command executed."
    echo "      Wait about a minute for services to initialize, then check status with: $0 status"
}

stop_services() {
    echo "INFO: Stopping OpenProject services..."
    sudo docker compose -f "${COMPOSE_FILE_PATH}" down --remove-orphans
    echo "INFO: OpenProject services stopped."
}

show_status() {
    echo "INFO: Current status of OpenProject services:"
    sudo docker compose -f "${COMPOSE_FILE_PATH}" ps
}

show_logs() {
    SERVICE_NAME=$1
    echo "INFO: Displaying last 100 log lines."
    if [ -z "${SERVICE_NAME}" ]; then
        echo "      Showing logs for all services. For specific service: $0 logs <service_name>"
        sudo docker compose -f "${COMPOSE_FILE_PATH}" logs --tail=100
    else
        echo "      Showing logs for service: ${SERVICE_NAME}"
        sudo docker compose -f "${COMPOSE_FILE_PATH}" logs --tail=100 "${SERVICE_NAME}"
    fi
}

# --- Main Logic ---
ACTION=$1

if [ -z "$ACTION" ]; then
    echo "Usage: $0 {deploy|reset|start|stop|status|logs [service_name]|fixdirs}"
    exit 1
fi

ensure_docker_daemon

case "$ACTION" in
    deploy|init)
        echo "--- Initial Deploy/Setup ---"
        stop_services # Stop if already running from a previous attempt
        remove_old_named_volumes
        setup_host_directories
        start_services
        echo "--- Deployment initiated. ---"
        ;;
    reset)
        echo "--- Full Reset ---"
        stop_services
        echo "INFO: Removing old named volumes (if any)..."
        remove_old_named_volumes
        echo "INFO: Re-setting up host directories and permissions..."
        setup_host_directories # Re-create and re-apply permissions
        start_services
        echo "--- Reset and deployment initiated. ---"
        ;;
    start)
        echo "--- Starting Services ---"
        # Assuming host directories are already set up and have correct permissions
        start_services
        echo "--- Start command issued. ---"
        ;;
    stop)
        echo "--- Stopping Services ---"
        stop_services
        echo "--- Services stopped. ---"
        ;;
    status)
        echo "--- Service Status ---"
        show_status
        ;;
    logs)
        echo "--- Service Logs ---"
        show_logs "$2" # Pass the service name (optional second argument)
        ;;
    fixdirs)
        echo "--- Fixing Host Directory Permissions Only ---"
        # This action can be used if services are down and you only want to re-apply permissions
        setup_host_directories
        echo "--- Directory permissions re-applied. You may need to restart services. ---"
        ;;
    *)
        echo "ERROR: Invalid action '$ACTION'"
        echo "Usage: $0 {deploy|reset|start|stop|status|logs [service_name]|fixdirs}"
        exit 1
        ;;
esac

exit 0 