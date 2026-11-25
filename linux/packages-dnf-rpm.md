# DNF and RPM package management

RHEL 8, 9, and 10. Commands are read-only unless marked `CHANGE`. Most need root.

## What is installed

```bash
rpm -q openssl                          # installed version, or "not installed"
rpm -qa --last | head                   # most recently installed packages
rpm -qi openssl                         # package details: vendor, build date, signature
rpm -ql openssl | head                  # files owned by a package
rpm -qf /usr/bin/curl                   # which package owns a file
rpm -q --changelog openssl | head -30   # changelog, includes CVE fixes
rpm -V openssl                          # verify files against the package database
dnf list installed 'kernel*'
dnf info openssl
dnf repoquery --installed --whatrequires openssl | head
```

`rpm -V` output codes: `S` size, `5` checksum, `M` mode, `U` user, `G` group, `T` mtime, `c` config file. A changed config file (`c`) is often expected. A changed binary is not.

## Repositories

```bash
dnf repolist                             # enabled repositories
dnf repolist -v | less                   # with URLs and package counts
dnf repoinfo <repo-id>
subscription-manager repos --list-enabled
subscription-manager status
cat /etc/dnf/dnf.conf                    # global options, including proxy and excludes
ls /etc/yum.repos.d/
```

## Updates

```bash
dnf check-update                         # exit code 100 means updates are available
dnf updateinfo summary                   # security, bugfix, and enhancement advisories
dnf updateinfo list --security
dnf updateinfo info RHSA-YYYY:NNNN       # one advisory
dnf upgrade --security --assumeno        # show what a security update would do, then answer no
dnf history                              # past transactions
dnf history info <id>                    # what one transaction changed
dnf needs-restarting -r                  # exit 1 means a reboot is needed
```

Changes:

```bash
dnf upgrade --security                   # CHANGE
dnf upgrade openssl                      # CHANGE
dnf install <pkg>                        # CHANGE
dnf history undo <id>                    # CHANGE: reverse a transaction, if older versions are still available
dnf clean all                            # CHANGE: drops cached metadata and packages
dnf makecache                            # CHANGE: refreshes metadata
```

## Version locks and excludes

```bash
dnf versionlock list                     # needs python3-dnf-plugin-versionlock
grep -i exclude /etc/dnf/dnf.conf /etc/yum.repos.d/*.repo
```

An `exclude=` or a version lock makes packages silently "not available." Check both when an expected update does not appear.

## Modules (RHEL 8 and 9)

Application Streams in RHEL 8 and 9 can use modules.

```bash
dnf module list                          # streams; [e] enabled, [d] default, [i] installed
dnf module list --enabled
```

An enabled module stream hides packages from other streams. `No match for argument` for a package you know exists can mean a different stream is enabled.

### RHEL 10 differences

- Modularity is deprecated and no modular content ships with RHEL 10. `dnf module` prints a deprecation warning.
- DNF no longer downloads `filelists` metadata by default. A third-party package with a file-path dependency can fail to resolve; the error hints at `--setopt=optional_metadata_types=filelists`.
- RPM verifies signatures with Sequoia PGP. Packages or keys that rely on old algorithms can fail signature checks that passed on RHEL 9.

## Common failures

| Message | Likely cause | Check |
| --- | --- | --- |
| `Curl error (6): Couldn't resolve host name` | DNS from the host | `getent hosts <repo-host>` |
| `Curl error (7): Failed to connect` or `(28): Timeout was reached` | Network, proxy, or firewall | `curl -v <repo-url>`; `proxy=` in `dnf.conf` |
| `Curl error (60): SSL peer certificate or SSH remote key was not OK` | TLS trust, often a TLS-inspecting proxy | See [ssh-tls-certificates.md](ssh-tls-certificates.md#system-trust-store) |
| `Status code: 403` from the CDN | Subscription not attached, expired, or repo not entitled | `subscription-manager status`; `subscription-manager refresh` (`CHANGE`) |
| `This system is not registered with an entitlement server` | Host not registered | `subscription-manager identity` |
| `Error: Failed to download metadata for repo` | Repo URL wrong or unreachable, or stale cache | `dnf repolist -v`; `dnf clean metadata` (`CHANGE`) |
| `No match for argument: <pkg>` | Package not in enabled repos, excluded, or hidden by a module stream | `dnf --showduplicates list <pkg>`; excludes; module streams |
| `nothing provides <dep> needed by <pkg>` | Dependency not in enabled repos | Enable the right repo, or a mix of releases is configured |
| `package <a> conflicts with <b>` | Two packages own the same file or capability | `dnf install --allowerasing` (`CHANGE`) shows removals; review carefully |
| `Transaction check error: installing package ... needs X MB on the / filesystem` | Disk space | `df -h /` and `/var/cache/dnf` |
| `rpmdb: ...` or `Error: rpmdb open failed` | Corrupted or locked RPM database | Check for another running `dnf` or `rpm`; `rpm --rebuilddb` (`CHANGE`) only after backup |
| `GPG check FAILED` or `public key for <pkg> is not installed` | Package signature or key missing | Import the vendor key from a trusted source. Do not set `gpgcheck=0`. |
| `Waiting for process with pid ... to finish` | Another dnf transaction is running, often automatic updates | `ps -ef \| grep -E 'dnf\|rpm'` |

## Satellite and local mirrors

Hosts registered to Red Hat Satellite get content from content views. A package missing on the host but present on the CDN usually means the content view version does not include it yet. Check the host's lifecycle environment and content view in Satellite. `subscription-manager identity` and `/etc/rhsm/rhsm.conf` show which server the host uses.

## Cautions

- `dnf upgrade` with no arguments updates everything, including the kernel.
- `--allowerasing` and `--nobest` can remove or downgrade packages. Read the transaction summary.
- Do not disable GPG checks to get past a signature error.
