# ServiceNow API diagnostic

`servicenow_api_diagnostic.yml` checks ServiceNow from an Ansible Automation Platform 2.7 job. It uses the ServiceNow credential already injected into the Execution Environment. It does not read `SN_USERNAME` or `SN_PASSWORD`, and it does not accept them as extra variables.

The read-only call uses `servicenow.itsm.api_info`. `servicenow.itsm.api` cannot send GET; its actions are `post`, `patch`, and `delete`. Using it for the connectivity test would create a record. The optional standard-change call uses `servicenow.itsm.api`.

No customer URL, credential, or template id belongs in this repository. Supply those at launch.

## Job template

Use the Execution Environment that already includes `servicenow.itsm` 2.5.0 or newer. `api_path` was added in 2.5.0.

| Setting | Value |
| --- | --- |
| Playbook | `ansible/servicenow_api_diagnostic.yml` |
| Inventory | An inventory that can target `localhost` |
| Credential | The custom ServiceNow credential that injects `SN_HOST`, `SN_USERNAME`, and `SN_PASSWORD` |
| Privilege escalation | Off |
| Check mode | Off. Check mode does not call the API for `servicenow.itsm.api` creates, so it cannot show HTTP 400. The playbook refuses POST in check mode. |
| Verbosity | 0 or 1. Verbosity 3 and above lets the collection log the request URL. |
| Limit | `localhost` |
| Other credentials | Do not attach a machine credential. The playbook sets `connection: local`, `delegate_to: localhost`, and `ansible_connection: local`. |

`SN_HOST` must be an `https` origin with no user, password, path, or query. The collection also reads `SN_TIMEOUT` from the environment when it is set. The playbook does not set a timeout; the collection default is 10 seconds.

The credential comparison lowercases both values and removes trailing slashes. `https://dev.example.com` and `https://dev.example.com:443` are different. The job stops before any API call when they differ.

## Extra variables

`approved_dev_url` is required for every run, including GET.

```yaml
approved_dev_url: https://dev.example.com
request_mode: get
```

POST creates a standard change. It runs only when `request_mode` is `post`, `confirm_post` is exactly `POST`, and `template_id` is one identifier. `post` or `yes` do not confirm it. The GET still runs first and does not block the POST. Each call is attempted once. There is no Ansible `retries`, `until`, or `loop` on the POST.

```yaml
approved_dev_url: https://dev.example.com
request_mode: post
confirm_post: POST
template_id: example-template-id
post_body_mode: omit
```

| Variable | Values | Default |
| --- | --- | --- |
| `approved_dev_url` | `https` origin that must match `SN_HOST` | none |
| `request_mode` | `get` or `post` | `get` |
| `confirm_post` | `POST` when `request_mode` is `post` | empty |
| `template_id` | Template identifier for the standard-change path | empty |
| `post_body_mode` | `omit` or `empty` | `omit` |

`template_id` accepts letters, digits, `.`, `_`, and `-`. Do not put a password in any extra variable. A template id is still visible to operators who can see the job's extra variables, and it is part of the request path. The playbook does not print it in the summary.

Launch the POST only with approval to create a record on that DEV instance. Do not rerun a failed POST automatically.

## What the job prints

API tasks are `no_log`, so their result is censored. That is intentional. Read the task named "Show the sanitized ServiceNow summary".

The summary can include the check name, `success`, `failed`, or `not run`, an HTTP status when the module put one in its error text, a short ServiceNow `message` and `detail`, and a GET row count. It does not include the record, the credential, authorization headers, or the raw response.

A failed call fails the job after that summary. `ignore_errors` on the API tasks only lets the summary run. It does not send the request again.

## Limitations

**GET module.** `servicenow.itsm.api_info` reads `change_request` with only the `number` column, `sysparm_no_count`, and the placeholder query `number=CHGEXAMPLE0000000`. That query is not a customer record. `api_info` has no `sysparm_limit` parameter, and its client pages through every match, so the playbook does not list the table. Zero rows still means the Table API accepted the authenticated request.

**HTTP status.** A successful module result has `record` and no status code. The playbook reports `not returned` and does not print `record`. The collection client treats HTTP 404 on GET as success, so a successful GET is not proof of HTTP 200.

**HTTP 400.** On a non-success status, `servicenow.itsm.api` fails the task. The only structured field is `msg`, formatted as `Unexpected response - <status> <raw body>`. The body is often the Python bytes form of the JSON, not a separate `status` or `json` field. The playbook keeps the three-digit status from that prefix and, when present, the top-level JSON strings `message` and `detail`. It then drops URLs, long hex identifiers, token-like values, and anything that still looks like a document. Nested JSON, XML, HTML, and non-ASCII bodies that do not survive that bytes formatting are omitted. The status can still be shown when the prefix is present.

**HTTP 401.** Authentication failure raises a different error: `Failed to authenticate with the instance: 401 <reason>`. The response body is not included. The summary says authentication failed and does not print the body.

**POST body.** `data` defaults to `{}`. The client JSON-encodes that mapping whenever it is not null. Omitting `data` and passing `data: {}` both send `{}`. `post_body_mode` records which test you selected. It cannot produce a POST with no body. There is no second request that compares the two modes.

**Retries.** The playbook does not set Ansible `retries`, `until`, or `loop` on POST. `servicenow.itsm` 2.6.3 makes one HTTP attempt. Later releases can repeat a TLS handshake timeout inside that single module call, and that retry count is not a module option. An HTTP 400 is not retried. Username/password authentication does not retry HTTP 401.

**Other.** Certificate validation stays at the collection default. The playbook does not set `validate_certs: false` or `include_sensitive_headers: true`. A successful POST may have created a standard change; the new record is not displayed. Confirm the result in the DEV instance when the status is unclear.
