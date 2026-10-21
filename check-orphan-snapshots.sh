#!/usr/bin/env bash
# Detects orphaned snapshots on the Huawei NAS and VM disks running low on space.
# Scans running virt-launcher pods, reads df and .snapshot for each disk,
# and compares them with the VolumeSnapshotContents in the cluster.
# At the end, prints the removal commands.
#
# Usage: ./check-orphan-snapshots.sh [namespace] [usage_threshold_%]
#   no namespace: all namespaces
#   default threshold: 80
#
# Requirements: oc logged in with exec permission on virt-launcher pods, jq.
# Limitation: only sees running VMs (needs the mount in virt-launcher)
# and disks under /run/kubevirt-private/vmi-disks (hotplug disks are not covered).
# The script does NOT remove anything; it only lists and suggests commands.

set -euo pipefail

NS_FILTER="${1:-}"
THRESHOLD="${2:-80}"

if [[ -n "$NS_FILTER" ]]; then
  NS_ARGS=(-n "$NS_FILTER")
else
  NS_ARGS=(-A)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/vsc_orphans"     # vsc ns vs
: > "$TMP/array_orphans"   # share snapshot ns vm disk

# Snapshot UIDs known to OpenShift (snapcontent-<uid> -> snapshot_<uid> on the array)
KNOWN=$(oc get volumesnapshotcontent -o json \
  | jq -r '.items[].metadata.name' \
  | sed -n 's/^snapcontent-//p' | tr '-' '_' | sort -u)

# 1. VSCs in Retain whose VolumeSnapshot no longer exists
echo "== VSCs in Retain without a VolumeSnapshot (orphans still visible in OpenShift)"
oc get volumesnapshotcontent -o json | jq -r '
  .items[] | select(.spec.deletionPolicy=="Retain")
  | [.metadata.name, .spec.volumeSnapshotRef.namespace, .spec.volumeSnapshotRef.name] | @tsv' \
| while IFS=$'\t' read -r vsc ns vs; do
    if ! oc get volumesnapshot "$vs" -n "$ns" >/dev/null 2>&1; then
      echo "$vsc  (VS $ns/$vs not found)"
      echo "$vsc $ns $vs" >> "$TMP/vsc_orphans"
    fi
  done
[[ -s "$TMP/vsc_orphans" ]] || echo "none"
echo

# 2. Disk usage and orphaned snapshots on the array
echo "== Disks of running VMs"
printf '%-28s %-22s %-8s %6s %6s %5s %6s %7s\n' NAMESPACE VM DISK SIZE USED USE% SNAPS ORPHANS

oc get pods "${NS_ARGS[@]}" -l kubevirt.io=virt-launcher \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.metadata.labels.kubevirt\.io/domain}{"\n"}{end}' \
| while read -r ns pod vm; do
    out=$(oc exec -n "$ns" "$pod" -c compute -- sh -c '
      for d in /run/kubevirt-private/vmi-disks/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        df -P -B1G "$d" | awk -v n="$n" "NR==2{printf \"DF %s %s %s %s %s\n\", n, \$2, \$3, \$5, \$1}"
        ls "$d/.snapshot" 2>/dev/null | sed "s/^/SNAP $n /"
      done' 2>/dev/null) || { echo "$ns/$vm: exec failed" >&2; continue; }

    echo "$out" | awk '$1=="DF"{print $2, $3, $4, $5, $6}' | while read -r disk size used pct src; do
      share=${src##*:/}
      snaps=$(echo "$out" | awk -v d="$disk" '$1=="SNAP" && $2==d {print $3}')
      total=0; orphans=0; orphan_list=""
      for s in $snaps; do
        total=$((total+1))
        uid=${s#snapshot_}
        if ! grep -qx "$uid" <<<"$KNOWN"; then
          orphans=$((orphans+1)); orphan_list+=" $s"
          echo "$share $s $ns $vm $disk" >> "$TMP/array_orphans"
        fi
      done
      printf '%-28s %-22s %-8s %5sG %5sG %5s %6s %7s\n' "$ns" "$vm" "$disk" "$size" "$used" "$pct" "$total" "$orphans"
      if [[ $orphans -gt 0 ]]; then echo "    orphans:$orphan_list"; fi
      p=${pct%\%}
      if [[ $p -ge $THRESHOLD ]]; then echo "    WARNING: usage above ${THRESHOLD}%"; fi
    done
  done
echo

# 3. Removal commands
echo "================ HOW TO REMOVE ================"
echo "Before removing: confirm with the backup team that the corresponding"
echo "backups have already been copied to NetBackup and that no datamover"
echo "is using the snapshot (oc get pods -n backup-netbackup)."
echo

if [[ -s "$TMP/vsc_orphans" ]]; then
  echo "-- Orphans visible in OpenShift (you can remove them yourself):"
  echo "   Switch to Delete and delete the VSC; the Huawei driver removes the snapshot from the array."
  echo
  while read -r vsc ns vs; do
    echo "oc patch volumesnapshotcontent $vsc --type merge -p '{\"spec\":{\"deletionPolicy\":\"Delete\"}}'"
    echo "oc delete volumesnapshotcontent $vsc"
  done < "$TMP/vsc_orphans"
  echo
fi

if [[ -s "$TMP/array_orphans" ]]; then
  echo "-- Orphans on the array only (no object in OpenShift):"
  printf '   %-50s %-50s %s\n' FILESYSTEM SNAPSHOT VM/DISK
  while read -r share snap ns vm disk; do
    printf '   %-50s %-50s %s\n' "$share" "$snap" "$ns/$vm/$disk"
  done < "$TMP/array_orphans"
  echo

  # Sample snapshotHandle per filesystem, used to build the orphans' handles
  oc get volumesnapshotcontent -o json \
    | jq -r '.items[] | select(.status.snapshotHandle != null)
             | [.metadata.name, .status.snapshotHandle] | @tsv' > "$TMP/handles"

  echo "   Option A: remove through OpenShift. Creates a static VS/VSC pair pointing"
  echo "   to the snapshot on the array, with Delete, then deletes the VS; the Huawei"
  echo "   driver removes the snapshot. Check the snapshotHandle before applying."
  echo
  while read -r share snap ns vm disk; do
    orphan_uid=${snap#snapshot_}                  # uid with _
    sample=$(grep -F "$share" "$TMP/handles" | head -1 || true)
    if [[ -z "$sample" ]]; then
      echo "   # $snap: no reference VSC on filesystem $share; use Option B"
      echo
      continue
    fi
    sample_vsc=${sample%%$'\t'*}
    sample_handle=${sample#*$'\t'}
    sample_uid=${sample_vsc#snapcontent-}         # uid with -
    sample_uid_us=${sample_uid//-/_}
    orphan_uid_dash=${orphan_uid//_/-}
    if [[ "$sample_handle" == *"$sample_uid_us"* ]]; then
      handle=${sample_handle//$sample_uid_us/$orphan_uid}
    elif [[ "$sample_handle" == *"$sample_uid"* ]]; then
      handle=${sample_handle//$sample_uid/$orphan_uid_dash}
    else
      echo "   # $snap: unrecognized handle format ($sample_handle); use Option B"
      echo
      continue
    fi
    short=${orphan_uid_dash:0:8}
    cat <<EOF
cat <<'YAML' | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
metadata:
  name: cleanup-vsc-$short
spec:
  deletionPolicy: Delete
  driver: csi.huawei.com
  source:
    snapshotHandle: $handle
  volumeSnapshotRef:
    name: cleanup-vs-$short
    namespace: $ns
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: cleanup-vs-$short
  namespace: $ns
spec:
  source:
    volumeSnapshotContentName: cleanup-vsc-$short
YAML
oc wait volumesnapshot cleanup-vs-$short -n $ns --for=jsonpath='{.status.readyToUse}'=true --timeout=60s
oc delete volumesnapshot cleanup-vs-$short -n $ns

EOF
  done < "$TMP/array_orphans"

  echo "   Option B: the storage team removes them in OceanStor DeviceManager,"
  echo "   using the filesystem and snapshot from the table above."
  echo
fi

if [[ ! -s "$TMP/vsc_orphans" && ! -s "$TMP/array_orphans" ]]; then
  echo "No orphans found."
  echo
fi

echo "After removal, confirm the freed space (may take a few minutes):"
echo "oc exec -n <ns> <virt-launcher-pod> -c compute -- df -h /run/kubevirt-private/vmi-disks/<disk>"
