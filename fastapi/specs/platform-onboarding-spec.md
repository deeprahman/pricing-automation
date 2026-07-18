# Platform Onboarding Specification

## Purpose
This spec defines how to add a new REST platform to the system so API tokens are managed from the `Platforms` tab, stored in `secrets`, validated on save, and used by runtime connectors.

## 1) Database Contract
Add one row to `auto_pws.platforms` with platform metadata.

Required metadata shape:

```json
{
  "domain": "https://api.vendor.com",
  "secret": {
    "Token Label A": {
      "Name": "Authorization",
      "type": "Bearer Token",
      "secret_table_ptr": null
    },
    "Token Label B": {
      "Name": "X-API-Key",
      "type": "API Key",
      "secret_table_ptr": null
    }
  },
  "endpoints": {
    "listings": {
      "path": "/v1/listings",
      "request_type": "get"
    }
  }
}
```

Notes:
- `metadata.secret` is the source of truth for token slots.
- User-entered token values are written to `auto_pws.secrets` (encrypted).
- `secret_table_ptr` stores the `secrets.id` pointer for each token slot.

## 2) UI Behavior
No new UI code is required for new platforms if metadata follows the contract.

The existing `Platforms` tab will:
- Read token slots from `metadata.secret`.
- Render one input per slot.
- Show slot label, header name, auth type, configured state, and `secret_id`.
- Call token save/delete APIs per slot.

## 3) Backend Requirements
Implement provider validation and connector behavior in `fastapi/main.py`:

1. Add a provider validator helper (pattern):
- Build auth headers from metadata token slots.
- Call a lightweight provider endpoint for auth verification.
- Normalize result to:
  - `checked`
  - `provider`
  - `endpoint`
  - `ok`
  - `message`
  - optional `status_code`, `reason`

2. Wire validator in `_validate_platform_api_token(...)` dispatch by platform name.

3. Keep strict rollback on validation failure:
- Create path: delete created secret + clear pointer.
- Update path: restore previous secret value (and previous description).
- Return `400` with structured validation payload.

4. Use metadata-driven headers in runtime connector calls (`_build_platform_auth_headers(...)`).

## 4) Validation Endpoint Rules
Pick one endpoint per provider that is safe and low-cost.

Selection checklist:
- Must confirm auth validity.
- Should not mutate provider data.
- Should be low latency and inexpensive.
- Must have deterministic error behavior for bad credentials.

Current providers:
- OwnerRez: `GET /v2/properties`
- PriceLabs: `GET /v1/listings`
- Wheelhouse RM API key: `GET /ss_api/v1/listings` (requires `X-Integration-Api-Key`)

## 5) Test Checklist
For each new platform validator:
- Valid token returns `ok=true`.
- Invalid token returns `400` from save endpoint with structured validation detail.
- Create rollback removes pointer and secret.
- Update rollback restores prior value.
- UI status panel shows returned validation payload.

## 6) Operational Checklist
Before enabling in production:
- Ensure encryption env vars are available to FastAPI (`SECRETS_ENCRYPTION_KEY` or `SECRET_ENCRYPTION_KEY`).
- Verify platform metadata includes correct header names and token types.
- Confirm endpoint and rate limits for validation call.
- Run API smoke tests with both valid and intentionally invalid tokens.
