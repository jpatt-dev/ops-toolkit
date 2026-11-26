# Podman and containers on RHEL

Podman is daemonless. Rootless containers belong to the user who started them; `sudo podman ps` and `podman ps` show different containers. Always check which user you are. Commands are read-only unless marked `CHANGE` or `RESTART`.

AAP containerized installs and Execution Environments run on Podman. For EE-specific checks, see [ansible/collections-and-execution-environments.md](../ansible/collections-and-execution-environments.md).

## State

```bash
podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphRoot}}'   # rootless? where images live
podman ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
podman images
podman system df                          # space used by images, containers, volumes
podman inspect <container> --format '{{.State.Status}} {{.State.ExitCode}} {{.State.Error}}'
podman logs --tail 100 <container>
podman logs --since 10m -f <container>
podman top <container>                    # processes inside
podman stats --no-stream                  # CPU and memory per container
podman port <container>                   # published ports
podman exec -it <container> /bin/sh       # shell inside a running container (if the image has one)
```

## Containers managed by systemd

RHEL 9.2+ and RHEL 10 use Quadlet: `.container` files generate systemd units.

```bash
systemctl --user list-units --type=service | grep -i <name>   # rootless
systemctl status <name>.service                              # rootful
ls ~/.config/containers/systemd/ /etc/containers/systemd/    # Quadlet files
/usr/libexec/podman/quadlet -dryrun -user                    # print generated units and errors (rootless)
journalctl --user -u <name>.service
loginctl show-user <user> -p Linger                          # Linger=yes keeps user services running after logout
```

Rootless user services stop at logout unless lingering is enabled (`loginctl enable-linger <user>`, `CHANGE`).

## Common failures

| Message or symptom | Likely cause | Check or fix |
| --- | --- | --- |
| `Error: initializing source docker://...: reading manifest ...: unauthorized` | Not logged in to the registry as this user | `podman login --get-login <registry>`; login as the user that runs the container |
| `x509: certificate signed by unknown authority` | Registry CA not trusted | Add the CA to the system trust store, or to `/etc/containers/certs.d/<registry>/ca.crt` |
| `short-name resolution enforced but cannot prompt without a TTY` | Image referenced without a registry | Use a fully qualified image name |
| `Error: rootlessport cannot expose privileged port 80` | Rootless containers cannot bind ports below 1024 by default | Publish a high port, or adjust `net.ipv4.ip_unprivileged_port_start` (`CHANGE`, host-wide) |
| `Permission denied` on a bind mount | SELinux label | Add `:Z` or `:z` to the volume (relabels the host directory); see [selinux.md](selinux.md#containers) |
| Files owned by odd UIDs on the host | Rootless user namespace mapping | `podman unshare ls -ln <dir>`; `cat /etc/subuid /etc/subgid` |
| `cannot find UID/GID for user` or `newuidmap` errors | User has no `/etc/subuid` and `/etc/subgid` entries | Add ranges (`CHANGE`), then `podman system migrate` |
| Exit code 137 | Killed by SIGKILL, often OOM | `podman inspect --format '{{.State.OOMKilled}}'`; `journalctl -k \| grep -i oom` |
| Exit code 125, 126, 127 | Podman error, command not executable, command not found | `podman logs`; image entrypoint |
| Container cannot reach the network | DNS inside the container, proxy, or firewall | `podman exec <c> cat /etc/resolv.conf`; `podman exec <c> getent hosts <name>` |
| `no space left on device` | Image storage full | `podman system df`; `df -h $(podman info --format '{{.Store.GraphRoot}}')` |

## Networking

```bash
podman network ls
podman network inspect podman
podman inspect <container> --format '{{json .NetworkSettings.Networks}}'
```

RHEL 9 and 10 use the Netavark network stack. Rootless containers use `pasta` or `slirp4netns` for outbound traffic. A proxy set in the host shell is not inherited unless you pass it with `--env` or set it in `containers.conf`.

## Cleaning up

```bash
podman container prune                    # CHANGE: removes stopped containers
podman image prune                        # CHANGE: removes dangling images
podman image prune -a                     # CHANGE: removes every image not used by a container
podman system reset                       # CHANGE: deletes ALL containers, images, volumes for this user
```

On an AAP node, `prune -a` and `system reset` remove Execution Environments and platform images. Do not run them there without a plan.

## Cautions

- Rootless and rootful storage are separate. An image pulled with `sudo` is not available to the rootless user.
- `podman exec` into a production container can change its state. Prefer `podman logs` and `podman inspect`.
- Registry credentials live in the user's `auth.json`. Do not copy that file into tickets or repositories.
