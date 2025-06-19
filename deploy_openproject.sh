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

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ENV_FILE="openproject/.env"
DATA_DIR="/opt/openproject_data"

# --- Helper Functions ---
ensure_docker_daemon() {
    echo -e "${BLUE}INFO: Checking Docker daemon status...${NC}"
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Docker is not running. Please start Docker first.${NC}"
        exit 1
    fi
    echo -e "${GREEN}INFO: Docker daemon is running.${NC}"
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

# Fix all permission issues for OpenProject containers
fix_permissions() {
    echo -e "${YELLOW}--- Fixing OpenProject Container Permissions ---${NC}"
    echo -e "${BLUE}INFO: Applying comprehensive permission fixes...${NC}"
    
    # Create data directories if they don't exist
    sudo mkdir -p ${DATA_DIR}/{assets,postgres,redis}
    
    # Fix 1: OpenProject assets directory (OpenProject containers run as user 1001:1001)
    echo -e "${BLUE}INFO: Setting permissions for assets directory...${NC}"
    sudo chown -R 1001:1001 ${DATA_DIR}/assets
    sudo chmod -R 755 ${DATA_DIR}/assets
    
    # Fix 2: PostgreSQL data directory (PostgreSQL runs as user 70:70 in alpine container)
    echo -e "${BLUE}INFO: Setting permissions for PostgreSQL directory...${NC}"
    sudo chown -R 70:70 ${DATA_DIR}/postgres
    sudo chmod -R 700 ${DATA_DIR}/postgres
    
    # Fix 3: Redis data directory (Redis runs as user 999:999)
    echo -e "${BLUE}INFO: Setting permissions for Redis directory...${NC}"
    sudo chown -R 999:999 ${DATA_DIR}/redis
    sudo chmod -R 755 ${DATA_DIR}/redis
    
    echo -e "${GREEN}INFO: Permission fixes applied successfully.${NC}"
    echo -e "${YELLOW}--- Permission Fixes Complete ---${NC}"
}

# Fix OpenProject container assets permissions (for running containers)
fix_container_permissions() {
    echo -e "${YELLOW}--- Fixing Container Internal Permissions ---${NC}"
    echo -e "${BLUE}INFO: Fixing OpenProject container internal permissions...${NC}"
    
    # Check if containers are running
    if docker ps | grep -q "openproject.*web"; then
        echo -e "${BLUE}INFO: Fixing assets permissions inside web container...${NC}"
        docker exec -u root $(docker ps -q -f name=openproject.*web) chown -R app:app /var/openproject/assets 2>/dev/null || true
        
        echo -e "${BLUE}INFO: Fixing temp directory permissions inside web container...${NC}"
        docker exec -u root $(docker ps -q -f name=openproject.*web) chown -R app:app /app/tmp 2>/dev/null || true
        docker exec -u root $(docker ps -q -f name=openproject.*web) mkdir -p /app/tmp/pids 2>/dev/null || true
        docker exec -u root $(docker ps -q -f name=openproject.*web) chown -R app:app /app/tmp/pids 2>/dev/null || true
    fi
    
    if docker ps | grep -q "openproject.*worker"; then
        echo -e "${BLUE}INFO: Fixing assets permissions inside worker container...${NC}"
        docker exec -u root $(docker ps -q -f name=openproject.*worker) chown -R app:app /var/openproject/assets 2>/dev/null || true
        
        echo -e "${BLUE}INFO: Fixing temp directory permissions inside worker container...${NC}"
        docker exec -u root $(docker ps -q -f name=openproject.*worker) chown -R app:app /app/tmp 2>/dev/null || true
        docker exec -u root $(docker ps -q -f name=openproject.*worker) mkdir -p /app/tmp/pids 2>/dev/null || true
        docker exec -u root $(docker ps -q -f name=openproject.*worker) chown -R app:app /app/tmp/pids 2>/dev/null || true
    fi
    
    echo -e "${GREEN}INFO: Container internal permission fixes applied.${NC}"
    echo -e "${YELLOW}--- Container Permission Fixes Complete ---${NC}"
}

# Fix directory permissions before deployment
fixdirs() {
    fix_permissions
}

# Check if Docker is installed and running (updated function name)
check_docker() {
    echo -e "${BLUE}INFO: Checking Docker daemon status...${NC}"
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Docker is not running. Please start Docker first.${NC}"
        exit 1
    fi
    echo -e "${GREEN}INFO: Docker daemon is running.${NC}"
}

# Deploy OpenProject
deploy() {
    ensure_docker_daemon
    echo -e "${YELLOW}--- Starting OpenProject Deployment ---${NC}"
    
    # Apply permission fixes before deployment
    fix_permissions
    
    echo -e "${BLUE}INFO: Starting OpenProject services...${NC}"
    cd openproject && docker compose up -d --build --pull always
    
    # Wait a moment for containers to start
    echo -e "${BLUE}INFO: Waiting for containers to initialize...${NC}"
    sleep 30
    
    # Apply container-level permission fixes
    fix_container_permissions
    
    echo -e "${GREEN}INFO: OpenProject deployment completed.${NC}"
    echo -e "${YELLOW}--- Deployment Complete ---${NC}"
}

# --- Main Logic ---
ACTION=$1

if [ -z "$ACTION" ]; then
    echo "Usage: $0 {deploy|reset|start|stop|status|logs [service_name]|fixdirs|fixperms}"
    echo ""
    echo "Commands:"
    echo "  deploy   - Full deployment with comprehensive permission fixes"
    echo "  reset    - Stop, cleanup, and redeploy everything"
    echo "  start    - Start services with permission fixes"
    echo "  stop     - Stop all services"
    echo "  status   - Show container status"
    echo "  logs     - Show container logs (optionally for specific service)"
    echo "  fixdirs  - Fix host directory permissions only"
    echo "  fixperms - Fix running container permissions"
    echo ""
    echo "Note: This script includes comprehensive permission fixes for OpenProject Docker containers"
    echo "      based on community best practices to resolve common permission issues."
    exit 1
fi

ensure_docker_daemon

case "$ACTION" in
    deploy|init)
        # Use the new improved deploy function
        deploy
        ;;
    reset)
        echo -e "${YELLOW}--- Full Reset ---${NC}"
        stop_services
        echo -e "${BLUE}INFO: Removing old named volumes (if any)...${NC}"
        remove_old_named_volumes
        echo -e "${BLUE}INFO: Re-setting up host directories and permissions...${NC}"
        setup_host_directories # Re-create and re-apply permissions
        fix_permissions # Apply new permission fixes
        start_services
        echo -e "${GREEN}--- Reset and deployment initiated. ---${NC}"
        ;;
    start)
        echo -e "${YELLOW}--- Starting Services ---${NC}"
        # Apply permission fixes before starting
        fix_permissions
        start_services
        # Apply container-level permission fixes after starting
        sleep 20
        fix_container_permissions
        echo -e "${GREEN}--- Start command completed. ---${NC}"
        ;;
    stop)
        echo -e "${YELLOW}--- Stopping Services ---${NC}"
        stop_services
        echo -e "${GREEN}--- Services stopped. ---${NC}"
        ;;
    status)
        echo -e "${YELLOW}--- Service Status ---${NC}"
        show_status
        ;;
    logs)
        echo -e "${YELLOW}--- Service Logs ---${NC}"
        show_logs "$2" # Pass the service name (optional second argument)
        ;;
    fixdirs)
        echo -e "${YELLOW}--- Fixing Host Directory Permissions Only ---${NC}"
        # This action can be used if services are down and you only want to re-apply permissions
        setup_host_directories
        fix_permissions
        echo -e "${GREEN}--- Directory permissions re-applied. You may need to restart services. ---${NC}"
        ;;
    fixperms)
        echo -e "${YELLOW}--- Fixing Container Permissions (Running Containers) ---${NC}"
        fix_container_permissions
        echo -e "${GREEN}--- Container permission fixes applied. ---${NC}"
        ;;
    *)
        echo -e "${RED}ERROR: Invalid action '$ACTION'${NC}"
        echo "Usage: $0 {deploy|reset|start|stop|status|logs [service_name]|fixdirs|fixperms}"
        exit 1
        ;;
esac

exit 0 