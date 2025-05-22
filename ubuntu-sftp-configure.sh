#!/bin/bash


# Ubuntu SFTP Server Configuration Script - Tested on Ubuntu 24.04 and 25.04
# What it does: Configure a new Ubuntu VM as a secure SFTP target
# with specific users and folder permissions
# Created by Seth Crosby
# GNU license

# Create log file
LOGFILE="/tmp/sftp-setup.sh.log"
exec > >(tee -a "$LOGFILE") 2>&1

set -e 

# Initialize an array to store all passwords
declare -A ALL_PASSWORDS

# Function to generate secure passwords according to requirements
generate_secure_password() {
    # Generate a password that meets the following requirements:
    # - 18 characters in length
    # - At least 1 uppercase letter
    # - At least 1 lowercase letter
    # - At least 1 numeric digit
    # - At least 1 special character (not a letter or digit)
    
    local length=18
    local uppercase_chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local lowercase_chars="abcdefghijklmnopqrstuvwxyz"
    local numeric_chars="0123456789"
    local special_chars="!@#$%^&*()-_=+[]{}|;:,.<>?/~"
    local all_chars="${uppercase_chars}${lowercase_chars}${numeric_chars}${special_chars}"
    
    # First, ensure we have at least one of each required character type
    local password=""
    password="${password}${uppercase_chars:$(( RANDOM % ${#uppercase_chars} )):1}"
    password="${password}${lowercase_chars:$(( RANDOM % ${#lowercase_chars} )):1}"
    password="${password}${numeric_chars:$(( RANDOM % ${#numeric_chars} )):1}"
    password="${password}${special_chars:$(( RANDOM % ${#special_chars} )):1}"
    
    # Fill the rest of the password with random characters
    while [ ${#password} -lt $length ]; do
        password="${password}${all_chars:$(( RANDOM % ${#all_chars} )):1}"
    done
    
    # Shuffle the password characters to avoid predictable pattern
    password=$(echo "$password" | fold -w1 | shuf | tr -d '\n')
    
    echo "$password"
}

echo "============================================================"
echo "Starting SFTP Server Configuration for Ubuntu 24/25"
echo "$(date)"
echo "============================================================"


# UBUNTU: Update the package lists and upgrade installed packages
echo "[1/6] Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

# UBUNTU: Install necessary packages
echo "[2/6] Installing required software..."
sudo apt-get install -y openssh-server ufw acl openssl

# UBUNTU: Configure UFW (Ubuntu's default firewall)
echo "[3/6] Configuring firewall..."
sudo ufw --force enable
sudo ufw allow ssh
sudo ufw reload

# User/directory strucutre

echo "[4/6] Creating users and directory structure..."

# Create buadmin user as "break glass" or maintenance account
sudo useradd -m buadmin -c "Backup Administrator" -s /bin/bash
ADMIN_PASS=$(generate_secure_password)
echo "buadmin:$ADMIN_PASS" | sudo chpasswd
sudo usermod -aG sudo buadmin
echo "Administrator user 'buadmin' created"
# Store password in array
ALL_PASSWORDS["buadmin"]=$ADMIN_PASS

# Create main backup directory
sudo mkdir -p /vmwbackups
sudo chown root:root /vmwbackups
sudo chmod 755 /vmwbackups

# Create SFTP users and their directories
declare -A users=(
    ["vcsa-buuser"]="/vmwbackups/vcsa"
    ["nsx-buuser"]="/vmwbackups/nsx"
    ["sddc-buuser"]="/vmwbackups/sddc"
    ["avi-buuser"]="/vmwbackups/avi"
)

# Create a common group for sFTP users
sudo groupadd --system sftpusers 

for user in "${!users[@]}"; do
    # Create user
    sudo useradd -m "$user" -c "SFTP Backup User" -s /bin/bash
    USER_PASS=$(generate_secure_password)
    echo "$user:$USER_PASS" | sudo chpasswd
    echo "User '$user' created"
    # Store password in array
    ALL_PASSWORDS["$user"]=$USER_PASS
    
    # Add user to sftpusers group
    sudo usermod -aG sftpusers "$user"
    
    # Create directory
    sudo mkdir -p "${users[$user]}"
    
    # Set ownership and permissions
    # Root owns the directory, but user can write to it
    sudo chown root:root "${users[$user]}"
    sudo chmod 755 "${users[$user]}"
    
    # Set permissions to allow writing but not deletion
    sudo setfacl -m u:"$user":rwx "${users[$user]}"
    sudo setfacl -d -m u:"$user":rwx "${users[$user]}"
    
    echo "Directory '${users[$user]}' configured for user '$user'"
done

# Create read-only user for all backup folders
readonly_user="restore-operator"
sudo useradd -m "$readonly_user" -c "Backup Read-Only User" -s /bin/bash
READONLY_PASS=$(generate_secure_password)
echo "$readonly_user:$READONLY_PASS" | sudo chpasswd
echo "Read-only user '$readonly_user' created"

ALL_PASSWORDS["$readonly_user"]=$READONLY_PASS

for dir in "${users[@]}"; do
    sudo setfacl -m u:"$readonly_user":rx "$dir"
    sudo setfacl -d -m u:"$readonly_user":rx "$dir"
done

echo "Read-only user '$readonly_user' configured with access to all backup folders"

# Give buadmin access to all folders
for dir in "${users[@]}"; do
    sudo setfacl -m u:buadmin:rwx "$dir"
    sudo setfacl -d -m u:buadmin:rwx "$dir"
done

# SSH/SFTP Config

echo "[5/6] Configuring SSH for SFTP..."

# Create a secure SSHD config
sudo bash -c "cat > /etc/ssh/sshd_config << EOL
# SSH Server Configuration
Port 22
Protocol 2
PermitRootLogin no
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
PrintMotd no

# SFTP Subsystem Configuration
Subsystem sftp internal-sftp

# SFTP User Configuration
Match Group sftpusers
    ForceCommand internal-sftp
    ChrootDirectory /
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes

# Read-only user configuration
Match User $readonly_user
    ForceCommand internal-sftp
    ChrootDirectory /
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOL"

# UBUNTU: AppArmor Configuration for SFTP (Ubuntu's MAC system)
echo "[6/6] Configuring AppArmor for SFTP..."
sudo apt-get install -y apparmor-utils

# UBUNTU: Check if AppArmor is enabled and configure SSH profile
if sudo aa-status >/dev/null 2>&1; then
    echo "AppArmor is active, configuring SSH profile..."
    sudo aa-complain /usr/sbin/sshd 2>/dev/null || true
else
    echo "AppArmor not active, skipping profile configuration"
fi

# Restart SSH service to apply changes
echo "Restarting SSH service..."
sudo systemctl restart ssh

# Enable SSH service to start on boot
sudo systemctl enable ssh

# Cleanup & show credentials

echo "============================================================"
echo "SFTP Server Configuration Complete!"
echo ""
echo "GENERATED ACCOUNT CREDENTIALS"
echo "------------------------------------------------------------"
printf "%-20s | %s\n" "USERNAME" "PASSWORD"
echo "------------------------------------------------------------"
printf "%-20s | %s\n" "buadmin" "${ALL_PASSWORDS["buadmin"]}"
for user in "${!users[@]}"; do
    printf "%-20s | %s\n" "$user" "${ALL_PASSWORDS["$user"]}"
done
printf "%-20s | %s\n" "$readonly_user" "${ALL_PASSWORDS["$readonly_user"]}"
echo "------------------------------------------------------------"
echo ""
echo "IMPORTANT: Please save these passwords securely!"
echo "============================================================"

# Print SSH status to verify
sudo systemctl status ssh --no-pager