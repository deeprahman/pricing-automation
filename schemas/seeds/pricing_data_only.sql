--
-- PostgreSQL database dump
--

\restrict goWx6neaIUenXSrlboN3PgyfAXhYy8U22Oa1oudmuPkL5CvP5gSgn8VTjVcSuD5

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
SET session_replication_role = replica;

--
-- Data for Name: pricing_rules; Type: TABLE DATA; Schema: public; Owner: n8n
--

COPY public.pricing_rules (id, rule_uuid, property_id, platform_id, platform_property_lookup_id, operation_id, rule_config, applicable_dates, start_date, end_date, day_of_week_pattern, rule_name, rule_description, priority, status, allow_override, requires_approval, approved_by, approved_at, created_by, created_via, applied_count, last_applied_at, created_at, updated_at, activated_at, expires_at) FROM stdin;
1	9587ea68-0dd8-4e45-86b8-4a56f0386d50	\N	\N	2	1	{"subject": "price", "operation": {"type": "percentage", "amount": 10}, "conditions": {"booking_category": {"in": ["job_related", "medical_related"]}}, "apply_window": {"applies_from": "departure", "duration_days": 3}}	\N	2026-01-01	2026-12-08	\N	Rule increase	\N	50	active	t	f	\N	\N	dp.rahman@gmail.com	pwsadmin	0	\N	2026-04-08 18:44:39.258718+06	2026-04-08 18:44:39.258718+06	\N	\N
\.


--
-- Data for Name: pricing_rule_audit; Type: TABLE DATA; Schema: public; Owner: n8n
--

COPY public.pricing_rule_audit (id, rule_id, rule_uuid, operation, actor_id, actor_type, old_values, new_values, ip_address, user_agent, api_key_prefix, success, error_message, created_at) FROM stdin;
1	1	9587ea68-0dd8-4e45-86b8-4a56f0386d50	cache_invalidate	dp.rahman@gmail.com	system	\N	{"invalidated_prices": 0}	\N	\N	\N	t	\N	2026-04-08 18:44:39.258718+06
\.


--
-- Name: pricing_rule_audit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: n8n
--

SELECT pg_catalog.setval('public.pricing_rule_audit_id_seq', 1, true);


--
-- Name: pricing_rules_id_seq; Type: SEQUENCE SET; Schema: public; Owner: n8n
--

SELECT pg_catalog.setval('public.pricing_rules_id_seq', 1, true);
SET session_replication_role = origin;


--
-- PostgreSQL database dump complete
--

\unrestrict goWx6neaIUenXSrlboN3PgyfAXhYy8U22Oa1oudmuPkL5CvP5gSgn8VTjVcSuD5
