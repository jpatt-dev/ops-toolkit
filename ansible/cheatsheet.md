# Ansible and AAP cheat sheet

Read-only unless marked `CHANGE`. Details are in the linked guides.

## First five minutes on a failing job

| Step | Command or place | What to look for |
| --- | --- | --- |
| 1 | Job details **Explanation** and first output lines | Failed before tasks (EE, project, inventory, credential) or in a task |
| 2 | Failed task result | `msg`, `rc`, `stderr`, `module_stderr` |
| 3 | Last successful run of the same template | Different EE, project revision, inventory, or extra vars |
| 4 | Execution node | Same node every time it fails? |
| 5 | Reproduce on one host | `--limit host01.example.com -vv` |

## Versions and configuration

| Problem | Command | What to look for |
| --- | --- | --- |
| Which core and config | `ansible --version` | `core` version, `config file`, collection paths |
| What settings changed | `ansible-config dump --only-changed` | Overrides and their source |
| Collection installed? | `ansible-galaxy collection list <ns.coll>` | Version and path; duplicates on several paths |
| Module options | `ansible-doc <fqcn>` | Options for the installed version |
| What is in the EE | `podman run --rm <ee> ansible-galaxy collection list` | Same collection versions as you expect |
| Python libs in the EE | `podman run --rm <ee> python3 -m pip list` | `pywinrm`, `requests`, `pypsrp`, SDKs |

## Inventory and variables

| Problem | Command | What to look for |
| --- | --- | --- |
| Hosts in a group | `ansible-inventory -i inv --graph <group>` | Missing or extra hosts |
| One host's inventory vars | `ansible-inventory -i inv --host <host>` | `ansible_host`, connection vars |
| Pattern result | `ansible -i inv 'web:&prod' --list-hosts` | Exactly the hosts you expect |
| Variable value at runtime | `ansible.builtin.debug: var=x` | Value at the point of use |
| Variable type | `{{ x \| type_debug }}` | `str` where you expected `bool` or `int` |
| Who overrides it | [precedence list](inventory-and-variables.md#variable-precedence) | Extra vars, `set_fact`, role vars |

## Playbook runs

| Goal | Command |
| --- | --- |
| Syntax only | `ansible-playbook site.yml --syntax-check` |
| Hosts and tasks | `ansible-playbook site.yml -i inv --list-hosts --list-tasks` |
| Dry run on one host | `ansible-playbook site.yml -i inv --check --diff --limit host01.example.com` |
| Connection detail | `-vvv` (avoid on jobs with secrets) |
| `CHANGE` Skip to a task | `--start-at-task 'Task name'` (runs the playbook) |
| `CHANGE` Step through | `--step` (runs each task you confirm) |
| Timing | `ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks` |
| `CHANGE` Same as AAP | `ansible-navigator run site.yml -i inv --eei <ee> --mode stdout` (runs the playbook; add `--check`) |

## Connectivity

| Problem | Command | What to look for |
| --- | --- | --- |
| Linux reachability | `ansible -i inv host -m ansible.builtin.ping` | `pong`, or the layer that failed |
| SSH detail | `ssh -vvv -o BatchMode=yes user@host true` | Auth methods offered, key accepted, prompts |
| Port open | `timeout 5 bash -c '</dev/tcp/host/22' && echo open` | Refused vs timeout |
| Windows reachability | `ansible -i inv win -m ansible.windows.win_ping` | `pong` |
| WinRM TLS | `curl -sS -o /dev/null -w '%{http_code}\n' https://win:5986/wsman` | Any HTTP code = TCP and TLS work |
| Kerberos | `klist` in the job; `chronyc tracking` | Ticket, realm, clock offset |

## AAP API (through the gateway)

| Problem | Endpoint | What to look for |
| --- | --- | --- |
| Platform up | `/api/gateway/v1/ping/` | HTTP 200 |
| Controller and nodes | `/api/controller/v2/ping/` | Instances, heartbeat |
| Node health | `/api/controller/v2/instances/` | `errors`, `capacity`, `node_state` |
| Job detail | `/api/controller/v2/jobs/<id>/` | `status`, `job_explanation`, `execution_node` |
| Failed events | `/api/controller/v2/jobs/<id>/job_events/?failed=true` | Failing task and host |
| What a launch needs | GET `/api/controller/v2/job_templates/<id>/launch/` | Required prompts; `ignored_fields` after a POST |

## Error message to guide

| Message contains | Go to |
| --- | --- |
| `UNREACHABLE`, `Permission denied`, `credentials were rejected`, `Kerberos` | [connectivity-ssh-winrm.md](connectivity-ssh-winrm.md) |
| `couldn't resolve module/action`, `Failed to import the required Python library`, `unauthorized` on image pull | [collections-and-execution-environments.md](collections-and-execution-environments.md) |
| `is undefined`, `has no attribute`, `mapping values are not allowed`, `Conditionals must have a boolean result` | [common-failures.md](common-failures.md) |
| `Pending`, `Waiting`, `Task was marked as running`, project sync errors | [aap-platform-and-controller.md](aap-platform-and-controller.md) |
| `Failed to authenticate with the instance`, `Unexpected response - 4xx` | [servicenow-integration.md](servicenow-integration.md) |

## Labeled changes

| Action | Command | Note |
| --- | --- | --- |
| `CHANGE` Install collections | `ansible-galaxy collection install -r collections/requirements.yml -p ./collections` | Installs into the project |
| `CHANGE` Log in to a registry | `podman login registry.redhat.io` | Writes the auth file for that user |
| `CHANGE` Pull an image | `podman pull <image>` | Uses disk on the node |
| `CHANGE` Remove unused images | `podman image prune` | Can remove an EE still referenced by AAP |
| `CHANGE` Restart a platform service | `systemctl --user restart <unit>` | Interrupts running jobs |
