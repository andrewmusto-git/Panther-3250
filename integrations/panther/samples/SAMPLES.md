# Sample Data — Panther OAA Connector

This directory is reserved for sample/test data used during dry-run validation.

Because Panther is a REST API source, this connector does **not** read flat files at
runtime. Place representative JSON response fixtures here to support offline testing.

---

## Files to create

### `sample_users.json`
A JSON file containing a realistic `GET /v1/users` response object:

```json
{
  "results": [
    {
      "id": "a1b2c3d4-0000-0000-0000-000000000001",
      "email": "alice@example.com",
      "givenName": "Alice",
      "familyName": "Smith",
      "enabled": true,
      "status": "CONFIRMED",
      "createdAt": "2024-01-15T10:00:00Z",
      "lastLoggedInAt": "2024-11-01T08:30:00Z",
      "role": {
        "id": "role-admin-001",
        "name": "Admin"
      }
    },
    {
      "id": "a1b2c3d4-0000-0000-0000-000000000002",
      "email": "bob@example.com",
      "givenName": "Bob",
      "familyName": "Jones",
      "enabled": false,
      "status": "FORCE_CHANGE_PASSWORD",
      "createdAt": "2024-03-10T12:00:00Z",
      "lastLoggedInAt": null,
      "role": {
        "id": "role-analyst-002",
        "name": "Analyst"
      }
    }
  ],
  "next": null
}
```

### `sample_roles.json`
A JSON file containing a realistic `GET /v1/roles` response object:

```json
{
  "results": [
    {
      "id": "role-admin-001",
      "name": "Admin",
      "permissions": ["UserModify", "ViewAlerts", "ManageAlerts", "ManageRoles"],
      "logTypeAccessKind": "ALLOW_ALL",
      "logTypeAccess": [],
      "createdAt": "2023-01-01T00:00:00Z",
      "updatedAt": "2024-01-01T00:00:00Z"
    },
    {
      "id": "role-analyst-002",
      "name": "Analyst",
      "permissions": ["ViewAlerts", "ManageAlerts"],
      "logTypeAccessKind": "ALLOW_ALL",
      "logTypeAccess": [],
      "createdAt": "2023-01-01T00:00:00Z",
      "updatedAt": "2024-01-01T00:00:00Z"
    },
    {
      "id": "role-readonly-003",
      "name": "AnalystReadOnly",
      "permissions": ["ViewAlerts"],
      "logTypeAccessKind": "ALLOW_ALL",
      "logTypeAccess": [],
      "createdAt": "2023-01-01T00:00:00Z",
      "updatedAt": "2024-01-01T00:00:00Z"
    }
  ],
  "next": null
}
```

---

## Usage

When running a dry-run with `--dry-run`, the connector calls the **live Panther API**
(after acquiring an OAuth2 token). The sample files above are for reference only and
are not consumed by the script at runtime.

To run a fully offline dry-run, you would need to mock the HTTP endpoints, which is
outside the scope of this connector. The recommended validation approach is a
`--dry-run` against a non-production Panther instance.
