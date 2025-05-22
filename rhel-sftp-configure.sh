#!/bin/bash


# RHEL SFTP Server Configuration Script - Tested on RHEL 9.5 and 9.6
# What it does: Configure a new RHEL 9 VM as a secure SFTP target
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
echo "Starting SFTP Server Configuration for RHEL 9"
echo "$(date)"
echo "============================================================"

# RHEL:  Update the package lists and upgrade installed packages
echo "[1/6] Updating system packages..."
sudo dnf check-update || true  # The check-update command returns exit code 100 if updates are available
sudo dnf upgrade -y

# RHEL: Install necessary packages
echo "[2/6] Installing required software..."
sudo dnf install -y openssh-server firewalld acl openssl


# RHEL: Configure firewalld (RHEL's default firewall)
echo "[3/6] Configuring firewall..."
sudo systemctl enable firewalld
sudo systemctl start firewalld
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload


# User/directory strucutre

echo "[4/6] Creating users and directory structure..."

# Create buadmin user as "break glass" or maintenance account
sudo useradd -m buadmin -c "Backup Administrator"
ADMIN_PASS=$(generate_secure_password)
echo "buadmin:$ADMIN_PASS" | sudo chpasswd
sudo usermod -aG wheel buadmin
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
    sudo useradd -m "$user" -c "SFTP Backup User"
    USER_PASS=$(generate_secure_password)
    echo "$user:$USER_PASS" | sudo chpasswd
    echo "User '$user' created"

    ALL_PASSWORDS["$user"]=$USER_PASS
    
    sudo usermod -aG sftpusers "$user"
    sudo mkdir -p "${users[$user]}"

    # Root owns the directory, but user can write to it
    sudo chown root:root "${users[$user]}"
    sudo chmod 755 "${users[$user]}"
    
    # Set permissions to allow writing but not deletion
    sudo setfacl -m u:"$user":rwx "${users[$user]}"
    sudo setfacl -d -m u:"$user":rwx "${users[$user]}"
    
    echo "Directory '${users[$user]}' configured for user '$user'"
done

# Create read-only user for all backups
readonly_user="restore-operator"
sudo useradd -m "$readonly_user" -c "Backup Read-Only User"
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

# RHEL:   SELINUX Configuration
echo "[6/6] Configuring SELinux for SFTP..."
sudo dnf install -y policycoreutils-python-utils
sudo setsebool -P ssh_chroot_rw_homedirs on
sudo setsebool -P allow_ssh_keysign on

# RHEL: Set proper SELinux context for the backup directories
sudo semanage fcontext -a -t ssh_home_t "/vmwbackups(/.*)?"
sudo restorecon -Rv /vmwbackups

# Restart SSH service to apply changes
echo "Restarting SSH service..."
sudo systemctl restart sshd

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
sudo systemctl status sshd --no-pager