#!/bin/bash
set -euo pipefail

# Production deployment script
ENVIRONMENT=${ENVIRONMENT:-production}
COMPOSE_FILE="docker-compose.prod.yml"

echo "🚀 Starting OpenProject deployment for ${ENVIRONMENT}"

# Pre-deployment checks
check_prerequisites() {
    echo "✅ Checking prerequisites..."
    
    # Check if secrets exist
    for secret in postgres_password openproject_secret grafana_password; do
        if [[ ! -f "./secrets/${secret}.txt" ]]; then
            echo "❌ Missing secret: ${secret}.txt"
            exit 1
        fi
    done
    
    # Check if .env file exists
    if [[ ! -f ".env" ]]; then
        echo "❌ Missing .env file"
        exit 1
    fi
    
    # Validate environment variables
    required_vars=(
        "OPENPROJECT_HOST__NAME"
        "POSTGRES_USER"
        "POSTGRES_DB"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "❌ Missing required environment variable: ${var}"
            exit 1
        fi
    done
}

# Database backup before deployment
backup_database() {
    echo "💾 Creating database backup..."
    docker-compose -f ${COMPOSE_FILE} exec db pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} | gzip > "backups/pre-deploy-$(date +%Y%m%d-%H%M%S).sql.gz"
}

# Deploy with rolling updates
deploy() {
    echo "🔄 Pulling latest images..."
    docker-compose -f ${COMPOSE_FILE} pull
    
    echo "🏗️  Building and starting services..."
    docker-compose -f ${COMPOSE_FILE} up -d --remove-orphans
    
    echo "⏳ Waiting for health checks..."
    sleep 30
    
    # Verify deployment
    if docker-compose -f ${COMPOSE_FILE} ps | grep -q "unhealthy\|Exit"; then
        echo "❌ Deployment failed - unhealthy services detected"
        docker-compose -f ${COMPOSE_FILE} logs --tail=50
        exit 1
    fi
}

# Post-deployment verification
verify_deployment() {
    echo "🔍 Verifying deployment..."
    
    # Check if OpenProject is responding
    if curl -f -s "https://${OPENPROJECT_HOST__NAME}/health" > /dev/null; then
        echo "✅ OpenProject is responding"
    else
        echo "❌ OpenProject health check failed"
        exit 1
    fi
}

# Main execution
main() {
    check_prerequisites
    backup_database
    deploy
    verify_deployment
    
    echo "🎉 Deployment completed successfully!"
    echo "📊 Access monitoring at: https://${OPENPROJECT_HOST__NAME}/grafana"
}

main "$@"
