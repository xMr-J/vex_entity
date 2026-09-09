# vex_entity

`vex_entity` is a lightweight, server-authoritative entity lifecycle utility for RedM.

It handles secure networked entity spawning, ownership tracking, state bag synchronization, migration recovery, and automated cleanup.

## Dependencies

* `vex_core`
* `vex_callback`

## Features

* Secure server-authoritative spawning
* Entity ownership tracking
* State bag synchronization
* Safe entity deletion
* Ghost entity recovery
* Automatic garbage collection
* Model whitelist validation
* Persistent/transient entity support

## Core Exports

```lua
exports['vex_entity']:SpawnNetworkedEntity(...)
exports['vex_entity']:DeleteEntitySafely(netId)
exports['vex_entity']:SetEntityState(netId, key, value)
exports['vex_entity']:GetEntityRecord(netId)
exports['vex_entity']:GetEntitiesBySource(source)
exports['vex_entity']:SetEntityPersistence(netId, true)
```

Built for the VEX RedM ecosystem.
