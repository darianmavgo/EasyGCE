#!/bin/bash

#####
##### EasyGCE Remote Desktop Diagnostic Script
#####

## Set defaults
GCE_PROJECT_NAME=mavgollc
GCE_VM_NAME=
GCE_VM_ZONE=us-east1-c
SSH_KEY_PATH="$HOME/.ssh/easygce_key"
SSH_USER=$(whoami)
AUTO_FIX=false

usage(){
  cat <<-EOF

Usage: $0 -p <gce_project_name> [OPTIONS]

Required:
  -p <project_name>     GCE project name

Optional:
  -n <vm_name>          VM instance name (auto-detect if not specified)
  -z <zone>             GCE zone (default: us-east1-c)
  -k <ssh_key_path>     SSH key path (default: ~/.ssh/easygce_key)
  -u <ssh_user>         SSH username (default: current user)
  -f                    Auto-fix detected issues
  -h                    Show this help

Examples:
  $0 -p mavgollc
  $0 -p mavgollc -n my-vm-name -f
  $0 -p mavgollc -u ubuntu -f

EOF
}

while getopts "p:n:z:k:u:fh" opt; do
    case "${opt}" in
        p)
            GCE_PROJECT_NAME=${OPTARG}
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
        f)
            AUTO_FIX=true
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
    gcloud config set project ${GCE_PROJECT_NAME}
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

check_ssh_connectivity(){
    local vm_ip=$(get_vm_ip)
    echo "=== SSH Connectivity Test ==="
    
    if [[ ! -f ${SSH_KEY_PATH} ]]; then
        echo "✗ SSH key not found at: ${SSH_KEY_PATH}"
        echo "  Run: ssh-keygen -t rsa -b 4096 -f ${SSH_KEY_PATH} -N ''"
        return 1
    fi
    
    echo "Testing SSH connection to ${SSH_USER}@${vm_ip}..."
    if ssh -i ${SSH_KEY_PATH} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${SSH_USER}@${vm_ip} "echo 'SSH connection successful'" &>/dev/null; then
        echo "✓ SSH connection working"
        return 0
    else
        echo "✗ SSH connection failed"
        echo "  Check: VM is running, SSH key is correct, firewall allows port 22"
        return 1
    fi
}

check_vm_status(){
    echo "=== VM Status Check ==="
    local status=$(gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="get(status)")
    local vm_ip=$(get_vm_ip)
    
    echo "VM Name: ${GCE_VM_NAME}"
    echo "VM Zone: ${GCE_VM_ZONE}"
    echo "VM IP: ${vm_ip}"
    echo "VM Status: ${status}"
    
    if [[ ${status} != "RUNNING" ]]; then
        echo "✗ VM is not running"
        if [[ ${AUTO_FIX} == true ]]; then
            echo "Auto-fixing: Starting VM..."
            gcloud compute instances start ${GCE_VM_NAME} --zone=${GCE_VM_ZONE}
            echo "Waiting for VM to start..."
            sleep 30
        fi
        return 1
    else
        echo "✓ VM is running"
        return 0
    fi
}

check_firewall_rules(){
    echo "=== Firewall Rules Check ==="
    local required_ports="22 3389 5901 6901"
    local missing_ports=""
    
    # Get all firewall rules and their allowed ports
    local all_rules=$(gcloud compute firewall-rules list --format="csv[no-heading](name,allowed[].ports.flatten())" 2>/dev/null)
    
    for port in ${required_ports}; do
        # Check if any rule allows this port (handle various port formats)
        local rule_exists=$(echo "${all_rules}" | grep -E "tcp:${port}(;|$)|^[^,]*,.*${port}" | head -1)
        if [[ -z ${rule_exists} ]]; then
            # Double-check by looking for the specific rule name pattern
            local specific_rule=$(gcloud compute firewall-rules list --filter="name~easygce-inbound-tcp-${port}" --format="value(name)" 2>/dev/null)
            if [[ -n ${specific_rule} ]]; then
                echo "✓ Firewall rule exists for port: ${port} (rule: ${specific_rule})"
            else
                missing_ports="${missing_ports} ${port}"
                echo "✗ Firewall rule missing for port: ${port}"
            fi
        else
            local rule_name=$(echo "${rule_exists}" | cut -d',' -f1)
            echo "✓ Firewall rule exists for port: ${port} (rule: ${rule_name})"
        fi
    done
    
    if [[ -n ${missing_ports} ]] && [[ ${AUTO_FIX} == true ]]; then
        echo "Auto-fixing: Creating missing firewall rules..."
        for port in ${missing_ports}; do
            echo "Creating firewall rule for port: ${port}"
            gcloud compute firewall-rules create easygce-inbound-tcp-${port} \
                --action allow \
                --rules tcp:${port} \
                --direction INGRESS \
                --priority 1000 \
                --source-ranges 0.0.0.0/0 || echo "  Rule creation failed (may already exist with different name)"
        done
    fi
}

run_remote_command(){
    local vm_ip=$(get_vm_ip)
    local command="$1"
    ssh -i ${SSH_KEY_PATH} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${SSH_USER}@${vm_ip} "${command}"
}

check_desktop_environment(){
    echo "=== Desktop Environment Check ==="
    
    if ! check_ssh_connectivity; then
        echo "Cannot check desktop environment - SSH connection failed"
        return 1
    fi
    
    echo "Checking if XFCE is installed..."
    if run_remote_command "dpkg -l | grep -q xfce4"; then
        echo "✓ XFCE desktop environment is installed"
    else
        echo "✗ XFCE desktop environment is NOT installed"
        if [[ ${AUTO_FIX} == true ]]; then
            echo "Auto-fixing: Installing XFCE desktop environment..."
            run_remote_command "sudo apt-get update && sudo apt-get -y install xfce4 xfce4-goodies"
        fi
    fi
}

check_remote_desktop_services(){
    echo "=== Remote Desktop Services Check ==="
    
    if ! check_ssh_connectivity; then
        echo "Cannot check services - SSH connection failed"
        return 1
    fi
    
    # Check XRDP
    echo "Checking XRDP service..."
    if run_remote_command "systemctl is-active --quiet xrdp"; then
        echo "✓ XRDP service is running"
    else
        echo "✗ XRDP service is NOT running"
        if run_remote_command "dpkg -l | grep -q xrdp"; then
            echo "  XRDP is installed but not running"
            if [[ ${AUTO_FIX} == true ]]; then
                echo "Auto-fixing: Starting XRDP service..."
                run_remote_command "sudo systemctl enable xrdp && sudo systemctl start xrdp"
            fi
        else
            echo "  XRDP is not installed"
            if [[ ${AUTO_FIX} == true ]]; then
                echo "Auto-fixing: Installing and starting XRDP..."
                run_remote_command "sudo apt-get -y install xrdp && sudo systemctl enable xrdp && sudo systemctl start xrdp"
            fi
        fi
    fi
    
    # Check TightVNC
    echo "Checking TightVNC service..."
    if run_remote_command "systemctl is-active --quiet tightvncserver"; then
        echo "✓ TightVNC service is running"
    else
        echo "✗ TightVNC service is NOT running"
        if run_remote_command "dpkg -l | grep -q tightvncserver"; then
            echo "  TightVNC is installed but not running"
            if [[ ${AUTO_FIX} == true ]]; then
                echo "Auto-fixing: Configuring and starting TightVNC..."
                configure_tightvnc
            fi
        else
            echo "  TightVNC is not installed"
            if [[ ${AUTO_FIX} == true ]]; then
                echo "Auto-fixing: Installing and configuring TightVNC..."
                run_remote_command "sudo apt-get -y install tightvncserver"
                configure_tightvnc
            fi
        fi
    fi
    
    # Check noVNC (web-based VNC)
    echo "Checking web-based VNC..."
    if run_remote_command "pgrep -f 'python.*6901' > /dev/null"; then
        echo "✓ Web-based VNC is running on port 6901"
    else
        echo "✗ Web-based VNC is NOT running on port 6901"
        echo "  This might be provided by the Docker container"
    fi
}

configure_tightvnc(){
    local vm_ip=$(get_vm_ip)
    echo "Configuring TightVNC for user ubuntu..."
    
    # Create ubuntu user if it doesn't exist
    run_remote_command "sudo useradd -m -s /bin/bash ubuntu 2>/dev/null || true"
    run_remote_command "echo 'ubuntu:ubuntu123' | sudo chpasswd"
    
    # Setup VNC for ubuntu user
    run_remote_command "sudo -u ubuntu mkdir -p /home/ubuntu/.vnc"
    run_remote_command "echo 'ubuntu123' | sudo -u ubuntu vncpasswd -f > /tmp/vncpasswd"
    run_remote_command "sudo mv /tmp/vncpasswd /home/ubuntu/.vnc/passwd"
    run_remote_command "sudo chown ubuntu:ubuntu /home/ubuntu/.vnc/passwd"
    run_remote_command "sudo chmod 600 /home/ubuntu/.vnc/passwd"
    
    # Create VNC startup script
    run_remote_command "sudo -u ubuntu tee /home/ubuntu/.vnc/xstartup > /dev/null << 'EOF'
#!/bin/bash
xrdb \$HOME/.Xresources
startxfce4 &
EOF"
    run_remote_command "sudo chmod +x /home/ubuntu/.vnc/xstartup"
    
    # Create systemd service
    run_remote_command "sudo tee /lib/systemd/system/tightvncserver.service > /dev/null << 'EOF'
[Unit]
Description=TightVNC remote desktop server
After=sshd.service

[Service]
Type=forking
ExecStart=/usr/bin/tightvncserver :1 -geometry 1024x768 -depth 24
ExecStop=/usr/bin/tightvncserver -kill :1
User=ubuntu
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF"
    
    # Enable and start the service
    run_remote_command "sudo systemctl daemon-reload"
    run_remote_command "sudo systemctl enable tightvncserver"
    run_remote_command "sudo systemctl start tightvncserver"
}

check_port_accessibility(){
    echo "=== Port Accessibility Test ==="
    local vm_ip=$(get_vm_ip)
    local ports="22 3389 5901 6901"
    
    for port in ${ports}; do
        echo -n "Testing port ${port}... "
        if nc -z -w5 ${vm_ip} ${port} 2>/dev/null; then
            echo "✓ Accessible"
        else
            echo "✗ Not accessible"
        fi
    done
}

check_user_accounts(){
    echo "=== User Accounts Check ==="
    
    if ! check_ssh_connectivity; then
        echo "Cannot check users - SSH connection failed"
        return 1
    fi
    
    echo "Checking for ubuntu user..."
    if run_remote_command "id ubuntu > /dev/null 2>&1"; then
        echo "✓ Ubuntu user exists"
    else
        echo "✗ Ubuntu user does NOT exist"
        if [[ ${AUTO_FIX} == true ]]; then
            echo "Auto-fixing: Creating ubuntu user..."
            run_remote_command "sudo useradd -m -s /bin/bash ubuntu"
            run_remote_command "echo 'ubuntu:ubuntu123' | sudo chpasswd"
            run_remote_command "sudo usermod -aG sudo ubuntu"
        fi
    fi
}

print_summary(){
    local vm_ip=$(get_vm_ip)
    
    cat <<EOF

=================================================================
DIAGNOSTIC SUMMARY
=================================================================

VM Details:
  Name: ${GCE_VM_NAME}
  Zone: ${GCE_VM_ZONE}
  IP: ${vm_ip}

Connection Commands:
  SSH: ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${vm_ip}
  VNC: open vnc://${vm_ip}:5901 (password: ubuntu123)
  RDP: ${vm_ip}:3389 (username: ubuntu, password: ubuntu123)
  Web: http://${vm_ip}:6901 (password: ubuntu123)

Manual Setup Commands (if auto-fix was not used):
  sudo apt-get update && sudo apt-get -y install xfce4 xfce4-goodies
  sudo apt-get -y install xrdp tightvncserver
  sudo systemctl enable xrdp && sudo systemctl start xrdp
  
To re-run diagnosis with auto-fix:
  ${0} -p ${GCE_PROJECT_NAME} -f

=================================================================
EOF
}

#####
##### Main execution
#####

main(){
    echo "Starting EasyGCE Remote Desktop Diagnosis..."
    echo "Auto-fix mode: ${AUTO_FIX}"
    echo ""
    
    set_gcloud_project
    find_vm_instance
    
    check_vm_status
    check_firewall_rules
    check_ssh_connectivity
    check_user_accounts
    check_desktop_environment
    check_remote_desktop_services
    check_port_accessibility
    
    print_summary
    
    echo "Diagnosis complete!"
}

main