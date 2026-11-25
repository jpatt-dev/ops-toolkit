# SSH and WinRM connectivity from Ansible

Use this guide when Ansible reports a host as `UNREACHABLE`, or authentication and privilege escalation fail. It covers the Ansible side. For the Windows listener, firewall, and authentication configuration, see [windows/winrm-remote-admin.md](../windows/winrm-remote-admin.md). For the Linux `sshd` side, see [linux/ssh-tls-certificates.md](../linux/ssh-tls-certificates.md).

Separate the layers before changing anything:

1. Name resolution: does the name resolve to the right address?
2. Network: is the port reachable from the node that runs the job?
3. Transport: does SSH or WinRM negotiate?
4. Authentication: is the account accepted?
5. Authorization and privilege escalation: can the account do the work?
6. Python or PowerShell on the target: can the module run?

In AAP, run the network checks from the **execution node** that ran the job, not from your workstation. The job details page shows the execution node.

## Linux and SSH

### Quick checks

```bash
getent hosts host01.example.com                       # resolution as the system sees it, including /etc/hosts
timeout 5 bash -c '</dev/tcp/host01.example.com/22' && echo open   # TCP reachability without extra tools
ssh -vvv -o BatchMode=yes user@host01.example.com true # SSH with the same non-interactive behavior as Ansible
ansible -i inventory host01.example.com -m ansible.builtin.ping -vvvv
```

`BatchMode=yes` makes SSH fail instead of prompting, which is what Ansible does. If a plain `ssh` works but this fails, SSH was prompting for something: a password, a passphrase, or a host key.

### SSH failures

| Message | Layer | Likely cause | Check or fix |
| --- | --- | --- | --- |
| `Could not resolve hostname` | DNS | Name not in DNS or wrong search domain | `getent hosts`; set `ansible_host` |
| `Connection timed out` | Network | Firewall drop, wrong address, or route | Test from the execution node; see [network/connectivity-testing.md](../network/connectivity-testing.md) |
| `Connection refused` | Network/service | Host reachable, nothing listening on the port | `sshd` stopped or on another port; set `ansible_port` |
| `Host key verification failed` | Transport | Unknown or changed host key | Confirm the key out of band. Do not disable checking globally. |
| `Permission denied (publickey,gssapi-keyex,gssapi-with-mic)` | Auth | Key not authorized, wrong user, or password auth disabled | Server `journalctl -u sshd`; `ansible_user`; key in the Machine credential |
| `Permission denied (publickey,password)` with a password | Auth | Wrong password, account locked or expired | Server logs; `chage -l <user>` on the target |
| `no matching host key type found` or `no matching key exchange method found` | Transport | Crypto policy mismatch between client and server | `update-crypto-policies --show` on both sides; see [linux/ssh-tls-certificates.md](../linux/ssh-tls-certificates.md) |
| `Shared connection to ... closed` followed by a module error | Target | The module failed; SSH itself worked | Read the module output above that line |
| `/usr/bin/python: not found` or interpreter discovery warnings | Target | No Python where Ansible looked | Install the platform Python, or set `ansible_python_interpreter` |
| `Timeout (12s) waiting for privilege escalation prompt` | become | Sudo asked for a password that was not supplied, or a custom prompt | Supply the become password in the Machine credential; check `sudo -l` as that user |
| `Missing sudo password` | become | `become: true` with no password and sudo requires one | Same as above |
| `sudo: a password is required` | become | Same as above | Same as above |
| `Failed to set permissions on the temporary files Ansible needs to create when becoming an unprivileged user` | become | `become_user` is not root and ACL tools or a shared temp dir are missing | Install `acl` on the target, or follow the documented `become_user` options |

### SSH connection variables

| Variable | Use |
| --- | --- |
| `ansible_host` | Address to connect to |
| `ansible_port` | SSH port |
| `ansible_user` | Remote user |
| `ansible_ssh_private_key_file` | Key file, when not supplied by a credential |
| `ansible_ssh_common_args` | Extra SSH options, such as a `ProxyJump` |
| `ansible_python_interpreter` | Target Python path |
| `ansible_become_method` | `sudo` by default |

Jump host example:

```yaml
ansible_ssh_common_args: '-o ProxyJump=user@bastion.example.com'
```

## Windows and WinRM

### Quick checks from the Ansible side

```bash
getent hosts win01.example.com
timeout 5 bash -c '</dev/tcp/win01.example.com/5986' && echo open    # HTTPS listener
timeout 5 bash -c '</dev/tcp/win01.example.com/5985' && echo open    # HTTP listener
curl -sS -o /dev/null -w '%{http_code}\n' https://win01.example.com:5986/wsman   # TLS check; any HTTP code means TLS worked
ansible -i inventory win01.example.com -m ansible.windows.win_ping -vvvv
```

An HTTP code such as `405` or `401` from `/wsman` means the TCP connection and TLS handshake succeeded. A certificate error means the execution node does not trust the listener certificate or the name does not match it.

Inside an EE, confirm the Python libraries the connection plugin needs:

```bash
podman run --rm <ee-image> python3 -m pip list 2>/dev/null | grep -Ei 'pywinrm|pypsrp|requests|kerberos|gssapi|ntlm'
```

### Connection variables

Use WinRM over HTTPS (5986) with certificate validation. NTLM and Kerberos also encrypt the message over HTTP, but HTTPS protects every transport and lets you validate the server.

```yaml
# group_vars/windows.yml (no secrets here; the password comes from a Machine credential)
ansible_connection: winrm
ansible_port: 5986
ansible_winrm_scheme: https
ansible_winrm_transport: kerberos            # or ntlm, credssp, certificate
ansible_winrm_server_cert_validation: validate
ansible_winrm_ca_trust_path: /etc/pki/tls/certs/ca-bundle.crt
```

The PSRP connection plugin is an alternative with similar options:

```yaml
ansible_connection: psrp
ansible_port: 5986
ansible_psrp_protocol: https
ansible_psrp_auth: negotiate                 # kerberos with NTLM fallback
ansible_psrp_cert_validation: validate
```

| Transport | Account type | Notes |
| --- | --- | --- |
| `kerberos` | Domain | Requires DNS names that match SPNs, time within skew, `krb5.conf` and Kerberos libraries in the EE. Does not work with an IP address as the host. |
| `ntlm` | Local or domain | Simple to set up. No delegation. Local accounts need admin rights over the network to be allowed. |
| `credssp` | Local or domain | Allows credential delegation for second-hop access. Sends credentials to the server. Use only where required and approved. |
| `certificate` | Local | Maps a client certificate to a local account |
| `basic` | Local | Sends the password with every request. Avoid. Disabled on the service by default. |

### WinRM failures

| Message | Layer | Likely cause | Check or fix |
| --- | --- | --- | --- |
| `Max retries exceeded ... Connection refused` | Network/service | No listener on that port | On the host: `winrm enumerate winrm/config/listener` |
| `Max retries exceeded ... timed out` | Network | Firewall or wrong address | Test port from the execution node; Windows firewall rule for WinRM |
| `certificate verify failed` | TLS | Listener certificate not trusted by the EE, expired, or name mismatch | Check the certificate with `openssl s_client`; add the CA to the EE. Do not set validation to `ignore` as the fix. |
| `the specified credentials were rejected by the server` | Auth | Wrong password, account locked, wrong transport, or local account blocked by remote UAC | Security log event 4625 on the target; see [windows/ad-auth-certificates.md](../windows/ad-auth-certificates.md) |
| `Server not found in Kerberos database` | Kerberos | No SPN for the name used, or connected by IP or alias | Use the FQDN that has an `HTTP/` or `HOST/` SPN; `setspn -Q` |
| `Cannot find KDC for realm` or `Cannot contact any KDC` | Kerberos | `krb5.conf` missing in the EE, wrong realm, or DNS SRV records not resolvable | `krb5.conf` in the EE; `dig _kerberos._tcp.example.com SRV` |
| `Clock skew too great` | Kerberos | Time on node and DC differ by more than the allowed skew (default 5 minutes) | `chronyc tracking` on the node; `w32tm /query /status` on Windows |
| `kerberos: the python kerberos library is not installed` or `requests_kerberos` missing | EE | Library missing from the EE | Add `pywinrm[kerberos]` and the system packages to the EE |
| `winrm or requests is not installed` | EE | `pywinrm` missing | Add `pywinrm` to the EE |
| `ntlm: ... 401 Unauthorized` | Auth | Bad password, or NTLM disabled by policy | Security log on the target; domain NTLM restrictions |
| `Connection reset by peer` or `Bad HTTP response returned from server. Code 500` | Service | WinRM service quota or plugin error, or a proxy between | `Event Viewer > Microsoft-Windows-WinRM/Operational` |
| `0x80070005` or `Access is denied` from a module | Authorization | Account lacks rights, or the operation is blocked in a network logon | Use `become: true` with `become_method: runas` for that task |

### Windows `become`

Some Windows operations refuse to run in a WinRM network logon. Windows Update and some DPAPI or credential-store operations are common examples. Use `become` for those tasks:

```yaml
- name: Search for updates as SYSTEM
  ansible.windows.win_updates:
    state: searched
  become: true
  become_method: runas
  become_user: SYSTEM
```

`ansible.windows.win_updates` already handles this internally in current versions. Your own `win_shell` scripts that call the Windows Update API do not.

## Cautions

- `ansible_winrm_server_cert_validation: ignore` and `ansible_ssh_common_args: -o StrictHostKeyChecking=no` hide man-in-the-middle attacks. Use them only for a short, approved test, never as a default in group vars.
- Do not put `ansible_password` or `ansible_become_password` in inventory files. Use a Machine credential or Vault.
- `-vvvv` output can include usernames, hostnames, and connection arguments. Review it before sharing.
