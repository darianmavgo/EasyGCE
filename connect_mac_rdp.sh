#!/bin/bash

#####
##### macOS Remote Desktop Connection Script for EasyGCE
#####

## Set defaults
GCE_PROJECT_NAME=mavgollc
GCE_VM_NAME=
GCE_VM_ZONE=us-east1-c
RDP_USERNAME="ubuntu"
RDP_PASSWORD="ubuntu123"
CONNECTION_TYPE="vnc"

usage(){
  cat <<-EOF

Usage: $0 -p <gce_project_name> [OPTIONS]

Required:
  -p <project_name>     GCE project name

Optional:
  -n <vm_name>          VM instance name (auto-detect if not specified)
  -z <zone>             GCE zone (default: us-east1-c)
  -u <username>         RDP username (default: ubuntu)
  -w <password>         RDP password (default: ubuntu123)
  -t <type>             Connection type: rdp, vnc, web (default: vnc)
  -h                    Show this help

Examples:
  $0 -p my-project
  $0 -p my-project -n my-vm-name -t rdp
  $0 -p my-project -z us-west1-a -t web

Connection Types:
  vnc  - Use built-in Screen Sharing (VNC client) [DEFAULT]
  rdp  - Use Microsoft Remote Desktop (requires app from App Store)
  web  - Open web browser to web-based VNC
EOF
}

while getopts "p:n:z:u:w:t:h" opt; do
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
        u)
            RDP_USERNAME=${OPTARG}
            ;;
        w)
            RDP_PASSWORD=${OPTARG}
            ;;
        t)
            CONNECTION_TYPE=${OPTARG}
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

# Validate connection type
if [[ ! ${CONNECTION_TYPE} =~ ^(rdp|vnc|web)$ ]]; then
    echo -e "\n\tERROR: Invalid connection type. Must be rdp, vnc, or web"
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
            echo "Please specify VM name with -n option or ensure VM is running"
            exit 1
        fi
        
        # Take the first match
        GCE_VM_NAME=$(echo "${vm_list}" | head -1 | cut -d$'\t' -f1)
        GCE_VM_ZONE=$(echo "${vm_list}" | head -1 | cut -d$'\t' -f2)
        
        echo "Found VM: ${GCE_VM_NAME} in zone: ${GCE_VM_ZONE}"
    fi
}

get_vm_ip(){
    local vm_ip=$(gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="get(networkInterfaces[0].accessConfigs[0].natIP)")
    
    if [[ -z ${vm_ip} ]]; then
        echo "ERROR: Could not retrieve IP address for VM ${GCE_VM_NAME}"
        exit 1
    fi
    
    echo "${vm_ip}"
}

check_vm_status(){
    local status=$(gcloud compute instances describe ${GCE_VM_NAME} --zone=${GCE_VM_ZONE} --format="get(status)")
    
    if [[ ${status} != "RUNNING" ]]; then
        echo "WARNING: VM ${GCE_VM_NAME} is not running (status: ${status})"
        echo "Starting VM..."
        gcloud compute instances start ${GCE_VM_NAME} --zone=${GCE_VM_ZONE}
        
        echo "Waiting for VM to start..."
        sleep 15
    fi
}

check_connection_requirements(){
    if [[ ${CONNECTION_TYPE} == "rdp" ]]; then
        # Check if Microsoft Remote Desktop is installed
        if [[ ! -d "/Applications/Microsoft Remote Desktop.app" ]]; then
            echo "ERROR: Microsoft Remote Desktop is not installed"
            echo ""
            echo "Please install Microsoft Remote Desktop from the Mac App Store:"
            echo "https://apps.apple.com/us/app/microsoft-remote-desktop/id1295203466"
            echo ""
            echo "Alternative: Use VNC connection (default) or web VNC:"
            echo "  ${0} -p ${GCE_PROJECT_NAME} -t vnc"
            echo "  ${0} -p ${GCE_PROJECT_NAME} -t web"
            exit 1
        fi
    elif [[ ${CONNECTION_TYPE} == "vnc" ]]; then
        echo "Using built-in macOS Screen Sharing for VNC connection"
        echo "This uses the TightVNC server configured with XFCE desktop"
    elif [[ ${CONNECTION_TYPE} == "web" ]]; then
        echo "Using web-based VNC via noVNC interface"
        echo "This will open your default browser to connect"
    fi
}

create_rdp_file(){
    local vm_ip=$1
    local rdp_file="/tmp/easygce_connection.rdp"
    
    cat > ${rdp_file} <<EOF
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
winposstr:s:0,3,0,0,800,600
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:0
allow font smoothing:i:0
allow desktop composition:i:0
disable full window drag:i:1
disable menu anims:i:1
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
full address:s:${vm_ip}:3389
audiomode:i:0
redirectprinters:i:1
redirectcomports:i:0
redirectsmartcards:i:1
redirectclipboard:i:1
redirectposdevices:i:0
autoreconnection enabled:i:1
authentication level:i:2
prompt for credentials:i:0
negotiate security layer:i:1
remoteapplicationmode:i:0
alternate shell:s:
shell working directory:s:
gatewayhostname:s:
gatewayusagemethod:i:4
gatewaycredentialssource:i:4
gatewayprofileusagemethod:i:0
promptcredentialonce:i:0
gatewaybrokeringtype:i:0
use redirection server name:i:0
rdgiskdcproxy:i:0
kdcproxyname:s:
username:s:${RDP_USERNAME}
EOF
    
    echo "${rdp_file}"
}

connect_rdp(){
    local vm_ip=$1
    echo "Connecting to ${vm_ip}:3389 via RDP..."
    
    local rdp_file=$(create_rdp_file ${vm_ip})
    
    echo ""
    echo "Opening Microsoft Remote Desktop..."
    echo "Username: ${RDP_USERNAME}"
    echo "Password: ${RDP_PASSWORD}"
    echo ""
    
    open -a "Microsoft Remote Desktop" "${rdp_file}"
    
    # Clean up RDP file after a delay
    (sleep 10 && rm -f "${rdp_file}") &
}

connect_vnc(){
    local vm_ip=$1
    echo "Connecting to ${vm_ip}:5901 via VNC..."
    
    echo ""
    echo "Opening Screen Sharing (VNC)..."
    echo "Password: ${RDP_PASSWORD}"
    echo ""
    echo "VNC Connection Details:"
    echo "  Server: ${vm_ip}:5901"
    echo "  Display: XFCE Desktop Environment"
    echo "  Resolution: 1024x768 (configurable)"
    echo ""
    
    # Use Screen Sharing app (built-in VNC client)
    # The vnc:// URL will prompt for password automatically
    open "vnc://${vm_ip}:5901"
    
    # Also provide alternative connection methods
    echo "Alternative VNC clients:"
    echo "  - Finder -> Go -> Connect to Server -> vnc://${vm_ip}:5901"
    echo "  - RealVNC Viewer, TigerVNC, or other VNC clients"
}

connect_web(){
    local vm_ip=$1
    echo "Opening web-based VNC at http://${vm_ip}:6901"
    
    echo ""
    echo "Opening web browser..."
    echo "Password: ${RDP_PASSWORD}"
    echo ""
    
    open "http://${vm_ip}:6901"
}

test_connection(){
    local vm_ip=$1
    local port
    
    case ${CONNECTION_TYPE} in
        rdp) port=3389 ;;
        vnc) port=5901 ;;
        web) port=6901 ;;
    esac
    
    echo "Testing connection to ${vm_ip}:${port}..."
    
    if nc -z -w5 ${vm_ip} ${port} 2>/dev/null; then
        echo "✓ Port ${port} is accessible"
        return 0
    else
        echo "✗ Port ${port} is not accessible"
        echo ""
        echo "This could mean:"
        echo "1. The remote desktop services are not yet installed/running"
        echo "2. Firewall rules are not configured"
        echo "3. VM is still starting up"
        echo ""
        echo "Try running the desktop setup scripts on the VM:"
        echo "  ssh -i ~/.ssh/easygce_key $(whoami)@${vm_ip}"
        echo "  sudo /tmp/scripts/21_install_desktop.sh"
        echo "  sudo /tmp/scripts/23_install_remote_desktops.sh"
        echo ""
        return 1
    fi
}

print_connection_info(){
    local vm_ip=$1
    
    cat <<EOF

=================================================================
EasyGCE Remote Desktop Connection
=================================================================

VM Details:
  Name: ${GCE_VM_NAME}
  Zone: ${GCE_VM_ZONE}
  IP: ${vm_ip}
  Connection Type: ${CONNECTION_TYPE}

Credentials:
  Username: ${RDP_USERNAME}
  Password: ${RDP_PASSWORD}

Manual Connection Info:
  RDP: ${vm_ip}:3389
  VNC: ${vm_ip}:5901  
  Web: http://${vm_ip}:6901

=================================================================
EOF
}

#####
##### Main execution
#####

main(){
    echo "Starting EasyGCE remote desktop connection..."
    
    set_gcloud_project
    find_vm_instance
    check_vm_status
    check_connection_requirements
    
    local vm_ip=$(get_vm_ip)
    print_connection_info ${vm_ip}
    
    if test_connection ${vm_ip}; then
        case ${CONNECTION_TYPE} in
            rdp)
                connect_rdp ${vm_ip}
                ;;
            vnc)
                connect_vnc ${vm_ip}
                ;;
            web)
                connect_web ${vm_ip}
                ;;
        esac
    else
        echo "Connection test failed. Please check VM setup."
        exit 1
    fi
    
    echo "Connection initiated!"
}

main