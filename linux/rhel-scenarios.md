# Common RHEL troubleshooting scenarios

Short workflows that go from quick checks to deeper investigation. Each step links to the guide with the detail. Steps are read-only unless marked `CHANGE` or `RESTART`.

Capture a baseline first with [rhel-snapshot.sh](rhel-snapshot.sh). It is read-only and prints to the terminal.

## Service will not start

1. `systemctl status <unit>`: note the `Result:` and `status=` code. See [systemd-journal.md](systemd-journal.md#service-state).
2. `journalctl -u <unit> -b | tail -50`.
3. Run the application's config test (`nginx -t`, `sshd -t`, `httpd -t`).
4. `ss -ltnp | grep :<port>`: is something else on the port?
5. `ausearch -m AVC -ts recent`: SELinux denial? See [selinux.md](selinux.md).
6. Disk full? `df -hT /var /tmp`.
7. After fixing: `systemctl reset-failed <unit>` (`CHANGE`) and `systemctl start <unit>` (`RESTART`).

## Cannot SSH to the host

1. From the client: does the name resolve, and is TCP 22 open? See [network/connectivity-testing.md](../network/connectivity-testing.md).
2. Timeout: network or firewall. Refused: `sshd` down or listening elsewhere.
3. From the console: `systemctl status sshd`, `sshd -t`, `ss -ltnp | grep sshd`.
4. Authentication fails: `journalctl -u sshd --since '15 min ago'`. See [ssh-tls-certificates.md](ssh-tls-certificates.md#ssh-server).
5. Account issues: `faillock --user <u>`, `chage -l <u>`, `getent passwd <u>`. See [system-files-users.md](system-files-users.md#users-and-groups).

## Filesystem full

1. `df -hT` and `df -i`.
2. `du -xh --max-depth=1 <mount> | sort -h | tail`.
3. `lsof -nP +L1` for deleted-but-open files.
4. Clean the specific cause. See [storage-lvm.md](storage-lvm.md#disk-full).
5. Extend the LV if growth is legitimate. See [storage-lvm.md](storage-lvm.md#extend-a-logical-volume).

## Host is slow

1. `uptime`, `vmstat 2 5`. Is it CPU (`us`/`sy`), I/O (`wa`, `b`), memory (`si`/`so`), or steal (`st`)?
2. Top consumers: `ps ... --sort=-%cpu` and `--sort=-rss`.
3. I/O: `iostat -xz 2 5`, `pidstat -d 2 5`.
4. Memory: `free -h`, OOM messages in `journalctl -k`.
5. History: `sar -u`, `sar -r`, `sar -q` for when it started.
6. See [performance-processes.md](performance-processes.md).

## Package update fails

1. Read the first error line. Look it up in [packages-dnf-rpm.md](packages-dnf-rpm.md#common-failures).
2. `subscription-manager status` and `dnf repolist`.
3. `curl -v <repo-url>` for network, proxy, and TLS.
4. `df -h / /var`.
5. Another transaction running? `ps -ef | grep -E 'dnf|rpm'`.

## Host does not boot after patching

1. From the console, pick the previous kernel in the GRUB menu.
2. Once up: `journalctl -b -1 -p err` for the failed boot.
3. `/etc/fstab` errors are common: `findmnt --verify`.
4. Set the working kernel as default if needed: `grubby --set-default /boot/vmlinuz-<version>` (`CHANGE`).
5. Collect `sosreport` (`CHANGE`: writes an archive) for a support case. It contains host details; handle it as sensitive.

## Time is wrong

1. `timedatectl`: `System clock synchronized: yes`?
2. `chronyc tracking` and `chronyc sources -v`: reachable sources, offset.
3. UDP 123 to the time servers allowed?
4. `chronyc makestep` (`CHANGE`) steps the clock immediately. Large jumps can upset running applications.

## DNS works for some names, not others

1. `getent hosts <name>` vs `dig <name> +short`.
2. `/etc/resolv.conf` search domains and nameservers.
3. `dig @<each nameserver> <name>`: do the servers agree?
4. See [network/dns.md](../network/dns.md).

## Host cannot reach an HTTPS API

Follow [network/workflows.md](../network/workflows.md#server-cannot-reach-an-api-endpoint). Check the system trust store if TLS fails: [ssh-tls-certificates.md](ssh-tls-certificates.md#system-trust-store).

## After an Ansible patch run: reboot needed?

```bash
dnf needs-restarting -r; echo "exit=$?"     # 1 = reboot required
dnf needs-restarting -s                     # services to restart
```

In a playbook, register the command result and check `rc == 1`. Do not treat `rc == 1` as a task failure: set `failed_when: needs_restarting.rc not in [0, 1]`.
