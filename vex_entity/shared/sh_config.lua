VexEntityModels = VexEntityModels or {}

-- ============================================================================
-- Model allow-lists
-- ============================================================================
--
-- FAIL-CLOSED POLICY:
-- A model absent from the relevant table is rejected.
--
-- Keep categories separate. This prevents callers from supplying a legitimate
-- hash but lying about its entity class.
--
-- Horses/mounts belong in the ped table, never the vehicle table.
--
-- Only the explicit wagon model present in the architecture is pre-populated
-- here. Add deployment-approved models deliberately rather than opening this
-- resource to arbitrary hashes.

VexEntityModels.Peds = {
    -- [`a_c_horse_example`] = true,
}

VexEntityModels.Vehicles = {
    [`p_wagon01x`] = true,
}

VexEntityModels.Objects = {
    -- [`p_example_prop01x`] = true,
}

-- ============================================================================
-- Utility API
-- ============================================================================

function VexEntityModels.NormalizeHash(model)
    if type(model) == 'number' then
        return model
    end

    if type(model) == 'string' and model ~= '' then
        return joaat(model)
    end

    return nil
end

function VexEntityModels.GetPool(entityType)
    if entityType == 'ped' then
        return VexEntityModels.Peds
    end

    if entityType == 'vehicle' then
        return VexEntityModels.Vehicles
    end

    if entityType == 'object' then
        return VexEntityModels.Objects
    end

    return nil
end

function VexEntityModels.IsAllowed(entityType, model)
    local pool = VexEntityModels.GetPool(entityType)
    if not pool then
        return false
    end

    local hash = VexEntityModels.NormalizeHash(model)
    if not hash then
        return false
    end

    return pool[hash] == true
end