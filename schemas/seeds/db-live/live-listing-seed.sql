--
-- PostgreSQL database dump
--

\restrict NoHxFoSRFHygKmPHvflzpH1xFzgR9pBkfrFxYag3mikwiHbUXxVLF5xgmKeTmIx

-- Dumped from database version 16.13 (Debian 16.13-1.pgdg13+1)
-- Dumped by pg_dump version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', 'public', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: properties; Type: TABLE DATA; Schema: public; Owner: n8n
--

COPY public.properties (id, descrp, created_at, updated_at) FROM stdin;
1	{"city": "Coconut Creek", "state": "Florida", "street": "370 Sunshine Dr Apt L4", "country": "UNITED STATES", "latitude": "26.235574", "longitude": "-80.176134", "postal_code": "33066"}	2026-04-07 19:14:46.498725+06	2026-04-07 19:14:46.498725+06
\.


--
-- Data for Name: platform_property_lookup; Type: TABLE DATA; Schema: public; Owner: n8n
--

COPY public.platform_property_lookup (id, properties_ptr, platform_id, listing_id, name, metadata, self, created_at, updated_at) FROM stdin;
1	1	1	370435	Rocky Creek L4 - 2/2	{"raw": {"id": 370435, "key": "55cd9bb8-1658-4a3d-9fc9-84dfe1afbd85", "name": "Rocky Creek L4 - 2/2", "active": true, "address": {"id": 691118246, "city": "Coconut Creek", "state": "Florida", "country": "UNITED STATES", "street1": "370 Sunshine Dr Apt L4", "is_default": false, "postal_code": "33066"}, "bedrooms": 2, "check_in": "16:00", "latitude": 26.235574, "max_pets": 0, "bathrooms": 2, "check_out": "10:00", "longitude": -80.176134, "time_zone": "America/New_York", "is_snoozed": false, "max_guests": 4, "public_url": "https://palmwavestays.com/370-sunshine-drive-l4-orp5b5a703x", "check_in_end": "22:00", "currency_code": "USD", "external_name": "L4 - Second Floor", "property_type": "apartment", "thumbnail_url": "https://uc.orez.io/i/95e4f63784064bba97782542785a01eb-Thumb", "bathrooms_full": 2, "bathrooms_half": 0, "thumbnail_url_large": "https://uc.orez.io/i/95e4f63784064bba97782542785a01eb-Large", "thumbnail_url_medium": "https://uc.orez.io/i/95e4f63784064bba97782542785a01eb-Medium"}, "city": "Coconut Creek", "name": "Rocky Creek L4 - 2/2", "state": "Florida", "country": "UNITED STATES", "timezone": "America/New_York", "public_url": "https://palmwavestays.com/370-sunshine-drive-l4-orp5b5a703x", "currency_code": "USD"}	\N	2026-04-07 19:14:46.498725+06	2026-04-07 19:14:46.503218+06
3	1	1	408676	420 50th St. Front 3/2	{"currency_code": "USD", "pms": "ownerrez", "source": "external_services_pricelabs_live_task"}	\N	2026-04-07 19:14:46.498725+06	2026-04-07 19:14:46.503218+06
2	1	3	370435	Rocky Creek L4 - 2/2	{"raw": {"id": "370435", "meta": {"photos": [], "num_beds": 2, "amenities": ["carbon_monoxide_detector", "air_conditioning", "cable_or_satellite_tv", "coffee_maker", "ceiling_fans", "cleaning_before_checkout", "dishwasher", "dryer", "ev_charger", "fire_extinguisher", "freezer", "hair_dryer", "laptop_friendly_workspace", "hangers", "heating", "hot_water", "microwave", "oven", "private_entrance", "private_living_room", "refrigerator", "room_darkening_shades", "shampoo", "smart_lock", "smoke_detector", "stove", "towel", "kitchen", "family_kid_friendly", "fresh_linens", "internet", "parking", "outdoor_activities", "indoor_entertainment", "washing_machine", "water_views", "cleaning_essentials", "services", "safety_features", "sports_activities", "policies"], "num_photos": 20, "num_reviews": 45, "star_rating": null, "source_user_id": "347405742", "security_deposit": null}, "links": {"upgrade": "https://app.usewheelhouse.com/u/account/billing/subscription?listing_id=48131763", "calendar": "https://app.usewheelhouse.com/l/48131763/calendar"}, "title": "Rocky Creek L4 - 2/2", "channel": "ownerrez", "currency": "USD", "location": {"address": "370 Sunshine Dr Apt L4 Coconut Creek Florida 33066 US", "country": "US", "latitude": 26.235574, "longitude": -80.176134, "postal_code": "33066"}, "nickname": null, "num_beds": 2, "amenities": ["carbon_monoxide_detector", "air_conditioning", "cable_or_satellite_tv", "coffee_maker", "ceiling_fans", "cleaning_before_checkout", "dishwasher", "dryer", "ev_charger", "fire_extinguisher", "freezer", "hair_dryer", "laptop_friendly_workspace", "hangers", "heating", "hot_water", "microwave", "oven", "private_entrance", "private_living_room", "refrigerator", "room_darkening_shades", "shampoo", "smart_lock", "smoke_detector", "stove", "towel", "kitchen", "family_kid_friendly", "fresh_linens", "internet", "parking", "outdoor_activities", "indoor_entertainment", "washing_machine", "water_views", "cleaning_essentials", "services", "safety_features", "sports_activities", "policies"], "is_active": true, "market_id": 149, "room_type": null, "thumb_url": "https://uc.orez.io/i/95e4f63784064bba97782542785a01eb-Thumb", "num_photos": 20, "owner_name": null, "channel_ids": {"wheelhouse": "48131763"}, "description": null, "num_reviews": 45, "star_rating": null, "num_bedrooms": 2, "num_bathrooms": 2, "property_type": "apartment", "wheelhouse_id": "48131763", "source_user_id": "347405742", "security_deposit": null, "base_min_night_stay": null, "listing_preferences": {"fees": [], "nickname": null, "min_price": 75, "base_price": null, "minimum_stay": 1, "num_max_guests": 4, "num_included_guests": 4, "weekly_discount_pct": 0, "monthly_discount_pct": 0, "base_price_adjustment": 1.1, "automatic_rate_posting_enabled": true}, "wheelhouse_created_at": "2024-07-27 05:45:33 -0700"}, "name": "Rocky Creek L4 - 2/2", "country": "US", "amenities": ["carbon_monoxide_detector", "air_conditioning", "cable_or_satellite_tv", "coffee_maker", "ceiling_fans", "cleaning_before_checkout", "dishwasher", "dryer", "ev_charger", "fire_extinguisher", "freezer", "hair_dryer", "laptop_friendly_workspace", "hangers", "heating", "hot_water", "microwave", "oven", "private_entrance", "private_living_room", "refrigerator", "room_darkening_shades", "shampoo", "smart_lock", "smoke_detector", "stove", "towel", "kitchen", "family_kid_friendly", "fresh_linens", "internet", "parking", "outdoor_activities", "indoor_entertainment", "washing_machine", "water_views", "cleaning_essentials", "services", "safety_features", "sports_activities", "policies"], "public_url": "https://app.usewheelhouse.com/l/48131763/calendar", "currency_code": "USD"}	1	2026-04-07 19:15:15.202112+06	2026-04-07 19:15:15.206654+06
\.


--
-- Data for Name: pricing_rules; Type: TABLE DATA; Schema: public; Owner: n8n
--

COPY public.pricing_rules (id, rule_uuid, property_id, platform_id, platform_property_lookup_id, operation_id, rule_config, applicable_dates, start_date, end_date, day_of_week_pattern, rule_name, rule_description, priority, status, allow_override, requires_approval, approved_by, approved_at, created_by, created_via, applied_count, last_applied_at, created_at, updated_at, activated_at, expires_at) FROM stdin;
1	bc93c7f9-05d0-465d-981b-ba90f507ffa8	\N	\N	1	1	{"subject": "price", "operation": {"type": "percentage", "amount": 20}, "conditions": {"booking_category": {"in": ["job_related", "medical_related"]}}, "apply_window": {"applies_from": "departure", "duration_days": 3}}	\N	2026-01-01	2026-12-31	\N	Rule increase	\N	50	active	t	f	\N	\N	dp.rahman@gmail.com	pwsadmin	0	\N	2026-04-07 19:17:38.250249+06	2026-04-07 19:17:38.250249+06	\N	\N
\.


--
-- Name: platform_property_lookup_id_seq; Type: SEQUENCE SET; Schema: public; Owner: n8n
--

SELECT pg_catalog.setval('public.platform_property_lookup_id_seq', 3, true);


--
-- Name: pricing_rule_audit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: n8n
--

SELECT pg_catalog.setval('public.pricing_rule_audit_id_seq', 1, true);


--
-- Name: pricing_rules_id_seq; Type: SEQUENCE SET; Schema: public; Owner: n8n
--

SELECT pg_catalog.setval('public.pricing_rules_id_seq', 1, true);


--
-- Name: properties_id_seq; Type: SEQUENCE SET; Schema: public; Owner: n8n
--

SELECT pg_catalog.setval('public.properties_id_seq', 1, true);


--
-- PostgreSQL database dump complete
--

\unrestrict NoHxFoSRFHygKmPHvflzpH1xFzgR9pBkfrFxYag3mikwiHbUXxVLF5xgmKeTmIx
