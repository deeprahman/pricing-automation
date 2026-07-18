-- ============================================================================
-- DEFAULT PLATFORMS SEED DATA
-- ============================================================================
-- Run AFTER: schemas/property_platform_sql.sql
-- Purpose:
--   - Seed default platform integrations:
--       1) OwnerRez  -> pms
--       2) PriceLabs -> dpt
--       3) Wheelhouse -> dpt
--   - Store instruction-driven metadata templates in platforms.metadata
--   - Keep secret pointers unresolved (NULL) for later API key/token wiring
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Dependency validation
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.platforms') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platforms. Run schemas/property_platform_sql.sql first.';
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- Default platform rows (idempotent by name)
-- ----------------------------------------------------------------------------
INSERT INTO platforms (name, type, is_active, metadata)
VALUES
    (
        'OwnerRez',
        'pms',
        TRUE,
        '{
            "domain": "https://api.ownerrez.com",
            "secret": {
                "OAuth Access Token": {
                    "Name": "Authorization",
                    "type": "Bearer Token",
                    "secret_table_ptr": null
                }
            },
            "endpoints": {
                "properties": {
                    "path_prefix": "/v2",
                    "path": "/properties",
                    "request_type": "get",
                    "params": {
                        "active": true
                    },
                    "required_property_fields": {
                        "platform_property_id": "id",
                        "latitude": "latitude",
                        "longitude": "longitude",
                        "timezone": "time_zone",
                        "currency_code": "currency_code",
                        "public_url": "public_url",
                        "city": "address.city",
                        "country": "address.country",
                        "state": "address.state"
                    },
                    "constraints": {
                        "only_include_active": true
                    }
                }
            }
        }'::jsonb
    ),
    (
        'PriceLabs',
        'dpt',
        TRUE,
        '{
            "domain": "https://api.pricelabs.co",
            "secret": {
                "Customer API Key": {
                    "Name": "X-API-Key",
                    "type": "API Key",
                    "secret_table_ptr": null
                }
            },
            "endpoints": {
                "listings": {
                    "path_prefix": "/v1",
                    "path": "/listings",
                    "request_type": "get",
                    "params": {
                        "skip_hidden": "<boolean>",
                        "only_syncing_listings": "<boolean>"
                    }
                },
                "listing_date_specific_overrides": {
                    "path_prefix": "/v1",
                    "path": "/listings/{listing_id}/overrides",
                    "request_type": "post",
                    "body": {
                        "overrides": [
                            {
                                "date": "YYYY-MM-DD",
                                "price": "<number>",
                                "price_type": "fixed|percent",
                                "currency": "USD",
                                "min_stay": "<number>",
                                "min_price": "<number>",
                                "min_price_type": "fixed|percent_base|percent_min",
                                "max_price": "<number>",
                                "max_price_type": "fixed|percent_base|percent_max",
                                "base_price": "<number>",
                                "check_in_check_out_enabled": "0|1",
                                "check_in": "0000000",
                                "check_out": "0000000",
                                "reason": "string"
                            }
                        ],
                        "pms": "airbnb",
                        "update_children": "<boolean>"
                    }
                },
                "delete_listing_date_specific_overrides": {
                    "path_prefix": "/v1",
                    "path": "/listings/{listing_id}/overrides",
                    "request_type": "delete",
                    "body": {
                        "overrides": [
                            {
                                "date": "YYYY-MM-DD"
                            }
                        ],
                        "pms": "airbnb",
                        "update_children": "<boolean>"
                    }
                }
            },
            "listing_filters": {
                "exclude_push_enabled": false
            }
        }'::jsonb
    ),
    (
        'Wheelhouse',
        'dpt',
        TRUE,
        '{
            "domain": "https://api.usewheelhouse.com",
            "secret": {
                "RM API Key": {
                    "Name": "X-Integration-Api-Key",
                    "type": "API Key",
                    "required": true,
                    "secret_table_ptr": null
                }
            },
            "endpoints": {
                "listings": {
                    "path_prefix": "/ss_api/v1",
                    "path": "/listings",
                    "request_type": "get",
                    "params": {
                        "offset": "<number>",
                        "page": "<number>",
                        "per_page": "<number>",
                        "exclude_inactive": "<boolean>"
                    }
                },
                "bulk_set_custom_rates": {
                    "path_prefix": "/ss_api/v1",
                    "path": "/listings/{listing_id}/bulk_custom_rates",
                    "request_type": "put",
                    "body": {
                        "custom_rates": [
                            {
                                "start_date": "YYYY-MM-DD",
                                "end_date": "YYYY-MM-DD",
                                "rate_type": "fixed|adjustment",
                                "currency": "USD",
                                "adjustment": "<number>",
                                "monday": "<number>",
                                "tuesday": "<number>",
                                "wednesday": "<number>",
                                "thursday": "<number>",
                                "friday": "<number>",
                                "saturday": "<number>",
                                "sunday": "<number>"
                            }
                        ]
                    }
                },
                "bulk_delete_custom_rates": {
                    "path_prefix": "/ss_api/v1",
                    "path": "/listings/{listing_id}/bulk_custom_rates",
                    "request_type": "delete",
                    "body": {
                        "delete_ranges": [
                            {
                                "start_date": "YYYY-MM-DD",
                                "end_date": "YYYY-MM-DD"
                            }
                        ]
                    }
                }
            }
        }'::jsonb
    )
ON CONFLICT (name) DO UPDATE
SET
    type = EXCLUDED.type,
    is_active = EXCLUDED.is_active,
    metadata = EXCLUDED.metadata;

COMMIT;
