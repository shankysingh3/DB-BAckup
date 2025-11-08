-- ================================================================================
-- UPDATE: Scope 3 Insertion Function - Add Spend-Based Calculation Support
-- ================================================================================
-- Purpose: Update insert_scope3_emission() to properly support spend-based (EEIO)
--          calculations in addition to activity-based calculations
-- Created: 2025-11-06
--
-- Changes:
-- 1. Detect if unit is currency (USD, GBP, EUR, CAD, AUD)
-- 2. Use different calculation formulas for activity-based vs spend-based
-- 3. Add validation for spend_amount when using currency units
-- 4. Update activity description to show calculation method clearly
-- ================================================================================

-- Drop all possible function signatures
DROP FUNCTION IF EXISTS insert_scope3_emission(UUID, UUID, INTEGER, UUID, VARCHAR, NUMERIC, VARCHAR, VARCHAR, NUMERIC, VARCHAR, VARCHAR, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS insert_scope3_emission(UUID, INTEGER, UUID, NUMERIC, VARCHAR);
DROP FUNCTION IF EXISTS insert_scope3_emission(UUID, INTEGER, UUID, NUMERIC, VARCHAR, UUID, VARCHAR, NUMERIC, VARCHAR, VARCHAR, NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION insert_scope3_emission(
    -- REQUIRED parameters (no defaults) - MUST come first
    p_organization_id UUID,
    p_year INTEGER,
    p_emission_factor_id UUID,
    p_activity_data_value NUMERIC,
    p_activity_data_unit VARCHAR,
    -- OPTIONAL parameters (with defaults) - MUST come after required ones
    p_site_id UUID DEFAULT NULL,
    p_calculation_approach VARCHAR DEFAULT 'ACTIVITY_BASED',  -- 'ACTIVITY_BASED', 'SPEND_BASED', 'SUPPLIER_SPECIFIC'
    p_data_quality VARCHAR DEFAULT 'ESTIMATED',  -- 'PRIMARY', 'SECONDARY', 'ESTIMATED', 'PROXY'
    p_spend_amount NUMERIC DEFAULT NULL,
    p_spend_currency VARCHAR DEFAULT NULL,
    p_supplier_name VARCHAR DEFAULT NULL,
    p_primary_data_pct NUMERIC DEFAULT 0,
    p_uncertainty_pct NUMERIC DEFAULT NULL
)
RETURNS TABLE(
    emission_id UUID,
    emissions_tco2e NUMERIC,
    emission_factor_used NUMERIC,
    category VARCHAR,
    ghg_category INTEGER,
    calculation_method VARCHAR
) AS $$
DECLARE
    v_emission_id UUID;
    v_emission_factor_value NUMERIC;
    v_emissions_tco2e NUMERIC;
    v_category VARCHAR;
    v_subcategory VARCHAR;
    v_fuel_type VARCHAR;
    v_source VARCHAR;
    v_ghg_category INTEGER;
    v_value_chain_stage VARCHAR;
    v_activity_description TEXT;
    v_calculation_type VARCHAR;  -- NEW: Will be set to 'ACTIVITY_BASED' or 'SPEND_BASED'
    v_factor_unit VARCHAR;        -- NEW: Store factor unit to detect currency
BEGIN
    -- ============================================================================
    -- STEP 1: Validate Inputs
    -- ============================================================================

    -- Check organization exists
    IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p_organization_id) THEN
        RAISE EXCEPTION 'Organization not found: %', p_organization_id;
    END IF;

    -- Check site exists (if provided)
    IF p_site_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sites WHERE id = p_site_id AND organization_id = p_organization_id) THEN
        RAISE EXCEPTION 'Site not found or does not belong to organization: %', p_site_id;
    END IF;

    -- Validate year
    IF p_year < 1990 OR p_year > 2100 THEN
        RAISE EXCEPTION 'Invalid year: %. Must be between 1990 and 2100', p_year;
    END IF;

    -- Validate calculation approach
    IF p_calculation_approach NOT IN ('ACTIVITY_BASED', 'SPEND_BASED', 'SUPPLIER_SPECIFIC') THEN
        RAISE EXCEPTION 'Invalid calculation approach: %. Must be ACTIVITY_BASED, SPEND_BASED, or SUPPLIER_SPECIFIC', p_calculation_approach;
    END IF;

    -- Validate activity data
    IF p_activity_data_value <= 0 THEN
        RAISE EXCEPTION 'Activity data value must be positive: %', p_activity_data_value;
    END IF;

    IF p_activity_data_unit IS NULL OR p_activity_data_unit = '' THEN
        RAISE EXCEPTION 'Activity data unit is required';
    END IF;


    -- ============================================================================
    -- STEP 2: Retrieve Emission Factor
    -- ============================================================================

    SELECT
        ef.factor_value,
        ef.category,
        ef.subcategory,
        ef.fuel_type,
        ef.source,
        ef.unit  -- NEW: Get unit to detect if currency
    INTO
        v_emission_factor_value,
        v_category,
        v_subcategory,
        v_fuel_type,
        v_source,
        v_factor_unit
    FROM emission_factors ef
    WHERE ef.id = p_emission_factor_id
      AND ef.scope = 3
      AND ef.is_active = true
      AND CURRENT_DATE BETWEEN ef.validity_start_date AND COALESCE(ef.validity_end_date, '9999-12-31'::DATE);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Emission factor not found or not valid: %', p_emission_factor_id;
    END IF;


    -- ============================================================================
    -- STEP 2.5: Validate Spend-Based Requirements (NEW)
    -- ============================================================================

    -- Check if this is a spend-based factor (currency unit)
    IF v_factor_unit IN ('USD', 'GBP', 'EUR', 'CAD', 'AUD', 'JPY', 'CNY') THEN
        -- This is an EEIO (spend-based) factor
        IF p_spend_amount IS NULL OR p_spend_amount <= 0 THEN
            RAISE EXCEPTION 'Spend amount is required and must be positive for spend-based (EEIO) factors with currency unit: %', v_factor_unit;
        END IF;
        IF p_spend_currency IS NULL OR p_spend_currency = '' THEN
            RAISE EXCEPTION 'Spend currency is required for spend-based (EEIO) factors';
        END IF;
        -- Warn if currency mismatch (factor currency vs provided currency)
        IF p_spend_currency != v_factor_unit THEN
            RAISE WARNING 'Currency mismatch: Factor uses % but spend is in %. Consider currency conversion.', v_factor_unit, p_spend_currency;
        END IF;
    END IF;


    -- ============================================================================
    -- STEP 3: Determine GHG Category and Value Chain Stage
    -- ============================================================================

    -- Map category name to GHG category number (1-15)
    v_ghg_category := CASE
        -- Category 1: Purchased Goods and Services
        WHEN v_category ILIKE '%Material use%' OR v_category ILIKE '%Purchased Goods%' THEN 1

        -- Category 2: Capital Goods
        WHEN v_category ILIKE '%Capital goods%' OR v_category ILIKE '%Capital Goods%' THEN 2

        -- Category 3: Fuel and Energy Related Activities
        WHEN v_category ILIKE '%WTT%fuel%' OR v_category ILIKE '%WTT%bioenergy%'
             OR v_category ILIKE '%Transmission and distribution%'
             OR v_category ILIKE '%T&D%' OR v_category ILIKE '%WTT%heat%steam%'
             OR v_category ILIKE '%WTT%electricity%' THEN 3

        -- Category 4: Upstream Transportation and Distribution
        WHEN v_category ILIKE '%Freighting goods%' OR v_category ILIKE '%WTT%delivery%freight%' THEN 4

        -- Category 5: Waste Generated in Operations
        WHEN v_category ILIKE '%Waste disposal%' OR v_category ILIKE '%Water%' THEN 5

        -- Category 6: Business Travel
        WHEN v_category ILIKE '%Business travel%' OR v_category ILIKE '%Hotel stay%'
             OR v_category ILIKE '%WTT%travel%' THEN 6

        -- Category 7: Employee Commuting
        WHEN v_category ILIKE '%Homeworking%' OR v_category ILIKE '%Commuting%' THEN 7

        -- Category 8: Upstream Leased Assets
        WHEN v_category ILIKE '%Managed assets%' OR v_category ILIKE '%Upstream leased%' THEN 8

        -- Category 9: Downstream Transportation and Distribution
        WHEN v_category ILIKE '%Downstream transport%' THEN 9

        -- Categories 10-15: Not yet implemented
        ELSE NULL
    END;

    -- Determine value chain stage
    v_value_chain_stage := CASE
        WHEN v_ghg_category BETWEEN 1 AND 8 THEN 'UPSTREAM'
        WHEN v_ghg_category BETWEEN 9 AND 15 THEN 'DOWNSTREAM'
        ELSE NULL
    END;

    IF v_ghg_category IS NULL THEN
        RAISE WARNING 'Could not determine GHG category for category: %. Defaulting to NULL', v_category;
    END IF;


    -- ============================================================================
    -- STEP 4: Calculate Emissions (tCO2e) - UPDATED FOR SPEND-BASED
    -- ============================================================================

    -- Detect if this is activity-based or spend-based based on factor unit
    IF v_factor_unit IN ('USD', 'GBP', 'EUR', 'CAD', 'AUD', 'JPY', 'CNY') THEN
        -- ===== SPEND-BASED CALCULATION (EEIO) =====
        -- Use spend_amount instead of activity_data_value
        v_calculation_type := 'SPEND_BASED';
        v_emissions_tco2e := (p_spend_amount * v_emission_factor_value) / 1000.0;

        RAISE NOTICE 'Spend-based calculation: % % × % kgCO2e/% = % tCO2e',
            p_spend_amount, p_spend_currency,
            v_emission_factor_value, v_factor_unit,
            v_emissions_tco2e;

    ELSE
        -- ===== ACTIVITY-BASED CALCULATION (Physical Quantity) =====
        -- Use activity_data_value as before
        v_calculation_type := 'ACTIVITY_BASED';
        v_emissions_tco2e := (p_activity_data_value * v_emission_factor_value) / 1000.0;

        RAISE NOTICE 'Activity-based calculation: % % × % kgCO2e/% = % tCO2e',
            p_activity_data_value, p_activity_data_unit,
            v_emission_factor_value, v_factor_unit,
            v_emissions_tco2e;
    END IF;

    -- Ensure non-negative result
    IF v_emissions_tco2e < 0 THEN
        RAISE EXCEPTION 'Calculated emissions cannot be negative: %', v_emissions_tco2e;
    END IF;


    -- ============================================================================
    -- STEP 5: Build Activity Description - UPDATED
    -- ============================================================================

    v_activity_description := CONCAT(
        v_fuel_type,
        CASE WHEN v_subcategory IS NOT NULL AND v_subcategory != ''
             THEN ' (' || v_subcategory || ')'
             ELSE ''
        END,
        ': ',
        -- Show different description based on calculation type
        CASE
            WHEN v_calculation_type = 'SPEND_BASED' THEN
                CONCAT(
                    p_spend_amount::TEXT, ' ', p_spend_currency,
                    ' (EEIO: ', v_emission_factor_value::TEXT, ' kgCO2e/', v_factor_unit, ')',
                    ' = ', ROUND(v_emissions_tco2e, 4)::TEXT, ' tCO2e'
                )
            ELSE  -- ACTIVITY_BASED or SUPPLIER_SPECIFIC
                CONCAT(
                    p_activity_data_value::TEXT, ' ', p_activity_data_unit,
                    ' × ', v_emission_factor_value::TEXT, ' kgCO2e/', p_activity_data_unit,
                    CASE WHEN p_calculation_approach = 'SPEND_BASED' AND p_spend_amount IS NOT NULL
                         THEN ' (Spend: ' || p_spend_amount::TEXT || ' ' || p_spend_currency || ')'
                         ELSE ''
                    END
                )
        END,
        CASE WHEN p_supplier_name IS NOT NULL AND p_supplier_name != ''
             THEN ' - Supplier: ' || p_supplier_name
             ELSE ''
        END
    );


    -- ============================================================================
    -- STEP 6: Insert Emission Record
    -- ============================================================================

    INSERT INTO emissions_scope_3 (
        organization_id,
        year,
        category,
        subcategory,
        activity_description,
        activity_data_unit,
        activity_data_value,
        emission_factor_source,
        emission_factor_value,
        emissions_tco2e,
        data_quality,
        source_type,
        emission_factor_id,
        ghg_category,
        value_chain_stage,
        calculation_approach,
        spend_amount,
        spend_currency,
        supplier_name,
        primary_data_pct,
        uncertainty_pct,
        uploaded_at,
        created_at,
        updated_at
    )
    VALUES (
        p_organization_id,
        p_year,
        v_category,
        v_subcategory,
        v_activity_description,
        p_activity_data_unit,
        p_activity_data_value,
        v_source,
        v_emission_factor_value,
        v_emissions_tco2e,
        p_data_quality,
        CASE
            WHEN v_calculation_type = 'SPEND_BASED' THEN 'EEIO'
            WHEN p_calculation_approach = 'SUPPLIER_SPECIFIC' THEN 'PRIMARY'
            ELSE 'ACTIVITY'
        END,
        p_emission_factor_id,
        v_ghg_category,
        v_value_chain_stage,
        v_calculation_type,  -- Use detected type instead of user-provided
        p_spend_amount,
        p_spend_currency,
        p_supplier_name,
        p_primary_data_pct,
        p_uncertainty_pct,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    )
    RETURNING id INTO v_emission_id;


    -- ============================================================================
    -- STEP 7: Return Result
    -- ============================================================================

    RETURN QUERY
    SELECT
        v_emission_id,
        v_emissions_tco2e,
        v_emission_factor_value,
        v_category,
        v_ghg_category,
        v_calculation_type;  -- Return detected type

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION insert_scope3_emission(
    UUID, INTEGER, UUID, NUMERIC, VARCHAR,
    UUID, VARCHAR, VARCHAR, NUMERIC, VARCHAR, VARCHAR, NUMERIC, NUMERIC
) IS
'Insert a Scope 3 emission record with automatic tCO2e calculation.

UPDATED: Now properly supports both activity-based AND spend-based (EEIO) calculations.

Calculation Method Detection (Automatic):
- If emission factor unit is currency (USD, GBP, EUR, etc.) → SPEND_BASED
- Otherwise → ACTIVITY_BASED

Formula:
- ACTIVITY_BASED: (activity_data_value × emission_factor_value) / 1000 = tCO2e
  Example: 5 tonnes × 241.79 kgCO2e/tonne / 1000 = 1.209 tCO2e

- SPEND_BASED: (spend_amount × emission_factor_value) / 1000 = tCO2e
  Example: $10,000 × 0.5 kgCO2e/$ / 1000 = 5 tCO2e

Parameters (NEW ORDER - required first, optional after):
  REQUIRED:
    p_organization_id       - Organization UUID (required)
    p_year                  - Reporting year (e.g., 2025) (required)
    p_emission_factor_id    - Emission factor UUID from selection function (required)
    p_activity_data_value   - Quantity (for activity-based) OR same as spend_amount (for spend-based) (required)
    p_activity_data_unit    - Physical unit (km, kg) OR currency (USD, GBP) (required)
  OPTIONAL (defaults provided):
    p_site_id               - Site UUID (optional, default NULL)
    p_calculation_approach  - User preference (ACTIVITY_BASED, SPEND_BASED, SUPPLIER_SPECIFIC) (default: ACTIVITY_BASED)
    p_data_quality          - PRIMARY, SECONDARY, ESTIMATED, PROXY (default: ESTIMATED)
    p_spend_amount          - $ amount (REQUIRED for spend-based factors) (default: NULL)
    p_spend_currency        - Currency code (REQUIRED for spend-based factors) (default: NULL)
    p_supplier_name         - Supplier name (optional) (default: NULL)
    p_primary_data_pct      - % primary data (0-100) (default: 0)
    p_uncertainty_pct       - Uncertainty % (optional) (default: NULL)

Returns:
  emission_id             - UUID of created record
  emissions_tco2e         - Calculated emissions (tonnes CO2e)
  emission_factor_used    - Emission factor value
  category                - Scope 3 category
  ghg_category            - GHG Protocol category (1-15)
  calculation_method      - ACTIVITY_BASED or SPEND_BASED (auto-detected)

Usage Examples:

-- Activity-Based (Physical Quantity):
SELECT * FROM insert_scope3_emission(
    p_organization_id := ''org-uuid'',
    p_year := 2025,
    p_emission_factor_id := ''material-steel-tonnes-uuid'',
    p_activity_data_value := 5,
    p_activity_data_unit := ''tonnes'',
    p_data_quality := ''SECONDARY''
);
-- Result: 5 tonnes × 241.79 kgCO2e/tonne = 1.209 tCO2e

-- Spend-Based (EEIO):
SELECT * FROM insert_scope3_emission(
    p_organization_id := ''org-uuid'',
    p_year := 2025,
    p_emission_factor_id := ''eeio-steel-manufacturing-usd-uuid'',
    p_activity_data_value := 10000,  -- Match spend_amount
    p_activity_data_unit := ''USD'',
    p_spend_amount := 10000,
    p_spend_currency := ''USD'',
    p_data_quality := ''ESTIMATED''
);
-- Result: $10,000 × 0.5 kgCO2e/$ = 5 tCO2e';


-- ================================================================================
-- VERIFICATION
-- ================================================================================

SELECT '=== SCOPE 3 INSERTION FUNCTION UPDATED SUCCESSFULLY ===' as status;

-- Check function exists
SELECT
    r.routine_name,
    'Updated with spend-based support' as status
FROM information_schema.routines r
WHERE r.routine_name = 'insert_scope3_emission';

SELECT '✅ Function now supports both activity-based AND spend-based calculations' as result;


-- ================================================================================
-- NEXT STEPS
-- ================================================================================

/*
1. ✅ Created ingest_scope3_eeio_factors.sql (50 EEIO factors)
2. ✅ Updated insert_scope3_emission() function (dual calculation)
3. ⏭️ Update get_scope3_emission_factors_for_selection() (add filtering)
4. ⏭️ Test with test_scope3_spend_based_functions.sql
5. ⏭️ Document in SCOPE3_SPEND_BASED_GUIDE.md
6. ⏭️ Integrate into UI with calculation method selector
*/
