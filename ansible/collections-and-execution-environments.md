# Collections, Execution Environments, and registry access

Use this guide when a module or plugin cannot be found, a Python library is missing, an Execution Environment (EE) will not pull, or a job behaves differently in AAP than on your workstation.

Commands are read-only unless marked `CHANGE`.

## Collections

### What is installed and where

```bash
ansible-galaxy collection list                       # all collections on the search path
ansible-galaxy collection list servicenow.itsm       # one collection, every path it appears in
ansible-config dump | grep -i COLLECTIONS_PATH       # search order
ansible-doc -l servicenow.itsm                       # modules in a collection
ansible-doc servicenow.itsm.change_request           # options and return values for the installed version
```

`ansible-doc` describes the version that is installed, which may not be the version on the documentation website. Use it as the source of truth for parameters.

When a collection is listed under two paths, Ansible uses the first path in `COLLECTIONS_PATHS`. An old copy in `~/.ansible/collections` can shadow the one in your project.

### Requirements file

```yaml
# collections/requirements.yml
collections:
  - name: ansible.windows
    version: ">=2.0.0"
  - name: servicenow.itsm
    version: ">=2.5.0"
```

```bash
ansible-galaxy collection install -r collections/requirements.yml -p ./collections   # CHANGE: installs into the project
ansible-galaxy collection install -r collections/requirements.yml --force            # CHANGE: reinstall even if present
ansible-galaxy collection verify servicenow.itsm                                      # compare installed files with the server
```

Pin versions for production content. An unpinned requirement installs whatever is newest on the server at sync time.

### Galaxy servers and automation hub

`ansible.cfg` lists the servers to try in order:

```ini
[galaxy]
server_list = automation_hub, galaxy

[galaxy_server.automation_hub]
url = https://console.redhat.com/api/automation-hub/content/published/
auth_url = https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
# token is supplied by ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN, not stored here

[galaxy_server.galaxy]
url = https://galaxy.ansible.com/
```

Keep tokens out of `ansible.cfg` in a repository. Use the `ANSIBLE_GALAXY_SERVER_<NAME>_TOKEN` environment variable, or an AAP **Ansible Galaxy/Automation Hub API Token** credential attached to the organization.

A private automation hub has its own URL for each repository. Copy it from the hub UI rather than guessing the path.

### Collection failures

| Message | Likely cause | Check |
| --- | --- | --- |
| `couldn't resolve module/action 'ns.coll.module'` | Collection not installed in this environment, or typo in the FQCN | `ansible-galaxy collection list ns.coll` in the EE |
| `Failed to import the required Python library (x) on <host>'s Python` | Module needs a Python package that is not in the EE (for local or delegated tasks) or on the target | `python3 -m pip list` in the EE; add to `requirements.txt` |
| `ERROR! Neither the collection requirement entry key 'name', nor 'source' point to a concrete resolvable collection artifact` | Wrong name, wrong server, or the version does not exist | Collection name spelling; `server_list`; the version on the server |
| `HTTP Error 401: Unauthorized` or `403` from galaxy | Missing or expired hub token, or token for a different hub | Refresh the token; confirm the server URL matches the token's hub |
| `Unknown error when attempting to call Galaxy` with TLS text | Private hub uses an internal CA that the client does not trust | See [Trusting an internal CA](#trusting-an-internal-ca) |
| Module parameter unsupported | Installed collection is older than the docs you read | `ansible-doc` for the installed version |

## Execution Environments

An EE is a container image that holds `ansible-core`, `ansible-runner`, collections, Python packages, and system packages. In AAP 2.x every job runs inside one. The controller host's own Ansible installation is not used for jobs.

That means:

- A collection installed on the controller host is invisible to jobs.
- A Python package installed with `pip` on the controller host is invisible to jobs.
- Files on the controller host, such as `/etc/krb5.conf` or a CA bundle, are not visible unless the EE contains them or the platform mounts them.

### Inspect an Execution Environment

```bash
podman images                                                     # images present on this node
podman run --rm <ee-image> ansible --version
podman run --rm <ee-image> ansible-galaxy collection list
podman run --rm <ee-image> python3 -m pip list
podman run --rm <ee-image> rpm -qa | sort                         # system packages
podman run --rm <ee-image> cat /etc/os-release
podman inspect <ee-image> --format '{{.Created}} {{.Digest}}'
skopeo inspect docker://<registry>/<namespace>/<image>:<tag>      # remote image metadata without pulling
```

With `ansible-navigator`:

```bash
ansible-navigator images --mode stdout                            # images and their contents
ansible-navigator collections --eei <ee-image> --mode stdout
ansible-navigator exec --eei <ee-image> -- ansible --version
ansible-navigator run site.yml -i inventory --eei <ee-image> --mode stdout --pp missing   # CHANGE: runs the playbook; add --check for a dry run
```

`--eei` is short for `--execution-environment-image`. `--pp` is the pull policy: `always`, `missing`, `never`, or `tag`. `ansible-navigator run` reproduces AAP job behavior more closely than `ansible-playbook` on the host.

### Build an EE

`execution-environment.yml` for `ansible-builder` version 3:

```yaml
---
version: 3

images:
  base_image:
    name: <registry>/<namespace>/<base-ee-image>:<tag>

dependencies:
  galaxy: requirements.yml      # collections
  python: requirements.txt      # Python packages
  system: bindep.txt            # RPMs, in bindep format

options:
  package_manager_path: /usr/bin/microdnf
```

```bash
ansible-builder create -f execution-environment.yml                     # CHANGE: writes the build context only
ansible-builder build -f execution-environment.yml -t <image>:<tag> -v 3  # CHANGE: builds an image
```

Build failures and what they usually mean:

| Output | Likely cause |
| --- | --- |
| `No match for argument: <pkg>` from dnf/microdnf | Package not in the repositories available to the build, or the base image uses a different package manager |
| `Could not find a version that satisfies the requirement` from pip | Package name or version does not exist for this Python, or the build has no route to the package index |
| Collection dependency conflict from `ansible-galaxy` | Two collections require incompatible versions of a third. Pin the shared dependency. |
| `unauthorized` when pulling the base image | `podman login` to the base image registry is missing |

Use `ansible-builder introspect --sanitize <path-to-collections>` to see the Python and system requirements that installed collections declare.

### Execution Environment failures in AAP jobs

| Message or symptom | Likely cause | Check |
| --- | --- | --- |
| Job fails before the first task with an image pull error | Registry credential, image name, tag, or network | See [Registry authentication and image pulls](#registry-authentication-and-image-pulls) |
| `Failed to JSON parse a line from worker stream` | The worker could not run `ansible-runner` correctly: image is not an EE, wrong entrypoint, or the container failed early | Run the image by hand with `podman run --rm <ee-image> ansible-runner --version` |
| Module works locally, fails in AAP with a missing library | The library is on your workstation, not in the EE | `pip list` in the EE |
| Job uses an older collection than the project requires | Project `collections/requirements.yml` was not installed, or the EE copy is found first | Project sync output; **Settings > Job settings** collection download setting |
| Kerberos, custom CA, or `krb5.conf` missing | File exists on the host but not in the container | Build it into the EE, or expose the path through the platform settings for isolated jobs |

AAP chooses the EE in this order: job template, then project default, then organization default, then the global default. A job's details page shows which one it used.

## Registry authentication and image pulls

### Verify by hand

Run these on the execution node as the user that runs jobs. On a containerized install that is the non-root install user, not root.

```bash
podman login registry.redhat.io                          # CHANGE: stores credentials in the auth file
podman login --get-login registry.redhat.io              # which account is logged in, if any
podman pull <registry>/<namespace>/<image>:<tag>         # CHANGE: downloads the image
curl -sS -o /dev/null -w '%{http_code}\n' https://<registry>/v2/   # 401 here is normal: the registry is reachable and asks for auth
```

Rootless Podman stores credentials in `${XDG_RUNTIME_DIR}/containers/auth.json`. Root uses `/run/containers/0/auth.json`. A login as one user does not help another user.

### In AAP

- Create a **Container Registry** credential with the registry host, an account, and a password or token.
- Attach it to the Execution Environment object, not to the job template.
- Set the EE **Pull** option. `Always` pulls on every job and fails if the registry is unreachable. `Only pull if missing` uses the cached copy when present. `Never` requires the image to be on every execution node already.

### Pull errors

| Message | Likely cause | Fix |
| --- | --- | --- |
| `unauthorized: Please login to the Red Hat Registry using your Customer Portal credentials` | No or invalid credential for `registry.redhat.io` | Attach a Container Registry credential; use a registry service account token |
| `unauthorized: authentication required` | Credential missing or wrong for a private registry | Test `podman login` with the same account |
| `manifest unknown` or `name unknown` | Image path or tag does not exist | `skopeo inspect docker://...`; check the tag |
| `x509: certificate signed by unknown authority` | Registry uses a CA the node does not trust | Add the CA to the node trust store. Do not mark the registry insecure. |
| `dial tcp ...: i/o timeout` or `connection refused` | Network, proxy, or firewall | See [network/workflows.md](../network/workflows.md) |
| `toomanyrequests` | Registry rate limit | Use an authenticated pull, a mirror, or `Only pull if missing` |
| `no space left on device` | Image storage full | `podman system df`; remove unused images with `podman image prune` (`CHANGE`) |

## Trusting an internal CA

Python packages installed with `pip` often use the `certifi` bundle, not the system trust store. A custom CA added to the host is then still untrusted inside the EE.

Options, in order of preference:

1. Build the CA into the EE and update its trust store:

   ```yaml
   additional_build_files:
     - src: files/internal-ca.crt
       dest: certs

   additional_build_steps:
     prepend_final:
       - COPY _build/certs/internal-ca.crt /etc/pki/ca-trust/source/anchors/
       - RUN update-ca-trust
   ```

2. Point Python clients at the system bundle with `REQUESTS_CA_BUNDLE` or `SSL_CERT_FILE` set to `/etc/pki/tls/certs/ca-bundle.crt`.
3. Use a module option such as `ca_path` or `ca_cert` when the module provides one. Check `ansible-doc`.

Do not set `validate_certs: false` as the fix. See [network/tls-openssl.md](../network/tls-openssl.md).

## Cautions

- Do not put registry passwords or hub tokens in `execution-environment.yml`, `ansible.cfg`, or this repository.
- Rebuilding an EE with the same tag changes what every job using that tag runs. Use new tags for new builds.
- `podman image prune` and `podman system prune` delete images and can remove an EE that jobs still need.
