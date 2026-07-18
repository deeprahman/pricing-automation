-- ============================================================================
-- PROPERTY PLATFORM DEMO QUERIES
-- ============================================================================
-- Run AFTER:
--   1) schemas/property_platform_sql.sql
--   2) schemas/seeds/property_platform_sql.seed_data.sql
-- Purpose:
--   - Demonstrate query patterns and operational scenarios
-- ============================================================================

-- ============================================================================
-- USING THE INTERFACE FUNCTIONS - PRACTICAL EXAMPLES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- EXAMPLE 1: Cross-Platform Lookup
-- ----------------------------------------------------------------------------
-- Question: "I have an Airbnb booking for 'airbnb_miami_beach_xyz'. 
--            Where else is this property listed so I can block the calendar?"

SELECT * FROM get_cross_platform_properties(4, 'airbnb_miami_beach_xyz');

-- Expected Result:
-- platform_id | platform_property_id    | platform_name | platform_type
-- ------------|------------------------|---------------|---------------
-- 1           | ownerrez_miami_001     | OwnerRez      | pms
-- 2           | pl_miami_001           | PriceLabs     | dpt
-- 4           | airbnb_miami_beach_xyz | Airbnb        | ota

-- Interpretation: This property is also on OwnerRez (ID: ownerrez_miami_001) 
-- and PriceLabs (ID: pl_miami_001). You need to block calendars on those platforms too.


-- ----------------------------------------------------------------------------
-- EXAMPLE 2: Get Property Details
-- ----------------------------------------------------------------------------
-- Question: "What are the full details of VRBO property 'vrbo_8675309'?"

SELECT * FROM get_property_details(5, 'vrbo_8675309');

-- Expected Result:
-- internal_property_id | latitude | longitude  | property_name         | full_details
-- ---------------------|----------|------------|-----------------------|-------------
-- 2                    | 24.5551  | -81.7800   | Key West Sunset Villa | {"name": "Key West..."...}

-- You can extract specific fields from full_details:
SELECT 
    property_name,
    latitude,
    longitude,
    full_details->>'bedrooms' AS bedrooms,
    full_details->>'city' AS city,
    full_details->>'street' AS street
FROM get_property_details(5, 'vrbo_8675309');


-- ----------------------------------------------------------------------------
-- EXAMPLE 3: List All Properties on a Platform
-- ----------------------------------------------------------------------------
-- Question: "Show me all properties we manage on Airbnb"

SELECT * FROM get_all_properties_on_platform(4);

-- Expected Result:
-- internal_property_id | platform_property_id    | property_name                  | latitude | longitude  | city            | state
-- ---------------------|------------------------|--------------------------------|----------|------------|-----------------|-------
-- 1                    | airbnb_miami_beach_xyz | Miami Beach Luxury Condo       | 25.7617  | -80.1918   | Miami Beach     | FL
-- 3                    | airbnb_ftlaud_abc      | Fort Lauderdale Beach House    | 26.1224  | -80.1373   | Fort Lauderdale | FL


-- ----------------------------------------------------------------------------
-- EXAMPLE 4: Find Platform ID by Name
-- ----------------------------------------------------------------------------
-- Useful when you have a platform name string from user input or config

SELECT get_platform_id_by_name('PriceLabs');
-- Returns: 2

-- Use in conjunction with other functions:
SELECT * FROM get_all_properties_on_platform(
    get_platform_id_by_name('PriceLabs')
);


-- ----------------------------------------------------------------------------
-- EXAMPLE 5: Adding a New Property Dynamically
-- ----------------------------------------------------------------------------
-- Scenario: A new Airbnb listing is created via webhook

DO $$
DECLARE
    new_lookup_id INT;
BEGIN
    -- Add the property
    new_lookup_id := link_platform_property(
        get_platform_id_by_name('Airbnb'),
        'airbnb_new_listing_123',
        '25.7900',
        '-80.1300',
        '{
            "name": "Downtown Miami Apartment",
            "city": "Miami",
            "state": "FL",
            "bedrooms": 1,
            "bathrooms": 1
        }'::JSONB
    );
    
    RAISE NOTICE 'Created new property mapping with ID: %', new_lookup_id;
END $$;


-- ----------------------------------------------------------------------------
-- EXAMPLE 6: Syncing Properties Across Platforms
-- ----------------------------------------------------------------------------
-- Scenario: You added a property to OwnerRez, now add it to PriceLabs

DO $$
DECLARE
    property_info RECORD;
    new_lookup_id INT;
BEGIN
    -- Get the property details from OwnerRez
    SELECT * INTO property_info 
    FROM get_property_details(1, 'ownerrez_miami_001');
    
    -- Add to PriceLabs with the SAME coordinates if not already linked.
    -- This keeps the example idempotent for container bootstrap runs.
    IF EXISTS (
        SELECT 1
        FROM platform_property_lookup ppl
        WHERE ppl.platform_id = get_platform_id_by_name('PriceLabs')
          AND ppl.properties_ptr = property_info.internal_property_id
    ) THEN
        RAISE NOTICE 'Property already linked to PriceLabs, skipping sync example';
    ELSE
        new_lookup_id := link_platform_property(
            get_platform_id_by_name('PriceLabs'),
            'pl_auto_sync_001',                  -- New PriceLabs ID
            property_info.latitude,              -- Same coordinates
            property_info.longitude,
            property_info.full_details
        );

        RAISE NOTICE 'Synced property to PriceLabs with lookup ID: %', new_lookup_id;
    END IF;
END $$;


-- ----------------------------------------------------------------------------
-- EXAMPLE 7: Bulk Query - Properties Missing from a Platform
-- ----------------------------------------------------------------------------
-- Question: "Which properties are on OwnerRez but NOT on Airbnb?"

SELECT 
    p.id AS property_id,
    p.descrp->>'name' AS property_name,
    ppl_or.platform_property_id AS ownerrez_id
FROM Properties p
JOIN Platform_Property_Lookup ppl_or 
    ON p.id = ppl_or.properties_ptr 
    AND ppl_or.platform_id = 1  -- OwnerRez
LEFT JOIN Platform_Property_Lookup ppl_ab 
    ON p.id = ppl_ab.properties_ptr 
    AND ppl_ab.platform_id = 4  -- Airbnb
WHERE ppl_ab.id IS NULL;  -- Not on Airbnb

-- Expected Result:
-- property_id | property_name           | ownerrez_id
-- ------------|------------------------|------------------
-- 2           | Key West Sunset Villa   | ownerrez_keywest_002


-- ----------------------------------------------------------------------------
-- EXAMPLE 8: Update Property Details
-- ----------------------------------------------------------------------------
-- Scenario: Property details changed, update the canonical record

DO $$
DECLARE
    prop_id INT;
BEGIN
    -- Get the internal property ID
    SELECT internal_property_id INTO prop_id
    FROM get_property_details(1, 'ownerrez_miami_001');
    
    -- Update the property details
    UPDATE Properties
    SET descrp = descrp || '{"sleeps": 8, "pool": true}'::JSONB
    WHERE id = prop_id;
    
    RAISE NOTICE 'Updated property % with new details', prop_id;
END $$;

-- The update is immediately reflected across ALL platforms
-- since they all point to the same Properties record


-- ----------------------------------------------------------------------------
-- EXAMPLE 9: Generate Cross-Platform Report
-- ----------------------------------------------------------------------------
-- Question: "Show me a summary of all properties and their platform presence"

SELECT 
    p.id AS property_id,
    p.descrp->>'name' AS property_name,
    p.descrp->>'city' AS city,
    COUNT(DISTINCT ppl.platform_id) AS platform_count,
    STRING_AGG(DISTINCT plat.name, ', ' ORDER BY plat.name) AS platforms,
    STRING_AGG(DISTINCT ppl.platform_property_id, ', ') AS platform_ids
FROM Properties p
LEFT JOIN Platform_Property_Lookup ppl ON p.id = ppl.properties_ptr
LEFT JOIN Platforms plat ON ppl.platform_id = plat.id
GROUP BY p.id, p.descrp
ORDER BY platform_count DESC, p.id;

-- Expected Result:
-- property_id | property_name                  | city            | platform_count | platforms                        | platform_ids
-- ------------|--------------------------------|-----------------|----------------|----------------------------------|---------------------------
-- 2           | Key West Sunset Villa          | Key West        | 4              | Beyond Pricing, OwnerRez, Pr...  | ownerrez_keywest_002, vr...
-- 1           | Miami Beach Luxury Condo       | Miami Beach     | 3              | Airbnb, OwnerRez, PriceLabs      | ownerrez_miami_001, airb...
-- 3           | Fort Lauderdale Beach House    | Fort Lauderdale | 3              | Airbnb, OwnerRez, VRBO           | ownerrez_ftlaud_003, air...


-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================
-- Run these to verify the data integrity and relationships

-- Check 1: Verify each property has unique lat/lon
SELECT 
    descrp->>'latitude' AS lat,
    descrp->>'longitude' AS lon,
    COUNT(*) AS count
FROM Properties
GROUP BY descrp->>'latitude', descrp->>'longitude'
HAVING COUNT(*) > 1;
-- Should return 0 rows (no duplicates)

-- Check 2: Verify no platform has duplicate property IDs
SELECT 
    platform_id,
    platform_property_id,
    COUNT(*) AS count
FROM Platform_Property_Lookup
GROUP BY platform_id, platform_property_id
HAVING COUNT(*) > 1;
-- Should return 0 rows (no duplicates)

-- Check 3: Verify each property appears max once per platform
SELECT 
    platform_id,
    properties_ptr,
    COUNT(*) AS count
FROM Platform_Property_Lookup
GROUP BY platform_id, properties_ptr
HAVING COUNT(*) > 1;
-- Should return 0 rows (no duplicates)

-- Check 4: View complete mapping
SELECT 
    plat.name AS platform,
    plat.type,
    ppl.platform_property_id,
    p.descrp->>'name' AS property_name,
    p.descrp->>'latitude' AS lat,
    p.descrp->>'longitude' AS lon
FROM Platform_Property_Lookup ppl
JOIN Platforms plat ON ppl.platform_id = plat.id
JOIN Properties p ON ppl.properties_ptr = p.id
ORDER BY p.id, plat.name;


-- ============================================================================
-- NOTES ON USING THE INTERFACE FUNCTIONS
-- ============================================================================
/*

KEY PRINCIPLES:

1. ALWAYS use link_platform_property() to add properties
   - Don't insert directly into Properties or Platform_Property_Lookup
   - The function handles duplicates and maintains data integrity

2. Use EXACT same coordinates when adding to multiple platforms
   - '25.7617' and '25.761700' are DIFFERENT strings
   - Inconsistent precision creates duplicate property records
   - Standardize to 6 decimal places (±0.11 meter accuracy)

3. Cross-platform queries are the main use case
   - get_cross_platform_properties() finds all platform IDs for syncing
   - Essential for calendar blocking, pricing sync, etc.

4. Property details are in JSONB for flexibility
   - Only lat/lon are required
   - Add any additional fields as needed
   - No schema changes required for new property attributes

5. Platforms can be temporarily disabled
   - Set is_active = FALSE instead of deleting
   - Functions automatically filter inactive platforms

COMMON WORKFLOWS:

A. Adding a new property from API webhook:
   1. Extract lat/lon and platform-specific ID from webhook
   2. Call link_platform_property() with all available details
   3. Function handles whether property already exists

B. Syncing a property to another platform:
   1. Call get_property_details() to get lat/lon
   2. Create listing on new platform's API
   3. Call link_platform_property() with same lat/lon and new platform ID

C. Handling a booking:
   1. Call get_cross_platform_properties() with booking's platform/ID
   2. Block calendar on all returned platforms
   3. Update pricing tools if applicable

D. Bulk import from platform API:
   1. Fetch all properties from platform
   2. Loop through and call link_platform_property() for each
   3. Function automatically handles existing vs new properties

*/
