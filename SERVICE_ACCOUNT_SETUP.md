# Service Account and VM Setup Guide
----------------------------------------

This script creates a service account, sets up firewall rules, and creates a GCE VM instance that you can SSH into to run the EasyGCE scripts.

## Prerequisites
-----------------

* Installed gcloud CLI tool
* Authenticated with Google Cloud (`gcloud auth login`)
* Project with Compute Engine API enabled

## Quick Start
--------------

```bash
./gce_setup_with_service_account.sh -p mavgollc
```

## Script Features
------------------

The script performs the following operations:

1. **SSH Key Generation**: Creates an SSH key pair for secure VM access
2. **Service Account Creation**: Creates a dedicated service account with necessary permissions
3. **Firewall Rules**: Opens required ports (22, 80, 443, 3389, 5901, 6901)
4. **VM Instance Creation**: Creates Ubuntu VM with the service account attached
5. **Script Transfer**: Copies all EasyGCE scripts to the VM via SSH
6. **Connection Info**: Provides SSH and remote desktop connection details

## Usage Options
----------------

```bash
Usage: ./gce_setup_with_service_account.sh -p <gce_project_name> [OPTIONS]

Required:
  -p <project_name>     GCE project name

Optional:
  -s <service_account>  Service account name (default: easygce-service-account)
  -n <vm_name>          VM instance name (default: project_name-timestamp)
  -z <zone>             GCE zone (default: us-east1-c)
  -m <machine_type>     Machine type (default: n1-standard-2)
  -k <ssh_key_path>     SSH key path (default: ~/.ssh/easygce_key)
  -b                    Auto-delete boot disk when VM is deleted
  -h                    Show help
```

## Examples
-----------

### Basic Setup
```bash
./gce_setup_with_service_account.sh -p mavgollc
```

### Custom Configuration
```bash
./gce_setup_with_service_account.sh -p mavgollc -n my-desktop-vm -z us-west1-a -m n1-standard-4
```

### Auto-delete Boot Disk
```bash
./gce_setup_with_service_account.sh -p mavgollc -b
```

## After VM Creation
--------------------

Once the script completes, you'll receive connection information:

### SSH into the VM
```bash
ssh -i ~/.ssh/easygce_key <username>@<vm_ip>
```

### Install Desktop Environment
```bash
sudo /tmp/scripts/21_install_desktop.sh
```

### Install Remote Desktop Servers
```bash
sudo /tmp/scripts/23_install_remote_desktops.sh
```

### Or Run Full EasyGCE Setup
```bash
sudo /tmp/gce_server_deploy.sh -p mavgollc
```

## Service Account Permissions
------------------------------

The created service account has these roles:
* `roles/compute.instanceAdmin` - Manage VM instances
* `roles/compute.securityAdmin` - Manage firewall rules

## Firewall Ports
-----------------

The script opens these ports automatically:
* **22** - SSH access
* **80** - HTTP web access
* **443** - HTTPS web access
* **3389** - RDP (Remote Desktop Protocol)
* **5901** - VNC (Virtual Network Computing)
* **6901** - Web-based VNC

## Remote Desktop Access
------------------------

After running the desktop setup scripts:

### macOS Quick Connect
For Mac users, use the automated connection script:
```bash
# VNC connection (uses built-in Screen Sharing) [DEFAULT]
./connect_mac_rdp.sh -p mavgollc

# RDP connection (requires Microsoft Remote Desktop from App Store)
./connect_mac_rdp.sh -p mavgollc -t rdp

# Web-based VNC (opens in browser)
./connect_mac_rdp.sh -p mavgollc -t web
```

### Manual Connections

#### RDP (Windows/Mac/Linux)
* **Connection**: `<vm_ip>:3389`
* **Username**: `ubuntu`
* **Password**: `ubuntu123`
* **Mac**: Requires Microsoft Remote Desktop from App Store

#### VNC
* **Connection**: `<vm_ip>:5901`
* **Password**: `ubuntu123`
* **Mac**: Use built-in Screen Sharing or `open vnc://<vm_ip>:5901`

#### Web VNC
* **URL**: `http://<vm_ip>:6901`
* **Password**: `ubuntu123`

## Troubleshooting
------------------

### Script Fails with Permission Errors
Ensure you have the following IAM roles in your GCP project:
* `roles/compute.admin`
* `roles/iam.serviceAccountAdmin`
* `roles/resourcemanager.projectIamAdmin`

### SSH Connection Issues
* Verify the SSH key was generated: `ls -la ~/.ssh/easygce_key*`
* Check firewall rules allow port 22
* Ensure VM is in RUNNING state

### Can't Connect to Remote Desktop
* Verify the desktop installation scripts ran successfully
* Check that firewall rules are created for ports 3389, 5901, 6901
* Ensure the VM has sufficient resources (minimum n1-standard-2)

## Cleanup
----------

To remove resources created by this script:

```bash
# Delete VM instance
gcloud compute instances delete <vm_name> --zone=<zone>

# Delete firewall rules
gcloud compute firewall-rules delete easygce-inbound-tcp-22
gcloud compute firewall-rules delete easygce-inbound-tcp-80
gcloud compute firewall-rules delete easygce-inbound-tcp-443
gcloud compute firewall-rules delete easygce-inbound-tcp-3389
gcloud compute firewall-rules delete easygce-inbound-tcp-5901
gcloud compute firewall-rules delete easygce-inbound-tcp-6901

# Delete service account
gcloud iam service-accounts delete easygce-service-account@<project>.iam.gserviceaccount.com
```