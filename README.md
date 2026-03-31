# pcd-preinstall-validate

Pre-installation validation script for **Platform9 Private Cloud Director (PCD)** hypervisor hosts.

The script performs a set of mandatory and recommended checks on a host before installing PCD components.

## What it checks

- Host OS is supported (Ubuntu 22.04 LTS or Ubuntu 24.04 LTS)
- Architecture is `x86_64`
- CPU cores (>= 8)
- RAM (>= 16GB)
- Hardware virtualization flags present (`vmx` / `svm`)
- Basic CPU sanity checks (vendor/model info and a minimal instruction set baseline)
- `cloud-init` is disabled (when installed)
- Netplan is not using DHCP and has static addressing configured
- Netplan bond mode sanity (warn/fail if unsupported)
- Fails if SAN-backed storage appears to be presented already (iSCSI sessions, FC-attached LUNs, or multipath maps)
- Swap presence (recommended)
- LVM filter configuration when `lvm2` is installed (recommended)
- Outbound connectivity to required endpoints (via `curl --head`)
- Root filesystem free space check (>= 250GB)
- Optional: `multipath-tools` presence (flag-controlled)

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

```bash
./saasvalidate.sh
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
