-- ============================================================================
-- COMPLETE SQL IMPLEMENTATION
-- Property-Platform-Listing System with Linked Lists
-- ============================================================================
-- This file contains all database objects needed for the property-platform
-- listing system with linked list chain support.
--
-- Includes:
--   - ENUM types
--   - Tables (Platforms, Properties, Platform_Property_Lookup)
--   - Indexes
--   - Triggers
--   - Functions
--
-- Version: 1.0
-- Date: 2026-03-30
-- ============================================================================

-- ============================================================================
-- ENUM TYPE DEFINITIONS
-- ============================================================================

-- Platform type enumeration
-- pms: Property Management Software (e.g., OwnerRez, Guesty)
-- ota: Online Travel Agency (e.g., Airbnb, Booking.com, VRBO)
-- dpt: Dynamic Pricing Tool (e.g., PriceLabs, Beyond Pricing)
DO $$
BEGIN
    CREATE TYPE platform_type AS ENUM('pms', 'ota', 'dpt');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- UTILITY FUNCTION: update_updated_at_column
-- ============================================================================
-- Trigger function to automatically update the updated_at timestamp
-- This function is reused across all tables that need auto-updating timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PLATFORMS TABLE
-- ============================================================================
DROP TABLE IF EXISTS Platforms CASCADE;
CREATE TABLE Platforms (
    -- Primary key: Auto-incrementing unique identifier for each platform
    id SERIAL PRIMARY KEY,

    -- Platform name: Unique identifier (e.g., "Airbnb", "Booking", "OwnerRez")
    -- Must be unique across all platforms to prevent duplicate entries
    name TEXT NOT NULL UNIQUE,

    -- Platform type: Categorizes the platform as PMS, OTA, or DPT
    -- Uses the platform_type ENUM defined above
    type platform_type NOT NULL,

    -- Active status: Flag to enable/disable a platform without deleting it
    -- Useful for temporarily suspending integration with a platform
    -- Default: TRUE (platform is active by default)
    is_active BOOLEAN DEFAULT TRUE,

    -- Platform metadata: Flexible JSONB store for platform-specific configuration
    -- Expected shape (all keys optional):
    --   {
    --     "api": {
    --       "base_url":    "https://api.example.com/v2",
    --       "auth_scheme": "oauth2" | "api_key" | "basic",
    --       "version":     "2024-01"
    --     },
    --     "rate_limits": {
    --       "requests_per_minute": 60,
    --       "requests_per_day":    10000
    --     },
    --     "webhook": {
    --       "endpoint":   "https://hooks.example.com/events",
    --       "secret_ref": "vault:secret/platform/airbnb"
    --     },
    --     "sync": {
    --       "enabled":        true,
    --       "interval_hours": 1
    --     },
    --     "tags": ["primary", "revenue-tracked"]
    --   }
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    -- Creation timestamp: Records when the platform was first added
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Last update timestamp: Records the last modification time
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Constraint: metadata must be a JSON object, never an array or scalar
    CONSTRAINT chk_platforms_metadata_object
        CHECK (jsonb_typeof(metadata) = 'object')
);

-- Index on platform name for fast lookups
CREATE INDEX idx_platforms_name ON Platforms (name);

-- Index on platform type for filtering platforms by category
CREATE INDEX idx_platforms_type ON Platforms (type);

-- Partial index on active platforms only
CREATE INDEX idx_platforms_is_active ON Platforms (is_active) WHERE is_active = TRUE;

-- GIN index on metadata for efficient JSONB operator queries
CREATE INDEX idx_platforms_metadata_gin ON Platforms USING GIN (metadata);

-- Trigger to auto-update updated_at on any UPDATE to Platforms table
CREATE TRIGGER update_platforms_updated_at
    BEFORE UPDATE ON Platforms
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- PROPERTIES TABLE
-- ============================================================================
DROP TABLE IF EXISTS Properties CASCADE;
CREATE TABLE Properties (
    -- Primary key: Auto-incrementing unique identifier for each property
    id SERIAL PRIMARY KEY,

    -- Property description: JSONB object containing all property details
    -- Required fields: latitude, longitude (enforced by CHECK constraint)
    -- Optional fields: name, street, city, zip, state, country, etc.
    -- Example: {
    --   "latitude": "25.7617",
    --   "longitude": "-80.1918",
    --   "name": "Miami Beach House",
    --   "street": "123 Ocean Dr",
    --   "city": "Miami",
    --   "state": "FL",
    --   "country": "USA"
    -- }
    descrp JSONB NOT NULL,

    -- Creation timestamp: Records when the property was first added
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Last update timestamp: Records the last modification time
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Constraint: Ensure latitude and longitude are present in JSONB
    CHECK (
        descrp ? 'latitude'
        AND descrp ? 'longitude'
        AND descrp->>'latitude' IS NOT NULL
        AND descrp->>'longitude' IS NOT NULL
    ),

    -- Constraint: Validate latitude and longitude are within valid ranges
    CHECK (
        (descrp->>'latitude')::NUMERIC BETWEEN -90 AND 90
        AND (descrp->>'longitude')::NUMERIC BETWEEN -180 AND 180
    )
);

-- Unique constraint on latitude/longitude combination
-- Ensures that two properties with the same coordinates cannot exist
CREATE UNIQUE INDEX idx_properties_lat_lon_unique
ON Properties ((descrp->>'latitude'), (descrp->>'longitude'));

-- GIN index for JSONB queries
CREATE INDEX idx_properties_descrp_gin ON Properties USING GIN (descrp);

-- Trigger to auto-update updated_at on any UPDATE to Properties table
CREATE TRIGGER update_properties_updated_at
    BEFORE UPDATE ON Properties
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- PLATFORM_PROPERTY_LOOKUP TABLE
-- ============================================================================
DROP TABLE IF EXISTS Platform_Property_Lookup CASCADE;
CREATE TABLE Platform_Property_Lookup (
    -- Primary key: Auto-incrementing unique identifier for each mapping
    id SERIAL PRIMARY KEY,

    -- Foreign key to Properties table: Links to the canonical property record
    -- This is the internal property ID that ties all platform listings together
    properties_ptr INT NOT NULL,

    -- Foreign key to Platforms table: Identifies which platform this listing is on
    platform_id INT NOT NULL,

    -- Platform-specific listing ID: The ID used by the external platform
    -- This is the ID that the platform (e.g., Airbnb, OwnerRez) uses internally
    -- Examples: "site1_01111", "air123", "pl_abc456"
    listing_id TEXT NOT NULL,

    -- Optional listing name as provided by the source platform
    -- This is listing-specific and may differ across platforms for the same property
    name TEXT,

    -- Listing metadata: Listing-specific details from the source platform
    -- Expected shape (all keys optional):
    --   {
    --     "name": "Rocky Creek - Building H",
    --     "amenities": ["wifi", "pool"],
    --     "city": "Coconut Creek",
    --     "state": "Florida",
    --     "country": "UNITED STATES",
    --     "timezone": "America/New_York",
    --     "currency_code": "USD",
    --     "public_url": "https://...",
    --     "raw": { ...platform payload... }
    --   }
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    -- Self-referencing foreign key for linked list chain
    -- NULL: This listing is the HEAD of a chain (not linked)
    -- NOT NULL: This listing is linked to the listing with id = self
    -- This column creates the backward-pointing linked list
    self INT,

    -- Creation timestamp: Records when this platform mapping was created
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Last update timestamp: Records the last modification time
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Foreign key constraint: Ensures properties_ptr references valid Properties.id
    FOREIGN KEY (properties_ptr)
        REFERENCES Properties(id)
        ON DELETE CASCADE,

    -- Foreign key constraint: Ensures platform_id references valid Platforms.id
    FOREIGN KEY (platform_id)
        REFERENCES Platforms(id)
        ON DELETE CASCADE,

    -- Self-referencing foreign key for the linked list
    FOREIGN KEY (self)
        REFERENCES Platform_Property_Lookup(id)
        ON DELETE SET NULL,

    -- CONSTRAINT 1: Each platform can only have one listing with a given listing ID
    -- Prevents duplicate mappings like (Airbnb, "prop123") appearing twice
    UNIQUE(platform_id, listing_id),

    -- CONSTRAINT 2: Each listing ID in self column must be unique
    -- Ensures each listing has at most one incoming link
    UNIQUE(self),

    -- CONSTRAINT 3: Prevent self-linking
    -- A listing cannot link to itself (self cannot equal id)
    CHECK(self IS NULL OR self != id),

    -- CONSTRAINT 4: Ensure listing_id is not an empty string
    CHECK(listing_id <> ''),

    -- CONSTRAINT 5: metadata must be a JSON object
    CHECK (jsonb_typeof(metadata) = 'object')
);

-- Index for lookups by properties_ptr (find all mappings/listings for a property)
CREATE INDEX idx_platform_property_lookup_props
ON Platform_Property_Lookup (properties_ptr);

-- Index for lookups by platform_id (find all properties on a platform)
CREATE INDEX idx_platform_property_lookup_platform
ON Platform_Property_Lookup (platform_id);

-- Index for lookups by listing_id (reverse lookup from platform ID)
CREATE INDEX idx_platform_property_lookup_listing_id
ON Platform_Property_Lookup (listing_id);

-- Composite index for common query pattern (platform + property lookup)
CREATE INDEX idx_platform_property_lookup_composite
ON Platform_Property_Lookup (platform_id, properties_ptr);

-- Index on self column (used for chain traversal)
CREATE INDEX idx_platform_property_lookup_self
ON Platform_Property_Lookup (self) WHERE self IS NOT NULL;

-- Index for efficient chain traversal
CREATE INDEX idx_platform_property_lookup_chain_traversal
ON Platform_Property_Lookup (properties_ptr, platform_id);

-- GIN index for listing metadata queries
CREATE INDEX idx_platform_property_lookup_metadata_gin
ON Platform_Property_Lookup USING GIN (metadata);

-- Trigger to auto-update updated_at on any UPDATE to this table
CREATE TRIGGER update_platform_property_lookup_updated_at
    BEFORE UPDATE ON Platform_Property_Lookup
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- VALIDATION TRIGGER FUNCTION
-- ============================================================================
-- Trigger function to validate platform linking constraints
-- Enforces the business rule that listings on the same platform cannot link
CREATE OR REPLACE FUNCTION validate_platform_link()
RETURNS TRIGGER AS $$
DECLARE
    self_platform_id INT;
    self_property_ptr INT;
    chain_id INT;
    chain_count INT := 0;
    max_chain_depth INT := 100;
BEGIN
    -- Only validate if self is being set to a non-null value
    IF NEW.self IS NOT NULL THEN
        -- Get platform and property of the referenced listing
        SELECT platform_id, properties_ptr
        INTO self_platform_id, self_property_ptr
        FROM Platform_Property_Lookup
        WHERE id = NEW.self;

        -- Check if referenced listing exists
        IF self_platform_id IS NULL THEN
            RAISE EXCEPTION
                'Cannot link to non-existent listing (id: %)', NEW.self;
        END IF;

        -- CONSTRAINT 1: Platforms must be different
        IF self_platform_id = NEW.platform_id THEN
            RAISE EXCEPTION
                'Cannot link listing on platform % to another listing on the same platform. '
                'Listing % (platform %) cannot link to listing % (platform %)',
                NEW.platform_id,
                NEW.id, NEW.platform_id,
                NEW.self, self_platform_id;
        END IF;

        -- CONSTRAINT 2: Properties must be the same
        IF self_property_ptr != NEW.properties_ptr THEN
            RAISE EXCEPTION
                'Cannot link listings from different properties. '
                'Listing % (property %) cannot link to listing % (property %)',
                NEW.id, NEW.properties_ptr,
                NEW.self, self_property_ptr;
        END IF;

        -- CONSTRAINT 3: Check for circular references
        chain_id := NEW.self;
        WHILE chain_id IS NOT NULL AND chain_count < max_chain_depth LOOP
            IF chain_id = NEW.id THEN
                RAISE EXCEPTION
                    'Cannot create circular reference. '
                    'Linking listing % to listing % would create a cycle',
                    NEW.id, NEW.self;
            END IF;

            SELECT self INTO chain_id
            FROM Platform_Property_Lookup
            WHERE id = chain_id;

            chain_count := chain_count + 1;
        END LOOP;

        IF chain_count >= max_chain_depth THEN
            RAISE EXCEPTION
                'Chain depth exceeded (possible circular reference) for listing %',
                NEW.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to Platform_Property_Lookup
CREATE TRIGGER validate_platform_link_trigger
    BEFORE INSERT OR UPDATE ON Platform_Property_Lookup
    FOR EACH ROW
    EXECUTE FUNCTION validate_platform_link();

-- ============================================================================
-- FUNCTION 1: find_or_create_property
-- ============================================================================
-- Purpose: Find or create property, then create/update platform listing with
-- optional linking to an existing chain
--
-- Parameters:
--   prop_latitude: Latitude as TEXT
--   prop_longitude: Longitude as TEXT
--   prop_address: Address details in JSONB
--   input_platform_id: Platform ID
--   input_listing_id: Platform's listing ID
--   listing_name: Optional listing name stored on Platform_Property_Lookup.name
--   link_to_lookup_id: Optional lookup ID to link to (NULL = chain head)
--
-- Returns: The Platform_Property_Lookup.id (lookup_id)

CREATE OR REPLACE FUNCTION find_or_create_property(
    prop_latitude TEXT,
    prop_longitude TEXT,
    prop_address JSONB,
    input_platform_id INT,
    input_listing_id TEXT,
    link_to_lookup_id INT DEFAULT NULL
)
RETURNS INT AS $$
BEGIN
    RETURN find_or_create_property(
        prop_latitude,
        prop_longitude,
        prop_address,
        input_platform_id,
        input_listing_id,
        NULL,
        link_to_lookup_id
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION find_or_create_property(
    prop_latitude TEXT,
    prop_longitude TEXT,
    prop_address JSONB,
    input_platform_id INT,
    input_listing_id TEXT,
    listing_name TEXT,
    link_to_lookup_id INT DEFAULT NULL
)
RETURNS INT AS $$
DECLARE
    property_id INT;
    merged_details JSONB;
    normalized_listing_metadata JSONB;
    reference_properties_ptr INT;
    reference_platform_id INT;
    chain_tail_id INT;
    lookup_id INT;
    existing_lookup_id INT;
    current_self_value INT;
    self_value INT;
BEGIN
    -- STEP 1: Validate coordinates
    IF NOT (prop_latitude ~ '^-?([0-8]?[0-9](\.[0-9]{1,10})?|90(\.0{1,10})?)$') THEN
        RAISE EXCEPTION 'Invalid latitude: % (must be numeric between -90 and 90)', prop_latitude;
    END IF;

    IF NOT (prop_longitude ~ '^-?((1[0-7][0-9]|[0-9]?[0-9])(\.[0-9]{1,10})?|180(\.0{1,10})?)$') THEN
        RAISE EXCEPTION 'Invalid longitude: % (must be numeric between -180 and 180)', prop_longitude;
    END IF;

    -- STEP 2: Find or create property
    merged_details := prop_address ||
                      jsonb_build_object('latitude', prop_latitude,
                                        'longitude', prop_longitude);
    normalized_listing_metadata := jsonb_strip_nulls(
        jsonb_build_object('name', listing_name)
    );

    SELECT id INTO property_id
    FROM Properties
    WHERE descrp->>'latitude' = prop_latitude
      AND descrp->>'longitude' = prop_longitude;

    IF property_id IS NULL THEN
        INSERT INTO Properties (descrp)
        VALUES (merged_details)
        RETURNING id INTO property_id;
    END IF;

    -- STEP 3: Validate and process link_to_lookup_id
    self_value := NULL;

    IF link_to_lookup_id IS NOT NULL THEN
        -- Step 3A: Find the referenced lookup row
        SELECT properties_ptr, platform_id
        INTO reference_properties_ptr, reference_platform_id
        FROM Platform_Property_Lookup
        WHERE id = link_to_lookup_id;

        IF reference_properties_ptr IS NULL THEN
            RAISE EXCEPTION 'Referenced lookup record does not exist: id = %', link_to_lookup_id;
        END IF;

        -- Step 3B: Validate same properties_ptr
        IF reference_properties_ptr != property_id THEN
            RAISE EXCEPTION
                'Cannot link listings from different properties. '
                'Found property has properties_ptr=%, but link_to_lookup_id references properties_ptr=%. '
                'All chain members must reference the SAME property (same lat/lon).',
                property_id, reference_properties_ptr;
        END IF;

        -- Step 3C: Find chain tail
        WITH RECURSIVE find_chain_tail AS (
            SELECT id, self FROM Platform_Property_Lookup WHERE id = link_to_lookup_id
            UNION ALL
            SELECT ppl.id, ppl.self FROM Platform_Property_Lookup ppl
            JOIN find_chain_tail ON ppl.self = find_chain_tail.id
        )
        SELECT id INTO chain_tail_id
        FROM find_chain_tail
        WHERE id NOT IN (SELECT self FROM find_chain_tail WHERE self IS NOT NULL)
        LIMIT 1;

        -- Step 3D: Validate different platforms (will be checked by trigger)
        self_value := chain_tail_id;
    END IF;

    -- STEP 4: Check if mapping already exists
    SELECT id, self
    INTO existing_lookup_id, current_self_value
    FROM Platform_Property_Lookup
    WHERE platform_id = input_platform_id
      AND listing_id = input_listing_id;

    -- STEP 5: Create or update mapping
    IF existing_lookup_id IS NOT NULL THEN
        IF link_to_lookup_id IS NULL THEN
            self_value := current_self_value;
        END IF;
        UPDATE Platform_Property_Lookup
        SET properties_ptr = property_id,
            name = COALESCE(listing_name, name),
            metadata = CASE
                WHEN normalized_listing_metadata = '{}'::JSONB THEN metadata
                ELSE COALESCE(metadata, '{}'::JSONB) || normalized_listing_metadata
            END,
            self = self_value,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = existing_lookup_id
        RETURNING id INTO lookup_id;
    ELSE
        INSERT INTO Platform_Property_Lookup
            (properties_ptr, platform_id, listing_id, name, metadata, self)
        VALUES
            (property_id, input_platform_id, input_listing_id, listing_name, normalized_listing_metadata, self_value)
        RETURNING id INTO lookup_id;
    END IF;

    -- STEP 6: Return lookup_id
    RETURN lookup_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 1A: link_platform_property
-- ============================================================================
-- Purpose: Public wrapper that keeps FastAPI/live DB naming aligned with
-- platform_property_id while delegating to find_or_create_property().
--
-- The 5-argument version remains backward compatible.
-- The 6-argument version allows selecting an existing lookup row / chain anchor.

CREATE OR REPLACE FUNCTION link_platform_property(
    input_platform_id INT,
    input_platform_property_id TEXT,
    prop_latitude TEXT,
    prop_longitude TEXT,
    prop_details JSONB
)
RETURNS INT AS $$
BEGIN
    RETURN link_platform_property(
        input_platform_id,
        input_platform_property_id,
        prop_latitude,
        prop_longitude,
        prop_details,
        NULL
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION link_platform_property(
    input_platform_id INT,
    input_platform_property_id TEXT,
    prop_latitude TEXT,
    prop_longitude TEXT,
    prop_details JSONB,
    link_to_lookup_id INT
)
RETURNS INT AS $$
DECLARE
    normalized_details JSONB := COALESCE(prop_details, '{}'::JSONB);
    listing_name TEXT;
BEGIN
    listing_name := COALESCE(
        normalized_details->>'name',
        normalized_details->>'title',
        normalized_details->>'label'
    );

    RETURN find_or_create_property(
        prop_latitude,
        prop_longitude,
        normalized_details,
        input_platform_id,
        input_platform_property_id,
        listing_name,
        link_to_lookup_id
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 2: find_linked_listings
-- ============================================================================
-- Purpose: Given a listing, find ALL listings in its chain (both directions)
--
-- Parameters:
--   input_platform_id: Platform ID
--   input_listing_id: Platform's listing ID
--
-- Returns: TABLE with all linked listings

CREATE OR REPLACE FUNCTION find_linked_listings(
    input_platform_id INT,
    input_listing_id TEXT
)
RETURNS TABLE(
    lookup_id INT,
    platform_id INT,
    listing_id TEXT,
    platform_name TEXT,
    platform_type platform_type,
    is_chain_head BOOLEAN,
    linked_to_id INT
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE chain AS (
        -- Start from the given listing
        SELECT ppl.id, ppl.self, ppl.platform_id, ppl.listing_id, ppl.properties_ptr
        FROM Platform_Property_Lookup ppl
        WHERE ppl.platform_id = input_platform_id
          AND ppl.listing_id = input_listing_id

        UNION ALL

        -- Follow backward through self references
        SELECT ppl.id, ppl.self, ppl.platform_id, ppl.listing_id, ppl.properties_ptr
        FROM Platform_Property_Lookup ppl
        JOIN chain ON ppl.id = chain.self

        UNION ALL

        -- Follow forward (find all rows pointing to rows in chain)
        SELECT ppl.id, ppl.self, ppl.platform_id, ppl.listing_id, ppl.properties_ptr
        FROM Platform_Property_Lookup ppl
        JOIN chain ON ppl.self = chain.id
    )
    SELECT
        chain.id AS lookup_id,
        chain.platform_id,
        chain.listing_id,
        p.name AS platform_name,
        p.type AS platform_type,
        (chain.self IS NULL) AS is_chain_head,
        chain.self AS linked_to_id
    FROM chain
    JOIN Platforms p ON chain.platform_id = p.id
    ORDER BY chain.self DESC NULLS FIRST, chain.id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 3: link_listings
-- ============================================================================
-- Purpose: Explicitly link a source listing to a target listing
--
-- Parameters:
--   source_platform_id: Platform of source listing
--   source_listing_id: Listing ID of source
--   target_platform_id: Platform of target listing
--   target_listing_id: Listing ID of target
--
-- Returns: The lookup_id of source listing after linking

CREATE OR REPLACE FUNCTION link_listings(
    source_platform_id INT,
    source_listing_id TEXT,
    target_platform_id INT,
    target_listing_id TEXT
)
RETURNS INT AS $$
DECLARE
    source_lookup_id INT;
    target_lookup_id INT;
    chain_tail_id INT;
BEGIN
    -- Get the lookup IDs for both listings
    SELECT id INTO source_lookup_id
    FROM Platform_Property_Lookup
    WHERE platform_id = source_platform_id
      AND listing_id = source_listing_id;

    SELECT id INTO target_lookup_id
    FROM Platform_Property_Lookup
    WHERE platform_id = target_platform_id
      AND listing_id = target_listing_id;

    -- Validate both listings exist
    IF source_lookup_id IS NULL THEN
        RAISE EXCEPTION
            'Source listing not found: platform_id=%, listing_id=%',
            source_platform_id, source_listing_id;
    END IF;

    IF target_lookup_id IS NULL THEN
        RAISE EXCEPTION
            'Target listing not found: platform_id=%, listing_id=%',
            target_platform_id, target_listing_id;
    END IF;

    -- Find the tail of the chain containing target
    WITH RECURSIVE find_chain_tail AS (
        SELECT id, self FROM Platform_Property_Lookup WHERE id = target_lookup_id
        UNION ALL
        SELECT ppl.id, ppl.self FROM Platform_Property_Lookup ppl
        JOIN find_chain_tail ON ppl.self = find_chain_tail.id
    )
    SELECT id INTO chain_tail_id
    FROM find_chain_tail
    WHERE id NOT IN (SELECT self FROM find_chain_tail WHERE self IS NOT NULL)
    LIMIT 1;

    -- Update source listing to point to target chain's tail
    UPDATE Platform_Property_Lookup
    SET self = chain_tail_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = source_lookup_id;

    RETURN source_lookup_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 4: unlink_listing
-- ============================================================================
-- Purpose: Remove the link from a listing to its previous listing in the chain
--
-- Parameters:
--   input_platform_id: Platform ID
--   input_listing_id: Listing ID on that platform
--
-- Returns: The lookup_id of the unlinked listing

CREATE OR REPLACE FUNCTION unlink_listing(
    input_platform_id INT,
    input_listing_id TEXT
)
RETURNS INT AS $$
DECLARE
    lookup_id INT;
BEGIN
    SELECT id INTO lookup_id
    FROM Platform_Property_Lookup
    WHERE platform_id = input_platform_id
      AND listing_id = input_listing_id;

    IF lookup_id IS NULL THEN
        RAISE EXCEPTION
            'Listing not found: platform_id=%, listing_id=%',
            input_platform_id, input_listing_id;
    END IF;

    -- Set self to NULL, breaking the link
    UPDATE Platform_Property_Lookup
    SET self = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = lookup_id;

    RETURN lookup_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 5: get_cross_platform_properties
-- ============================================================================
-- Purpose: Given a listing, find all platform listings for the same property
--
-- Parameters:
--   input_platform_id: Platform ID
--   input_listing_id: Listing ID on that platform
--
-- Returns: TABLE with all cross-platform listings for the property

CREATE OR REPLACE FUNCTION get_cross_platform_properties(
    p_platform_id INT,
    p_listing_id TEXT
)
RETURNS TABLE (
    id INT,
    platform_id INT,
    platform_name TEXT,
    platform_type platform_type,
    listing_id TEXT,
    property_id INT,
    name TEXT,
    metadata JSONB,
    self INT,
    is_active BOOLEAN
) AS $$
DECLARE
    v_property_id INT;
BEGIN
    SELECT ppl.properties_ptr
    INTO v_property_id
    FROM platform_property_lookup ppl
    WHERE ppl.platform_id = p_platform_id
      AND ppl.listing_id = p_listing_id
    ORDER BY ppl.id ASC
    LIMIT 1;

    IF v_property_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT
        ppl.id,
        ppl.platform_id,
        p.name AS platform_name,
        p.type AS platform_type,
        ppl.listing_id,
        ppl.properties_ptr AS property_id,
        ppl.name,
        ppl.metadata,
        ppl.self,
        p.is_active
    FROM platform_property_lookup ppl
    JOIN platforms p ON ppl.platform_id = p.id
    WHERE ppl.properties_ptr = v_property_id
      AND p.is_active = true
    ORDER BY ppl.platform_id ASC, ppl.id ASC;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 6: get_listings_by_lat_long
-- ============================================================================
-- Purpose: Get all listings for a property identified by exact latitude/longitude
--
-- Parameters:
--   input_latitude: Latitude as TEXT
--   input_longitude: Longitude as TEXT
--
-- Returns: TABLE with all listings matching the lat/long pair

CREATE OR REPLACE FUNCTION get_listings_by_lat_long(
    input_latitude TEXT,
    input_longitude TEXT
)
RETURNS TABLE(
    id INT,
    platform_id INT,
    listing_id TEXT,
    listing_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ppl.id,
        ppl.platform_id,
        ppl.listing_id,
        ppl.name AS listing_name
    FROM Properties prop
    JOIN Platform_Property_Lookup ppl
        ON ppl.properties_ptr = prop.id
    WHERE prop.descrp->>'latitude' = input_latitude
      AND prop.descrp->>'longitude' = input_longitude
    ORDER BY ppl.platform_id, ppl.id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 7: get_property_details
-- ============================================================================
-- Purpose: Get complete property information for a platform/listing pair
--
-- Parameters:
--   input_platform_id: Platform ID
--   input_listing_id: Listing ID on that platform
--
-- Returns: TABLE with property details

CREATE OR REPLACE FUNCTION get_property_details(
    input_platform_id INT,
    input_listing_id TEXT
)
RETURNS TABLE(
    internal_property_id INT,
    latitude TEXT,
    longitude TEXT,
    property_name TEXT,
    full_details JSONB
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.id AS internal_property_id,
        p.descrp->>'latitude' AS latitude,
        p.descrp->>'longitude' AS longitude,
        p.descrp->>'name' AS property_name,
        p.descrp AS full_details
    FROM Platform_Property_Lookup ppl
    JOIN Properties p ON ppl.properties_ptr = p.id
    WHERE ppl.platform_id = input_platform_id
      AND ppl.listing_id = input_listing_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 8: get_platform_id_by_name
-- ============================================================================
-- Purpose: Helper function to get platform ID by platform name
--
-- Parameters:
--   platform_name: The name of the platform (e.g., 'Airbnb')
--
-- Returns: Platform ID (INT) or NULL if not found

CREATE OR REPLACE FUNCTION get_platform_id_by_name(platform_name TEXT)
RETURNS INT AS $$
DECLARE
    plat_id INT;
BEGIN
    SELECT id INTO plat_id
    FROM Platforms
    WHERE name = platform_name
      AND is_active = TRUE;

    RETURN plat_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 9: get_all_properties_on_platform
-- ============================================================================
-- Purpose: Get all properties listed on a specific platform
--
-- Parameters:
--   input_platform_id: Platform ID
--
-- Returns: TABLE with all properties on platform

CREATE OR REPLACE FUNCTION get_all_properties_on_platform(input_platform_id INT)
RETURNS TABLE(
    internal_property_id INT,
    listing_id TEXT,
    property_name TEXT,
    latitude TEXT,
    longitude TEXT,
    city TEXT,
    state TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.id AS internal_property_id,
        ppl.listing_id,
        p.descrp->>'name' AS property_name,
        p.descrp->>'latitude' AS latitude,
        p.descrp->>'longitude' AS longitude,
        p.descrp->>'city' AS city,
        p.descrp->>'state' AS state
    FROM Platform_Property_Lookup ppl
    JOIN Properties p ON ppl.properties_ptr = p.id
    WHERE ppl.platform_id = input_platform_id
    ORDER BY p.id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 10: validate_chain_integrity
-- ============================================================================
-- Purpose: Audit function to detect chain violations
--
-- Returns: TABLE with validation violations

CREATE OR REPLACE FUNCTION validate_chain_integrity()
RETURNS TABLE(
    violation_type TEXT,
    lookup_id INT,
    platform_id INT,
    listing_id TEXT,
    details TEXT
) AS $$
BEGIN
    -- VIOLATION 1: Duplicate self values
    RETURN QUERY
    SELECT
        'duplicate_self_value'::TEXT AS violation_type,
        id AS lookup_id,
        (SELECT platform_id FROM Platform_Property_Lookup WHERE id = a.id LIMIT 1)::INT,
        (SELECT listing_id FROM Platform_Property_Lookup WHERE id = a.id LIMIT 1)::TEXT,
        format('Duplicate self value %s appears multiple times', a.self::TEXT)
    FROM (
        SELECT self, id FROM Platform_Property_Lookup
        WHERE self IS NOT NULL
        GROUP BY self, id
        HAVING COUNT(*) > 1
    ) a;

    -- VIOLATION 2: Self-links
    RETURN QUERY
    SELECT
        'self_link'::TEXT,
        id,
        platform_id,
        listing_id,
        'Listing links to itself'
    FROM Platform_Property_Lookup
    WHERE self = id;

    -- VIOLATION 3: Links to same platform
    RETURN QUERY
    SELECT
        'same_platform_link'::TEXT,
        ppl1.id,
        ppl1.platform_id,
        ppl1.listing_id,
        format('Links to listing on same platform (id: %s)', ppl2.id::TEXT)
    FROM Platform_Property_Lookup ppl1
    JOIN Platform_Property_Lookup ppl2 ON ppl1.self = ppl2.id
    WHERE ppl1.platform_id = ppl2.platform_id;

    -- VIOLATION 4: Links to different property
    RETURN QUERY
    SELECT
        'different_property_link'::TEXT,
        ppl1.id,
        ppl1.platform_id,
        ppl1.listing_id,
        format('Links to listing on different property (prop: %s vs %s)',
               ppl1.properties_ptr::TEXT, ppl2.properties_ptr::TEXT)
    FROM Platform_Property_Lookup ppl1
    JOIN Platform_Property_Lookup ppl2 ON ppl1.self = ppl2.id
    WHERE ppl1.properties_ptr != ppl2.properties_ptr;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION 11: can_link_listings
-- ============================================================================
-- Purpose: Check if two listings can be linked without violating constraints
--
-- Parameters:
--   source_platform_id: Source platform ID
--   source_listing_id: Source listing ID
--   target_platform_id: Target platform ID
--   target_listing_id: Target listing ID
--
-- Returns: TABLE with boolean can_link and reason text

CREATE OR REPLACE FUNCTION can_link_listings(
    source_platform_id INT,
    source_listing_id TEXT,
    target_platform_id INT,
    target_listing_id TEXT
)
RETURNS TABLE(can_link BOOLEAN, reason TEXT) AS $$
DECLARE
    source_lookup_id INT;
    target_lookup_id INT;
    source_property INT;
    target_property INT;
    target_has_incoming_link BOOLEAN;
BEGIN
    -- Find listings
    SELECT id, properties_ptr INTO source_lookup_id, source_property
    FROM Platform_Property_Lookup
    WHERE platform_id = source_platform_id
      AND listing_id = source_listing_id;

    SELECT id, properties_ptr INTO target_lookup_id, target_property
    FROM Platform_Property_Lookup
    WHERE platform_id = target_platform_id
      AND listing_id = target_listing_id;

    -- Check 1: Both listings exist
    IF source_lookup_id IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Source listing does not exist';
        RETURN;
    END IF;

    IF target_lookup_id IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Target listing does not exist';
        RETURN;
    END IF;

    -- Check 2: Different platforms
    IF source_platform_id = target_platform_id THEN
        RETURN QUERY SELECT FALSE, 'Cannot link listings on the same platform';
        RETURN;
    END IF;

    -- Check 3: Same property
    IF source_property != target_property THEN
        RETURN QUERY SELECT FALSE, 'Listings reference different properties';
        RETURN;
    END IF;

    -- Check 4: Target doesn't already have incoming link
    SELECT EXISTS(
        SELECT 1
        FROM Platform_Property_Lookup
        WHERE self = target_lookup_id
    ) INTO target_has_incoming_link;

    IF target_has_incoming_link THEN
        RETURN QUERY SELECT FALSE, 'Target listing already has an incoming link';
        RETURN;
    END IF;

    -- All checks passed
    RETURN QUERY SELECT TRUE, 'Listings can be linked';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SUMMARY
-- ============================================================================
-- Tables created:
--   - Platforms
--   - Properties
--   - Platform_Property_Lookup
--
-- Functions created:
--   1. find_or_create_property        - Create/update property and listing with linking
--   2. find_linked_listings           - Find all linked listings in a chain
--   3. link_listings                  - Explicitly link two listings
--   4. unlink_listing                 - Remove link from a listing
--   5. get_cross_platform_properties  - Get all listings for same property
--   6. get_listings_by_lat_long       - Get all listings for a lat/long pair
--   7. get_property_details           - Get property details by listing
--   8. get_platform_id_by_name        - Helper to find platform by name
--   9. get_all_properties_on_platform - Get all properties on a platform
--   10. validate_chain_integrity      - Audit chains for violations
--   11. can_link_listings             - Check if linking is allowed
--
-- Triggers created:
--   - update_platforms_updated_at     - Auto-update timestamp
--   - update_properties_updated_at    - Auto-update timestamp
--   - update_platform_property_lookup_updated_at - Auto-update timestamp
--   - validate_platform_link_trigger  - Validate linking constraints
--
-- ============================================================================

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
