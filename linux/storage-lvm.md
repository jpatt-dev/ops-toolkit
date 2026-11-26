# Storage, LVM, and filesystems

RHEL 8, 9, and 10. Commands are read-only unless marked `CHANGE`. Storage changes can destroy data. Have a backup and console access before running any of them.

## What is there

```bash
lsblk -f                        # devices, partitions, filesystems, UUIDs, mount points
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
df -hT                          # usage by filesystem with type
df -i                           # inode usage; 100% inodes = "No space left" with free blocks
findmnt                         # mount tree
findmnt -no SOURCE,OPTIONS /var # what backs /var and with which options
cat /etc/fstab
blkid                           # UUIDs and labels
pvs; vgs; lvs                   # LVM summary
lvs -a -o +devices              # which physical devices back each LV
vgdisplay <vg>                  # free extents (Free PE / Size)
multipath -ll                   # SAN multipath state, when used
cat /proc/mdstat                # software RAID, when used
```

## Disk full

1. `df -hT` to find the filesystem. `df -i` for inodes.
2. `du -xh --max-depth=1 /var | sort -h | tail` to find the directory. `-x` stays on one filesystem.
3. `lsof -nP +L1` to find deleted files still held open. Their space is freed only when the process closes them.
4. Common causes: `/var/log`, `/var/lib/containers`, `/var/cache/dnf`, core dumps in `/var/lib/systemd/coredump`, journal size.

Safe cleanups, each `CHANGE`:

```bash
journalctl --vacuum-size=500M             # CHANGE: trims the journal
dnf clean packages                        # CHANGE: removes cached RPMs
podman image prune                        # CHANGE: removes dangling images
```

Do not delete files under `/var/lib/rpm`, `/var/lib/containers/storage` by hand, or open log files with `rm`. Truncate an open log with `: > file` (`CHANGE`) if you must.

## Extend a logical volume

Check first:

```bash
vgs                                       # VFree must be larger than the extension
lvs <vg>/<lv>
findmnt -no FSTYPE /mountpoint            # xfs or ext4
```

Extend and grow the filesystem in one step:

```bash
lvextend -r -L +10G /dev/<vg>/<lv>        # CHANGE: -r resizes the filesystem too
lvextend -r -l +100%FREE /dev/<vg>/<lv>   # CHANGE: use all free space in the VG
```

If the VG has no free space, add a disk:

```bash
pvcreate /dev/sdX                         # CHANGE: destroys data on /dev/sdX
vgextend <vg> /dev/sdX                    # CHANGE
```

Grow a disk that was enlarged in the hypervisor:

```bash
echo 1 > /sys/class/block/sdX/device/rescan   # CHANGE: rescan size
growpart /dev/sdX 2                           # CHANGE: grow partition 2 (cloud-utils-growpart)
pvresize /dev/sdX2                            # CHANGE: grow the PV
```

XFS can grow but cannot shrink. ext4 can shrink only while unmounted.

## Mount failures

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Boot drops to emergency mode | An `/etc/fstab` entry failed | `journalctl -b -p err`; `systemctl --failed`; boot with the entry commented out |
| `mount: wrong fs type, bad option, bad superblock` | Wrong type, missing helper (`nfs-utils`, `cifs-utils`), or corruption | `blkid <dev>`; `dmesg \| tail` |
| `mount: /x: special device UUID=... does not exist` | UUID changed or the disk is missing | `blkid` |
| NFS mount hangs | Server unreachable or firewall | `showmount -e <server>`; `rpcinfo -p <server>`; TCP 2049 |
| Read-only filesystem after errors | Kernel remounted read-only after I/O or metadata errors | `journalctl -k \| grep -Ei 'error\|remount'` |

Validate `/etc/fstab` changes before rebooting:

```bash
findmnt --verify                          # syntax and sanity checks of fstab
mount -a                                  # CHANGE: mounts everything not yet mounted; errors show now, not at boot
systemctl daemon-reload                   # CHANGE: systemd regenerates mount units from fstab
```

Use `nofail` for non-critical mounts, and `_netdev` for network filesystems, so a missing device does not stop the boot.

## Filesystem checks

```bash
xfs_info /mountpoint                      # XFS geometry
xfs_repair -n /dev/<vg>/<lv>              # read-only check; filesystem must be unmounted
tune2fs -l /dev/<dev> | grep -Ei 'state|mount count|last checked'   # ext4
```

`xfs_repair` without `-n` and `fsck` without `-n` modify the filesystem (`CHANGE`). Run them only on unmounted filesystems.

## I/O errors and slow storage

```bash
journalctl -k | grep -Ei 'i/o error|timeout|reset|blk_update_request'
iostat -xz 2 5                            # per-device utilization and latency (sysstat)
```

In `iostat -x`, high `%util` with high `r_await`/`w_await` (milliseconds) means the device is saturated or slow. See [performance-processes.md](performance-processes.md#disk-io).

## Cautions

- Confirm the device name with `lsblk` immediately before any `pvcreate`, `mkfs`, `wipefs`, or partitioning command. Device names can change across reboots.
- Snapshot or back up before resizing.
- A wrong `/etc/fstab` entry can stop the host from booting.
