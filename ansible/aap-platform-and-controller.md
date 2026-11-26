# AAP 2.6 and 2.7 platform and automation controller troubleshooting

Use this guide for problems inside Red Hat Ansible Automation Platform: jobs stuck or failing before tasks run, project syncs, credentials, surveys, and API access through the platform gateway.

Commands are read-only unless marked `CHANGE`. Check the Red Hat documentation for your exact version before changing platform configuration.

## Architecture in one page

AAP 2.5 introduced a unified platform. AAP 2.6 and 2.7 keep that model.

| Component | Role | What fails when it is unhealthy |
| --- | --- | --- |
| Platform gateway | Single UI, authentication, and API entry point. Routes requests to the services below. | Login, SSO, every UI page, API calls |
| Automation controller (automation execution) | Job templates, inventories, projects, credentials, scheduling, job dispatch | Jobs, project syncs, inventory syncs |
| Automation hub (automation content) | Private collections and Execution Environment images | Collection installs during project sync, EE pulls |
| Event-Driven Ansible controller (automation decisions) | Rulebook activations that react to events | Event-driven job launches |
| Automation mesh (receptor) | Connects controller to execution and hop nodes | Jobs stuck in waiting, nodes marked unavailable |
| PostgreSQL | State for all services | Everything |
| Redis | Cache and messaging for gateway and services | UI and event updates, websockets |

Version facts that affect troubleshooting:

- **AAP 2.7 removed direct component API access.** The platform gateway is the only entry point. Integrations that called the controller, hub, or EDA APIs directly must go through the gateway. Red Hat lists minimum collection versions for 2.7 (for example `ansible.controller` 4.8.0 and `ansible.platform` 2.7.0) and provides `aap-detect-direct-component-access` to find old usage before upgrading.
- **AAP 2.7 removed the RPM installer.** New RHEL installs are containerized. OpenShift uses the operator. RPM installs must migrate to a supported topology on 2.6 first.
- **AAP 2.6** still includes the RPM installer, which was deprecated in 2.5. It is supported on RHEL 9 only, not RHEL 10.
- The platform's bundled `ansible-core` and the core inside your EEs are separate. Jobs use the EE's version. Check it with `ansible --version` inside the image.

## API through the platform gateway

Use the gateway URL for all API calls. The controller API is under `/api/controller/`.

```bash
# Read-only. Prompts for the password; nothing is stored.
curl -sS -u "$AAP_USER" https://aap.example.com/api/gateway/v1/ping/
curl -sS -u "$AAP_USER" https://aap.example.com/api/controller/v2/ping/
curl -sS -u "$AAP_USER" https://aap.example.com/api/controller/v2/me/

# With a token: read it without echo, and pass the header to curl on stdin
# (-K -) so the token never appears in the process list or shell history.
read -rs -p 'AAP token: ' AAP_TOKEN; echo
printf 'header = "Authorization: Bearer %s"\n' "$AAP_TOKEN" |
  curl -sS -K - https://aap.example.com/api/controller/v2/jobs/<id>/
unset AAP_TOKEN
```

Do not write `-H "Authorization: Bearer $AAP_TOKEN"` on the command line: other local users can read it with `ps` while curl runs.

Useful read-only controller endpoints:

| Endpoint | Use |
| --- | --- |
| `/api/controller/v2/ping/` | Controller version, instances, instance groups, heartbeat |
| `/api/controller/v2/instances/` | Node state, capacity, `errors`, last health check |
| `/api/controller/v2/instance_groups/` | Capacity and which nodes are in each group |
| `/api/controller/v2/jobs/<id>/` | Status, `job_explanation`, `execution_node`, EE used |
| `/api/controller/v2/jobs/<id>/stdout/?format=txt` | Full job output as text |
| `/api/controller/v2/jobs/<id>/job_events/?failed=true` | Only failed events |
| `/api/controller/v2/job_templates/<id>/launch/` (GET) | What the template will prompt for and which fields are required |
| `/api/controller/v2/project_updates/<id>/stdout/?format=txt` | Project sync output |

A `POST` to `.../launch/` starts a job. Treat it as a change. When a launch POST includes fields the template does not prompt for, the response lists them in `ignored_fields` and the job runs without them.

Gateway errors: `401` means the gateway rejected the identity. `403` means the identity is known but lacks the role. `404` on a path that worked before an upgrade can mean the integration still uses a removed direct component path.

## Job states

| State | Meaning | Where to look |
| --- | --- | --- |
| Pending | Waiting for a dependency: a project or inventory update, or another run of the same template when concurrent jobs are not allowed | Job details **Explanation**; the blocking job |
| Waiting | Accepted, waiting for capacity on an instance group | Instance group capacity; node health |
| Running | Running on `execution_node` | Job output |
| Failed with no tasks | Failed before Ansible started: EE pull, project, inventory, credential, or node problem | Job **Explanation** field and the first lines of output |
| Error | Platform problem, not a task failure | **Explanation**; controller task logs |
| Canceled | Canceled by a user, workflow, or timeout | Activity stream; job timeout setting |

Messages you may see in **Explanation**:

| Message | Meaning |
| --- | --- |
| `Task was marked as running but was not present in the job queue, so it has been marked as failed.` | The controller lost track of the job, often after a service restart or node loss. Rerun after checking node health. |
| `Job terminated due to timeout` | Job template timeout reached |
| `Previous Task Failed: {"job_type": "project_update", ...}` | The dependent project sync failed. Open that project update. |
| `Receptor detail: ...` | Mesh or execution node error. Check the named node. |

## Node and service checks

On a containerized install, services run as Podman containers under the install user and are managed by user-level systemd units. Run these as that user.

```bash
podman ps --format '{{.Names}}\t{{.Status}}'                 # running containers and uptime
systemctl --user list-units --type=service --all | grep -Ei 'automation|receptor|postgres|redis'
journalctl --user -u <unit-name> --since '30 min ago'         # logs for one service unit
podman logs --since 30m <container-name>                      # container stdout and stderr
podman exec -it receptor receptorctl --socket <socket-path> status   # mesh status
df -h ; free -m                                               # disk and memory
```

Container and unit names vary by version and topology. List them first instead of guessing. The receptor control socket path is set in the receptor configuration (`control-service` → `filename`).

On OpenShift, use `oc get pods -n <namespace>`, `oc logs <pod> -c <container>`, and `oc describe pod <pod>` instead.

Restarting a platform service interrupts running jobs. Mark it `CHANGE` and coordinate before doing it.

## Job templates, surveys, and extra variables

### Before launching

- Confirm the inventory, limit, credentials, EE, and instance group on the job template.
- Use the launch endpoint GET (above) to see required prompts.
- Run against one host with a limit first.

### Surveys

| Symptom | Cause | Fix |
| --- | --- | --- |
| Survey answer ignored | A later source overrides it, such as a workflow's extra vars | Check workflow node and workflow extra vars |
| Value arrives as a string | Survey `text` and `multiplechoice` answers are strings | Use `\| int` or `\| bool`, or use the `integer` and `float` types |
| Password answer shows `$encrypted$` | Expected. Survey passwords are stored encrypted and masked. | None. Do not log the variable. |
| API launch value ignored | Variables not set to **Prompt on launch** and no survey field for it | Enable **Prompt on launch** for variables, or add the survey question |
| Multiple choice rejected | Answer not in the configured choices | Match exactly, including case |

Survey answers, template variables, and launch-time variables are all extra vars. They override every variable defined in the playbook, inventory, and roles. See [inventory-and-variables.md](inventory-and-variables.md#variable-precedence).

Jinja2 in extra vars is controlled by the **Allow Jinja in extra variables** setting (`ALLOW_JINJA_IN_EXTRA_VARS`). The default allows it only in template-defined variables. Do not change it to `always`; that lets anyone with launch rights inject templates.

## Credentials and authentication

| Credential type | Used for | Common failure |
| --- | --- | --- |
| Machine | SSH or WinRM to managed hosts, and `become` | Wrong user, missing `become` password, key passphrase not set |
| Source Control | Project sync from Git | `Permission denied (publickey)`, or HTTPS `could not read Username` |
| Vault | Decrypting vaulted content | `no vault secrets found`; vault ID label mismatch |
| Container Registry | Pulling EE images | See [image pulls](collections-and-execution-environments.md#registry-authentication-and-image-pulls) |
| Ansible Galaxy/Automation Hub API Token | Collection installs during project sync | `401` or `403` from the hub |
| Custom credential types | Injecting API settings as env vars, extra vars, or files | Injector key name differs from what the module reads |

Custom credential type example. The module reads `SN_HOST`, `SN_USERNAME`, and `SN_PASSWORD` from the environment, so the injector sets exactly those names.

```yaml
# Input configuration
fields:
  - id: instance
    type: string
    label: Instance URL
  - id: username
    type: string
    label: Username
  - id: password
    type: string
    label: Password
    secret: true
required:
  - instance
  - username
  - password
```

```yaml
# Injector configuration
env:
  SN_HOST: '{{ instance }}'
  SN_USERNAME: '{{ username }}'
  SN_PASSWORD: '{{ password }}'
```

Secret fields are masked in the UI and API. They are not masked in your own `debug` output. Never print them.

To check that an injector works without exposing the value, test for presence only:

```yaml
- name: Confirm the credential injected SN_HOST
  ansible.builtin.assert:
    that: lookup('ansible.builtin.env', 'SN_HOST') | length > 0
    fail_msg: SN_HOST is not set. Attach the credential to the job template.
```

## Project synchronization

| Message in the project update | Likely cause | Fix |
| --- | --- | --- |
| `Permission denied (publickey)` | SSH key in the Source Control credential is wrong or not authorized | Test the same key with `ssh -T git@<git-host>` from a workstation |
| `could not read Username for 'https://...': terminal prompts disabled` | HTTPS repository needs a credential and none is attached | Attach a Source Control credential with a token |
| `Host key verification failed` | Git host key unknown or changed | Confirm the host key out of band before trusting a new one |
| `fatal: couldn't find remote ref <branch>` | Branch or tag does not exist | Check the SCM branch and refspec |
| `SSL certificate problem: unable to get local issuer certificate` | Git server uses an internal CA not trusted in the project update EE | Add the CA to the EE used for project updates |
| Collections from `collections/requirements.yml` missing at run time | Collection download disabled, no Galaxy credential on the organization, or the file is not at that path | Project update output; organization Galaxy credentials |
| Playbook not listed in the job template dropdown | File not at the expected path, invalid YAML, or not recognized as a playbook | Sync output; confirm the file has `hosts:` at play level |

Project options:

- **Update revision on launch** syncs before every job. A slow Git server slows every job.
- **Clean** discards local changes before sync. **Delete** removes the whole local copy first.
- Requirements are read from `collections/requirements.yml` and `roles/requirements.yml` in the project.

## Workflow checklist for a failing job

1. Open the job. Read **Explanation** and the first 20 lines of output.
2. If no task ran: check the EE pull, project update, inventory update, and credentials in that order.
3. If a task failed: read that task's result. Rerun with `--limit` to one host and verbosity 2.
4. Compare the EE, project revision, and inventory with the last successful run of the same template.
5. Check the execution node with `/api/controller/v2/instances/`.
6. Reproduce outside AAP with `ansible-navigator run` and the same EE, using `--check` or a test host (`CHANGE`: without `--check` it runs the playbook).

## Cautions

- Do not raise job verbosity above 2 on templates that handle credentials or API tokens unless every sensitive task uses `no_log`.
- Job output, activity stream, and job extra vars are visible to users with read access to the template. Do not pass secrets as plain extra vars.
- Do not disable TLS verification on credentials or projects to clear an error. Fix trust instead.
