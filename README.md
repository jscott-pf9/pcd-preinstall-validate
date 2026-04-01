# pcd-preinstall-validate

Pre-installation validation script for **Platform9 Private Cloud Director (PCD)** hypervisor hosts.

The script performs a set of mandatory and recommended checks on a host before installing PCD components.

## What it checks

### System Requirements
- Host OS is supported (Ubuntu 22.04 LTS or Ubuntu 24.04 LTS)
- Architecture is `x86_64`
- CPU cores (>= 8)
- RAM (>= 16GB)
- Hardware virtualization flags present (`vmx` / `svm`)
- Basic CPU sanity checks (vendor/model info and a minimal instruction set baseline)
- Kernel version detection

### Performance & Hardware
- CPU governor set to 'performance' (recommended)
- IOMMU/VT-d enabled for PCI passthrough (recommended)
- Hugepages configuration (recommended)
- System load average monitoring (recommended)

### Network Configuration
- `cloud-init` is disabled (when installed)
- Time synchronization service is active (systemd-timesyncd, ntp, ntpd, or chronyd)
- Network interfaces are up with link (recommended)
- DNS resolution is working
- Netplan is not using DHCP and has static addressing configured
- Netplan bond mode sanity (warn/fail if unsupported)

### Storage & Filesystem
- Root filesystem type (ext4 or xfs recommended)
- Root filesystem free space (>= 250GB recommended)
- `/var` free space (>= 50GB recommended)
- `/tmp` free space (>= 10GB recommended)
- Disk I/O scheduler detection (recommended)
- Fails if SAN-backed storage appears to be presented already (iSCSI sessions, FC-attached LUNs, or multipath maps)
- Warns if iSCSI initiator name appears to be a default/template value (risk of duplicates across nodes)
- Swap presence (recommended)
- LVM filter configuration when `lvm2` is installed (mandatory if lvm2 installed)

### Security & Access
- SSH service is running
- Firewall status (UFW/iptables detection, recommended)
- SELinux/AppArmor status (recommended)

### Virtualization
- Nested virtualization support detection (recommended)
- No conflicting libvirt/qemu packages pre-installed (recommended)

### Connectivity
- Outbound connectivity to required endpoints (via `curl --head`)

### Optional Checks
- `multipath-tools` presence (flag-controlled with --check-multipath)

## Report Output

The script can generate validation reports in two formats:

### Markdown Report Format

The text report is generated in Markdown format for better readability:

```markdown
# PCD Pre-Installation Validation Report

**Generated:** 2026-04-01T15:10:23Z  
**Hostname:** hypervisor-01  
**OS:** Ubuntu 22.04.3 LTS

---

## Summary

| Status | Count |
|--------|-------|
| ✅ Passed | 45 |
| ⚠️ Warnings | 8 |
| ❌ Failed | 2 |

---

## Validation Results

- ✅ **PASS:** OS: Ubuntu 22.04.3 LTS
- ✅ **PASS:** Architecture is x86_64
- ✅ **PASS:** CPU cores: 16 (>= 8 required)
- ⚠️ **WARN:** CPU governor is not set to 'performance'
- ❌ **FAIL:** DNS resolution failed
...

---

## System Information

### Network Configuration

#### IP Addresses
```
(output of 'ip a')
```

#### IP Routes
```
(output of 'ip route')
```

#### Network Connectivity Test
```
(output of 'ping -c 4 google.com')
```

#### Netplan Configuration
```yaml
(contents of /etc/netplan/*.yaml files)
```

### Storage Information

#### Disk Usage
```
(output of 'df -kh')
```

### iSCSI Configuration
```
(iSCSI sessions, nodes, and initiator name if available)
```

### Multipath Configuration
```
(multipath devices and configuration if available)
```

### LVM Configuration
```
(LVM filter settings, physical volumes, volume groups, and logical volumes if LVM is installed)
```

---

*End of Report*
```

### JSON Report Format

```json
{
  "report_metadata": {
    "generated_at": "2026-04-01T15:10:23Z",
    "hostname": "hypervisor-01",
    "os": "Ubuntu 22.04.3 LTS",
    "script_version": "1.0"
  },
  "summary": {
    "total_checks": 55,
    "passed": 45,
    "warnings": 8,
    "failed": 2
  },
  "checks": [
    {"status": "PASS", "message": "OS: Ubuntu 22.04.3 LTS"},
    {"status": "PASS", "message": "Architecture is x86_64"},
    {"status": "WARN", "message": "CPU governor is not set to 'performance'"},
    {"status": "FAIL", "message": "DNS resolution failed"}
  ],
  "system_information": {
    "network": {
      "ip_addresses": "...",
      "ip_routes": "...",
      "ping_test": "...",
      "netplan_config": "..."
    },
    "storage": {
      "disk_usage": "..."
    },
    "iscsi": {
      "info": "..."
    },
    "multipath": {
      "info": "..."
    },
    "lvm": {
      "info": "..."
    }
  }
}
```

The JSON format is ideal for:
- Automated processing and analysis
- Integration with monitoring systems
- Batch validation across multiple servers
- Generating compliance reports

## Supported platforms

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

## Prerequisites

- Bash
- Common base utilities typically present on Ubuntu (e.g. `awk`, `grep`, `df`, `uname`, `nproc`)
- `curl` (used for outbound connectivity checks)

## Get the script

Option 1: Clone the repository

```bash
git clone https://github.com/jscott-pf9/pcd-preinstall-validate.git
cd pcd-preinstall-validate
```

Option 2: Download just the script

```bash
curl -fsSL -o saasvalidate.sh \
  https://raw.githubusercontent.com/jscott-pf9/pcd-preinstall-validate/main/saasvalidate.sh
chmod +x saasvalidate.sh
```

## Usage

Make the script executable (if needed):

```bash
chmod +x saasvalidate.sh
```

Run the standard validation:

### Basic Usage

```bash
sudo ./saasvalidate.sh
```

### With Report Generation

```bash
# Generate Markdown report (default filename: pcd-validation-report.md)
sudo ./saasvalidate.sh --report

# Generate report with custom filename
sudo ./saasvalidate.sh --report my-server-validation

# Generate JSON report
sudo ./saasvalidate.sh --report --report-format json

# Generate both Markdown and JSON reports
sudo ./saasvalidate.sh --report --report-format both
```

### Command-Line Options

- `-m, --check-multipath` - Enable optional check for multipath-tools package presence
- `-r, --report [FILE]` - Generate validation report (default: pcd-validation-report.md)
- `--report-format FORMAT` - Report format: text (Markdown), json, or both (default: text)
- `-h, --help` - Show help message

### Examples

```bash
# Run validation only
sudo ./saasvalidate.sh

# Run with multipath check
sudo ./saasvalidate.sh --check-multipath

# Run and generate text report
sudo ./saasvalidate.sh --report

# Run and generate JSON report for automation
sudo ./saasvalidate.sh --report validation-$(hostname).json --report-format json

# Run with all options
sudo ./saasvalidate.sh --check-multipath --report --report-format both
```

Enable the optional `multipath-tools` check:

```bash
./saasvalidate.sh --check-multipath
# or
./saasvalidate.sh -m
```

Show help:

```bash
./saasvalidate.sh --help
```

## Exit codes

- `0`: All mandatory checks passed
- `1`: One or more mandatory checks failed (script reports failures inline)
- `2`: Invalid arguments

## Output

The script prints each check result and uses a green check for pass, red X for fail, and yellow `!` for warnings.

Warnings do **not** cause a non-zero exit code, but should still be reviewed.

## Notes

- The connectivity checks perform HTTP(S) `HEAD` requests to the documented endpoints. If your environment uses a proxy or restricted egress, you may need to adjust networking or allow-lists.
- The CPU model compatibility check cannot directly map to libvirt/QEMU CPU model names before virtualization packages are installed, so it performs host-signal-based sanity checks and may emit warnings for older/unusual CPUs.
