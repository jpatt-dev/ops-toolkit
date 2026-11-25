# System information, files, permissions, users, and groups

RHEL 8, 9, and 10. Commands are read-only unless marked `CHANGE`.

## System information

```bash
cat /etc/redhat-release            # RHEL release
hostnamectl                        # hostname, OS, kernel, architecture, virtualization
uname -r                           # running kernel
uptime                             # time since boot and load averages
timedatectl                        # time zone, NTP sync state
chronyc tracking                   # NTP offset and source quality
subscription-manager status        # subscription state (needs root)
subscription-manager repos --list-enabled
lscpu                              # CPU model, sockets, cores, threads
free -h                            # memory and swap
lsblk                              # block devices and mount points
cat /proc/cmdline                  # kernel boot parameters
rpm -q kernel                      # installed kernels
grubby --default-kernel            # kernel used at next boot
last -x reboot shutdown | head     # recent reboots and shutdowns
who -b                             # last boot time
```

| Question | Answer from |
| --- | --- |
| Is a reboot needed after patching? | `dnf needs-restarting -r` (exit code 1 means a reboot is needed) |
| Which services need a restart after an update? | `dnf needs-restarting -s` |
| Running kernel differs from newest installed? | Compare `uname -r` with `rpm -q --last kernel \| head -1` |
| Is time in sync? | `chronyc tracking`: `Leap status : Normal` and a small `System time` offset |

Time drift breaks Kerberos, TLS validity checks, and log correlation. Check it early.

## Files and directories

```bash
ls -lah /path                     # sizes, owners, modes, hidden files
ls -lZ /path                      # with SELinux context
stat /path/file                   # mode, owner, timestamps, inode
file /path/file                   # content type
du -sh /var/* 2>/dev/null | sort -h | tail   # largest directories under /var
find / -xdev -type f -size +500M 2>/dev/null # large files on the root filesystem only
find /etc -mmin -60 -type f       # files changed in the last hour
lsof +D /path 2>/dev/null | head  # processes holding files open under a path (can be slow)
lsof -nP | grep '(deleted)'       # deleted files still held open; they still use disk
readlink -f /path/link            # resolve a symlink fully
```

`df` showing a full filesystem while `du` shows less usage usually means a process holds a deleted file open. Restarting that process (`CHANGE`) releases the space.

## Permissions and ownership

```bash
ls -l /path/file                  # owner, group, mode
namei -l /full/path/to/file       # every directory on the path with its mode; finds the blocking directory
getfacl /path                     # POSIX ACLs; a + after the mode in ls means ACLs exist
id username                       # UID, primary group, supplementary groups
sudo -l -U username               # what sudo allows that user (run as root)
```

Mode bits:

| Bits | File | Directory |
| --- | --- | --- |
| `r` (4) | Read content | List names |
| `w` (2) | Change content | Create, delete, rename entries |
| `x` (1) | Execute | Enter (traverse) |
| setuid `s` on user | Run as file owner | No effect on Linux |
| setgid `s` on group | Run as file group | New files inherit the directory's group |
| sticky `t` | No effect | Only owners can delete their files (`/tmp`) |

"Permission denied" checklist:

1. `namei -l` the full path. Every directory needs `x` for the user.
2. Check the file mode and owner.
3. Check ACLs with `getfacl`.
4. Check SELinux with `ausearch -m AVC -ts recent`. See [selinux.md](selinux.md).
5. Check mount options: `findmnt -no OPTIONS /mountpoint` (`noexec`, `ro`, `nosuid`).
6. Check immutable attributes: `lsattr /path/file` (`i` means immutable).

Changes:

```bash
chown user:group /path/file              # CHANGE
chmod 0640 /path/file                    # CHANGE
setfacl -m u:svcacct:rx /path/dir        # CHANGE: add an ACL entry
restorecon -Rv /path                     # CHANGE: reset SELinux contexts to policy defaults
```

Avoid `chmod -R 777`. It hides the real problem and creates a new security one.

## Users and groups

```bash
getent passwd username            # account from local files, LDAP, or SSSD
getent group groupname
id username
chage -l username                 # password age, expiry, and account expiry
passwd -S username                # status: PS (set), LK (locked), NP (no password)
faillock --user username          # failed login counter (RHEL 8+, pam_faillock)
lastlog -u username               # last login (removed in some newer releases; use `last username`)
last -n 20 username               # recent sessions
loginctl list-sessions
sssctl user-checks username       # SSSD view of a domain user, when sssd-tools is installed
realm list                        # joined domains, when using realmd
```

Login failure checklist:

| Symptom | Check |
| --- | --- |
| Domain user not found | `getent passwd user@example.com`; `systemctl status sssd`; `sssctl domain-status example.com` |
| Correct password rejected | `faillock --user`; `chage -l`; `journalctl -u sshd` and `/var/log/secure` |
| Locked after failures | `faillock --user username` shows the count |
| SSH key login fails | Permissions: `~/.ssh` 0700, `authorized_keys` 0600, home not group-writable; SELinux context on `~/.ssh` |
| `sudo` denied | `sudo -l -U username`; files in `/etc/sudoers.d/`; `journalctl _COMM=sudo` |

Changes:

```bash
faillock --user username --reset         # CHANGE: clear failed-login lock
usermod -aG wheel username               # CHANGE: add to a supplementary group (-a is required, or other groups are removed)
chage -E -1 username                     # CHANGE: remove account expiry
visudo -cf /etc/sudoers.d/example        # validate a sudoers file before it is used
sss_cache -E                             # CHANGE: invalidate the SSSD cache
```

Group changes apply at the next login. Existing sessions keep the old groups.

## Cautions

- `usermod -G` without `-a` replaces all supplementary groups.
- Edit sudoers only with `visudo`. A syntax error can lock everyone out of `sudo`.
- `find /` without `-xdev` crosses into NFS and other mounts and can be slow or hang.
