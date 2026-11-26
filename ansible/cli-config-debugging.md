# Ansible CLI, configuration, and playbook debugging

Use this guide when a playbook fails on the command line or inside an Execution Environment and you need to see what Ansible actually did. For inventory and variables, see [inventory-and-variables.md](inventory-and-variables.md). For error messages, see [common-failures.md](common-failures.md).

All commands on this page are read-only unless marked `CHANGE`. Any `ansible-playbook` or `ansible-navigator run` without `--check`, `--syntax-check`, or a `--list-*` option executes the playbook and makes its changes; those lines are marked `CHANGE`.

## Know which Ansible you are running

Most "works on my laptop, fails in AAP" problems are version or path differences. Check these first.

```bash
ansible --version                 # core version, config file in use, module search path, Python
ansible-config dump --only-changed  # every setting that differs from the default, and where it came from
ansible-galaxy collection list    # collections and versions on the collection path
python3 -c 'import sys; print(sys.executable)'
```

What to read in `ansible --version`:

| Line | Why it matters |
| --- | --- |
| `ansible [core 2.x.y]` | Module behavior, templating rules, and Python support change between core releases. |
| `config file = ...` | `None` means no `ansible.cfg` was found. A different path means a different file won. |
| `ansible collection location = ...` | Where collections are searched. A collection outside these paths is not found. |
| `python version = ...` | The controller-side Python. Not the target host's Python. |

Inside AAP, run the same commands in the Execution Environment image instead of on the controller host. See [collections-and-execution-environments.md](collections-and-execution-environments.md#inspect-an-execution-environment).

## Configuration

Ansible uses the **first** configuration file it finds, in this order. Files are not merged.

1. `ANSIBLE_CONFIG` environment variable
2. `ansible.cfg` in the current directory
3. `~/.ansible.cfg`
4. `/etc/ansible/ansible.cfg`

Ansible ignores `ansible.cfg` in the current directory when that directory is world-writable. `ansible --version` then shows a different file, or `None`.

```bash
ansible-config view                     # contents of the file in use
ansible-config dump --only-changed      # effective non-default settings and their origin
ansible-config list | less              # every setting, its env var, and its ini key
ansible-config init --disabled > ansible.cfg.example   # CHANGE: writes a file. Commented template of all settings.
```

Environment variables override `ansible.cfg`. Command-line options override both. In AAP, settings come from the project's `ansible.cfg`, job template options, and environment variables set on the job or in **Settings > Job settings**.

Settings that most often explain surprises:

| Setting | Env var | Effect |
| --- | --- | --- |
| `inventory` | `ANSIBLE_INVENTORY` | Default inventory when `-i` is not given |
| `remote_user` | `ANSIBLE_REMOTE_USER` | User when no `ansible_user` is set |
| `host_key_checking` | `ANSIBLE_HOST_KEY_CHECKING` | Whether unknown SSH host keys fail the connection |
| `collections_path` | `ANSIBLE_COLLECTIONS_PATH` | Where collections are searched |
| `roles_path` | `ANSIBLE_ROLES_PATH` | Where roles are searched |
| `forks` | `ANSIBLE_FORKS` | Parallel hosts per task |
| `timeout` | `ANSIBLE_TIMEOUT` | Connection timeout in seconds |
| `interpreter_python` | `ANSIBLE_PYTHON_INTERPRETER` | How the target Python is chosen |
| `stdout_callback` | `ANSIBLE_STDOUT_CALLBACK` | Output format |

## Pre-flight checks

Run these before a real execution. None of them contact a managed host except `ansible -m ping`.

```bash
ansible-playbook site.yml --syntax-check          # parses YAML and play structure; does not resolve variables
ansible-playbook site.yml -i inventory --list-hosts   # which hosts each play targets after --limit
ansible-playbook site.yml -i inventory --list-tasks   # task order, including imported tasks
ansible-playbook site.yml -i inventory --list-tags
ansible -i inventory web -m ansible.builtin.ping      # connection, auth, and Python on the target. Not ICMP.
```

`--syntax-check` passing does not mean variables resolve. Undefined variables fail at run time.

`--list-tasks` shows `import_*` tasks but not `include_*` tasks, because includes are resolved while the play runs.

## Dry runs

```bash
ansible-playbook site.yml -i inventory --check --diff --limit host01.example.com
```

- `--check` asks each module to report what it would change. Modules that do not support check mode are skipped.
- `--diff` shows file and template differences. It can print secrets that are inside templated files. Use `no_log` or `diff: false` on those tasks.
- Tasks that depend on a registered result from a skipped task can fail in check mode only. Guard them with `when: not ansible_check_mode` when that is expected.
- `ansible.builtin.command` and `ansible.builtin.shell` do not run in check mode unless the task sets `check_mode: false`. Only do that for read-only commands.

## Verbosity

| Flag | What you get |
| --- | --- |
| `-v` | Task results |
| `-vv` | Task paths and included files |
| `-vvv` | Connection details: user, port, the SSH or WinRM command, and remote temp paths |
| `-vvvv` | Connection plugin debugging, including SSH `-vvv` output |

Higher verbosity can log URLs, headers, and module arguments. Do not use `-vvv` or above on jobs that handle credentials unless every sensitive task has `no_log: true`. Do not paste that output into tickets.

## Narrowing a failure

```bash
# CHANGE: each of these runs the playbook for real. Add --check --diff to make it a dry run.
ansible-playbook site.yml -i inventory --limit host01.example.com          # one host
ansible-playbook site.yml -i inventory --tags patch --skip-tags reboot
ansible-playbook site.yml -i inventory --start-at-task 'Install updates'   # skip earlier tasks
ansible-playbook site.yml -i inventory --step                               # confirm each task
ansible-playbook site.yml -i inventory -e @vars-test.yml                     # extra vars from a file outside the repo
```

`--start-at-task` skips earlier tasks, including `set_fact` and `register` tasks the later tasks need. Expect undefined variables.

After a failure, `ansible-playbook` can write a retry file only when `retry_files_enabled` is true. Re-running with `--limit @site.retry` targets only the failed hosts.

## Look at data, not guesses

```yaml
- name: Show one variable as Ansible sees it on this host
  ansible.builtin.debug:
    var: ansible_host

- name: Show the type, not just the value
  ansible.builtin.debug:
    msg: "{{ my_value | type_debug }}"

- name: Show a registered result in full
  ansible.builtin.debug:
    var: result
    verbosity: 1        # printed only at -v and above
```

`type_debug` answers questions like "why is `'false'` truthy": the value is a string, not a boolean.

Ad hoc equivalents:

```bash
ansible -i inventory host01.example.com -m ansible.builtin.debug -a 'var=hostvars[inventory_hostname].ansible_host'
ansible -i inventory host01.example.com -m ansible.builtin.setup -a 'filter=ansible_distribution*'
```

## Task debugger

The task debugger stops on a failed task and lets you inspect and re-run it.

```yaml
- name: Example
  hosts: all
  debugger: on_failed
```

Or for one run: `ANSIBLE_ENABLE_TASK_DEBUGGER=True ansible-playbook site.yml` (`CHANGE`: runs the playbook).

At the `(debug)` prompt: `p task.args`, `p task_vars['ansible_host']`, `p result._result`, `redo`, `continue`, `quit`.

The debugger needs an interactive terminal. It does not work in an AAP job.

## Output formats

```bash
# CHANGE: both run the playbook. Add --check to observe without changing hosts.
ANSIBLE_CALLBACK_RESULT_FORMAT=yaml ansible-playbook site.yml    # readable multi-line results (core 2.13+)
ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks ansible-playbook site.yml   # per-task timing; needs ansible.posix
```

`profile_tasks` shows which tasks are slow. `ansible.posix.timer` shows total run time.

## Keeping remote files

```bash
ANSIBLE_KEEP_REMOTE_FILES=1 ansible-playbook site.yml -vvv     # CHANGE: runs the playbook
```

The module payload stays in the remote temp directory shown at `-vvv`. That payload can contain module arguments, including secrets. Delete it when you are done.

## Common CLI failures

| Message | Likely cause | Check |
| --- | --- | --- |
| `[WARNING]: provided hosts list is empty, only localhost is available` | Inventory not found or empty | `ansible-inventory -i inventory --graph`; confirm `-i` path and `ansible.cfg` `inventory` |
| `[WARNING]: Could not match supplied host pattern, ignoring: web` | Group or host name not in inventory | `ansible-inventory --graph`; group names are case-sensitive |
| `ERROR! the role 'x' was not found` | Role not on `roles_path` | `ansible-config dump \| grep -i roles_path`; `ansible-galaxy role list` |
| `couldn't resolve module/action 'x.y.z'` | Collection missing or wrong FQCN | `ansible-galaxy collection list x.y`; see [collections-and-execution-environments.md](collections-and-execution-environments.md) |
| `ERROR! Attempting to decrypt but no vault secrets found` | Vault-encrypted data and no vault password | Supply `--ask-vault-pass` or a vault ID; in AAP, attach a Vault credential |
| `Timeout (12s) waiting for privilege escalation prompt` | `become` password missing, wrong, or sudo prompt not recognized | Confirm `become_method`, and whether sudo needs a password; see [connectivity-ssh-winrm.md](connectivity-ssh-winrm.md) |

## Cautions

- Use fully qualified collection names (`ansible.builtin.copy`). Short names depend on which collections are installed.
- Prefer `--limit` to a single test host before running against a group.
- `--check` is not a guarantee. Modules that call APIs may not support it, and command tasks are skipped.
- Keep extra-vars files that contain real data outside this repository.
