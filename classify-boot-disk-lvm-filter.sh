#!/usr/bin/env bash
#
# classify-boot-disk-lvm-filter.sh
#
# Classifies the disk backing the root volume as multipath SAN or local, then
# writes the appropriate LVM device filter into /etc/lvm/lvm.conf:
#
#   multipath SAN -> filter = global_filter = [ "a|^/dev/mapper/|", "r|.*|" ]
#   local disk    -> filter = global_filter = [ "a|^/dev/<rootdisk>|", "r|.*|" ]
#
# Safe by default:
#   * DRY-RUN unless --apply (just classifies and prints the proposed filter)
#   * tests the candidate filter against the live root VG BEFORE writing
#   * backs up lvm.conf, re-verifies after writing, auto-rolls-back on failure
#   * NEVER reboots; only rebuilds the initramfs if you pass --rebuild-initramfs
#
# Usage:
#   sudo ./classify-boot-disk-lvm-filter.sh                      # dry-run
#   sudo ./classify-boot-disk-lvm-filter.sh --apply              # write filter (backup + verify)
#   sudo ./classify-boot-disk-lvm-filter.sh --apply --rebuild-initramfs
#
set -euo pipefail

LVM_CONF=/etc/lvm/lvm.conf
APPLY=0
REBUILD=0

for arg in "$@"; do
  case "$arg" in
    --apply)             APPLY=1 ;;
    --rebuild-initramfs) REBUILD=1 ;;
    -h|--help)           grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$LVM_CONF" ]    || die "$LVM_CONF not found"

# --- 1. locate the device(s) backing root ---------------------------------
root_src=$(findmnt -no SOURCE / 2>/dev/null) || die "cannot determine root source"
log "Root source:        $root_src"

vg=""
declare -a root_pvs=()
if lvs "$root_src" >/dev/null 2>&1; then
  vg=$(lvs --noheadings -o vg_name "$root_src" | tr -d '[:space:]')
  log "Root volume group:  $vg"
  while read -r pv; do [ -n "$pv" ] && root_pvs+=("$pv"); done \
    < <(pvs --noheadings -o pv_name -S vg_name="$vg" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
else
  log "Root is NOT on LVM (direct partition) -> the LVM filter does not gate this host's boot."
  root_pvs+=("$root_src")
fi
[ "${#root_pvs[@]}" -gt 0 ] || die "could not resolve any PV backing root"
log "Root PV(s):         ${root_pvs[*]}"

# --- 2. classify each PV: multipath SAN vs local ---------------------------
# Walks the device dependency chain (lsblk -s) and looks for a multipath layer
# or an fc/iscsi transport (SAN) vs sata/sas/nvme/ata/usb (local).
classify_pv() {
  local pv="$1" base chain tran is_mpath=0 is_san=0
  base=$(basename "$pv")

  # /dev/mapper/* PV is already a multipath/dm device -> SAN by construction
  case "$pv" in
    /dev/mapper/*|/dev/dm-*) is_mpath=1 ;;
  esac

  # Walk the dependency chain downward to the backing disk(s).
  chain=$(lsblk -s -rno NAME,TYPE "$pv" 2>/dev/null || true)
  if printf '%s\n' "$chain" | awk '{print $2}' | grep -qi '^mpath$'; then
    is_mpath=1
  fi

  # Transport of the underlying disk(s): fc/iscsi => SAN.
  while read -r disk; do
    [ -n "$disk" ] || continue
    tran=$(lsblk -dno TRAN "/dev/$disk" 2>/dev/null | tr -d '[:space:]')
    case "$tran" in
      fc|iscsi|fcoe) is_san=1 ;;
    esac
  done < <(printf '%s\n' "$chain" | awk '$2=="disk"{print $1}')

  # Cross-check against the multipath WWID table: if the WWID is claimed by
  # multipathd, LVM must use /dev/mapper, not the raw /dev/sdX paths.
  if [ "$is_mpath" -eq 0 ] && command -v multipath >/dev/null 2>&1; then
    if multipath -ll 2>/dev/null | grep -q .; then
      while read -r disk; do
        [ -n "$disk" ] || continue
        local wwid
        wwid=$(/lib/udev/scsi_id -g -u -d "/dev/$disk" 2>/dev/null || true)
        if [ -n "$wwid" ] && grep -qF "$wwid" /etc/multipath/wwids 2>/dev/null; then
          is_mpath=1; is_san=1
        fi
      done < <(printf '%s\n' "$chain" | awk '$2=="disk"{print $1}')
    fi
  fi

  if [ "$is_mpath" -eq 1 ] || [ "$is_san" -eq 1 ]; then
    echo san
  else
    echo local
  fi
}

verdict=local
declare -a local_disks=()
for pv in "${root_pvs[@]}"; do
  c=$(classify_pv "$pv")
  log "  $pv -> $c"
  if [ "$c" = "san" ]; then
    verdict=san
  else
    # remember the backing local disk for the accept anchor
    while read -r disk; do
      [ -n "$disk" ] && local_disks+=("/dev/$disk")
    done < <(lsblk -s -rno NAME,TYPE "$pv" 2>/dev/null | awk '$2=="disk"{print $1}')
  fi
done
log "Classification:     $verdict"

# --- 3. build the candidate filter ----------------------------------------
if [ "$verdict" = "san" ]; then
  FILTER='[ "a|^/dev/mapper/|", "r|.*|" ]'
else
  # de-dupe the local disk list and build an accept entry per disk
  declare -A seen=()
  accepts=""
  for d in "${local_disks[@]}"; do
    [ -n "${seen[$d]:-}" ] && continue
    seen[$d]=1
    accepts="${accepts}\"a|^${d}|\", "
  done
  [ -n "$accepts" ] || accepts='"a|^/dev/sda|", '
  FILTER="[ ${accepts}\"r|.*|\" ]"
fi
log ""
log "Proposed filter / global_filter:"
log "    $FILTER"

# --- 4. test the candidate filter against the live root VG BEFORE writing --
# --config applies the filter in-memory only; nothing is written to disk yet.
test_filter() {
  local f="$1"
  if [ -n "$vg" ]; then
    vgs --config "devices { filter = $f global_filter = $f }" \
        --noheadings -o vg_name "$vg" 2>/dev/null \
      | tr -d '[:space:]' | grep -qx "$vg"
  else
    # root not on LVM: just confirm the candidate parses
    lvm dumpconfig --config "devices { filter = $f global_filter = $f }" \
        devices/filter >/dev/null 2>&1
  fi
}

log ""
if test_filter "$FILTER"; then
  log "Pre-write test:     PASS (root VG '${vg:-<none>}' resolves under candidate filter)"
else
  die "Pre-write test FAILED: candidate filter hides the root VG. Refusing to write."
fi

# --- 5. dry-run stops here -------------------------------------------------
if [ "$APPLY" -ne 1 ]; then
  log ""
  log "DRY-RUN. Re-run with --apply to write the filter to $LVM_CONF."
  exit 0
fi

# --- 6. back up, write, re-verify, auto-rollback ---------------------------
ts=$(date +%Y%m%d-%H%M%S)
backup="${LVM_CONF}.bak.${ts}"
cp -a "$LVM_CONF" "$backup"
log ""
log "Backup written:     $backup"

# Replace existing filter/global_filter lines (commented or not) in the
# devices { } stanza; insert if absent. Keep both identical on SAN hosts.
write_filter() {
  local f="$1"
  python3 - "$LVM_CONF" "$f" <<'PY'
import re, sys
path, flt = sys.argv[1], sys.argv[2]
src = open(path).read()
def sub_or_insert(text, key, value):
    pat = re.compile(r'^\s*#?\s*%s\s*=.*$' % re.escape(key), re.M)
    line = "\t%s = %s" % (key, value)
    if pat.search(text):
        return pat.sub(line, text, count=1)
    # insert just inside the devices { } block
    return re.sub(r'(devices\s*\{)', r'\1\n' + line, text, count=1)
for key in ("filter", "global_filter"):
    src = sub_or_insert(src, key, flt)
open(path, "w").write(src)
PY
}
write_filter "$FILTER"
log "Filter written to $LVM_CONF (filter and global_filter set identical)."

# Re-verify against the on-disk config (no --config override this time).
if [ -n "$vg" ]; then
  if pvs >/dev/null 2>&1 && vgs --noheadings -o vg_name "$vg" 2>/dev/null \
       | tr -d '[:space:]' | grep -qx "$vg"; then
    log "Post-write verify:  PASS (root VG '$vg' resolves with on-disk config)"
  else
    log "Post-write verify:  FAIL -> rolling back"
    cp -a "$backup" "$LVM_CONF"
    die "Root VG stopped resolving after write. Restored $LVM_CONF from $backup."
  fi
else
  log "Post-write verify:  root not on LVM; nothing further to check."
fi

# --- 7. optional initramfs rebuild ----------------------------------------
# The boot-time filter lives in the initramfs, not just on disk. Without this
# rebuild a SAN host can still boot non-deterministically.
if [ "$REBUILD" -eq 1 ]; then
  log ""
  log "Rebuilding initramfs for all installed kernels..."
  update-initramfs -u -k all
  log "Done. Verify the filter landed in each image before rebooting, e.g.:"
  log "    for i in /boot/initrd.img-*; do echo \"== \$i\"; \\"
  log "      lsinitramfs \"\$i\" | grep -E 'lvm/lvm.conf|multipath' ; done"
else
  log ""
  log "NOTE: initramfs NOT rebuilt. On a boot-from-SAN host the boot-time filter"
  log "      lives in the initramfs. Re-run with --rebuild-initramfs (or run"
  log "      'update-initramfs -u -k all' manually) before the next reboot."
fi

log ""
log "Complete. No reboot performed."