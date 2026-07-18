from __future__ import annotations

from typing import Any


def coordinate_key(latitude: str, longitude: str) -> str:
    if not latitude or not longitude:
        return ""
    return f"{latitude},{longitude}"


def build_remote_link_annotations(
    items: list[dict[str, Any]],
    *,
    current_platform_id: int,
    linked_rows_by_platform_property_id: dict[str, dict[str, Any]],
    coordinate_candidates_by_key: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    annotated: list[dict[str, Any]] = []
    for item in items:
        row = dict(item)
        remote_platform_property_id = str(row.get("platform_property_id") or "").strip()
        latitude = str(row.get("latitude") or "").strip()
        longitude = str(row.get("longitude") or "").strip()
        if latitude:
            row["latitude"] = latitude
        if longitude:
            row["longitude"] = longitude

        linked_row = linked_rows_by_platform_property_id.get(remote_platform_property_id)
        coordinate_match = coordinate_candidates_by_key.get(coordinate_key(latitude, longitude)) if latitude and longitude else None
        existing_property = linked_row or coordinate_match or {}
        auto_select_reason: str | None = None
        all_link_candidates = list(coordinate_match.get("link_candidates") or []) if coordinate_match else []
        same_platform_candidates = [
            candidate
            for candidate in all_link_candidates
            if candidate.get("platform_id") == current_platform_id
        ]
        link_candidates = [
            candidate
            for candidate in all_link_candidates
            if candidate.get("platform_id") != current_platform_id
        ]
        default_link_to_lookup_id: int | None = None
        link_selection_required = False
        link_problem: str | None = None
        same_platform_match_without_link = False
        existing_property_without_listings = False

        if linked_row is not None:
            auto_select_reason = "already_linked_on_platform"
            default_link_to_lookup_id = linked_row.get("lookup_id")
            if default_link_to_lookup_id is not None and not any(
                candidate.get("lookup_id") == default_link_to_lookup_id for candidate in link_candidates
            ):
                link_candidates.insert(
                    0,
                    {
                        "lookup_id": linked_row.get("lookup_id"),
                        "property_id": linked_row.get("property_id"),
                        "platform_id": current_platform_id,
                        "platform_name": None,
                        "platform_type": None,
                        "platform_property_id": remote_platform_property_id,
                        "listing_name": linked_row.get("listing_name"),
                    },
                )
        elif coordinate_match is not None and coordinate_match.get("property_id") is not None:
            if link_candidates:
                auto_select_reason = "matched_by_coordinates"
                if len(link_candidates) == 1:
                    default_link_to_lookup_id = link_candidates[0].get("lookup_id")
                else:
                    link_selection_required = True
            elif same_platform_candidates:
                auto_select_reason = "matched_on_same_platform_without_link"
                same_platform_match_without_link = True
            else:
                auto_select_reason = "matched_existing_property_without_listings"
                existing_property_without_listings = True

        row["existing_property_id"] = existing_property.get("property_id") if existing_property else None
        row["existing_property_name"] = existing_property.get("property_name") if existing_property else None
        row["existing_property_latitude"] = existing_property.get("latitude") if existing_property else None
        row["existing_property_longitude"] = existing_property.get("longitude") if existing_property else None
        row["is_linked_on_platform"] = linked_row is not None
        row["is_auto_selected"] = row["existing_property_id"] is not None
        row["auto_select_reason"] = auto_select_reason
        row["lookup_id"] = linked_row.get("lookup_id") if linked_row else None
        row["link_candidates"] = link_candidates
        row["default_link_to_lookup_id"] = default_link_to_lookup_id
        row["link_selection_required"] = link_selection_required
        row["link_problem"] = link_problem
        row["same_platform_match_without_link"] = same_platform_match_without_link
        row["existing_property_without_listings"] = existing_property_without_listings
        annotated.append(row)
    return annotated


def resolve_import_link_choice(
    annotation: dict[str, Any],
    requested_link_to_lookup_id: int | None,
) -> tuple[int | None, str | None]:
    link_candidates = annotation.get("link_candidates") if isinstance(annotation.get("link_candidates"), list) else []
    candidate_lookup_ids = {
        int(candidate["lookup_id"])
        for candidate in link_candidates
        if candidate.get("lookup_id") is not None
    }
    existing_property_id = annotation.get("existing_property_id")
    existing_lookup_id = annotation.get("lookup_id")
    existing_property_without_listings = bool(annotation.get("existing_property_without_listings"))

    if (
        not existing_property_without_listings
        and annotation.get("link_problem") == "existing_coordinates_without_lookup"
        and existing_property_id is not None
        and not candidate_lookup_ids
    ):
        existing_property_without_listings = True

    if existing_property_without_listings:
        if requested_link_to_lookup_id is not None:
            return None, "link_to_lookup_id must be blank when the existing property has no listings yet"
        return None, None

    if annotation.get("is_linked_on_platform"):
        if requested_link_to_lookup_id is not None and requested_link_to_lookup_id != existing_lookup_id:
            return None, "Already linked on this platform; link_to_lookup_id must be blank or the current lookup_id"
        return None, None

    if annotation.get("same_platform_match_without_link"):
        return None, None

    if existing_property_id is not None:
        if requested_link_to_lookup_id is None:
            return None, "link_to_lookup_id is required when coordinates already exist"
        if requested_link_to_lookup_id not in candidate_lookup_ids:
            return None, "link_to_lookup_id must match one of the available listing candidates"
        return requested_link_to_lookup_id, None

    if requested_link_to_lookup_id is not None:
        return None, "link_to_lookup_id must be blank for new coordinates"

    return None, None
