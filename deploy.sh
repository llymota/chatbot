#!/bin/bash

# Exit on error, undefined vars, pipe failures
set -euo pipefail

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

# Install Docker-compose if not installed
if command_exists docker-compose; then
  echo -e "✅  Docker-compose already installed\n"
else
  echo -e "⌛  Installing Docker Compose Plugin...\n"
  apt-get update  
  apt-get install -y docker-compose

  if ! command_exists docker-compose; then
    echo -e "⛔  Docker Compose installation failed\n" >&2
    exit 1
  fi

  echo -e "✅  Docker Compose installed successfully\n"
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

# Create .env file if it doesn't exist
ENV_FILE="$REPO_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo -e "✅  .env file already exists\n"
  read -p "Do you want to edit the existing .env file? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
      nano "$ENV_FILE"
      echo -e "✅  .env file updated successfully\n"
  fi
else
  # Create .env file
  echo -e "⚡  Creating .env file...\n"
  touch "$ENV_FILE"

  # Open .env file in nano editor for input environment variables
  echo -e "📝  Please enter your environment variables in the editor. Save and exit when done.\n"
  nano "$ENV_FILE"
  echo -e "✅  .env file saved successfully\n"

  # Validate .env file is not empty
  if [ ! -s "$ENV_FILE" ]; then
    echo -e "⚠️  Warning: .env file is empty\n"
  fi
fi

echo -e "\n🚀  Starting all services...\n"

cd "$REPO_DIR"

# Function to start a docker-compose service
start_compose() {
    local compose_file=$1
    local service_name=$2

    if [ -f "$compose_file" ]; then
        echo -e "⚡  Starting $service_name...\n"
        
        docker-compose -f "$compose_file" up -d
        
        if [ $? -eq 0 ]; then
            echo -e "⌛  $service_name starting...\n"
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

    echo -e "🕓  Waiting for '$service_name' container to be up...\n"

    while ! docker ps --format '{{.Names}}' | grep -qwi "$service_name"; do
        sleep $interval
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e "⛔  Timeout reached: '$service_name' did not start in expected time.\n" >&2
            exit 1
        fi
    done

    echo -e "✅  '$service_name' is now running.\n"
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