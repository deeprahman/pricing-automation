# Shared OwnerRez Client How-To

Location: `workers/pws_workers/shared/ownerrez_client.py`

Purpose
- Provides one reusable sync HTTP client for OwnerRez API calls.
- Intended to support the live `get_ownerrez_messages` action and future OwnerRez endpoints.
- Keeps HTTP config, retry rules, TLS handling, and response normalization in one place.

## What It Does

The client currently exposes:

- `OwnerRezClient.get_messages(thread_id, offset=None, limit=None)`

It sends:

- `GET /messages`
- query params:
  - `threadId`
  - `include_drafts=false`
  - `include_attachments=false`
  - optional `offset`
  - optional `limit`
- header:
  - `Authorization: Bearer <OWNERREZ_BEARER_TOKEN>`

Base URL default:

- `https://api.ownerrez.com/v2`

## Environment Variables

Required:

- `OWNERREZ_BEARER_TOKEN`

Optional:

- `OWNERREZ_API_BASE_URL`
  - default: `https://api.ownerrez.com/v2`
- `OWNERREZ_CA_BUNDLE`
  - custom CA bundle path for outbound TLS trust override

## Timeouts And Retries

Configured HTTP timeouts:

- connect: `5s`
- read: `20s`
- write: `20s`
- pool: `5s`

Configured in-process retry behavior:

- total attempts: `3`
- default backoff: `1s`, then `2s`
- retryable conditions:
  - transport errors
  - timeout errors
  - HTTP `429`, `500`, `502`, `503`, `504`
- if `Retry-After` is present on a retryable response, that delay is used instead of the default backoff

## Response Contract

`get_messages(...)` returns a normalized message-thread payload shaped like the repo's canonical OwnerRez samples under `data/api-data/messages/` and like the existing dummy fixtures:

```json
{
  "guest": { "first_name": "...", "id": 123, "last_name": "..." },
  "items": [
    {
      "id": 90546176,
      "thread_id": 9744759,
      "body": "...",
      "date_utc": "2026-01-18T14:23:32Z",
      "from_contact_id": 620534629,
      "from_role": "guest",
      "is_draft": false
    }
  ],
  "offset": 0,
  "limit": 100,
  "thread": {
    "booking_id": 16219451,
    "channel": "airbnb",
    "id": 9744759,
    "property_id": 389578,
    "type": "channel"
  }
}
```

Normalization rules:

- `items` must be a list of objects
- `thread` must be an object
- `thread.id` is ensured
- `offset` falls back to request offset, then `0`
- `limit` falls back to request limit, then `len(items)`

This keeps the payload compatible with `messages-worker`, which relies on `result.items`, `result.thread`, `result.offset`, and `result.limit`.

## Error Types

The client raises typed exceptions so the caller can decide between queue retry, callback error propagation, or terminal task failure.

- `OwnerRezRetryableError`
  - transport/timeouts or retryable HTTP status after retries are exhausted
- `OwnerRezPermanentError`
  - non-retryable upstream HTTP responses such as `400`, `401`, `403`, `404`, `422`
- `OwnerRezConfigError`
  - missing token, invalid base URL, or missing CA bundle path
- `OwnerRezResponseShapeError`
  - invalid JSON body or response shape that does not match the expected message contract

Each error includes:

- `failure_classification`
- optional `status_code`
- `attempts`

## Minimal Usage Example

```python
from pws_workers.shared.ownerrez_client import OwnerRezClient

client = OwnerRezClient(token="your-ownerrez-bearer-token")
result = client.get_messages(thread_id=9744759, offset=9, limit=10)

print(result["thread"]["id"])
print(len(result["items"]))
```

## Worker Integration Pattern

Typical caller behavior should be:

1. Build or reuse one process-level `OwnerRezClient`
2. Call `get_messages(...)`
3. On `OwnerRezRetryableError`
   - fail the queue task with `retry=True`
4. On `OwnerRezPermanentError`
   - convert to callback payload with `result=None` and `error=str(exc)`
5. On `OwnerRezConfigError` or `OwnerRezResponseShapeError`
   - fail the task without retry
6. On success
   - pass the normalized payload downstream unchanged

## Logging Hook

`get_messages(...)` accepts an optional `log_event(level, message, metadata)` callback.

Use it when you want worker-side structured logs for:

- request attempts
- response status codes
- retry scheduling
- normalized item counts

Sensitive values such as the bearer token should never be logged.

## Testing Pattern

For tests, pass an `httpx.MockTransport` into the client:

```python
import httpx
from pws_workers.shared.ownerrez_client import OwnerRezClient

requests = []

def handler(request: httpx.Request) -> httpx.Response:
    requests.append(request)
    return httpx.Response(200, json={
        "items": [],
        "offset": 0,
        "limit": 0,
        "thread": {"id": 9744759}
    })

client = OwnerRezClient(
    token="test-token",
    transport=httpx.MockTransport(handler),
)

client.get_messages(thread_id=9744759)
assert requests[0].headers["Authorization"] == "Bearer test-token"
```

## Notes

- This HOWTO documents the shared OwnerRez client itself.
- The existing worker-specific guide at `workers/pws_workers/external-services-worker/HOWTO.md` still documents the external worker contract and callback flow.
- If more OwnerRez endpoints are added later, extend `ownerrez_client.py` instead of creating ad hoc request code in each action handler.
