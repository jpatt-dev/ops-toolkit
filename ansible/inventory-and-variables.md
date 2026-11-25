# Inventory and variables

Use this guide when the wrong hosts run, a host is missing from a group, or a variable has a value you did not expect. All commands are read-only.

## See the inventory the way Ansible sees it

```bash
ansible-inventory -i inventory --graph                  # group tree with hosts
ansible-inventory -i inventory --graph web              # one group
ansible-inventory -i inventory --host host01.example.com  # merged variables for one host
ansible-inventory -i inventory --list --yaml | less     # everything, after plugins and group_vars
ansible -i inventory 'web:&prod' --list-hosts           # result of a host pattern
```

`--host` shows inventory variables only: inventory files, `group_vars`, and `host_vars` next to the inventory. It does not show play vars, role vars, facts, or extra vars. Use `ansible.builtin.debug` inside the play for those.

### Host patterns

| Pattern | Meaning |
| --- | --- |
| `web` | Group `web` |
| `web:db` | Union |
| `web:&prod` | Intersection: in `web` and in `prod` |
| `web:!host03.example.com` | Exclusion |
| `~web0[1-3]\..*` | Regular expression (starts with `~`) |
| `web[0]`, `web[0:2]` | Position within the group. Order is not guaranteed across inventory sources. |

`--limit` uses the same patterns. In AAP, the job template **Limit** field and a launch-time limit are patterns too.

## Inventory troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Host missing from a group | Name mismatch, typo, or a dynamic inventory filter excluded it | `ansible-inventory --graph`; inspect the source filter or query |
| Host appears twice with different names | Same machine under FQDN and short name | Choose one name; set `ansible_host` for the address |
| `ansible_host` is wrong | A later `group_vars` file or a dynamic source overrides it | `ansible-inventory --host <name>`; compare with the source |
| Group variables do not apply | `group_vars/<name>.yml` filename does not match the group, or directory is not next to the inventory or playbook | Directory layout and spelling |
| Dynamic inventory returns nothing | Plugin not enabled, credential missing, or the file name does not match the plugin's required suffix | `ansible-inventory -i source.yml --list -vvv` |
| `[WARNING]: Unable to parse ... as an inventory source` | No enabled plugin accepted the file | `ansible-config dump \| grep -i INVENTORY_ENABLED`; check file suffix and YAML |

Inventory plugin files usually must end with a specific suffix. For example, the ServiceNow plugin reads files ending in `now.yml` or `now.yaml`. Check `ansible-doc -t inventory <plugin>` for the exact rule.

### AAP inventory notes

- An inventory **source** is synced into the controller database. Jobs read the synced copy, not the live source. Check the source's last sync time and its job output.
- **Overwrite** removes hosts and groups that are no longer in the source. **Overwrite variables** replaces variables instead of merging them. Both can remove data that someone added by hand.
- **Update on launch** syncs before each job. A failed sync fails the job.
- Constructed inventories build groups from existing inventories with Jinja2 `groups`, `keyed_groups`, and `compose`. Use the constructed inventory's **limit** and **verbosity** to debug which hosts it produces.
- The same hostname in two inventory sources of one inventory is one host. The last source to sync sets its variables.

## Variable precedence

Lowest to highest. A later entry overrides an earlier one. This is the order in the Ansible documentation.

1. Command-line values that are not variables, such as `-u`
2. Role defaults (`roles/x/defaults/main.yml`)
3. Inventory file or script group vars
4. Inventory `group_vars/all`
5. Playbook `group_vars/all`
6. Inventory `group_vars/*`
7. Playbook `group_vars/*`
8. Inventory file or script host vars
9. Inventory `host_vars/*`
10. Playbook `host_vars/*`
11. Host facts and cached `set_fact`
12. Play `vars`
13. Play `vars_prompt`
14. Play `vars_files`
15. Role vars (`roles/x/vars/main.yml`)
16. Block vars
17. Task vars
18. `include_vars`
19. `set_fact` and registered vars
20. Role and `include_role` params
21. Include params
22. Extra vars (`-e`). These always win.

Practical rules that follow from the list:

- Put tunable values in role `defaults`. Values in role `vars` are hard to override and surprise people.
- Child groups override parent groups. Groups at the same depth merge alphabetically by group name, so the later name wins. Set `ansible_group_priority` in inventory to change that.
- `set_fact` beats everything except role params, include params, and extra vars. A `set_fact` early in a play can hide a value you changed in inventory.
- Extra vars cannot be overridden by anything in the playbook. If a value will not change, look for it in extra vars first.

### Where AAP puts variables

| AAP source | Precedence it maps to |
| --- | --- |
| Inventory, group, and host variables | Inventory variables |
| Job template **Variables** | Extra vars |
| Survey answers | Extra vars |
| Launch-time extra vars (prompt on launch) | Extra vars, applied over the template's |
| Workflow node and workflow extra vars | Extra vars |
| Custom credential `extra_vars` injector | Extra vars |
| Workflow `set_stats` artifacts | Extra vars for later nodes |

Because surveys, template variables, and credential injectors all become extra vars, they override anything the playbook sets. See [aap-platform-and-controller.md](aap-platform-and-controller.md#job-templates-surveys-and-extra-variables).

## Finding where a value came from

1. Run `ansible-inventory --host <name>`. If the value is wrong here, the problem is in inventory.
2. Search the project: `grep -rn 'my_var' group_vars host_vars roles playbooks`.
3. Print it in the play at the point of use with `ansible.builtin.debug: var=my_var`.
4. Check extra vars: job template variables, survey, workflow, launch prompt, and credential injectors.
5. Check `set_fact` and `register` with the same name earlier in the play.

## Variable troubleshooting

| Message or symptom | Likely cause | Fix |
| --- | --- | --- |
| `'my_var' is undefined` | Not set for this host, set in a skipped task, or a typo | Use `ansible.builtin.debug` and `ansible-inventory --host`; add a role default |
| `'dict object' has no attribute 'x'` | The key is missing, or the value is a string that looks like a dict | `{{ value \| type_debug }}`; use `value.x \| default(...)` or `value['x']` |
| `"false"` is treated as true | String, not boolean | Use `\| bool` in the condition, or pass a real boolean in YAML or JSON extra vars |
| Number compares wrong | String vs integer | Use `\| int` |
| Value is right in inventory, wrong in the task | Overridden later: role vars, `set_fact`, or extra vars | Walk the precedence list from the top |
| `hostvars['other']` missing facts | Facts were not gathered for that host in this run | Gather facts for that host earlier, or enable fact caching |

## Magic variables worth knowing

| Variable | Contents |
| --- | --- |
| `inventory_hostname` | Name of the host in inventory |
| `ansible_host` | Address used to connect, when set |
| `group_names` | Groups the current host belongs to |
| `groups` | Every group and its hosts |
| `hostvars` | Variables of every host |
| `ansible_play_hosts` | Hosts still active in this play (failed hosts removed) |
| `ansible_check_mode` | `true` during `--check` |
| `ansible_play_batch` | Hosts in the current `serial` batch |

## Cautions

- Do not commit `host_vars` or `group_vars` that contain customer hostnames, IP addresses, or credentials to this repository.
- Store secrets with Ansible Vault or an AAP credential. Do not put them in survey defaults or job template variables, which other users with access can read.
