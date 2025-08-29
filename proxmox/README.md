# Proxmox LXC Setup for OtterWiki

This directory contains scripts and documentation for deploying OtterWiki in Proxmox LXC containers.

## Overview

The `setup-otterwiki-lxc.sh` script automates the creation and configuration of an LXC container in Proxmox VE for running OtterWiki. It handles everything from container creation to service configuration, providing a ready-to-use OtterWiki installation.

## Features

- **Ubuntu 24.04 LTS**: Uses the latest Ubuntu LTS template
- **Automated Setup**: Complete installation and configuration of OtterWiki
- **Flexible Configuration**: Customizable resources, networking, and authentication
- **Production Ready**: Includes nginx, uWSGI, and supervisor for reliable service management
- **Host DNS Integration**: Automatically uses host DNS settings as default

## Requirements

- Proxmox VE 7.0 or later
- Root access to Proxmox host
- Available container ID number
- Network bridge configured (default: vmbr0)
- Storage pool available (default: local-lvm)

## Quick Start

### Execute Directly from GitHub

Run the script directly from the repository without cloning:

```bash
# Basic usage with DHCP
curl -fsSL https://raw.githubusercontent.com/redimp/otterwiki/main/proxmox/setup-otterwiki-lxc.sh | bash -s -- -i 100

# With static IP and SSH key
curl -fsSL https://raw.githubusercontent.com/redimp/otterwiki/main/proxmox/setup-otterwiki-lxc.sh | bash -s -- -i 100 -a 192.168.1.100/24 -g 192.168.1.1 -k ~/.ssh/id_rsa.pub
```

### Local Usage

After cloning or downloading the script locally:

#### Basic Usage

Create a container with DHCP networking:

```bash
./setup-otterwiki-lxc.sh -i 100
```

#### Advanced Usage

Create a container with static IP and SSH key authentication:

```bash
./setup-otterwiki-lxc.sh -i 100 \
  -n "otterwiki-prod" \
  -a 192.168.1.100/24 \
  -g 192.168.1.1 \
  -k ~/.ssh/id_rsa.pub \
  -m 4096 \
  -c 4
```

## Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --id` | Container ID (required) | - |
| `-n, --name` | Container hostname | otterwiki |
| `-t, --template` | Ubuntu template | ubuntu-24.04-standard_24.04-2_amd64.tar.zst |
| `-s, --storage` | Storage pool | auto-detect |
| `-m, --memory` | Memory in MB | 2048 |
| `-c, --cores` | CPU cores | 2 |
| `-d, --disk` | Disk size | 20G |
| `-b, --bridge` | Network bridge | vmbr0 |
| `-a, --ip` | Static IP (CIDR format) | DHCP |
| `-g, --gateway` | Gateway IP | - |
| `-ns, --nameserver` | DNS server | Host DNS |
| `-k, --ssh-key` | SSH public key file | - |
| `-p, --password` | Root password | Interactive prompt |
| `-h, --help` | Show help message | - |

## What the Script Does

1. **Validation**: Checks Proxmox environment and container ID availability
2. **Template Management**: Downloads Ubuntu 24.04 template if not present
3. **Container Creation**: Creates LXC container with specified configuration
4. **System Setup**: Updates packages and installs dependencies
5. **OtterWiki Installation**: Sets up Python environment and installs OtterWiki
6. **Service Configuration**: Configures nginx, uWSGI, and supervisor
7. **Data Setup**: Initializes git repository and configuration files

## Post-Installation

### Accessing OtterWiki

After successful installation:

- **Web Interface**: `http://[container-ip]` (port 80)
- **Container Shell**: `pct enter [container-id]`
- **First User**: The first registered user becomes the admin

### Container Management

```bash
# Start container
pct start 100

# Stop container
pct stop 100

# Enter container
pct enter 100

# View container status
pct status 100

# Delete container
pct destroy 100
```

### Service Management (inside container)

```bash
# Restart services
systemctl restart supervisor

# Check service status
supervisorctl status

# View logs
supervisorctl tail -f uwsgi
supervisorctl tail -f nginx
```

## Configuration Files

Key configuration files in the container:

- **OtterWiki Config**: `/app-data/settings.cfg`
- **uWSGI Config**: `/app/uwsgi.ini`
- **Nginx Config**: `/etc/nginx/sites-available/otterwiki`
- **Supervisor Config**: `/etc/supervisor/conf.d/otterwiki.conf`

## Data Persistence

- **Wiki Data**: `/app-data/repository` (git repository)
- **Database**: `/app-data/db.sqlite`
- **Configuration**: `/app-data/settings.cfg`

## Networking Examples

### Static IP Configuration

```bash
# Single static IP
./setup-otterwiki-lxc.sh -i 100 -a 192.168.1.100/24 -g 192.168.1.1

# Custom DNS server
./setup-otterwiki-lxc.sh -i 100 -a 192.168.1.100/24 -g 192.168.1.1 -ns 1.1.1.1
```

### Different Network Bridge

```bash
# Use custom bridge
./setup-otterwiki-lxc.sh -i 100 -b vmbr1
```

## Troubleshooting

### Common Issues

1. **Storage Error** (`no such logical volume`): 
   - The script now auto-detects available storage
   - To manually specify: `./setup-otterwiki-lxc.sh -i 100 -s local`
   - Check available storage: `pvesm status -content rootdir`

2. **Template Download Fails**: Check internet connectivity and Proxmox subscription

3. **Container ID Exists**: Use a different ID or remove existing container

4. **Network Issues**: Verify bridge configuration and IP ranges

5. **SSH Key Not Found**: Ensure path to SSH key file is correct

### Log Locations

- **Container Creation**: Script output shows detailed progress
- **Service Logs**: Available via `supervisorctl tail` commands
- **System Logs**: `/var/log/` in container

### Getting Help

For issues with:
- **Script**: Check script output and container logs
- **OtterWiki**: Consult [OtterWiki documentation](https://otterwiki.com/)
- **Proxmox**: Check Proxmox VE documentation

## Security Considerations

- Change default secret key in `/app-data/settings.cfg`
- Configure proper firewall rules
- Use SSH key authentication when possible
- Regularly update container packages
- Monitor container resource usage

## Customization

The script can be modified to:
- Install additional packages
- Configure different web servers
- Adjust service configurations
- Set up SSL certificates
- Configure backup scripts

## License

This script is part of the OtterWiki project and follows the same licensing terms.