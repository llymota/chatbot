#!/bin/bash

# Exit on error, undefined vars, pipe failures
set -euo pipefail

echo "🚀 Starting setup script..."

# check if is running as root
if [ "$(id -u)" != "0" ]; then
    echo "⛔ This script must be run as root" >&2
    exit 1
fi

# check if is Mac OS
if [ "$(uname)" = "Darwin" ]; then
    echo "⛔ This script must be run on Linux" >&2
    exit 1
fi

# check if is running inside a container
if [ -f /.dockerenv ]; then
    echo "⛔ This script must be run on Linux" >&2
    exit 1
fi

# Function to check port availability
check_port() {
    local port=$1
    if ss -tulnp | grep ":$port " >/dev/null; then
        echo "⛔ Error: something is already running on port $port" >&2
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
  echo "✅ Docker already installed"
else
  echo "⌛ Installing Docker..."
  curl -sSL https://get.docker.com | sh

  if ! command_exists docker; then
    echo "⛔ Docker installation failed" >&2
    exit 1
  fi

  echo "✅ Docker installed successfully"
fi

# Install Docker-compose if not installed
if command_exists docker-compose; then
  echo "✅ Docker-compose already installed"
else
  echo "⌛ Installing Docker Compose Plugin..."
  apt-get update  
  apt-get install -y docker-compose-plugin

  if ! command_exists docker-compose; then
    echo "⛔ Docker Compose installation failed" >&2
    exit 1
  fi

  echo "✅ Docker Compose installed successfully"
fi  

# Install Git if not installed
if command_exists git; then
  echo "✅ Git already installed"
else
  echo "⌛ Installing Git..."
  apt-get update
  apt-get install -y git 

  if ! command_exists git; then
    echo "⛔ Git installation failed" >&2
    exit 1
  fi

  echo "✅ Git installed successfully"
fi 

# Clone the repository if not already cloned
REPO_URL="https://github.com"
REPO_DIR="/chatbot" # Same name as repository

if [ -d "$REPO_DIR" ]; then
  echo "✅ Repository already cloned at $REPO_DIR"

  echo "⌛ Pulling latest changes..."
  cd "$REPO_DIR"
  git pull origin main
  cd - > /dev/null
  echo "✅ Repository updated successfully"
else
  echo "⌛ Cloning repository..."
  git clone "$REPO_URL"

  if [ ! -d "$REPO_DIR" ]; then
    echo "⛔ Repository cloning failed" >&2
    exit 1
  fi

  echo "✅ Repository cloned successfully"
fi

# Create Docker network if it doesn't exist
NETWORK_NAME="chatbot"
if docker network ls --format '{{.Name}}' | grep -qw "$NETWORK_NAME"; then
    echo "✅ Docker network '$NETWORK_NAME' already exists"
else
    echo "⌛ Creating Docker network '$NETWORK_NAME'..."
    docker network create --driver bridge "$NETWORK_NAME"
    
    if ! docker network ls --format '{{.Name}}' | grep -qw "$NETWORK_NAME"; then
      echo "⛔ Docker network creation failed" >&2   
      exit 1
    fi

    echo "✅ Docker network created"
fi

# Create .env file if it doesn't exist
ENV_FILE="$REPO_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "✅ .env file already exists"
  read -p "Do you want to edit the existing .env file? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
      nano "$ENV_FILE"
      echo "✅ .env file updated successfully"
  fi
else
  # Create .env file
  echo "⚡ Creating .env file..."
  touch "$ENV_FILE"

  # Open .env file in nano editor for input environment variables
  echo "📝 Please enter your environment variables in the editor. Save and exit when done."
  nano "$ENV_FILE"
  echo "✅ .env file saved successfully"

  # Validate .env file is not empty
  if [ ! -s "$ENV_FILE" ]; then
    echo "⚠️ Warning: .env file is empty"
  fi
fi

echo "🚀 Starting all services..."

# Function to start a docker-compose service
start_compose() {
    local compose_file=$1
    local service_name=$2

    if [ -f "$compose_file" ]; then
        echo "⚡ Starting $service_name..."
        cd "$REPO_DIR"
        docker-compose -f "$compose_file" up -d
        if [ $? -eq 0 ]; then
            echo "✅ $service_name started successfully"
        else
            echo "⛔ Failed to start $service_name" >&2
            exit 1
        fi
        cd - > /dev/null
    else
        echo "⛔ Compose file not found: $compose_file" >&2
        exit 1
    fi
}

# Wait for a container to be up
wait_for_container() {
    local service_name=$1
    local timeout=1800
    local interval=5
    local elapsed=0

    echo "🕓 Waiting for '$service_name' container to be up..."

    while ! docker ps --format '{{.Names}}' | grep -qwi "$service_name"; do
        sleep $interval
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "⛔ Timeout reached: '$service_name' did not start in expected time." >&2
            exit 1
        fi
    done

    echo "✅ '$service_name' is now running."
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

echo "🚩 All services started successfully"
echo "🎉 Setup script completed successfully"