# Live Fixture Seeds

These seeds support `postClassificationLive` in [worker-fixture.sh](../../../tests/worker-fixture.sh) (PowerShell wrapper: [worker-fixture.ps1](../../../tests/worker-fixture.ps1)).

## Command

```bash
bash tests/worker-fixture.sh postClassificationLive
```

That command runs this sequence:

1. Reset the schema database.
2. Apply [live-listing-seed.sql](./live-listing-seed.sql).
3. Bootstrap fresh DB secret rows for OwnerRez and Wheelhouse from local secrets.
4. Apply [test_data_future_bookings_seed.sql](./test_data_future_bookings_seed.sql).
5. Apply [test_data_future_bookings_classified_seed.sql](./test_data_future_bookings_classified_seed.sql).

## Required Local Settings

The fixture reads process environment first and `.env.local` second.

- Secret encryption key: `SECRETS_ENCRYPTION_KEY` or `SECRET_ENCRYPTION_KEY`
- Optional secret key id: `SECRETS_ENCRYPTION_KEY_ID`, `SECRETS_KEY_ID`, or `SECRET_ENCRYPTION_KEY_ID`
- OwnerRez bearer token: `OWNERREZ_BEARER_TOKEN`
- Wheelhouse RM API key: `WHEELHOUSE_RM_API_KEY`
- Accepted local aliases for Wheelhouse RM API key: `WHEELHOUSE_INTEGRATION_KEY`, `WHEELHOUSE_ACCESS_KEY`, `WHEELHOUSE_API_KEY`, `WHEELHOUSE_USER_ACCESS_TOKEN`, `WHEELHOUSE_USER_API_KEY`

The DB secret bootstrap uses the same encryption-key family that the workers use at runtime. If that key is missing, `postClassificationLive` fails before reset.

## Seeded Live Cases

- Booking `54000001` / thread `95000001` includes message `97000017` and is classified as `medical_related`.
- Booking `54000002` / thread `95000002` includes message `97000027` and is classified as `job_related`.
- Booking `54000003` stays generic.
- Booking `54000004` includes a `checkout` reminder on message `97000048`.

The canonical active pricing rule stays on OwnerRez lookup `1` and matches both `job_related` and `medical_related`.

## Manual Downstream Smoke

Use the helper or enqueue equivalent payloads directly.

Medical path:

```json
{
  "worker": "property-platform-worker",
  "queue": "property-platform",
  "action": "get_linked_listings",
  "payload": {
    "booking_id": 54000001,
    "categories": ["medical_related"],
    "canonical_pair": {
      "platform_property_lookup_id": 1
    },
    "message_ids": [97000017]
  }
}
```

Job path:

```json
{
  "worker": "property-platform-worker",
  "queue": "property-platform",
  "action": "get_linked_listings",
  "payload": {
    "booking_id": 54000002,
    "categories": ["job_related"],
    "canonical_pair": {
      "platform_property_lookup_id": 1
    },
    "message_ids": [97000027]
  }
}
```

## Live Provider Note

Real OwnerRez and Wheelhouse smoke runs must not run with `LOG_LEVEL=DEBUG`, because the external-services worker uses debug mock mode for provider writes in that setting.
