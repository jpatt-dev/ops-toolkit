# RHEL cheat sheet

RHEL 8, 9, and 10. Read-only unless marked `CHANGE` or `RESTART`. Details are in the linked guides.

## First two minutes

| Check | Command | What to look for |
| --- | --- | --- |
| Snapshot | `./rhel-snapshot.sh --brief` | Anything marked `!`, failed units, reboot needed |
| Release and kernel | `cat /etc/redhat-release; uname -r` | Expected major/minor release |
| Uptime and load | `uptime` | Recent reboot; load vs CPU count |
| Failed services | `systemctl --failed` | Any unit listed |
| Errors this boot | `journalctl -b -p err -n 50` | Repeating errors |
| Disk and inodes | `df -hT; df -i` | 90%+ |
| Memory | `free -h` | Low `available`, swap in use |
| Time | `chronyc tracking` | Large offset, `Leap status` not Normal |

## Services and logs

| Problem | Command | What to look for |
| --- | --- | --- |
| Why did it fail | `systemctl status <unit>` | `Result:` and `status=` code |
| Full start log | `journalctl -u <unit> -b` | First error line |
| Real unit config | `systemctl cat <unit>` | Drop-ins overriding `ExecStart`, `User` |
| Boot slow | `systemd-analyze blame` | Units taking minutes |
| Previous boot | `journalctl -b -1 -p err` | Needs persistent journal |
| OOM kills | `journalctl -k \| grep -i 'killed process'` | Victim and memory |
| `RESTART` | `systemctl restart <unit>` | Drops connections |
| `CHANGE` | `systemctl reset-failed <unit>` | Clears start-limit state |

## Permissions, users, SELinux

| Problem | Command | What to look for |
| --- | --- | --- |
| Which directory blocks access | `namei -l /full/path` | Missing `x` on a directory |
| ACLs | `getfacl <path>` | Extra entries |
| SELinux denial | `ausearch -m AVC -ts recent` | `scontext`, `tcontext`, `{ perm }` |
| Expected label | `matchpathcon <path>` vs `ls -Z <path>` | Mismatch |
| Port label | `semanage port -l \| grep <port>` | Port missing for the service type |
| Booleans | `getsebool -a \| grep <svc>` | Required boolean off |
| Locked account | `faillock --user <u>`; `chage -l <u>` | Failure count; expiry |
| sudo rights | `sudo -l -U <u>` | Missing rule |
| `CHANGE` | `restorecon -Rv <path>` | Resets labels |

## Network

| Problem | Command | What to look for |
| --- | --- | --- |
| Addresses | `ip -br addr` | Interface `UP` with the expected address |
| Path to a host | `ip route get <ip>` | Interface and source address |
| Listening | `ss -ltnp` | Service bound to `0.0.0.0`/`[::]`, not `127.0.0.1` |
| Name resolution | `getent hosts <name>` vs `dig <name> +short` | Differences: `/etc/hosts` or search domain |
| Firewall zone | `firewall-cmd --get-active-zones; firewall-cmd --list-all` | Port/service allowed in the right zone |
| TCP port reachable | `timeout 5 bash -c '</dev/tcp/<host>/<port>' && echo open` | Open, refused, or timeout |
| `CHANGE` | `firewall-cmd --add-port=<p>/tcp` | Runtime only until `--permanent` |

## Packages

| Problem | Command | What to look for |
| --- | --- | --- |
| Installed version | `rpm -q <pkg>` | Version and release |
| Who owns a file | `rpm -qf <file>` | Package name |
| Available updates | `dnf check-update` | Exit code 100 = updates |
| Security advisories | `dnf updateinfo list --security` | RHSA IDs |
| Recent changes | `dnf history`; `rpm -qa --last \| head` | What changed before the problem |
| Reboot needed | `dnf needs-restarting -r` | Exit code 1 |
| Repos | `dnf repolist`; `subscription-manager status` | Missing repo; subscription state |
| `CHANGE` | `dnf upgrade --security` | Updates packages |

## Storage

| Problem | Command | What to look for |
| --- | --- | --- |
| Layout | `lsblk -f` | Devices, filesystems, mounts |
| LVM free space | `vgs` | `VFree` |
| Biggest directories | `du -xh --max-depth=1 <mnt> \| sort -h \| tail` | Growth location |
| Deleted but open | `lsof -nP +L1` | Large `SIZE` held by a process |
| fstab valid | `findmnt --verify` | Errors before reboot |
| I/O latency | `iostat -xz 2 5` | `r_await`/`w_await`, `%util` |
| `CHANGE` | `lvextend -r -L +10G /dev/<vg>/<lv>` | Grows LV and filesystem |

## Performance and processes

| Problem | Command | What to look for |
| --- | --- | --- |
| What kind of busy | `vmstat 2 5` | `r`, `b`, `wa`, `si/so`, `st` |
| Per CPU | `mpstat -P ALL 2 3` | One CPU pinned |
| Top CPU | `ps -eo pid,user,%cpu,cmd --sort=-%cpu \| head` | Runaway process |
| Top memory | `ps -eo pid,user,rss,cmd --sort=-rss \| head` | Growth over time |
| By service | `systemd-cgtop` | Which unit or container |
| Open files limit | `cat /proc/<pid>/limits` | `Max open files` |
| History | `sar -u`, `sar -r`, `sar -q` | When it started |

## TLS, SSH, containers

| Problem | Command | What to look for |
| --- | --- | --- |
| sshd effective config | `sshd -T` | `passwordauthentication`, `allowusers` |
| sshd syntax | `sshd -t` | Errors before reload |
| CA trusted? | `trust list \| grep -i <name>` | Anchor present |
| Cert details | `openssl x509 -in c.pem -noout -subject -issuer -dates -ext subjectAltName` | Expiry, SAN |
| Crypto policy | `update-crypto-policies --show` | `DEFAULT` vs `LEGACY`/`FIPS` |
| Containers | `podman ps -a` (as the right user) | Exited containers, restarts |
| Container log | `podman logs --tail 100 <c>` | Error lines |
| `CHANGE` | `update-ca-trust` after adding an anchor | Rebuilds bundles |
