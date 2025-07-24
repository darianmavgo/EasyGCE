#!/bin/bash

#####
##### Setup Google Cloud Storage Downloads Folder with FUSE
#####

## Set defaults
GCE_PROJECT_NAME=mavgollc
GCS_BUCKET_NAME="${GCE_PROJECT_NAME}-easygce-downloads"
DOWNLOADS_PATH="/home/ubuntu/Downloads"
MOUNT_POINT="/home/ubuntu/Downloads"
GCE_VM_NAME=
GCE_VM_ZONE=us-east1-c
SSH_KEY_PATH="$HOME/.ssh/easygce_key"
SSH_USER=$(whoami)

usage(){
  cat <<-EOF

Usage: $0 -p <gce_project_name> [OPTIONS]

Required:
  -p <project_name>     GCE project name

Optional:
  -b <bucket_name>      GCS bucket name (default: project-easygce-downloads)
  -d <downloads_path>   Downloads folder path (default: /home/ubuntu/Downloads)
  -n <vm_name>          VM instance name (auto-detect if not specified)
  -z <zone>             GCE zone (default: us-east1-c)
  -k <ssh_key_path>     SSH key path (default: ~/.ssh/easygce_key)
  -u <ssh_user>         SSH username (default: current user)
  -h                    Show this help

Examples:
  $0 -p mavgollc
  $0 -p mavgollc -b my-downloads-bucket
  $0 -p mavgollc -d /home/ubuntu/MyDownloads

EOF
}

while getopts "p:b:d:n:z:k:u:h" opt; do
    case "${opt}" in
        p)
            GCE_PROJECT_NAME=${OPTARG}
            GCS_BUCKET_NAME="${GCE_PROJECT_NAME}-easygce-downloads"
            ;;
        b)
            GCS_BUCKET_NAME=${OPTARG}
            ;;
        d)
            DOWNLOADS_PATH=${OPTARG}
            MOUNT_POINT=${OPTARG}
            ;;
        n)
            GCE_VM_NAME=${OPTARG}
            ;;
        z)
            GCE_VM_ZONE=${OPTARG}
            ;;
        k)
            SSH_KEY_PATH=${OPTARG}
            ;;
        u)
            SSH_USER=${OPTARG}
            ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

# Validate required parameters
if [[ -z ${GCE_PROJECT_NAME} ]]; then
    echo -e "\n\tERROR: GCE project name is required (-p option)"
    usage
    exit 1
fi

#####
##### Functions
#####

set_gcloud_project(){
    echo "Setting gcloud project to: ${GCE_PROJECT_NAME}"
    gcloud config set project ${GCE_PROJECT_NAME} >/dev/null 2>&1
}

find_vm_instance(){
    if [[ -z ${GCE_VM_NAME} ]]; then
        echo "Auto-detecting EasyGCE VM instance..."
        
        # Look for VMs with "easygce" in the name
        local vm_list=$(gcloud compute instances list --format="value(name,zone)" --filter="name~easygce")
        
        if [[ -z ${vm_list} ]]; then
            # Fallback: look for any running VM in the specified zone
            vm_list=$(gcloud compute instances list --format="value(name,zone)" --filter="zone:${GCE_VM_ZONE} AND status:RUNNING")
        fi
        
        if [[ -z ${vm_list} ]]; then
            echo "ERROR: No running VM instances found in project ${GCE_PROJECT_NAME}"
            exit 1
        fi
        
        # Take the first match
        GCE_VM_NAME=$(echo "${vm_list}" | head -1 | cut -d$'\t' -f1)
        GCE_VM_ZONE=$(echo "${vm_list}" | head -1 | cut -d$'\t' -f2)
        
        echo "Found VM: ${GCE_VM_NAME} in zone: ${GCE_VM_ZONE}"
    fi
}

get_vm_ip(){
    gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
}

run_remote_command(){
    local vm_ip=$(get_vm_ip)
    local command="$1"
    ssh -i ${SSH_KEY_PATH} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${SSH_USER}@${vm_ip} "${command}"
}

create_gcs_bucket(){
    echo "=== Creating Google Cloud Storage Bucket ==="
    
    # Check if bucket already exists
    if gsutil ls -b gs://${GCS_BUCKET_NAME} >/dev/null 2>&1; then
        echo "✓ GCS bucket already exists: gs://${GCS_BUCKET_NAME}"
    else
        echo "Creating GCS bucket: gs://${GCS_BUCKET_NAME}"
        
        # Create bucket with regional storage in same region as VM
        local vm_region=$(echo ${GCE_VM_ZONE} | sed 's/-[a-z]$//')
        gsutil mb -p ${GCE_PROJECT_NAME} -c STANDARD -l ${vm_region} gs://${GCS_BUCKET_NAME}
        
        if [[ $? -eq 0 ]]; then
            echo "✓ GCS bucket created successfully"
        else
            echo "✗ Failed to create GCS bucket"
            exit 1
        fi
    fi
    
    # Set bucket permissions (optional - for easier access)
    echo "Setting bucket permissions..."
    gsutil iam ch serviceAccount:$(gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="value(serviceAccounts[0].email)"):objectAdmin gs://${GCS_BUCKET_NAME}
}

install_gcsfuse(){
    echo "=== Installing gcsfuse on VM ==="
    
    echo "Adding gcsfuse repository..."
    run_remote_command "export GCSFUSE_REPO=gcsfuse-\$(lsb_release -c -s) && echo \"deb http://packages.cloud.google.com/apt \$GCSFUSE_REPO main\" | sudo tee /etc/apt/sources.list.d/gcsfuse.list"
    
    echo "Adding Google Cloud public key..."
    run_remote_command "curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -"
    
    echo "Installing gcsfuse..."
    run_remote_command "sudo apt-get update && sudo apt-get install -y gcsfuse"
    
    # Verify installation
    if run_remote_command "which gcsfuse" >/dev/null 2>&1; then
        echo "✓ gcsfuse installed successfully"
        run_remote_command "gcsfuse --version"
    else
        echo "✗ gcsfuse installation failed"
        exit 1
    fi
}

setup_downloads_folder(){
    echo "=== Setting up Downloads Folder ==="
    
    # Backup existing Downloads folder if it has content
    echo "Checking existing Downloads folder..."
    if run_remote_command "[ -d '${DOWNLOADS_PATH}' ] && [ \"\$(ls -A '${DOWNLOADS_PATH}' 2>/dev/null)\" ]"; then
        echo "Backing up existing Downloads folder content..."
        run_remote_command "sudo -u ubuntu mkdir -p '${DOWNLOADS_PATH}.backup' && sudo -u ubuntu cp -r '${DOWNLOADS_PATH}'/* '${DOWNLOADS_PATH}.backup'/ 2>/dev/null || true"
    fi
    
    # Create Downloads directory if it doesn't exist
    echo "Creating Downloads directory..."
    run_remote_command "sudo -u ubuntu mkdir -p '${DOWNLOADS_PATH}'"
    
    # Set proper permissions
    run_remote_command "sudo chown ubuntu:ubuntu '${DOWNLOADS_PATH}'"
    run_remote_command "sudo chmod 755 '${DOWNLOADS_PATH}'"
    
    echo "✓ Downloads folder prepared"
}

mount_gcs_bucket(){
    echo "=== Mounting GCS Bucket to Downloads Folder ==="
    
    # Create mount script
    echo "Creating mount script..."
    run_remote_command "sudo tee /usr/local/bin/mount-gcs-downloads.sh > /dev/null << 'EOF'
#!/bin/bash

BUCKET_NAME=\"${GCS_BUCKET_NAME}\"
MOUNT_POINT=\"${MOUNT_POINT}\"
LOG_FILE=\"/var/log/gcsfuse-downloads.log\"

# Function to log messages
log_message() {
    echo \"\$(date '+%Y-%m-%d %H:%M:%S') - \$1\" | sudo tee -a \"\$LOG_FILE\"
}

# Check if already mounted
if mountpoint -q \"\$MOUNT_POINT\"; then
    log_message \"GCS bucket already mounted at \$MOUNT_POINT\"
    exit 0
fi

# Ensure mount point exists
sudo -u ubuntu mkdir -p \"\$MOUNT_POINT\"

# Mount the bucket
log_message \"Mounting GCS bucket gs://\$BUCKET_NAME to \$MOUNT_POINT\"

gcsfuse \\
    --debug_gcs \\
    --debug_fuse \\
    --log-file=\"\$LOG_FILE\" \\
    --log-format=\"text\" \\
    --dir-mode=0755 \\
    --file-mode=0644 \\
    --uid=\$(id -u ubuntu) \\
    --gid=\$(id -g ubuntu) \\
    --foreground=false \\
    \"\$BUCKET_NAME\" \"\$MOUNT_POINT\"

if [ \$? -eq 0 ]; then
    log_message \"Successfully mounted GCS bucket\"
    
    # Create a test file to verify mount
    sudo -u ubuntu touch \"\$MOUNT_POINT/.gcsfuse-test\" 2>/dev/null || true
else
    log_message \"Failed to mount GCS bucket\"
    exit 1
fi
EOF"
    
    # Make mount script executable
    run_remote_command "sudo chmod +x /usr/local/bin/mount-gcs-downloads.sh"
    
    # Create unmount script
    echo "Creating unmount script..."
    run_remote_command "sudo tee /usr/local/bin/unmount-gcs-downloads.sh > /dev/null << 'EOF'
#!/bin/bash

MOUNT_POINT=\"${MOUNT_POINT}\"
LOG_FILE=\"/var/log/gcsfuse-downloads.log\"

# Function to log messages
log_message() {
    echo \"\$(date '+%Y-%m-%d %H:%M:%S') - \$1\" | sudo tee -a \"\$LOG_FILE\"
}

if mountpoint -q \"\$MOUNT_POINT\"; then
    log_message \"Unmounting GCS bucket from \$MOUNT_POINT\"
    fusermount -u \"\$MOUNT_POINT\"
    
    if [ \$? -eq 0 ]; then
        log_message \"Successfully unmounted GCS bucket\"
    else
        log_message \"Failed to unmount GCS bucket\"
        exit 1
    fi
else
    log_message \"GCS bucket not mounted at \$MOUNT_POINT\"
fi
EOF"
    
    # Make unmount script executable
    run_remote_command "sudo chmod +x /usr/local/bin/unmount-gcs-downloads.sh"
    
    # Mount the bucket
    echo "Mounting GCS bucket..."
    run_remote_command "/usr/local/bin/mount-gcs-downloads.sh"
    
    # Verify mount
    if run_remote_command "mountpoint -q '${MOUNT_POINT}'"; then
        echo "✓ GCS bucket successfully mounted to Downloads folder"
    else
        echo "✗ Failed to mount GCS bucket"
        exit 1
    fi
}

setup_auto_mount(){
    echo "=== Setting up Auto-mount on Boot ==="
    
    # Create systemd service for auto-mounting
    run_remote_command "sudo tee /etc/systemd/system/gcsfuse-downloads.service > /dev/null << 'EOF'
[Unit]
Description=Mount GCS bucket to Downloads folder
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mount-gcs-downloads.sh
ExecStop=/usr/local/bin/unmount-gcs-downloads.sh
User=root

[Install]
WantedBy=multi-user.target
EOF"
    
    # Enable the service
    run_remote_command "sudo systemctl daemon-reload"
    run_remote_command "sudo systemctl enable gcsfuse-downloads.service"
    
    echo "✓ Auto-mount service configured"
}

create_desktop_shortcut(){
    echo "=== Creating Desktop Shortcut ==="
    
    # Create desktop shortcut for Downloads folder
    run_remote_command "sudo -u ubuntu mkdir -p /home/ubuntu/Desktop"
    run_remote_command "sudo -u ubuntu tee /home/ubuntu/Desktop/Downloads.desktop > /dev/null << 'EOF'
[Desktop Entry]
Version=1.0
Type=Link
Name=Downloads (Cloud Storage)
Comment=Downloads folder synced to Google Cloud Storage
URL=file://${DOWNLOADS_PATH}
Icon=folder-download
EOF"
    
    run_remote_command "sudo -u ubuntu chmod +x /home/ubuntu/Desktop/Downloads.desktop"
    
    echo "✓ Desktop shortcut created"
}

test_gcs_mount(){
    echo "=== Testing GCS Mount ==="
    
    local vm_ip=$(get_vm_ip)
    echo "Testing file operations on mounted GCS bucket..."
    
    # Test write operation
    echo "Testing write operation..."
    if run_remote_command "sudo -u ubuntu echo 'GCS Downloads Test File' > '${MOUNT_POINT}/test-file.txt'"; then
        echo "✓ Write test successful"
    else
        echo "✗ Write test failed"
    fi
    
    # Test read operation
    echo "Testing read operation..."
    local content=$(run_remote_command "sudo -u ubuntu cat '${MOUNT_POINT}/test-file.txt' 2>/dev/null")
    if [[ "${content}" == "GCS Downloads Test File" ]]; then
        echo "✓ Read test successful"
    else
        echo "✗ Read test failed"
    fi
    
    # Test from GCS side
    echo "Verifying file appears in GCS bucket..."
    sleep 2  # Allow time for sync
    if gsutil ls gs://${GCS_BUCKET_NAME}/test-file.txt >/dev/null 2>&1; then
        echo "✓ File visible in GCS bucket"
    else
        echo "⚠ File not yet visible in GCS bucket (may need time to sync)"
    fi
    
    # Clean up test file
    run_remote_command "sudo -u ubuntu rm -f '${MOUNT_POINT}/test-file.txt'" 2>/dev/null || true
    
    echo "✓ GCS mount testing complete"
}

print_instructions(){
    local vm_ip=$(get_vm_ip)
    
    cat <<EOF

=================================================================
GCS DOWNLOADS FOLDER SETUP COMPLETE
=================================================================

Configuration:
  Project: ${GCE_PROJECT_NAME}
  VM: ${GCE_VM_NAME} (${vm_ip})
  GCS Bucket: gs://${GCS_BUCKET_NAME}
  Downloads Path: ${DOWNLOADS_PATH}

Features Configured:
✓ Google Cloud Storage bucket created
✓ gcsfuse installed and configured
✓ Downloads folder mounted to GCS bucket
✓ Auto-mount on boot enabled
✓ Desktop shortcut created
✓ Proper permissions set

How to Use:
1. Connect to your VM via remote desktop
2. Save/download files to the Downloads folder
3. Files automatically appear in GCS bucket: gs://${GCS_BUCKET_NAME}
4. Access files from anywhere using GCS

Useful Commands:
  # Check mount status
  mountpoint ${DOWNLOADS_PATH}
  
  # View mount logs
  tail -f /var/log/gcsfuse-downloads.log
  
  # Manual mount/unmount
  /usr/local/bin/mount-gcs-downloads.sh
  /usr/local/bin/unmount-gcs-downloads.sh
  
  # List files in GCS bucket
  gsutil ls gs://${GCS_BUCKET_NAME}
  
  # Download files from GCS
  gsutil cp gs://${GCS_BUCKET_NAME}/filename.ext ./

Browser Access:
  View files: https://console.cloud.google.com/storage/browser/${GCS_BUCKET_NAME}

=================================================================
EOF
}

#####
##### Main execution
#####

main(){
    echo "Starting GCS Downloads Folder Setup..."
    echo "Project: ${GCE_PROJECT_NAME}"
    echo "Bucket: gs://${GCS_BUCKET_NAME}"
    echo "Downloads Path: ${DOWNLOADS_PATH}"
    echo ""
    
    set_gcloud_project
    find_vm_instance
    create_gcs_bucket
    install_gcsfuse
    setup_downloads_folder
    mount_gcs_bucket
    setup_auto_mount
    create_desktop_shortcut
    test_gcs_mount
    
    print_instructions
    
    echo "GCS Downloads setup complete!"
}

main