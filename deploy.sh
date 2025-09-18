#!/bin/bash

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
    
    # Clone the repository if not already cloned
    REPO_URL="https://github.com/llymota/chatbot.git"
    REPO_DIR="chatbot" # Same name as repository
    
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
    
    # Update or create ENV files for all services
    ENV_FILES=(
        "$REPO_DIR/.env"
        "$REPO_DIR/n8n/.env"
        "$REPO_DIR/supabase/.env"
        "$REPO_DIR/typebot/.env"
    )
    
    for ENV_FILE in "${ENV_FILES[@]}"; do
        if [ -f "$ENV_FILE" ]; then
            echo -e "✅  Found existing .env: $ENV_FILE"
            read -p "Do you want to edit this file? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                nano "$ENV_FILE"
                echo -e "✅  Updated: $ENV_FILE\n"
            else
                echo -e "⏭️  Skipping: $ENV_FILE\n"
            fi
        else
            echo -e "⚡  Creating .env file: $ENV_FILE\n"
            mkdir -p "$(dirname "$ENV_FILE")"
            touch "$ENV_FILE"
            echo -e "📝  Please enter your environment variables in the editor. Save and exit when done.\n"
            nano "$ENV_FILE"
            echo -e "✅  Created: $ENV_FILE\n"
            
            if [ ! -s "$ENV_FILE" ]; then
                echo -e "⚠️  Warning: $ENV_FILE is empty\n"
            fi
        fi
    done
    
    echo -e "\n🚀  Starting all services...\n"
    
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
    
    # Start Supabase
    start_compose "supabase/docker-compose.supabase.yml" "supabase"
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
    
    REPO_DIR="chatbot"
    
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
    stop_service "supabase/docker-compose.supabase.yml" "supabase"
    stop_service "docker-compose.yml" "traefik"
    
    cd - > /dev/null
    
    echo -e "🎉  All services stopped successfully\n"
}

# Start all services
up() {
    echo -e "\n🚀  Starting docker compose up script...\n"
    
    check_container(){
        local compose_file=$1
        local service_name=$2
        
        if [ -f "$compose_file" ]; then
            echo -e "⌛  Checking status of $service_name...\n"
            
            # Get container status (running, exited, restarting, etc.)
            local status
            status=$(docker compose -f "$compose_file" ps --status=running --status=restarting | grep "$service_name" | awk '{print $4}')
            
            if [[ "$status" == "running" ]]; then
                echo -e "✅  $service_name is already running. Skipping...\n"
                return 0
                elif [[ "$status" == "restarting" ]]; then
                echo -e "⚠️  $service_name is in restarting state. Please check logs.\n"
                return 1
            fi
        fi
    }
    
    check_container "docker-compose.yml" "traefik"
    check_container "supabase/docker-compose.supabase.yml" "supabase"
    check_container "n8n/docker-compose.n8n.yml" "n8n"
    check_container "typebot/docker-compose.typebot.yml" "typebot"
    
    REPO_URL="https://github.com/llymota/chatbot.git"
    REPO_DIR="chatbot"
    
    # Check if repository exists
    if [ ! -d "$REPO_DIR" ]; then
        echo -e "\n⛔  Repository directory not found: $REPO_DIR\n" >&2
        echo -e "    Please run the deploy script first.\n" >&2
        exit 1
    fi
    
    cd "$REPO_DIR"
    
    read -p "Do you want to pull latest code? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "⌛  Pulling latest changes...\n"
        git pull origin main
        echo -e "\n✅  Repository updated successfully\n"
    fi
    
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
        fi
    }
    
    # Start all services
    start_service "docker-compose.yml" "traefik"
    start_service "supabase/docker-compose.supabase.yml" "supabase"
    start_service "n8n/docker-compose.n8n.yml" "n8n"
    start_service "typebot/docker-compose.typebot.yml" "typebot"
    
    cd - > /dev/null
    
    echo -e "🎉  All services started successfully\n"
}

# Restart all services
restart() {
    echo -e "\n🚀  Starting restart script...\n"
    
    REPO_DIR="chatbot"
    
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
    restart_service "supabase/docker-compose.supabase.yml" "supabase"
    restart_service "n8n/docker-compose.n8n.yml" "n8n"
    restart_service "typebot/docker-compose.typebot.yml" "typebot"
    
    cd - > /dev/null
    
    echo -e "🎉  All services restarted successfully\n"
}

# Reset all services
reset() {
    echo -e "\n🚀  Starting reset script...\n"
}

# Update ENV files
update_env() {
    echo -e "\n🚀  Starting update ENV script...\n"
    
    REPO_DIR="chatbot"
    
    if [ -f "$REPO_DIR/.env" ]; then
        echo -e "\n📂  Found: $REPO_DIR/.env"
        echo "helllo"
        read -p "Do you want to edit this file? (y/N): " -n 1 -r REPLY
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "⌛  Opening $REPO_DIR/.env...\n"
            nano "$REPO_DIR/.env"
            echo -e "✅  Updated: $REPO_DIR/.env\n"
        else
            echo -e "⏭️  Skipping: $REPO_DIR/.env\n"
        fi
    else
        echo -e "⚠️  File not found: $REPO_DIR/.env\n"
    fi
    
    echo -e "🎉  ENV update process completed\n"
}

# Show usage information
help() {
    echo "\n🚩  Usage: $0 [COMMAND]"
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
    echo "❌  Unknown command: $1"
    echo ""
    help
    exit 1
fi