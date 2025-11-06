# Scope 2 Implementation - Execution Guide

## Overview
This guide provides the correct execution order for all Scope 2 (Indirect Emissions) implementation scripts.

## Architecture Summary

**Hybrid Approach:**
- **Electricity**: Uses `grid_regions` table (29 regions already exist in database)
- **Heat/Steam/Cooling**: Uses `emission_factors` table (new factors to be ingested)
- **Market-Based Methodology**: Uses `electricity_contracts` table (renewable energy contracts)

## Prerequisites
- Scope 1 implementation completed (steps 1-12)
- Database backup: `backup_Sachin_01.11.25.sql` restored
- Grid regions already exist (29 regions covering UK, EU, US eGRID, Middle East, Asia)

## Execution Order

### Step 1: Create Electricity Contracts Table
**File:** `create_electricity_contracts_table.sql`

**Purpose:** Store renewable energy contracts (Green Tariffs, PPAs, RECs, GO Certificates) for market-based accounting

**What it does:**
- Creates `electricity_contracts` table
- Creates `get_active_electricity_contract()` helper function
- Enables dual methodology support (location-based vs market-based)

**Expected result:**
```sql
-- Table created with 0 rows
-- Function created: get_active_electricity_contract(site_id, year, month)
```

---

### Step 2: Ingest Heat/Steam/Cooling Emission Factors
**File:** `ingest_scope2_heat_steam_cooling_factors.sql`

**Purpose:** Add base emission factors (in kWh only) for Heat, Steam, and Cooling

**Coverage:**
- **UK (DEFRA 2025):** District Heating, Steam (2 factors)
- **EU Countries (IEA 2024):** Germany, France, Netherlands, Spain, Italy, Sweden, Belgium, Denmark (16 factors)
- **Other Regions:** USA, Canada, China, Japan, Australia (5 factors)
- **Global Fallback:** District heating, cooling (3 factors)

**Expected result:** ~26 new emission_factors records with unit = 'kWh'

**Validation query:**
```sql
SELECT category, country_code, unit, COUNT(*)
FROM emission_factors
WHERE scope = 2 AND category IN ('Steam & Heating', 'Cooling')
GROUP BY category, country_code, unit;
```

---

### Step 3: Add Multi-Unit Emission Factors
**File:** `add_scope2_multi_unit_factors.sql`

**Purpose:** Generate emission factors in multiple units (MWh, GJ, Therms, MMBtu) from base kWh factors

**Why needed:** Enables UI dropdown for unit selection (similar to Scope 1 workflow)

**Conversion ratios used:**
- **MWh:** kWh × 1000 (all countries)
- **GJ:** kWh × 3.6 (all countries)
- **Therms:** kWh × 0.03412 (UK, Commonwealth countries only)
- **MMBtu:** kWh × 0.003412 (USA only)

**Expected result:** ~100+ new emission_factors records

**Validation query:**
```sql
SELECT unit, COUNT(*)
FROM emission_factors
WHERE scope = 2 AND category IN ('Steam & Heating', 'Cooling')
GROUP BY unit
ORDER BY CASE unit
    WHEN 'kWh' THEN 1
    WHEN 'MWh' THEN 2
    WHEN 'GJ' THEN 3
    WHEN 'Therms' THEN 4
    WHEN 'MMBtu' THEN 5
END;

-- Expected output:
-- kWh: ~26 (base factors)
-- MWh: ~26 (all countries)
-- GJ: ~26 (all countries)
-- Therms: ~10 (UK/Commonwealth only)
-- MMBtu: ~5 (USA only)
```

---

### Step 4: Auto-Map Sites to Grid Regions
**File:** `populate_sites_grid_region.sql`

**Purpose:** Automatically populate `sites.grid_region` based on country and city

**Mappings included:**
- **UK:** All sites → `GB-NG` (National Grid)
- **EU Countries:** Germany (50HZ, Amprion, TenneT, TransnetBW), Netherlands (TenneT), etc.
- **Middle East:** 15 specific mappings (Dubai DEWA, Abu Dhabi EWEC, Saudi SEC, etc.)
- **Asia-Pacific:** Japan (TEPCO, KEPCO), Singapore (EMA), Australia (NEM regions)
- **USA:** Commented out (requires state-level mapping to eGRID subregions)

**Important notes:**
- Won't overwrite manual mappings (`grid_region_source = 'MANUAL'`)
- USA sites require manual mapping or state data

**Validation query:**
```sql
SELECT country_code, grid_region, grid_region_source, COUNT(*)
FROM sites
WHERE grid_region IS NOT NULL
GROUP BY country_code, grid_region, grid_region_source;
```

---

### Step 5: Create Scope 2 Emission Function
**File:** `create_insert_scope2_emission_function_REVISED.sql`

**Purpose:** Main emission entry function with hybrid architecture and dual methodology support

**Function signature:**
```sql
CREATE FUNCTION insert_scope2_emission(
    p_site_id UUID,
    p_year INTEGER,
    p_month INTEGER,
    p_energy_type VARCHAR,              -- 'Electricity', 'Heat', 'Steam', 'Cooling'
    p_consumption_value NUMERIC,
    p_uploaded_by UUID,
    p_emission_factor_id UUID DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_document_upload_id UUID DEFAULT NULL
) RETURNS UUID
```

**Key logic:**

**For Electricity:**
1. Check for active renewable contract (market-based methodology)
   - If found: Use contract emission factor (often 0 gCO2e/kWh)
   - Sets `methodology = 'MARKET_BASED'`
   - Sets `emission_factor_id = NULL`
   - Uses `electricity_contracts.emission_factor_gco2_kwh`

2. No contract found: Use grid region factor (location-based)
   - Query `grid_regions` by `sites.grid_region` code
   - Fallback to `sites.country_code` if grid_region is NULL
   - Parse JSONB description for CH4/N2O breakdown
   - Sets `methodology = 'LOCATION_BASED'`
   - Sets `emission_factor_id = NULL` (uses grid_regions instead)

**For Heat/Steam/Cooling:**
1. Query `emission_factors` table
2. Prioritize: Country match → Global fallback
3. Order by validity date (most recent first)
4. Sets `methodology = 'LOCATION_BASED'`
5. Populates `emission_factor_id` (FK to emission_factors table)

**Expected result:** Function created successfully

---

### Step 6: Validation Testing
**File:** `validate_scope2_workflow_REVISED.sql`

**Purpose:** Comprehensive testing of Scope 2 implementation

**Tests included:**

**STEP 1-3:** Setup test site and user

**STEP 4:** Test electricity (location-based)
```sql
-- Insert using grid_regions table
SELECT insert_scope2_emission(
    test_site_id, 2024, 1, 'Electricity', 1000.00, test_user_id,
    NULL, 'Test location-based electricity'
);

-- Verify:
-- methodology = 'LOCATION_BASED'
-- emission_factor_id IS NULL
-- grid_region_code IS NOT NULL
```

**STEP 5:** Create test renewable contract

**STEP 6:** Test electricity (market-based)
```sql
-- Insert using electricity_contracts table
SELECT insert_scope2_emission(
    test_site_id, 2024, 2, 'Electricity', 1500.00, test_user_id,
    NULL, 'Test market-based electricity'
);

-- Verify:
-- methodology = 'MARKET_BASED'
-- emission_factor_id IS NULL
-- co2e_kg_total = 0 (renewable contract)
```

**STEP 7:** Test Heat entry
```sql
-- Insert using emission_factors table
SELECT insert_scope2_emission(
    test_site_id, 2024, 3, 'Heat', 500.00, test_user_id,
    NULL, 'Test district heating'
);

-- Verify:
-- methodology = 'LOCATION_BASED'
-- emission_factor_id IS NOT NULL
-- Factor matches emission_factors table
```

**STEP 8:** Test Cooling entry

**STEP 9-10:** Display results

**STEP 11:** Architecture verification (CRITICAL)
```sql
-- Verify electricity entries have NULL emission_factor_id
SELECT COUNT(*) FROM emissions_scope_2
WHERE energy_type = 'Electricity' AND emission_factor_id IS NULL;

-- Verify heat/cooling entries have emission_factor_id populated
SELECT COUNT(*) FROM emissions_scope_2
WHERE energy_type IN ('Heat', 'Steam', 'Cooling') AND emission_factor_id IS NOT NULL;
```

**STEP 12:** Cleanup

---

## UI Implementation Guide

### Cascading Dropdown Workflow

**Step 1: Select Emission Category**
```sql
SELECT id, name, code, display_order
FROM emission_categories
WHERE scope = 2 AND is_active = true
ORDER BY display_order;

-- Returns:
-- Indirect Emissions from Electricity (electricity)
-- Steam & Heating (steam)
-- Cooling (cooling)
```

**Step 2a: If Electricity → Select Methodology**
```sql
SELECT id, name, code, description
FROM activity_types
WHERE code IN ('grid', 'market') AND is_active = true;

-- Returns:
-- Grid Supply (grid) - Location-based grid average
-- Market-Based (market) - Green tariffs, RECs, PPAs
```

**Step 2b: If Market-Based → Show active contracts**
```sql
SELECT * FROM get_active_electricity_contract(site_id, year, month);

-- If no contract: Show warning + option to add contract
```

**Step 3: Select Unit (Heat/Steam/Cooling only)**
```sql
-- For selected category and site country:
SELECT DISTINCT unit,
    MIN(display_name) as example_name,
    COUNT(*) as available_factors
FROM emission_factors ef
JOIN emission_factor_classifications efc ON ef.id = efc.emission_factor_id
WHERE efc.emission_category_id = :selected_category_id
  AND (ef.country_code = :site_country OR ef.geographic_scope = 'Global')
  AND ef.is_active = true
GROUP BY unit
ORDER BY CASE unit
    WHEN 'kWh' THEN 1
    WHEN 'MWh' THEN 2
    WHEN 'GJ' THEN 3
    WHEN 'Therms' THEN 4
    WHEN 'MMBtu' THEN 5
END;

-- Example output for UK site, Steam & Heating:
-- kWh: 2 factors available (District Heating - UK)
-- MWh: 2 factors available
-- GJ: 2 factors available
-- Therms: 2 factors available (UK-specific)
```

**Step 4: Enter Consumption Value**
- Input field with selected unit label
- Preview emission factor before submission

**Step 5: Preview Before Submit**
```sql
-- Show selected emission factor:
SELECT
    ef.display_name,
    ef.factor_value,
    ef.unit,
    ef.source,
    ef.validity_start_date
FROM emission_factors ef
WHERE ef.id = :selected_factor_id;

-- Calculate preview:
-- estimated_emissions = consumption_value × factor_value / 1000 (convert to tonnes)
```

### UI Query Examples

**Get available units for site:**
```sql
-- For Heat/Steam/Cooling at a specific site
SELECT DISTINCT ef.unit
FROM emission_factors ef
JOIN emission_factor_classifications efc ON ef.id = efc.emission_factor_id
WHERE efc.emission_category_id = :category_id
  AND (ef.country_code = (SELECT country_code FROM sites WHERE id = :site_id)
       OR ef.geographic_scope = 'Global')
  AND ef.is_active = true
ORDER BY CASE ef.unit
    WHEN 'kWh' THEN 1
    WHEN 'MWh' THEN 2
    WHEN 'GJ' THEN 3
    WHEN 'Therms' THEN 4
    WHEN 'MMBtu' THEN 5
END;
```

**Get factor for selected category + unit:**
```sql
SELECT ef.*
FROM emission_factors ef
JOIN emission_factor_classifications efc ON ef.id = efc.emission_factor_id
WHERE efc.emission_category_id = :category_id
  AND ef.unit = :selected_unit
  AND (ef.country_code = :site_country OR ef.geographic_scope = 'Global')
  AND ef.is_active = true
  AND :reporting_date BETWEEN ef.validity_start_date AND ef.validity_end_date
ORDER BY
    CASE WHEN ef.country_code = :site_country THEN 1 ELSE 2 END,
    ef.validity_start_date DESC
LIMIT 1;
```

---

## Known Issues and Considerations

### 1. USA Grid Region Mapping
**Issue:** USA sites require state-to-eGRID subregion mapping

**Workaround:** Manual mapping required for now

**Future enhancement:** Add state column to sites table + automated mapping script

### 2. Therms vs MMBtu
**Note:**
- **Therms:** Used in UK and Commonwealth countries (1 Therm = 29.3071 kWh)
- **MMBtu:** Used in USA (1 MMBtu = 293.071 kWh)

Script correctly filters by region to show appropriate units.

### 3. District Heating Provider-Specific Factors
**Current:** Only national/global average factors

**Future enhancement:** Could add provider-specific factors (e.g., "Vattenfall District Heat - Stockholm")

### 4. Electricity Unit Selection
**Note:** Electricity uses only kWh because grid_regions table only stores kWh factors

**Future consideration:** Could extend grid_regions with multiple units if needed

---

## Validation Checklist

After executing all scripts, verify:

- [ ] `electricity_contracts` table exists with helper function
- [ ] ~26 base Heat/Steam/Cooling factors in kWh exist
- [ ] ~100+ multi-unit factors exist (MWh, GJ, Therms, MMBtu)
- [ ] Sites have `grid_region` populated (except USA)
- [ ] `insert_scope2_emission()` function exists
- [ ] Validation script passes all 12 steps
- [ ] Architecture verification confirms:
  - Electricity entries: `emission_factor_id IS NULL`
  - Heat/Steam/Cooling entries: `emission_factor_id IS NOT NULL`

---

## Next Steps

1. Execute scripts in order (Steps 1-6)
2. Run validation script and verify all tests pass
3. Test UI workflow with cascading dropdowns
4. Add sample renewable contract for testing market-based methodology
5. Map USA sites to eGRID subregions (manual or enhanced script)

---

## Questions?

If you encounter errors:
1. Check column names match database schema
2. Verify grid_regions table has 29 regions
3. Confirm emission_categories and activity_types exist for Scope 2
4. Review validation query results

End of Scope 2 Execution Guide
