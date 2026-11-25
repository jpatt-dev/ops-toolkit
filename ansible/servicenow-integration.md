# ServiceNow integrations from Ansible and AAP

Use this guide when automation creates or updates ServiceNow records, reads the CMDB as an inventory, or fails talking to a ServiceNow instance. For REST concepts and raw API troubleshooting, see [api/servicenow-rest-concepts.md](../api/servicenow-rest-concepts.md). For a ready-made diagnostic job, see [servicenow_api_diagnostic.yml](servicenow_api_diagnostic.yml) and its section in [README.md](README.md#servicenow-api-diagnostic).

## The collection

The certified collection is `servicenow.itsm`. Confirm it is in the EE and check its version before reading any documentation:

```bash
podman run --rm <ee-image> ansible-galaxy collection list servicenow.itsm
ansible-doc -l servicenow.itsm
ansible-doc servicenow.itsm.change_request
ansible-doc -t inventory servicenow.itsm.now
```

Commonly used content:

| Content | Purpose |
| --- | --- |
| `servicenow.itsm.change_request`, `change_request_info` | Create, update, close, and read change requests |
| `servicenow.itsm.change_request_task` | Change tasks |
| `servicenow.itsm.incident`, `incident_info` | Incidents |
| `servicenow.itsm.configuration_item`, `configuration_item_info` | CMDB CIs |
| `servicenow.itsm.api`, `api_info` | Generic REST access. `api` handles `post`, `patch`, and `delete`. `api_info` reads. |
| `servicenow.itsm.now` (inventory plugin) | Build inventory from a CMDB table |

## Authentication

The modules accept an `instance` dictionary, or read environment variables when it is omitted. Use environment variables injected by an AAP credential so nothing sensitive appears in playbooks or extra vars.

| Environment variable | Meaning |
| --- | --- |
| `SN_HOST` | Instance URL, such as `https://dev.example.com` |
| `SN_USERNAME`, `SN_PASSWORD` | Basic or OAuth password-grant account |
| `SN_CLIENT_ID`, `SN_CLIENT_SECRET` | OAuth client, when using OAuth |
| `SN_GRANT_TYPE` | OAuth grant type, when not the default |
| `SN_TIMEOUT` | Request timeout |

Run `ansible-doc servicenow.itsm.change_request` and read the `instance` option for the full list supported by your installed version. See [aap-platform-and-controller.md](aap-platform-and-controller.md#credentials-and-authentication) for a custom credential type that injects these.

## Read-only checks first

```yaml
- name: Confirm read access to change_request
  servicenow.itsm.change_request_info:
    number: CHG0000000          # placeholder; use a known test record
  register: chg
  no_log: true

- name: Report the count only
  ansible.builtin.debug:
    msg: "records returned: {{ chg.records | length }}"
```

Zero records with no error means authentication and the table ACL allowed the query but nothing matched. It does not prove the record does not exist; a read ACL can hide records. See [api/servicenow-rest-concepts.md](../api/servicenow-rest-concepts.md#acls-hide-data-instead-of-failing).

## Change request lifecycle

A typical automated change:

1. Create the change, or create from a standard change template.
2. Move it to the state your change model allows automation to enter. Many instances require approval before **Implement**.
3. Run the automation.
4. Close it with a close code and notes, or leave it for review on failure.

```yaml
- name: Create a normal change
  servicenow.itsm.change_request:
    type: normal
    state: new
    short_description: Monthly OS patching for example group
    description: Created by AAP job {{ tower_job_id | default('manual') }}
  register: change
  no_log: true

- name: Keep only the number for later tasks
  ansible.builtin.set_fact:
    change_number: "{{ change.record.number }}"

- name: Close the change after success
  servicenow.itsm.change_request:
    number: "{{ change_number }}"
    state: closed
    close_code: successful
    close_notes: Completed by automation.
```

Check state names, close codes, and required fields with `ansible-doc` and with your instance's change model. Instances often add mandatory fields, business rules, or approval policies that reject a transition with HTTP 400 or 403.

In AAP, `tower_job_id` and `awx_job_id` hold the current job ID.

### Standard changes

Standard changes come from a pre-approved template. Use the Change Management API standard endpoint, or the module option for templates in your collection version. The existing diagnostic shows a guarded POST to `api/sn_chg_rest/change/standard/<template_id>` through `servicenow.itsm.api`. Read its limitations: an omitted `data` and `data: {}` send the same body, and HTTP status is not a return field.

## CMDB inventory plugin

```yaml
# inventory/servers.now.yml
plugin: servicenow.itsm.now
table: cmdb_ci_server
columns:
  - name
  - ip_address
  - os
  - classification
sysparm_query: operational_status=1^install_status=1
keyed_groups:
  - key: os
    prefix: os
  - key: classification
    prefix: env
compose:
  ansible_host: ip_address
```

```bash
ansible-inventory -i inventory/servers.now.yml --graph
ansible-inventory -i inventory/servers.now.yml --host <ci-name>
```

Verify every option name against `ansible-doc -t inventory servicenow.itsm.now` for your version. Option names and query syntax have changed across releases.

| Symptom | Likely cause |
| --- | --- |
| No hosts | Query matches nothing, wrong table, or the account cannot read the table |
| Many more hosts than expected | Query field name misspelled. ServiceNow can ignore an invalid condition and return everything. |
| Hosts with no `ansible_host` | The `ip_address` or FQDN column is empty in the CMDB |
| Duplicate hostnames | CMDB has duplicate CIs with the same name |
| Group names look odd | `keyed_groups` values contain spaces or characters that Ansible replaces with `_` |

Test the same encoded query with the Table API first. See [api/servicenow-rest-concepts.md](../api/servicenow-rest-concepts.md#table-api).

## Failures

| Message or symptom | Likely cause | Check |
| --- | --- | --- |
| `Failed to authenticate with the instance: 401` | Wrong account, locked account, or OAuth client wrong | Test with the read-only API call in [api/cheatsheet.md](../api/cheatsheet.md) |
| `Unexpected response - 403` | Account authenticated but lacks the role or ACL | Roles on the integration account; the table's ACLs |
| `Unexpected response - 400` with a message | Invalid field, invalid choice value, or a business rule rejected the change | Read the `message` and `detail`; compare required fields |
| `Unexpected response - 404` | Wrong path, table, or record | Confirm the path in REST API Explorer |
| `CERTIFICATE_VERIFY_FAILED` | Proxy or instance certificate not trusted in the EE | [trusting an internal CA](collections-and-execution-environments.md#trusting-an-internal-ca) |
| Timeouts | Proxy required, instance slow, or large query | Proxy env vars in the EE; narrow the query; `SN_TIMEOUT` |
| Duplicate changes created | Task retried, job relaunched, or loop over hosts | Create the change once per run, on `localhost` or with `run_once: true` |

## Design rules for production

- Run ServiceNow API tasks once per job: on `localhost`, or with `run_once: true` and `delegate_to: localhost`. A task that runs per host creates one record per host.
- Never retry a create automatically. Check whether the record exists before trying again.
- Use `no_log: true` on API tasks. Print only the fields you need, such as the record number.
- Keep the instance URL in the credential. Do not hardcode it in playbooks in this repository.
- Use a dedicated integration account with only the roles it needs.
