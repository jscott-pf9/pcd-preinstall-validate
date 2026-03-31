#!/bin/bash

 # Platform9 Private Cloud Director (PCD) - Pre-installation validation script (Hypervisor host)
 # Supported OS: Ubuntu 22.04 LTS / Ubuntu 24.04 LTS
 #
 # Usage:
 #   ./saasvalidate.sh
 #   ./saasvalidate.sh --check-multipath
 #
 # Optional flags:
 #   -m, --check-multipath   Warn/fail output for presence of multipath-tools package (optional check)
 #   -h, --help              Show usage
 #
 # Exit codes:
 #   0  All mandatory checks passed
 #   1  One or more mandatory checks failed
 #   2  Invalid arguments

 check_multipath=0
 fail_count=0

 # Output helpers
 pass() {
     echo -e "$1 \033[0;32m✓\033[0m"
 }

 fail() {
     echo -e "$1 \033[0;31m✗\033[0m"
     fail_count=$((fail_count + 1))
 }

 warn() {
     echo -e "$1 \033[0;33m!\033[0m"
 }

 # Check: OS must be Ubuntu 22.04 or 24.04
 if [[ -r /etc/os-release ]]; then
     # shellcheck disable=SC1091
     . /etc/os-release
 else
     echo -e "Cannot read /etc/os-release; unable to detect OS \033[0;31m✗\033[0m"
     exit 1
 fi

 if [[ "${ID:-}" != "ubuntu" ]] || { [[ "${VERSION_ID:-}" != "22.04" ]] && [[ "${VERSION_ID:-}" != "24.04" ]]; }; then
     echo -e "Unsupported OS: ${PRETTY_NAME:-unknown}. This validation script supports Ubuntu 22.04 and 24.04 only \033[0;31m✗\033[0m"
     exit 1
 fi

 pass "OS: ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}"

 # CLI usage
 usage() {
     echo "Usage: $0 [--check-multipath|-m]"
 }

 # Parse CLI arguments
 while [[ $# -gt 0 ]]; do
     case "$1" in
         -m|--check-multipath)
             check_multipath=1
             shift
             ;;
         -h|--help)
             usage
             exit 0
             ;;
         *)
             echo "Unknown argument: $1"
             usage
             exit 2
             ;;
     esac
 done

 # Check: Platform9 PCD supports x86_64 hosts
 arch=$(uname -m)
 if [[ "$arch" == "x86_64" ]]; then
     pass "Architecture is $arch"
 else
     fail "Architecture is $arch (x86_64 required)"
 fi

 # Check: Minimum CPU requirement (8 vCPUs)
 vcpus=$(nproc 2>/dev/null)
 if [[ -n "$vcpus" ]] && [[ "$vcpus" -ge 8 ]]; then
     pass "CPU cores: $vcpus (>= 8 required)"
 else
     fail "CPU cores: ${vcpus:-unknown} (>= 8 required)"
 fi

 # Check: Minimum RAM requirement (16GB)
 mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
 if [[ -n "$mem_kb" ]]; then
     mem_gb=$(( (mem_kb + 1024*1024 - 1) / (1024*1024) ))
     if [[ "$mem_gb" -ge 16 ]]; then
         pass "RAM: ~${mem_gb}GB (>= 16GB required)"
     else
         fail "RAM: ~${mem_gb}GB (>= 16GB required)"
     fi
 else
     fail "RAM: unable to determine (>= 16GB required)"
 fi

 # Check: Hardware virtualization extension present (vmx for Intel, svm for AMD)
 if grep -qE '(^flags\s*:.*\s(vmx|svm)\s)' /proc/cpuinfo 2>/dev/null; then
     pass "Hardware virtualization extensions present (vmx/svm)"
 else
     fail "Hardware virtualization extensions not detected (vmx/svm)"
 fi

 # Check: CPU model must be supported by Platform9 PCD
 # Ref: https://docs.platform9.com/private-cloud-director/2025.10/virtualized-clusters/host/cpu-model/supported-cpu-models-list
 # Note: The supported CPU models list is expressed using QEMU/libvirt CPU model names.
 # Before libvirt/qemu is installed, we can't reliably map the host's marketing CPU name
 # to those model identifiers. This check therefore uses host hardware signals only and
 # emits warnings if the CPU looks unusual/too old.
 cpu_vendor_id=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
 cpu_model_name=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
 cpu_flags=$(awk -F': ' '/^flags/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)

 if [[ -n "$cpu_vendor_id" ]] || [[ -n "$cpu_model_name" ]]; then
     pass "CPU: ${cpu_vendor_id:-unknown} - ${cpu_model_name:-unknown}"
 else
     warn "Unable to read CPU vendor/model from /proc/cpuinfo"
 fi

 # Baseline ISA check (rough x86-64-v2 indicator): cx16 + sse4_2 + popcnt
 # If missing, the platform may be too old for modern virtualization stacks.
 if [[ -n "$cpu_flags" ]] && echo "$cpu_flags" | grep -qw cx16 && echo "$cpu_flags" | grep -qw sse4_2 && echo "$cpu_flags" | grep -qw popcnt; then
     pass "CPU instruction set baseline looks OK (cx16/sse4_2/popcnt present)"
 else
     warn "CPU instruction set baseline may be too old (missing one of: cx16, sse4_2, popcnt)"
 fi

 if [[ "$cpu_vendor_id" == "GenuineIntel" ]]; then
     if echo "${cpu_model_name:-}" | grep -qiE 'xeon|intel'; then
         pass "CPU vendor: Intel"
     else
         warn "CPU vendor: Intel (model name not recognized as typical server CPU)"
     fi
 elif [[ "$cpu_vendor_id" == "AuthenticAMD" ]]; then
     if echo "${cpu_model_name:-}" | grep -qiE 'epyc|opteron|amd'; then
         pass "CPU vendor: AMD"
     else
         warn "CPU vendor: AMD (model name not recognized as typical server CPU)"
     fi
 else
     warn "Unknown CPU vendor_id (${cpu_vendor_id:-unknown}); cannot assess compatibility against supported CPU models list"
 fi

 # Check: cloud-init must be disabled
 # If cloud-init is enabled it can overwrite network configuration and break static netplan.
 cloud_init_disabled=0
 if dpkg -s cloud-init >/dev/null 2>&1; then
     if [[ -f /etc/cloud/cloud-init.disabled ]]; then
         cloud_init_disabled=1
     elif [[ -r /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ]] && grep -qE '^[[:space:]]*config:[[:space:]]*disabled[[:space:]]*$' /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg; then
         cloud_init_disabled=1
     fi

     if [[ "$cloud_init_disabled" -eq 1 ]]; then
         pass "cloud-init is disabled"
     else
         fail "cloud-init is enabled (disable it to prevent network config changes)"
     fi
 else
     warn "cloud-init package not found; skipping cloud-init disable check"
 fi

 # Check: netplan must be statically configured (no DHCP)
 # This validates that dhcp4/dhcp6 are not enabled in /etc/netplan/*.yaml.
 netplan_files=(/etc/netplan/*.yaml /etc/netplan/*.yml)
 netplan_found=0
 netplan_dhcp_enabled=0
 netplan_has_addresses=0
 netplan_has_bonds=0
 netplan_bad_bond_mode=0
 netplan_good_bond_mode=0
 netplan_unknown_bond_mode=0

 for f in "${netplan_files[@]}"; do
     [[ -e "$f" ]] || continue
     netplan_found=1

     if grep -qiE '^[[:space:]]*dhcp4:[[:space:]]*(true|yes)[[:space:]]*$' "$f" || grep -qiE '^[[:space:]]*dhcp6:[[:space:]]*(true|yes)[[:space:]]*$' "$f"; then
         netplan_dhcp_enabled=1
     fi

     if grep -qE '^[[:space:]]*addresses:[[:space:]]*\[' "$f" || grep -qE '^[[:space:]]*addresses:[[:space:]]*$' "$f"; then
         netplan_has_addresses=1
     fi

     if grep -qE '^[[:space:]]*bonds:[[:space:]]*$' "$f"; then
         netplan_has_bonds=1
         if grep -qiE '^[[:space:]]*mode:[[:space:]]*balance-rr[[:space:]]*$' "$f"; then
             netplan_bad_bond_mode=1
         elif grep -qiE '^[[:space:]]*mode:[[:space:]]*(active-backup|802\.3ad|lacp)[[:space:]]*$' "$f"; then
             netplan_good_bond_mode=1
         else
             netplan_unknown_bond_mode=1
         fi
     fi
 done

 if [[ "$netplan_found" -eq 0 ]]; then
     fail "No netplan config found under /etc/netplan/*.yaml"
 else
     if [[ "$netplan_dhcp_enabled" -eq 1 ]]; then
         fail "Netplan is configured with DHCP (static configuration required)"
     else
         pass "Netplan DHCP is disabled"
     fi

     if [[ "$netplan_has_addresses" -eq 1 ]]; then
         pass "Netplan has static IP addresses configured"
     else
         warn "Netplan static addresses not detected (ensure static IPs are configured)"
     fi
 fi

 # Check: if netplan bonding is used, ensure mode is active-backup or 802.3ad/lacp (not balance-rr)
 if [[ "$netplan_has_bonds" -eq 1 ]]; then
     if [[ "$netplan_bad_bond_mode" -eq 1 ]]; then
         fail "Netplan bonding mode balance-rr detected (not supported; use active-backup or 802.3ad/lacp)"
     elif [[ "$netplan_good_bond_mode" -eq 1 ]]; then
         pass "Netplan bonding mode is supported (active-backup or 802.3ad/lacp)"
     elif [[ "$netplan_unknown_bond_mode" -eq 1 ]]; then
         warn "Netplan bonding detected but mode not found/recognized (ensure active-backup or 802.3ad/lacp)"
     fi
 fi

 san_present=0
 san_reasons=()

 if command -v multipath >/dev/null 2>&1; then
     mp_out=$(multipath -ll 2>/dev/null)
     if [[ -n "${mp_out:-}" ]] && ! echo "$mp_out" | grep -qiE '(^|[[:space:]])(no maps|no multipath)([[:space:]]|$)'; then
         san_present=1
         san_reasons+=("multipath maps detected")
     fi
 else
     if [[ -d /dev/mapper ]]; then
         while IFS= read -r dm_name; do
             [[ -n "$dm_name" ]] || continue
             if udevadm info --query=property --name="/dev/mapper/$dm_name" 2>/dev/null | grep -qE '^DM_UUID=mpath-'; then
                 san_present=1
                 san_reasons+=("multipath device detected (/dev/mapper/$dm_name)")
                 break
             fi
         done < <(ls -1 /dev/mapper 2>/dev/null | grep -v '^control$' || true)
     fi
 fi

 if command -v iscsiadm >/dev/null 2>&1; then
     iscsi_sessions=$(iscsiadm -m session 2>/dev/null || true)
     if [[ -n "${iscsi_sessions:-}" ]]; then
         san_present=1
         san_reasons+=("active iSCSI sessions detected")
     fi
 fi

 if [[ -d /sys/class/fc_host ]] && compgen -G "/sys/class/fc_host/host*" >/dev/null; then
     fc_luns=$(lsblk -dn -o TRAN 2>/dev/null | awk '$1=="fc" {print; exit}')
     if [[ -n "${fc_luns:-}" ]]; then
         san_present=1
         san_reasons+=("FC-attached LUNs appear to be visible")
     fi
 fi

 if [[ "$san_present" -eq 1 ]]; then
     fail "SAN-backed storage appears to be presented to this host (${san_reasons[*]})"
 else
     pass "No SAN-backed storage detected (iSCSI/FC/multipath)"
 fi

 # Check (recommended): Swap configured
 swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
 if [[ -n "$swap_kb" ]] && [[ "$swap_kb" -gt 0 ]]; then
     swap_gb=$(( (swap_kb + 1024*1024 - 1) / (1024*1024) ))
     pass "Swap configured: ~${swap_gb}GB"
 else
     warn "Swap not configured (recommended)"
 fi

 # Check (recommended): If lvm2 is installed, LVM device filters should be configured
 # Ref: https://docs.platform9.com/private-cloud-director/getting-started/pre-requisites/hypervisor-lvm-configuration
 if dpkg -s lvm2 >/dev/null 2>&1; then
     if [[ -r /etc/lvm/lvm.conf ]]; then
         lvm_filter_line=$(grep -E '^[[:space:]]*filter[[:space:]]*=' /etc/lvm/lvm.conf | head -n 1)
         lvm_global_filter_line=$(grep -E '^[[:space:]]*global_filter[[:space:]]*=' /etc/lvm/lvm.conf | head -n 1)

         if [[ -z "$lvm_filter_line" ]]; then
             warn "lvm2 detected but /etc/lvm/lvm.conf filter is not set (recommended to configure LVM device filters)"
         elif ! echo "$lvm_filter_line" | grep -qE '"a\|\^/dev/'; then
             warn "lvm2 detected but /etc/lvm/lvm.conf filter does not appear to include accept rules (a|^/dev/...)"
         fi

         if [[ -z "$lvm_global_filter_line" ]]; then
             warn "lvm2 detected but /etc/lvm/lvm.conf global_filter is not set (recommended to configure LVM device filters)"
         elif ! echo "$lvm_global_filter_line" | grep -qE '"a\|\^/dev/'; then
             warn "lvm2 detected but /etc/lvm/lvm.conf global_filter does not appear to include accept rules (a|^/dev/...)"
         fi
     else
         warn "lvm2 detected but /etc/lvm/lvm.conf is not readable; cannot validate LVM filter configuration"
     fi
 fi

 # Check: Outbound connectivity for required endpoints (curl HEAD)
 # Ref: https://docs.platform9.com/private-cloud-director/getting-started/pre-requisites
 # Array of URLs to check
 urls=(
     "https://pcdctl.s3.us-west-2.amazonaws.com/pcdctl-setup"
     "http://security.ubuntu.com/ubuntu"
     "http://us.archive.ubuntu.com/ubuntu"
     "http://ubuntu-cloud.archive.canonical.com/ubuntu"
     "http://nova.clouds.archive.ubuntu.com/ubuntu"
     "https://wiki.ubuntu.com/OpenStack/CloudArchive"
 )

 # Function to check URL accessibility
 check_url() {
     url="$1"
     if curl --output /dev/null --silent --head --fail "$url"; then
         echo -e "$url \033[0;32m✓\033[0m" # Green checkmark
     else
         echo -e "$url \033[0;31m✗\033[0m" # Red X
     fi
 }

# Total number of URLs to check
total_urls=${#urls[@]}

# Loop through URLs and check with a progress meter
count=0
for url in "${urls[@]}"; do
    count=$((count + 1))
    check_url "$url"
    
    # Progress Meter
    progress=$(( (count * 100) / total_urls ))
    echo -ne "Progress: [$progress%] ($count/$total_urls)\r"
done

# Check: Root filesystem free space (interpreted as available space on /)
root_size=$(df -h / | awk 'NR==2 {print $4}')
echo "Root file system size: $root_size"

# Check: Root filesystem free space >= 250GB
root_size_gb=$(df -BG / | awk 'NR==2 {print substr($4, 1, length($4)-1)}')
if [ "$root_size_gb" -ge 250 ]; then
    echo -e "Root file system size is \033[0;32m$root_size_gb GB\033[0m (≥ 250GB)"
else
    echo -e "Root file system size is \033[0;31m$root_size_gb GB\033[0m (< 250GB)"
fi

# Optional check: multipath-tools package installed
if [[ "$check_multipath" -eq 1 ]]; then
    if dpkg -s multipath-tools >/dev/null 2>&1; then
        echo -e "multipath-tools is \033[0;32minstalled\033[0m"
    else
        echo -e "multipath-tools is \033[0;31mNOT installed\033[0m"
    fi
else
    echo "Skipping multipath-tools check (enable with --check-multipath or -m)"
fi

# Exit non-zero if any mandatory checks failed
if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
