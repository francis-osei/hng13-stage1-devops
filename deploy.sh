#!/bin/bash

set -euo pipefail

# ============ CONFIGURATION ============
LOG_FILE="deploy_$(date +%Y%m%d).log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "===== Deployment Script Started ====="
echo "All actions will be logged to $LOG_FILE"
echo

# --- Validation Functions ---

# Validate input is not empty
validate_input() {
  local input_name=$1
  local input_value=$2
  if [[ -z "$input_value" ]]; then
    echo "❌ Error: $input_name cannot be empty."
    exit 1
  fi
}

# Validate SSH key path exists
validate_ssh_key() {
  if [[ ! -f "$1" ]]; then
    echo "❌ Error: SSH key file not found at $1"
    exit 1
  fi
}

# --- User Inputs ---

read -p "Enter Git Repository URL: " GIT_REPO
validate_input "Git Repository URL" "$GIT_REPO"

read -s -p "Enter Personal Access Token (PAT): " GIT_PAT
echo
validate_input "Personal Access Token" "$GIT_PAT"

read -p "Enter Branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter SSH Username: " SSH_USER
validate_input "SSH Username" "$SSH_USER"

read -p "Enter Server IP Address: " SERVER_IP
validate_input "Server IP Address" "$SERVER_IP"

read -p "Enter SSH Key Path: " SSH_KEY_PATH
validate_input "SSH Key Path" "$SSH_KEY_PATH"
validate_ssh_key "$SSH_KEY_PATH"

read -p "Enter Application Port (e.g., 8080): " APP_PORT
validate_input "Application Port" "$APP_PORT"

# --- Summary ---

echo
echo "===== Summary of Inputs ====="
echo "Repository:  $GIT_REPO"
echo "Branch:      $BRANCH"
echo "SSH User:    $SSH_USER"
echo "Server IP:   $SERVER_IP"
echo "SSH Key:     $SSH_KEY_PATH"
echo "App Port:    $APP_PORT"
echo "================================="
echo
echo "✅ All inputs validated successfully. Proceeding with deployment..."
echo


# ============ STEP 2: CLONE OR UPDATE REPOSITORY ============

echo "===== Step 2: Cloning Repository ====="

# Extract repo name (folder name)
# REPO_NAME=$(basename "$GIT_REPO" .git)
REPO_NAME=$(basename -s .git "$GIT_REPO")

# Prepare authenticated URL (masking PAT in logs)
AUTH_REPO_URL=$(echo "$GIT_REPO" | sed "s#https://#https://${SSH_USER}:${GIT_PAT}@#")

# Check if repo already exists
if [[ -d "$REPO_NAME/.git" ]]; then
  echo "Repository already exists locally. Pulling latest changes..."
  cd "$REPO_NAME"
 
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git pull origin "$BRANCH"
  echo "Repository updated successfully."
else
  echo "Cloning repository from $GIT_REPO..."
  git clone --branch "$BRANCH" "$AUTH_REPO_URL"
  cd "$REPO_NAME"
  echo "Repository cloned successfully."
fi


echo "===== Step 3: Navigate into the Cloned Directory ====="

# Verify Dockerfile or docker-compose.yml exists
if [[ -f "Dockerfile" ]]; then
  echo "Found Dockerfile"
elif [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]];  then
  echo "Found docker-compose.yml"
else
  echo "❌ Error: No Dockerfile or docker-compose.yml found in the repository."
  exit 1
fi

# ====== Step 4: SSH Connectivity Check ======
echo "Checking SSH connectivity to $SSH_USER@$SSH_IP..."

# Optional: ping check
if ping -c 2 "$SSH_IP" &>/dev/null; then
    echo "Ping successful to $SSH_IP"
else
    echo "Warning: Cannot ping $SSH_IP. Continuing to SSH test..."
fi

# SSH dry-run to test credentials
if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SSH_IP" "echo 'SSH connection successful'" &>/dev/null; then
    echo "SSH connection successful."
else
    echo "Error: SSH connection failed. Check username, IP, and key."
    exit 1
fi

echo "Remote server is reachable."


# ====== Step 5: Prepare Remote Environment ======
echo "Setting up remote environment on $SSH_USER@$SSH_IP..."

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" <<'EOF'
echo "Connected to remote server."

# Update system packages
echo "Updating system packages..."
sudo apt-get update -y && sudo apt-get upgrade -y

# Install Docker if missing
if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
else
    echo "Docker already installed."
fi

# Install Docker Compose if missing
if ! command -v docker-compose &>/dev/null; then
    echo "Installing Docker Compose..."
    sudo apt-get install -y docker-compose
else
    echo "Docker Compose already installed."
fi

# Install Nginx if missing
if ! command -v nginx &>/dev/null; then
    echo "Installing Nginx..."
    sudo apt-get install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
else
    echo "Nginx already installed."
fi

# Add user to Docker group
sudo usermod -aG docker $USER || true

# Verify versions
docker --version
docker-compose --version
nginx -v

echo "Remote environment setup completed."
EOF

echo "Remote server is ready for deployment."



# ====== Step 6: Deploy Dockerized Application ======
echo "Deploying Dockerized application to $SSH_USER@$SSH_IP..."

# Define remote project directory
REMOTE_DIR="~/$(basename "$GIT_REPO" .git)"

# Transfer project files (rsync preferred for updates)
echo "Transferring project files..."
rsync -avz -e "ssh -i $SSH_KEY" ./ "$SSH_USER@$SSH_IP:$REMOTE_DIR/"

# SSH into remote server to build and run containers
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" <<EOF
echo "Connected to remote server for deployment."

cd "$REMOTE_DIR" || exit 1

# Deploy using docker-compose if present, else use Dockerfile
if [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]]; then
    echo "Found docker-compose file. Deploying containers..."
    docker-compose down || true  # Stop old containers safely
    docker-compose up -d --build
elif [[ -f "Dockerfile" ]]; then
    echo "Found Dockerfile. Building and running container..."
    IMAGE_NAME=$(basename "$REMOTE_DIR" | tr '[:upper:]' '[:lower:]')
    docker stop "$IMAGE_NAME" || true
    docker rm "$IMAGE_NAME" || true
    docker build -t "$IMAGE_NAME" .
    docker run -d -p $APP_PORT:$APP_PORT --name "$IMAGE_NAME" "$IMAGE_NAME"
else
    echo "Error: No Dockerfile or docker-compose.yml found."
    exit 1
fi

# Validate containers are running
echo "Checking running containers..."
docker ps
EOF

echo "Deployment completed successfully."


# ====== Step 7: Configure Nginx Reverse Proxy ======
echo "Configuring Nginx as a reverse proxy..."

REMOTE_DIR="~/$(basename "$GIT_REPO" .git)"

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" <<EOF
echo "Connected to remote server for Nginx configuration."

# Define server block file
NGINX_CONF="/etc/nginx/sites-available/$(basename "$REMOTE_DIR")"

# Create Nginx config
sudo tee "$NGINX_CONF" > /dev/null <<EOL
server {
    listen 80;

    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Enable the config
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

# Test Nginx configuration
sudo nginx -t

# Reload Nginx to apply changes
sudo systemctl reload nginx

echo "Nginx reverse proxy configured successfully."
EOF

echo "Nginx is now forwarding HTTP traffic to the application."

# ====== Step 8: Validate Deployment ======
echo "Validating deployment on $SSH_USER@$SSH_IP..."

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" <<EOF
echo "Connected to remote server for validation."

# Check Docker service
if systemctl is-active --quiet docker; then
    echo "Docker service is running."
else
    echo "Error: Docker service is not running!"
    exit 1
fi

# Check if container is running
CONTAINER_NAME=$(basename "$REMOTE_DIR" | tr '[:upper:]' '[:lower:]')
if docker ps --format '{{.Names}}' | grep -w "$CONTAINER_NAME" &>/dev/null; then
    echo "Container '$CONTAINER_NAME' is running."
else
    echo "Error: Container '$CONTAINER_NAME' is not running!"
    exit 1
fi

# Optional: Check container health if healthcheck exists
if docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" &>/dev/null; then
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME")
    echo "Container health status: $HEALTH_STATUS"
fi

# Test Nginx proxy locally
if curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q "200"; then
    echo "Nginx is proxying requests successfully."
else
    echo "Warning: Nginx may not be proxying correctly."
fi

EOF

echo "Deployment validation completed."


# ====== Step 9: Logging and Error Handling ======
# Enable strict mode
set -euo pipefail

# Create timestamped log file
LOG_FILE="deploy_$(date '+%Y%m%d_%H%M%S').log"
echo "Deployment started at $(date)" | tee -a "$LOG_FILE"

# Function to log messages
log() {
    local MESSAGE="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" | tee -a "$LOG_FILE"
}

# Function to handle errors
error_exit() {
    local MESSAGE="$1"
    local CODE="${2:-1}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $MESSAGE" | tee -a "$LOG_FILE" >&2
    exit "$CODE"
}

# Trap unexpected errors anywhere in the script
trap 'error_exit "Unexpected error occurred at line $LINENO."' ERR

# Example usage in the script
log "Starting deployment..."


# ====== Step 10: Idempotency and Cleanup ======
CLEANUP=false

# Check for --cleanup flag
for arg in "$@"; do
    if [[ "$arg" == "--cleanup" ]]; then
        CLEANUP=true
        break
    fi
done

# Define variables
REMOTE_DIR="~/$(basename "$GIT_REPO" .git)"
CONTAINER_NAME=$(basename "$GIT_REPO" .git | tr '[:upper:]' '[:lower:]')
NGINX_CONF="/etc/nginx/sites-available/$CONTAINER_NAME"

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_IP" <<EOF
echo "Connected to remote server for cleanup/idempotency..."

if $CLEANUP; then
    echo "Cleanup mode enabled. Removing containers, images, Nginx config, and project files..."

    docker stop "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
    docker rmi "$CONTAINER_NAME" || true
    sudo rm -f "$NGINX_CONF"
    sudo rm -f /etc/nginx/sites-enabled/"$CONTAINER_NAME"
    sudo nginx -s reload || true
    rm -rf "$REMOTE_DIR"

    echo "Cleanup completed."
else
    echo "Ensuring idempotency for deployment..."

    # Stop old container if running
    if docker ps --format '{{.Names}}' | grep -w "$CONTAINER_NAME" &>/dev/null; then
        echo "Stopping old container..."
        docker stop "$CONTAINER_NAME"
        docker rm "$CONTAINER_NAME"
    fi

    # Remove duplicate Nginx config symlink if exists
    if [[ -L /etc/nginx/sites-enabled/"$CONTAINER_NAME" ]]; then
        sudo rm -f /etc/nginx/sites-enabled/"$CONTAINER_NAME"
    fi

    echo "Idempotency checks completed."
fi
EOF

echo "Idempotency and cleanup step finished."
