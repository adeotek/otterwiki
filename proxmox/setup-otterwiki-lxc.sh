#!/bin/bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
CONTAINER_ID=""
CONTAINER_NAME="otterwiki"
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
STORAGE="local-lvm"
MEMORY=2048
CORES=2
DISK_SIZE="20G"
NETWORK="vmbr0"
IP_ADDRESS=""
GATEWAY=""
NAMESERVER="$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}' 2>/dev/null || echo '8.8.8.8')"
SSH_KEY=""
ROOT_PASSWORD=""

usage() {
    cat << EOF
Usage: $SCRIPT_NAME -i CONTAINER_ID [OPTIONS]

Creates an LXC container in Proxmox for OtterWiki

Required:
  -i, --id CONTAINER_ID        Container ID (e.g., 100)

Optional:
  -n, --name NAME              Container name (default: $CONTAINER_NAME)
  -t, --template TEMPLATE      CT template (default: $TEMPLATE)
  -s, --storage STORAGE        Storage location (default: $STORAGE)
  -m, --memory MEMORY          Memory in MB (default: $MEMORY)
  -c, --cores CORES            CPU cores (default: $CORES)
  -d, --disk DISK_SIZE         Disk size (default: $DISK_SIZE)
  -b, --bridge NETWORK         Network bridge (default: $NETWORK)
  -a, --ip IP_ADDRESS          Static IP address (CIDR format, e.g., 192.168.1.100/24)
  -g, --gateway GATEWAY        Gateway IP address
  -ns, --nameserver NS         DNS nameserver (default: host DNS)
  -k, --ssh-key SSH_KEY        Path to SSH public key file
  -p, --password PASSWORD      Root password (will prompt if not provided)
  -h, --help                   Show this help message

Example:
  $SCRIPT_NAME -i 100 -a 192.168.1.100/24 -g 192.168.1.1 -k ~/.ssh/id_rsa.pub
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    exit 1
}

check_proxmox() {
    if ! command -v pct &> /dev/null; then
        error "This script must be run on a Proxmox host with pct command available"
    fi
}

check_template() {
    local template_path="/var/lib/vz/template/cache/$TEMPLATE"
    if [[ ! -f "$template_path" ]]; then
        log "Template $TEMPLATE not found, downloading..."
        pveam update
        pveam download local "$TEMPLATE" || error "Failed to download template $TEMPLATE"
    fi
}

validate_container_id() {
    if [[ ! "$CONTAINER_ID" =~ ^[0-9]+$ ]]; then
        error "Container ID must be a number"
    fi
    
    if pct status "$CONTAINER_ID" &>/dev/null; then
        error "Container with ID $CONTAINER_ID already exists"
    fi
}

create_container() {
    local create_cmd=(
        pct create "$CONTAINER_ID"
        "/var/lib/vz/template/cache/$TEMPLATE"
        --hostname "$CONTAINER_NAME"
        --memory "$MEMORY"
        --cores "$CORES"
        --rootfs "$STORAGE:$DISK_SIZE"
        --net0 "name=eth0,bridge=$NETWORK,firewall=1"
        --nameserver "$NAMESERVER"
        --features "nesting=1"
        --unprivileged 1
        --onboot 1
    )
    
    if [[ -n "$IP_ADDRESS" ]]; then
        if [[ -n "$GATEWAY" ]]; then
            create_cmd[${#create_cmd[@]}]="--net0"
            create_cmd[${#create_cmd[@]}]="name=eth0,bridge=$NETWORK,firewall=1,ip=$IP_ADDRESS,gw=$GATEWAY"
        else
            create_cmd[${#create_cmd[@]}]="--net0"
            create_cmd[${#create_cmd[@]}]="name=eth0,bridge=$NETWORK,firewall=1,ip=$IP_ADDRESS"
        fi
    fi
    
    if [[ -n "$SSH_KEY" ]]; then
        if [[ -f "$SSH_KEY" ]]; then
            create_cmd+=(--ssh-public-keys "$SSH_KEY")
        else
            error "SSH key file not found: $SSH_KEY"
        fi
    fi
    
    if [[ -n "$ROOT_PASSWORD" ]]; then
        create_cmd+=(--password "$ROOT_PASSWORD")
    fi
    
    log "Creating container $CONTAINER_ID..."
    "${create_cmd[@]}" || error "Failed to create container"
}

setup_container() {
    log "Starting container $CONTAINER_ID..."
    pct start "$CONTAINER_ID" || error "Failed to start container"
    
    log "Waiting for container to be ready..."
    sleep 10
    
    log "Updating system packages..."
    pct exec "$CONTAINER_ID" -- bash -c "apt-get update && apt-get upgrade -y" || error "Failed to update packages"
    
    log "Installing essential packages..."
    pct exec "$CONTAINER_ID" -- bash -c "apt-get install -y curl wget git python3 python3-pip python3-venv nginx supervisor uwsgi uwsgi-plugin-python3 build-essential python3-dev libjpeg-dev zlib1g-dev libxml2-dev libxslt-dev" || error "Failed to install packages"
    
    log "Setting up Python virtual environment..."
    pct exec "$CONTAINER_ID" -- python3 -m venv /opt/otterwiki-venv
    pct exec "$CONTAINER_ID" -- /opt/otterwiki-venv/bin/pip install --upgrade pip wheel
    
    log "Installing OtterWiki..."
    pct exec "$CONTAINER_ID" -- /opt/otterwiki-venv/bin/pip install otterwiki
    
    log "Creating directories..."
    pct exec "$CONTAINER_ID" -- mkdir -p /app-data /app/otterwiki
    pct exec "$CONTAINER_ID" -- chown -R www-data:www-data /app-data
    
    log "Creating uWSGI configuration..."
    pct exec "$CONTAINER_ID" -- tee /app/uwsgi.ini > /dev/null << 'EOF'
[uwsgi]
module = otterwiki.wsgi:application
uid = www-data
gid = www-data
virtualenv = /opt/otterwiki-venv

master = true
processes = 2

socket = /tmp/uwsgi.sock
chmod-socket = 666
vacuum = true

die-on-term = true
EOF
    
    log "Creating Supervisor configuration..."
    pct exec "$CONTAINER_ID" -- tee /etc/supervisor/conf.d/otterwiki.conf > /dev/null << 'EOF'
[program:uwsgi]
command=/opt/otterwiki-venv/bin/uwsgi --ini /app/uwsgi.ini
directory=/app
user=www-data
autostart=true
autorestart=true
redirect_stderr=true

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
redirect_stderr=true
EOF
    
    log "Creating Nginx configuration..."
    pct exec "$CONTAINER_ID" -- tee /etc/nginx/sites-available/otterwiki > /dev/null << 'EOF'
server {
    listen 80 default_server;
    server_name _;

    client_max_body_size 50M;

    location /static {
        alias /opt/otterwiki-venv/lib/python3.12/site-packages/otterwiki/static;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location / {
        include uwsgi_params;
        uwsgi_pass unix:/tmp/uwsgi.sock;
        uwsgi_param SCRIPT_NAME '';
    }
}
EOF
    
    log "Enabling Nginx site..."
    pct exec "$CONTAINER_ID" -- rm -f /etc/nginx/sites-enabled/default
    pct exec "$CONTAINER_ID" -- ln -sf /etc/nginx/sites-available/otterwiki /etc/nginx/sites-enabled/
    
    log "Creating OtterWiki configuration..."
    pct exec "$CONTAINER_ID" -- tee /app-data/settings.cfg > /dev/null << 'EOF'
SECRET_KEY = 'change-this-secret-key-in-production'
REPOSITORY = '/app-data/repository'
SQLALCHEMY_DATABASE_URI = 'sqlite:////app-data/db.sqlite'
OTTERWIKI_NAME = 'OtterWiki'
OTTERWIKI_MAIL_DEFAULT_SENDER = 'otterwiki@localhost'
OTTERWIKI_WELCOME_PAGE = 'Home'
EOF
    
    log "Setting up environment..."
    pct exec "$CONTAINER_ID" -- tee /etc/environment > /dev/null << EOF
OTTERWIKI_SETTINGS=/app-data/settings.cfg
OTTERWIKI_REPOSITORY=/app-data/repository
PATH="/opt/otterwiki-venv/bin:\$PATH"
EOF
    
    log "Initializing OtterWiki repository..."
    pct exec "$CONTAINER_ID" -- mkdir -p /app-data/repository
    pct exec "$CONTAINER_ID" -- bash -c "cd /app-data/repository && git init --bare"
    pct exec "$CONTAINER_ID" -- chown -R www-data:www-data /app-data
    
    log "Starting services..."
    pct exec "$CONTAINER_ID" -- systemctl enable supervisor
    pct exec "$CONTAINER_ID" -- systemctl start supervisor
    
    log "Container setup completed successfully!"
    log "Container ID: $CONTAINER_ID"
    log "Container Name: $CONTAINER_NAME"
    
    if [[ -n "$IP_ADDRESS" ]]; then
        log "IP Address: $IP_ADDRESS"
    else
        local container_ip
        container_ip=$(pct exec "$CONTAINER_ID" -- ip route get 1 | awk '{print $7}' | head -1)
        log "IP Address: $container_ip (DHCP)"
    fi
    
    log ""
    log "To access the container:"
    log "  pct enter $CONTAINER_ID"
    log ""
    log "Access OtterWiki at:"
    if [[ -n "$IP_ADDRESS" ]]; then
        log "  http://${IP_ADDRESS%/*}"
    else
        log "  http://[container-ip]"
    fi
    log ""
    log "First registered user will become the admin."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--id)
            CONTAINER_ID="$2"
            shift 2
            ;;
        -n|--name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -t|--template)
            TEMPLATE="$2"
            shift 2
            ;;
        -s|--storage)
            STORAGE="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -c|--cores)
            CORES="$2"
            shift 2
            ;;
        -d|--disk)
            DISK_SIZE="$2"
            shift 2
            ;;
        -b|--bridge)
            NETWORK="$2"
            shift 2
            ;;
        -a|--ip)
            IP_ADDRESS="$2"
            shift 2
            ;;
        -g|--gateway)
            GATEWAY="$2"
            shift 2
            ;;
        -ns|--nameserver)
            NAMESERVER="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        -p|--password)
            ROOT_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

if [[ -z "$CONTAINER_ID" ]]; then
    error "Container ID is required. Use -i or --id option."
fi

if [[ -z "$ROOT_PASSWORD" && -z "$SSH_KEY" ]]; then
    echo -n "Enter root password for the container: "
    read -s ROOT_PASSWORD
    echo
fi

log "Starting LXC container creation process..."
check_proxmox
validate_container_id
check_template
create_container
setup_container

log "LXC container creation completed successfully!"