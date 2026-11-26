# Common automation failures, YAML, and Jinja2

Use this page to look up an error message. Each row gives the likely cause and the first check. Connection errors are in [connectivity-ssh-winrm.md](connectivity-ssh-winrm.md). Collection and EE errors are in [collections-and-execution-environments.md](collections-and-execution-environments.md). Platform errors are in [aap-platform-and-controller.md](aap-platform-and-controller.md).

## Validate before running

```bash
python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1])); print("ok")' playbook.yml   # pure YAML parse
yamllint playbook.yml                                    # style and syntax, if installed
ansible-playbook playbook.yml --syntax-check             # Ansible structure
ansible-lint playbook.yml                                # best practices and deprecated syntax, if installed
```

`yaml.safe_load` reports the line and column of the first YAML error. Ansible reports the same position, but sometimes on the line after the real mistake.

## YAML errors

| Message | Cause | Fix |
| --- | --- | --- |
| `mapping values are not allowed here` | An unquoted value contains a colon followed by a space, or indentation puts a key where a value belongs | Quote the value; check indentation on the line above |
| `found character '\t' that cannot start any token` | Tab character | Replace tabs with spaces |
| `did not find expected key` | Indentation is inconsistent within a list or mapping | Align siblings to the same column |
| `could not find expected ':'` | A line meant to be `key: value` is missing the colon, or a multi-line string is not marked | Add `:` or use `\|` or `>` block scalars |
| `found undefined alias` | Value starts with `*` | Quote it |
| `found unacceptable key (unhashable type: 'dict')` | A value starts with `{{` and is unquoted | Quote the whole value: `msg: "{{ var }}"` |
| `We were unable to read either as JSON nor YAML` | The file failed both parsers | Run `yaml.safe_load` on it for the exact position |
| `conflicting action statements: x, y` | Two modules in one task, usually from bad indentation | Indent module arguments under the module |
| `'x' is not a valid attribute for a Play` or `for a Task` | Misspelled keyword, or a module argument at task level | Move it under the module, or fix the spelling |

### YAML values that change type

| You wrote | YAML 1.1 reads it as | Write instead |
| --- | --- | --- |
| `yes`, `no`, `on`, `off` | Boolean | `true`, `false`, or quote the string |
| `mode: 0755` | Integer 493 in Ansible (octal). Works, but `755` without the zero is decimal and wrong. | `mode: '0755'` |
| `version: 1.10` | Float `1.1` | `version: '1.10'` |
| `country: NO` | Boolean false | `country: 'NO'` |
| `time: 12:30` | Sexagesimal integer in some parsers | `time: '12:30'` |
| `id: 0012` | Octal integer | `id: '0012'` |

Quote values that must stay strings: versions, IDs, modes, phone numbers, ZIP codes, and anything with a leading zero.

## Jinja2 and templating errors

| Message | Cause | Fix |
| --- | --- | --- |
| `'x' is undefined` | Variable not set for this host | See [inventory-and-variables.md](inventory-and-variables.md#variable-troubleshooting) |
| `'dict object' has no attribute 'y'` | Key missing | `x.y \| default('...')`, or test `x.y is defined` |
| `'list object' has no attribute 'y'` | You have a list of dicts, not a dict | `x \| map(attribute='y') \| list`, or index `x[0].y` |
| `template error while templating string: unexpected '}'` | Unbalanced braces or a stray `}}` | Count `{{` and `}}`; check filters for missing `)` |
| `unexpected char '...'` | Invalid syntax inside `{{ }}` | Check quotes and operators |
| `No filter named 'x'` | Filter is in a collection that is not installed, or misspelled | Use the FQCN, such as `ansible.utils.ipaddr`; install the collection |
| `The conditional check '...' failed. The error was: ...` | The expression in `when` raised an error | Read the error after "The error was" |
| `conditional statements should not include jinja2 templating delimiters` (warning) | `when: "{{ x }}"` | Write `when: x` |
| `Conditional result ... of type 'str' ... Conditionals must have a boolean result.` | ansible-core 2.19 and later require a boolean from `when`, `until`, `failed_when`, `changed_when`, and `assert` | Make the expression boolean: `x \| bool`, `x \| length > 0`, `x is defined`. `ALLOW_BROKEN_CONDITIONALS` is a temporary bypass only. |
| `Syntax error in expression.` followed by a note about template delimiters | ansible-core 2.19+: `{{ }}` inside a `when` or `assert` expression | Remove the braces |
| `Conditional is marked as unsafe, and cannot be evaluated.` | ansible-core 2.16.1+ security change: a conditional that embeds a template from untrusted data | Rewrite the conditional without embedded templates |

ansible-core 2.19 overhauled templating (data tagging). The AAP 2.6 and 2.7 release notes list ansible-core 2.16 as the platform core version, but an EE can contain a newer core. Content that works in one EE can fail in another. Check `ansible --version` inside the EE you run. Read the [ansible-core 2.19 porting guide](https://docs.ansible.com/ansible/latest/porting_guides/porting_guide_core_2.19.html) before moving content to a 2.19 or later EE.

### Patterns that avoid most templating errors

```yaml
# Safe defaults
port: "{{ app_port | default(8443) | int }}"

# Omit an optional module argument when the variable is not set
ansible.builtin.user:
  name: "{{ user_name }}"
  shell: "{{ user_shell | default(omit) }}"

# Boolean from a string survey answer
when: enable_reboot | bool

# Non-empty check that is a boolean
when: target_list | default([]) | length > 0

# Nested lookup that tolerates missing keys
record_number: "{{ (result.json | default({})).get('result', {}).get('number', 'not returned') }}"
```

## Module and task failures

| Message | Likely cause | First check |
| --- | --- | --- |
| `Unsupported parameters for (module) module: x` | Parameter does not exist in the installed version | `ansible-doc <fqcn>` for the installed version |
| `missing required arguments: x` | Required parameter omitted | `ansible-doc` |
| `value of state must be one of: ...` | Invalid choice | Use one of the listed values |
| `non-zero return code` from `command` or `shell` | The command failed on the target | Read `stderr` and `rc` in the result |
| `Destination directory ... does not exist` | Parent directory missing | Create it with `ansible.builtin.file` first |
| `Could not find or access 'x'` | `src` file not in `files/` or `templates/` search path | `-vv` shows the paths searched |
| `Status code was 401 and not [200]` from `uri` | Authentication failure | See [api/http-error-troubleshooting.md](../api/http-error-troubleshooting.md) |
| `Request failed: <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED]>` | Trust problem in the EE | See [trusting an internal CA](collections-and-execution-environments.md#trusting-an-internal-ca) |
| `This module requires the ... Python library` | Library not in the EE, or not on the target for remote modules | `pip list` in the EE or on the target |
| `async task did not complete within the requested time` | `async` timeout too short for the work | Increase `async`; check the target for the job |
| `Failed to connect to the host via ssh` after a reboot task | Host still rebooting | Use `ansible.builtin.reboot` or `ansible.windows.win_reboot`, which wait for the host |
| `MODULE FAILURE` with `See stdout/stderr for the exact error` | Module crashed on the target, often Python or PowerShell errors | Read `module_stdout` and `module_stderr` |
| `The task includes an option with an undefined variable` | Undefined variable in task arguments | The error lists the variable name |

## Partial failures and unreachable hosts

- A failed host is removed from the rest of the play. Other hosts continue unless `any_errors_fatal: true` or `max_fail_percentage` is reached.
- An unreachable host is also removed. `ignore_errors` does not catch unreachable hosts. Use `ignore_unreachable: true` on the task when you must continue, and handle it explicitly.
- `serial` batches stop the play when an entire batch fails.
- The play recap shows `ok`, `changed`, `unreachable`, `failed`, `skipped`, `rescued`, and `ignored` per host. In AAP, the job's host status summary shows the same counts.

Pattern for controlled failure handling:

```yaml
- name: Apply change with explicit recovery
  block:
    - name: Do the work
      ansible.builtin.command: /usr/local/bin/do-work --check-first
      register: work
      changed_when: work.rc == 0
  rescue:
    - name: Record the failure for the report
      ansible.builtin.set_fact:
        work_failed: true
  always:
    - name: Summarize without printing secrets
      ansible.builtin.debug:
        msg: "rc={{ work.rc | default('not run') }}"
```

## Cautions

- `ignore_errors: true` hides real failures. Prefer `failed_when` with a precise condition, or `block` and `rescue`.
- Do not use `shell` when a module exists. Modules are idempotent and report changes correctly.
- Keep `no_log: true` on tasks that handle credentials, including their `register` targets you later print.
