#!/bin/bash

#####
##### Google Cloud Engine Service Account and VM Setup Script
#####

## Set defaults
GCE_PROJECT_NAME=mavgollc
GCE_SERVICE_ACCOUNT_NAME="easygce-service-account"
GCE_SERVICE_ACCOUNT_DISPLAY_NAME="EasyGCE Service Account"
GCE_SERVICE_ACCOUNT_DESCRIPTION="Service account for EasyGCE VM operations"
GCE_VM_NAME=
GCE_VM_ZONE=us-east1-c
GCE_MACHINE_TYPE=n1-standard-2
GCE_VM_IMAGE_PROJECT=ubuntu-os-cloud
GCE_VM_IMAGE=ubuntu-2004-focal-v20231101
GCE_BOOT_DISK_SIZE=30GB
GCE_BOOT_DISK_TYPE=pd-ssd
GCE_BOOT_DISK_AUTO_DELETE=--no-boot-disk-auto-delete
GCE_OPEN_INBOUND_PORTS='22 80 443 3389 5901 6901'
SSH_KEY_PATH="$HOME/.ssh/easygce_key"

usage(){
  cat <<-EOF

Usage: $0 -p <gce_project_name> [OPTIONS]

Required:
  -p <project_name>     GCE project name

Optional:
  -s <service_account>  Service account name (default: easygce-service-account)
  -n <vm_name>          VM instance name (default: project_name-timestamp)
  -z <zone>             GCE zone (default: us-east1-c)
  -m <machine_type>     Machine type (default: n1-standard-2)
  -k <ssh_key_path>     SSH key path (default: ~/.ssh/easygce_key)
  -b                    Auto-delete boot disk when VM is deleted
  -h                    Show this help

Examples:
  $0 -p my-project
  $0 -p my-project -n my-vm -z us-west1-a -m n1-standard-4
EOF
}

while getopts "p:s:n:z:m:k:bh" opt; do
    case "${opt}" in
        b)
            GCE_BOOT_DISK_AUTO_DELETE=
            ;;
        p)
            GCE_PROJECT_NAME=${OPTARG}
            ;;
        s)
            GCE_SERVICE_ACCOUNT_NAME=${OPTARG}
            ;;
        n)
            GCE_VM_NAME=${OPTARG}
            ;;
        z)
            GCE_VM_ZONE=${OPTARG}
            ;;
        m)
            GCE_MACHINE_TYPE=${OPTARG}
            ;;
        k)
            SSH_KEY_PATH=${OPTARG}
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

if [[ -z ${GCE_VM_NAME} ]]; then
    GCE_VM_NAME=${GCE_PROJECT_NAME}-easygce-$(date +%s)
fi

#####
##### Functions
#####

generate_ssh_key(){
    echo "Generating SSH key pair..."
    if [[ ! -f ${SSH_KEY_PATH} ]]; then
        ssh-keygen -t rsa -b 4096 -f ${SSH_KEY_PATH} -N "" -C "easygce-$(whoami)"
        echo "SSH key generated at: ${SSH_KEY_PATH}"
    else
        echo "SSH key already exists at: ${SSH_KEY_PATH}"
    fi
}

set_gcloud_project(){
    echo "Setting gcloud project to: ${GCE_PROJECT_NAME}"
    gcloud config set project ${GCE_PROJECT_NAME}
}

create_service_account(){
    echo "Creating service account: ${GCE_SERVICE_ACCOUNT_NAME}"
    
    # Check if service account already exists
    if gcloud iam service-accounts describe ${GCE_SERVICE_ACCOUNT_NAME}@${GCE_PROJECT_NAME}.iam.gserviceaccount.com &>/dev/null; then
        echo "Service account already exists: ${GCE_SERVICE_ACCOUNT_NAME}"
    else
        # Create service account
        gcloud iam service-accounts create ${GCE_SERVICE_ACCOUNT_NAME} \
            --display-name="${GCE_SERVICE_ACCOUNT_DISPLAY_NAME}" \
            --description="${GCE_SERVICE_ACCOUNT_DESCRIPTION}"
    fi
    
    # Assign necessary roles
    echo "Assigning roles to service account..."
    gcloud projects add-iam-policy-binding ${GCE_PROJECT_NAME} \
        --member="serviceAccount:${GCE_SERVICE_ACCOUNT_NAME}@${GCE_PROJECT_NAME}.iam.gserviceaccount.com" \
        --role="roles/compute.instanceAdmin"
    
    gcloud projects add-iam-policy-binding ${GCE_PROJECT_NAME} \
        --member="serviceAccount:${GCE_SERVICE_ACCOUNT_NAME}@${GCE_PROJECT_NAME}.iam.gserviceaccount.com" \
        --role="roles/compute.securityAdmin"
}

create_firewall_rules(){
    echo "Creating firewall rules..."
    open_ports=$(gcloud compute firewall-rules list --format="table(allowed[].ports, direction, sourceRanges)" | grep 0.0.0.0 | grep -Eo "[0-9]{2,5}" | uniq)
    
    for port in ${GCE_OPEN_INBOUND_PORTS}; do
        if [[ ! $(echo $open_ports | grep $port) ]]; then
            echo "Creating firewall rule for port: ${port}"
            gcloud compute firewall-rules create easygce-inbound-tcp-${port} \
                --action allow \
                --rules tcp:${port} \
                --direction INGRESS \
                --priority 1000 \
                --source-ranges 0.0.0.0/0
        else
            echo "Firewall rule already exists for port: ${port}"
        fi
    done
}

create_startup_script(){
    echo "Creating VM startup script..."
    cat > /tmp/easygce_startup.sh <<'EOF'
#!/bin/bash
# Update system
apt-get update && apt-get -y upgrade

# Install essential packages
apt-get -y install git curl wget unzip

# Create easygce directory
mkdir -p /opt/easygce
cd /opt/easygce

# Clone the repository (will be done via SSH later)
echo "VM startup complete. Ready for EasyGCE installation."
EOF
    chmod +x /tmp/easygce_startup.sh
}

create_vm_instance(){
    echo "Creating VM instance: ${GCE_VM_NAME}"
    
    # Check if VM already exists
    if gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} &>/dev/null; then
        echo "VM instance already exists: ${GCE_VM_NAME}"
        return
    fi
    
    # Create the instance
    gcloud compute instances create ${GCE_VM_NAME} \
        ${GCE_BOOT_DISK_AUTO_DELETE} \
        --boot-disk-size=${GCE_BOOT_DISK_SIZE} \
        --boot-disk-type=${GCE_BOOT_DISK_TYPE} \
        --image-project=${GCE_VM_IMAGE_PROJECT} \
        --image=${GCE_VM_IMAGE} \
        --machine-type=${GCE_MACHINE_TYPE} \
        --zone=${GCE_VM_ZONE} \
        --service-account=${GCE_SERVICE_ACCOUNT_NAME}@${GCE_PROJECT_NAME}.iam.gserviceaccount.com \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --metadata-from-file startup-script=/tmp/easygce_startup.sh \
        --metadata ssh-keys="$(whoami):$(cat ${SSH_KEY_PATH}.pub)"
}

wait_for_vm(){
    echo "Waiting for VM to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="get(status)" | grep -q "RUNNING"; then
            echo "VM is running. Waiting for SSH to be ready..."
            sleep 10
            
            # Test SSH connection
            if ssh -i ${SSH_KEY_PATH} -o ConnectTimeout=10 -o StrictHostKeyChecking=no $(whoami)@$(get_vm_ip) "echo 'SSH connection successful'" &>/dev/null; then
                echo "VM is ready for SSH connections!"
                return 0
            fi
        fi
        
        echo "Attempt $attempt/$max_attempts: VM not ready yet..."
        sleep 10
        ((attempt++))
    done
    
    echo "ERROR: VM failed to become ready within expected time"
    return 1
}

get_vm_ip(){
    gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
}

setup_vm_scripts(){
    local vm_ip=$(get_vm_ip)
    echo "Setting up scripts on VM at IP: ${vm_ip}"
    
    # Copy the entire scripts directory to the VM
    echo "Copying scripts to VM..."
    scp -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -r ./scripts $(whoami)@${vm_ip}:/tmp/
    
    # Copy the main deployment script
    scp -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no ./gce_server_deploy.sh $(whoami)@${vm_ip}:/tmp/
    
    # Make scripts executable
    ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no $(whoami)@${vm_ip} "sudo chmod +x /tmp/scripts/*.sh /tmp/gce_server_deploy.sh"
    
    echo "Scripts copied successfully!"
}

print_connection_info(){
    local vm_ip=$(get_vm_ip)
    
    cat <<EOF

=================================================================
EasyGCE VM Setup Complete!
=================================================================

VM Details:
  Name: ${GCE_VM_NAME}
  Zone: ${GCE_VM_ZONE}
  IP: ${vm_ip}
  Service Account: ${GCE_SERVICE_ACCOUNT_NAME}@${GCE_PROJECT_NAME}.iam.gserviceaccount.com

SSH Connection:
  ssh -i ${SSH_KEY_PATH} $(whoami)@${vm_ip}

To install desktop environment and remote desktop servers:
  ssh -i ${SSH_KEY_PATH} $(whoami)@${vm_ip}
  sudo /tmp/scripts/21_install_desktop.sh
  sudo /tmp/scripts/23_install_remote_desktops.sh

Or run the full EasyGCE setup:
  sudo /tmp/gce_server_deploy.sh -p ${GCE_PROJECT_NAME}

Remote Desktop Access (after running setup):
  RDP: ${vm_ip}:3389 (username: ubuntu, password: ubuntu123)
  VNC: ${vm_ip}:5901 (password: ubuntu123)
  Web VNC: http://${vm_ip}:6901 (password: ubuntu123)

=================================================================
EOF
}

#####
##### Main execution
#####

main(){
    echo "Starting EasyGCE setup with service account..."
    
    generate_ssh_key
    set_gcloud_project
    create_service_account
    create_firewall_rules
    create_startup_script
    create_vm_instance
    
    if wait_for_vm; then
        setup_vm_scripts
        print_connection_info
    else
        echo "ERROR: Failed to set up VM properly"
        exit 1
    fi
    
    # Clean up temporary files
    rm -f /tmp/easygce_startup.sh
    
    echo "Setup complete!"
}

main