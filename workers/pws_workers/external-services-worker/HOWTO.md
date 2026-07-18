# External Services Worker How-To

Location: `workers/pws_workers/external-services-worker/external_services_worker.py`

Primary queue: `external-services`

This worker handles external fetch and classify actions for the messages pipeline.
It also handles canonical `process_instruction` dispatch for external pricing writes.

## `process_instruction` Provider Modules

`process_instruction` is split into orchestration + provider adapters:

- Orchestration: `workers/pws_workers/external-services-worker/external_services_worker.py`
- Provider adapters:
  - `workers/pws_workers/external-services-worker/providers/pricelabs_provider.py`
  - `workers/pws_workers/external-services-worker/providers/wheelhouse_provider.py`
  - `workers/pws_workers/external-services-worker/providers/ownerrez_provider.py`
  - `workers/pws_workers/external-services-worker/providers/registry.py`
  - `workers/pws_workers/external-services-worker/providers/base.py`

Boundary contract:

- Worker file owns payload validation, target resolution, retry/callback orchestration, and adapter dispatch.
- Provider adapter files own provider request-shape translation and provider execution behavior.
- Shared `pws_workers.shared.*_client` modules are low-level transports.

## Actions

### Fetch actions

- `get_ownerrez_messages`
  - Live fetch action
  - Uses shared `OwnerRezClient` (`pws_workers.shared.ownerrez_client`)

- `get_dummy_messages`
  - Dummy fetch action
  - Reads fixture pages from `data/dummy_messages`

### Classify actions

- `classify_messages`
  - Live AI classification action
  - Uses the configured live provider from `llm_providers`, with environment fallback
  - Reads allowed categories from active rows in `message_classes`
  - Unknown category from AI is logged as `WARNING` and mapped to `uncategorized`

- `classify_dummy_messages`
  - Dummy classification action
  - Uses `MockMessageClassifier`

## Runtime Env (workers service)

Required for live fetch:

- `OWNERREZ_BEARER_TOKEN`

Optional for live fetch:

- `OWNERREZ_API_BASE_URL` (default `https://api.ownerrez.com/v2`)
- `OWNERREZ_CA_BUNDLE` (path must be readable inside the `workers` container)

Required for live classify (`classify_messages`) when no database provider is configured:

- `OPENAI_API_KEY` when `PWS_MESSAGE_CLASSIFIER_PROVIDER=openai`

Optional for live classify:

- `llm_providers` rows in the application database; see `workers/specifications/llm_provider_specification.md`
- `PWS_MESSAGE_CLASSIFIER_PROVIDER` (`openai` by default, `ollama` in `docker-compose.local.yml`)
- `PWS_MESSAGE_CLASSIFIER_MODEL` (default `gpt-3.5-turbo`)
- `PWS_MESSAGE_CLASSIFIER_TIMEOUT_SECONDS` (default `60`)
- `OLLAMA_API_URL` (used when provider is `ollama`)
- `OLLAMA_MODEL` (used when provider is `ollama`)

## Runtime Variable TTLs

- Runtime-variable TTLs are configured from `workers/pws_workers/worker_manifest.json`.
- Resolution precedence is: `action.by_scope[scope]` -> `action.default_ttl_minutes` -> `worker.by_scope[scope]` -> `worker.default_ttl_minutes` -> manifest default -> code fallback.
- In the checked-in manifest, this worker currently uses `default_ttl_minutes = 15`.

## Fetch Error Handling

For `get_ownerrez_messages`:

- `OwnerRezRetryableError`
  - task is failed with retry (`retry_delay="2 minutes"`)
  - no runtime response write
  - no callback enqueue

- `OwnerRezPermanentError`
  - treated as upstream business error
  - runtime response is written as `{ "result": null, "error": "..." }`
  - callback is still enqueued through normal path

- `OwnerRezConfigError` / `OwnerRezResponseShapeError`
  - task is failed without retry
  - no runtime response write
  - no callback enqueue

For `get_dummy_messages`, existing dummy/file-backed behavior is unchanged.

## Classify Error Handling

For `classify_messages`:

- Empty active `message_classes`
  - logs `ERROR` (`CLASSIFY_MESSAGE_CLASSES_EMPTY`)
  - task fails without retry

- OpenAI or Ollama transport/API failure
  - task fails with retry

- Invalid AI response format
  - task fails without retry

- Unknown AI category
  - logs `WARNING`
  - category is mapped to `uncategorized`
  - if `uncategorized` is missing from active `message_classes`, task fails without retry

- LLM usage persistence (`llm_model_usage`) failure
  - task fails with retry

## Direct Payload Examples

### 1. Dummy fetch

```json
{
  "action": "get_dummy_messages",
  "booking_id": 51000002,
  "thread_id": 91000002,
  "platform_id": 1,
  "offset": 12,
  "limit": 6,
  "return_ref": {
    "worker": "messages-worker",
    "queue": "messages-service",
    "action": "fetch_res_handler"
  }
}
```

### 2. Live fetch

```json
{
  "action": "get_ownerrez_messages",
  "booking_id": 51000002,
  "thread_id": 9744759,
  "platform_id": 1,
  "offset": 9,
  "limit": 10,
  "return_ref": {
    "worker": "messages-worker",
    "queue": "messages-service",
    "action": "fetch_res_handler"
  }
}
```

### 3. Dummy classify

The request runtime variable should contain:

```json
{
  "items": [
    {
      "pk": 123,
      "body": "guest text"
    }
  ]
}
```

Payload:

```json
{
  "action": "classify_dummy_messages",
  "data_ref": {
    "worker_id": "worker-id-that-wrote-the-request",
    "scope": "classifier-extsvc",
    "key": "classify-input"
  },
  "return_ref": {
    "worker": "messages-worker",
    "queue": "messages-service",
    "action": "handle_classified_dummy_messages"
  }
}
```

### 4. Live classify

```json
{
  "action": "classify_messages",
  "data_ref": {
    "worker_id": "worker-id-that-wrote-the-request",
    "scope": "classifier-extsvc",
    "key": "classify-input"
  },
  "return_ref": {
    "worker": "messages-worker",
    "queue": "messages-service",
    "action": "handle_classified_messages"
  }
}
```

## Notes

- Callback payload shape for fetch/classify is unchanged (`result`, `error`, pagination fields, refs).
- The worker accepts both `return_ref` and legacy `return_handler*` callback fields.
- Canonical upstream emitters use `percentage`/`fixed`; compatibility-only legacy `flat` can still be accepted at the external-worker boundary and normalized by provider adapters.
- On process shutdown/restart, the shared OwnerRez client singleton is reset so the underlying `httpx` client is closed.
- Live classify writes one batch-level row into `llm_model_usage` (including token counts when available).

## Adding A New Provider Adapter

1. Add a new module under `external-services-worker/providers/` implementing adapter methods:
   - `build_execution_plan(target, instruction, helpers)`
   - `execute_plan(plan, helpers)`
2. Register the adapter in `providers/registry.py`.
3. Add/extend focused tests in `tests/worker_tests/test_external_services_process_instruction.py`.
4. Update specification docs under `workers/specifications/`.

## `process_instruction` Debug Mock Mode

- When `LOG_LEVEL=DEBUG`, `process_instruction` does not send live HTTP requests to `OwnerRez`, `PriceLabs`, or `Wheelhouse`.
- In this mode, request execution is mocked with a per-request failure rate of `0.1` (10%).
- Mocked failures are surfaced as retryable provider failures so normal retry behavior is preserved.
