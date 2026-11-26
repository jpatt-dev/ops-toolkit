# Linux

Troubleshooting references for Red Hat Enterprise Linux 8, 9, and 10. Start with the [cheat sheet](cheatsheet.md) or the [scenarios](rhel-scenarios.md).

| File | Covers |
| --- | --- |
| [cheatsheet.md](cheatsheet.md) | Quick tables for every topic below |
| [rhel-scenarios.md](rhel-scenarios.md) | Step-by-step workflows: service will not start, cannot SSH, disk full, slow host, update failures, boot after patching, time, DNS |
| [rhel-snapshot.sh](rhel-snapshot.sh) | Read-only health snapshot script |
| [system-files-users.md](system-files-users.md) | System information, files and directories, permissions and ownership, users and groups |
| [systemd-journal.md](systemd-journal.md) | systemd services, unit files and drop-ins, `journalctl`, log files |
| [networking-dns-firewalld.md](networking-dns-firewalld.md) | Interfaces and routes, NetworkManager, sockets, host DNS, firewalld |
| [selinux.md](selinux.md) | Reading AVC denials, labels, ports, booleans, containers, permissive mode |
| [packages-dnf-rpm.md](packages-dnf-rpm.md) | RPM queries, repositories, updates, errata, version locks, modules, RHEL 10 changes |
| [storage-lvm.md](storage-lvm.md) | Disk full, LVM extension, mounts and fstab, filesystem checks, I/O errors |
| [performance-processes.md](performance-processes.md) | CPU, memory, disk I/O, process states, limits, `sar` |
| [ssh-tls-certificates.md](ssh-tls-certificates.md) | sshd configuration, system trust store, certificates, crypto policies |
| [podman.md](podman.md) | Podman state, Quadlet, rootless issues, networking, cleanup |

Related: [network/](../network/README.md) for protocol-level troubleshooting, [ansible/connectivity-ssh-winrm.md](../ansible/connectivity-ssh-winrm.md) for Ansible SSH errors.

## Using the snapshot script

```bash
./linux/rhel-snapshot.sh            # full
./linux/rhel-snapshot.sh --brief    # skip process and journal sections
sudo ./linux/rhel-snapshot.sh       # include sections that need root
```

The script only reads. It does not save output. Its output can contain hostnames, addresses, and user names; review it before sharing, and do not save it in this repository.

## Conventions

- Commands are read-only unless marked `CHANGE` (modifies configuration or data) or `RESTART` (restarts or reloads a service).
- Examples use `example.com` names and `192.0.2.0/24` documentation addresses. Replace them with your own at the prompt, not in this repository.
