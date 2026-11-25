# systemd services and journal log analysis

RHEL 8, 9, and 10. Commands are read-only unless marked `CHANGE` or `RESTART`.

## Service state

```bash
systemctl status nginx                     # state, main PID, recent log lines
systemctl is-active nginx; systemctl is-enabled nginx
systemctl --failed                         # every failed unit
systemctl list-units --type=service --state=running
systemctl list-unit-files --state=enabled
systemctl cat nginx                        # unit file plus every drop-in, in load order
systemctl show nginx -p ExecStart -p User -p Restart -p NRestarts -p ActiveEnterTimestamp
systemctl list-dependencies nginx          # what it needs
systemctl list-dependencies --reverse nginx  # what needs it
systemd-analyze verify /etc/systemd/system/example.service   # unit file syntax check
systemd-analyze blame | head               # slowest units at boot
systemd-analyze critical-chain             # boot path that took longest
```

Reading `systemctl status`:

| Field | Meaning |
| --- | --- |
| `Loaded: loaded (...; enabled; preset: ...)` | Unit file found; enabled at boot |
| `Loaded: masked` | Linked to `/dev/null`; cannot start until unmasked |
| `Active: active (running)` | Main process is running |
| `Active: active (exited)` | `Type=oneshot` that completed, normal for some units |
| `Active: failed (Result: exit-code)` | Main process exited non-zero |
| `Active: failed (Result: timeout)` | Did not start or stop within the timeout |
| `Active: failed (Result: start-limit-hit)` | Restarted too often; systemd stopped trying |
| `Active: activating (auto-restart)` | Crashing and being restarted |
| `Main PID: ... (code=exited, status=203/EXEC)` | Executable not found, not executable, or blocked by SELinux |
| `status=200/CHDIR` | `WorkingDirectory` missing or not accessible |
| `status=217/USER` | `User=` does not exist |
| `status=226/NAMESPACE` | Sandboxing option failed, often a path in `ReadWritePaths` that does not exist |

## Service failure workflow

1. `systemctl status <unit>` to see the result code and last lines.
2. `journalctl -u <unit> -b --no-pager | tail -50` for the full start attempt.
3. `systemctl cat <unit>` to see the real `ExecStart`, user, and drop-ins.
4. Run the `ExecStart` command by hand as the service user to see the error directly: `sudo -u <user> <command>`.
5. Check configuration syntax with the application's own test, such as `nginx -t`, `httpd -t`, `sshd -t`, or `haproxy -c -f <file>`.
6. Check SELinux denials: `ausearch -m AVC -ts recent`.
7. Check ports already in use: `ss -ltnp | grep :<port>`.

## Changing services

```bash
systemctl restart nginx                    # RESTART
systemctl reload nginx                     # CHANGE: re-read configuration, if the unit supports it
systemctl enable --now nginx               # CHANGE: enable and start
systemctl reset-failed nginx               # CHANGE: clear failed and start-limit state
systemctl edit nginx                       # CHANGE: creates a drop-in override; never edit vendor files in /usr/lib/systemd
systemctl daemon-reload                    # CHANGE: required after editing unit files by hand
systemctl unmask nginx                     # CHANGE
```

Drop-ins live in `/etc/systemd/system/<unit>.d/*.conf` and override the vendor unit in `/usr/lib/systemd/system/`. To replace a list value such as `ExecStart`, clear it first:

```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/nginx -g 'daemon off;'
```

## Journal

```bash
journalctl -b                              # this boot
journalctl -b -1                           # previous boot (needs persistent journal)
journalctl --list-boots
journalctl -u sshd --since '1 hour ago'
journalctl -u sshd -u sssd --since today    # several units interleaved
journalctl -p err -b                       # priority err and worse this boot
journalctl -p warning --since '2026-01-01 08:00' --until '2026-01-01 09:00'
journalctl -k                              # kernel messages (like dmesg, with timestamps)
journalctl -f -u nginx                     # follow
journalctl _PID=1234                       # one process
journalctl _COMM=sudo                      # by command name
journalctl -o json-pretty -n 1 -u nginx    # all fields of one entry
journalctl -o short-iso-precise            # precise timestamps for correlation
journalctl --disk-usage
```

Priorities: `0 emerg`, `1 alert`, `2 crit`, `3 err`, `4 warning`, `5 notice`, `6 info`, `7 debug`. `-p err` includes 0 through 3.

Persistent journal: with the default `Storage=auto`, journald keeps logs on disk only when `/var/log/journal/` exists. Otherwise logs live in `/run` and `-b -1` returns nothing after a reboot. Check with `ls -d /var/log/journal` and `journalctl --list-boots`.

## Traditional log files

| File | Contents |
| --- | --- |
| `/var/log/messages` | General system messages via rsyslog |
| `/var/log/secure` | Authentication, `sshd`, `sudo` |
| `/var/log/audit/audit.log` | Audit events, including SELinux AVC denials |
| `/var/log/dnf.log`, `/var/log/dnf.rpm.log` | Package transactions |
| `/var/log/cron` | Cron jobs |
| `/var/log/boot.log` | Boot messages from some services |

## Patterns to search for

```bash
journalctl -b | grep -Ei 'oom|out of memory|killed process'      # OOM killer
journalctl -k -b | grep -Ei 'i/o error|blk_update_request|xfs.*error|ext4.*error'   # storage errors
journalctl -b | grep -Ei 'segfault|core dumped'
journalctl -u sshd --since today | grep -Ei 'failed|invalid user'
coredumpctl list                                                  # recorded crashes
```

## Cautions

- `journalctl --vacuum-size` and `--vacuum-time` delete logs (`CHANGE`). Capture what you need first.
- Log output can contain usernames, IP addresses, and tokens passed on command lines. Review before attaching to a ticket.
- Restarting a service with active connections drops them. Prefer `reload` when supported.
