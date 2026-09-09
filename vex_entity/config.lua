Config = Config or {}

-- ============================================================================
-- General
-- ============================================================================

Config.Debug = false
Config.DebugStateBags = false
Config.DebugOwnership = false
Config.DebugGarbageCollector = false
Config.DebugSpawn = false

-- Reserved entity-state namespace.
-- Caller-owned gameplay state MUST NOT use this prefix.
Config.ReservedStatePrefix = 'vex:'

-- ============================================================================
-- Ownership watchdog
-- ============================================================================

-- Client watchdog delay when the client currently knows about no vex_entity
-- entities. Strict non-busy-poll yield: the watchdog thread fully suspends
-- for this long via Wait() (Wait is Citizen.Wait's global alias) rather than
-- evaluating ownership on every tick.
Config.WatchdogDormantMs = 1000

-- Client watchdog delay while one or more tracked entities are in awareness.
Config.WatchdogActiveMs = 500

-- An owner must remain suspicious for at least this long before the client
-- attempts recovery. This prevents one-frame migration flicker from causing
-- control fights.
Config.OwnershipDwellMs = 400

-- Maximum NetworkRequestControlOfEntity attempts made during one recovery
-- operation.
Config.ControlRequestMaxAttempts = 20

-- Delay between bounded control acquisition attempts.
-- Zero intentionally means one game frame.
Config.ControlRequestRetryMs = 0

-- Prevent repeated recovery operations against the same network entity from
-- being immediately restarted after an exhausted attempt.
Config.RecoveryCooldownMs = 1500

-- ============================================================================
-- Asset streaming / designated-client fallback
-- ============================================================================

-- Used only if a deployment requires a client-designated creation fallback.
Config.AssetStreamingMaxAttempts = 100

Config.AssetStreamingRetryMs = 50

-- Maximum time the server will keep an internal client fallback request alive.
Config.ClientOperationTimeoutMs = 10000

-- ============================================================================
-- Deletion security
-- ============================================================================

-- Maximum tolerated distance between a requesting client and an entity for
-- client-originated deletion operations.
--
-- Server resources invoking DeleteEntitySafely directly are not treated as
-- player proximity requests.
Config.MaxClientDeleteDistance = 25.0

-- Additional buffer added ON TOP of MaxClientDeleteDistance before a
-- client-originated deletion request is denied. This absorbs legitimate
-- network latency / position-sync jitter between the server's last-known
-- player position and that player's true position at the moment the request
-- arrives — a request is only ever denied once it exceeds
-- MaxClientDeleteDistance PLUS this tolerance, never on the base distance
-- alone. Keep this small: it is a jitter allowance, not a second proximity
-- radius.
Config.NetworkPositionTolerance = 3.0

-- Bounded confirmation timeout after issuing entity deletion.
Config.DeleteConfirmationTimeoutMs = 5000

Config.DeleteConfirmationPollMs = 100

-- ============================================================================
-- Garbage collection
-- ============================================================================

-- Main transient-entity GC sweep.
Config.SweepIntervalMs = 60000

-- A transient entity that has not been observed/reported for this duration is
-- eligible for the normal stale sweep.
Config.StaleThresholdMs = 300000

-- An unresolved network entity/owner is allowed to remain in an orphaned state
-- for this long before the orphan safeguard purges it.
Config.OrphanThresholdMs = 120000

-- Global number of entities managed by vex_entity.
Config.MaxPoolSize = 500

-- Optional per-type caps.
Config.MaxPoolByType = {
    ped = 200,
    vehicle = 150,
    object = 300
}

-- Persistent entities are NEVER automatically evicted to satisfy these caps.

-- ============================================================================
-- Spawn validation
-- ============================================================================

Config.ValidEntityTypes = {
    ped = true,
    vehicle = true,
    object = true
}

-- Exact playable-world limits were explicitly left unpinned in the blueprint.
-- Keep bounds validation opt-in until deployment-specific coordinates are
-- confirmed.
Config.WorldBounds = {
    enabled = false,

    min = {
        x = -10000.0,
        y = -10000.0,
        z = -1000.0
    },

    max = {
        x = 10000.0,
        y = 10000.0,
        z = 3000.0
    }
}

-- Optional spawn collision rejection.
--
-- Exact server-side collision-query native availability was not pinned by the
-- architecture. This therefore remains disabled until the deployment artifact
-- is verified.
Config.SpawnCollisionCheck = {
    enabled = false,
    radius = 1.5
}

-- ============================================================================
-- State bags
-- ============================================================================

Config.StateKeys = {
    netId = 'vex:netId',
    entityType = 'vex:entityType',
    modelHash = 'vex:modelHash',
    spawnedBy = 'vex:spawnedBy',
    currentOwner = 'vex:currentOwner',
    deletionPool = 'vex:deletionPool',
    persistent = 'vex:isPersistent',
    spawnTag = 'vex:spawnTag'
}

-- ============================================================================
-- Persistent-owner policy
-- ============================================================================

-- The architecture deliberately leaves reassignment of persistent entities
-- after spawnedBy disconnect unresolved.
--
-- "orphan" means retain the entity and leave spawnedBy as historical metadata.
Config.PersistentDisconnectPolicy = 'orphan'