# SSH server, certificates, trust store, and crypto policies on RHEL

Host-side SSH and TLS configuration. For client-side TLS debugging with `openssl s_client` and `curl`, see [network/tls-openssl.md](../network/tls-openssl.md). For Ansible SSH errors, see [ansible/connectivity-ssh-winrm.md](../ansible/connectivity-ssh-winrm.md). Commands are read-only unless marked `CHANGE` or `RESTART`.

## SSH server

```bash
systemctl status sshd
ss -ltnp | grep sshd                     # listening address and port
sshd -t                                  # configuration syntax test (root)
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|allowgroups|kexalgorithms|hostkeyalgorithms|ciphers|macs) '
sshd -T -C user=deploy,host=client.example.com,addr=192.0.2.20   # effective settings for one client, including Match blocks
ls /etc/ssh/sshd_config.d/               # drop-ins; read before sshd_config on RHEL 9 and later
journalctl -u sshd --since '1 hour ago'
```

`sshd -T` prints the effective configuration after includes and defaults. It is more reliable than reading `sshd_config`, because the first value set for a keyword wins and drop-ins are read first.

Server-side log messages:

| Message | Meaning |
| --- | --- |
| `Invalid user x from 192.0.2.20` | Account does not exist |
| `Failed password for x` | Wrong password, or account locked |
| `Authentication refused: bad ownership or modes for directory /home/x/.ssh` | `~/.ssh` or home is group- or world-writable |
| `User x from ... not allowed because not listed in AllowUsers` | `AllowUsers` or `AllowGroups` excludes the account |
| `Connection closed by authenticating user x ... [preauth]` | Client gave up, often no acceptable key |
| `userauth_pubkey: signature algorithm ssh-rsa not in PubkeyAcceptedAlgorithms` | Client offered an RSA key with SHA-1 signatures, refused by policy |
| `fatal: Timeout before authentication` | Client stalled, often slow DNS reverse lookup on the server or a network problem |

Key file permissions that `sshd` accepts by default (`StrictModes yes`): home directory not writable by group or others; `~/.ssh` mode `0700`; `authorized_keys` mode `0600`; all owned by the user. On SELinux hosts, `restorecon -Rv ~/.ssh` (`CHANGE`) fixes wrong labels.

Changes:

```bash
sshd -t && systemctl reload sshd         # CHANGE: test, then reload without dropping sessions
```

Keep an existing session open while changing SSH configuration, and test a new login before closing it.

## System trust store

RHEL uses a shared system trust store. Most tools use it: `curl`, `dnf`, `openssl`, Python from RHEL packages, and Podman.

```bash
trust list | grep -i -A2 'label: example'   # is a CA anchored?
ls /etc/pki/ca-trust/source/anchors/        # locally added CAs
openssl x509 -in /etc/pki/ca-trust/source/anchors/internal-ca.crt -noout -subject -issuer -dates
```

Add an internal CA:

```bash
cp internal-ca.crt /etc/pki/ca-trust/source/anchors/   # CHANGE: PEM or DER
update-ca-trust                                         # CHANGE: rebuilds the bundles in /etc/pki/ca-trust/extracted
```

Applications with their own bundle are not affected: Java keystores, Python virtual environments with `certifi`, Node.js, and containers including AAP Execution Environments. See [ansible/collections-and-execution-environments.md](../ansible/collections-and-execution-environments.md#trusting-an-internal-ca).

## Inspect certificates on the host

```bash
openssl x509 -in cert.pem -noout -subject -issuer -dates -ext subjectAltName
openssl x509 -in cert.pem -noout -fingerprint -sha256
openssl verify -CAfile chain.pem cert.pem             # chain validates against the given CA bundle
openssl verify cert.pem                               # against the system trust store
# Does this key match this certificate? Compare the two hashes.
openssl x509 -in cert.pem -noout -pubkey | sha256sum
openssl pkey -in key.pem -pubout | sha256sum
# Expiry in the next 30 days? Exit status 1 means it will expire.
openssl x509 -in cert.pem -noout -checkend $((30*24*3600))
```

Find certificates used by common services:

```bash
grep -RiE 'ssl_certificate|SSLCertificateFile|crt ' /etc/nginx /etc/httpd /etc/haproxy 2>/dev/null
```

## Crypto policies

RHEL 8 and later set TLS and SSH algorithms system-wide with crypto policies.

```bash
update-crypto-policies --show            # DEFAULT, LEGACY, FUTURE, FIPS, plus subpolicies like :SHA1
fips-mode-setup --check                  # FIPS state (RHEL 8 and 9)
cat /proc/sys/crypto/fips_enabled        # 1 means FIPS mode
```

What breaks and why:

| Symptom | Cause |
| --- | --- |
| SSH to an old device fails with `no matching key exchange method` or `no matching host key type` | The old device only offers algorithms removed from the current policy |
| TLS to an old server fails with `unsupported protocol` or `no protocols available` | Server only offers TLS 1.0 or 1.1 |
| Certificate rejected with `ca md too weak` or a signature algorithm error | Certificate or CA signed with SHA-1, which RHEL 9 `DEFAULT` rejects |
| Works on RHEL 8, fails on RHEL 9 | RHEL 9 `DEFAULT` disabled SHA-1 signatures |

Fix the old endpoint when you can. When you cannot, scope the exception as narrowly as possible:

```bash
ssh -o KexAlgorithms=+diffie-hellman-group14-sha1 user@old-device   # one connection only
update-crypto-policies --set DEFAULT:SHA1                          # CHANGE: whole host; reboot recommended
```

`update-crypto-policies --set LEGACY` weakens every TLS and SSH client and server on the host. Record any such change and plan to revert it.

## Cautions

- Never copy private keys into tickets, chats, or this repository. `.gitignore` excludes `*.key` and `*.pem`, but that is a last line of defense.
- A broken `sshd_config` can lock you out after a restart. Always run `sshd -t` first.
- Changing the crypto policy affects every service on the host.
