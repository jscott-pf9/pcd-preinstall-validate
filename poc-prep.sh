#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.1"

usage() {
  echo "poc-prep.sh v${SCRIPT_VERSION}"
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --proxy URL                       Configure system-wide HTTP(S) proxy in /etc/environment and APT"
  echo "  --netplan-wizard                  Interactive wizard to generate netplan config"
  echo "  --netplan-file PATH               Netplan file to write (default: /etc/netplan/01-netcfg.yaml)"
  echo "  --disable-cloud-init-networking   Disable cloud-init network config (default)"
  echo "  --no-disable-cloud-init-networking Do not modify cloud-init configuration"
  echo "  --setup-chrony                    Prefer chrony if installed, else configure systemd-timesyncd (default)"
  echo "  --no-setup-chrony                 Do not modify time sync configuration"
  echo "  --ntp-servers LIST                Space-separated NTP servers for timesyncd (default: 0.pool.ntp.org 1.pool.ntp.org)"
  echo "  --fallback-ntp-servers LIST       Space-separated fallback NTP servers for timesyncd (default: ntp.ubuntu.com)"
  echo "  --ensure-iscsi-initiator          Ensure iSCSI initiator name is hostname-based (default)"
  echo "  --no-ensure-iscsi-initiator       Do not modify iSCSI initiator name"
  echo "  --configure-lvm-filter            Configure LVM device filters for boot disk topology (default)"
  echo "  --no-configure-lvm-filter         Skip LVM filter configuration"
  echo "  --rebuild-initramfs               Rebuild initramfs after writing LVM filter (required for boot-from-SAN)"
  echo "  -V, --version                     Print version and exit"
  echo "  -h, --help                        Show help"
}

ok() { printf '\033[0;32m%s\033[0m %s\n' "OK" "$1"; }
warn() { printf '\033[0;33m%s\033[0m %s\n' "WARN" "$1"; }
err() { printf '\033[0;31m%s\033[0m %s\n' "ERROR" "$1" 1>&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    exit 1
  fi
}

prompt() {
  local p="$1"
  local v
  read -r -p "$p" v
  printf '%s' "$v"
}

prompt_default() {
  local p="$1"
  local d="$2"
  local v
  read -r -p "${p} [${d}]: " v
  if [[ -z "${v:-}" ]]; then
    printf '%s' "$d"
  else
    printf '%s' "$v"
  fi
}

is_physical_iface() {
  local ifname="$1"
  [[ -d "/sys/class/net/${ifname}" ]] || return 1
  [[ "$ifname" != "lo" ]] || return 1
  [[ -e "/sys/class/net/${ifname}/device" ]] || return 1
  case "$ifname" in
    bond*|br*|vlan*|virbr*|docker*|veth*|cni*|flannel*|kube*|tun*|tap*) return 1 ;;
  esac
  return 0
}

get_iface_state_line() {
  local ifname="$1"
  local oper="unknown"
  local carrier="?"
  [[ -r "/sys/class/net/${ifname}/operstate" ]] && oper=$(cat "/sys/class/net/${ifname}/operstate" 2>/dev/null || true)
  [[ -r "/sys/class/net/${ifname}/carrier" ]] && carrier=$(cat "/sys/class/net/${ifname}/carrier" 2>/dev/null || true)
  printf '%s (operstate=%s carrier=%s)' "$ifname" "$oper" "$carrier"
}

pick_ifaces_interactive() {
  local need_count="$1"
  local -a ifaces=()
  local -a labels=()
  local i

  while IFS= read -r i; do
    [[ -n "$i" ]] || continue
    ifaces+=("$i")
    labels+=("$(get_iface_state_line "$i")")
  done < <(ls -1 /sys/class/net 2>/dev/null | while read -r n; do is_physical_iface "$n" && echo "$n"; done)

  if [[ "${#ifaces[@]}" -eq 0 ]]; then
    err "No physical interfaces detected"
    return 1
  fi

  echo "Detected physical interfaces:"
  for idx in "${!ifaces[@]}"; do
    echo "  $((idx+1))) ${labels[$idx]}"
  done

  local sel
  if [[ "$need_count" -eq 1 ]]; then
    sel=$(prompt "Select interface number: ")
  else
    sel=$(prompt "Select ${need_count} interface numbers (space-separated): ")
  fi

  local -a nums=()
  read -r -a nums <<<"${sel:-}"
  if [[ "$need_count" -eq 1 ]]; then
    if [[ "${#nums[@]}" -ne 1 ]]; then
      err "Select exactly 1 interface"
      return 1
    fi
  else
    if [[ "${#nums[@]}" -lt "$need_count" ]]; then
      err "Select at least ${need_count} interfaces"
      return 1
    fi
  fi

  local -a chosen=()
  local n
  for n in "${nums[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || { err "Invalid selection: $n"; return 1; }
    if (( n < 1 || n > ${#ifaces[@]} )); then
      err "Selection out of range: $n"
      return 1
    fi
    chosen+=("${ifaces[$((n-1))]}")
  done

  printf '%s\n' "${chosen[@]}"
}

write_netplan_yaml() {
  local outfile="$1"
  local mode="$2"
  local ip_cidr="$3"
  local gw="$4"
  local dns_csv="$5"
  local mtu="$6"
  shift 6
  local -a ifaces=("$@");

  mkdir -p "$(dirname "$outfile")"

  local dns_yaml=""
  local -a dns_arr=()
  local d
  IFS=',' read -r -a dns_arr <<<"$dns_csv"
  for d in "${dns_arr[@]}"; do
    d=$(printf '%s' "$d" | xargs)
    [[ -n "$d" ]] && dns_yaml+="\n        - $d"
  done

  if [[ "$mode" == "single" ]]; then
    local iface="${ifaces[0]}"
    {
      printf '%s\n' "network:"
      printf '%s\n' "  version: 2"
      printf '%s\n' "  renderer: networkd"
      printf '%s\n' "  ethernets:"
      printf '%s\n' "    ${iface}:"
      printf '%s\n' "      dhcp4: false"
      printf '%s\n' "      dhcp6: false"
      [[ -n "$mtu" ]] && printf '%s\n' "      mtu: ${mtu}"
      printf '%s\n' "      addresses:"
      printf '%s\n' "        - ${ip_cidr}"
      printf '%s\n' "      routes:"
      printf '%s\n' "        - to: default"
      printf '%s\n' "          via: ${gw}"
      printf '%s\n' "      nameservers:"
      printf '%s\n' "        addresses:${dns_yaml}"
    } >"$outfile"
  else
    local bond_mode="$mode"
    local i
    {
      printf '%s\n' "network:"
      printf '%s\n' "  version: 2"
      printf '%s\n' "  renderer: networkd"
      printf '%s\n' "  ethernets:"
      for i in "${ifaces[@]}"; do
        printf '%s\n' "    ${i}: {}"
      done
      printf '%s\n' "  bonds:"
      printf '%s\n' "    bond0:"
      printf '%s\n' "      interfaces: [$(IFS=,; printf '%s' "${ifaces[*]}")]"
      printf '%s\n' "      dhcp4: false"
      printf '%s\n' "      dhcp6: false"
      [[ -n "$mtu" ]] && printf '%s\n' "      mtu: ${mtu}"
      printf '%s\n' "      addresses:"
      printf '%s\n' "        - ${ip_cidr}"
      printf '%s\n' "      routes:"
      printf '%s\n' "        - to: default"
      printf '%s\n' "          via: ${gw}"
      printf '%s\n' "      nameservers:"
      printf '%s\n' "        addresses:${dns_yaml}"
      printf '%s\n' "      parameters:"
      if [[ "$bond_mode" == "active-backup" ]]; then
        printf '%s\n' "        mode: active-backup"
        printf '%s\n' "        mii-monitor-interval: 100"
      else
        printf '%s\n' "        mode: 802.3ad"
        printf '%s\n' "        mii-monitor-interval: 100"
        printf '%s\n' "        lacp-rate: fast"
        printf '%s\n' "        transmit-hash-policy: layer2+3"
      fi
    } >"$outfile"
  fi
}

netplan_wizard() {
  ok "Starting netplan wizard"

  local choice
  echo "Choose configuration type:"
  echo "  1) Single interface (static IP)"
  echo "  2) bond0 active-backup (static IP)"
  echo "  3) bond0 802.3ad (LACP) (static IP)"
  choice=$(prompt "Enter choice [1-3]: ")

  local mode=""
  local need_count=1
  case "$choice" in
    1) mode="single"; need_count=1 ;;
    2) mode="active-backup"; need_count=2 ;;
    3) mode="802.3ad"; need_count=2 ;;
    *) err "Invalid choice"; return 1 ;;
  esac

  local ip_cidr
  local gw
  local dns
  local mtu

  ip_cidr=$(prompt "Enter IP/CIDR (example 192.168.1.10/24): ")
  gw=$(prompt "Enter default gateway IP (example 192.168.1.1): ")
  dns=$(prompt_default "Enter DNS servers comma-separated" "8.8.8.8,1.1.1.1")
  mtu=$(prompt_default "Enter MTU (blank for default)" "")

  local -a ifaces=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && ifaces+=("$line")
  done < <(pick_ifaces_interactive "$need_count")

  ok "Writing netplan to ${netplan_file}"
  write_netplan_yaml "$netplan_file" "$mode" "$ip_cidr" "$gw" "$dns" "$mtu" "${ifaces[@]}"

  echo ""
  echo "Wrote: ${netplan_file}"
  echo ""
  cat "$netplan_file"
  echo ""

  if command -v netplan >/dev/null 2>&1; then
    local do_validate
    do_validate=$(prompt_default "Run 'netplan generate' to validate? (y/N)" "N")
    if [[ "$do_validate" =~ ^[Yy]$ ]]; then
      if netplan generate >/dev/null 2>&1; then
        ok "netplan generate succeeded"
      else
        err "netplan generate failed"
        return 1
      fi
    fi

    local do_try
    do_try=$(prompt_default "Run 'netplan try' now? (y/N)" "N")
    if [[ "$do_try" =~ ^[Yy]$ ]]; then
      netplan try
    fi
  else
    warn "netplan command not found; skipping validation/apply"
  fi
}

setup_proxy() {
  if [[ -z "${proxy_url:-}" ]]; then
    ok "No proxy configured; skipping proxy setup"
    return 0
  fi

  local env_file=/etc/environment
  local tmp
  tmp=$(mktemp)
  grep -vE '^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=' \
    "$env_file" 2>/dev/null >"$tmp" || true
  printf '%s\n' \
    "http_proxy=${proxy_url}" \
    "https_proxy=${proxy_url}" \
    "HTTP_PROXY=${proxy_url}" \
    "HTTPS_PROXY=${proxy_url}" \
    "no_proxy=localhost,127.0.0.1,169.254.169.254" \
    "NO_PROXY=localhost,127.0.0.1,169.254.169.254" >>"$tmp"
  mv "$tmp" "$env_file"
  ok "Configured proxy in /etc/environment"

  mkdir -p /etc/apt/apt.conf.d
  local apt_proxy=/etc/apt/apt.conf.d/99-pcd-proxy.conf
  printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' \
    "$proxy_url" "$proxy_url" >"$apt_proxy"
  ok "Configured proxy in ${apt_proxy}"
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    err "Cannot read /etc/os-release"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]] || { [[ "${VERSION_ID:-}" != "22.04" ]] && [[ "${VERSION_ID:-}" != "24.04" ]]; }; then
    err "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported: Ubuntu 22.04/24.04"
    exit 1
  fi
  ok "OS detected: ${PRETTY_NAME:-ubuntu ${VERSION_ID:-}}"
}

ensure_ssh_active() {
  if systemctl is-enabled --quiet ssh.service 2>/dev/null || systemctl is-enabled --quiet sshd.service 2>/dev/null; then
    :
  else
    systemctl enable ssh.service >/dev/null 2>&1 || true
    systemctl enable sshd.service >/dev/null 2>&1 || true
  fi

  if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
    ok "SSH service is active"
  else
    systemctl start ssh.service >/dev/null 2>&1 || true
    systemctl start sshd.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
      ok "SSH service started"
    else
      warn "SSH service is not active"
    fi
  fi
}

disable_cloud_init_networking() {
  if [[ "$disable_cloud_init_network" -eq 0 ]]; then
    ok "cloud-init networking changes disabled by flag"
    return 0
  fi

  if [[ ! -d /etc/cloud ]]; then
    ok "cloud-init not present; nothing to disable"
    return 0
  fi

  mkdir -p /etc/cloud/cloud.cfg.d
  local cfg_file=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  if [[ -f "$cfg_file" ]] && grep -qE '^[[:space:]]*config:[[:space:]]*disabled[[:space:]]*$' "$cfg_file" 2>/dev/null; then
    ok "cloud-init network config already disabled ($cfg_file)"
  else
    printf '%s\n' 'network: {config: disabled}' >"$cfg_file"
    ok "Disabled cloud-init network config ($cfg_file)"
  fi
}

setup_chrony() {
  if [[ "$enable_chrony" -eq 0 ]]; then
    ok "Chrony setup disabled by flag"
    return 0
  fi

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qxE 'chrony\.service|chronyd\.service'; then
    if systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null; then
      systemctl stop systemd-timesyncd.service >/dev/null 2>&1 || true
    fi
    if systemctl is-enabled --quiet systemd-timesyncd.service 2>/dev/null; then
      systemctl disable systemd-timesyncd.service >/dev/null 2>&1 || true
    fi

    systemctl enable chrony.service >/dev/null 2>&1 || systemctl enable chronyd.service >/dev/null 2>&1 || true
    systemctl start chrony.service >/dev/null 2>&1 || systemctl start chronyd.service >/dev/null 2>&1 || true

    if systemctl is-active --quiet chrony.service 2>/dev/null || systemctl is-active --quiet chronyd.service 2>/dev/null; then
      ok "Time sync active (chrony)"
      return 0
    fi

    err "Chrony unit exists but service is not active"
    return 1
  fi

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qxE 'systemd-timesyncd\.service'; then
    mkdir -p /etc/systemd/timesyncd.conf.d
    local cfg=/etc/systemd/timesyncd.conf.d/99-pcd.conf
    {
      printf '%s\n' '[Time]'
      printf '%s\n' "NTP=${ntp_servers}"
      printf '%s\n' "FallbackNTP=${fallback_ntp_servers}"
    } >"$cfg"

    systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true
    systemctl restart systemd-timesyncd.service >/dev/null 2>&1 || true

    if systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null; then
      ok "Time sync active (systemd-timesyncd)"
    else
      err "systemd-timesyncd is not active"
      return 1
    fi
  else
    err "No time sync service found (chrony not installed and systemd-timesyncd not available)"
    return 1
  fi
}

ensure_iscsi_initiator() {
  if [[ "$ensure_iscsi_initiator" -eq 0 ]]; then
    ok "iSCSI initiator changes disabled by flag"
    return 0
  fi

  if [[ ! -d /etc/iscsi ]] || [[ ! -f /etc/iscsi/initiatorname.iscsi ]]; then
    warn "open-iscsi not present yet (/etc/iscsi/initiatorname.iscsi not found); skipping initiator name"
    return 0
  fi

  local host
  host=$(hostname --fqdn 2>/dev/null || hostname 2>/dev/null || true)
  if [[ -z "${host:-}" ]]; then
    err "Unable to determine hostname for iSCSI initiator"
    return 1
  fi

  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9.-' '-')
  host=${host#-}
  host=${host%-}

  local prefix
  prefix="iqn.$(date +%Y-%m).local.pcd"
  local desired
  desired="${prefix}:${host}"

  local current
  current=$(awk -F= '/^InitiatorName=/ {print $2; exit}' /etc/iscsi/initiatorname.iscsi 2>/dev/null || true)
  if [[ "$current" == "$desired" ]]; then
    ok "iSCSI initiator name already hostname-based ($desired)"
    return 0
  fi

  printf '%s\n' "InitiatorName=${desired}" > /etc/iscsi/initiatorname.iscsi
  ok "Set iSCSI initiator name to ${desired}"

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qxE 'iscsid\.service'; then
    systemctl restart iscsid.service >/dev/null 2>&1 || warn "Failed to restart iscsid.service"
  fi
}

_lvm_classify_pv() {
  local pv="$1" chain tran is_mpath=0 is_san=0
  if lsblk -dno TYPE "$pv" 2>/dev/null | grep -qi '^mpath$'; then
    is_mpath=1
  fi
  chain=$(lsblk -s -no NAME,TYPE "$pv" 2>/dev/null || true)
  if printf '%s\n' "$chain" | awk '{print $2}' | grep -qi '^mpath$'; then
    is_mpath=1
  fi
  while read -r disk; do
    [ -n "$disk" ] || continue
    tran=$(lsblk -dno TRAN "/dev/$disk" 2>/dev/null | tr -d '[:space:]')
    case "$tran" in
      fc|iscsi|fcoe) is_san=1 ;;
    esac
  done < <(printf '%s\n' "$chain" | awk '$2=="disk"{print $1}')
  if [ "$is_mpath" -eq 1 ] || [ "$is_san" -eq 1 ]; then echo san; else echo local; fi
}

configure_lvm_filter() {
  if [[ "$do_configure_lvm_filter" -eq 0 ]]; then
    ok "LVM filter configuration skipped (--no-configure-lvm-filter)"
    return 0
  fi

  if ! dpkg -s lvm2 >/dev/null 2>&1; then
    ok "lvm2 not installed; skipping LVM filter configuration"
    return 0
  fi

  local LVM_CONF=/etc/lvm/lvm.conf
  [[ -f "$LVM_CONF" ]] || { err "$LVM_CONF not found"; return 1; }

  local root_src vg="" pvs_list=() verdict=local local_disks=()
  root_src=$(findmnt -no SOURCE / 2>/dev/null) || { err "cannot determine root source"; return 1; }

  if lvs "$root_src" >/dev/null 2>&1; then
    vg=$(lvs --noheadings -o vg_name "$root_src" 2>/dev/null | tr -d '[:space:]')
    while read -r pv; do
      [[ -n "$pv" ]] && pvs_list+=("$pv")
    done < <(pvs --noheadings -o pv_name -S vg_name="$vg" 2>/dev/null \
             | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi
  # If LVM tools didn't resolve PVs, walk the DM device tree with lsblk to find backing disks
  if [[ "${#pvs_list[@]}" -eq 0 ]] && [[ -n "$root_src" ]]; then
    while read -r _disk; do
      [[ -n "$_disk" ]] && pvs_list+=("/dev/$_disk")
    done < <(lsblk -s -no NAME,TYPE "$root_src" 2>/dev/null | awk '$2=="disk"{print $1}')
  fi
  # Last resort: add root source itself (rare — only if lsblk also found nothing)
  if [[ "${#pvs_list[@]}" -eq 0 ]] && [[ -n "$root_src" ]]; then
    pvs_list+=("$root_src")
  fi

  local _pv _c _disk
  for _pv in "${pvs_list[@]}"; do
    _c=$(_lvm_classify_pv "$_pv")
    if [[ "$_c" == "san" ]]; then
      verdict=san
    else
      while read -r _disk; do
        [[ -n "$_disk" ]] && local_disks+=("/dev/$_disk")
      done < <(lsblk -s -no NAME,TYPE "$_pv" 2>/dev/null | awk '$2=="disk"{print $1}')
    fi
  done

  local FILTER
  if [[ "$verdict" == "san" ]]; then
    FILTER='[ "a|^/dev/mapper/|", "r|.*|" ]'
  else
    local accepts="" _d
    declare -A _seen=()
    for _d in "${local_disks[@]:-}"; do
      [[ -n "${_seen[$_d]:-}" ]] && continue
      _seen[$_d]=1
      accepts="${accepts}\"a|^${_d}|\", "
    done
    [[ -n "$accepts" ]] || accepts='"a|^/dev/sda|", '
    FILTER="[ ${accepts}\"r|.*|\" ]"
  fi

  # pre-write in-memory test
  if [[ -n "$vg" ]]; then
    if ! vgs --config "devices { filter = $FILTER global_filter = $FILTER }" \
         --noheadings -o vg_name "$vg" 2>/dev/null | tr -d '[:space:]' | grep -qx "$vg"; then
      err "LVM filter pre-write test failed: candidate filter hides root VG. Refusing to write."
      return 1
    fi
  fi

  local ts backup
  ts=$(date +%Y%m%d-%H%M%S)
  backup="${LVM_CONF}.bak.${ts}"
  cp -a "$LVM_CONF" "$backup"

  python3 - "$LVM_CONF" "$FILTER" <<'PY'
import re, sys
path, flt = sys.argv[1], sys.argv[2]
src = open(path).read()
def sub_or_insert(text, key, value):
    pat = re.compile(r'^\s*#?\s*%s\s*=.*$' % re.escape(key), re.M)
    line = "\t%s = %s" % (key, value)
    if pat.search(text):
        return pat.sub(line, text, count=1)
    return re.sub(r'(devices\s*\{)', r'\1\n' + line, text, count=1)
for key in ("filter", "global_filter"):
    src = sub_or_insert(src, key, flt)
open(path, "w").write(src)
PY

  # post-write verify
  if [[ -n "$vg" ]]; then
    if ! pvs >/dev/null 2>&1 || ! vgs --noheadings -o vg_name "$vg" 2>/dev/null \
         | tr -d '[:space:]' | grep -qx "$vg"; then
      cp -a "$backup" "$LVM_CONF"
      err "LVM filter post-write verify failed; rolled back from $backup"
      return 1
    fi
  fi

  ok "LVM filter configured (${verdict} boot disk): ${FILTER}"

  if [[ "$rebuild_initramfs" -eq 1 ]]; then
    update-initramfs -u -k all
    ok "initramfs rebuilt"
  else
    warn "initramfs not rebuilt — re-run with --rebuild-initramfs before next reboot if this is a boot-from-SAN host"
  fi
}

disable_cloud_init_network=1
enable_chrony=1
ensure_iscsi_initiator=1
do_configure_lvm_filter=1
rebuild_initramfs=0
run_netplan_wizard=0
netplan_file="/etc/netplan/01-netcfg.yaml"
ntp_servers="0.pool.ntp.org 1.pool.ntp.org"
fallback_ntp_servers="ntp.ubuntu.com"
proxy_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy)
      shift
      if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
        proxy_url="$1"
        shift
      else
        err "--proxy requires a URL (e.g. http://proxy.corp:3128)"
        exit 2
      fi
      ;;
    --netplan-wizard)
      run_netplan_wizard=1
      shift
      ;;
    --netplan-file)
      shift
      if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
        netplan_file="$1"
        shift
      else
        err "--netplan-file requires a path"
        exit 2
      fi
      ;;
    --disable-cloud-init-networking)
      disable_cloud_init_network=1
      shift
      ;;
    --no-disable-cloud-init-networking)
      disable_cloud_init_network=0
      shift
      ;;
    --setup-chrony)
      enable_chrony=1
      shift
      ;;
    --no-setup-chrony)
      enable_chrony=0
      shift
      ;;
    --ntp-servers)
      shift
      if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
        ntp_servers="$1"
        shift
      else
        err "--ntp-servers requires a value"
        exit 2
      fi
      ;;
    --fallback-ntp-servers)
      shift
      if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
        fallback_ntp_servers="$1"
        shift
      else
        err "--fallback-ntp-servers requires a value"
        exit 2
      fi
      ;;
    --ensure-iscsi-initiator)
      ensure_iscsi_initiator=1
      shift
      ;;
    --no-ensure-iscsi-initiator)
      ensure_iscsi_initiator=0
      shift
      ;;
    --configure-lvm-filter)
      do_configure_lvm_filter=1
      shift
      ;;
    --no-configure-lvm-filter)
      do_configure_lvm_filter=0
      shift
      ;;
    --rebuild-initramfs)
      rebuild_initramfs=1
      shift
      ;;
    -V|--version)
      echo "poc-prep.sh v${SCRIPT_VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

need_root
require_cmd systemctl

detect_os
setup_proxy

ensure_ssh_active
disable_cloud_init_networking
setup_chrony
ensure_iscsi_initiator
configure_lvm_filter

if [[ "$run_netplan_wizard" -eq 1 ]]; then
  netplan_wizard
fi

ok "Node prep completed"

echo ""
echo "Next steps:"
echo "  1) Configure static netplan (no DHCP) and verify DNS/time sync"
echo "  2) If you use iSCSI, verify the initiator name in /etc/iscsi/initiatorname.iscsi"
echo "  3) Run validation: sudo ./poc-validate.sh --report"
