-- ================================================================================
-- UPDATE: Scope 3 Selection Function - Add Calculation Type Filtering
-- ================================================================================
-- Purpose: Update get_scope3_emission_factors_for_selection() to filter by
--          calculation approach (activity-based vs spend-based)
-- Created: 2025-11-06
--
-- Changes:
-- 1. Add optional p_calculation_approach parameter for filtering
-- 2. Add calculation_type to return columns (ACTIVITY_BASED or SPEND_BASED)
-- 3. Sort factors: Activity-based first (higher quality), then spend-based
-- 4. Detect calculation type from unit (currency = spend-based)
-- ================================================================================

DROP FUNCTION IF EXISTS get_scope3_emission_factors_for_selection(VARCHAR, UUID, VARCHAR);
DROP FUNCTION IF EXISTS get_scope3_emission_factors_for_selection(VARCHAR, UUID);

CREATE OR REPLACE FUNCTION get_scope3_emission_factors_for_selection(
    p_category_name VARCHAR,              -- Category name (e.g., 'Business travel- land', 'Purchased Goods')
    p_site_id UUID,                       -- Site ID for location-aware filtering
    p_calculation_approach VARCHAR DEFAULT NULL  -- NEW: 'ACTIVITY_BASED', 'SPEND_BASED', or NULL (show all)
)
RETURNS TABLE(
    id UUID,
    display_name TEXT,
    fuel_type VARCHAR,
    unit VARCHAR,
    factor_value NUMERIC,
    source VARCHAR,
    source_year INTEGER,
    location_priority INTEGER,
    co2_factor NUMERIC,
    ch4_factor NUMERIC,
    n2o_factor NUMERIC,
    description TEXT,
    category VARCHAR,
    subcategory VARCHAR,
    country_code VARCHAR,
    is_primary BOOLEAN,
    calculation_type VARCHAR  -- NEW: 'ACTIVITY_BASED' or 'SPEND_BASED'
) AS $$
BEGIN
    RETURN QUERY
    WITH site_info AS (
        SELECT
            s.country_code
        FROM sites s
        WHERE s.id = p_site_id
    ),
    available_factors AS (
        SELECT
            ef.id,
            ef.fuel_type,
            ef.unit,
            ef.factor_value,
            ef.source,
            ef.source_year,
            ef.country_code,
            ef.geographic_scope,
            ef.co2_factor,
            ef.ch4_factor,
            ef.n2o_factor,
            ef.description,
            ef.category,
            ef.subcategory,
            si.country_code as site_country_code,
            COALESCE(efc.is_primary, false) as is_primary,
            -- NEW: Detect calculation type from unit
            (CASE
                WHEN ef.unit IN ('USD', 'GBP', 'EUR', 'CAD', 'AUD', 'JPY', 'CNY') THEN 'SPEND_BASED'
                ELSE 'ACTIVITY_BASED'
            END)::VARCHAR as calculation_type,
            CASE
                -- Exact country match (BEST)
                WHEN ef.country_code = si.country_code THEN 1
                -- UK factors (fallback for most users since DEFRA data is UK-centric)
                WHEN ef.country_code = 'GBR' AND ef.country_code != si.country_code THEN 2
                -- Global fallback
                WHEN ef.geographic_scope = 'Global' OR ef.country_code IS NULL THEN 3
                -- Other countries (for reference)
                ELSE 4
            END as location_priority,
            CONCAT(
                ef.fuel_type,
                CASE
                    WHEN ef.subcategory IS NOT NULL AND ef.subcategory != ''
                    THEN ' - ' || REPLACE(ef.subcategory, ' / ', ' / ')
                    ELSE ''
                END,
                ' - ', ef.unit,
                ' (',
                ef.source,
                CASE WHEN ef.source_year IS NOT NULL THEN ' ' || ef.source_year::TEXT ELSE '' END,
                CASE
                    WHEN ef.country_code = si.country_code THEN ' - ' || ef.country_code || ' ✓'
                    WHEN ef.country_code = 'GBR' THEN ' - GBR'
                    WHEN ef.country_code = 'USA' THEN ' - USA'
                    WHEN ef.geographic_scope = 'Global' THEN ' - Global'
                    WHEN ef.country_code IS NOT NULL THEN ' - ' || ef.country_code
                    ELSE ''
                END,
                ')',
                CASE WHEN COALESCE(efc.is_primary, false) THEN ' [Recommended]' ELSE '' END,
                -- NEW: Add badge for EEIO factors
                CASE
                    WHEN ef.unit IN ('USD', 'GBP', 'EUR', 'CAD', 'AUD', 'JPY', 'CNY')
                    THEN ' [EEIO - Lower Quality]'
                    ELSE ''
                END
            ) as display_name
        FROM emission_factors ef
        CROSS JOIN site_info si
        LEFT JOIN emission_factor_classifications efc ON ef.id = efc.emission_factor_id
        WHERE ef.scope = 3
          AND ef.is_active = true
          -- Match category name (flexible matching)
          AND (
              ef.category ILIKE '%' || p_category_name || '%'
              OR p_category_name ILIKE '%' || ef.category || '%'
          )
          -- NEW: Filter by calculation approach if specified
          AND (
              p_calculation_approach IS NULL  -- Show all
              OR (
                  p_calculation_approach = 'ACTIVITY_BASED'
                  AND ef.unit NOT IN ('USD', 'GBP', 'EUR', 'CAD', 'AUD', 'JPY', 'CNY')
              )
              OR (
                  p_calculation_approach = 'SPEND_BASED'
                  AND ef.unit IN ('USD', 'GBP', 'EUR', 'CAD', 'AUD', 'JPY', 'CNY')
              )
          )
          -- Ensure valid date range
          AND CURRENT_DATE BETWEEN ef.validity_start_date
                                AND COALESCE(ef.validity_end_date, '9999-12-31'::DATE)
    )
    SELECT
        af.id,
        af.display_name,
        af.fuel_type,
        af.unit,
        af.factor_value,
        af.source,
        af.source_year,
        af.location_priority,
        af.co2_factor,
        af.ch4_factor,
        af.n2o_factor,
        af.description,
        af.category,
        af.subcategory,
        af.country_code,
        af.is_primary,
        af.calculation_type  -- NEW: Return calculation type
    FROM available_factors af
    ORDER BY
        -- NEW: Activity-based factors FIRST (higher quality)
        CASE af.calculation_type
            WHEN 'ACTIVITY_BASED' THEN 1
            WHEN 'SPEND_BASED' THEN 2
            ELSE 3
        END,
        af.location_priority ASC,  -- Country match first
        af.is_primary DESC,         -- Recommended factors first
        af.category,
        af.subcategory,
        af.fuel_type,
        -- Unit ordering (common units first)
        CASE af.unit
            WHEN 'km' THEN 1
            WHEN 'miles' THEN 2
            WHEN 'kg' THEN 3
            WHEN 'tonnes' THEN 4
            WHEN 'litres' THEN 5
            WHEN 'kWh' THEN 6
            WHEN 'MWh' THEN 7
            WHEN 'nights' THEN 8
            WHEN 'passenger.km' THEN 9
            WHEN 'tonne.km' THEN 10
            WHEN 'USD' THEN 11
            WHEN 'GBP' THEN 12
            WHEN 'EUR' THEN 13
            ELSE 14
        END,
        af.source_year DESC NULLS LAST;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_scope3_emission_factors_for_selection(VARCHAR, UUID, VARCHAR) IS
'Returns available Scope 3 emission factors filtered by category and calculation approach.

UPDATED: Now supports filtering by calculation approach and shows calculation type.

Location-aware with fallback: Country match → UK (DEFRA) → Global.

Parameters:
- p_category_name: Category name (e.g., ''Business Travel'', ''Purchased Goods'', ''Freighting goods'')
- p_site_id: Site UUID for location-based filtering
- p_calculation_approach: Optional filter:
    - NULL: Show all factors (activity-based AND spend-based)
    - ''ACTIVITY_BASED'': Show only physical quantity factors (higher quality)
    - ''SPEND_BASED'': Show only EEIO (financial spend) factors (lower quality)

Prioritizes:
1. Activity-based factors (higher quality) over spend-based (EEIO)
2. Exact country match (site.country_code = ef.country_code)
3. UK factors (DEFRA 2025 - most comprehensive dataset)
4. Global fallback (ef.geographic_scope = ''Global'')

Usage Examples:

-- Get all factors for Purchased Goods (both activity-based and spend-based)
SELECT * FROM get_scope3_emission_factors_for_selection(
    ''Purchased Goods'',
    ''site-uuid'',
    NULL  -- Show all
);

-- Get ONLY activity-based factors (physical quantities)
SELECT * FROM get_scope3_emission_factors_for_selection(
    ''Purchased Goods'',
    ''site-uuid'',
    ''ACTIVITY_BASED''  -- Only tonnes, kg, etc.
);

-- Get ONLY spend-based (EEIO) factors
SELECT * FROM get_scope3_emission_factors_for_selection(
    ''Purchased Goods'',
    ''site-uuid'',
    ''SPEND_BASED''  -- Only USD, GBP, EUR factors
);

Returns:
  id                  - Factor UUID
  display_name        - Formatted for UI dropdown (includes quality indicator)
  unit                - Physical unit OR currency
  factor_value        - Emission factor (kgCO2e per unit)
  location_priority   - 1 = best match
  is_primary          - true = recommended
  calculation_type    - ''ACTIVITY_BASED'' or ''SPEND_BASED'' (auto-detected from unit)

UI Integration:
- Sort order: Activity-based first, then spend-based
- Activity-based factors: Higher quality, no badge
- Spend-based factors: Display with "[EEIO - Lower Quality]" badge';


-- ================================================================================
-- VERIFICATION
-- ================================================================================

SELECT '=== SCOPE 3 SELECTION FUNCTION UPDATED SUCCESSFULLY ===' as status;

-- Check function exists with new signature
SELECT
    r.routine_name,
    p.parameter_name,
    p.data_type,
    p.parameter_mode,
    p.ordinal_position
FROM information_schema.routines r
JOIN information_schema.parameters p ON r.specific_name = p.specific_name
WHERE r.routine_name = 'get_scope3_emission_factors_for_selection'
  AND p.parameter_mode IN ('IN', 'OUT')
ORDER BY p.parameter_mode DESC, p.ordinal_position;


-- ================================================================================
-- TEST QUERIES
-- ================================================================================

/*
-- Test 1: Get all factors for Purchased Goods (should show both activity and EEIO)
SELECT
    calculation_type,
    unit,
    display_name,
    location_priority
FROM get_scope3_emission_factors_for_selection(
    'Purchased Goods',
    (SELECT id FROM sites LIMIT 1),
    NULL  -- Show all
)
ORDER BY calculation_type, display_name
LIMIT 20;

-- Expected: Mix of activity-based (tonnes, kg) and spend-based (USD) factors


-- Test 2: Get ONLY activity-based factors
SELECT
    calculation_type,
    unit,
    display_name
FROM get_scope3_emission_factors_for_selection(
    'Purchased Goods',
    (SELECT id FROM sites LIMIT 1),
    'ACTIVITY_BASED'  -- Only physical quantities
)
LIMIT 10;

-- Expected: Only factors with unit = tonnes, kg, etc. (no USD)


-- Test 3: Get ONLY spend-based (EEIO) factors
SELECT
    calculation_type,
    unit,
    display_name,
    factor_value
FROM get_scope3_emission_factors_for_selection(
    'Purchased Goods',
    (SELECT id FROM sites LIMIT 1),
    'SPEND_BASED'  -- Only EEIO
)
ORDER BY fuel_type
LIMIT 10;

-- Expected: Only factors with unit = USD, GBP, EUR


-- Test 4: Verify sorting (activity-based should come first)
SELECT
    calculation_type,
    unit,
    LEFT(display_name, 60) as name_preview,
    location_priority
FROM get_scope3_emission_factors_for_selection(
    'Purchased Goods',
    (SELECT id FROM sites LIMIT 1),
    NULL  -- Show all
)
LIMIT 20;

-- Expected: Activity-based factors listed before spend-based


-- Test 5: Check if EEIO badge is shown
SELECT
    display_name,
    calculation_type,
    CASE
        WHEN display_name LIKE '%[EEIO - Lower Quality]%' THEN 'Badge present'
        ELSE 'No badge'
    END as eeio_badge
FROM get_scope3_emission_factors_for_selection(
    'Purchased Goods',
    (SELECT id FROM sites LIMIT 1),
    'SPEND_BASED'
)
LIMIT 5;

-- Expected: All EEIO factors should have "[EEIO - Lower Quality]" badge
*/


-- ================================================================================
-- SUCCESS CRITERIA
-- ================================================================================

/*
✅ FUNCTION: get_scope3_emission_factors_for_selection()
   - Updated with p_calculation_approach parameter (optional)
   - Returns calculation_type column (ACTIVITY_BASED or SPEND_BASED)
   - Filters factors by approach when specified
   - Sorts activity-based first (higher quality)
   - Adds "[EEIO - Lower Quality]" badge to spend-based factors
   - Backward compatible (p_calculation_approach defaults to NULL)

✅ FILTERING:
   - NULL: Show all factors (both activity-based and spend-based)
   - 'ACTIVITY_BASED': Show only physical quantity factors
   - 'SPEND_BASED': Show only EEIO (currency) factors

✅ SORTING:
   - Activity-based factors listed FIRST (priority 1)
   - Spend-based factors listed SECOND (priority 2)
   - Then by location_priority, is_primary, category, unit

✅ UI INTEGRATION:
   - Dropdown can filter by calculation approach
   - Badge clearly indicates lower quality of EEIO factors
   - Calculation type available for UI logic
*/

SELECT '✅ Function now supports filtering by calculation approach (activity vs spend)' as result;


-- ================================================================================
-- NEXT STEPS
-- ================================================================================

/*
1. ✅ Created ingest_scope3_eeio_factors.sql (50 EEIO factors)
2. ✅ Updated insert_scope3_emission() function (dual calculation)
3. ✅ Updated get_scope3_emission_factors_for_selection() (filtering)
4. ⏭️ Test with test_scope3_spend_based_functions.sql
5. ⏭️ Document in SCOPE3_SPEND_BASED_GUIDE.md
6. ⏭️ Integrate into UI:
   - Add calculation method radio button
   - Filter factors by selected method
   - Show quality indicators (badges)
   - Default to activity-based
*/
