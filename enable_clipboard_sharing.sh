#!/bin/bash

#####
##### Enable Clipboard Sharing for EasyGCE Remote Desktop
#####

## Set defaults
GCE_PROJECT_NAME=mavgollc
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
  -n <vm_name>          VM instance name (auto-detect if not specified)
  -z <zone>             GCE zone (default: us-east1-c)
  -k <ssh_key_path>     SSH key path (default: ~/.ssh/easygce_key)
  -u <ssh_user>         SSH username (default: current user)
  -h                    Show this help

Examples:
  $0 -p mavgollc
  $0 -p mavgollc -n my-vm-name

EOF
}

while getopts "p:n:z:k:u:h" opt; do
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

install_clipboard_utilities(){
    echo "=== Installing Clipboard Utilities ==="
    
    echo "Installing clipboard and VNC utilities..."
    run_remote_command "sudo apt-get update"
    run_remote_command "sudo apt-get install -y xsel xclip autocutsel parcellite tigervnc-tools"
    
    echo "✓ Clipboard utilities installed"
}

configure_vnc_clipboard(){
    echo "=== Configuring VNC for Clipboard Sharing ==="
    
    # Stop the current VNC server
    echo "Stopping current VNC server..."
    run_remote_command "sudo systemctl stop tightvncserver" || true
    run_remote_command "sudo -u ubuntu vncserver -kill :1" || true
    
    # Update VNC startup script for clipboard sharing
    echo "Configuring VNC startup script for clipboard sharing..."
    run_remote_command "sudo -u ubuntu tee /home/ubuntu/.vnc/xstartup > /dev/null << 'EOF'
#!/bin/bash
# Load X resources
xrdb \$HOME/.Xresources

# Start clipboard synchronization daemon
autocutsel -fork
autocutsel -selection PRIMARY -fork

# Start parcellite clipboard manager
parcellite &

# Start XFCE desktop
startxfce4 &
EOF"
    
    run_remote_command "sudo chmod +x /home/ubuntu/.vnc/xstartup"
    
    # Update systemd service for better VNC configuration
    echo "Updating VNC systemd service..."
    run_remote_command "sudo tee /lib/systemd/system/tightvncserver.service > /dev/null << 'EOF'
[Unit]
Description=TightVNC remote desktop server
After=sshd.service

[Service]
Type=forking
ExecStartPre=/bin/bash -c 'sudo -u ubuntu /usr/bin/vncserver -kill :1 > /dev/null 2>&1 || :'
ExecStart=/usr/bin/sudo -u ubuntu /usr/bin/vncserver :1 -geometry 1280x1024 -depth 24 -dpi 96
ExecStop=/usr/bin/sudo -u ubuntu /usr/bin/vncserver -kill :1
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    
    # Reload and restart the service
    run_remote_command "sudo systemctl daemon-reload"
    run_remote_command "sudo systemctl enable tightvncserver"
    run_remote_command "sudo systemctl start tightvncserver"
    
    echo "✓ VNC configured for clipboard sharing"
}

configure_xrdp_clipboard(){
    echo "=== Configuring XRDP for Better Clipboard Support ==="
    
    # Install xrdp clipboard utilities
    run_remote_command "sudo apt-get install -y xrdp-pulseaudio-installer"
    
    # Configure XRDP for clipboard sharing
    run_remote_command "sudo tee -a /etc/xrdp/xrdp.ini > /dev/null << 'EOF'

[Globals]
clipboard=true
EOF"
    
    # Create XRDP session script with clipboard support
    run_remote_command "sudo -u ubuntu tee /home/ubuntu/.xsession > /dev/null << 'EOF'
#!/bin/bash
# Start clipboard utilities
autocutsel -fork
autocutsel -selection PRIMARY -fork
parcellite &

# Start XFCE
exec startxfce4
EOF"
    
    run_remote_command "sudo chmod +x /home/ubuntu/.xsession"
    
    # Restart XRDP service
    run_remote_command "sudo systemctl restart xrdp"
    
    echo "✓ XRDP configured for clipboard sharing"
}

install_tigervnc_server(){
    echo "=== Installing TigerVNC Server (Better Clipboard Support) ==="
    
    # Install TigerVNC server
    run_remote_command "sudo apt-get install -y tigervnc-standalone-server tigervnc-common"
    
    # Configure TigerVNC for ubuntu user
    run_remote_command "sudo -u ubuntu mkdir -p /home/ubuntu/.vnc"
    
    # Set VNC password
    run_remote_command "echo 'ubuntu123' | sudo -u ubuntu vncpasswd -f > /tmp/vncpasswd"
    run_remote_command "sudo mv /tmp/vncpasswd /home/ubuntu/.vnc/passwd"
    run_remote_command "sudo chown ubuntu:ubuntu /home/ubuntu/.vnc/passwd"
    run_remote_command "sudo chmod 600 /home/ubuntu/.vnc/passwd"
    
    # Create TigerVNC startup script
    run_remote_command "sudo -u ubuntu tee /home/ubuntu/.vnc/xstartup > /dev/null << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Load X resources
[ -r \$HOME/.Xresources ] && xrdb \$HOME/.Xresources

# Start clipboard synchronization
autocutsel -fork
autocutsel -selection PRIMARY -fork

# Start clipboard manager
parcellite &

# Start XFCE desktop environment
exec startxfce4
EOF"
    
    run_remote_command "sudo chmod +x /home/ubuntu/.vnc/xstartup"
    
    # Create TigerVNC systemd service
    run_remote_command "sudo tee /etc/systemd/system/tigervnc@.service > /dev/null << 'EOF'
[Unit]
Description=TigerVNC Server
After=syslog.target network.target

[Service]
Type=forking
User=ubuntu
ExecStartPre=/bin/bash -c '/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || :'
ExecStart=/usr/bin/vncserver :%i -geometry 1280x1024 -depth 24 -dpi 96 -localhost no
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    
    # Stop TightVNC and start TigerVNC
    run_remote_command "sudo systemctl stop tightvncserver" || true
    run_remote_command "sudo systemctl disable tightvncserver" || true
    run_remote_command "sudo systemctl enable tigervnc@1"
    run_remote_command "sudo systemctl start tigervnc@1"
    
    echo "✓ TigerVNC server installed and configured"
}

test_clipboard_functionality(){
    echo "=== Testing Clipboard Functionality ==="
    local vm_ip=$(get_vm_ip)
    
    echo "Testing clipboard utilities on the VM..."
    run_remote_command "echo 'Clipboard test from VM' | xclip -selection clipboard"
    local clipboard_content=$(run_remote_command "xclip -selection clipboard -o" 2>/dev/null)
    
    if [[ "${clipboard_content}" == "Clipboard test from VM" ]]; then
        echo "✓ VM clipboard utilities are working"
    else
        echo "✗ VM clipboard utilities may have issues"
    fi
    
    echo ""
    echo "Clipboard sharing should now work with:"
    echo "1. VNC connection to ${vm_ip}:5901"
    echo "2. RDP connection to ${vm_ip}:3389"
    echo ""
    echo "Note: For best clipboard support, try RDP connection:"
    echo "  ./connect_mac_rdp.sh -p ${GCE_PROJECT_NAME} -t rdp"
}

print_instructions(){
    local vm_ip=$(get_vm_ip)
    
    cat <<EOF

=================================================================
CLIPBOARD SHARING SETUP COMPLETE
=================================================================

Your VM now has enhanced clipboard sharing configured!

Connection Options (in order of clipboard support quality):

1. RDP (Best clipboard support):
   - Use: ./connect_mac_rdp.sh -p ${GCE_PROJECT_NAME} -t rdp
   - Requires: Microsoft Remote Desktop from App Store
   - Features: Full bidirectional clipboard, file transfer

2. VNC with TigerVNC (Good clipboard support):
   - Use: ./connect_mac_rdp.sh -p ${GCE_PROJECT_NAME} -t vnc
   - Connection: vnc://${vm_ip}:5901
   - Features: Basic clipboard sharing

3. Web VNC (Limited clipboard support):
   - Use: ./connect_mac_rdp.sh -p ${GCE_PROJECT_NAME} -t web
   - URL: http://${vm_ip}:6901
   - Features: Manual clipboard via web interface

Clipboard Utilities Installed:
- autocutsel: Automatic clipboard synchronization
- parcellite: Advanced clipboard manager
- xclip/xsel: Command-line clipboard tools

Testing Your Clipboard:
1. Connect via RDP or VNC
2. Copy text on your Mac
3. Paste in the remote desktop (Ctrl+V)
4. Copy text in the remote desktop
5. Paste on your Mac (Cmd+V)

=================================================================
EOF
}

#####
##### Main execution
#####

main(){
    echo "Starting EasyGCE Clipboard Sharing Setup..."
    echo ""
    
    set_gcloud_project
    find_vm_instance
    
    install_clipboard_utilities
    configure_vnc_clipboard
    configure_xrdp_clipboard
    install_tigervnc_server
    test_clipboard_functionality
    
    print_instructions
    
    echo "Clipboard sharing setup complete!"
}

main