# TLS and certificate troubleshooting with OpenSSL

Read-only. Works with OpenSSL 1.1.1 (RHEL 8) and OpenSSL 3 (RHEL 9 and 10). For host trust store and crypto policy changes, see [linux/ssh-tls-certificates.md](../linux/ssh-tls-certificates.md). For Windows certificate stores, see [windows/ad-auth-certificates.md](../windows/ad-auth-certificates.md#certificates).

## How a TLS connection fails

1. **TCP** must connect first. A TLS error after a timeout is really a network problem.
2. **Protocol and cipher negotiation**: client and server need a common TLS version and cipher suite.
3. **Certificate chain**: the server sends its certificate and intermediates; the client must chain them to a CA it trusts.
4. **Name check**: the name the client used must be in the certificate's Subject Alternative Name.
5. **Validity dates**: now must be between `notBefore` and `notAfter`, so client clock matters.
6. **Optional**: revocation checks, client certificates (mutual TLS).

## Connect and inspect

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null
openssl s_client -connect api.example.com:443 -servername api.example.com -showcerts </dev/null    # full chain the server sends
openssl s_client -connect api.example.com:443 -servername api.example.com -verify_return_error -verify_hostname api.example.com </dev/null
openssl s_client -connect api.example.com:443 -servername api.example.com -CAfile /path/to/ca.pem </dev/null   # test with a specific CA
openssl s_client -connect api.example.com:443 -servername api.example.com -tls1_2 </dev/null   # force TLS 1.2
openssl s_client -connect api.example.com:443 -servername api.example.com -tls1_3 </dev/null
openssl s_client -connect smtp.example.com:587 -starttls smtp </dev/null   # STARTTLS protocols: smtp, imap, ldap, ...
```

Always pass `-servername`. Without SNI, servers that host several names may return a default certificate, and you debug the wrong one. `</dev/null` makes `s_client` exit after the handshake.

Through an HTTP proxy (OpenSSL 1.1.0+):

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com -proxy proxy.example.com:8080 </dev/null
```

Show only the leaf certificate's key fields:

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

### Reading s_client output

| Line | Meaning |
| --- | --- |
| `depth=2 ... depth=0 ...` | Chain from root (highest depth) to leaf (0) as verified |
| `Certificate chain` / `0 s:... i:...` | What the server sent: `s:` subject, `i:` issuer |
| `Verification: OK` / `Verify return code: 0 (ok)` | Chain trusted and valid |
| `Protocol  : TLSv1.3` | Negotiated version |
| `Cipher    : TLS_AES_256_GCM_SHA384` | Negotiated cipher |
| `Server Temp Key` | Key exchange group |
| `Acceptable client certificate CA names` | The server asks for a client certificate (mutual TLS) |

## Verify return codes

| Code | Message | Meaning and fix |
| --- | --- | --- |
| 0 | `ok` | Trusted |
| 2 | `unable to get issuer certificate` | An intermediate or root is missing from the client trust store |
| 10 | `certificate has expired` | Renew the certificate, or check the client clock |
| 9 | `certificate is not yet valid` | Client clock behind, or new certificate deployed early |
| 18 | `self-signed certificate` (`self signed certificate` in 1.1.1) | Leaf is self-signed. Trust it explicitly or replace it. |
| 19 | `self-signed certificate in certificate chain` | Chain ends in a root the client does not trust; often an internal CA or a TLS-inspecting proxy |
| 20 | `unable to get local issuer certificate` | Client does not have the issuing CA, or the server did not send the intermediate |
| 21 | `unable to verify the first certificate` | Server sent only the leaf; missing intermediate |
| 62 | `hostname mismatch` (with `-verify_hostname`) | The name is not in the SAN |

Codes 20 and 21 together with a short `Certificate chain` (only `0 s:`) almost always mean the server is not sending its intermediate. Fix the server's chain file. Do not work around it on every client.

## Inspect certificate files

```bash
openssl x509 -in cert.pem -noout -text                       # everything
openssl x509 -in cert.pem -noout -subject -issuer -dates -serial
openssl x509 -in cert.pem -noout -ext subjectAltName,keyUsage,extendedKeyUsage   # OpenSSL 1.1.1+
openssl x509 -in cert.pem -noout -fingerprint -sha256
openssl x509 -inform der -in cert.cer -noout -text           # DER (binary) file, common from Windows
openssl verify -CAfile ca-chain.pem cert.pem                 # chain check offline
openssl verify -untrusted intermediate.pem -CAfile root.pem cert.pem
openssl crl2pkcs7 -nocrl -certfile bundle.pem | openssl pkcs7 -print_certs -noout   # list every cert in a bundle
openssl req -in request.csr -noout -text -verify             # inspect a CSR
openssl pkcs12 -in file.p12 -info -nokeys                    # inspect a PKCS#12 bundle; prompts for its password
```

OpenSSL 3 refuses some older PKCS#12 files that use legacy algorithms. Add `-legacy` to read them.

Does the key match the certificate? The two hashes must be equal:

```bash
openssl x509 -in cert.pem -noout -pubkey | sha256sum
openssl pkey -in key.pem -pubout | sha256sum
```

Formats:

| Format | Looks like | Notes |
| --- | --- | --- |
| PEM | `-----BEGIN CERTIFICATE-----` | Text. Can hold several certificates. Linux default. |
| DER | Binary | `.cer` or `.der`. One certificate. |
| PKCS#12 | Binary | `.pfx` or `.p12`. Certificate, chain, and private key, password-protected. |
| PKCS#7 | `-----BEGIN PKCS7-----` or binary | `.p7b`. Certificates only, no key. |

## Handshake failures

| Error | Likely cause | Check |
| --- | --- | --- |
| `sslv3 alert handshake failure` / `alert 40` | No common protocol or cipher, or the server requires a client certificate | Try `-tls1_2` and `-tls1_3`; check for `Acceptable client certificate CA names` |
| `wrong version number` | Not TLS on that port (plain HTTP, or a proxy speaking HTTP) | `curl -v http://host:port/` |
| `unsupported protocol` / `no protocols available` | Server only supports TLS 1.0/1.1, disabled by the client policy | Upgrade the server; see crypto policies in the Linux guide |
| `unexpected eof while reading` | Server or middlebox closed the connection during the handshake | Firewall or IPS, load balancer, server-side TLS errors |
| `Connection reset by peer` during handshake | Middlebox terminating TLS it does not allow, or SNI-based filtering | Test with and without the proxy; compare SNI |
| `ca md too weak` / `EE certificate key too weak` | SHA-1 signature or small RSA key rejected by policy | Reissue the certificate |
| Handshake hangs after `CONNECTED` | MTU problem: certificate chain packets dropped | See [MTU](performance-packet-capture.md#mtu-problems) |
| Works with `curl`, fails in Python or Java | Different trust store | Python `certifi`, Java `cacerts`, EE images |

## TLS-inspecting proxies

When a corporate proxy inspects TLS, the certificate the client receives is issued by the proxy's CA, not the real server's CA. `openssl s_client` from the same network shows an issuer like `O=Example Corp Proxy CA`.

- Add the proxy CA to the client trust store where your policy allows it.
- Some APIs pin certificates or require mutual TLS and break under inspection. Request a bypass for those destinations.

## Expiry monitoring snippet

```bash
host=api.example.com
end=$(openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
echo "$host expires: $end"
openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -checkend $((30*24*3600)) \
  && echo "more than 30 days left" || echo "expires within 30 days"
```

## Do not disable verification as the fix

`curl -k`, `--insecure`, `validate_certs: false`, `-SkipCertificateCheck`, and `ansible_winrm_server_cert_validation: ignore` turn off the protection TLS exists to provide. Use them only to confirm that a failure is a trust problem, in a test, and then fix the trust:

1. Get the full chain the server sends with `-showcerts`.
2. Identify the root and intermediates.
3. Fix the server chain if an intermediate is missing.
4. Add the internal or proxy root CA to the client trust store, or point the client at a CA bundle (`--cacert`, `ca_path`, `REQUESTS_CA_BUNDLE`).
5. Reissue the certificate if the name or algorithm is wrong.
