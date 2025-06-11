# VMware SFTP Backup Target Configuration
## Overview
This is a set of handy configuration scripts to set up secure SFTP backup targets for VMware infrastructure components (eg. vCenter). Sets up an Ubuntu VM as a dedicated SFTP server with strong security, organized directories, multiple SFTP users (with appropriate permissions), read-only and admin accounts, and a strong baseline of hardening. Scripts are provided for Ubuntu and RHEL at this time.
### Why This Solution?
Critical Broadcom / VMware products generally offer a configuration file backup mechanism and it's the only thing VMware will support. This icludes vCenter Server, SDDC Manager, NSX Manager, and Avi Load Balancer, among others. These all require SFTP targets for backups and the vendor will not officially support snapshot- or image-based VM backup solutions. (vCenter gives options other than SFTP, but I'm preferential to a single backup protocol and destination.)
## Traditional approaches often involve:
- Running SFTP servers on Windows Server (easy to maintain, but... Windows is the backup destination. AD is a risk.)
- Manual configuration, prone to security gaps
- Permission structures are usually overlooked

## This solution provides:
- Secure alternative to Windows-based SFTP servers
- Automated, consistent configuration
- Proper isolation between different product backup folders with unique users/permissions
- Centralized backup target that can itself be protected by an enterprise backup solution (Commvault, Veeam, other)

## Security Features:
- Strong, random passwords for all users.
- No root or read-only logins over SSH.
- SFTP-only access for non-admins, chrooted for safety.
- Admin and read-only accounts for emergency use and restore scenarios.
- Granular permissions:
  - SFTP users can access only their designated directories.
  - Read-only user can read (not modify) all.
  - Backup Admin can access all.

## Architecture
The scripts create a structured SFTP environment with:
### User Roles
- Administrator (buadmin) - Full access to all backup directories
- Product-specific users - Write access only to their designated folders
  - vcsa-buuser - vCenter Server backups
  - nsx-buuser - NSX Manager backups
  - sddc-buuser - SDDC Manager backups
  - avi-buuser - Avi Load balancer backups
  - Restore operator (restore-operator) - Read-only access to all backup directories, SCP-only access and no SSH permission

### Directory Structure
```
/vmwbackups/
├── vcsa/    # vCenter Server backups
├── nsx/     # NSX Manager backups
└── sddc/    # SDDC Manager backups
... Others can be created, of course.
```

### Permissions
There's a lot of reasons to keep permissions separate between the user who writes backups and the user who would be restoring. Here's how the permissions look under one folder (vcsa) once the script has built the services, users, and directories and a backup has been sent. 

![Backup Directory Permissions](./assets/folder-permissions1.png)

# How to use? 
More detail forthcoming, but follow these steps:
 - Build your host VM. I generally install as minimal/no gui. 
 - Update pacakges, make sure ssh services are started. 
 - SCP this script to your host VM. 
 - Run the script -- it will request an elevated privilege password, and will build the services and directory structure above.
 - Log into your VMware system (eg. https://vcsa.yourdomain.net:5480 ) and configure the backups to point to the SFTP server you just set up.
 - Capture backups of that SFTP server on a sensible schedule and with adequate retention.
