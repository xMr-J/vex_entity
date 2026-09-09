-- ============================================================================
-- vex_entity — server/main.lua
-- ============================================================================
--
-- Consolidated server-authoritative entity lifecycle module. This file merges
-- what were previously five separate server modules (registry, state,
-- vex_callback bridge, spawn/delete, migration+GC) into one production file:
--
--   1. Master Server Entity Ledger    (GlobalEntityRegistry + indices)
--   2. Reserved-namespace State Bags  (VexEntityState)
--   3. vex_callback / client-op bridge (VexEntityServerBridge)
--   4. Secure Spawning / Deletion Exports
--   5. Client-originated deletion requests (vex_core proximity gate)
--   6. Ownership migration ingestion + disconnect/resource-stop/idle/orphan GC
--
-- Load order inside this single chunk mirrors the original file order so
-- every forward reference (e.g. spawn logic calling the registry's PurgeEntity
-- global, or the GC sweep calling into VexEntityState) resolves exactly the
-- same way it did when these were separate server_scripts entries.
--
-- Depends on: shared/sh_config.lua (VexEntityModels), config.lua (Config).
-- vex_core and vex_callback are soft dependencies — every call into either is
-- capability-checked/pcall-wrapped, never assumed present, per the
-- architecture's own "unconfirmed external API" posture.
--
-- Performance/security audit pass (this revision):
--   - Registry Count()/CountByType() are O(1) maintained counters instead of
--     a pairs() scan on every SpawnNetworkedEntity call (Section 1).
--   - A third secondary index, EntitiesByResource, plus an onResourceStop
--     handler (Section 6) close the gap where entities spawned on behalf of
--     a script (not a player) were never cleaned up if that script stopped
--     or restarted mid-session.
--   - Client-originated deletion proximity checks now prefer the entity's
--     LIVE server-tracked position over the registry cache, and apply
--     Config.NetworkPositionTolerance on top of Config.MaxClientDeleteDistance
--     to absorb legitimate latency/jitter without weakening the base radius
--     (Section 5).
--   - The reserved-namespace state-bag audit's internal-write suppression is
--     now keyed per-entity instead of per-key-name (Section 2), removing a
--     latent (currently harmless, but not structurally guaranteed) cross-talk
--     risk between two different entities sharing a vex:* key name.

-- ============================================================================
-- SECTION 1 — Master Server Entity Ledger
-- ============================================================================

GlobalEntityRegistry = GlobalEntityRegistry or {}
EntitiesBySource = EntitiesBySource or {}
EntitiesByType = EntitiesByType or {
    ped = {},
    vehicle = {},
    object = {}
}

-- Third secondary index, keyed by the resource that originally called
-- SpawnNetworkedEntity (GetInvokingResource() at spawn time — see Section 4).
-- Exists so a dependent gameplay resource stopping/restarting (Section 6)
-- can be swept in O(k), the same way a player disconnect already is, instead
-- of leaking every transient entity it ever spawned.
EntitiesByResource = EntitiesByResource or {}

VexEntityRegistry = VexEntityRegistry or {}

local RESOURCE = GetCurrentResourceName()

-- Maintained counters, not O(n) scans. Count()/CountByType() are called on
-- EVERY SpawnNetworkedEntity invocation via ensureCapacity — under rapid
-- multi-entity creation that made every single spawn pay for a full
-- GlobalEntityRegistry traversal just to check a number. Insert/RemoveIndexes
-- below are the only two places entries ever enter/leave the registry, so
-- they are the only two places these counters are touched.
local registryCount = 0
local registryCountByType = {}

local function now()
    return GetGameTimer()
end

local function log(level, message, ...)
    if level == 'debug' and not Config.Debug then
        return
    end

    local formatted = message

    if select('#', ...) > 0 then
        formatted = string.format(message, ...)
    end

    print(('[%s] [%s] %s'):format(
        RESOURCE,
        string.upper(level),
        formatted
    ))
end

VexEntityRegistry.Log = log
VexEntityRegistry.Now = now

local function ensureSourceIndex(source)
    if source == nil then
        return nil
    end

    source = tonumber(source)

    if not source or source <= 0 then
        return nil
    end

    EntitiesBySource[source] = EntitiesBySource[source] or {}

    return EntitiesBySource[source]
end

local function ensureTypeIndex(entityType)
    EntitiesByType[entityType] = EntitiesByType[entityType] or {}
    return EntitiesByType[entityType]
end

local function ensureResourceIndex(resourceName)
    if type(resourceName) ~= 'string' or resourceName == '' then
        return nil
    end

    EntitiesByResource[resourceName] = EntitiesByResource[resourceName] or {}

    return EntitiesByResource[resourceName]
end

function VexEntityRegistry.Insert(record)
    assert(type(record) == 'table', 'record must be a table')
    assert(type(record.netId) == 'number', 'record.netId must be a number')
    assert(
        Config.ValidEntityTypes[record.entityType] == true,
        'invalid record.entityType'
    )

    if GlobalEntityRegistry[record.netId] then
        return false, 'duplicate_net_id'
    end

    GlobalEntityRegistry[record.netId] = record

    local sourceIndex = ensureSourceIndex(record.spawnedBy)

    if sourceIndex then
        sourceIndex[record.netId] = true
    end

    ensureTypeIndex(record.entityType)[record.netId] = true

    local resourceIndex = ensureResourceIndex(record.invokingResource)

    if resourceIndex then
        resourceIndex[record.netId] = true
    end

    registryCount = registryCount + 1
    registryCountByType[record.entityType] =
        (registryCountByType[record.entityType] or 0) + 1

    return true
end

function VexEntityRegistry.RemoveIndexes(record)
    if not record then
        return
    end

    local source = tonumber(record.spawnedBy)

    if source and EntitiesBySource[source] then
        EntitiesBySource[source][record.netId] = nil

        if next(EntitiesBySource[source]) == nil then
            EntitiesBySource[source] = nil
        end
    end

    local typeIndex = EntitiesByType[record.entityType]

    if typeIndex then
        typeIndex[record.netId] = nil
    end

    local resourceName = record.invokingResource

    if
        type(resourceName) == 'string'
        and EntitiesByResource[resourceName]
    then
        EntitiesByResource[resourceName][record.netId] = nil

        if next(EntitiesByResource[resourceName]) == nil then
            EntitiesByResource[resourceName] = nil
        end
    end

    registryCount = math.max(0, registryCount - 1)

    if registryCountByType[record.entityType] then
        registryCountByType[record.entityType] = math.max(
            0,
            registryCountByType[record.entityType] - 1
        )
    end
end

function VexEntityRegistry.Get(netId)
    return GlobalEntityRegistry[tonumber(netId)]
end

function VexEntityRegistry.Touch(netId, coords, heading)
    local entry = VexEntityRegistry.Get(netId)

    if not entry then
        return false
    end

    entry.lastSeen = now()

    if coords then
        entry.coords = coords
    end

    if heading ~= nil then
        entry.heading = heading
    end

    return true
end

function VexEntityRegistry.SetOwner(netId, source, coords, heading)
    local entry = VexEntityRegistry.Get(netId)

    if not entry then
        return false
    end

    entry.currentOwner = tonumber(source) or 0
    entry.lastSeen = now()

    if coords then
        entry.coords = coords
    end

    if heading ~= nil then
        entry.heading = heading
    end

    return true
end

-- O(1) — maintained by Insert/RemoveIndexes above, never a table scan. This
-- is on the hot path (ensureCapacity calls it on every spawn, potentially
-- more than once inside its eviction loop), which is exactly what made the
-- previous full-registry pairs() scan a real cost under rapid multi-entity
-- creation.
function VexEntityRegistry.Count()
    return registryCount
end

function VexEntityRegistry.CountByType(entityType)
    return registryCountByType[entityType] or 0
end

function VexEntityRegistry.GetBySource(source)
    source = tonumber(source)

    if not source or not EntitiesBySource[source] then
        return {}
    end

    local result = {}

    for netId in pairs(EntitiesBySource[source]) do
        result[#result + 1] = netId
    end

    return result
end

function VexEntityRegistry.GetByResource(resourceName)
    if type(resourceName) ~= 'string' or not EntitiesByResource[resourceName] then
        return {}
    end

    local result = {}

    for netId in pairs(EntitiesByResource[resourceName]) do
        result[#result + 1] = netId
    end

    return result
end

function VexEntityRegistry.SetPersistence(netId, persistent)
    local entry = VexEntityRegistry.Get(netId)

    if not entry then
        return false, 'unknown_net_id'
    end

    persistent = persistent == true

    entry.isPersistent = persistent
    entry.deletionPool = not persistent
    entry.lastSeen = now()

    return true
end

local function resolveServerEntity(netId)
    if type(NetworkGetEntityFromNetworkId) ~= 'function' then
        return nil
    end

    local ok, entity = pcall(NetworkGetEntityFromNetworkId, netId)

    if not ok or not entity or entity == 0 then
        return nil
    end

    return entity
end

local function serverEntityExists(netId)
    if type(NetworkDoesEntityExistWithNetworkId) == 'function' then
        local ok, exists = pcall(NetworkDoesEntityExistWithNetworkId, netId)

        if ok then
            return exists == true
        end
    end

    local entity = resolveServerEntity(netId)

    if entity and type(DoesEntityExist) == 'function' then
        local ok, exists = pcall(DoesEntityExist, entity)

        if ok then
            return exists == true
        end
    end

    return false
end

local function tryServerDelete(netId)
    local entity = resolveServerEntity(netId)

    if not entity then
        return false, 'no_server_entity_handle'
    end

    if type(DeleteEntity) ~= 'function' then
        return false, 'server_delete_native_unavailable'
    end

    local ok = pcall(DeleteEntity, entity)

    if not ok then
        return false, 'server_delete_native_failed'
    end

    return true
end

-- The single convergent teardown primitive. Every deletion path in this file
-- — explicit export call, proximity-gated client request, disconnect GC,
-- idle sweep, orphan safeguard, and pool-overflow eviction — funnels through
-- this function and only this function ever removes a registry entry.
function VexEntityRegistry.PurgeEntity(netId, reason)
    netId = tonumber(netId)

    local entry = GlobalEntityRegistry[netId]

    if not entry then
        return true, 'already_absent'
    end

    if entry.purgeInFlight then
        return false, 'purge_already_in_flight'
    end

    entry.purgeInFlight = true
    entry.pendingDeletion = true

    local deleted = false

    if not serverEntityExists(netId) then
        deleted = true
    else
        local issued = tryServerDelete(netId)

        if issued then
            local deadline = now() + Config.DeleteConfirmationTimeoutMs

            while now() < deadline do
                if not serverEntityExists(netId) then
                    deleted = true
                    break
                end

                Wait(Config.DeleteConfirmationPollMs)
            end
        end

        -- Direct server-side deletion either isn't available on this build or
        -- didn't confirm in time. Fall back to instructing the entity's
        -- current owning client to take control and delete it locally.
        if not deleted and VexEntityServerBridge then
            local owner = tonumber(entry.currentOwner)

            if owner and owner > 0 then
                local ok = VexEntityServerBridge.RequestClientDelete(
                    owner,
                    netId
                )

                if ok then
                    local deadline = now() + Config.DeleteConfirmationTimeoutMs

                    while now() < deadline do
                        if not serverEntityExists(netId) then
                            deleted = true
                            break
                        end

                        Wait(Config.DeleteConfirmationPollMs)
                    end
                end
            end
        end
    end

    if not deleted and serverEntityExists(netId) then
        entry.pendingDeletion = false
        entry.purgeInFlight = false

        log(
            'warn',
            'Failed to confirm deletion of netId %s (%s). Registry retained.',
            netId,
            tostring(reason)
        )

        return false, 'delete_confirmation_failed'
    end

    if VexEntityState then
        VexEntityState.ClearReservedState(netId)
    end

    VexEntityRegistry.RemoveIndexes(entry)
    GlobalEntityRegistry[netId] = nil

    log(
        'debug',
        'Purged netId %s. reason=%s',
        netId,
        tostring(reason)
    )

    return true
end

-- Blueprint primitive name — referenced as a bare global throughout this file.
PurgeEntity = VexEntityRegistry.PurgeEntity

-- ============================================================================
-- SECTION 2 — Reserved-Namespace State Bag Control
-- ============================================================================

VexEntityState = VexEntityState or {}

-- Keyed [entity][key], not just [key]. setBag() below never yields between
-- incrementing this and issuing the native write, so a bare [key] table was
-- already safe under the current single-threaded/cooperative call pattern —
-- but it was safe by coincidence of there being no Wait() in that path
-- today, not by construction. Keying per-entity removes that coincidence:
-- two different entities' state bags writing the same key name (e.g. two
-- separate vex_entity spawns both writing vex:currentOwner back to back)
-- can never cross-suppress each other's audit exemption even if a future
-- change adds a yield point into setBag.
local internalStateWrite = {}

local function markInternalWrite(entity, key, delta)
    internalStateWrite[entity] = internalStateWrite[entity] or {}

    local bucket = internalStateWrite[entity]
    bucket[key] = (bucket[key] or 0) + delta

    if bucket[key] <= 0 then
        bucket[key] = nil

        if next(bucket) == nil then
            internalStateWrite[entity] = nil
        end
    end
end

local function isInternalWrite(entity, key)
    local bucket = internalStateWrite[entity]
    return bucket ~= nil and bucket[key] ~= nil
end

local function getEntity(netId)
    if type(NetworkGetEntityFromNetworkId) ~= 'function' then
        return nil
    end

    local ok, entity = pcall(NetworkGetEntityFromNetworkId, netId)

    if not ok or not entity or entity == 0 then
        return nil
    end

    if type(DoesEntityExist) == 'function' then
        local existsOk, exists = pcall(DoesEntityExist, entity)

        if existsOk and not exists then
            return nil
        end
    end

    return entity
end

local function startsWithReservedPrefix(key)
    return type(key) == 'string'
        and key:sub(1, #Config.ReservedStatePrefix) == Config.ReservedStatePrefix
end

local function setBag(entity, key, value)
    markInternalWrite(entity, key, 1)

    local ok, err = pcall(function()
        Entity(entity).state:set(key, value, true)
    end)

    markInternalWrite(entity, key, -1)

    if not ok then
        if Config.DebugStateBags then
            log(
                'warn',
                'State write failed key=%s error=%s',
                tostring(key),
                tostring(err)
            )
        end

        return false
    end

    return true
end

-- Pushes every vex:-namespaced bookkeeping field onto the entity at spawn
-- time, so any other resource holding this entity handle can read ownership/
-- pool metadata directly off it without an export round trip.
function VexEntityState.WriteReserved(netId)
    local record = VexEntityRegistry.Get(netId)

    if not record then
        return false
    end

    local entity = getEntity(netId)

    if not entity then
        return false
    end

    setBag(entity, Config.StateKeys.netId, record.netId)
    setBag(entity, Config.StateKeys.entityType, record.entityType)
    setBag(entity, Config.StateKeys.modelHash, record.modelHash)
    setBag(entity, Config.StateKeys.spawnedBy, record.spawnedBy or 0)
    setBag(entity, Config.StateKeys.currentOwner, record.currentOwner or 0)
    setBag(entity, Config.StateKeys.deletionPool, record.deletionPool)
    setBag(entity, Config.StateKeys.persistent, record.isPersistent)
    setBag(entity, Config.StateKeys.spawnTag, record.spawnTag)

    return true
end

function VexEntityState.WriteOwner(netId)
    local record = VexEntityRegistry.Get(netId)

    if not record then
        return false
    end

    local entity = getEntity(netId)

    if not entity then
        return false
    end

    return setBag(
        entity,
        Config.StateKeys.currentOwner,
        record.currentOwner or 0
    )
end

function VexEntityState.WritePersistence(netId)
    local record = VexEntityRegistry.Get(netId)

    if not record then
        return false
    end

    local entity = getEntity(netId)

    if not entity then
        return false
    end

    setBag(entity, Config.StateKeys.deletionPool, record.deletionPool)
    setBag(entity, Config.StateKeys.persistent, record.isPersistent)

    return true
end

function VexEntityState.ClearReservedState(netId)
    local entity = getEntity(netId)

    if not entity then
        return
    end

    for _, key in pairs(Config.StateKeys) do
        setBag(entity, key, nil)
    end
end

-- The sanctioned entry point for the OPEN gameplay namespace (Section 3's
-- SetEntityState export routes here). Reserved vex:* keys are refused before
-- the bag is ever touched.
function VexEntityState.SetGameplayState(netId, key, value)
    if type(key) ~= 'string' or key == '' then
        return false, 'invalid_key'
    end

    if startsWithReservedPrefix(key) then
        return false, 'reserved_state_namespace'
    end

    local entity = getEntity(tonumber(netId))

    if not entity then
        return false, 'entity_not_found'
    end

    local ok = pcall(function()
        Entity(entity).state:set(key, value, true)
    end)

    if not ok then
        return false, 'state_write_failed'
    end

    return true
end

-- ----------------------------------------------------------------------------
-- Reserved-namespace audit — defense in depth against a modified client
-- attempting to overwrite vex:* bookkeeping directly. Convention alone
-- ("only vex_entity writes this") is not an enforcement mechanism, so any
-- external write into the reserved namespace is reverted back to the
-- registry's own authoritative value and logged.
-- ----------------------------------------------------------------------------

if type(AddStateBagChangeHandler) == 'function' then
    AddStateBagChangeHandler(nil, nil, function(
        bagName,
        key,
        value,
        _reserved,
        replicated
    )
        if not startsWithReservedPrefix(key) then
            return
        end

        if replicated ~= true then
            return
        end

        local entity = nil

        if type(GetEntityFromStateBagName) == 'function' then
            local ok, resolved = pcall(GetEntityFromStateBagName, bagName)

            if ok then
                entity = resolved
            end
        end

        if not entity or entity == 0 then
            return
        end

        -- Resolved to a concrete entity handle first, THEN checked against
        -- the per-entity suppression map — this is what makes the audit
        -- exemption specific to the entity vex_entity itself just wrote,
        -- never to every entity sharing that key name.
        if isInternalWrite(entity, key) then
            return
        end

        if type(NetworkGetNetworkIdFromEntity) ~= 'function' then
            return
        end

        local ok, netId = pcall(NetworkGetNetworkIdFromEntity, entity)

        if not ok or not netId then
            return
        end

        local record = VexEntityRegistry.Get(netId)

        if not record then
            return
        end

        local expected

        if key == Config.StateKeys.netId then
            expected = record.netId
        elseif key == Config.StateKeys.entityType then
            expected = record.entityType
        elseif key == Config.StateKeys.modelHash then
            expected = record.modelHash
        elseif key == Config.StateKeys.spawnedBy then
            expected = record.spawnedBy or 0
        elseif key == Config.StateKeys.currentOwner then
            expected = record.currentOwner or 0
        elseif key == Config.StateKeys.deletionPool then
            expected = record.deletionPool
        elseif key == Config.StateKeys.persistent then
            expected = record.isPersistent
        elseif key == Config.StateKeys.spawnTag then
            expected = record.spawnTag
        else
            -- Unknown vex:* key: the namespace is completely reserved.
            expected = nil
        end

        log(
            'warn',
            'Rejected external reserved state write netId=%s key=%s value=%s',
            tostring(netId),
            tostring(key),
            tostring(value)
        )

        setBag(entity, key, expected)
    end)
end

-- ============================================================================
-- SECTION 3 — vex_callback / Client-Operation Bridge
-- ============================================================================
--
-- vex_callback's concrete resolve/timeout API is unconfirmed (see project
-- architecture notes) — every structural-validation check below is plain
-- server-side Lua so it works standalone today, and can be re-wired behind
-- vex_callback's real promise/coroutine surface later without changing any
-- export signature in Section 4.

VexEntityServerBridge = VexEntityServerBridge or {}

local pendingClientOps = {}
local nextRequestSeq = 0

local function nextRequestId()
    nextRequestSeq = nextRequestSeq + 1

    if nextRequestSeq > 2147483647 then
        nextRequestSeq = 1
    end

    return ('%s:%s:%s'):format(
        GetCurrentResourceName(),
        GetGameTimer(),
        nextRequestSeq
    )
end

function VexEntityServerBridge.ValidateSpawn(
    entityType,
    modelHash,
    coords,
    isPersistent
)
    if Config.ValidEntityTypes[entityType] ~= true then
        return false, 'invalid_entity_type'
    end

    modelHash = VexEntityModels.NormalizeHash(modelHash)

    if not modelHash then
        return false, 'invalid_model_hash'
    end

    if not VexEntityModels.IsAllowed(entityType, modelHash) then
        return false, 'model_not_whitelisted'
    end

    if type(coords) ~= 'vector3' and type(coords) ~= 'table' then
        return false, 'invalid_coordinates'
    end

    local x = tonumber(coords.x)
    local y = tonumber(coords.y)
    local z = tonumber(coords.z)

    if not x or not y or not z then
        return false, 'invalid_coordinates'
    end

    -- NaN rejection.
    if x ~= x or y ~= y or z ~= z then
        return false, 'invalid_coordinates'
    end

    if Config.WorldBounds.enabled then
        local minimum = Config.WorldBounds.min
        local maximum = Config.WorldBounds.max

        if
            x < minimum.x or x > maximum.x
            or y < minimum.y or y > maximum.y
            or z < minimum.z or z > maximum.z
        then
            return false, 'coordinates_out_of_bounds'
        end
    end

    return true, {
        entityType = entityType,
        modelHash = modelHash,
        coords = vector3(x, y, z),
        isPersistent = isPersistent == true
    }
end

function VexEntityServerBridge.ValidateDelete(netId)
    netId = tonumber(netId)

    if not netId then
        return false, 'invalid_net_id'
    end

    local record = VexEntityRegistry.Get(netId)

    if not record then
        return false, 'unknown_net_id'
    end

    if record.pendingDeletion then
        return false, 'deletion_already_pending'
    end

    return true, record
end

-- ----------------------------------------------------------------------------
-- Internal designated-client operation bridge — only used when direct
-- server-side entity creation/deletion natives are unavailable on the target
-- build (Section 1's PurgeEntity fallback, and a future client-create
-- fallback once nearest-client arbitration is decided).
-- ----------------------------------------------------------------------------

RegisterNetEvent('vex_entity:clientOperationResult', function(
    requestId,
    success,
    payload
)
    local source = source
    local request = pendingClientOps[requestId]

    if not request then
        return
    end

    -- A client may only resolve the request it was actually issued.
    if request.source ~= source then
        return
    end

    request.done = true
    request.success = success == true
    request.payload = payload
end)

local function awaitClientOperation(source, operation, payload)
    source = tonumber(source)

    if not source or source <= 0 then
        return false, 'invalid_client'
    end

    local requestId = nextRequestId()

    pendingClientOps[requestId] = {
        source = source,
        done = false,
        success = false,
        payload = nil
    }

    TriggerClientEvent(
        'vex_entity:clientOperation',
        source,
        requestId,
        operation,
        payload
    )

    local deadline = now() + Config.ClientOperationTimeoutMs

    while now() < deadline do
        local request = pendingClientOps[requestId]

        if not request then
            return false, 'request_disappeared'
        end

        if request.done then
            local success = request.success
            local result = request.payload

            pendingClientOps[requestId] = nil

            return success, result
        end

        Wait(25)
    end

    pendingClientOps[requestId] = nil

    return false, 'client_operation_timeout'
end

function VexEntityServerBridge.RequestClientDelete(source, netId)
    return awaitClientOperation(source, 'delete', {
        netId = netId
    })
end

function VexEntityServerBridge.RequestClientCreate(source, payload)
    return awaitClientOperation(source, 'create', payload)
end

-- ============================================================================
-- SECTION 4 — Secure Spawning / Deletion Exports
-- ============================================================================
--
-- These exports are the ONLY sanctioned way another server-side resource
-- creates or destroys a vex_entity-managed networked object. A client can
-- never call an export directly — exports are not network-exposed — so raw
-- client-side CreateVehicle/CreatePed/CreateObject/DeleteEntity calls from a
-- gameplay script are architecturally impossible to route around this file:
-- there is no server code path that trusts a client-originated creation
-- command at all, and the one client-originated deletion path (Section 5)
-- is proximity-gated and funnels into the exact same deleteEntitySafely
-- below rather than a parallel implementation.

local function createServerEntity(entityType, modelHash, coords, heading)
    heading = tonumber(heading) or 0.0

    -- Exact RedM server-native parity is an open architecture item. Every
    -- native call is capability-checked instead of assumed present.

    if entityType == 'vehicle' then
        if type(CreateVehicle) ~= 'function' then
            return nil, 'server_vehicle_creation_unavailable'
        end

        local ok, entity = pcall(
            CreateVehicle,
            modelHash,
            coords.x,
            coords.y,
            coords.z,
            heading,
            true,
            true
        )

        if ok and entity and entity ~= 0 then
            return entity
        end

        return nil, 'server_vehicle_creation_failed'
    end

    if entityType == 'ped' then
        if type(CreatePed) ~= 'function' then
            return nil, 'server_ped_creation_unavailable'
        end

        -- pedType is deliberately not guessed: the architecture leaves the
        -- exact RDR3 pedType enum as an implementation-open item, and
        -- guessing wrong here is worse than refusing outright (a wrong
        -- pedType can silently misclassify a networked ped rather than
        -- fail loudly).
        return nil, 'ped_type_not_configured'
    end

    if entityType == 'object' then
        local creator = CreateObjectNoOffset or CreateObject

        if type(creator) ~= 'function' then
            return nil, 'server_object_creation_unavailable'
        end

        local ok, entity = pcall(
            creator,
            modelHash,
            coords.x,
            coords.y,
            coords.z,
            true,
            true,
            false
        )

        if ok and entity and entity ~= 0 then
            return entity
        end

        return nil, 'server_object_creation_failed'
    end

    return nil, 'invalid_entity_type'
end

local function getNetId(entity)
    if type(NetworkGetNetworkIdFromEntity) ~= 'function' then
        return nil
    end

    local ok, netId = pcall(NetworkGetNetworkIdFromEntity, entity)

    if not ok or not netId or netId == 0 then
        return nil
    end

    return netId
end

-- Still an O(n) pairs() scan, deliberately not converted to a maintained
-- structure like Count()/CountByType() above. Reviewed, not an oversight:
-- this only runs inside ensureCapacity's eviction path, which only triggers
-- near/at Config.MaxPoolSize (500 by default) — a bounded, rare-path scan of
-- at most a few hundred entries, not the per-spawn hot path Count() was. A
-- FIFO/ordered structure would remove even that, but only at real risk: an
-- eviction that fails after being popped (delete-confirmation timeout,
-- client-fallback failure) would need to be re-queued correctly or the
-- structure silently loses a valid candidate over time — added correctness
-- surface disproportionate to optimizing an already-bounded, already-rare
-- scan.
local function oldestTransient(entityType)
    local candidate

    for _, entry in pairs(GlobalEntityRegistry) do
        if
            entry.deletionPool == true
            and not entry.pendingDeletion
            and (not entityType or entry.entityType == entityType)
        then
            if not candidate or entry.createdAt < candidate.createdAt then
                candidate = entry
            end
        end
    end

    return candidate
end

local function ensureCapacity(entityType)
    while VexEntityRegistry.Count() >= Config.MaxPoolSize do
        local candidate = oldestTransient(nil)

        if not candidate then
            return false, 'global_capacity_exceeded'
        end

        local purged = PurgeEntity(candidate.netId, 'overflow')

        if not purged then
            return false, 'global_capacity_exceeded'
        end
    end

    local typeCap = Config.MaxPoolByType[entityType]

    if typeCap then
        while VexEntityRegistry.CountByType(entityType) >= typeCap do
            local candidate = oldestTransient(entityType)

            if not candidate then
                return false, ('%s_capacity_exceeded'):format(entityType)
            end

            local purged = PurgeEntity(candidate.netId, 'overflow')

            if not purged then
                return false, ('%s_capacity_exceeded'):format(entityType)
            end
        end
    end

    return true
end

local function registerEntity(
    entity,
    entityType,
    modelHash,
    coords,
    heading,
    isPersistent,
    spawnedBy,
    spawnTag,
    invokingResource
)
    local netId = getNetId(entity)

    if not netId then
        return nil, 'network_id_unavailable'
    end

    local timestamp = VexEntityRegistry.Now()

    local record = {
        netId = netId,
        entityType = entityType,
        modelHash = modelHash,

        spawnedBy = tonumber(spawnedBy) or 0,
        invokingResource = invokingResource,

        coords = vector3(coords.x, coords.y, coords.z),
        heading = tonumber(heading) or 0.0,

        currentOwner = tonumber(spawnedBy) or 0,

        deletionPool = not isPersistent,
        isPersistent = isPersistent == true,

        createdAt = timestamp,
        lastSeen = timestamp,

        spawnTag = spawnTag,

        pendingDeletion = false,
        purgeInFlight = false,
        orphanSince = nil
    }

    local inserted, reason = VexEntityRegistry.Insert(record)

    if not inserted then
        return nil, reason
    end

    VexEntityState.WriteReserved(netId)

    return netId
end

local function spawnNetworkedEntity(
    entityType,
    modelHash,
    coords,
    isPersistent,
    options
)
    -- Captured as the very first statement, before anything below can yield
    -- (ensureCapacity's eviction path is the one place this function can
    -- Wait()). GetInvokingResource() resolves the resource that crossed the
    -- export boundary to call this — capturing it after a yield risks
    -- resolving the wrong (or no) caller, since a suspended coroutine can
    -- resume in a different native call-stack context. Same
    -- capture-at-creation-time convention vex_prompts/vex_zones use for
    -- their own invokingResource field.
    local invokingResource = GetInvokingResource()

    options = type(options) == 'table' and options or {}

    -- Structural validation ALWAYS runs before any native creation call.
    -- Nothing below this point executes against an unvalidated request.
    local valid, normalized = VexEntityServerBridge.ValidateSpawn(
        entityType,
        modelHash,
        coords,
        isPersistent
    )

    if not valid then
        return nil, normalized
    end

    local capacityOk, capacityReason = ensureCapacity(
        normalized.entityType
    )

    if not capacityOk then
        return nil, capacityReason
    end

    local heading = tonumber(options.heading) or 0.0
    local spawnedBy = tonumber(options.spawnedBy) or 0
    local spawnTag = options.spawnTag

    local entity, createReason = createServerEntity(
        normalized.entityType,
        normalized.modelHash,
        normalized.coords,
        heading
    )

    if not entity then
        -- A server-designated client fallback is allowed by the architecture
        -- but nearest-client arbitration is an unresolved open item — do not
        -- silently pick a random connected client to originate a spawn.
        return nil, createReason
    end

    local netId, registerReason = registerEntity(
        entity,
        normalized.entityType,
        normalized.modelHash,
        normalized.coords,
        heading,
        normalized.isPersistent,
        spawnedBy,
        spawnTag,
        invokingResource
    )

    if not netId then
        if type(DeleteEntity) == 'function' then
            pcall(DeleteEntity, entity)
        end

        return nil, registerReason
    end

    if Config.DebugSpawn then
        log(
            'debug',
            'Spawned %s netId=%s model=%s persistent=%s',
            normalized.entityType,
            tostring(netId),
            tostring(normalized.modelHash),
            tostring(normalized.isPersistent)
        )
    end

    return netId
end

local function deleteEntitySafely(netId)
    local valid, result = VexEntityServerBridge.ValidateDelete(netId)

    if not valid then
        if result == 'unknown_net_id' then
            log(
                'warn',
                'DeleteEntitySafely ignored unknown netId %s.',
                tostring(netId)
            )

            return true, 'unknown_net_id'
        end

        return false, result
    end

    result.pendingDeletion = true

    return PurgeEntity(result.netId, 'explicit')
end

local function setEntityPersistence(netId, persistent)
    local success, reason = VexEntityRegistry.SetPersistence(
        tonumber(netId),
        persistent
    )

    if not success then
        return false, reason
    end

    VexEntityState.WritePersistence(tonumber(netId))

    return true
end

-- ----------------------------------------------------------------------------
-- Public server exports
-- ----------------------------------------------------------------------------

exports('SpawnNetworkedEntity', function(
    entityType,
    modelHash,
    coords,
    isPersistent,
    options
)
    return spawnNetworkedEntity(
        entityType,
        modelHash,
        coords,
        isPersistent,
        options
    )
end)

exports('DeleteEntitySafely', function(netId)
    return deleteEntitySafely(netId)
end)

exports('SetEntityState', function(netId, key, value)
    return VexEntityState.SetGameplayState(
        tonumber(netId),
        key,
        value
    )
end)

exports('GetEntityRecord', function(netId)
    return VexEntityRegistry.Get(tonumber(netId))
end)

exports('GetEntitiesBySource', function(source)
    return VexEntityRegistry.GetBySource(source)
end)

exports('SetEntityPersistence', function(netId, persistent)
    return setEntityPersistence(netId, persistent)
end)

-- ============================================================================
-- SECTION 5 — Client-Originated Deletion Requests (proximity-gated)
-- ============================================================================
--
-- DeleteEntitySafely (Section 4) is for trusted server-side callers and, by
-- design, performs no player-proximity check — Config.MaxClientDeleteDistance
-- documents exactly that split ("Server resources invoking DeleteEntitySafely
-- directly are not treated as player proximity requests"). A raw client can
-- never reach that export directly, since exports are not network-exposed —
-- so this network event is the ONLY path by which player input can reach
-- entity deletion, and it is where the actual untrusted-input boundary lives.
--
-- The security property this section provides: a player may only request
-- deletion of an entity they are actually standing near, verified against
-- coordinates the SERVER independently resolves for that player — never
-- coordinates the client supplies about itself. This closes the injection
-- vector named in the brief (a modified client firing a delete request for
-- an arbitrary, distant NetID it has no legitimate reason to touch).

local function getAuthoritativePlayerCoords(source)
    -- Preferred path: vex_core, when running, is this ecosystem's own
    -- canonical authoritative-coordinate source. Its exact export name/return
    -- shape is not pinned anywhere in this project, so the call is guarded
    -- exactly like vex_zones' own (unconfirmed) vex_core integration —
    -- a missing export, wrong signature, or vex_core not running all fall
    -- through to the native path below rather than throwing.
    if GetResourceState('vex_core') == 'started' then
        local ok, coords = pcall(function()
            return exports['vex_core']:GetPlayerCoords(source)
        end)

        if ok and coords then
            local x = tonumber(coords.x)
            local y = tonumber(coords.y)
            local z = tonumber(coords.z)

            if x and y and z then
                return vector3(x, y, z)
            end
        end
    end

    -- Fallback: read the server's own tracked ped for this player directly.
    -- This is not a weaker guarantee than vex_core — it is the same
    -- authoritative source vex_core would ultimately be reading from, and a
    -- client cannot forge what the server independently resolves about its
    -- own player-owned ped (the same trust argument vex_zones' own
    -- getAuthoritativeCoords fallback relies on).
    local ped = GetPlayerPed(source)

    if not ped or ped == 0 then
        return nil
    end

    local ok, coords = pcall(GetEntityCoords, ped)

    if not ok or not coords then
        return nil
    end

    return vector3(coords.x, coords.y, coords.z)
end

local function distance3D(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z

    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Prefer the LIVE, server-tracked entity position over the registry's cached
-- `coords` field. The cache is only as fresh as the last migration report or
-- watchdog touch — bounded by Config.WatchdogActiveMs on the owning client
-- (500ms by default), so it can lag a fast-moving vehicle briefly. A
-- resolvable server-side entity handle (resolveServerEntity, Section 1)
-- reflects the network layer's own current synced position instead, and
-- costs nothing extra when it resolves cleanly. Falls back to the cache only
-- when no server-side handle is available at all.
local function resolveDeletionCheckCoords(netId, entry)
    local entity = resolveServerEntity(netId)

    if entity then
        local ok, coords = pcall(GetEntityCoords, entity)

        if ok and coords then
            return vector3(coords.x, coords.y, coords.z)
        end
    end

    return entry.coords
end

RegisterNetEvent('vex_entity:requestDelete', function(netId)
    local source = source
    netId = tonumber(netId)

    if not netId then
        return
    end

    local entry = VexEntityRegistry.Get(netId)

    if not entry then
        log(
            'warn',
            'Client %s requested deletion of unknown netId %s. Ignored.',
            tostring(source),
            tostring(netId)
        )

        return
    end

    local playerCoords = getAuthoritativePlayerCoords(source)

    if not playerCoords then
        log(
            'warn',
            'Client %s requested deletion of netId %s but no authoritative coordinates could be resolved for that player. Denied.',
            tostring(source),
            tostring(netId)
        )

        return
    end

    local targetCoords = resolveDeletionCheckCoords(netId, entry)
    local distance = distance3D(playerCoords, targetCoords)
    local baseDistance = Config.MaxClientDeleteDistance
    local tolerance = Config.NetworkPositionTolerance or 0
    local allowedDistance = baseDistance + tolerance

    if distance > allowedDistance then
        log(
            'warn',
            'Client %s DENIED deletion of netId %s: %.2f units away (max %.2f + %.2f tolerance = %.2f). Possible spoofed/injected request.',
            tostring(source),
            tostring(netId),
            distance,
            baseDistance,
            tolerance,
            allowedDistance
        )

        return
    end

    if Config.DebugSpawn and distance > baseDistance then
        log(
            'debug',
            'Client %s delete of netId %s allowed only via network tolerance: %.2f units away (base max %.2f).',
            tostring(source),
            tostring(netId),
            distance,
            baseDistance
        )
    end

    local success, reason = deleteEntitySafely(netId)

    if Config.DebugSpawn then
        log(
            'debug',
            'Client %s proximity-validated delete of netId %s -> success=%s reason=%s',
            tostring(source),
            tostring(netId),
            tostring(success),
            tostring(reason)
        )
    end
end)

-- ============================================================================
-- SECTION 6 — Ownership Migration Ingestion + Garbage Collection
-- ============================================================================

local function playerExists(source)
    source = tonumber(source)

    if not source or source <= 0 then
        return false
    end

    return GetPlayerName(source) ~= nil
end

local function sanitizeCoords(coords)
    if type(coords) ~= 'table' then
        return nil
    end

    local x = tonumber(coords.x)
    local y = tonumber(coords.y)
    local z = tonumber(coords.z)

    if not x or not y or not z then
        return nil
    end

    if x ~= x or y ~= y or z ~= z then
        return nil
    end

    return vector3(x, y, z)
end

-- ----------------------------------------------------------------------------
-- Ownership migration reports (Section 2 of the architecture)
-- ----------------------------------------------------------------------------

RegisterNetEvent('vex_entity:reportOwnership', function(
    netId,
    coords,
    heading
)
    local source = source
    netId = tonumber(netId)

    local entry = VexEntityRegistry.Get(netId)

    if not entry then
        return
    end

    -- A client may only claim itself as the current simulation owner — it
    -- never supplies an arbitrary owner source, since `source` here comes
    -- from the network event's own connection, not from the payload.
    local cleanCoords = sanitizeCoords(coords)
    local cleanHeading = tonumber(heading)

    VexEntityRegistry.SetOwner(
        netId,
        source,
        cleanCoords,
        cleanHeading
    )

    entry.orphanSince = nil

    VexEntityState.WriteOwner(netId)

    if Config.DebugOwnership then
        log(
            'debug',
            'Ownership migration netId=%s owner=%s',
            tostring(netId),
            tostring(source)
        )
    end
end)

RegisterNetEvent('vex_entity:touch', function(netId, coords, heading)
    local source = source
    netId = tonumber(netId)

    local entry = VexEntityRegistry.Get(netId)

    if not entry then
        return
    end

    -- Only the currently-recorded owner may refresh the authoritative
    -- registry cache through this path.
    if tonumber(entry.currentOwner) ~= tonumber(source) then
        return
    end

    VexEntityRegistry.Touch(
        netId,
        sanitizeCoords(coords),
        tonumber(heading)
    )
end)

-- ----------------------------------------------------------------------------
-- Disconnect session garbage collection
-- ----------------------------------------------------------------------------
--
-- O(k) via the EntitiesBySource index — never a scan of the whole registry.
-- Every non-persistent (deletionPool == true) entity the disconnecting
-- player spawned routes into PurgeEntity immediately. Persistent entities
-- survive per Config.PersistentDisconnectPolicy ("orphan" by default — the
-- architecture deliberately leaves reassignment policy unresolved); their
-- ownership is simply cleared if this player was also the current simulation
-- owner, and the low-frequency hygiene sweep below resolves anything the
-- disconnect handler can't decide synchronously.

AddEventHandler('playerDropped', function()
    local droppedSource = tonumber(source)

    if not droppedSource then
        return
    end

    local spawnedEntities = VexEntityRegistry.GetBySource(droppedSource)

    for i = 1, #spawnedEntities do
        local netId = spawnedEntities[i]
        local entry = VexEntityRegistry.Get(netId)

        if entry then
            if entry.deletionPool == true then
                PurgeEntity(netId, 'disconnect')
            else
                if tonumber(entry.currentOwner) == droppedSource then
                    entry.currentOwner = 0
                    entry.orphanSince = VexEntityRegistry.Now()
                    VexEntityState.WriteOwner(netId)
                end
            end
        end
    end

    -- An entity spawned by somebody else may nevertheless have been
    -- simulated by this player. Those entries are resolved by the
    -- low-frequency hygiene sweep below rather than an O(n) scan here.
end)

-- ----------------------------------------------------------------------------
-- Dependent-resource stop / vex_entity restart garbage collection
-- ----------------------------------------------------------------------------
--
-- The gap a player-disconnect handler alone doesn't cover: entities spawned
-- on behalf of a SCRIPT (a scripted event, an admin tool, a system spawn
-- with no player source at all) are orphaned forever if that owning
-- resource stops or restarts mid-session — nothing about a player
-- disconnecting is involved, so AddEventHandler('playerDropped', ...) above
-- never fires for this case. EntitiesByResource (Section 1), populated from
-- GetInvokingResource() captured at spawn time (Section 4), is what makes
-- this an O(k) sweep instead of a registry-wide scan, exactly mirroring the
-- disconnect handler's own EntitiesBySource lookup. Two distinct cases, the
-- same split vex_prompts/vex_zones already document for their own
-- equivalent stop-handlers:

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        -- vex_entity itself is stopping. Best-effort purge of every
        -- transient entity currently tracked — persistent entities are
        -- deliberately left alone; a resource restart must never delete a
        -- player-facing persistent asset out from under the world.
        --
        -- Candidates are collected before purging, never purged mid-pairs()
        -- traversal: PurgeEntity can yield (client-fallback confirmation
        -- polling), and Lua only guarantees safe mutation of the CURRENT
        -- key during a pairs() traversal, not safety against a *different*
        -- piece of code mutating the table during that yield. Same
        -- collect-then-purge discipline the sweep thread below already
        -- uses, applied here for the same reason.
        local candidates = {}

        for netId, entry in pairs(GlobalEntityRegistry) do
            if entry.deletionPool == true and not entry.pendingDeletion then
                candidates[#candidates + 1] = netId
            end
        end

        for i = 1, #candidates do
            PurgeEntity(candidates[i], 'resource_stop_self')
        end

        if Config.DebugGarbageCollector and #candidates > 0 then
            log(
                'debug',
                'vex_entity stopping: swept %s transient entities.',
                tostring(#candidates)
            )
        end

        return
    end

    local owned = VexEntityRegistry.GetByResource(resourceName)

    if #owned == 0 then
        return
    end

    for i = 1, #owned do
        local netId = owned[i]
        local entry = VexEntityRegistry.Get(netId)

        if entry and entry.deletionPool == true then
            PurgeEntity(netId, 'resource_stop')
        end

        -- Persistent entities survive a dependent resource's stop, same as
        -- they survive a spawning player's disconnect (Config.
        -- PersistentDisconnectPolicy) — invokingResource simply becomes
        -- historical metadata rather than triggering any reassignment.
    end

    if Config.DebugGarbageCollector then
        log(
            'debug',
            'Resource %s stopped: swept %s tracked transient entities.',
            resourceName,
            tostring(#owned)
        )
    end
end)

-- ----------------------------------------------------------------------------
-- Idle/stale sweep + orphan safeguard
-- ----------------------------------------------------------------------------
--
-- Single low-frequency CreateThread — no busy-poll, no per-tick cost. Wakes
-- every Config.SweepIntervalMs and performs two independent passes over the
-- registry: the normal transient stale sweep, and the orphan safeguard for
-- entries whose ownership cannot be resolved at all.

local function networkEntityExists(netId)
    if type(NetworkDoesEntityExistWithNetworkId) ~= 'function' then
        return true
    end

    local ok, exists = pcall(
        NetworkDoesEntityExistWithNetworkId,
        netId
    )

    if not ok then
        -- Fail safe: native uncertainty should never destroy a valid entity.
        return true
    end

    return exists == true
end

CreateThread(function()
    while true do
        Wait(Config.SweepIntervalMs)

        local currentTime = VexEntityRegistry.Now()
        local staleCandidates = {}
        local orphanCandidates = {}

        for netId, entry in pairs(GlobalEntityRegistry) do
            if not entry.pendingDeletion then
                -- ------------------------------------------------------------
                -- Normal stale sweep
                -- ------------------------------------------------------------

                if
                    entry.deletionPool == true
                    and (
                        currentTime - entry.lastSeen
                    ) >= Config.StaleThresholdMs
                then
                    staleCandidates[#staleCandidates + 1] = netId
                end

                -- ------------------------------------------------------------
                -- Orphan safeguard
                -- ------------------------------------------------------------

                local unresolved = false

                if not networkEntityExists(netId) then
                    unresolved = true
                elseif
                    tonumber(entry.currentOwner)
                    and tonumber(entry.currentOwner) > 0
                    and not playerExists(entry.currentOwner)
                then
                    unresolved = true
                end

                if unresolved then
                    entry.orphanSince = entry.orphanSince or currentTime

                    if
                        currentTime - entry.orphanSince
                        >= Config.OrphanThresholdMs
                    then
                        orphanCandidates[#orphanCandidates + 1] = netId
                    end
                else
                    entry.orphanSince = nil
                end
            end
        end

        -- Purge outside the registry traversal so index/registry mutation
        -- never invalidates the scan currently in progress.

        for i = 1, #orphanCandidates do
            local netId = orphanCandidates[i]

            log(
                'warn',
                'Orphan safeguard triggered for netId %s.',
                tostring(netId)
            )

            PurgeEntity(netId, 'orphan')
        end

        for i = 1, #staleCandidates do
            local netId = staleCandidates[i]

            -- It may already have been removed as an orphan above.
            local entry = VexEntityRegistry.Get(netId)

            if
                entry
                and entry.deletionPool
                and not entry.pendingDeletion
            then
                PurgeEntity(netId, 'sweep')
            end
        end

        if Config.DebugGarbageCollector then
            log(
                'debug',
                'GC sweep complete. tracked=%s stale=%s orphan=%s',
                tostring(VexEntityRegistry.Count()),
                tostring(#staleCandidates),
                tostring(#orphanCandidates)
            )
        end
    end
end)
