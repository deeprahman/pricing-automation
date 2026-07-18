# Platform Listing List UI Specification

## Purpose

This specification defines how the PWS Admin UI should render a fetched listing list for any platform, including PMS, OTA, and DPT platforms such as PriceLabs and Wheelhouse.

The main rule is:

> A platform listing list must show provider listings as provider listings. It must not infer duplicate listings from shared latitude/longitude.

Latitude/longitude is only a property-linking hint. It is not a listing identity.

## 1. Scope

This applies to listing tables shown after a platform fetch, including:

- `Properties -> Import/Sync`
- DPT listing import flows
- future platform-specific listing list screens
- PriceLabs
- Wheelhouse
- OwnerRez
- any new platform added through `platforms.metadata`

## 2. Listing Identity

Every fetched listing row must have one stable platform identity.

Preferred identity fields:

- `platform_id`
- `platform_property_id`
- provider listing id from the raw payload, such as `raw.id`
- provider/source key when required, such as PriceLabs `pms`

For PriceLabs, listing identity is:

```text
pms + ":" + platform_property_id
```

Example:

```text
ownerrez:393858
```

Do not use coordinates as identity.

## 3. Coordinate Semantics

Coordinates are used only for matching against local `properties` rows and suggesting link candidates.

The UI must allow multiple fetched listings to have the same coordinates without marking them as duplicates.

Example valid listing set:

```text
5358 W Wrightwood Ave - Basement 2/1      41.9279317,-87.7610561
5358 W Wrightwood Ave 1st Floor 2/1       41.9279317,-87.7610561
5358 W Wrightwood Ave 2nd Floor 2/1       41.9279317,-87.7610561
5358 W Wrightwood Ave Whole Property 6/3  41.9279317,-87.7610561
```

These are separate listings. The UI must not label them `Duplicate in fetched list` only because coordinates match.

## 4. Backend Annotation Contract

The backend fetch endpoint should return normalized listing rows plus link annotations.

Endpoint pattern:

```text
GET /pwsadmin/api/platforms/{platform_id}/properties/remote?fetch_all=true&per_page=100
```

Each returned item should include:

```json
{
  "platform_property_id": "393858",
  "name": "5358 W Wrightwood Ave 1st Floor 2/1",
  "pms": "ownerrez",
  "latitude": "41.9279317",
  "longitude": "-87.7610561",
  "city": "Chicago",
  "state": "Illinois",
  "country": "United States",
  "raw": {},
  "existing_property_id": null,
  "existing_property_name": null,
  "is_linked_on_platform": false,
  "is_auto_selected": false,
  "auto_select_reason": null,
  "lookup_id": null,
  "link_candidates": [],
  "default_link_to_lookup_id": null,
  "link_selection_required": false,
  "link_problem": null,
  "same_platform_match_without_link": false,
  "existing_property_without_listings": false
}
```

The backend is responsible for:

- normalizing provider payloads into consistent fields
- checking whether the listing is already linked on the selected platform
- finding local property matches by coordinates
- building link candidates from existing platform-property chains
- flagging rows that require an explicit link choice
- blocking rows only when there is a real link/import problem

## 5. Frontend Responsibilities

The frontend listing table must:

- render the returned rows without provider-specific duplicate-coordinate logic
- preserve the backend annotation fields
- select rows by `platform_property_id`
- show provider-specific columns only for display
- show link controls from `link_candidates`
- set `selected_link_to_lookup_id` from `default_link_to_lookup_id`
- send `link_to_lookup_id` on import when required

The frontend must initialize fetched rows like this:

```js
const fetchedItems = Array.isArray(res.items) ? res.items : [];
const annotatedItems = fetchedItems.map((item) => ({ ...item, is_coordinate_duplicate: false }));
remoteCache = annotatedItems.map((item) => ({
  ...item,
  selected_link_to_lookup_id: normalizeLookupId(item.default_link_to_lookup_id),
}));
```

There must not be a PriceLabs-only or Wheelhouse-only coordinate duplicate pass.

## 6. Highlight Rules

Rows may be highlighted only from backend annotation states.

Allowed highlight reasons:

- `link_problem` exists and row cannot be imported
- `existing_property_without_listings` is true
- `link_selection_required` is true and no link is selected
- `is_auto_selected` is true

Do not highlight because:

- two fetched listings have the same latitude/longitude
- a listing name looks similar to another fetched listing
- multiple units are in the same building
- a whole-property listing shares coordinates with unit listings

## 7. Badge Rules

The `Auto` or status badge column may show:

- `Linked`
- `Lat/Lon match #{property_id}`
- `Select listing`
- `Preselected`
- `Same-platform match`
- `{Property #id | name} has no listings yet`
- `Duplicate in fetched list` only when a real duplicate identity is returned by the backend or by an explicitly identity-based dedupe check

Do not show `Duplicate in fetched list` for shared coordinates.

## 8. Provider-Specific Columns

Column sets may vary by platform, but behavior must remain consistent.

OwnerRez:

- Name
- ID
- City
- State
- Country
- Timezone
- Currency
- Public URL
- Lat/Lon
- Link To
- Auto

PriceLabs:

- Name
- ID
- City
- State
- Country
- Lat/Lon
- Push Enabled
- Link To
- Auto

Wheelhouse:

- Name
- ID
- Lat/Lon
- Link To
- Auto

Provider-specific columns are display-only. They must not change duplicate or highlight semantics.

## 9. Import Behavior

When importing selected rows:

1. Reject if no rows are selected.
2. Reject if any selected row has a blocking `link_problem`.
3. Reject if any selected row has `link_selection_required` and no selected link.
4. Send each selected row with:

```json
{
  "platform_property_id": "393858",
  "name": "5358 W Wrightwood Ave 1st Floor 2/1",
  "latitude": "41.9279317",
  "longitude": "-87.7610561",
  "link_to_lookup_id": null,
  "raw": {}
}
```

The backend must re-annotate and validate import choices before writing.

## 10. New Platform Checklist

When adding listing-list UI support for a platform:

- Add fetch normalization in the backend.
- Map provider id to `platform_property_id`.
- Preserve raw payload in `raw`.
- Include coordinates when available.
- Add display columns in `getRemoteColumnDefinitions(platform)`.
- Do not add provider-specific coordinate duplicate detection.
- Use backend link annotations for row highlight state.
- Add tests confirming shared coordinates are not treated as fetched duplicates.

## 11. Regression Rule From PriceLabs/Wheelhouse

PriceLabs and Wheelhouse must behave the same way for shared coordinates:

- shared coordinates are allowed
- shared coordinates do not mean duplicate
- shared coordinates do not create a frontend duplicate badge
- shared coordinates do not create extra frontend highlight behavior
- only backend link annotations may highlight rows

