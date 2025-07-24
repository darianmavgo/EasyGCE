#!/bin/bash

#####
##### GCP VPC Firewall Rules Checker for EasyGCE Remote Desktop
#####

## Set defaults
GCE_PROJECT_NAME=mavgollc
NETWORK_NAME="default"
AUTO_FIX=false
VERBOSE=false

usage(){
  cat <<-EOF

Usage: $0 -p <gce_project_name> [OPTIONS]

Required:
  -p <project_name>     GCE project name

Optional:
  -n <network_name>     VPC network name (default: default)
  -f                    Auto-fix missing firewall rules
  -v                    Verbose output
  -h                    Show this help

Examples:
  $0 -p mavgollc
  $0 -p mavgollc -f -v
  $0 -p mavgollc -n my-vpc-network

EOF
}

while getopts "p:n:fvh" opt; do
    case "${opt}" in
        p)
            GCE_PROJECT_NAME=${OPTARG}
            ;;
        n)
            NETWORK_NAME=${OPTARG}
            ;;
        f)
            AUTO_FIX=true
            ;;
        v)
            VERBOSE=true
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
##### Required Ports Configuration
#####

# Define required ports for EasyGCE remote desktop
declare -A REQUIRED_PORTS=(
    ["22"]="SSH - Secure Shell access"
    ["80"]="HTTP - Web server access"
    ["443"]="HTTPS - Secure web server access"
    ["3389"]="RDP - Remote Desktop Protocol (Windows/XRDP)"
    ["5900"]="VNC - Virtual Network Computing base port"
    ["5901"]="VNC - TightVNC Display :1 (macOS Screen Sharing)"
    ["5902"]="VNC - TightVNC Display :2 (optional)"
    ["6901"]="noVNC - Web-based VNC client"
)

# Common firewall rule patterns to look for
COMMON_RULE_PATTERNS=(
    "default-allow-ssh"
    "default-allow-http"
    "default-allow-https" 
    "default-allow-rdp"
    "allow-rdp"
    "easygce-inbound-tcp-"
    "inbound-tcp-"
)

#####
##### Functions
#####

set_gcloud_project(){
    echo "Setting gcloud project to: ${GCE_PROJECT_NAME}"
    gcloud config set project ${GCE_PROJECT_NAME} >/dev/null 2>&1
}

get_all_firewall_rules(){
    echo "Retrieving all firewall rules for network: ${NETWORK_NAME}"
    gcloud compute firewall-rules list \
        --filter="network:(${NETWORK_NAME})" \
        --format="table(
            name,
            direction,
            priority,
            sourceRanges.list():label=SRC_RANGES,
            allowed[].map().firewall_rule().list():label=ALLOW,
            targetTags.list():label=TARGET_TAGS,
            targetServiceAccounts.list():label=TARGET_SVC_ACCT
        )" 2>/dev/null
}

check_port_coverage(){
    echo "=== Port Coverage Analysis ==="
    echo "Checking required ports for EasyGCE remote desktop..."
    echo ""
    
    # Get firewall rules in CSV format for easier parsing
    local rules_csv=$(gcloud compute firewall-rules list \
        --filter="network:(${NETWORK_NAME}) AND direction=INGRESS" \
        --format="csv[no-heading](name,allowed[].ports.flatten(),sourceRanges.flatten(),targetTags.flatten(),disabled)" 2>/dev/null)
    
    local missing_ports=()
    local covered_ports=()
    
    for port in "${!REQUIRED_PORTS[@]}"; do
        local port_covered=false
        local covering_rules=()
        
        # Check if any rule covers this port
        while IFS=',' read -r rule_name allowed_ports source_ranges target_tags disabled; do
            # Skip disabled rules
            if [[ "${disabled}" == "True" ]]; then
                continue
            fi
            
            # Check if this rule allows the port
            if echo "${allowed_ports}" | grep -qE "(^|;)tcp:${port}(;|$|,)|(^|;)${port}(;|$|,)"; then
                port_covered=true
                covering_rules+=("${rule_name}")
                
                if [[ ${VERBOSE} == true ]]; then
                    echo "  Port ${port} covered by rule: ${rule_name}"
                    echo "    Source ranges: ${source_ranges}"
                    echo "    Target tags: ${target_tags:-"(all instances)"}"
                fi
            fi
        done <<< "${rules_csv}"
        
        if [[ ${port_covered} == true ]]; then
            covered_ports+=("${port}")
            echo "✓ Port ${port} (${REQUIRED_PORTS[$port]}) - COVERED"
            if [[ ${VERBOSE} == false ]]; then
                echo "    Rules: ${covering_rules[*]}"
            fi
        else
            missing_ports+=("${port}")
            echo "✗ Port ${port} (${REQUIRED_PORTS[$port]}) - MISSING"
        fi
        echo ""
    done
    
    echo "=== Summary ==="
    echo "Covered ports: ${#covered_ports[@]}/${#REQUIRED_PORTS[@]}"
    echo "Missing ports: ${#missing_ports[@]}"
    
    if [[ ${#missing_ports[@]} -gt 0 ]]; then
        echo ""
        echo "Missing ports that need firewall rules:"
        for port in "${missing_ports[@]}"; do
            echo "  - ${port} (${REQUIRED_PORTS[$port]})"
        done
        
        if [[ ${AUTO_FIX} == true ]]; then
            echo ""
            create_missing_rules "${missing_ports[@]}"
        fi
    fi
    
    return ${#missing_ports[@]}
}

create_missing_rules(){
    local missing_ports=("$@")
    echo "=== Auto-Fix: Creating Missing Firewall Rules ==="
    
    for port in "${missing_ports[@]}"; do
        local rule_name="easygce-allow-${port}"
        echo "Creating rule: ${rule_name} for port ${port}"
        
        local result=$(gcloud compute firewall-rules create "${rule_name}" \
            --network="${NETWORK_NAME}" \
            --action=allow \
            --rules="tcp:${port}" \
            --direction=ingress \
            --priority=1000 \
            --source-ranges=0.0.0.0/0 \
            --description="EasyGCE: ${REQUIRED_PORTS[$port]}" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            echo "✓ Successfully created rule for port ${port}"
        else
            echo "✗ Failed to create rule for port ${port}"
            echo "  Error: ${result}"
        fi
        echo ""
    done
}

check_default_rules(){
    echo "=== Default GCP Firewall Rules Check ==="
    
    local default_rules=("default-allow-ssh" "default-allow-http" "default-allow-https" "default-allow-internal" "default-allow-rdp")
    
    for rule in "${default_rules[@]}"; do
        local rule_info=$(gcloud compute firewall-rules describe "${rule}" --format="value(disabled,sourceRanges[],allowed[])" 2>/dev/null)
        
        if [[ -n ${rule_info} ]]; then
            local disabled=$(echo "${rule_info}" | head -1)
            if [[ "${disabled}" == "True" ]]; then
                echo "⚠ Rule ${rule} exists but is DISABLED"
            else
                echo "✓ Rule ${rule} exists and is enabled"
                if [[ ${VERBOSE} == true ]]; then
                    gcloud compute firewall-rules describe "${rule}" --format="table(sourceRanges[],allowed[])" 2>/dev/null
                fi
            fi
        else
            echo "✗ Default rule ${rule} is missing"
        fi
    done
    echo ""
}

check_network_tags(){
    echo "=== Network Tags Analysis ==="
    
    # Get all VMs in the project and their tags
    local vms_info=$(gcloud compute instances list \
        --format="csv[no-heading](name,zone,tags.list())" 2>/dev/null)
    
    if [[ -z ${vms_info} ]]; then
        echo "No VM instances found in project"
        return
    fi
    
    echo "VM instances and their network tags:"
    echo "${vms_info}" | while IFS=',' read -r vm_name zone tags; do
        echo "  VM: ${vm_name} (${zone})"
        if [[ -n ${tags} ]]; then
            echo "    Tags: ${tags}"
        else
            echo "    Tags: (none - uses default firewall rules)"
        fi
    done
    echo ""
    
    # Check for firewall rules that use specific tags
    local tagged_rules=$(gcloud compute firewall-rules list \
        --filter="network:(${NETWORK_NAME}) AND targetTags:*" \
        --format="csv[no-heading](name,targetTags.flatten())" 2>/dev/null)
    
    if [[ -n ${tagged_rules} ]]; then
        echo "Firewall rules with specific target tags:"
        echo "${tagged_rules}" | while IFS=',' read -r rule_name target_tags; do
            echo "  Rule: ${rule_name} -> Tags: ${target_tags}"
        done
    else
        echo "No firewall rules use specific network tags (all apply to all VMs)"
    fi
    echo ""
}

test_port_connectivity(){
    echo "=== Port Connectivity Test ==="
    echo "Testing if ports are actually accessible from external sources..."
    echo ""
    
    # Get a VM IP to test against
    local test_vm_ip=$(gcloud compute instances list \
        --filter="status:RUNNING" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
        --limit=1 2>/dev/null)
    
    if [[ -z ${test_vm_ip} ]]; then
        echo "No running VM instances found to test connectivity"
        return
    fi
    
    echo "Testing connectivity to VM IP: ${test_vm_ip}"
    echo ""
    
    for port in "${!REQUIRED_PORTS[@]}"; do
        echo -n "Testing port ${port} (${REQUIRED_PORTS[$port]})... "
        
        if command -v nc >/dev/null 2>&1; then
            if timeout 5 nc -z "${test_vm_ip}" "${port}" 2>/dev/null; then
                echo "✓ ACCESSIBLE"
            else
                echo "✗ NOT ACCESSIBLE"
            fi
        elif command -v telnet >/dev/null 2>&1; then
            if timeout 5 telnet "${test_vm_ip}" "${port}" 2>/dev/null | grep -q "Connected"; then
                echo "✓ ACCESSIBLE"
            else
                echo "✗ NOT ACCESSIBLE"
            fi
        else
            echo "? CANNOT TEST (nc/telnet not available)"
        fi
    done
    echo ""
}

print_recommendations(){
    echo "=== Recommendations ==="
    echo ""
    echo "For optimal EasyGCE remote desktop connectivity:"
    echo ""
    echo "1. Essential ports (must be open):"
    echo "   - Port 22 (SSH) - for server administration"
    echo "   - Port 5901 (VNC) - for macOS Screen Sharing"
    echo "   - Port 3389 (RDP) - for Windows Remote Desktop clients"
    echo ""
    echo "2. Optional ports (recommended):"
    echo "   - Port 6901 (noVNC) - for web-based remote desktop"
    echo "   - Port 80/443 (HTTP/HTTPS) - for web services"
    echo ""
    echo "3. Security considerations:"
    echo "   - Consider restricting source IP ranges for production use"
    echo "   - Use strong passwords or key-based authentication"
    echo "   - Consider using Cloud NAT + Internal IPs for enhanced security"
    echo ""
    echo "4. macOS Screen Sharing specific:"
    echo "   - Connect to: vnc://YOUR_VM_IP:5901"
    echo "   - Default password: ubuntu123"
    echo "   - Protocol: VNC (RFC 6143 compatible)"
    echo ""
}

print_summary(){
    echo "==================================================================="
    echo "GCP FIREWALL ANALYSIS SUMMARY"
    echo "==================================================================="
    echo "Project: ${GCE_PROJECT_NAME}"
    echo "Network: ${NETWORK_NAME}"
    echo "Auto-fix: ${AUTO_FIX}"
    echo ""
    echo "Use this information to ensure your EasyGCE remote desktop setup"
    echo "has proper network connectivity through GCP firewall rules."
    echo ""
    echo "To re-run with auto-fix: $0 -p ${GCE_PROJECT_NAME} -f"
    echo "To run with verbose output: $0 -p ${GCE_PROJECT_NAME} -v"
    echo "==================================================================="
}

#####
##### Main execution
#####

main(){
    echo "Starting GCP Firewall Rules Analysis for EasyGCE..."
    echo "Project: ${GCE_PROJECT_NAME}"
    echo "Network: ${NETWORK_NAME}"
    echo "Auto-fix: ${AUTO_FIX}"
    echo ""
    
    set_gcloud_project
    
    echo "=== Current Firewall Rules ==="
    get_all_firewall_rules
    echo ""
    
    check_default_rules
    check_port_coverage
    check_network_tags
    
    if [[ ${VERBOSE} == true ]]; then
        test_port_connectivity
    fi
    
    print_recommendations
    print_summary
    
    echo "Analysis complete!"
}

main