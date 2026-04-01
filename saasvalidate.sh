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
 generate_report=0
 report_format="text"
 report_file=""
 iscsi_discovery_portal=""
 iscsi_discovery_report=""

 # Report data storage
 declare -a report_data

 # Output helpers
 pass() {
    echo -e "\033[0;32m✓\033[0m $1"
    if [[ "$generate_report" -eq 1 ]]; then
        report_data+=("PASS|$1")
    fi
 }

 fail() {
    echo -e "\033[0;31m✗\033[0m $1"
    fail_count=$((fail_count + 1))
    if [[ "$generate_report" -eq 1 ]]; then
        report_data+=("FAIL|$1")
    fi
 }

 warn() {
    echo -e "\033[0;33m!\033[0m $1"
    if [[ "$generate_report" -eq 1 ]]; then
        report_data+=("WARN|$1")
    fi
 }

 # Check: OS must be Ubuntu 22.04 or 24.04
 if [[ -r /etc/os-release ]]; then
     # shellcheck disable=SC1091
     . /etc/os-release
 else
     fail "Cannot read /etc/os-release; unable to detect OS"
     exit 1
 fi

 if [[ "${ID:-}" != "ubuntu" ]] || { [[ "${VERSION_ID:-}" != "22.04" ]] && [[ "${VERSION_ID:-}" != "24.04" ]]; }; then
     fail "Unsupported OS: ${PRETTY_NAME:-unknown}. This validation script supports Ubuntu 22.04 and 24.04 only"
     exit 1
 fi

 pass "OS: ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}"

 # CLI usage
 usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -m, --check-multipath          Enable multipath-tools check"
    echo "  -r, --report [FILE]            Generate report (default: pcd-validation-report.md)"
    echo "  --report-format FORMAT         Report format: text, json, or both (default: text)"
    echo "  --iscsi-discovery IP[:PORT]    Optional: iSCSI sendtargets discovery test (warns on failure)"
    echo "  -h, --help                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Run validation only"
    echo "  $0 --report                           # Run and save Markdown report to pcd-validation-report.md"
    echo "  $0 --report myreport                  # Run and save Markdown report to myreport.md"
    echo "  $0 --report --report-format json      # Generate JSON report"
    echo "  $0 --report --report-format both      # Generate both Markdown and JSON reports"
    echo "  $0 --iscsi-discovery 10.0.0.50        # Run iSCSI discovery test against a portal"
 }

 # Parse CLI arguments
 while [[ $# -gt 0 ]]; do
     case "$1" in
         -m|--check-multipath)
             check_multipath=1
             shift
             ;;
         -r|--report)
             generate_report=1
             shift
             if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
                 report_file="$1"
                 shift
             fi
             ;;
         --report-format)
             shift
             if [[ $# -gt 0 ]]; then
                 report_format="$1"
                 shift
             else
                 echo "Error: --report-format requires an argument (text, json, or both)"
                 exit 2
             fi
             ;;
         --iscsi-discovery)
             shift
             if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
                 iscsi_discovery_portal="$1"
                 shift
             else
                 echo "Error: --iscsi-discovery requires an argument (IP[:PORT])"
                 exit 2
             fi
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

 # Set default report filename if not specified
 if [[ "$generate_report" -eq 1 ]] && [[ -z "$report_file" ]]; then
     report_file="pcd-validation-report"
 fi

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

 # Check (recommended): Swap configured
 swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
 if [[ -n "$swap_kb" ]] && [[ "$swap_kb" -gt 0 ]]; then
     swap_gb=$(( (swap_kb + 1024*1024 - 1) / (1024*1024) ))
     pass "Swap configured: ~${swap_gb}GB"
 else
     warn "Swap not configured (recommended)"
 fi

 # Check (recommended): Root filesystem free space >= 250GB
 root_size_gb=$(df -BG / | awk 'NR==2 {print substr($4, 1, length($4)-1)}')
 if [ "$root_size_gb" -ge 250 ]; then
     pass "Root file system size is $root_size_gb GB (≥ 250GB)"
 else
     warn "Root file system size is $root_size_gb GB (> 250GB recommended)"
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

 # Check (recommended): CPU governor should be set to performance
# DISABLED: Uncomment to re-enable this check
# cpu_governor_ok=0
# cpu_governor_count=0
# for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
#     [[ -r "$gov_file" ]] || continue
#     cpu_governor_count=$((cpu_governor_count + 1))
#     governor=$(cat "$gov_file" 2>/dev/null)
#     if [[ "$governor" != "performance" ]]; then
#         cpu_governor_ok=1
#         break
#     fi
# done
# 
# if [[ "$cpu_governor_count" -eq 0 ]]; then
#     warn "CPU frequency scaling not available or not readable"
# elif [[ "$cpu_governor_ok" -eq 1 ]]; then
#     warn "CPU governor is not set to 'performance' (current: $governor, recommended for consistent performance)"
# else
#     pass "CPU governor set to 'performance'"
# fi

 # Check (recommended): IOMMU/VT-d enabled for PCI passthrough
 if [[ -d /sys/kernel/iommu_groups ]] && [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
     iommu_group_count=$(ls -1 /sys/kernel/iommu_groups 2>/dev/null | wc -l)
     pass "IOMMU enabled ($iommu_group_count IOMMU groups detected)"
 elif grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline 2>/dev/null; then
     warn "IOMMU enabled in kernel parameters but no IOMMU groups detected (check BIOS settings)"
 else
     warn "IOMMU not detected (enable in BIOS and add intel_iommu=on or amd_iommu=on to kernel parameters for PCI passthrough)"
 fi

 # Check (recommended): Hugepages configuration
# DISABLED: Uncomment to re-enable this check
# hugepages_total=$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo 2>/dev/null)
# hugepages_size=$(awk '/^Hugepagesize:/ {print $2}' /proc/meminfo 2>/dev/null)
# if [[ -n "$hugepages_total" ]] && [[ "$hugepages_total" -gt 0 ]]; then
#     hugepages_mb=$((hugepages_total * hugepages_size / 1024))
#     pass "Hugepages configured: $hugepages_total pages x ${hugepages_size}kB (~${hugepages_mb}MB total)"
# else
#     warn "Hugepages not configured (recommended for VM performance)"
# fi

 # Check: Kernel version
 kernel_version=$(uname -r)
 if [[ -n "$kernel_version" ]]; then
     pass "Kernel version: $kernel_version"
 else
     warn "Unable to determine kernel version"
 fi

 # Check (recommended): System load average
 load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
 if [[ -n "$load_avg" ]] && [[ -n "$vcpus" ]]; then
     load_per_cpu=$(awk "BEGIN {printf \"%.2f\", $load_avg / $vcpus}")
     if awk "BEGIN {exit !($load_per_cpu > 2.0)}"; then
         warn "System load average is high: $load_avg (${load_per_cpu} per CPU)"
     else
         pass "System load average: $load_avg (${load_per_cpu} per CPU)"
     fi
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

 # Check: Time synchronization (NTP or systemd-timesyncd) must be configured and running
 time_sync_ok=0
 time_sync_service=""

 if systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null; then
     time_sync_ok=1
     time_sync_service="systemd-timesyncd"
 elif systemctl is-active --quiet ntp.service 2>/dev/null; then
     time_sync_ok=1
     time_sync_service="ntp"
 elif systemctl is-active --quiet ntpd.service 2>/dev/null; then
     time_sync_ok=1
     time_sync_service="ntpd"
 elif systemctl is-active --quiet chronyd.service 2>/dev/null; then
     time_sync_ok=1
     time_sync_service="chronyd"
 fi

 if [[ "$time_sync_ok" -eq 1 ]]; then
     pass "Time synchronization is active ($time_sync_service)"
 else
     fail "No active time synchronization service detected (systemd-timesyncd, ntp, ntpd, or chronyd required)"
 fi

 # Check (recommended): Network interfaces are up with link
 active_interfaces=$(ip -o link show | awk -F': ' '$3 !~ /LOOPBACK/ && $3 ~ /UP/ {print $2}' | wc -l)
 if [[ "$active_interfaces" -gt 0 ]]; then
     pass "Active network interfaces: $active_interfaces"
 else
     warn "No active network interfaces detected (excluding loopback)"
 fi

 # Check (recommended): At least one bonded network with >= 2 member interfaces
 bond_ok=0
 if compgen -G "/proc/net/bonding/*" >/dev/null; then
     for bond_file in /proc/net/bonding/*; do
         [[ -r "$bond_file" ]] || continue
         slave_count=$(grep -c '^Slave Interface:' "$bond_file" 2>/dev/null || true)
         if [[ "$slave_count" -ge 2 ]]; then
             bond_ok=1
             break
         fi
     done
 fi
 if [[ "$bond_ok" -eq 1 ]]; then
     pass "Bonded network detected with >= 2 interfaces"
 else
     warn "No bonded network detected with at least 2 interfaces (recommended)"
 fi

 # Check: DNS resolution working
 if command -v host >/dev/null 2>&1; then
     if host google.com >/dev/null 2>&1; then
         pass "DNS resolution is working"
     else
         fail "DNS resolution failed (unable to resolve google.com)"
     fi
 elif command -v nslookup >/dev/null 2>&1; then
     if nslookup google.com >/dev/null 2>&1; then
         pass "DNS resolution is working"
     else
         fail "DNS resolution failed (unable to resolve google.com)"
     fi
 else
     warn "DNS resolution tools not available (host or nslookup not found)"
 fi

 # Check (recommended): Firewall status
# DISABLED: Uncomment to re-enable this check
# if systemctl is-active --quiet ufw.service 2>/dev/null; then
#     warn "UFW firewall is active (may interfere with PCD networking)"
# elif command -v iptables >/dev/null 2>&1; then
#     iptables_rules=$(iptables -L -n 2>/dev/null | grep -c '^Chain')
#     if [[ "$iptables_rules" -gt 3 ]]; then
#         warn "iptables rules detected ($iptables_rules chains, may interfere with PCD networking)"
#     else
#         pass "No active firewall rules detected"
#     fi
# else
#     pass "No firewall detected"
# fi

 # Check: SSH service is running
 if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
     pass "SSH service is active"
 else
     fail "SSH service is not active (required for remote management)"
 fi

 # Check (recommended): SELinux/AppArmor status
# DISABLED: Uncomment to re-enable this check
# if command -v getenforce >/dev/null 2>&1; then
#     selinux_status=$(getenforce 2>/dev/null)
#     if [[ "$selinux_status" == "Disabled" ]] || [[ "$selinux_status" == "Permissive" ]]; then
#         pass "SELinux is $selinux_status"
#     else
#         warn "SELinux is $selinux_status (may cause issues with virtualization)"
#     fi
# elif systemctl is-active --quiet apparmor.service 2>/dev/null; then
#     warn "AppArmor is active (may cause issues with virtualization)"
# else
#     pass "No SELinux or AppArmor restrictions detected"
# fi

 # Check: Root filesystem type
 root_fstype=$(df -T / | awk 'NR==2 {print $2}')
 if [[ "$root_fstype" == "ext4" ]] || [[ "$root_fstype" == "xfs" ]]; then
     pass "Root filesystem type: $root_fstype"
 else
     warn "Root filesystem type is $root_fstype (ext4 or xfs recommended)"
 fi

 # Check (recommended): Disk I/O scheduler for root device
# DISABLED: Uncomment to re-enable this check
# root_device=$(df / | awk 'NR==2 {print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||')
# if [[ -n "$root_device" ]] && [[ -r "/sys/block/$root_device/queue/scheduler" ]]; then
#     scheduler=$(cat "/sys/block/$root_device/queue/scheduler" 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
#     if [[ -n "$scheduler" ]]; then
#         pass "I/O scheduler for $root_device: $scheduler"
#     else
#         warn "Unable to determine I/O scheduler for $root_device"
#     fi
# else
#     warn "Unable to check I/O scheduler (root device: $root_device)"
# fi

 # Check (recommended): /var disk space
 var_size_gb=$(df -BG /var 2>/dev/null | awk 'NR==2 {print substr($4, 1, length($4)-1)}')
 if [[ -n "$var_size_gb" ]] && [[ "$var_size_gb" -ge 50 ]]; then
     pass "/var free space: ${var_size_gb}GB (>= 50GB recommended)"
 elif [[ -n "$var_size_gb" ]]; then
     warn "/var free space: ${var_size_gb}GB (>= 50GB recommended)"
 else
     warn "Unable to determine /var free space"
 fi

 # Check (recommended): /tmp disk space
 tmp_size_gb=$(df -BG /tmp 2>/dev/null | awk 'NR==2 {print substr($4, 1, length($4)-1)}')
 if [[ -n "$tmp_size_gb" ]] && [[ "$tmp_size_gb" -ge 10 ]]; then
     pass "/tmp free space: ${tmp_size_gb}GB (>= 10GB recommended)"
 elif [[ -n "$tmp_size_gb" ]]; then
     warn "/tmp free space: ${tmp_size_gb}GB (>= 10GB recommended)"
 else
     warn "Unable to determine /tmp free space"
 fi

 # Check: netplan must be statically configured (no DHCP)
 # This validates that dhcp4/dhcp6 are not enabled in /etc/netplan/*.yaml.
 netplan_files=(/etc/netplan/*.yaml /etc/netplan/*.yml)
 netplan_found=0
 netplan_file_count=0
 netplan_dhcp_enabled=0
 netplan_has_addresses=0
 netplan_has_bonds=0
 netplan_bad_bond_mode=0
 netplan_good_bond_mode=0
 netplan_unknown_bond_mode=0

 for f in "${netplan_files[@]}"; do
     [[ -e "$f" ]] || continue
     netplan_found=1
     netplan_file_count=$((netplan_file_count + 1))

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
     if [[ "$netplan_file_count" -gt 1 ]]; then
         warn "Multiple netplan files detected under /etc/netplan ($netplan_file_count files); ensure configuration is not conflicting"
     fi
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

 # Check (recommended): Nested virtualization support
 if [[ -r /sys/module/kvm_intel/parameters/nested ]]; then
     nested_intel=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null)
     if [[ "$nested_intel" == "Y" ]] || [[ "$nested_intel" == "1" ]]; then
         pass "Nested virtualization enabled (Intel)"
     else
         warn "Nested virtualization disabled (Intel) - enable if running on VMs"
     fi
 elif [[ -r /sys/module/kvm_amd/parameters/nested ]]; then
     nested_amd=$(cat /sys/module/kvm_amd/parameters/nested 2>/dev/null)
     if [[ "$nested_amd" == "Y" ]] || [[ "$nested_amd" == "1" ]]; then
         pass "Nested virtualization enabled (AMD)"
     else
         warn "Nested virtualization disabled (AMD) - enable if running on VMs"
     fi
 else
     pass "Nested virtualization check skipped (not running on VM or KVM modules not loaded)"
 fi

 # Check (recommended): libvirt/qemu should not be pre-installed
 libvirt_installed=0
 if dpkg -s libvirt-daemon-system >/dev/null 2>&1 || dpkg -s libvirt-bin >/dev/null 2>&1; then
     libvirt_installed=1
 fi
 if dpkg -s qemu-kvm >/dev/null 2>&1 || dpkg -s qemu-system-x86 >/dev/null 2>&1; then
     libvirt_installed=1
 fi

 if [[ "$libvirt_installed" -eq 1 ]]; then
     warn "libvirt or qemu packages detected (may conflict with PCD installation)"
 else
     pass "No conflicting libvirt/qemu packages detected"
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
     fail "Preexisting SAN volumes detected on this host (${san_reasons[*]})"
 else
     pass "No preexisting SAN volumes detected (iSCSI/FC/multipath)"
 fi

 # Check (recommended): iSCSI initiator name should not be default/template
 if [[ -r /etc/iscsi/initiatorname.iscsi ]]; then
     initiator_name=$(grep -E '^InitiatorName=' /etc/iscsi/initiatorname.iscsi 2>/dev/null | cut -d= -f2)
     if [[ -n "$initiator_name" ]]; then
         is_default=0
         if echo "$initiator_name" | grep -qE '^iqn\.1993-08\.org\.debian:01:'; then
             is_default=1
         elif echo "$initiator_name" | grep -qE '^iqn\.2004-10\.com\.ubuntu:01:'; then
             is_default=1
         elif echo "$initiator_name" | grep -qE ':(01|02):'; then
             is_default=1
         fi
         
         if [[ "$is_default" -eq 1 ]]; then
             warn "iSCSI initiator name appears to be default/template: $initiator_name (verify uniqueness across all nodes)"
         else
             pass "iSCSI initiator name: $initiator_name"
         fi
     fi
 fi

 # Check (optional): iSCSI sendtargets discovery test against a portal
 if [[ -n "${iscsi_discovery_portal:-}" ]]; then
     if command -v iscsiadm >/dev/null 2>&1; then
         iscsi_discovery_cmd=(iscsiadm -m discovery -t sendtargets -p "$iscsi_discovery_portal")
         if command -v timeout >/dev/null 2>&1; then
             iscsi_discovery_out=$(timeout 10s "${iscsi_discovery_cmd[@]}" 2>&1)
             iscsi_discovery_rc=$?
             if [[ "$iscsi_discovery_rc" -eq 124 ]]; then
                 iscsi_discovery_report="(timeout)"
                 warn "iSCSI discovery timed out (portal: $iscsi_discovery_portal)"
             elif [[ "$iscsi_discovery_rc" -ne 0 ]]; then
                 iscsi_discovery_report="$iscsi_discovery_out"
                 warn "iSCSI discovery failed (portal: $iscsi_discovery_portal): $iscsi_discovery_out"
             else
                 iscsi_discovery_report="$iscsi_discovery_out"
                 iscsi_target_count=$(printf '%s\n' "$iscsi_discovery_out" | grep -c 'iqn\.' || true)
                 if [[ "$iscsi_target_count" -gt 0 ]]; then
                     pass "iSCSI discovery succeeded (portal: $iscsi_discovery_portal, targets: $iscsi_target_count)"
                 else
                     warn "iSCSI discovery returned no targets (portal: $iscsi_discovery_portal)"
                 fi
             fi
         else
             iscsi_discovery_out=$("${iscsi_discovery_cmd[@]}" 2>&1)
             iscsi_discovery_rc=$?
             if [[ "$iscsi_discovery_rc" -ne 0 ]]; then
                 iscsi_discovery_report="$iscsi_discovery_out"
                 warn "iSCSI discovery failed (portal: $iscsi_discovery_portal): $iscsi_discovery_out"
             else
                 iscsi_discovery_report="$iscsi_discovery_out"
                 iscsi_target_count=$(printf '%s\n' "$iscsi_discovery_out" | grep -c 'iqn\.' || true)
                 if [[ "$iscsi_target_count" -gt 0 ]]; then
                     pass "iSCSI discovery succeeded (portal: $iscsi_discovery_portal, targets: $iscsi_target_count)"
                 else
                     warn "iSCSI discovery returned no targets (portal: $iscsi_discovery_portal)"
                 fi
             fi
         fi
     else
         iscsi_discovery_report="iscsiadm not installed"
         warn "iSCSI discovery skipped: iscsiadm not installed (portal: $iscsi_discovery_portal)"
     fi
 fi

 # Check (recommended): If lvm2 is installed, LVM device filters should be configured
 # Ref: https://docs.platform9.com/private-cloud-director/getting-started/pre-requisites/hypervisor-lvm-configuration
 if dpkg -s lvm2 >/dev/null 2>&1; then
     if [[ -r /etc/lvm/lvm.conf ]]; then
         lvm_filter_line=$(grep -E '^[[:space:]]*filter[[:space:]]*=' /etc/lvm/lvm.conf | head -n 1)
         lvm_global_filter_line=$(grep -E '^[[:space:]]*global_filter[[:space:]]*=' /etc/lvm/lvm.conf | head -n 1)

         if [[ -z "$lvm_filter_line" ]]; then
             fail "lvm2 detected but /etc/lvm/lvm.conf filter is not set (configure LVM device filters)"
         fi

         if [[ -z "$lvm_global_filter_line" ]]; then
             fail "lvm2 detected but /etc/lvm/lvm.conf global_filter is not set (configure LVM device filters)"
         fi
     else
         fail "lvm2 detected but /etc/lvm/lvm.conf is not readable; cannot validate LVM filter configuration"
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
         pass "$url"
     else
         fail "$url"
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

# Optional check: multipath-tools package installed
if [[ "$check_multipath" -eq 1 ]]; then
    if dpkg -s multipath-tools >/dev/null 2>&1; then
        pass "multipath-tools is installed"
    else
        fail "multipath-tools is NOT installed"
    fi
else
    echo "Skipping multipath-tools check (enable with --check-multipath or -m)"
fi

 # Collect system information for report if requested
 if [[ "$generate_report" -eq 1 ]]; then
    # Capture network information
    sysinfo_ip_addr=$(ip a 2>/dev/null)
    sysinfo_ip_route=$(ip route 2>/dev/null)
    sysinfo_ping=$(ping -c 4 google.com 2>&1 || echo "Ping failed")
    
    # Capture storage information
    sysinfo_df=$(df -kh 2>/dev/null)
    
    # Capture netplan configuration
    sysinfo_netplan=""
    for netplan_file in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        if [[ -r "$netplan_file" ]]; then
            sysinfo_netplan+="--- $netplan_file ---"$'\n'
            sysinfo_netplan+=$(cat "$netplan_file" 2>/dev/null)
            sysinfo_netplan+=$'\n\n'
        fi
    done
    if [[ -z "$sysinfo_netplan" ]]; then
        sysinfo_netplan="No netplan configuration files found"
    fi
    
    # Capture iSCSI information if available
     sysinfo_iscsi=""
     if command -v iscsiadm >/dev/null 2>&1; then
         sysinfo_iscsi+="=== iSCSI Sessions ==="$'\n'
         sysinfo_iscsi+=$(iscsiadm -m session 2>&1 || echo "No active iSCSI sessions")
         sysinfo_iscsi+=$'\n\n'
         sysinfo_iscsi+="=== iSCSI Nodes ==="$'\n'
         sysinfo_iscsi+=$(iscsiadm -m node 2>&1 || echo "No iSCSI nodes configured")
         sysinfo_iscsi+=$'\n'
     else
         sysinfo_iscsi="iSCSI tools not installed"
     fi

     if [[ -n "${iscsi_discovery_portal:-}" ]]; then
         sysinfo_iscsi+=$'\n'"=== iSCSI SendTargets Discovery ==="$'\n'
         sysinfo_iscsi+="Portal: $iscsi_discovery_portal"$'\n'
         sysinfo_iscsi+="${iscsi_discovery_report:-}"$'\n'
     fi
    
    # Capture initiator name if exists
    if [[ -r /etc/iscsi/initiatorname.iscsi ]]; then
        sysinfo_iscsi+=$'\n'"=== iSCSI Initiator Name ==="$'\n'
        sysinfo_iscsi+=$(cat /etc/iscsi/initiatorname.iscsi 2>/dev/null)
        sysinfo_iscsi+=$'\n'
    fi
    
    # Capture multipath information if available
    sysinfo_multipath=""
    if command -v multipath >/dev/null 2>&1; then
        sysinfo_multipath+="=== Multipath Devices ==="$'\n'
        sysinfo_multipath+=$(multipath -ll 2>&1 || echo "No multipath devices")
        sysinfo_multipath+=$'\n\n'
        sysinfo_multipath+="=== Multipath Configuration ==="$'\n'
        if [[ -r /etc/multipath.conf ]]; then
            sysinfo_multipath+=$(cat /etc/multipath.conf 2>/dev/null)
        else
            sysinfo_multipath+="No /etc/multipath.conf found"
        fi
        sysinfo_multipath+=$'\n'
    else
        sysinfo_multipath="Multipath tools not installed"
    fi
    
    # Capture LVM configuration if available
    sysinfo_lvm=""
    if dpkg -s lvm2 >/dev/null 2>&1; then
        sysinfo_lvm+="=== LVM Configuration (/etc/lvm/lvm.conf) ==="$'\n'
        if [[ -r /etc/lvm/lvm.conf ]]; then
            # Extract filter and global_filter lines
            filter_line=$(grep -E '^[[:space:]]*filter[[:space:]]*=' /etc/lvm/lvm.conf 2>/dev/null | head -n 1)
            global_filter_line=$(grep -E '^[[:space:]]*global_filter[[:space:]]*=' /etc/lvm/lvm.conf 2>/dev/null | head -n 1)
            
            if [[ -n "$filter_line" ]]; then
                sysinfo_lvm+="filter: $filter_line"$'\n'
            else
                sysinfo_lvm+="filter: NOT SET"$'\n'
            fi
            
            if [[ -n "$global_filter_line" ]]; then
                sysinfo_lvm+="global_filter: $global_filter_line"$'\n'
            else
                sysinfo_lvm+="global_filter: NOT SET"$'\n'
            fi
        else
            sysinfo_lvm+="/etc/lvm/lvm.conf not readable"$'\n'
        fi
        sysinfo_lvm+=$'\n'
        
        # Capture LVM volume information
        sysinfo_lvm+="=== Physical Volumes ==="$'\n'
        sysinfo_lvm+=$(pvs 2>&1 || echo "No physical volumes or pvs command failed")
        sysinfo_lvm+=$'\n\n'
        sysinfo_lvm+="=== Volume Groups ==="$'\n'
        sysinfo_lvm+=$(vgs 2>&1 || echo "No volume groups or vgs command failed")
        sysinfo_lvm+=$'\n\n'
        sysinfo_lvm+="=== Logical Volumes ==="$'\n'
        sysinfo_lvm+=$(lvs 2>&1 || echo "No logical volumes or lvs command failed")
        sysinfo_lvm+=$'\n'
    else
        sysinfo_lvm="LVM2 not installed"
    fi
fi

# Generate report if requested
if [[ "$generate_report" -eq 1 ]]; then
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    hostname=$(hostname)
    
    # Generate Markdown report
    if [[ "$report_format" == "text" ]] || [[ "$report_format" == "both" ]]; then
        text_file="${report_file}.md"
        {
            echo "# PCD Pre-Installation Validation Report"
            echo ""
            echo "**Generated:** $timestamp  "
            echo "**Hostname:** $hostname  "
            echo "**OS:** ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}"
            echo ""
            echo "---"
            echo ""
            echo "## Summary"
            echo ""
            
            pass_count=0
            warn_count=0
            fail_count_report=0
            
            for entry in "${report_data[@]}"; do
                status="${entry%%|*}"
                case "$status" in
                    PASS) ((pass_count++)) ;;
                    WARN) ((warn_count++)) ;;
                    FAIL) ((fail_count_report++)) ;;
                esac
            done
            
            echo "| Status | Count |"
            echo "|--------|-------|"
            echo "| ✅ Passed | $pass_count |"
            echo "| ⚠️ Warnings | $warn_count |"
            echo "| ❌ Failed | $fail_count_report |"
            echo ""
            echo "---"
            echo ""
            echo "## Validation Results"
            echo ""
            
            for entry in "${report_data[@]}"; do
                status="${entry%%|*}"
                message="${entry#*|}"
                case "$status" in
                    PASS) echo "- ✅ **PASS:** $message" ;;
                    WARN) echo "- ⚠️ **WARN:** $message" ;;
                    FAIL) echo "- ❌ **FAIL:** $message" ;;
                esac
            done
            
            echo ""
            echo "---"
            echo ""
            echo "## System Information"
            echo ""
            
            echo "### Network Configuration"
            echo ""
            echo "#### IP Addresses"
            echo '```'
            echo "$sysinfo_ip_addr"
            echo '```'
            echo ""
            echo "#### IP Routes"
            echo '```'
            echo "$sysinfo_ip_route"
            echo '```'
            echo ""
            echo "#### Network Connectivity Test"
            echo '```'
            echo "$sysinfo_ping"
            echo '```'
            echo ""
            echo "#### Netplan Configuration"
            echo '```yaml'
            echo "$sysinfo_netplan"
            echo '```'
            echo ""
            
            echo "### Storage Information"
            echo ""
            echo "#### Disk Usage"
            echo '```'
            echo "$sysinfo_df"
            echo '```'
            echo ""
            
            if [[ "$sysinfo_iscsi" != "iSCSI tools not installed" ]] || [[ -r /etc/iscsi/initiatorname.iscsi ]]; then
                echo "### iSCSI Configuration"
                echo ""
                echo '```'
                echo "$sysinfo_iscsi"
                echo '```'
                echo ""
            fi
            
            if [[ "$sysinfo_multipath" != "Multipath tools not installed" ]]; then
                echo "### Multipath Configuration"
                echo ""
                echo '```'
                echo "$sysinfo_multipath"
                echo '```'
                echo ""
            fi
            
            if [[ "$sysinfo_lvm" != "LVM2 not installed" ]]; then
                echo "### LVM Configuration"
                echo ""
                echo '```'
                echo "$sysinfo_lvm"
                echo '```'
                echo ""
            fi
            
            echo "---"
            echo ""
            echo "*End of Report*"
        } > "$text_file"
        
        echo ""
        echo "Markdown report saved to: $text_file"
    fi
    
    # Generate JSON report
    if [[ "$report_format" == "json" ]] || [[ "$report_format" == "both" ]]; then
        json_file="${report_file}.json"
        {
            echo "{"
            echo "  \"report_metadata\": {"
            echo "    \"generated_at\": \"$timestamp\","
            echo "    \"hostname\": \"$hostname\","
            echo "    \"os\": \"${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}\","
            echo "    \"script_version\": \"1.0\""
            echo "  },"
            echo "  \"summary\": {"
            
            pass_count=0
            warn_count=0
            fail_count_report=0
            
            for entry in "${report_data[@]}"; do
                status="${entry%%|*}"
                case "$status" in
                    PASS) ((pass_count++)) ;;
                    WARN) ((warn_count++)) ;;
                    FAIL) ((fail_count_report++)) ;;
                esac
            done
            
            echo "    \"total_checks\": ${#report_data[@]},"
            echo "    \"passed\": $pass_count,"
            echo "    \"warnings\": $warn_count,"
            echo "    \"failed\": $fail_count_report"
            echo "  },"
            echo "  \"checks\": ["
            
            first=1
            for entry in "${report_data[@]}"; do
                status="${entry%%|*}"
                message="${entry#*|}"
                # Escape quotes in message
                message_escaped="${message//\"/\\\"}"
                
                if [[ $first -eq 0 ]]; then
                    echo ","
                fi
                first=0
                
                echo -n "    {"
                echo -n "\"status\": \"$status\", "
                echo -n "\"message\": \"$message_escaped\""
                echo -n "}"
            done
            
            echo ""
            echo "  ],"
            echo "  \"system_information\": {"
            echo "    \"network\": {"
            echo -n "      \"ip_addresses\": "
            printf '%s' "$sysinfo_ip_addr" | jq -Rs .
            echo ","
            echo -n "      \"ip_routes\": "
            printf '%s' "$sysinfo_ip_route" | jq -Rs .
            echo ","
            echo -n "      \"ping_test\": "
            printf '%s' "$sysinfo_ping" | jq -Rs .
            echo ","
            echo -n "      \"netplan_config\": "
            printf '%s' "$sysinfo_netplan" | jq -Rs .
            echo ""
            echo "    },"
            echo "    \"storage\": {"
            echo -n "      \"disk_usage\": "
            printf '%s' "$sysinfo_df" | jq -Rs .
            echo ""
            echo "    },"
            echo "    \"iscsi\": {"
            echo -n "      \"info\": "
            printf '%s' "$sysinfo_iscsi" | jq -Rs .
            echo ""
            echo "    },"
            echo "    \"multipath\": {"
            echo -n "      \"info\": "
            printf '%s' "$sysinfo_multipath" | jq -Rs .
            echo ""
            echo "    },"
            echo "    \"lvm\": {"
            echo -n "      \"info\": "
            printf '%s' "$sysinfo_lvm" | jq -Rs .
            echo ""
            echo "    }"
            echo "  }"
            echo "}"
        } > "$json_file"
        
        echo "JSON report saved to: $json_file"
    fi
fi

# Exit non-zero if any mandatory checks failed
if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
