#!/bin/bash
set -euo pipefail

# Production deployment script
ENVIRONMENT=${ENVIRONMENT:-production}
COMPOSE_FILE="docker-compose.yml"

echo "🚀 Starting OpenProject deployment for ${ENVIRONMENT}"

# Pre-deployment checks
check_prerequisites() {
    echo "✅ Checking prerequisites..."
    
    # Check if .env file exists
    if [[ ! -f ".env" ]]; then
        echo "❌ Missing .env file. Please copy .env.example to .env and configure it."
        exit 1
    fi
    
    # Validate required environment variables are set in .env
    # Note: Docker Compose automatically loads .env, but we can check critical ones here
    # This requires sourcing the .env file or using a tool like grep.
    # For simplicity, we'll assume .env is correctly populated if it exists.
    # A more robust check might involve:
    # source .env
    # for var in "${required_vars[@]}"; do ... done
    # However, sourcing .env in a script can have side effects.

    # Example check for a few critical variables (you might want to expand this)
    # This grep approach is safer than sourcing.
    required_vars_in_env=(
        "OPENPROJECT_HOST__NAME"
        "POSTGRES_USER"
        "POSTGRES_DB"
        "POSTGRES_PASSWORD"
        "REDIS_PASSWORD"
        "OPENPROJECT_SECRET_KEY_BASE"
    )

    echo "ℹ️  Verifying essential variables in .env file..."
    all_vars_present=true
    for var_name in "${required_vars_in_env[@]}"; do
        if ! grep -q "^${var_name}=" ".env"; then
            echo "❌ Missing required environment variable in .env: ${var_name}"
            all_vars_present=false
        fi
    done

    if [ "$all_vars_present" = false ]; then
        echo "👉 Please ensure all required variables are set in your .env file."
        exit 1
    fi

    echo "✅ Essential .env variables seem to be present."
}

# Database backup before deployment
backup_database() {
    echo "💾 Creating database backup..."
    # Ensure POSTGRES_USER and POSTGRES_DB are available from .env for docker-compose exec
    docker-compose -f ${COMPOSE_FILE} exec -T db pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" | gzip > "backups/pre-deploy-$(date +%Y%m%d-%H%M%S).sql.gz"
    echo "✅ Database backup created."
}

# Deploy with rolling updates
deploy() {
    echo "🔄 Pulling latest images..."
    docker-compose -f ${COMPOSE_FILE} pull
    
    echo "🏗️  Building and starting services..."
    # --force-recreate might be useful if configurations changed significantly
    # --no-deps can speed up updates for specific services if dependencies are already running
    docker-compose -f ${COMPOSE_FILE} up -d --remove-orphans
    
    echo "⏳ Waiting for services to become healthy (approx 60-120s)..."
    # A more robust health check loop could be implemented here
    # For now, a simple sleep. Consider checking `docker-compose ps` output in a loop.
    sleep 90 # Increased sleep time
    
    # Verify deployment health
    if docker-compose -f ${COMPOSE_FILE} ps | grep -q "unhealthy\|Exit"; then
        echo "❌ Deployment failed - unhealthy or exited services detected after startup period."
        echo "🔍 Recent logs for services:"
        docker-compose -f ${COMPOSE_FILE} logs --tail=50
        # Consider specific checks for critical services like 'web' or 'db'
        exit 1
    else
        echo "✅ All services appear to be running."
    fi
}

# Post-deployment verification
verify_deployment() {
    echo "🔍 Verifying OpenProject application..."
    
    # Check if OpenProject is responding via Caddy
    # Ensure OPENPROJECT_HOST__NAME is available from .env
    # The script now relies on .env being loaded by docker-compose,
    # but for curl, we might need to source it or pass the var explicitly if not in current shell env.
    # Assuming OPENPROJECT_HOST__NAME is set in the calling environment or .env is sourced prior to script execution
    # For safety, let's try to get it from .env if possible, otherwise rely on it being in the environment
    local target_host=${OPENPROJECT_HOST__NAME}
    if [[ -z "$target_host" && -f ".env" ]]; then
        target_host=$(grep "^OPENPROJECT_HOST__NAME=" .env | cut -d '=' -f2)
    fi

    if [[ -z "$target_host" ]]; then
        echo "⚠️ OPENPROJECT_HOST__NAME not found. Cannot perform external health check."
        echo "👉 Please ensure OPENPROJECT_HOST__NAME is set in your .env file or environment."
        return # Don't exit, as internal checks might still be valuable
    fi
    
    echo "ℹ️  Attempting to reach OpenProject at https://${target_host}/health_checks/default"
    if curl --fail --silent --show-error --location --max-time 20 "https://${target_host}/health_checks/default" > /dev/null; then
        echo "✅ OpenProject application is responding successfully via https://${target_host}"
    else
        echo "❌ OpenProject application health check failed at https://${target_host}"
        echo "ℹ️  This could be due to DNS, Caddy, or OpenProject service issues."
        echo "ℹ️  Check Caddy logs: docker-compose -f ${COMPOSE_FILE} logs proxy"
        echo "ℹ️  Check OpenProject web logs: docker-compose -f ${COMPOSE_FILE} logs web"
        # exit 1 # Deciding not to exit here to allow manual checks, but in CI this might be an exit
    fi
}

# Main execution
main() {
    check_prerequisites
    backup_database
    deploy
    verify_deployment
    
    echo "🎉 Deployment completed!"
    local final_host=${OPENPROJECT_HOST__NAME}
     if [[ -z "$final_host" && -f ".env" ]]; then
        final_host=$(grep "^OPENPROJECT_HOST__NAME=" .env | cut -d '=' -f2)
    fi
    if [[ -n "$final_host" ]]; then
      echo "🌐 Access OpenProject at: https://${final_host}"
      # Assuming Grafana is on the same host, adjust if different
      echo "📊 Access monitoring (Grafana) at: https://${final_host}/grafana" # Ensure Grafana is exposed this way via Caddy
    else
      echo "🌐 Access OpenProject (Host not found, check .env)"
      echo "📊 Access monitoring (Grafana - Host not found, check .env)"
    fi
}

main "$@"
