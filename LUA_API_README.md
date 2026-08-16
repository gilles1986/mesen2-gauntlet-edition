# Mesen2 Lua API Extension: ROM Loading & Variable Persistence

This document describes the new API functions added to the Mesen2 Lua scripting engine: `emu.loadRom`, `emu.setPersist`, and `emu.getPersist`.

---

## 1. ROM Loading API

### `emu.loadRom(romPath, patchPath = "")`
Queues the emulator to unload the current game and load a different ROM file.

#### Parameters
* **`romPath`** *(string)*: The absolute filesystem path to the ROM file to be loaded (e.g. `"D:/roms/super_mario_bros.nes"`).
* **`patchPath`** *(string, optional)*: The absolute path to an IPS/BPS patch file to apply to the ROM upon loading. Defaults to an empty string (no patch).

#### Usage Example
```lua
-- Load a new ROM without a patch
emu.loadRom("D:/dev/roms/Castlevania.nes")

-- Load a new ROM and apply a patch
emu.loadRom("D:/dev/roms/Metroid.nes", "D:/dev/roms/Metroid_hack.ips")
```

#### ⚠️ Important Considerations
* **Deferred Execution (Non-Blocking)**: The ROM load **does not happen synchronously** in the middle of script execution. Instead, the request is queued. The actual ROM reload is executed safely at the end of the current emulation frame. This design prevents:
  * Emulation thread deadlocks (which would occur if a script attempted to join/stop the emulation thread it was running on).
  * Application crashes due to the Lua VM being destroyed while executing a synchronous reload.
* **Script Lifecycles**: Loading a new ROM reinitializes the core console and resets the debugger, which stops and unloads the current Lua script. To persist configuration, timers, or game state *across* this reload, you must use the persistence API described below.

---

## 2. Persistence API

Because loading a new ROM or restarting a script destroys the Lua scripting context, normal Lua global and local variables are lost. The persistence API allows you to store and retrieve basic values in static C++ memory that survives script lifecycles.

### `emu.setPersist(key, value)`
Stores a value in static memory under a given string key.

#### Parameters
* **`key`** *(string)*: The unique identifier for the stored value.
* **`value`** *(boolean | number | string | nil)*: The value to persist. Supported types are booleans, numbers (floats and integers), and strings. Passing `nil` or any unsupported type (e.g. tables, functions) deletes the key from persistence.

### `emu.getPersist(key)`
Retrieves a previously persisted value.

#### Parameters
* **`key`** *(string)*: The unique identifier of the value to retrieve.
#### Returns
* The persisted value (with its original type: `boolean`, `number`, or `string`), or `nil` if the key is not set.

#### Usage Example
```lua
-- 1. Retrieve value (defaulting to 0 if not yet set)
local runCount = emu.getPersist("myScript_runCount") or 0
emu.log("Script has been loaded " .. runCount .. " times.")

-- 2. Increment and save back
emu.setPersist("myScript_runCount", runCount + 1)

-- 3. Clear/delete the key when done
emu.setPersist("myScript_runCount", nil)
```

#### ⚠️ Important Considerations
* **Lifetime**: Persisted values reside in the static memory space of the native `MesenCore.dll`. Therefore, they will survive:
  * Reloading the current ROM.
  * Loading a completely different ROM.
  * Stopping and restarting the Lua script.
  * *Note: They do not persist across restarts of the Mesen.exe application itself.*
* **Type Constraints**: Only primitive types (`boolean`, `number`, `string`) are supported. Complex Lua structures (like tables or nested lists) cannot be persisted directly. If you need to persist a table, serialize it to a JSON string or a comma-separated string first, and parse it upon retrieval.
* **Namespace Safety**: Persisted keys are shared globally. To prevent collisions with other scripts, it is highly recommended to prefix your keys with a unique script name (e.g., `setPersist("myAwesomeScript_timer", 120)`).
