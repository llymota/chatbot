#!/bin/bash

REPO_DIR="chatbot"
REPO_URL="https://github.com/llymota/chatbot.git"

# Exit on error, undefined vars, pipe failures
set -euo pipefail

# Main deployment function
deploy() {
    echo -e "\n🚀  Starting setup script...\n"
    
    # check if is running as root
    if [ "$(id -u)" != "0" ]; then
        echo -e "⛔  This script must be run as root\n" >&2
        exit 1
    fi
    
    # check if is Mac OS
    if [ "$(uname)" = "Darwin" ]; then
        echo -e "⛔  This script must be run on Linux\n" >&2
        exit 1
    fi
    
    # check if is running inside a container
    if [ -f /.dockerenv ]; then
        echo -e "⛔  This script must be run on Linux\n" >&2
        exit 1
    fi
    
    # Function to check port availability
    check_port() {
        local port=$1
        if ss -tulnp | grep ":$port " >/dev/null; then
            echo -e "⛔  Error: something is already running on port $port\n" >&2
            return 1
        fi
    }
    
    check_port 80
    check_port 443
    
    # Function to check if a command exists
    command_exists() {
        command -v "$@" > /dev/null 2>&1
    }
    
    # Install Docker if not installed
    if command_exists docker; then
        echo -e "✅  Docker already installed\n"
    else
        echo -e "⌛  Installing Docker...\n"
        curl -sSL https://get.docker.com | sh
        
        if ! command_exists docker; then
            echo -e "⛔  Docker installation failed\n" >&2
            exit 1
        fi
        
        echo -e "✅  Docker installed successfully\n"
    fi
    
    # Install Git if not installed
    if command_exists git; then
        echo -e "✅  Git already installed\n"
    else
        echo -e "⌛  Installing Git...\n"
        apt-get update
        apt-get install -y git
        
        if ! command_exists git; then
            echo -e "⛔  Git installation failed\n" >&2
            exit 1
        fi
        
        echo -e "✅  Git installed successfully\n"
    fi
    
    if [ -d "$REPO_DIR" ]; then
        echo -e "✅  Repository already cloned at $REPO_DIR\n"
        
        echo -e "⌛  Pulling latest changes...\n"
        cd "$REPO_DIR"
        git pull origin main
        cd - > /dev/null
        echo -e "\n✅  Repository updated successfully\n"
    else
        echo -e "⌛  Cloning repository...\n"
        git clone "$REPO_URL"
        
        if [ ! -d "$REPO_DIR" ]; then
            echo -e "⛔  Repository cloning failed\n" >&2
            exit 1
        fi
        
        echo -e "✅  Repository cloned successfully\n"
    fi
    
    # Create Docker network if it doesn't exist
    NETWORK_NAME="chatbot"
    if docker network ls --format '{{.Name}}' | grep -qw "$NETWORK_NAME"; then
        echo -e "✅  Docker network '$NETWORK_NAME' already exists\n"
    else
        echo -e "⌛  Creating Docker network '$NETWORK_NAME'...\n"
        docker network create --driver bridge "$NETWORK_NAME"
        
        if ! docker network ls --format '{{.Name}}' | grep -qw "$NETWORK_NAME"; then
            echo -e "⛔  Docker network creation failed\n" >&2
            exit 1
        fi
        
        echo -e "\n✅  Docker network created\n"
    fi
    
    # Volumes to create if they don't exist
    VOLUMES=("redis-data" "n8n-data" "db-config")
    
    for VOLUME_NAME in "${VOLUMES[@]}"; do
        if docker volume ls --format '{{.Name}}' | grep -qw "$VOLUME_NAME"; then
            echo -e "✅  Docker volume '$VOLUME_NAME' already exists\n"
        else
            echo -e "⌛  Creating Docker volume '$VOLUME_NAME'...\n"
            docker volume create "$VOLUME_NAME" > /dev/null
            
            if ! docker volume ls --format '{{.Name}}' | grep -qw "$VOLUME_NAME"; then
                echo -e "⛔  Docker volume creation failed for '$VOLUME_NAME'\n" >&2
                exit 1
            fi
            
            echo -e "\n✅  Docker volume '$VOLUME_NAME' created\n"
        fi
    done
    
    # Update or create ENV files for all services
    ENV_FILES=(
        "$REPO_DIR/.env"
        "$REPO_DIR/n8n/.env"
        "$REPO_DIR/supabase/.env"
        "$REPO_DIR/typebot/.env"
    )
    
    for ENV_FILE in "${ENV_FILES[@]}"; do
        if [ -f "$ENV_FILE" ]; then
            echo -e "📂  Found: $ENV_FILE"
            read -p "Do you want to edit this file? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                nano "$ENV_FILE"
                echo -e "\n✅  Updated: $ENV_FILE\n"
            else
                echo -e "\n⏭️  Skipping: $ENV_FILE\n"
            fi
        else
            echo -e "⚡  Creating .env file: $ENV_FILE\n"
            mkdir -p "$(dirname "$ENV_FILE")"
            touch "$ENV_FILE"
            nano "$ENV_FILE"
            echo -e "✅  Created: $ENV_FILE\n"
            
            if [ ! -s "$ENV_FILE" ]; then
                echo -e "⚠️  Warning: $ENV_FILE is empty\n"
            fi
        fi
    done
    
    echo -e "\n🚀  Starting all services...\n"
    
    # Required Redis Configration
    echo 'vm.overcommit_memory = 1' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
    
    cd "$REPO_DIR"
    
    # Function to start a docker-compose service
    start_compose() {
        local compose_file=$1
        local service_name=$2
        
        if [ -f "$compose_file" ]; then
            echo -e "⚡  Starting $service_name...\n"
            
            docker compose -f "$compose_file" up -d
            
            if [ $? -eq 0 ]; then
                echo -e "\n⌛  $service_name starting...\n"
            else
                echo -e "⛔  Failed to start $service_name\n" >&2
                exit 1
            fi
        else
            echo -e "⛔  Compose file not found: $compose_file\n" >&2
            exit 1
        fi
    }
    
    # Wait for a container to be up
    wait_for_container() {
        local service_name=$1
        local timeout=1800
        local interval=5
        local elapsed=0
        
        echo -e "🕓  Waiting for $service_name container to be up...\n"
        
        while ! docker ps --format '{{.Names}}' | grep -qwi "$service_name"; do
            sleep $interval
            elapsed=$((elapsed + interval))
            if [ "$elapsed" -ge "$timeout" ]; then
                echo -e "⛔  Timeout reached: $service_name did not start in expected time.\n" >&2
                exit 1
            fi
        done
        
        echo -e "✅  $service_name is now running.\n"
    }
    
    # Start Traefik
    start_compose "docker-compose.yml" "traefik"
    wait_for_container "traefik"
    
    # Start Redis
    start_compose "redis/docker-compose.redis.yml" "redis"
    wait_for_container "redis"
    
    # Start Supabase
    start_compose "supabase/docker-compose.supabase.yml" "supabase"
    wait_for_container "supabase"
    
    # Start Supabase S3
    start_compose "supabase/docker-compose.s3.supabase.yml" "supabase-s3"
    wait_for_container "supabase"
    
    # Start n8n
    start_compose "n8n/docker-compose.n8n.yml" "n8n"
    wait_for_container "n8n"
    
    # Start Typebot
    start_compose "typebot/docker-compose.typebot.yml" "typebot"
    wait_for_container "typebot"
    
    echo -e "🚩  All services started successfully\n"
    
    cd - > /dev/null
    
    echo -e "🎉  Setup script completed successfully\n"
}

# Stop all services
down() {
    echo -e "\n🚀  Starting docker compose down script...\n"
    
    # Check if repository exists
    if [ ! -d "$REPO_DIR" ]; then
        echo -e "\n⛔  Repository directory not found: $REPO_DIR\n" >&2
        echo -e "    No services to stop.\n" >&2
        exit 0
    fi
    
    cd "$REPO_DIR"
    
    # Function to stop a service
    stop_service() {
        local compose_file=$1
        local service_name=$2
        
        if [ -f "$compose_file" ]; then
            echo -e "\n⌛  Stopping $service_name...\n"
            
            docker compose -f "$compose_file" down
            
            if [ $? -eq 0 ]; then
                echo -e "\n✅  $service_name stopped successfully\n"
            else
                echo -e "\n⛔  Failed to stop $service_name\n" >&2
                return 1
            fi
        else
            echo -e "\n⚠️  Compose file not found: $compose_file\n"
        fi
    }
    
    # Stop all services (in reverse order)
    stop_service "typebot/docker-compose.typebot.yml" "typebot"
    stop_service "n8n/docker-compose.n8n.yml" "n8n"
    stop_service "supabase/docker-compose.s3.supabase.yml" "supabase-s3"
    stop_service "supabase/docker-compose.supabase.yml" "supabase"
    stop_service "redis/docker-compose.redis.yml" "redis"
    stop_service "docker-compose.yml" "traefik"
    
    cd - > /dev/null
    
    echo -e "🎉  All services stopped successfully\n"
}

# Function to check and stop container if running
check_and_stop_container() {
    local compose_file=$1
    local service_name=$2
    
    if [ -f "$compose_file" ]; then
        echo -e "⌛  Checking status of $service_name...\n"
        
        # Check if any containers are running or restarting
        local running_count
        local restarting_count
        
        running_count=$(docker compose -f "$compose_file" ps --status=running --quiet | wc -l)
        restarting_count=$(docker compose -f "$compose_file" ps --status=restarting --quiet | wc -l)
        
        if [[ "$running_count" -gt 0 ]] || [[ "$restarting_count" -gt 0 ]]; then
            echo -e "\n🛑  $service_name is running/restarting. Stopping...\n"
            docker compose -f "$compose_file" down
            if [ $? -eq 0 ]; then
                echo -e "\n✅  $service_name stopped successfully\n"
            else
                echo -e "\n⚠️  Warning: Failed to stop $service_name cleanly\n"
            fi
        else
            echo -e "✅  $service_name is already stopped\n"
        fi
    else
        echo -e "⚠️  Compose file not found: $compose_file\n"
    fi
}

# Function to start a service
start_service() {
    local compose_file=$1
    local service_name=$2
    
    if [ -f "$compose_file" ]; then
        echo -e "⌛  Starting $service_name...\n"
        
        docker compose -f "$compose_file" up -d
        if [ $? -eq 0 ]; then
            echo -e "\n✅  $service_name started successfully\n"
        else
            echo -e "\n⛔  Failed to start $service_name\n" >&2
            return 1
        fi
    else
        echo -e "\n⚠️  Compose file not found: $compose_file\n"
        return 1
    fi
}

# Start all services
up() {
    echo -e "\n🚀  Starting docker compose up script...\n"
    
    # Check if repository exists
    if [ ! -d "$REPO_DIR" ]; then
        echo -e "⛔  Repository directory not found: $REPO_DIR\n" >&2
        echo -e "   Please run the deploy script first.\n" >&2
        exit 1
    fi
    
    cd "$REPO_DIR"
    
    echo -e "🛑  Stopping all running services first...\n"
    
    # Stop all services if they're running
    check_and_stop_container "docker-compose.yml" "traefik"
    check_and_stop_container "redis/docker-compose.redis.yml" "redis"
    check_and_stop_container "supabase/docker-compose.supabase.yml" "supabase"
    check_and_stop_container "supabase/docker-compose.s3.supabase.yml" "supabase-s3"
    check_and_stop_container "n8n/docker-compose.n8n.yml" "n8n"
    check_and_stop_container "typebot/docker-compose.typebot.yml" "typebot"
    
    echo -e "✅  All services stopped\n"
    
    # Ask about pulling latest code
    local REPLY=""
    if [[ -t 0 ]]; then
        read -p "Do you want to pull latest code? (y/N): " -n 1 -r REPLY
        elif [[ -c /dev/tty ]]; then
        read -p "Do you want to pull latest code? (y/N): " -n 1 -r REPLY < /dev/tty
    fi
    
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "⌛  Pulling latest changes...\n"
        git pull origin main
        echo -e "\n✅  Repository updated successfully\n"
    fi
    
    echo -e "\n🚀  Starting all services fresh...\n"
    
    # Start all services fresh
    start_service "docker-compose.yml" "traefik"
    start_service "redis/docker-compose.redis.yml" "redis"
    start_service "supabase/docker-compose.supabase.yml" "supabase"
    start_service "supabase/docker-compose.s3.supabase.yml" "supabase-s3"
    start_service "n8n/docker-compose.n8n.yml" "n8n"
    start_service "typebot/docker-compose.typebot.yml" "typebot"
    
    cd - > /dev/null
    
    echo -e "🎉  All services started successfully\n"
}

# Restart all services
restart() {
    echo -e "\n🚀  Starting restart script...\n"
    
    # Check if repository exists
    if [ ! -d "$REPO_DIR" ]; then
        echo -e "\n⛔  Repository directory not found: $REPO_DIR\n" >&2
        echo -e "    Please run the deploy script first.\n" >&2
        exit 1
    fi
    
    cd "$REPO_DIR"
    
    # Function to restart a service
    restart_service() {
        local compose_file=$1
        local service_name=$2
        
        if [ -f "$compose_file" ]; then
            echo -e "\n⌛  Restarting $service_name...\n"
            
            docker compose -f "$compose_file" restart
            
            if [ $? -eq 0 ]; then
                echo -e "\n✅  $service_name restarted successfully\n"
            else
                echo -e "\n⛔  Failed to restart $service_name\n" >&2
                return 1
            fi
        else
            echo -e "\n⚠️  Compose file not found: $compose_file (skipping $service_name)\n"
        fi
    }
    
    # Restart all services
    restart_service "docker-compose.yml" "traefik"
    restart_service "redis/docker-compose.redis.yml" "redis"
    restart_service "supabase/docker-compose.supabase.yml" "supabase"
    restart_service "supabase/docker-compose.s3.supabase.yml" "supabase-s3"
    restart_service "n8n/docker-compose.n8n.yml" "n8n"
    restart_service "typebot/docker-compose.typebot.yml" "typebot"
    
    cd - > /dev/null
    
    echo -e "🎉  All services restarted successfully\n"
}

# Reset all services - Complete system cleanup
reset() {
    echo -e "\n🚀  Starting reset script (Complete System Cleanup)...\n"
    
    # Warning message
    echo -e "⚠️  WARNING: This will completely reset your chatbot system!"
    echo -e "    - Stop all running services"
    echo -e "    - Remove all containers and images"
    echo -e "    - Delete all volumes and data"
    echo -e "    - Remove Docker network"
    echo -e "    - Clean up system resources"
    echo -e "    - All data will be permanently lost!\n"
    
    # Confirmation prompt with timeout
    echo -e "🔥  This action cannot be undone!"
    read -p "Type 'YES' to confirm reset (case sensitive): " -r CONFIRMATION
    
    if [ "$CONFIRMATION" != "YES" ]; then
        echo -e "\n❌  Reset cancelled. Exiting safely.\n"
        exit 0
    fi
    
    # Additional confirmation for critical reset
    echo -e "\n⚡  Last chance! Are you absolutely sure?"
    read -p "Type 'RESET' to proceed: " -r FINAL_CONFIRMATION
    
    if [ "$FINAL_CONFIRMATION" != "RESET" ]; then
        echo -e "\n❌  Reset cancelled. Exiting safely.\n"
        exit 0
    fi
    
    echo -e "\n🛑  Starting complete system reset...\n"
    
    # Check if repository exists
    if [ -d "$REPO_DIR" ]; then
        cd "$REPO_DIR"
        echo -e "✅  Found repository directory: $REPO_DIR\n"
    else
        echo -e "⚠️  Repository directory not found: $REPO_DIR"
        echo -e "    Proceeding with Docker cleanup only...\n"
    fi
    
    # Function to force stop and remove containers
    force_cleanup_service() {
        local compose_file=$1
        local service_name=$2
        
        if [ -f "$compose_file" ]; then
            echo -e "🛑  Force stopping and removing $service_name...\n"
            
            # Stop containers
            docker compose -f "$compose_file" down --timeout 10 2>/dev/null || true
            
            # Force remove containers if still running
            docker compose -f "$compose_file" rm -f -s 2>/dev/null || true
            
            # Get container names and force remove them
            local containers
            containers=$(docker compose -f "$compose_file" ps -a -q 2>/dev/null || true)
            if [ -n "$containers" ]; then
                echo -e "    Removing remaining containers...\n"
                docker rm -f $containers 2>/dev/null || true
            fi
            
            echo -e "✅  $service_name cleanup completed\n"
        else
            echo -e "⚠️  Compose file not found: $compose_file (skipping $service_name)\n"
        fi
    }
    
    # Step 1: Stop all services forcefully (in reverse order)
    echo -e "🔥  Step 1: Stopping all services...\n"
    
    if [ -d "$REPO_DIR" ]; then
        force_cleanup_service "typebot/docker-compose.typebot.yml" "typebot"
        force_cleanup_service "n8n/docker-compose.n8n.yml" "n8n"
        force_cleanup_service "supabase/docker-compose.s3.supabase.yml" "supabase-s3"
        force_cleanup_service "supabase/docker-compose.supabase.yml" "supabase"
        force_cleanup_service "redis/docker-compose.redis.yml" "redis"
        force_cleanup_service "docker-compose.yml" "traefik"
    fi
    
    # Step 2: Remove all project-related containers (fallback cleanup)
    echo -e "🗑️  Step 2: Removing all chatbot-related containers...\n"
    
    # Get all containers with chatbot network or name pattern
    local chatbot_containers
    chatbot_containers=$(docker ps -aq --filter "network=chatbot" 2>/dev/null || true)
    if [ -n "$chatbot_containers" ]; then
        echo -e "    Removing containers connected to chatbot network...\n"
        docker rm -f $chatbot_containers 2>/dev/null || true
    fi
    
    # Remove containers by name patterns
    local pattern_containers
    for pattern in "chatbot" "traefik" "supabase" "typebot" "n8n" "redis"; do
        pattern_containers=$(docker ps -aq --filter "name=$pattern" 2>/dev/null || true)
        if [ -n "$pattern_containers" ]; then
            echo -e "    Removing $pattern containers...\n"
            docker rm -f $pattern_containers 2>/dev/null || true
        fi
    done
    
    echo -e "✅  Container cleanup completed\n"
    
    # Step 3: Remove all volumes
    echo -e "🗑️  Step 3: Removing all volumes...\n"
    
    # Remove named volumes related to the project
    local project_volumes
    project_volumes=$(docker volume ls -q --filter "name=chatbot" 2>/dev/null || true)
    if [ -n "$project_volumes" ]; then
        echo -e "    Removing chatbot volumes...\n"
        docker volume rm $project_volumes 2>/dev/null || true
    fi
    
    # Remove volumes by pattern
    for pattern in "supabase" "typebot" "n8n" "redis" "traefik"; do
        local pattern_volumes
        pattern_volumes=$(docker volume ls -q --filter "name=$pattern" 2>/dev/null || true)
        if [ -n "$pattern_volumes" ]; then
            echo -e "    Removing $pattern volumes...\n"
            docker volume rm $pattern_volumes 2>/dev/null || true
        fi
    done
    
    # Remove dangling volumes
    echo -e "    Removing dangling volumes...\n"
    docker volume prune -f 2>/dev/null || true
    
    echo -e "✅  Volume cleanup completed\n"
    
    # Step 4: Remove Docker network
    echo -e "🗑️  Step 4: Removing Docker network...\n"
    
    local network_name="chatbot"
    if docker network ls --format '{{.Name}}' | grep -qw "$network_name" 2>/dev/null; then
        echo -e "    Removing network: $network_name\n"
        docker network rm "$network_name" 2>/dev/null || true
        echo -e "✅  Network removed successfully\n"
    else
        echo -e "⚠️  Network '$network_name' not found\n"
    fi
    
    # Step 5: Remove Docker images
    echo -e "🗑️  Step 5: Removing Docker images...\n"
    
    # Remove images by repository patterns
    for pattern in "traefik" "supabase" "typebot" "n8n" "redis" "postgres"; do
        local pattern_images
        pattern_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -i "$pattern" 2>/dev/null || true)
        if [ -n "$pattern_images" ]; then
            echo -e "    Removing $pattern images...\n"
            echo "$pattern_images" | xargs -r docker rmi -f 2>/dev/null || true
        fi
    done
    
    # Remove dangling images
    echo -e "    Removing dangling images...\n"
    docker image prune -f 2>/dev/null || true
    
    echo -e "✅  Image cleanup completed\n"
    
    # Step 6: Clean up repository data (optional)
    if [ -d "$REPO_DIR" ]; then
        echo -e "🗑️  Step 6: Repository cleanup options...\n"
        
        read -p "Do you want to remove the repository directory completely? (y/N): " -n 1 -r REPO_CLEANUP
        echo
        if [[ $REPO_CLEANUP =~ ^[Yy]$ ]]; then
            cd ..
            echo -e "    Removing repository directory: $REPO_DIR\n"
            rm -rf "$REPO_DIR"
            echo -e "✅  Repository directory removed\n"
        else
            # Clean up generated files but keep repository
            echo -e "    Cleaning up generated files in repository...\n"
            cd "$REPO_DIR"
            
            # Remove .env files
            find . -name ".env" -type f -delete 2>/dev/null || true
            find . -name ".env.local" -type f -delete 2>/dev/null || true
            find . -name ".env.production" -type f -delete 2>/dev/null || true
            
            # Remove logs
            find . -name "*.log" -type f -delete 2>/dev/null || true
            find . -type d -name "logs" -exec rm -rf {} + 2>/dev/null || true
            
            # Remove temporary and cache files
            find . -name ".cache" -type d -exec rm -rf {} + 2>/dev/null || true
            find . -name "node_modules" -type d -exec rm -rf {} + 2>/dev/null || true
            find . -name ".next" -type d -exec rm -rf {} + 2>/dev/null || true
            find . -name "dist" -type d -exec rm -rf {} + 2>/dev/null || true
            find . -name "build" -type d -exec rm -rf {} + 2>/dev/null || true
            
            # Git clean (remove untracked files)
            if command_exists git && [ -d ".git" ]; then
                echo -e "    Cleaning git repository...\n"
                git reset --hard HEAD 2>/dev/null || true
                git clean -fdx 2>/dev/null || true
            fi
            
            cd - > /dev/null
            echo -e "✅  Repository cleaned (kept structure)\n"
        fi
    else
        echo -e "⚠️  Step 6: Repository directory not found, skipping...\n"
    fi
    
    # Step 7: System cleanup
    echo -e "🧹  Step 7: System cleanup...\n"
    
    # Docker system prune
    echo -e "    Running Docker system prune...\n"
    docker system prune -af --volumes 2>/dev/null || true
    
    # Clean up any remaining Docker resources
    echo -e "    Final Docker cleanup...\n"
    docker container prune -f 2>/dev/null || true
    docker image prune -af 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    
    echo -e "✅  System cleanup completed\n"
    
    # Step 8: Verification
    echo -e "🔍  Step 8: Verification...\n"
    
    echo -e "    Checking remaining containers:\n"
    local remaining_containers
    remaining_containers=$(docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -E "(chatbot|traefik|supabase|typebot|n8n|redis)" || echo "None found")
    echo -e "      $remaining_containers\n"
    
    echo -e "    Checking remaining volumes:\n"
    local remaining_volumes
    remaining_volumes=$(docker volume ls --format "table {{.Name}}" | grep -E "(chatbot|traefik|supabase|typebot|n8n|redis)" || echo "None found")
    echo -e "      $remaining_volumes\n"
    
    echo -e "    Checking remaining networks:\n"
    local remaining_networks
    remaining_networks=$(docker network ls --format "table {{.Name}}" | grep "chatbot" || echo "None found")
    echo -e "      $remaining_networks\n"
    
    # Final status
    echo -e "🎉  RESET COMPLETED SUCCESSFULLY!\n"
    echo -e "📋  Summary:"
    echo -e "    ✅  All services stopped and removed"
    echo -e "    ✅  All containers removed"
    echo -e "    ✅  All volumes removed"
    echo -e "    ✅  Docker network removed"
    echo -e "    ✅  Docker images cleaned up"
    echo -e "    ✅  System resources cleaned"
    
    if [[ $REPO_CLEANUP =~ ^[Yy]$ ]]; then
        echo -e "    ✅  Repository directory removed"
        echo -e "\n🚀  To start fresh, run: curl -sSL <your-script-url> | sudo bash"
    else
        echo -e "    ✅  Repository cleaned (structure preserved)"
        echo -e "\n🚀  To deploy again, run: $0 deploy"
    fi
    
    echo -e "\n🌟  Your system is now clean and ready for a fresh deployment!\n"
}

# Update ENV files
update_env() {
    echo -e "\n🚀  Starting update ENV script...\n"
    
    # List of env files to update
    env_files=(
        "$REPO_DIR/.env"
        "$REPO_DIR/n8n/.env"
        "$REPO_DIR/supabase/.env"
        "$REPO_DIR/typebot/.env"
    )
    
    for env_file in "${env_files[@]}"; do
        if [ -f "$env_file" ]; then
            echo -e "\n📂  Found: $env_file"
            read -p "Do you want to edit this file? (y/N): " -n 1 -r REPLY
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                nano "$env_file"
                echo -e "\n✅  Updated: $env_file\n"
            else
                echo -e "\n⏭️  Skipping: $env_file\n"
            fi
        else
            echo -e "\n⚠️  File not found: $env_file\n"
        fi
    done
    
    echo -e "🎉  ENV update process completed\n"
}

# Show usage information
help() {
    echo -e "\n🚩  Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  🔸  deploy         Run the full deployment (default)"
    echo "  🔸  up, start      Start all services"
    echo "  🔸  down, stop     Stop all services"
    echo "  🔸  restart        Restart all services"
    echo "  🔸  update-env     Update environment files"
    echo "  🔸  reset          Reset all services"
    echo "  🔸  help           Show this help message"
    echo ""
}

###   >>  Script execution starts here  <<   ###

if [ $# -eq 0 ]; then
    deploy
    elif [ "$1" = "stop" ] || [ "$1" = "down" ]; then
    down
    elif [ "$1" = "up" ] || [ "$1" = "start" ]; then
    up
    elif [ "$1" = "restart" ]; then
    restart
    elif [ "$1" = "update-env" ]; then
    update_env
    elif [ "$1" = "reset" ]; then
    reset
    elif [ "$1" = "help" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    help
else
    echo -e "\n❌  Unknown command: $1"
    echo ""
    help
    exit 1
fi