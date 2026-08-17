--==================================================================
--  make_state.lua  -  Relay-Savestate erzeugen (Mesen Special)
--------------------------------------------------------------------
--  Schreibt den AKTUELLEN Zustand als Savestate nach <rom-ordner>/states/.
--  Anker ist der Ordner der GELADENEN ROM (Mesen gibt den Skript-Pfad nicht
--  zuverlaessig an Lua weiter, den ROM-Pfad aber schon). Dateiname automatisch
--  aus der ROM (mehrere Stages -> _2, _3, ...).
--
--  createSavestate darf nur in einem exec-Memory-Callback laufen -> das Skript
--  wartet auf die naechste CPU-Instruktion und speichert dort.
--
--  Benutzung (Veranstalter):
--    1) "Allow access to I/O and OS functions" aktivieren
--    2) ins Level / an den Startpunkt spielen
--    3) Skript ausfuehren -> Log zeigt den erzeugten Dateinamen
--==================================================================

-- Optional: fester Dateiname (ohne Endung). Leer = automatisch aus ROM-Name.
local NAME = ""

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end; return false
end

local function pickOut()
  local info = emu.getRomInfo() or {}
  emu.log("make_state: romPath = " .. tostring(info.path))
  local dir  = (info.path and info.path:match("(.*[/\\])")) or "D:/Games/SNES/"
  local sdir = dir .. "states/"
  local base
  if NAME ~= "" then
    base = NAME
  else
    base = (info.path or info.name or "state"):match("([^/\\]+)$") or "state"
    base = base:gsub("%.%w+$", "")              -- Endung weg
  end
  local out = sdir .. base .. ".state"
  local i = 2
  while exists(out) do out = sdir .. base .. "_" .. i .. ".state"; i = i + 1 end
  return out
end

local EXEC_S, EXEC_E, CPU = 0x000000, 0xFFFFFF, emu.cpuType.snes

local ref
ref = emu.addMemoryCallback(function()
  emu.removeMemoryCallback(ref, emu.callbackType.exec, EXEC_S, EXEC_E, CPU)  -- nur einmal
  local out  = pickOut()
  local data = emu.createSavestate()            -- hier erlaubt (exec-Callback)
  local f = io.open(out, "wb")
  if not f then                                 -- states/-Ordner fehlt? -> anlegen + nochmal
    local d = out:gsub("[^/\\]+$", ""):gsub("[/\\]+$", ""):gsub("/", "\\")
    pcall(os.execute, 'mkdir "' .. d .. '"')
    f = io.open(out, "wb")
  end
  if f then
    f:write(data); f:close()
    emu.log(string.format("Savestate geschrieben (%d Bytes): %s", #data, out))
    emu.displayMessage("Relay", "State -> " .. (out:match("([^/\\]+)$") or out))
  else
    emu.log("FEHLER beim Schreiben: " .. out)
    emu.log("Tipp: states/-Ordner manuell anlegen + I/O/OS-Zugriff aktiv?")
  end
end, emu.callbackType.exec, EXEC_S, EXEC_E, CPU)

emu.log("make_state: warte auf naechste CPU-Instruktion zum Speichern ...")
