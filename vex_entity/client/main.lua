-- ============================================================================
-- vex_entity — client/main.lua
-- ============================================================================
--
-- Consolidated client-side entity lifecycle module. Merges what were three
-- separate client scripts (bridge, state, watchdog) into one production
-- file and adds the two pieces the architecture left open:
--
--   1. Asynchronous Asset Streaming Helpers   (from client/bridge.lua)
--   2. Server Client-Operation Bridge          (from client/bridge.lua)
--   3. Local Gameplay State Export              (from client/state.lua)
--   4. Gameplay State Bag Broadcast [NEW]         (open-namespace interceptor)
--   5. Network Ownership Watchdog                  (from client/watchdog.lua)
--   6. Client Deletion Proxy [NEW]                   (player-facing delete path)
--
-- Section numbering intentionally does not match load order 1:1 — section 4
-- and 6 are placed next to the code they extend (state export, watchdog) so
-- the diff against the original three files stays easy to follow.
--
-- Never uses FiveM/GTA V–only references. Every native here
-- (RequestModel, HasModelLoaded, NetworkRequestControlOfEntity,
-- NetworkHasControlOfEntity, NetworkGetEntityOwner, NetToEnt, DoesEntityExist,
-- GetEntityCoords, GetEntityHeading, IsEntityAttached, DetachEntity,
-- AddStateBagChangeHandler, GetEntityFromStateBagName) is a shared CitizenFX
-- framework native that behaves identically on RDR3.

local function now()
    return GetGameTimer()
end

-- ============================================================================
-- SECTION 1 — Asynchronous Asset Streaming Helpers
-- ============================================================================
--
-- Non-blocking in the CitizenFX cooperative-thread sense: every wait yields
-- via Wait(), never spins, and is bounded by Config.AssetStreamingMaxAttempts
-- so an invalid/unstreamable model hash can never stall the calling thread
-- forever. Exposed on VexEntityClient so any section of this file — or a
-- future client-designated creation fallback once nearest-client arbitration
-- is decided — can reuse the exact same bounded loader rather than each
-- hand-rolling its own timeout.

VexEntityClient = VexEntityClient or {}

local function loadModel(modelHash)
    if HasModelLoaded(modelHash) then
        return true
    end

    RequestModel(modelHash)

    local attempts = 0

    while
        attempts < Config.AssetStreamingMaxAttempts
        and not HasModelLoaded(modelHash)
    do
        attempts = attempts + 1
        RequestModel(modelHash)
        Wait(Config.AssetStreamingRetryMs)
    end

    return HasModelLoaded(modelHash)
end

VexEntityClient.LoadModel = loadModel

-- ============================================================================
-- SECTION 2 — Server Client-Operation Bridge
-- ============================================================================
--
-- Server-designated fallback path only. The server reaches this when it
-- cannot complete an operation with a direct server-side native (Section 1
-- of server/main.lua's PurgeEntity) and instead asks a specific, already-
-- resolved client (the entity's current owner) to perform it locally. This
-- is never triggered directly by player input — Section 6 below is the
-- player-facing path, and it goes through the server's proximity gate
-- first, landing back here only if the server itself decides a client must
-- execute the deletion.

local function reply(requestId, success, payload)
    TriggerServerEvent(
        'vex_entity:clientOperationResult',
        requestId,
        success == true,
        payload
    )
end

local function clientDelete(payload)
    local netId = tonumber(payload and payload.netId)

    if not netId then
        return false, 'invalid_net_id'
    end

    local entity = NetToEnt(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return true, 'already_absent'
    end

    -- Detach before delete — see Section 6's DetachLooseAttachments note.
    -- Applied here too since a server-designated delete can target an
    -- entity this client never itself requested.
    if IsEntityAttached(entity) then
        DetachEntity(entity, true, true)
    end

    local attempts = 0

    while
        attempts < Config.ControlRequestMaxAttempts
        and not NetworkHasControlOfEntity(entity)
    do
        NetworkRequestControlOfEntity(entity)

        attempts = attempts + 1

        Wait(Config.ControlRequestRetryMs)
    end

    if not NetworkHasControlOfEntity(entity) then
        return false, 'control_request_exhausted'
    end

    DeleteEntity(entity)

    return not DoesEntityExist(entity),
        DoesEntityExist(entity)
            and 'delete_failed'
            or 'deleted'
end

local function clientCreate(_payload)
    -- Intentionally fail-closed until the deployment chooses a nearest-
    -- client arbitration policy and pins exact RDR3 creation-native
    -- signatures — the architecture's own open item, not an oversight here.
    -- VexEntityClient.LoadModel (Section 1) is already the bounded loader
    -- this path will call into once that policy is decided.
    return false, 'client_creation_fallback_not_configured'
end

RegisterNetEvent('vex_entity:clientOperation', function(
    requestId,
    operation,
    payload
)
    if type(requestId) ~= 'string' then
        return
    end

    if operation == 'delete' then
        local success, result = clientDelete(payload)
        reply(requestId, success, result)
        return
    end

    if operation == 'create' then
        local success, result = clientCreate(payload)
        reply(requestId, success, result)
        return
    end

    reply(requestId, false, 'unknown_operation')
end)

-- ============================================================================
-- SECTION 3 — Local Gameplay State Export
-- ============================================================================
--
-- The client-side half of the open gameplay namespace (server/main.lua
-- Section 2 is the server-side half). Reserved vex:* keys are refused
-- before the bag is ever touched — this module never lets a caller,
-- local or remote, write vex_entity's own bookkeeping fields.

local function isReservedKey(key)
    return type(key) == 'string'
        and key:sub(1, #Config.ReservedStatePrefix)
            == Config.ReservedStatePrefix
end

local function setEntityState(netId, key, value)
    netId = tonumber(netId)

    if not netId then
        return false, 'invalid_net_id'
    end

    if type(key) ~= 'string' or key == '' then
        return false, 'invalid_key'
    end

    if isReservedKey(key) then
        return false, 'reserved_state_namespace'
    end

    local entity = NetToEnt(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return false, 'entity_not_found'
    end

    local success = pcall(function()
        Entity(entity).state:set(key, value, true)
    end)

    if not success then
        return false, 'state_write_failed'
    end

    return true
end

exports('SetEntityState', setEntityState)

-- ============================================================================
-- SECTION 4 — Gameplay State Bag Broadcast  [NEW]
-- ============================================================================
--
-- vex_entity owns REPLICATION, not the MEANING of a caller's own gameplay
-- data (same "thin passthrough" restraint the architecture applies to
-- SetEntityState above) — so this module does not itself know what "locked"
-- or "damage" mean, doesn't touch a door prop or a damage decal, and never
-- will. What it provides instead: state bags already replicate a value to
-- every client in scope with zero manual net events, and this section turns
-- that replication into ONE convenient local Lua event other client
-- resources can subscribe to, instead of every gameplay script writing and
-- filtering its own global AddStateBagChangeHandler by hand.
--
-- A gameplay script reacts like this, entirely on its own side:
--
--   AddEventHandler('vex_entity:stateChanged', function(netId, entity, key, value)
--       if key == 'locked' then
--           -- e.g. play a wagon-trunk lock/unlock prop animation
--       end
--   end)
--
-- Reserved vex:* keys are excluded here on purpose — they are internal
-- bookkeeping already covered by Section 5's awareness tracking and by the
-- server-side reserved-namespace audit; re-broadcasting them as gameplay
-- events would just be noise for every subscriber.

local function isVexManagedEntity(entity)
    local ok, netId = pcall(function()
        return Entity(entity).state[Config.StateKeys.netId]
    end)

    if not ok then
        return nil
    end

    return tonumber(netId)
end

if type(AddStateBagChangeHandler) == 'function' then
    AddStateBagChangeHandler(nil, nil, function(
        bagName,
        key,
        value,
        _reservedArg,
        replicated
    )
        if isReservedKey(key) then
            return
        end

        if replicated ~= true then
            return
        end

        if type(GetEntityFromStateBagName) ~= 'function' then
            return
        end

        local ok, entity = pcall(GetEntityFromStateBagName, bagName)

        if not ok or not entity or entity == 0 then
            return
        end

        if not DoesEntityExist(entity) then
            return
        end

        local netId = isVexManagedEntity(entity)

        if not netId then
            -- Not a vex_entity-managed entity (e.g. a ped/prop belonging to
            -- some other system's own state-bag usage) — not this module's
            -- concern to broadcast.
            return
        end

        TriggerEvent('vex_entity:stateChanged', netId, entity, key, value)
    end)
end

-- ============================================================================
-- SECTION 5 — Network Ownership Watchdog
-- ============================================================================
--
-- Single adaptive thread, dormant/active wait alternation — never a per-tick
-- busy poll. Watches only the local "awareness set" (entities this client
-- either owns or has been told about via the vex:netId state key below),
-- never the whole server. Three "owner looks wrong" cases are kept distinct:
-- a genuine crash/disconnect, a walked-out-of-scope-but-alive owner, and
-- single-frame migration flicker — the last absorbed by
-- Config.OwnershipDwellMs so control fights never start over noise.

local TrackedEntities = {}

local function getNetIdFromBagName(bagName)
    if type(GetEntityFromStateBagName) ~= 'function' then
        return nil
    end

    local ok, entity = pcall(GetEntityFromStateBagName, bagName)

    if not ok or not entity or entity == 0 then
        return nil
    end

    if not DoesEntityExist(entity) then
        return nil
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)

    if not netId or netId == 0 then
        return nil
    end

    return netId
end

local function trackEntity(netId)
    TrackedEntities[netId] = TrackedEntities[netId] or {
        netId = netId,

        lastOwner = nil,
        invalidSince = nil,

        recoveryInFlight = false,
        recoveryCooldownUntil = 0
    }
end

local function untrackEntity(netId)
    TrackedEntities[netId] = nil
end

-- Awareness-set population through vex_entity's own reserved netId key —
-- this fires once per entity as its vex:netId bag key is set/cleared,
-- independent of Section 4's broader (and reserved-key-excluding) broadcast.
if type(AddStateBagChangeHandler) == 'function' then
    AddStateBagChangeHandler(
        Config.StateKeys.netId,
        nil,
        function(bagName, _key, value)
            local netId = tonumber(value)

            if netId then
                trackEntity(netId)
                return
            end

            local oldNetId = getNetIdFromBagName(bagName)

            if oldNetId then
                untrackEntity(oldNetId)
            end
        end
    )
end

local function getLocalAwarenessSet()
    local awareness = {}

    for netId, entry in pairs(TrackedEntities) do
        local entity = NetToEnt(netId)

        if entity and entity ~= 0 and DoesEntityExist(entity) then
            awareness[#awareness + 1] = {
                entity = entity,
                entry = entry
            }
        else
            TrackedEntities[netId] = nil
        end
    end

    return awareness
end

local function isNetworkPlayerValid(owner)
    if owner == nil or owner < 0 then
        return false
    end

    if owner == PlayerId() then
        return true
    end

    return NetworkIsPlayerActive(owner)
end

local function reportOwnershipMigration(netId, entity)
    local coords = GetEntityCoords(entity)
    local heading = GetEntityHeading(entity)

    TriggerServerEvent(
        'vex_entity:reportOwnership',
        netId,
        {
            x = coords.x,
            y = coords.y,
            z = coords.z
        },
        heading
    )
end

local function touchOwnedEntity(netId, entity)
    local coords = GetEntityCoords(entity)
    local heading = GetEntityHeading(entity)

    TriggerServerEvent(
        'vex_entity:touch',
        netId,
        {
            x = coords.x,
            y = coords.y,
            z = coords.z
        },
        heading
    )
end

local function attemptGhostRecovery(entity, entry)
    if entry.recoveryInFlight then
        return
    end

    if now() < entry.recoveryCooldownUntil then
        return
    end

    entry.recoveryInFlight = true

    CreateThread(function()
        local attempts = 0

        while
            attempts < Config.ControlRequestMaxAttempts
            and DoesEntityExist(entity)
            and not NetworkHasControlOfEntity(entity)
        do
            NetworkRequestControlOfEntity(entity)

            attempts = attempts + 1

            Wait(Config.ControlRequestRetryMs)
        end

        local acquired =
            DoesEntityExist(entity)
            and NetworkHasControlOfEntity(entity)

        entry.recoveryInFlight = false
        entry.recoveryCooldownUntil = now() + Config.RecoveryCooldownMs

        if acquired then
            entry.invalidSince = nil
            entry.lastOwner = PlayerId()

            reportOwnershipMigration(entry.netId, entity)

            if Config.DebugOwnership then
                print((
                    '[vex_entity] Recovered ownership netId=%s attempts=%s'
                ):format(
                    tostring(entry.netId),
                    tostring(attempts)
                ))
            end
        end
    end)
end

local function evaluateOwner(entity, entry)
    local owner = NetworkGetEntityOwner(entity)

    if entry.lastOwner ~= owner then
        entry.lastOwner = owner
        entry.invalidSince = nil

        if owner == PlayerId() then
            reportOwnershipMigration(entry.netId, entity)
        end
    end

    if isNetworkPlayerValid(owner) then
        entry.invalidSince = nil

        if owner == PlayerId() then
            touchOwnedEntity(entry.netId, entity)
        end

        return
    end

    if not entry.invalidSince then
        entry.invalidSince = now()
        return
    end

    if now() - entry.invalidSince < Config.OwnershipDwellMs then
        return
    end

    attemptGhostRecovery(entity, entry)
end

CreateThread(function()
    while true do
        local awareness = getLocalAwarenessSet()

        if #awareness == 0 then
            Wait(Config.WatchdogDormantMs)
        else
            for i = 1, #awareness do
                local candidate = awareness[i]

                evaluateOwner(candidate.entity, candidate.entry)
            end

            Wait(Config.WatchdogActiveMs)
        end
    end
end)

-- ============================================================================
-- SECTION 6 — Client Deletion Proxy  [NEW]
-- ============================================================================
--
-- The player-facing counterpart to server/main.lua's proximity-gated
-- 'vex_entity:requestDelete' event. A gameplay resource never calls
-- DeleteEntity itself and never needs to know the server-authoritative
-- deletion flow exists at all — it calls this one export, and everything
-- past that point (proximity validation against server-resolved coordinates,
-- direct server-side deletion, or the Section 2 client-operation fallback)
-- is entirely the server's decision.
--
-- Two local safety steps happen before anything is sent to the server:
--
--   1. A fast local no-op: if the entity is already gone client-side, this
--      returns immediately without spending a network round trip.
--   2. Attachment detachment: DetachEntity is called first if the target is
--      currently attached to anything. Deleting an attached entity without
--      detaching it first is exactly how a physics handle gets orphaned —
--      the attachment relationship can outlive the deleted entity on other
--      clients for a frame or more, which is the "orphaned physics handle"
--      failure mode this section exists to prevent. This client only ever
--      detaches the entity from what it's attached TO, never reaches into
--      the game's entity pool to hunt for children attached to it — that
--      would require an unbounded pool scan this module has no reason to
--      perform.

local function detachLooseAttachments(entity)
    if not IsEntityAttached(entity) then
        return
    end

    DetachEntity(entity, true, true)
end

local function requestEntityDeletion(netId)
    netId = tonumber(netId)

    if not netId then
        return false, 'invalid_net_id'
    end

    local entity = NetToEnt(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        -- Nothing here to clean up locally; the server-side registry sweep
        -- (orphan safeguard) is what reconciles a stale ledger entry, not
        -- this client guessing at server state.
        return true, 'already_absent_locally'
    end

    detachLooseAttachments(entity)

    TriggerServerEvent('vex_entity:requestDelete', netId)

    return true, 'requested'
end

exports('RequestEntityDeletion', requestEntityDeletion)
