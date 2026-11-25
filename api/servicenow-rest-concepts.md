# ServiceNow REST API concepts

How the ServiceNow REST APIs behave, which one to use, and what their errors mean. For copy-and-paste PowerShell tests of Change Management, see [recipes/servicenow.md](recipes/servicenow.md). For Ansible, see [ansible/servicenow-integration.md](../ansible/servicenow-integration.md).

Examples use `https://dev.example.com` and placeholders such as `<sys_id>`. Never put a real instance URL, sys_id, or credential in this repository.

The source of truth for your instance is **REST API Explorer** (`System Web Services > REST > REST API Explorer`). It shows the APIs, versions, and parameters available on that release, and can generate sample requests. ServiceNow behavior varies by release, plugins, and customization.

## Conventions shared by most APIs

| Item | Detail |
| --- | --- |
| Base path | `https://<instance>/api/<namespace>/<api>`; versioned form adds `/v1/`, `/v2/` |
| Format | JSON by default. Send `Accept: application/json`; send `Content-Type: application/json` with a body. |
| Response wrapper | Success: `{"result": ...}`. Failure: `{"error": {"message": "...", "detail": "..."}, "status": "failure"}` |
| Record identifier | `sys_id`, a 32-character hexadecimal string. Record numbers (`CHG0012345`) are display values, not keys. |
| Reference fields | Returned as `{"link": "...", "value": "<sys_id>"}` unless display values are requested |
| Pagination | `sysparm_limit` and `sysparm_offset`; `Link` response header with `rel="next"`; `X-Total-Count` header unless `sysparm_no_count=true` |
| Authentication | Basic, OAuth 2.0 bearer tokens, mutual TLS, or API keys, depending on what the instance enables |
| Authorization | Roles plus ACLs on tables and fields. The integration user's roles decide what each call can see and do. |

## Table API

Generic create, read, update, and delete on any table.

| Method | Path | Action |
| --- | --- | --- |
| GET | `/api/now/table/{table}` | Query records |
| GET | `/api/now/table/{table}/{sys_id}` | One record |
| POST | `/api/now/table/{table}` | Create |
| PATCH or PUT | `/api/now/table/{table}/{sys_id}` | Update |
| DELETE | `/api/now/table/{table}/{sys_id}` | Delete |

Query parameters:

| Parameter | Use |
| --- | --- |
| `sysparm_query` | Encoded query, such as `active=true^state=-1^ORDERBYDESCsys_created_on` |
| `sysparm_fields` | Comma-separated fields to return. Always set it: smaller, faster, and less data exposed. |
| `sysparm_limit` | Maximum records per page |
| `sysparm_offset` | Starting record for paging |
| `sysparm_display_value` | `false` (raw values, default), `true` (display values), or `all` (both) |
| `sysparm_exclude_reference_link` | `true` drops the `link` URLs from reference fields |
| `sysparm_no_count` | `true` skips the total count; faster on large tables |
| `sysparm_input_display_value` | On writes, `true` lets you send display values for reference and choice fields |

Encoded query operators: `=`, `!=`, `LIKE`, `STARTSWITH`, `IN`, `ISEMPTY`, `ISNOTEMPTY`, `>`, `<`; `^` is AND, `^OR` is OR, `^NQ` starts a new OR-joined query. Build complex queries in a list view filter, then right-click the breadcrumb and copy the query.

```bash
# Read-only. -u with only the user name makes curl prompt for the password.
curl -sS -u "$SN_USER" -H 'Accept: application/json' \
  "https://dev.example.com/api/now/table/change_request?sysparm_query=active%3Dtrue&sysparm_fields=number,state,short_description&sysparm_limit=5"
```

```powershell
$cred = Get-Credential
$uri  = 'https://dev.example.com/api/now/table/change_request?sysparm_query=active%3Dtrue&sysparm_fields=number,state&sysparm_limit=5'
(Invoke-RestMethod -Uri $uri -Credential $cred -Headers @{ Accept = 'application/json' }).result
```

`-Credential` sends credentials only after the server answers `401` with a Basic challenge. That costs an extra round trip and depends on the challenge being returned. The recipe in [recipes/servicenow.md](recipes/servicenow.md) builds the `Authorization` header explicitly instead, and PowerShell 7 can use `-Authentication Basic`.

### Behaviors that surprise people

#### An invalid query can return everything

When `sysparm_query` references a field that does not exist, ServiceNow drops that condition and runs the rest. The result can be every record in the table. The `glide.invalid_query.returns_no_rows` system property, when `true`, makes invalid queries return no rows instead, across lists, scripts, and web service APIs.

Before any automation updates or deletes records selected by a query:

1. Run the query read-only and check the count.
2. Confirm every field name exists on the table.
3. Stop if the count is not what you expected.

#### ACLs hide data instead of failing

A user without read access to some records gets a `200` with those records silently omitted. A user without read access to a field gets the record without that field, or with an empty value. "No results" and "missing fields" can be permission problems, not data problems. Compare with an account you know has access, or ask the ServiceNow admin to check ACLs.

#### A record that does not exist, or that you cannot read

`GET /api/now/table/{table}/{sys_id}` returns `404` with `No Record found` when the record does not exist **or** an ACL prevents reading it. The two cases look the same.

#### Business rules run

Writes through the Table API run the same business rules, data policies, and workflows as the UI. A `400` or `403` on write can come from a business rule or data policy, not from your JSON. Read the `message` and `detail`.

## Dedicated APIs versus the Table API

Use a dedicated API when one exists for the process. It applies the process rules that a raw table write would skip or have to reimplement.

| Need | Use | Why not the Table API |
| --- | --- | --- |
| Create or move change requests through their lifecycle | Change Management API (`/api/sn_chg_rest/...`) | Applies change models, standard change templates, conflict checks, and state rules |
| Create or update CIs without duplicates | CMDB Instance API or Identification and Reconciliation (IRE) | Table writes skip identification rules and create duplicates |
| Load external data with transforms | Import Set API | Uses transform maps, coalesce, and field mapping that the instance owner controls |
| Attachments | Attachment API (`/api/now/attachment`) | Binary content and metadata |
| Read a table for reporting | Table API | Fine for reads with `sysparm_fields` and paging |
| Custom process | Scripted REST API built by the instance owner | Documented by that team |

## Change Management API

Namespace `sn_chg_rest`. Versioned paths add `/v1/` and so on.

| Method | Path | Action |
| --- | --- | --- |
| GET | `/api/sn_chg_rest/change` | List change requests (query with `sysparm_query`) |
| GET | `/api/sn_chg_rest/change/{sys_id}` | One change |
| POST | `/api/sn_chg_rest/change` | Create a change, based on a change model |
| POST | `/api/sn_chg_rest/change/normal` | Create a normal change |
| POST | `/api/sn_chg_rest/change/emergency` | Create an emergency change |
| POST | `/api/sn_chg_rest/change/standard/{standard_change_template_id}` | Create a standard change from a published template |
| GET | `/api/sn_chg_rest/change/model` | Available change models |
| PATCH | `/api/sn_chg_rest/change/{sys_id}` | Update a change |
| GET, POST | `/api/sn_chg_rest/change/{sys_id}/task` | Change tasks |
| DELETE | `/api/sn_chg_rest/change/{sys_id}` | Delete (normally not something automation should do) |

Confirm the exact list for your release in REST API Explorer. Further endpoints cover conflicts, schedules, approvals, and CI associations.

Standard changes:

- `standard_change_template_id` is the `sys_id` of the template's record producer (`std_change_record_producer`), not the template name and not a change number.
- An invalid or unpublished template returns an error such as `Standard Change Template not found`.
- Fields in the body or query string that the template does not allow are ignored, not rejected. Check the created record.
- An empty body, `{}`, and a body with fields are different requests. See [recipes/servicenow.md](recipes/servicenow.md#test-2--post-with-no-body).

Change request states (default state model):

| Value | State |
| --- | --- |
| `-5` | New |
| `-4` | Assess |
| `-3` | Authorize |
| `-2` | Scheduled |
| `-1` | Implement |
| `0` | Review |
| `3` | Closed |
| `4` | Canceled |

Instances can customize states. Query `sys_choice` for `change_request.state` to see yours.

## CMDB, CIs, and relationships

| Table | Holds |
| --- | --- |
| `cmdb_ci` | Base CI class. Every CI class extends it. |
| `cmdb_ci_server`, `cmdb_ci_linux_server`, `cmdb_ci_win_server` | Server classes |
| `cmdb_rel_ci` | Relationships: `parent`, `child`, `type` |
| `cmdb_rel_type` | Relationship types, named `Parent descriptor::Child descriptor`, such as `Depends on::Used by`, `Runs on::Runs`, `Hosted on::Hosts`, `Contains::Contained by` |
| `task_ci` | Affected CIs on a task (change, incident) |
| `change_request.cmdb_ci` | The single primary CI field on a change |

Relationship direction matters. `A Depends on::Used by B` means A is the parent that depends on B. Reversing parent and child changes impact analysis.

### CMDB Instance API

Class-aware CI access that goes through the identification engine on writes. Requires the `itil` role or equivalent.

| Method | Path | Action |
| --- | --- | --- |
| GET | `/api/now/cmdb/instance/{className}` | CIs of a class |
| GET | `/api/now/cmdb/instance/{className}/{sys_id}` | One CI with `attributes`, `outbound_relations`, `inbound_relations` |
| POST | `/api/now/cmdb/instance/{className}` | Create a CI with `attributes`, `source`, and optional relations |
| PATCH | `/api/now/cmdb/instance/{className}/{sys_id}` | Update a CI |
| POST | `/api/now/cmdb/instance/{className}/{sys_id}/relation` | Add relations |
| DELETE | `/api/now/cmdb/instance/{className}/{sys_id}/relation/{rel_sys_id}` | Remove one relation |

Body shape for a create:

```json
{
  "source": "<discovery source configured on the instance>",
  "attributes": {
    "name": "host01.example.com",
    "ip_address": "192.0.2.10"
  },
  "outbound_relations": [],
  "inbound_relations": [
    { "type": "<cmdb_rel_type sys_id>", "target": "<sys_id of the related CI>" }
  ]
}
```

Common CMDB write errors:

| Error | Meaning |
| --- | --- |
| `MISSING_DEPENDENCY` | The class's identification rule requires a related CI (for example, a database instance must run on a host). Include the required relation. |
| `ABANDONED` | Processing of an item stopped because another item in the payload failed |
| Identification rule error | No identification rule exists for the class, or required identifier attributes are missing |
| Duplicate CIs after Table API writes | Writes bypassed identification. Use the CMDB or IRE APIs. |
| `source` rejected | The value must be a discovery source the instance recognizes |

Read the `detail` text; it usually names the class and the missing relation.

## Import Set API

Loads rows into a staging table (usually named `u_...` or `imp_...`), then transform maps write them to the target table.

| Method | Path | Behavior |
| --- | --- | --- |
| POST | `/api/now/import/{stagingTableName}` | One record. Loads and transforms **synchronously**. The response includes the transform result. |
| POST | `/api/now/import/{stagingTableName}/insertMultiple` | Many records in `{"records": [ ... ]}`. Transforms **asynchronously**. Returns `import_set_id` and `multi_import_set_id`. |
| GET | `/api/now/import/{stagingTableName}/{sys_id}` | One staging row and its transform result |

Single-record response fields: `import_set`, `staging_table`, and `result[]` with `transform_map`, `table`, `display_name`, `display_value`, `record_link`, `status`, `sys_id`, and `status_message` or `error_message` when set.

| `status` | Meaning |
| --- | --- |
| `inserted` | New target record created |
| `updated` | Existing record matched by coalesce and updated |
| `ignored` | Transform script chose to skip the row |
| `skipped` | No change, or the row did not meet a condition |
| `error` | Transform failed; read `error_message` |

Notes:

- The staging table accepts string name-value pairs. Types are converted by the transform.
- A `201` from the import endpoint means the row was staged. It does not mean the target record is correct. Check `status` and the target.
- For `insertMultiple`, check the import set and its rows (`sys_import_set`, `sys_import_set_row`) to see results. `{"records": ...}` is required; otherwise the error is `There is no root array element with name records`.
- Coalesce fields on the transform map decide insert versus update. Wrong or missing coalesce creates duplicates.
- Roles: the integration user typically needs `import_set_loader` and `import_transformer`, or the roles the staging table's ACLs require.

## Error reference for ServiceNow

| Status | Typical ServiceNow message | Meaning |
| --- | --- | --- |
| 400 | `Invalid table ...`, `Requested URI does not represent any resource`, `Exception while reading request` | Bad path, table, or JSON |
| 400 | Business rule or data policy message | The instance rejected the change |
| 401 | `User Not Authenticated`, `Required to provide Auth information` | Credentials missing or rejected |
| 403 | `User Not Authorized`; `Operation Failed` with an `ACL Exception ... due to security constraints` detail | Authenticated, but roles or ACLs deny it |
| 404 | `No Record found` | Missing record, or no read access to it |
| 405 | Method not allowed | Wrong method for that resource |
| 429 | Rate limit exceeded | A REST rate limit rule applies to this user or IP; honor `Retry-After` if returned |
| 500 | Script error text | Server-side script or business rule error; ask the instance owner |

For general HTTP troubleshooting, see [http-error-troubleshooting.md](http-error-troubleshooting.md).

## Cautions

- Use a non-production instance for write tests. Writes run business rules and notifications.
- Never loop a POST on retry. Check whether the record exists first.
- Log only record numbers and statuses, not full responses. Responses can contain personal data.
