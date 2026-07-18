-- ============================================================================
-- PROPERTY PLATFORM SEED DATA
-- ============================================================================
-- Run AFTER: schemas/property_platform_sql.sql
-- Purpose:
--   - Optional seed records for local experimentation
--
-- NOTE:
--   This file is intentionally excluded from automatic bootstrap.
-- ============================================================================

-- ============================================================================
-- SAMPLE DATA (For testing and demonstration)
-- ============================================================================

-- Insert sample platforms representing different integration types
INSERT INTO Platforms (name, type, is_active) VALUES
    ('OwnerRez', 'pms', TRUE),              -- Platform ID: 1 (Property Management Software)
    ('PriceLabs', 'dpt', TRUE),             -- Platform ID: 2 (Dynamic Pricing Tool)
    ('Beyond Pricing', 'dpt', TRUE),        -- Platform ID: 3 (Dynamic Pricing Tool)
    ('Airbnb', 'ota', TRUE),                -- Platform ID: 4 (Online Travel Agency)
    ('VRBO', 'ota', TRUE);                  -- Platform ID: 5 (Online Travel Agency)

-- Note: After inserting, platform IDs are:
-- 1 = OwnerRez (PMS)
-- 2 = PriceLabs (DPT)
-- 3 = Beyond Pricing (DPT)
-- 4 = Airbnb (OTA)
-- 5 = VRBO (OTA)


-- ============================================================================
-- HYPOTHETICAL SCENARIO: Beach Property Management Company
-- ============================================================================
-- Company: "Coastal Rentals Inc."
-- Scenario: Managing 3 beach properties across multiple platforms
-- 
-- PROPERTY 1: "Miami Beach Luxury Condo"
--   - Location: Miami Beach, FL (25.7617° N, 80.1918° W)
--   - Listed on: OwnerRez (PMS), Airbnb, PriceLabs
--
-- PROPERTY 2: "Key West Sunset Villa"  
--   - Location: Key West, FL (24.5551° N, 81.7800° W)
--   - Listed on: OwnerRez (PMS), VRBO, PriceLabs, Beyond Pricing
--
-- PROPERTY 3: "Fort Lauderdale Beach House"
--   - Location: Fort Lauderdale, FL (26.1224° N, 80.1373° W)  
--   - Listed on: OwnerRez (PMS), Airbnb, VRBO
-- ============================================================================


-- ----------------------------------------------------------------------------
-- STEP 1: Add properties using the interface function
-- ----------------------------------------------------------------------------

-- Property 1: Miami Beach Luxury Condo on OwnerRez
-- This creates both the property record AND the platform mapping
SELECT link_platform_property(
    1,                              -- platform_id (OwnerRez)
    'ownerrez_miami_001',          -- platform's property ID
    '25.7617',                     -- latitude
    '-80.1918',                    -- longitude
    '{
        "name": "Miami Beach Luxury Condo",
        "street": "1500 Ocean Drive",
        "city": "Miami Beach",
        "state": "FL",
        "zip": "33139",
        "country": "USA",
        "bedrooms": 2,
        "bathrooms": 2,
        "sleeps": 6
    }'::JSONB
);
-- This returns the lookup ID (e.g., 1)

-- Property 2: Key West Sunset Villa on OwnerRez
SELECT link_platform_property(
    1,                              -- platform_id (OwnerRez)
    'ownerrez_keywest_002',        -- platform's property ID
    '24.5551',                     -- latitude
    '-81.7800',                    -- longitude
    '{
        "name": "Key West Sunset Villa",
        "street": "245 Duval Street",
        "city": "Key West",
        "state": "FL",
        "zip": "33040",
        "country": "USA",
        "bedrooms": 4,
        "bathrooms": 3,
        "sleeps": 10
    }'::JSONB
);

-- Property 3: Fort Lauderdale Beach House on OwnerRez
SELECT link_platform_property(
    1,                              -- platform_id (OwnerRez)
    'ownerrez_ftlaud_003',         -- platform's property ID
    '26.1224',                     -- latitude
    '-80.1373',                    -- longitude
    '{
        "name": "Fort Lauderdale Beach House",
        "street": "789 Beachfront Blvd",
        "city": "Fort Lauderdale",
        "state": "FL",
        "zip": "33304",
        "country": "USA",
        "bedrooms": 5,
        "bathrooms": 4,
        "sleeps": 12
    }'::JSONB
);


-- ----------------------------------------------------------------------------
-- STEP 2: Add same properties to other platforms (using SAME coordinates)
-- ----------------------------------------------------------------------------

-- Property 1 on Airbnb
-- IMPORTANT: Same lat/lon as OwnerRez listing, so it links to same property
SELECT link_platform_property(
    4,                              -- platform_id (Airbnb)
    'airbnb_miami_beach_xyz',      -- Airbnb's property ID
    '25.7617',                     -- SAME latitude as OwnerRez
    '-80.1918',                    -- SAME longitude as OwnerRez
    '{"name": "Miami Beach Luxury Condo"}'::JSONB
);

-- Property 1 on PriceLabs
SELECT link_platform_property(
    2,                              -- platform_id (PriceLabs)
    'pl_miami_001',                -- PriceLabs property ID
    '25.7617',                     -- SAME coordinates
    '-80.1918',
    '{"name": "Miami Beach Luxury Condo"}'::JSONB
);

-- Property 2 on VRBO
SELECT link_platform_property(
    5,                              -- platform_id (VRBO)
    'vrbo_8675309',                -- VRBO listing ID
    '24.5551',                     -- Same as OwnerRez
    '-81.7800',
    '{"name": "Key West Sunset Villa"}'::JSONB
);

-- Property 2 on PriceLabs
SELECT link_platform_property(
    2,                              -- platform_id (PriceLabs)
    'pl_keywest_002',              -- PriceLabs property ID
    '24.5551',
    '-81.7800',
    '{"name": "Key West Sunset Villa"}'::JSONB
);

-- Property 2 on Beyond Pricing
SELECT link_platform_property(
    3,                              -- platform_id (Beyond Pricing)
    'bp_keywest_villa',            -- Beyond Pricing ID
    '24.5551',
    '-81.7800',
    '{"name": "Key West Sunset Villa"}'::JSONB
);

-- Property 3 on Airbnb
SELECT link_platform_property(
    4,                              -- platform_id (Airbnb)
    'airbnb_ftlaud_abc',           -- Airbnb's property ID
    '26.1224',
    '-80.1373',
    '{"name": "Fort Lauderdale Beach House"}'::JSONB
);

-- Property 3 on VRBO
SELECT link_platform_property(
    5,                              -- platform_id (VRBO)
    'vrbo_5551212',                -- VRBO listing ID
    '26.1224',
    '-80.1373',
    '{"name": "Fort Lauderdale Beach House"}'::JSONB
);
