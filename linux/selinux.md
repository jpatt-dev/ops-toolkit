# SELinux troubleshooting

SELinux denials look like ordinary permission errors. Check for them whenever something fails with "Permission denied" while file modes look correct. Commands are read-only unless marked `CHANGE`.

## Is SELinux involved?

```bash
getenforce                          # Enforcing, Permissive, or Disabled
sestatus                            # mode, policy, and config file mode
ausearch -m AVC,USER_AVC -ts recent # denials in the last 10 minutes (needs root and auditd)
ausearch -m AVC -ts today -c httpd  # denials for one command
journalctl -t setroubleshoot --since today   # human-readable analysis, if setroubleshoot-server is installed
sealert -l '*'                       # all setroubleshoot alerts with suggested fixes
```

No AVC lines while the failure reproduces means SELinux is probably not the cause. Some denials are hidden by `dontaudit` rules; `semodule -DB` (`CHANGE`) disables those temporarily, and `semodule -B` restores them.

## Read an AVC denial

```text
type=AVC msg=audit(...): avc:  denied  { read } for  pid=1234 comm="httpd"
  name="index.html" dev="dm-0" ino=5678
  scontext=system_u:system_r:httpd_t:s0
  tcontext=unconfined_u:object_r:user_home_t:s0
  tclass=file permissive=0
```

| Field | Meaning |
| --- | --- |
| `{ read }` | The permission that was denied |
| `comm` | The process name |
| `scontext` type `httpd_t` | The process domain |
| `tcontext` type `user_home_t` | The file label. Here it is wrong for web content. |
| `tclass=file` | Object class: `file`, `dir`, `tcp_socket`, `process` |
| `permissive=0` | The access was blocked. `1` means logged but allowed. |

Most real-world denials are one of three things: a wrong file label, a non-standard port, or a boolean that is off.

## Wrong file labels

```bash
ls -Z /var/www/html/index.html                # current label
matchpathcon /var/www/html/index.html         # label the policy expects
semanage fcontext -l | grep '/srv/web'        # custom path rules
restorecon -Rvn /var/www/html                 # dry run: what restorecon would change
```

Files moved with `mv` keep their original label. Files copied with `cp` get the destination's default label. This is why content moved from a home directory fails.

Fixes:

```bash
restorecon -Rv /var/www/html                                   # CHANGE: reset to policy defaults
semanage fcontext -a -t httpd_sys_content_t '/srv/web(/.*)?'   # CHANGE: add a rule for a custom path
restorecon -Rv /srv/web                                        # CHANGE: apply the new rule
```

Use `semanage fcontext` plus `restorecon` rather than `chcon`. A relabel or `restorecon` reverts `chcon` changes.

## Ports

```bash
semanage port -l | grep -w http_port_t        # ports a web server may bind
semanage port -l | grep 8443
```

```bash
semanage port -a -t http_port_t -p tcp 8081   # CHANGE: allow httpd to bind 8081
```

If the port already belongs to another type, use `-m` instead of `-a` to modify it.

## Booleans

```bash
getsebool -a | grep httpd                     # current values
semanage boolean -l | grep httpd_can_network_connect   # with descriptions
```

Common ones:

| Boolean | Allows |
| --- | --- |
| `httpd_can_network_connect` | Web server outbound connections to any port (reverse proxy) |
| `httpd_can_network_connect_db` | Web server connections to database ports |
| `haproxy_connect_any` | HAProxy connections to any port |
| `httpd_use_nfs` | Web server reading content on NFS |
| `use_nfs_home_dirs` | Home directories on NFS |
| `container_manage_cgroup` | Containers that manage cgroups (systemd in containers) |

```bash
setsebool -P httpd_can_network_connect on    # CHANGE: -P makes it persistent
```

## Containers

Rootless and rootful Podman volumes need a label the container can read. The `:Z` (private) or `:z` (shared) volume option relabels the host directory:

```bash
podman run -v /srv/data:/data:Z <image>       # CHANGE: relabels /srv/data
```

Do not use `:Z` on system directories such as `/home` or `/etc`. It relabels them for the container and breaks the host.

## Custom policy as a last resort

```bash
ausearch -m AVC -ts recent | audit2why             # explains why, and often names a boolean
ausearch -m AVC -c myapp -ts today | audit2allow -m myapp   # shows the rules a module would add
```

Read `audit2allow` output before installing anything. If it allows broad access such as `file read` on `user_home_t`, the real fix is a label, not a policy module.

```bash
ausearch -m AVC -c myapp -ts today | audit2allow -M myapp   # CHANGE: writes myapp.pp
semodule -i myapp.pp                                       # CHANGE: installs the module
```

## Permissive mode for diagnosis

```bash
semanage permissive -a httpd_t     # CHANGE: one domain permissive; the rest stays enforcing
semanage permissive -d httpd_t     # CHANGE: revert
setenforce 0                       # CHANGE: whole system permissive until reboot or setenforce 1
```

Use per-domain permissive mode to confirm SELinux is the cause, collect all denials, then fix them and revert. Do not leave a system permissive. Do not disable SELinux. Re-enabling it later requires a full relabel.

## Cautions

- `setenforce 0` lowers security for the whole host. Record it and revert it.
- `chcon` changes are temporary and are undone by a relabel.
- A policy module generated from one failure can allow far more than needed. Review it.
