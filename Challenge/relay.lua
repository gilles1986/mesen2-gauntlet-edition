--==================================================================
--  Game Relay - Mesen "Special" (custom build mit emu.loadRom + persist)
--------------------------------------------------------------------
--  Multi-Game-Relay in EINEM Lua-Skript: schaltet ROMs via emu.loadRom,
--  und traegt den Fortschritt via emu.setPersist/getPersist ueber die
--  durch den ROM-Wechsel ausgeloesten Skript-Neustarts hinweg.
--
--  Savestate-Funktionen (createSavestate/loadSavestate) duerfen nur in
--  einem exec-Memory-Callback laufen -> dafuer der runInExec()-Helfer.
--
--  >> Beim ERSTEN Lauf im Script-Log pruefen:
--     (1) nach dem ROM-Wechsel erscheint "Relay-Instanz: Segment 2/.."
--         (= Skript-Neustart nach loadRom greift, das Herzstueck)
--     (2) "loadSavestate -> OK" (= Level-Drop-in klappt)
--==================================================================

------------------------------- CONFIG -------------------------------
-- Ermittelt den Pfad zum Skript-Verzeichnis.
local function getScriptDir()
  -- Wenn die Engine eingebettet ueber den ChallengeManager geladen wurde, wird das
  -- Challenge-Verzeichnis als globale Variable __CHALLENGE_DIR injiziert (es liegt
  -- dann keine relay.lua-Datei auf der Platte, die hier gefunden werden koennte).
  if type(__CHALLENGE_DIR) == "string" and #__CHALLENGE_DIR > 0 then
    local d = __CHALLENGE_DIR:gsub("\\", "/")
    if not d:match("/$") then d = d .. "/" end
    return d
  end

  -- Finde den Dateinamen dieses Skripts (z. B. "relay.lua")
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local scriptName = source:match("([^/\\]+)$") or "relay.lua"

  -- Durchsuche package.path nach dem Pfad, in dem das Skript liegt
  for path in string.gmatch(package.path, "[^;]+") do
    local dir = path:match("(.*)[/\\]%?%.lua$") or path:match("(.*)[/\\]%?[/\\]init%.lua$")
    if dir then
      dir = dir:gsub("\\", "/")
      if not dir:match("/$") then dir = dir .. "/" end
      -- Prüfen, ob die Skriptdatei in diesem Verzeichnis existiert
      local f = io.open(dir .. scriptName, "r")
      if f then
        f:close()
        return dir
      end
    end
  end

  -- Fallback, falls die Suche fehlschlägt
  return "./"
end

local SCRIPT_DIR = getScriptDir()
local GAMES = SCRIPT_DIR .. "games/"

-- *** FILE-BASED DIAGNOSTIC LOG (challenge mode blocks emu.log UI) ***
local DIAG_PATH = SCRIPT_DIR .. "recordings/diag.txt"
local function flog(msg)
  local f = io.open(DIAG_PATH, "a")
  if f then
    f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
    f:close()
  end
end

-- Log script startup
do
  local raw_seg = emu.getPersist("relay_seg")
  local romInfo = emu.getRomInfo() or {}
  flog("=== SCRIPT RESTART ===")
  flog("relay_seg=" .. tostring(raw_seg))
  flog("romInfo.path=" .. tostring(romInfo.path))
  flog("inputDisplay=" .. tostring(__INPUT_DISPLAY) .. " pos=" .. tostring(__INPUT_DISPLAY_POS))
end


-- Konfiguration aus games.lua laden
local challengeConfig = dofile(SCRIPT_DIR .. "games.lua")
local CHALLENGE = challengeConfig.challenge or "Kaizo Challenge #1"
local segments = challengeConfig.segments
-- Reset-Combo: der User kann sie in den Challenge-Settings ueberschreiben (__RESET_BUTTONS,
-- z. B. "l,r" oder "select"). Ist nichts injiziert, gilt die challenge-eigene resetCombo bzw.
-- der Default. Die Buttons sind emu.getInput()-Keys (a,b,x,y,l,r,select,start,up,down,left,right).
local function parseResetButtons(s)
  local t = {}
  for b in s:gmatch("[^,]+") do
    b = b:match("^%s*(.-)%s*$")
    if #b > 0 then t[#t + 1] = b end
  end
  return t
end
local RESET_COMBO = (type(__RESET_BUTTONS) == "string" and #__RESET_BUTTONS > 0)
  and parseResetButtons(__RESET_BUTTONS)
  or (challengeConfig.resetCombo or { "select", "down" })
-- Hold-Dauer bis zum Reset: per Setting entweder Tippen (1 Frame) oder klassisch ~0,5 s (30).
local RESET_HOLD_FRAMES = (type(__RESET_HOLD_FRAMES) == "number" and __RESET_HOLD_FRAMES >= 1)
  and math.floor(__RESET_HOLD_FRAMES) or 30

-- Stabile Challenge-ID fuer die Bestenliste (siehe Challenge/LEADERBOARD_API.md).
-- Bevorzugt das explizite "id"-Feld aus games.lua; sonst wird ein Slug aus dem
-- Anzeigenamen abgeleitet.
local function slugify(s)
  s = tostring(s or ""):lower()
  s = s:gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if #s == 0 then s = "challenge" end
  return s
end
local CHALLENGE_ID = challengeConfig.id or slugify(CHALLENGE)

-- ACHTUNG, HARTE GRENZE: Lua erlaubt maximal 200 local-Variablen pro Funktion, und dieser
-- Hauptchunk IST eine Funktion. Er liegt bei ~199. Eine einzige weitere Top-Level-Deklaration
-- laesst die Engine nicht mehr kompilieren - und zwar STILL: die ROM laedt, das HUD bleibt weg,
-- selbst diag.txt wird nicht geschrieben (der Fehler passiert vor der ersten Zeile). Wer hier
-- etwas braucht, liest die injizierte Variable direkt als GLOBAL (kostet keinen local-Slot),
-- so wie __EMU_VERSION / __ENGINE_VERSION unten in den Aufnahme-Koepfen.

-- Forward declarations for scope sharing
local PRACTICE = false
local segIdx = 1
local phase = "init"
local getP, setP

-- ==========================================
-- AP14 REPLAY MODE & RECORD SYSTEM
-- ==========================================
local REPLAY = __REPLAY_DIR ~= nil
-- Name des Spielers, dessen Lauf abgespielt wird (vom ChallengeManager aus dem Replay-Header
-- injiziert). Nur zur Anzeige im Replay-HUD.
local REPLAY_PLAYER = (type(__REPLAY_PLAYER) == "string" and #__REPLAY_PLAYER > 0) and __REPLAY_PLAYER or nil
local BLANK_INPUT = {
  up = false, down = false, left = false, right = false,
  a = false, b = false, x = false, y = false,
  l = false, r = false, select = false, start = false
}

local SPIKE_FILE = ""
local spikeMode = "record" -- "record" or "replay"
local spikeInputs = {}          -- Replay: gepackter Input-Wert pro Poll (aus RLE expandiert)
local spikePollCounter = 0
local replayInput = {}          -- wiederverwendete Tabelle fuers setInput im Replay (kein Pro-Frame-Alloc)

local btnKeys = {"up", "down", "left", "right", "a", "b", "x", "y", "l", "r", "select", "start"}
local btnChars = {
  up="u", down="d", left="l", right="r",
  a="A", b="B", x="X", y="Y",
  l="L", r="R", select="s", start="S"
}

-- 12 Buttons <-> gepackte Ganzzahl (Bit i = btnKeys[i]). Bewusst arithmetisch (kein <<),
-- damit es unabhaengig von der Lua-Version funktioniert; v bleibt eine Ganzzahl.
local function packInput(input)
  local v, bit = 0, 1
  for i = 1, #btnKeys do
    if input[btnKeys[i]] then v = v + bit end
    bit = bit * 2
  end
  return v
end
-- Schreibt die 12 Buttons aus einer gepackten Ganzzahl in eine (wiederverwendbare) Tabelle.
local function unpackInto(tbl, v)
  local bit = 1
  for i = 1, #btnKeys do
    tbl[btnKeys[i]] = math.floor(v / bit) % 2 == 1
    bit = bit * 2
  end
  return tbl
end

-- ---- Aufnahme: RLE ueber gepackte Werte -------------------------------------------
-- Statt pro Frame eine rohe Input-Tabelle zu halten (~550 B/Frame, GC-Last bei langen
-- Segmenten), wird ein gepackter 12-Bit-Wert pro Frame RLE-kodiert: nur bei Input-Wechsel
-- entsteht ein neuer Lauf. Zahlen liegen inline in den Arrays -> praktisch kein Pro-Frame-Alloc.
local recVals = {}     -- Lauf-Werte (gepackt)
local recRuns = {}     -- Lauf-Laengen
local recCurVal = nil  -- laufender Lauf
local recCurRun = 0
local recTotalPolls = 0
local function recordReset()
  recVals = {}; recRuns = {}
  recCurVal = nil; recCurRun = 0
  recTotalPolls = 0
end
local function recordPush(v)
  recTotalPolls = recTotalPolls + 1
  if v == recCurVal then
    recCurRun = recCurRun + 1
  else
    if recCurVal ~= nil then
      recVals[#recVals + 1] = recCurVal
      recRuns[#recRuns + 1] = recCurRun
    end
    recCurVal = v
    recCurRun = 1
  end
end
local function recordFlush()
  if recCurVal ~= nil then
    recVals[#recVals + 1] = recCurVal
    recRuns[#recRuns + 1] = recCurRun
    recCurVal = nil
    recCurRun = 0
  end
end

local function deserializeInput(s)
  local input = {}
  for i, k in ipairs(btnKeys) do
    local char = btnChars[k]
    input[k] = (s:sub(i, i) == char)
  end
  return input
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- Laedt die Aufnahme in spikeInputs als GEPACKTE Werte (ein Eintrag pro Poll). Versteht das
-- aktuelle RLE-Format (GINP2, Zeilen "<hex3>*<count>") und das alte Zeilen-Format (GINP1, ein
-- 12-Zeichen-String pro Poll), damit vor der Umstellung erzeugte Replays weiter laufen.
local function loadReplayInputs(path)
  spikeInputs = {}
  local f = io.open(path, "r")
  if not f then return end
  local inHeader = true
  for line in f:lines() do
    if inHeader then
      if line == "" or line:match("^%s*$") then
        inHeader = false
      end
    else
      local hexv, cnt = line:match("^(%x%x%x)%*(%d+)$")
      if hexv then                                   -- GINP2: gepackter Wert + Lauflaenge
        local v = tonumber(hexv, 16)
        for _ = 1, tonumber(cnt) do
          spikeInputs[#spikeInputs + 1] = v
        end
      elseif #line >= 12 then                        -- GINP1 (legacy): 12-Zeichen-String
        spikeInputs[#spikeInputs + 1] = packInput(deserializeInput(line))
      end
    end
  end
  f:close()
end

-- ---- Replay-Navigation (L = Segment zurueck, R = Segment vor) ----------------------
-- Zustand UND Helfer liegen bewusst in EINER Tabelle: relay.lua liegt nah am Lua-Limit von
-- 200 file-scope-Locals (siehe Kommentar am stream-Modul), so kostet die ganze Navigation
-- nur ein einziges Local. Gefuellt wird l/r/combo im inputPolled-Callback aus dem PHYSISCHEN
-- Controller (im Replay ersetzt die Aufnahme den Input danach), ausgewertet wird es in onFrame.
--   dir     = vorgemerkte Richtung (-1/1), wird beim Loslassen ausgefuehrt
--   blocked = fuer diesen Tastendruck abgeblockt (beide Schultertasten = Reset-Combo)
local nav = { l = false, r = false, combo = false, dir = 0, blocked = false }

-- Segmentlaenge aus dem Kopf einer Aufnahme. "frames=" ist die echte Segmentzeit; aeltere
-- Replays (vor dieser Zeile) fallen auf "polls=" zurueck - bei einem Input-Poll pro Frame ist
-- das dieselbe Zahl, bei mehrfach pollenden Spielen nur eine Naeherung fuer die Anzeige.
nav.frames = function(idx)
  if not REPLAY then return nil end
  local f = io.open(__REPLAY_DIR .. "seg" .. math.floor(idx) .. ".inputs", "r")
  if not f then return nil end
  local frames, polls
  for line in f:lines() do
    if line == "" or line:match("^%s*$") then break end   -- Leerzeile = Ende des Kopfes
    frames = tonumber(line:match("^frames=(%d+)")) or frames
    polls  = tonumber(line:match("^polls=(%d+)")) or polls
  end
  f:close()
  return frames or polls
end

-- Schreibt die RLE-Aufnahme (GINP2). Der laufende Lauf wird zuvor abgeschlossen.
-- frames = Segmentzeit in Frames; steht im Kopf, damit die Replay-Navigation (L/R) beim
-- Springen die Gesamtzeit/Splits der uebersprungenen Segmente rekonstruieren kann.
local function saveRecordedInputs(path, frames)
  recordFlush()
  local f = io.open(path, "w")
  if f then
    f:write("GINP2\n")
    f:write("challenge=" .. CHALLENGE_ID .. "\n")
    f:write("segment=" .. math.floor(segIdx) .. "\n")
    f:write("player=" .. getP("name", PLAYER) .. "\n")
    f:write("polls=" .. recTotalPolls .. "\n")
    f:write("frames=" .. math.floor(frames or 0) .. "\n")
    -- Versionsstempel: welcher Emulator-Kern und welche Engine diesen Lauf erzeugt haben. Nur
    -- geschrieben, nicht geprueft. Direkt als Global gelesen, NICHT in ein local gehoben - der
    -- Chunk ist am 200-local-Limit (siehe Kasten oben).
    f:write("emu=" .. ((type(__EMU_VERSION) == "string" and __EMU_VERSION) or "") .. "\n")
    f:write("engine=" .. ((type(__ENGINE_VERSION) == "string" and __ENGINE_VERSION) or "") .. "\n")
    f:write("\n") -- Empty line separating header from data
    for i = 1, #recVals do
      f:write(string.format("%03X*%d\n", recVals[i], recRuns[i]))
    end
    f:close()
  end
end

-- ==========================================
-- LIVE-GHOST (Positions-Log) — AP10
-- ==========================================
-- Optionaler halbtransparenter PB-Ghost. Aufgezeichnet wird die WELT-Position pro Play-Frame
-- (+ Room-ID); gezeichnet wird sie relativ zur LIVE-Kamera. Dadurch stimmt der Ghost auch bei
-- Tempo-Unterschied: bist du schneller, scrollt der Ghost (kleineres Welt-X) hinten aus dem Bild.
-- SMW-Defaults; pro Segment via seg.ghost ueberschreibbar (retro-Games). Persistenter PB-Ghost:
-- recordings/pb_seg<idx>.ghost. Room-Matching ist grob (Translevel) und kann per seg.ghost.room
-- (Adresse) verfeinert oder mit room=false abgeschaltet werden.
local GHOST_MODE = (type(__GHOST) == "string" and __GHOST) or "pb"   -- "pb" | "off"
-- Foreign-ghost race ("Race a Ghost from File..."): the C# side extracts the shared .creplay
-- and injects __GHOST_DIR. When set, the ghost is loaded from <GHOST_DIR>/seg<idx>.ghost (a
-- friend's run) instead of the local recordings/pb_seg<idx>.ghost, and is always shown. The
-- ghost's player name is read from the file header, so it labels itself with the friend's name.
local GHOST_DIR = (type(__GHOST_DIR) == "string" and #__GHOST_DIR > 0) and __GHOST_DIR or nil
local GHOST_SHOW = (GHOST_MODE ~= "off" or GHOST_DIR ~= nil) and (not REPLAY)
-- Ghost tint (user-selectable in Challenge Settings): C# injects the RGB (0..0xFFFFFF) that
-- applies to the active ghost (own PB vs. foreign race ghost). The engine owns the transparency
-- so the ghost always stays "ghostly": a faint fill, a stronger border, an opaque name label.
-- ARGB is composed by arithmetic (alpha*0x1000000 + rgb) to avoid depending on Lua bit ops.
local GHOST_RGB = (type(__GHOST_COLOR) == "number") and (math.floor(__GHOST_COLOR) % 0x1000000) or 0xFFFFFF
-- Opacity (0..100, user-selectable): 100 = voll sichtbar, niedrig = blass. WICHTIG: Mesen
-- INVERTIERT das Alpha-Byte bei drawRectangle (0 = deckend, 255 = transparent — siehe
-- DrawRectangleCommand.h). Deshalb in "Sichtbarkeit" rechnen und (255 - Sichtbarkeit) als Byte
-- weitergeben, damit ein HOEHERER Regler-Wert = sichtbarer ist. Die Fuellung ist ~0.42x so
-- deckend wie der Rahmen (durchscheinender Koerper + festerer Rand).
local GHOST_OPACITY = (type(__GHOST_OPACITY) == "number") and math.max(0, math.min(100, math.floor(__GHOST_OPACITY))) or 30
local ghBorderVis = math.floor(255 * GHOST_OPACITY / 100 + 0.5)   -- gewuenschte Deckkraft Rahmen
local ghFillVis   = math.floor(ghBorderVis * 0.42 + 0.5)          -- Fuellung schwaecher als Rahmen
local GHOST_FILL   = (255 - ghFillVis)   * 0x1000000 + GHOST_RGB  -- Byte invertiert an Mesen geben
local GHOST_BORDER = (255 - ghBorderVis) * 0x1000000 + GHOST_RGB
-- Namens-Label mit EIGENER Opacity (Setting __GHOST_NAME_OPACITY, unabhaengig vom Koerper oben):
-- so bleibt der Name lesbar, auch wenn der Ghost sehr blass ist - oder faded ebenfalls. Gleiche
-- invertierte Alpha-Semantik wie oben (drawString invertiert das Alpha-Byte genauso wie
-- drawRectangle, siehe DrawStringCommand.h). Der schwarze Schatten (bg) faded mit gleicher
-- Deckkraft mit, sonst klebte bei blassem Namen ein deckender schwarzer Kasten dahinter.
-- Default 100 -> ghNameVis 255 -> Byte 0 -> voll deckend = exakt das bisherige Verhalten.
local GHOST_NAME_OPACITY = (type(__GHOST_NAME_OPACITY) == "number") and math.max(0, math.min(100, math.floor(__GHOST_NAME_OPACITY))) or 100
local ghNameVis = math.floor(255 * GHOST_NAME_OPACITY / 100 + 0.5)
local GHOST_NAME_COLOR = (255 - ghNameVis) * 0x1000000 + GHOST_RGB
local GHOST_NAME_BG    = (255 - ghNameVis) * 0x1000000            -- schwarzer Schatten, gleiche Deckkraft
-- Outline-only (Setting): nur den Rahmen zeichnen, keine Fuellung.
local GHOST_OUTLINE = (__GHOST_OUTLINE == true)
local GHOST_DEFAULT_ADDRS = { player_x = 0x94, player_y = 0x96, camera_x = 0x1A, camera_y = 0x1C, room = 0x13BF }
local ghostAddrs = GHOST_DEFAULT_ADDRS

local function resolveGhostAddrs(s)
  local d = GHOST_DEFAULT_ADDRS
  local o = s and s.ghost or nil
  if not o then return d end
  local room
  if o.room == false then room = nil
  elseif o.room ~= nil then room = o.room
  else room = d.room end
  return {
    player_x = o.player_x or d.player_x,
    player_y = o.player_y or d.player_y,
    camera_x = o.camera_x or d.camera_x,
    camera_y = o.camera_y or d.camera_y,
    room = room,
  }
end

-- HINWEIS: Hier stand die eigene Tod-Erkennung fuer das alte "Auto Reset on Death" (SMW-Default
-- $0071 == 9, pro Segment via seg.death ueberschreibbar). Der Auto-Reset haengt jetzt an den
-- games.lua-"fail"-Bedingungen (siehe AUTO_RESET), damit er auch fuer Retro-Challenges gilt und es
-- nur EINEN Ausloeser gibt. Damit war die Tod-Erkennung toter Code - und sie kostete drei der 200
-- local-Slots, die hier knapp sind. `seg.death` in games.lua hat seitdem keine Wirkung mehr; kein
-- Paket hat es je benutzt (der challenge-builder gibt das Feld nicht aus).

-- ==========================================
-- MUSIK STUMMSCHALTEN — "Mute music (keep sound effects)"
-- ==========================================
-- UI-Setting (vom ChallengeManager via __MUTE_MUSIC injiziert): haelt die N-SPC/AddmusicK-
-- Master-Musiklautstaerke pro Frame im SPC-RAM auf 0. Das trifft NUR die Musik (alle 8 Kanaele
-- laufen ueber diesen Master-Multiplikator); Sound-Effekte schreiben ihre DSP-Voice-Volumes
-- direkt und umgehen ihn -> SFX bleiben voll hoerbar (deshalb ersetzt das den frueheren Mixer-
-- Kanal-Ansatz, der Kanaele 7/8 = Musik nicht traf und SFX auf 1-6 mit-stumm schaltete). Ein
-- reiner SPC-RAM-Wert ohne Emulations-/Timing-Impact -> fairness-/replay-neutral. Kein Restore
-- noetig: ist Mute aus, poken wir nicht, und die Sound-Engine (bzw. der frische Savestate beim
-- Settings-Reload) haelt den Normalwert ($C0). SMW/AMK-Default-Adresse $0057; pro Segment via
-- seg.music_mute={addr=..} ueberschreibbar (retro-Games mit anderer Sound-Engine) oder
-- seg.music_mute=false, um es fuer dieses Segment abzuschalten.
local MUTE_MUSIC = (__MUTE_MUSIC == true)
local MUSIC_MUTE_DEFAULT = { addr = 0x0057 }
local musicMuteAddr = MUSIC_MUTE_DEFAULT
local function resolveMusicMute(s)
  local o = s and s.music_mute
  if o == false then return nil end               -- fuer dieses Segment abgeschaltet
  if type(o) ~= "table" then return MUSIC_MUTE_DEFAULT end
  return { addr = o.addr or MUSIC_MUTE_DEFAULT.addr }
end

-- Setzt die Master-Musiklautstaerke im SPC-RAM auf 0 (No-op, wenn Mute aus / fuer dieses Segment
-- abgeschaltet). Wird an zwei Stellen gerufen: (1) direkt NACH jedem Savestate-Load (dropInOp/
-- goOp/failOp) - der geladene State bringt den Normalwert ($C0) mit, wuerde die Musik also sonst
-- fuer einen Frame zuruueckbringen; (2) pro Frame in onFrame, damit auch ein Musikwechsel mitten
-- im Segment (Sublevel/Song-Init, der $57 selbst auf $C0 setzt) wieder stummgeschaltet wird.
local function applyMusicMute()
  if MUTE_MUSIC and musicMuteAddr then
    pcall(emu.write, musicMuteAddr.addr, 0, emu.memType.spcMemory)
  end
end

-- Aufnahme-Puffer (eine Position pro Play-Frame)
local ghRecX, ghRecY, ghRecRoom, ghRecN = {}, {}, {}, 0
local function ghostReset()
  ghRecX, ghRecY, ghRecRoom, ghRecN = {}, {}, {}, 0
end
local function ghostPush(x, y, room)
  ghRecN = ghRecN + 1
  ghRecX[ghRecN] = x; ghRecY[ghRecN] = y; ghRecRoom[ghRecN] = room
end
local function saveRecordedGhost(path)
  local f = io.open(path, "w")
  if not f then return end
  f:write("GPOS1\n")
  f:write("challenge=" .. CHALLENGE_ID .. "\n")
  f:write("segment=" .. math.floor(segIdx) .. "\n")
  f:write("player=" .. getP("name", PLAYER) .. "\n")
  f:write("frames=" .. ghRecN .. "\n")
  -- Als Global gelesen, nicht in ein local gehoben - 200-local-Limit (Kasten oben).
  f:write("emu=" .. ((type(__EMU_VERSION) == "string" and __EMU_VERSION) or "") .. "\n")
  f:write("engine=" .. ((type(__ENGINE_VERSION) == "string" and __ENGINE_VERSION) or "") .. "\n")
  f:write("\n")
  for i = 1, ghRecN do
    f:write(ghRecX[i] .. "," .. ghRecY[i] .. "," .. ghRecRoom[i] .. "\n")
  end
  f:close()
end

-- Anzeige-Puffer (der geladene PB-Ghost)
local ghX, ghY, ghRoom, ghLen, ghPlayer = {}, {}, {}, 0, "PB"
local function ghostLoad(path)
  ghX, ghY, ghRoom, ghLen, ghPlayer = {}, {}, {}, 0, "PB"
  local f = io.open(path, "r")
  if not f then return end
  local inData = false
  for line in f:lines() do
    if inData then
      local x, y, r = line:match("^(-?%d+),(-?%d+),(-?%d+)")
      if x then
        ghLen = ghLen + 1
        ghX[ghLen] = tonumber(x); ghY[ghLen] = tonumber(y); ghRoom[ghLen] = tonumber(r)
      end
    else
      local p = line:match("^player=(.+)")
      if p then ghPlayer = p end
      if line == "" then inData = true end
    end
  end
  f:close()
end

local function initSpikeMode()
  if REPLAY then
    SPIKE_FILE = __REPLAY_DIR .. "seg" .. math.floor(segIdx) .. ".inputs"
    spikeMode = "replay"
    loadReplayInputs(SPIKE_FILE)
    emu.log("Spike: Replay Mode. Loaded " .. #spikeInputs .. " polls from " .. SPIKE_FILE)
  else
    SPIKE_FILE = SCRIPT_DIR .. "recordings/temp_seg" .. math.floor(segIdx) .. ".inputs"
    spikeMode = "record"
    recordReset()
    emu.log("Spike: Record Mode. Will save to " .. SPIKE_FILE)

    -- If this is a fresh run (Segment 1 of a real challenge), clear all old temporary
    -- and completed recordings to start clean.
    if segIdx == 1 and not PRACTICE then
      emu.log("Spike: Fresh run started. Cleaning up old recordings.")
      for i = 1, #segments do
        os.remove(SCRIPT_DIR .. "recordings/temp_seg" .. math.floor(i) .. ".inputs")
        os.remove(SCRIPT_DIR .. "recordings/seg" .. math.floor(i) .. ".inputs")
      end
    end
  end
  -- Musik-Mute-Adresse fuer dieses Segment aufloesen (SMW/AMK-Default $0057, per seg.music_mute ueberschreibbar).
  musicMuteAddr = resolveMusicMute(segments[math.floor(segIdx)])
  -- Ghost: Adressen fuer dieses Segment aufloesen, Aufnahme-Puffer leeren, PB-Ghost laden.
  ghostAddrs = resolveGhostAddrs(segments[math.floor(segIdx)])
  ghostReset()
  if GHOST_SHOW then
    -- Foreign ghost (race a friend's .creplay) if injected, else the local PB ghost.
    local ghostPath = GHOST_DIR
      and (GHOST_DIR .. "seg" .. math.floor(segIdx) .. ".ghost")
      or (SCRIPT_DIR .. "recordings/pb_seg" .. math.floor(segIdx) .. ".ghost")
    ghostLoad(ghostPath)
  end
  spikePollCounter = 0
end

local function resetSpikeAttempt()
  recordReset()
  ghostReset()
  spikePollCounter = 0
  emu.log("Spike: Attempt reset. Poll counter set to 0.")
end

-- Pfade in Segmenten auflösen (relativ zu GAMES-Ordner machen)
for _, seg in ipairs(segments) do
  if seg.rom and not seg.rom:match("^[A-Za-z]:") and not seg.rom:match("^/") then
    seg.rom = GAMES .. seg.rom
  end
  if seg.state and not seg.state:match("^[A-Za-z]:") and not seg.state:match("^/") then
    seg.state = GAMES .. seg.state
  end
end

-- Debug-Ausgabe: Segmente, Reihenfolge und Pfade protokollieren
emu.log("Relay: Lade Challenge-Konfiguration aus: " .. SCRIPT_DIR .. "games.lua")
emu.log("Relay: Konfigurierte Segmente in Reihenfolge:")
for i, seg in ipairs(segments) do
  emu.log(string.format("  Segment %d/%d: %s", i, #segments, seg.name))
  emu.log(string.format("    ROM-Pfad:   %s", seg.rom or "Kein ROM angegeben"))
  emu.log(string.format("    State-Pfad: %s", seg.state or "Kein State angegeben"))
end

-- Debug-Log startup to file
local lf = io.open(SCRIPT_DIR .. "recordings/lua_log_startup.txt", "w")
if lf then
  lf:write("__CHALLENGE_DIR=" .. tostring(__CHALLENGE_DIR) .. "\n")
  lf:write("SCRIPT_DIR=" .. tostring(SCRIPT_DIR) .. "\n")
  lf:write("GAMES=" .. tostring(GAMES) .. "\n")
  for i, s in ipairs(segments) do
    lf:write("seg " .. i .. " rom=" .. tostring(s.rom) .. "\n")
  end
  lf:close()
end

local function getPlayerName()
  -- Vom ChallengeManager injizierter Name (aus den Challenge-Settings) hat Vorrang.
  if type(__PLAYER) == "string" then
    local n = __PLAYER:match("^%s*(.-)%s*$")
    if n and #n > 0 then return n end
  end

  local path = SCRIPT_DIR .. "player_name.txt"
  local f = io.open(path, "r")
  if f then
    local name = f:read("*l")
    f:close()
    if name then
      name = name:match("^%s*(.-)%s*$") -- strip leading/trailing whitespace
      if #name > 0 then
        return name
      end
    end
  end
  return "Player1"
end

local PLAYER    = getPlayerName()  -- Name des Spielers (wird aus player_name.txt gelesen, falls vorhanden)
-- Preview: vor jedem Segment-Start (und jedem Practice-Versuch) wird der Startframe
-- als Standbild fuer PREVIEW_FRAMES Frames gezeigt, BEVOR Spiel + Timer loslaufen, damit
-- der Spieler seine Inputs vorbereiten kann. Vom ChallengeManager via __PREVIEW_FRAMES
-- injiziert (Challenge-Einstellungen). 0 = aus (sofort los). Ersetzt den alten Countdown.
local PREVIEW_FRAMES = (type(__PREVIEW_FRAMES) == "number") and math.max(0, math.floor(__PREVIEW_FRAMES)) or 60
-- Setting "Get Ready nach Tod": nach einer fail-Bedingung den Segment-Timer ANHALTEN und das
-- GET-READY-Standbild zeigen, dann weiterspielen (Timer laeuft ab dem alten Stand weiter -
-- der Tod selbst kostet weiterhin die bereits verbrauchte Zeit, nur die Pause ist frei).
-- Fuers Replay irrelevant: Polls werden nur in der play-Phase gezaehlt (Aufnahme UND Replay),
-- die Pause ist im Input-Log also unsichtbar - deshalb im Replay-Modus einfach aus.
local FAIL_PREVIEW = (__FAIL_PREVIEW == true) and (not REPLAY)
-- goOp: Timer NICHT nullen (Fail-Preview setzt den Versuch fort, statt neu zu starten)
local failPreviewPending = false
local FPS       = 60.0988
local RESULT_FILE = GAMES .. "relay_result.txt"

-- Datei-IPC mit dem C#-ChallengeManager fuer den Bestenlisten-Submit (AP5):
-- Auf dem Done-Screen schreibt die Engine bei START SUBMIT_REQUEST; der
-- ChallengeManager signiert (HMAC) und sendet das Ergebnis, und schreibt das
-- Resultat nach SUBMIT_RESULT, das die Engine wieder anzeigt.
local SUBMIT_REQUEST = SCRIPT_DIR .. "submit_request.txt"
local SUBMIT_RESULT  = SCRIPT_DIR .. "submit_result.txt"

-- Export-IPC: auf dem Done-Screen schreibt die Engine bei SELECT EXPORT_REQUEST; der
-- ChallengeManager packt den gerade beendeten Lauf (Inputs + Geister) in eine .creplay und
-- oeffnet einen Speichern-Dialog. Rein lokal, kein Login/Netz noetig (anders als Submit).
local EXPORT_REQUEST = SCRIPT_DIR .. "export_request.txt"

-- Settings-Reload-IPC: ein L+R-Reset (bei GLEICHER ROM) schreibt RELOAD_REQUEST; der
-- ChallengeManager re-injiziert daraufhin die Engine (mit __FORCE_RESET) und baut dabei
-- den Header aus der AKTUELLEN Config neu -> geaenderte Challenge-Settings greifen sofort,
-- ohne die Challenge komplett neu zu starten. Der Persist (_persistedValues) ueberlebt den
-- Script-Reload, daher genuegt hier das Signal. Bei ROM-Wechsel-Reset ist kein Extra-Signal
-- noetig: das emu.loadRom loest ohnehin eine Neu-Injektion mit frischen Settings aus.
local RELOAD_REQUEST = SCRIPT_DIR .. "reload_request.txt"
local function writeReloadRequest()
  local ok, err = pcall(function()
    local f = assert(io.open(RELOAD_REQUEST, "w"))
    f:write("reload\n")                      -- Inhalt egal; dient nur als Signal
    f:close()
  end)
  emu.log("Reload-Request -> " .. (ok and RELOAD_REQUEST or ("ERROR: " .. tostring(err))))
  return ok
end

-- ---- Personal Bests (lokal: pro Segment + Gesamt) -----------------
-- Anzeige per "Show Personal Bests" im Challenge-Menue (injiziert als __SHOW_PBS).
-- PBs werden IMMER getrackt (auch wenn die Anzeige aus ist), damit sie da sind,
-- sobald man sie einschaltet. Gespeichert lokal in pb.txt im Challenge-Ordner.
local SHOW_PBS = (__SHOW_PBS == true)

-- Einzeln schaltbare Live-HUD-Elemente (vom ChallengeManager via __HUD_SEGMENT/__HUD_DELTA
-- injiziert, aus den Challenge-Settings). Fehlen sie (aeltere UI), gilt der bisherige
-- Default "an" (~= false). SHOW_SEGMENT blendet Segment-Zaehler + Segmentname aus,
-- SHOW_DELTA das laufende +/- gegen die Segment-PB (nur mit SHOW_PBS + vorhandener PB).
local SHOW_SEGMENT = (__HUD_SEGMENT ~= false)
local SHOW_DELTA   = (__HUD_DELTA ~= false)

-- Auto-Reset bei Fail (vom ChallengeManager via __AUTO_RESET injiziert): "off" = klassisch, ein
-- Fail laedt nur den Segment-Save neu und der Lauf laeuft weiter; "first" = nur in Segment 1, wo
-- ein Fail den Spieler ohnehin an den Anfang des LAUFES zurueckwirft (ohne Reset laeuft dort bloss
-- die Uhr weiter, auf einem bereits verdorbenen Lauf); "always" = jeder Fail beendet den Versuch.
-- Haengt an den games.lua-"fail"-Bedingungen der Challenge, funktioniert also auch fuer
-- Retro-Challenges. Zaehlt wie die Reset-Combo als neuer Versuch. In Practice ohne Wirkung (dort
-- IST der Segment-Neustart der Zweck) und im Replay ohne Wirkung.
-- Ersetzt das fruehere __AUTO_RESET_ON_DEATH, das an einem SMW-only-Tod-Check hing.
local AUTO_RESET = (type(__AUTO_RESET) == "string" and __AUTO_RESET) or "off"

-- HUD-Groesse (vom ChallengeManager via __HUD_SS injiziert: 1 = Big, 2 = Normal, 3 = Small, 4 = Smaller).
local surfaceScale = 1
local textScale = 1
local ox, oy = 0, 0
local function setupHudScale()
  local sizeType = (type(__HUD_SS) == "number") and math.floor(__HUD_SS) or 2
  if sizeType == 1 then -- Big (old Normal)
    surfaceScale = 1
    textScale = 1
  elseif sizeType == 2 then -- Normal (new intermediate)
    surfaceScale = 3
    textScale = 2
  elseif sizeType == 3 then -- Small (old Small)
    surfaceScale = 2
    textScale = 1
  elseif sizeType == 4 then -- Smaller (old Smaller)
    surfaceScale = 3
    textScale = 1
  else
    surfaceScale = 2
    textScale = 1
  end

  if surfaceScale > 1 then
    emu.selectDrawSurface(emu.drawSurface.scriptHud, surfaceScale)
    local ds = emu.getDrawSurfaceSize() or {}
    local ov = ds.overscan or {}
    ox = ov.left or 0
    oy = ov.top or 0

    local _origDrawString = emu.drawString
    emu.drawString = function(x, y, text, color, bg, maxWidth, frameCount, displayDelay, scale)
      local sx = x * surfaceScale + ox
      local sy = y * surfaceScale + oy
      return _origDrawString(sx, sy, text, color, bg, maxWidth or 0, frameCount or 1, displayDelay or 0, scale or textScale)
    end

    local _origMeasureString = emu.measureString
    emu.measureString = function(text, maxWidth, scale)
      return _origMeasureString(text, maxWidth, scale or textScale)
    end
  end
end
setupHudScale()

if type(emu.muteAudio) == "function" then
  emu.muteAudio(false)
end

local function drawRect(x, y, w, h, col, fill)
  local sx = x * surfaceScale + ox
  local sy = y * surfaceScale + oy
  local sw = w * surfaceScale
  local sh = h * surfaceScale
  emu.drawRectangle(sx, sy, sw, sh, col, fill)
end

-- ---- SNES Controller Input Display ------------------------------------------
-- Zeichnet ein kompaktes SNES-Gamepad-Overlay im ausgewaehlten Eck (TopRight,
-- BottomRight, BottomLeft). Live beim Spielen (emu.getInput(0)) und im Replay (replayInput).
inputDisplay = {
  enabled = (__INPUT_DISPLAY == true),
  pos = (type(__INPUT_DISPLAY_POS) == "string" and __INPUT_DISPLAY_POS) or "bottomright",
  _logged = false,
  draw = function(inp)
    if not inputDisplay.enabled then return end
    local ok, err = pcall(function()
      local curInput = inp
      if not curInput then
        if REPLAY and phase == "play" then
          curInput = replayInput
        else
          curInput = emu.getInput(0)
        end
      end
      curInput = curInput or {}

      local ds = emu.getDrawSurfaceSize() or {}
      local sz = emu.getScreenSize() or {}
      local W = sz.width or 256
      local H = (ds.visibleHeight and math.floor(ds.visibleHeight / surfaceScale)) or sz.height or 224

      local x0, y0
      if inputDisplay.pos == "topright" then
        x0 = W - 66
        y0 = (surfaceScale == 1 and 12 or 4)
      elseif inputDisplay.pos == "bottomleft" then
        x0 = 4
        y0 = H - 29
      else -- "bottomright"
        x0 = W - 66
        y0 = H - 29
      end

      if not inputDisplay._logged then
        inputDisplay._logged = true
        flog(string.format("inputDisplay.draw OK: x0=%s y0=%s W=%s H=%s surfaceScale=%s ox=%s oy=%s",
             tostring(x0), tostring(y0), tostring(W), tostring(H), tostring(surfaceScale), tostring(ox), tostring(oy)))
      end

      -- 1. L & R Schultertasten (abgerundet oben auf dem Gehaeuse)
      local lCol = curInput.l and 0xFFFFFF or 0x606060
      local rCol = curInput.r and 0xFFFFFF or 0x606060
      drawRect(x0 + 7,  y0,     14, 3, lCol, true)
      drawRect(x0 + 6,  y0 + 1, 16, 2, lCol, true)
      drawRect(x0 + 41, y0,     14, 3, rCol, true)
      drawRect(x0 + 40, y0 + 1, 16, 2, rCol, true)

      -- 2. Controller Body (abgerundete SNES-Form, vergroessert fuer perfekte Proportionen)
      -- Dunkler Rand (62 x 23)
      drawRect(x0 + 3, y0 + 3, 56, 23, 0x1A1A1A, true)
      drawRect(x0 + 1, y0 + 5, 60, 19, 0x1A1A1A, true)
      drawRect(x0 + 0, y0 + 7, 62, 15, 0x1A1A1A, true)
      drawRect(x0 + 2, y0 + 4, 58, 21, 0x1A1A1A, true)

      -- Hellgrauer Body (Faceplate)
      drawRect(x0 + 4, y0 + 4, 54, 21, 0xC6C6C6, true)
      drawRect(x0 + 2, y0 + 6, 58, 17, 0xC6C6C6, true)
      drawRect(x0 + 1, y0 + 8, 60, 13, 0xC6C6C6, true)
      drawRect(x0 + 3, y0 + 5, 56, 19, 0xC6C6C6, true)

      -- 3. Abgerundete Mulden (Bays) fuer D-Pad und Buttons
      -- Linke D-Pad Mulde (abgerundetes Quadrat)
      drawRect(x0 + 4, y0 + 6, 17, 17, 0x9E9E9E, true)
      drawRect(x0 + 3, y0 + 8, 19, 13, 0x9E9E9E, true)
      drawRect(x0 + 6, y0 + 5, 13, 19, 0x9E9E9E, true)

      -- Rechte ABXY Mulde (abgerundetes Feld fuer 5x5 Buttons)
      drawRect(x0 + 40, y0 + 5, 19, 19, 0x9E9E9E, true)
      drawRect(x0 + 39, y0 + 7, 21, 15, 0x9E9E9E, true)
      drawRect(x0 + 42, y0 + 4, 15, 21, 0x9E9E9E, true)

      -- 4. D-Pad (symmetrisches 15x15 Kreuz mit 5x5 Armen & abgerundeten Ecken)
      local dpadColor  = 0x222222
      local dpadActive = 0x00E5FF

      -- Center (5x5)
      drawRect(x0 + 10, y0 + 12, 5, 5, dpadColor, true)
      drawRect(x0 + 12, y0 + 14, 1, 1, 0x111111, true)

      -- Up (5x5)
      local colUp = curInput.up and dpadActive or dpadColor
      drawRect(x0 + 10, y0 + 7,  5, 5, colUp, true)
      drawRect(x0 + 10, y0 + 7,  1, 1, 0x9E9E9E, true)   -- Ecke oben-links
      drawRect(x0 + 14, y0 + 7,  1, 1, 0x9E9E9E, true)   -- Ecke oben-rechts

      -- Down (5x5)
      local colDown = curInput.down and dpadActive or dpadColor
      drawRect(x0 + 10, y0 + 17, 5, 5, colDown, true)
      drawRect(x0 + 10, y0 + 21, 1, 1, 0x9E9E9E, true)   -- Ecke unten-links
      drawRect(x0 + 14, y0 + 21, 1, 1, 0x9E9E9E, true)   -- Ecke unten-rechts

      -- Left (5x5)
      local colLeft = curInput.left and dpadActive or dpadColor
      drawRect(x0 + 5,  y0 + 12, 5, 5, colLeft, true)
      drawRect(x0 + 5,  y0 + 12, 1, 1, 0x9E9E9E, true)   -- Ecke oben-links
      drawRect(x0 + 5,  y0 + 16, 1, 1, 0x9E9E9E, true)   -- Ecke unten-links

      -- Right (5x5)
      local colRight = curInput.right and dpadActive or dpadColor
      drawRect(x0 + 15, y0 + 12, 5, 5, colRight, true)
      drawRect(x0 + 19, y0 + 12, 1, 1, 0x9E9E9E, true)   -- Ecke oben-rechts
      drawRect(x0 + 19, y0 + 16, 1, 1, 0x9E9E9E, true)   -- Ecke unten-rechts

      -- 5. Select & Start (saubere horizontale Gummipillen)
      local colSel   = curInput.select and 0xFFFFFF or 0x444444
      local colStart = curInput.start and 0xFFFFFF or 0x444444
      drawRect(x0 + 24, y0 + 14, 5, 2, colSel, true)
      drawRect(x0 + 32, y0 + 14, 5, 2, colStart, true)

      -- 6. ABXY Buttons (dicke, saftige 5x5 Knoepfe mit abgerundeten Ecken)
      local function drawRoundBtn(bx, by, col)
        drawRect(bx, by, 5, 5, col, true)
        drawRect(bx, by, 1, 1, 0x9E9E9E, true)
        drawRect(bx + 4, by, 1, 1, 0x9E9E9E, true)
        drawRect(bx, by + 4, 1, 1, 0x9E9E9E, true)
        drawRect(bx + 4, by + 4, 1, 1, 0x9E9E9E, true)
      end

      -- X (Top - Blau)
      drawRoundBtn(x0 + 47, y0 + 6,  curInput.x and 0x00B0FF or 0x154880)
      -- Y (Left - Gruen)
      drawRoundBtn(x0 + 41, y0 + 12, curInput.y and 0x00E676 or 0x1A6B2A)
      -- B (Bottom - Gelb)
      drawRoundBtn(x0 + 47, y0 + 18, curInput.b and 0xFFEA00 or 0x7A6B10)
      -- A (Right - Rot)
      drawRoundBtn(x0 + 53, y0 + 12, curInput.a and 0xFF1744 or 0x7A1818)
    end)
    if not ok and not inputDisplay._errLogged then
      inputDisplay._errLogged = true
      flog("ERROR in inputDisplay.draw: " .. tostring(err))
    end
  end
}

-- Big (surfaceScale=1): Start bei y=12 mit 10px Abstand (Originale Werte, Overscan-sicher).
-- Skalierte Modi: Start bei y=2 mit 8px Abstand (Wrapper handhabt den Overscan-Offset).
local hudStartY  = surfaceScale == 1 and 12 or 2
local hudLineGap = surfaceScale == 1 and 10 or 8
local function hudLineY(n) return hudStartY + n * hudLineGap end
local function hud(x, lineIdx, text, color, bg)
  emu.drawString(x, hudLineY(lineIdx), text, color or 0xFFFFFF, bg or 0x000000)
end

local PB_FILE  = SCRIPT_DIR .. "pb.txt"
local pbSeg    = {}    -- [Segmentname] = beste Frames
local pbTotal  = nil   -- bester Gesamtlauf in Frames
local prevTotalPB  = nil    -- Gesamt-PB VOR diesem Lauf (fuer den Vergleich auf dem Done-Screen)
local isNewTotalPB = false  -- hat DIESER Lauf eine neue Gesamt-PB gesetzt? (nur fuer die Anzeige)

local function loadPBs()
  pbSeg, pbTotal = {}, nil
  local f = io.open(PB_FILE, "r")
  if not f then return end
  for line in f:lines() do
    -- Frames toleranzweise als Zahl lesen (auch "6213.0"): aeltere Builds haben den
    -- total ueber den persist-Roundtrip als Float geschrieben, was der frueher
    -- benutzte reine "%d+"-Match nicht laden konnte (-> pbTotal war immer nil und
    -- jeder Lauf galt faelschlich als neue PB). Auf Ganzzahl-Frames normalisieren.
    local name, frames = line:match("^seg;(.-);([%d%.]+)%s*$")
    if name then
      pbSeg[name] = math.floor(tonumber(frames))
    else
      local t = line:match("^total;([%d%.]+)%s*$")
      if t then pbTotal = math.floor(tonumber(t)) end
    end
  end
  f:close()
end

local function savePBs()
  local f = io.open(PB_FILE, "w")
  if not f then return end
  for name, frames in pairs(pbSeg) do
    f:write("seg;" .. name .. ";" .. math.floor(frames) .. "\n")
  end
  -- Immer als Ganzzahl schreiben (kein "6213.0"): der persist-Roundtrip kann den
  -- total in einen Float verwandeln; sonst laedt loadPBs() ihn nicht zurueck.
  if pbTotal then f:write("total;" .. math.floor(pbTotal) .. "\n") end
  f:close()
end

-- ---- Versuchszaehler (ueber die gesamte Spielhistorie, ueberlebt Segment-Reloads) --
-- Ein "Versuch" = ein bewusster Neustart der GESAMTEN Challenge auf Segment 1 (Reset-
-- Combo). Ein Tod mitten im Segment laedt nur den Segment-Save neu (siehe failOp) und
-- zaehlt NICHT als neuer Versuch. Wird beim Submit als "tries" mitgeschickt, damit der
-- Server damit die tatsaechliche Versuchszahl statt eines simplen Submit-Zaehlers zeigt.
local ATTEMPTS_FILE = SCRIPT_DIR .. "attempts.txt"
local function loadAttempts()
  local f = io.open(ATTEMPTS_FILE, "r")
  if not f then return 1 end
  local n = tonumber(f:read("*a"))
  f:close()
  return n and math.max(1, math.floor(n)) or 1
end
local function saveAttempts(n)
  local f = io.open(ATTEMPTS_FILE, "w")
  if not f then return end
  f:write(tostring(math.floor(n)))
  f:close()
end

-- Setzt die Segment-PB (lokale Anzeige), falls schneller. Die serverseitigen Segment-PBs
-- werden NICHT von hier gepusht, sondern beim Run-Submit aus den Run-Splits abgeleitet
-- (aus dem vertrauenswuerdigen Core-persist, nicht aus pb.txt) - siehe submit.php.
local function updateSegmentPB(name, frames)
  if REPLAY then return false end
  local prev = pbSeg[name]
  if not prev or frames < prev then
    pbSeg[name] = frames
    savePBs()
    return true            -- neue Segment-PB (fuer die Stream-Stats: pbs++)
  end
  return false
end

loadPBs()

--[[
 { name = "DKC1 - Jungle Hijinx", rom = GAMES.."dkc1.sfc",
    state = GAMES.."states/dkc1.state",
    done = { addr = 0x003E, op = "increased" },
    fail = { addr = 0x0577, op = "decreased" } },

  { name = "Aladdin - Agrabah", rom = GAMES.."aladdin.sfc",
    state = GAMES.."states/aladdin.state",
    done = { addr = 0x1423, op = "nonzero" },
    fail = { addr = 0x0364, op = "decreased" } },

  -- Retro-Game (volle ROM referenziert, kein BPS-Patch). DKC2-RAM: www.p4plus2.com/dkc2/ram.php
  -- Speicher = snesWorkRam-Offset (wie SMW). Tod = Leben ($08BE, 2 Byte) sinkt.
  -- Level-Clear = $08C2 Bit 1 (0x0002, Level-Transition/Fadeout) - in-game verifizieren.
  { name = "DKC2 - Pirate Panic", rom = "DKC2 - Pirate Panic.smc",
    state = "states/DKC2 - Pirate Panic.state",
    done = { addr = 0x08C2, op = "anybits", value = 0x0002, size = 2 },
    fail = { addr = 0x08BE, op = "decreased", size = 2 } },
--]]
----------------------------- ENDE CONFIG ----------------------------

local MEM = emu.memType.snesWorkRam
local EXEC_S, EXEC_E, CPU = 0x000000, 0xFFFFFF, emu.cpuType.snes

-- ==========================================
-- GEGNER-ZAEHLER ("kills") — pro Segment
-- ==========================================
-- Zaehlt pro Versuch mit, wie viele Gegner der Spieler erledigt hat. Grundlage ist die SMW-
-- Sprite-Statustabelle $14C8 (12 Slots, 1 Byte je Slot), die pro Play-Frame gescannt wird:
-- wechselt ein Slot von einem LEBEND-Status (08 normal, 09 liegend/tragbar, 0A gekickt,
-- 0B getragen) in einen TOD-Status (02 weggeschleudert, 03 platt, 04 Spinjump-Kill,
-- 05 in Lava verbrannt), zaehlt das als ein Kill. Von Yoshi verschluckte Gegner (07 -> 00)
-- zaehlen ebenfalls. Ein Slot, der aus einem lebenden Status auf 00 springt, zaehlt NICHT -
-- das ist der normale Despawn am Bildschirmrand.
--
-- Der Zaehler ist VERSUCHS-lokal (Tod/Segment-Neustart setzt ihn auf 0 zurueck, weil der
-- Savestate die Gegner ebenfalls zurueckbringt). Zusaetzlich laeuft ein Lauf-Gesamtzaehler
-- (persistiert als "kills_total", ueberlebt den ROM-Wechsel zwischen Segmenten) fuer die
-- Stream-Stats; der zaehlt auch Kills aus gescheiterten Versuchen.
--
-- games.lua, pro Segment (alles optional):
--   kills = false                     -- Zaehler fuer dieses Segment aus (z. B. Retro-Segmente)
--   kills = { addr = 0x14C8, slots = 12, stride = 1, label = "Gegner", show = true,
--             alive = { 0x08, 0x09, 0x0A, 0x0B }, dead = { 0x02, 0x03, 0x04, 0x05 },
--             yoshi = true }          -- 07 -> 00 (von Yoshi verschluckt) mitzaehlen
-- Ziel-Segment ("toete X Gegner"):
--   done = { kills = 10 }             -- Kurzform fuer { counter = "kills", op = "atleast", value = 10 }
--
-- HINWEIS: das Modul lebt (wie stream) in EINER IIFE - relay.lua liegt nah am Lua-Limit von
-- 200 file-scope-Locals, deshalb kostet der ganze Zaehler hier nur ein einziges Local.
local kills = (function()
  local DEF = { addr = 0x14C8, slots = 12, stride = 1, label = "Kills",
                alive = { 0x08, 0x09, 0x0A, 0x0B },
                dead  = { 0x02, 0x03, 0x04, 0x05 } }
  local cfg, target, n, runTotal, prev = nil, nil, 0, 0, {}

  local function toSet(list)
    local t = {}
    for _, v in ipairs(list or {}) do t[v] = true end
    return t
  end

  local function build(o)
    if o == false then return nil end                 -- fuer dieses Segment abgeschaltet
    if type(o) ~= "table" then o = {} end
    return {
      addr   = o.addr   or DEF.addr,
      slots  = o.slots  or DEF.slots,
      stride = o.stride or DEF.stride,
      label  = o.label  or DEF.label,
      show   = o.show,                                -- nil = automatisch (nur mit Ziel)
      yoshi  = (o.yoshi ~= false),
      alive  = toSet(o.alive or DEF.alive),
      dead   = toSet(o.dead  or DEF.dead),
    }
  end

  return {
    -- Bei jedem Segmentwechsel rufen (auch beim In-Memory-Reset): uebernimmt die Segment-
    -- Konfiguration und liest das Ziel aus den "counter"-Bedingungen der done-Liste.
    bind = function(s, doneL)
      cfg = build(s and s.kills)
      target = nil
      if cfg then
        if type(s) == "table" and type(s.kills) == "table" and s.kills.target then
          target = s.kills.target                      -- reine Anzeige (Ziel ohne done-Bedingung)
        end
        for _, c in ipairs(doneL or {}) do
          if c.counter == "kills" and c.value then target = c.value end
        end
      end
      runTotal = tonumber(getP("kills_total", 0)) or 0
      prev = {}
      n = 0
    end,
    -- Neuer Versuch (Savestate-Load): Slot-Snapshot + Versuchszaehler zuruecksetzen.
    resetAttempt = function()
      prev = {}
      n = 0
    end,
    -- Neuer Lauf: auch den Lauf-Gesamtzaehler nullen.
    resetRun = function()
      runTotal = 0
      setP("kills_total", 0)
    end,
    -- Pro Play-Frame: Statustabelle scannen und neue Kills zaehlen. Liefert die Kills
    -- dieses Frames (0, wenn nichts passiert ist).
    update = function()
      if not cfg then return 0 end
      local got = 0
      for i = 0, cfg.slots - 1 do
        local st = emu.read(cfg.addr + i * cfg.stride, MEM)
        local p = prev[i]
        if p then
          if cfg.alive[p] and cfg.dead[st] then
            got = got + 1
          elseif cfg.yoshi and p == 0x07 and st == 0x00 then   -- von Yoshi verschluckt
            got = got + 1
          end
        end
        prev[i] = st
      end
      if got > 0 then
        n = n + got
        runTotal = runTotal + got
        setP("kills_total", runTotal)
      end
      return got
    end,
    get      = function() return n end,
    runTotal = function() return runTotal end,
    target   = function() return target end,
    label    = function() return cfg and cfg.label or DEF.label end,
    -- HUD-Zeile zeigen? Mit Ziel immer, sonst nur bei kills.show = true.
    visible  = function()
      if not cfg then return false end
      if cfg.show ~= nil then return cfg.show == true end
      return target ~= nil
    end,
  }
end)()

-- ---- Helfer -------------------------------------------------------
local function read_addr(d)
  -- Virtuelle "Adresse": Bedingungen koennen statt eines RAM-Werts den Gegner-Zaehler
  -- lesen ({ counter = "kills", op = "atleast", value = 10 }). Alle ops funktionieren
  -- damit unveraendert - die Baseline ist am Versuchs-Start immer 0.
  if d.counter then
    if d.counter == "kills" then return kills.get() end
    return 0
  end
  local sz = d.size or 1
  if     sz == 1 then return emu.read(d.addr,  MEM)
  elseif sz == 2 then return emu.read16(d.addr, MEM)
  -- 3 Byte (z. B. Mario-Score $0F34-$0F36): es gibt kein read24 - 32 Bit lesen und das
  -- ueberzaehlige High-Byte (bei $0F34 Luigis Score-Low-Byte) ausmaskieren.
  elseif sz == 3 then return emu.read32(d.addr, MEM) & 0xFFFFFF
  else                return emu.read32(d.addr, MEM) end
end

local function cond_met(d, baseline, cur)
  local op = d.op or "nonzero"
  if     op == "nonzero"   then return cur ~= 0
  elseif op == "increased" then return cur >  baseline
  elseif op == "decreased" then return cur <  baseline
  elseif op == "changed"   then return cur ~= baseline
  elseif op == "equals"    then return cur == d.value
  elseif op == "atleast"   then return cur >= (d.value or 1)
  -- Baseline-relativ: "seit Versuchs-Start um mind. value gestiegen/gefallen". Fuer
  -- z.B. "sammel X coins" (increasedby) unabhaengig vom Coin-Stand beim Segment-Start.
  elseif op == "increasedby" then return cur >= baseline + (d.value or 1)
  elseif op == "decreasedby" then return cur <= baseline - (d.value or 1)
  -- Bitmasken (value = Maske, NICHT baseline-relativ): fuer Games mit Flag-Bytes, z. B.
  -- DKC2 $08C2 (Tod = Bit 13 = 0x2000, Level-Fadeout = Bit 1 = 0x0002). Bei >8 Bit
  -- unbedingt size = 2 setzen, sonst wird nur das Low-Byte gelesen. (Lua 5.4 Bit-Ops.)
  elseif op == "anybits"   then return (cur & (d.value or 0)) ~= 0
  elseif op == "allbits"   then return (cur & (d.value or 0)) == (d.value or 0)
  elseif op == "nobits"    then return (cur & (d.value or 0)) == 0
  end
  return false
end

-- "done"/"fail" in games.lua akzeptieren EINE Bedingung ({ addr=.., op=.. }) ODER
-- eine LISTE von Bedingungen ({ { addr=.., op=.. }, { .. }, .. }) - ausgeloest wird,
-- sobald EINE davon zutrifft (ODER-Logik). Gedacht v. a. fuer fail: z. B. Tod ODER
-- Start+Select-Exit sollen beide das Segment neu starten (ohne Gesamtzeit-Reset).
-- Nachschlagliste + Snippet-Generator: Challenge/ram-referenz.html
-- Zusaetzlich gibt es die Kurzform { kills = N } ("toete N Gegner"), die hier auf eine
-- normale Bedingung auf den Gegner-Zaehler normalisiert wird (siehe read_addr/kills).
local function condList(c)
  if not c then return nil end
  local list = (c.addr or c.counter or c.kills) and { c } or c   -- einzelne Bedingung -> 1-elementige Liste
  local out = {}
  for i, x in ipairs(list) do
    if x.kills then
      out[i] = { counter = "kills", op = "atleast", value = x.kills }
    else
      out[i] = x
    end
  end
  return out
end

-- Baselines (Wert beim Versuchs-Start) fuer jede Bedingung der Liste lesen.
local function readBases(list)
  if not list then return nil end
  local bases = {}
  for i, c in ipairs(list) do bases[i] = read_addr(c) end
  return bases
end

local function anyCondMet(list, bases)
  if not list then return false end
  for i, c in ipairs(list) do
    if cond_met(c, bases and bases[i], read_addr(c)) then return true end
  end
  return false
end

-- ==========================================
-- ZIEL-FORTSCHRITT IM HUD — "Score 1200/5000"
-- ==========================================
-- Viele Ziel-Bedingungen zaehlen etwas, das das Spiel selbst NICHT anzeigt: SMW blendet den
-- Score waehrend eines Levels nirgends ein, den Gegner-Zaehler der Engine sowieso nicht. Daraus
-- wird hier eine Fortschrittszeile abgeleitet: AKTUELLER WERT / BENOETIGTER WERT.
--
-- Angezeigt werden nur Schwellen-ops, bei denen es einen Fortschritt gibt:
--   atleast                  -> absoluter Wert / value
--   increasedby/decreasedby  -> Differenz zum Segment-Start / value   (z. B. "Score-Punkte")
-- nonzero/equals/changed/Bitmasken haben keinen sinnvollen Zwischenstand -> keine Zeile.
--
-- Pro Bedingung optional in games.lua:
--   label = "Score"   -- HUD-Beschriftung (sonst automatisch, s. KNOWN bzw. Zaehler-Label)
--   mul   = 10        -- Anzeigefaktor: SMW speichert den Score als Punkte/10 -> mul = 10
--   show  = false     -- diese Bedingung nie im HUD anzeigen
--
-- Haengt bewusst als Feld am kills-Modul statt als eigenes file-scope-Local: relay.lua ist mit
-- ~198 Locals dicht am Lua-Limit von 200 (das do-Block-Local unten ist nur lokal aktiv).
do
  -- Bekannte SMW-Adressen: sinnvolle Beschriftung + Faktor, damit auch aeltere games.lua
  -- (ohne label/mul) sofort richtig angezeigt werden.
  local KNOWN = {
    [0x0F34] = { label = "Score", mul = 10 },   -- Mario-Score, RAM-Wert = Punkte / 10
    [0x0DBF] = { label = "Coins" },
    [0x18D2] = { label = "Combo" },             -- aufeinanderfolgende Stomps
    [0x0DBE] = { label = "Lives" },
  }

  -- Liefert label, aktuellen Wert, Zielwert (beide schon mit mul skaliert) - oder nil, wenn
  -- das Segment kein anzeigbares Ziel hat bzw. der Versuch noch nicht laeuft (keine Baselines).
  kills.goalInfo = function(list, bases)
    if not list or not bases then return nil end
    for i, c in ipairs(list) do
      local op = c.op or "nonzero"
      local target, cur
      if     op == "atleast"     then target = c.value or 1; cur = read_addr(c)
      elseif op == "increasedby" then target = c.value or 1; cur = read_addr(c) - (bases[i] or 0)
      elseif op == "decreasedby" then target = c.value or 1; cur = (bases[i] or 0) - read_addr(c)
      end
      if target and c.show ~= false then
        local k = (not c.counter) and KNOWN[c.addr] or nil
        local label = c.label
                      or (c.counter == "kills" and kills.label())
                      or (k and k.label)
                      or "Goal"
        local mul = c.mul or (k and k.mul) or 1
        if cur < 0 then cur = 0 end
        return label, math.floor(cur * mul), math.floor(target * mul)
      end
    end
    return nil
  end

  -- Fertige HUD-Zeile: (text, zielErreicht) oder nil.
  kills.goalLine = function(list, bases)
    local label, cur, target = kills.goalInfo(list, bases)
    if not label then return nil end
    return string.format("%s %d/%d", label, cur, target), cur >= target
  end
end

local function fmt(frames)
  local s = frames / FPS
  local m = math.floor(s / 60)
  return string.format("%d:%06.3f", m, s - m * 60)
end

local function normalizePath(p)
  if not p then return "" end
  return p:gsub("\\", "/"):lower()
end

-- Reset-Shortcut: alle Buttons aus RESET_COMBO muessen gleichzeitig gehalten werden.
local function comboHeld(input)
  if #RESET_COMBO == 0 then return false end   -- kein Button -> nie ausgeloest (statt "immer")
  for _, b in ipairs(RESET_COMBO) do
    if not input[b] then return false end
  end
  return true
end
local function comboLabel()
  local parts = {}
  for _, b in ipairs(RESET_COMBO) do parts[#parts + 1] = b:upper() end
  return table.concat(parts, "+")
end

-- ---- Persist (ueberlebt ROM-Wechsel + Skript-Neustart) ------------
local PFX = REPLAY and "replay_store_" or "relay_"
getP = function(k, d) local v = emu.getPersist(PFX .. k); if v == nil then return d end; return v end
setP = function(k, v) emu.setPersist(PFX .. k, v) end

local function splitsAppend(name, frames)
  name = name:gsub("[|;]", " ")
  local s = getP("splits", "")
  if #s > 0 then s = s .. "|" end
  setP("splits", s .. name .. ";" .. frames)
end
local function splitsList()
  local out = {}
  for item in string.gmatch(getP("splits", ""), "([^|]+)") do
    local n, f = item:match("(.-);(%d+)")
    if n then out[#out + 1] = { name = n, frames = tonumber(f) } end
  end
  return out
end

-- ---- Laufzeit (eine Instanz = ein Segment) ------------------------
if __FORCE_RESET then
  emu.setPersist(PFX .. "seg", nil)
  emu.setPersist(PFX .. "total", nil)
  emu.setPersist(PFX .. "splits", nil)
  emu.log("Relay: FORCE RESET requested. Cleared persist values.")
end

-- Practice-Mode (vom ChallengeManager via __PRACTICE_SEGMENT injiziert): ein einzelnes
-- Segment grinden, OHNE Scoring (keine PB-/total-/splits-/finished-Writes, kein Submit).
local PRACTICE_SEG = (type(__PRACTICE_SEGMENT) == "number" and __PRACTICE_SEGMENT > 0)
                     and math.floor(__PRACTICE_SEGMENT) or nil
PRACTICE = PRACTICE_SEG ~= nil
local practiceClears = 0
-- Nur im Speicher (NICHT persistiert): die abgeschlossenen Practice-Versuche dieser
-- Session. Eine neue Practice-Session laedt das Skript frisch -> Liste ist wieder leer.
local practiceTimes = {}        -- alle gefinishten Practice-Zeiten (chronologisch)
local practiceBest  = nil       -- beste gefinishte Practice-Zeit dieser Session
local practiceArmed = false     -- Restart-Latch: erst nach Tasten-Loslassen scharf

local attempts = 0
if not REPLAY then
  attempts = loadAttempts()
  setP("attempts", attempts)   -- persist immer aktuell halten, auch ohne Reset in dieser Session
end

-- segIdx forward-declared at top
if PRACTICE then
  segIdx = PRACTICE_SEG
  if segIdx > #segments then segIdx = #segments end
else
  segIdx = getP("seg", 0)
  if segIdx == 0 then
    segIdx = 1
    setP("seg", 1)
    setP("total", 0)
    setP("splits", "")
    setP("name", PLAYER)
    setP("id", CHALLENGE_ID)     -- fuer den Bestenlisten-Submit (vom ChallengeManager gelesen)
    setP("challenge", CHALLENGE)
    setP("finished", 0)          -- wird erst bei echtem Abschluss auf 1 gesetzt
    setP("kills_total", 0)       -- Gegner-Zaehler des Laufs (siehe kills-Modul)
    emu.log("Relay: FRISCHER LAUF initialisiert.")
  end
  if segIdx > #segments then segIdx = #segments end
end
segIdx = math.floor(segIdx)

local seg = segments[segIdx]
-- Normalisierte Bedingungs-Listen des aktiven Segments (siehe condList). Muessen bei
-- jedem seg-Wechsel ohne Skript-Neustart (resetChallenge in-memory) mitgezogen werden.
local doneList = condList(seg.done)
local failList = condList(seg.fail)
kills.bind(seg, doneList)        -- Gegner-Zaehler auf dieses Segment einstellen (Ziel aus done)

-- Validierung: Ist die korrekte ROM geladen?
local function checkRomLoaded()
  local info = emu.getRomInfo() or {}
  local currentRom = normalizePath(info.path)
  local targetRom = normalizePath(seg.rom)

  emu.log(string.format("Challenge: ROM-Check for Segment %d (%s)...", segIdx, seg.name))
  emu.log("  Done: " .. tostring(info.path))
  emu.log("  To do: " .. tostring(seg.rom))

  if currentRom ~= targetRom then
    -- Check if file can be opened by Lua
    local fileToLoad = seg.rom:gsub("/", "\\")
    local tf, terr = io.open(fileToLoad, "rb")
    local logFile = SCRIPT_DIR .. "recordings/lua_log.txt"
    local lf = io.open(logFile, "w")
    if lf then
      lf:write("fileToLoad=" .. tostring(fileToLoad) .. "\n")
      if tf then
        lf:write("io.open=success\n")
        tf:close()
      else
        lf:write("io.open=failed, error=" .. tostring(terr) .. "\n")
      end
      lf:close()
    end

    emu.log("  -> ROMs do not match! Load Segment-ROM...")
    emu.loadRom(fileToLoad, seg.patch and seg.patch:gsub("/", "\\") or "")
    return false
  end
  emu.log("  -> ROM-Check OK!")
  return true
end

if not checkRomLoaded() then
  return -- Beendet die weitere Ausfuehrung des Skripts, da loadRom ein Reboot ausloest
end
initSpikeMode()
local baseTotal = getP("total", 0)     -- Frames der vorherigen Segmente
local segFrames = 0
local retries   = 0
phase           = "init"               -- init -> preview -> go -> play -> done (Practice: + pdone)
local cdFrames  = 0
local previewReady = false             -- Freeze-State an sauberer Frame-Grenze schon gegriffen?
local previewState                      -- separater Standbild-State fuers Preview (haelt startState pristine)
local busy      = false                -- ein Exec-Op steht aus
local reloadPending = false            -- Reload-Request geschrieben; Engine wartet auf C#-Neu-Injektion
local goStuckFrames = 0                -- Diagnose: wie lange haengt "go" auf einen goOp-Callback?
local startState
local baseDone, baseFail
local resetHoldFrames = 0
local resetLatched    = false   -- nach Reset: erst wieder zaehlen, wenn Tasten losgelassen
-- Ein Combo-Reset startet das Skript neu (Engine-Reload bzw. ROM-Wechsel). Wird die Combo dabei
-- weiter gehalten, wuerde die frische Instanz sofort erneut ausloesen (v.a. im Tap-Modus -> Dauer-
-- Retry). resetChallenge setzt daher ein Persist-Flag; hier konsumieren wir es einmalig und
-- verlangen bis zur naechsten echten Tastenfreigabe (im inputPolled-Callback erkannt) keinen Reset.
local resetNeedsRelease = (tostring(getP("reset_hold_guard", "0")) == "1")
setP("reset_hold_guard", "0")
local submitState     = "idle"  -- idle -> sent (wartet auf Resultat) -> done
local submitPollFrames = 0      -- Drossel: submit_result.txt nur ~4x/s statt jeden Frame pollen
local submitMsg       = ""      -- vom ChallengeManager gemeldeter Status (1. Zeile = ok/error)
local submitOk        = false
local submitAchievements = {}   -- durch diesen Submit freigeschaltete Achievements ({name=, desc=})
local achFrame        = 0       -- Frame-Zaehler fuer Popup-Blinken/-Rotation
local startLatched    = false   -- Edge-Detection fuer den START-Submit
local physicalStartPressed = false
local selectLatched   = false   -- Edge-Detection fuer den SELECT-Export
local physicalSelectPressed = false
local exportFlashFrames = 0     -- >0: kurz "export dialog opened" statt der Aufforderung anzeigen
local pdoneButtonHeld = false   -- physischer Nicht-Richtungs-Tastendruck auf dem Practice-Ergebnis-Screen

-- ==========================================
-- STREAM-OVERLAY — Statistiken fuer OBS (AP: Stream-Stats)
-- ==========================================
-- Optionales Feature (UI-Setting "Stream overlay", via __STREAM_OVERLAY/__STREAM_DIR injiziert):
-- die Engine schreibt nach jedem Lauf-Event (Tod, Segment-Clear, Finish, Reset) eine schreib-only
-- stats.json + text/*.txt in den stream/-Ordner neben Mesen.exe. Ein self-contained overlay.html
-- (vom ChallengeManager dorthin kopiert) rendert das als OBS-Browser-Quelle. Session-Zahlen leben
-- in session.dat (schlank key=value) und werden pro Event read-modify-write aktualisiert, damit sie
-- Segment-Neustarts ueberleben; der "Reset stream stats"-Button loescht einfach session.dat.
-- WICHTIG: das ganze Modul lebt in EINER IIFE, die eine Tabelle (stream) zurueckgibt. Lua begrenzt
-- ein Chunk auf 200 file-scope-Locals; relay.lua liegt nah dran, darum werden die vielen Helfer hier
-- in einer inneren Funktion gekapselt (eigenes Local-Budget) - im Haupt-Chunk kostet es nur 1 Local.
local stream = (function()
  local STREAM_DIR = (type(__STREAM_DIR) == "string" and #__STREAM_DIR > 0) and __STREAM_DIR or nil
  if STREAM_DIR and not STREAM_DIR:match("/$") then STREAM_DIR = STREAM_DIR .. "/" end
  local enabled = (__STREAM_OVERLAY == true) and STREAM_DIR ~= nil and not REPLAY

  -- Gegner-Kills laufen (anders als Tode/Clears) sehr schubweise. Sie werden daher gepuffert
  -- und hoechstens einmal pro Sekunde geschrieben; jedes andere Event nimmt den Puffer mit.
  local pendingKills, killRenderAt = 0, 0
  local function takeKills()
    local k = pendingKills
    pendingKills = 0
    return k
  end

  -- Sekunden -> "H:MM:SS" bzw. "M:SS" (fuer Spielzeit; fmt() ist fuer Frame-Zeiten).
  local function fmtClock(sec)
    sec = math.max(0, math.floor(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
  end

  local function jsonEsc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("[%c]", function(c) return string.format("\\u%04x", string.byte(c)) end)
    return s
  end

  -- session.dat einlesen (fehlt sie -> frische Session mit jetzigem Startzeitpunkt).
  local function loadStats()
    local s = {
      session_start = os.time(), deaths = 0, resets = 0, finishes = 0,
      best_run = nil, pbs = 0, current_streak = 0, best_streak = 0,
      run_deaths = 0, run_start = os.time(), runs_started = 1, segd = {},
      kills = 0,
    }
    local f = STREAM_DIR and io.open(STREAM_DIR .. "session.dat", "r")
    if not f then return s end
    local fresh = true
    for line in f:lines() do
      local k, v = line:match("^([^=]+)=(.*)$")
      if k then
        fresh = false
        local seg = k:match("^segd:(.+)$")
        if seg then
          s.segd[seg] = tonumber(v) or 0
        elseif k == "best_run" then
          s.best_run = tonumber(v)               -- "" / non-number -> nil
        else
          s[k] = tonumber(v) or s[k]
        end
      end
    end
    f:close()
    if fresh then s.session_start = os.time(); s.run_start = os.time() end
    return s
  end

  local function saveStats(s)
    if not STREAM_DIR then return end
    pcall(function()
      local f = assert(io.open(STREAM_DIR .. "session.dat", "w"))
      f:write("session_start=", s.session_start, "\n")
      f:write("deaths=", s.deaths, "\n")
      f:write("resets=", s.resets, "\n")
      f:write("finishes=", s.finishes, "\n")
      f:write("best_run=", s.best_run or "", "\n")
      f:write("pbs=", s.pbs, "\n")
      f:write("current_streak=", s.current_streak, "\n")
      f:write("best_streak=", s.best_streak, "\n")
      f:write("run_deaths=", s.run_deaths, "\n")
      f:write("run_start=", s.run_start, "\n")
      f:write("runs_started=", s.runs_started, "\n")
      f:write("kills=", s.kills, "\n")
      for name, n in pairs(s.segd) do
        f:write("segd:", name, "=", n, "\n")
      end
      f:close()
    end)
  end

  -- Schreibt stats.json (fuers overlay.html) + einzelne text/*.txt (fuer OBS-Textquellen).
  local function render(s, state)
    if not STREAM_DIR then return end
    local now = os.time()
    local playSec = math.max(0, now - (s.session_start or now))
    local dph = playSec > 0 and math.floor(s.deaths / (playSec / 3600) + 0.5) or 0
    local frate = s.runs_started > 0 and math.floor(s.finishes / s.runs_started * 100 + 0.5) or 0
    local runTime = fmt(baseTotal + segFrames)

    -- Sum of Best + Golds (Segmente mit eigener PB) analog zum HUD.
    local sob, complete, golds = 0, true, 0
    for _, sg in ipairs(segments) do
      local pb = pbSeg[sg.name]
      if pb then sob = sob + pb; golds = golds + 1 else complete = false end
    end

    -- Nemesis + Segment-Breakdown (in Segment-Reihenfolge).
    local nemName, nemN = nil, 0
    local segParts = {}
    for _, sg in ipairs(segments) do
      local d = s.segd[sg.name] or 0
      if d > nemN then nemN = d; nemName = sg.name end
      segParts[#segParts + 1] = string.format('{"name":"%s","deaths":%d}', jsonEsc(sg.name), d)
    end

    -- Gegner-Zaehler: Segment (aktueller Versuch, ggf. mit Ziel), Lauf und Session.
    local killTarget = kills.target()
    local killStr = tostring(kills.get()) .. (killTarget and ("/" .. killTarget) or "")

    -- Ziel-Fortschritt des Segments ("Score 1200/5000") - wie im HUD, s. kills.goalInfo.
    local gLabel, gCur, gTarget = kills.goalInfo(doneList, baseDone)
    local goalJson = gLabel
      and string.format('{"label":"%s","current":%d,"target":%d}', jsonEsc(gLabel), gCur, gTarget)
      or "null"
    local goalStr = gLabel and string.format("%s %d/%d", gLabel, gCur, gTarget) or "--"

    local player = getP("name", PLAYER)
    local nemJson = nemName
      and string.format('{"segment":"%s","deaths":%d}', jsonEsc(nemName), nemN)
      or "null"

    local json = table.concat({
      "{\n",
      '  "updated": ', now, ',\n',
      '  "challenge": "', jsonEsc(CHALLENGE), '",\n',
      '  "player": "', jsonEsc(player), '",\n',
      '  "live": {\n',
      '    "segment": ', math.floor(segIdx), ', "segment_total": ', #segments, ',\n',
      '    "segment_name": "', jsonEsc(seg and seg.name or ""), '",\n',
      '    "run_time": "', runTime, '", "run_deaths": ', s.run_deaths, ', "state": "', state or "playing", '",\n',
      '    "kills": ', kills.get(), ', "kills_target": ', killTarget or 0, ', "run_kills": ', kills.runTotal(), ',\n',
      '    "goal": ', goalJson, '\n',
      '  },\n',
      '  "records": {\n',
      '    "pb_total": "', pbTotal and fmt(pbTotal) or "--", '", "pb_total_frames": ', pbTotal or 0, ',\n',
      '    "sum_of_best": "', complete and fmt(sob) or "--", '", "sum_of_best_complete": ', tostring(complete), ',\n',
      '    "golds": ', golds, ', "segments": ', #segments, '\n',
      '  },\n',
      '  "session": {\n',
      '    "deaths": ', s.deaths, ', "resets": ', s.resets, ', "finishes": ', s.finishes, ',\n',
      '    "best_run": "', s.best_run and fmt(s.best_run) or "--", '", "pbs": ', s.pbs, ',\n',
      '    "playtime": "', fmtClock(playSec), '", "playtime_seconds": ', playSec, ',\n',
      '    "runs_started": ', s.runs_started, ', "finish_rate": ', frate, ', "deaths_per_hour": ', dph, ',\n',
      '    "current_streak": ', s.current_streak, ', "best_streak": ', s.best_streak, ',\n',
      '    "kills": ', s.kills, ',\n',
      '    "nemesis": ', nemJson, ',\n',
      '    "segment_deaths": [', table.concat(segParts, ","), ']\n',
      '  }\n',
      "}\n",
    })

    pcall(function()
      local f = assert(io.open(STREAM_DIR .. "stats.json", "w"))
      f:write(json); f:close()
    end)

    -- Einzelne Textdateien fuer OBS "Text (GDI+)"-Quellen.
    local texts = {
      ["challenge"]      = CHALLENGE,
      ["player"]         = player,
      ["segment"]        = string.format("%d/%d %s", math.floor(segIdx), #segments, seg and seg.name or ""),
      ["run_time"]       = runTime,
      ["run_deaths"]     = s.run_deaths,
      ["pb_total"]       = pbTotal and fmt(pbTotal) or "--",
      ["sum_of_best"]    = complete and fmt(sob) or "--",
      ["golds"]          = string.format("%d/%d", golds, #segments),
      ["deaths"]         = s.deaths,
      ["finishes"]       = s.finishes,
      ["best_run"]       = s.best_run and fmt(s.best_run) or "--",
      ["pbs"]            = s.pbs,
      ["attempts"]       = s.runs_started,
      ["finish_rate"]    = frate .. "%",
      ["deaths_per_hour"] = dph,
      ["playtime"]       = fmtClock(playSec),
      ["streak"]         = string.format("%d (best %d)", s.current_streak, s.best_streak),
      ["nemesis"]        = nemName and string.format("%s (%d)", nemName, nemN) or "--",
      ["goal"]           = goalStr,                 -- Ziel des Segments, z. B. "Score 1200/5000"
      ["kills"]          = killStr,                 -- Segment (aktueller Versuch), z. B. "3/10"
      ["run_kills"]      = kills.runTotal(),        -- ganzer Lauf, inkl. gescheiterter Versuche
      ["session_kills"]  = s.kills,                 -- ganze Session
    }
    pcall(function()
      for name, val in pairs(texts) do
        local f = io.open(STREAM_DIR .. "text/" .. name .. ".txt", "w")
        if f then f:write(tostring(val)); f:close() end
      end
    end)
  end

  -- Event-Hooks (No-op, wenn das Overlay aus ist). Jeder macht load -> mutate -> save -> render.
  return {
    init = function()
      if not enabled then return end
      local s = loadStats(); saveStats(s); render(s, "playing")
    end,
    onDeath = function()
      if not enabled then return end
      local s = loadStats()
      s.kills = (s.kills or 0) + takeKills()
      s.deaths = s.deaths + 1
      s.run_deaths = s.run_deaths + 1
      local nm = seg and seg.name or "?"
      s.segd[nm] = (s.segd[nm] or 0) + 1
      s.current_streak = 0
      saveStats(s); render(s, "playing")
    end,
    -- Gegner erledigt (n = Kills in diesem Frame). Kann in Schueben kommen (ein Panzer raeumt
    -- eine ganze Reihe ab), darum wird hoechstens einmal pro Sekunde geschrieben; der Rest
    -- bleibt gepuffert und wird vom naechsten Schreibvorgang mitgenommen (takeKills).
    onKill = function(n)
      if not enabled then return end
      pendingKills = pendingKills + (n or 1)
      local now = os.time()
      if killRenderAt == now then return end
      killRenderAt = now
      local s = loadStats()
      s.kills = (s.kills or 0) + takeKills()
      saveStats(s); render(s, "playing")
    end,
    onClear = function(newPB)
      if not enabled then return end
      local s = loadStats()
      s.kills = (s.kills or 0) + takeKills()
      s.current_streak = s.current_streak + 1
      if s.current_streak > s.best_streak then s.best_streak = s.current_streak end
      if newPB then s.pbs = s.pbs + 1 end
      saveStats(s); render(s, "playing")
    end,
    onFinish = function(total, newPB)
      if not enabled then return end
      local s = loadStats()
      s.kills = (s.kills or 0) + takeKills()
      s.finishes = s.finishes + 1
      s.current_streak = s.current_streak + 1
      if s.current_streak > s.best_streak then s.best_streak = s.current_streak end
      if not s.best_run or total < s.best_run then s.best_run = total end
      if newPB then s.pbs = s.pbs + 1 end
      saveStats(s); render(s, "done")
    end,
    -- Neuer Run beginnt (Combo-Reset zaehlt als Reset; Auto-Reset-bei-Tod nur Run-Restart).
    onRunRestart = function(countReset)
      if not enabled then return end
      local s = loadStats()
      s.kills = (s.kills or 0) + takeKills()
      if countReset then s.resets = s.resets + 1 end
      s.runs_started = s.runs_started + 1
      s.run_deaths = 0
      s.run_start = os.time()
      saveStats(s); render(s, "playing")
    end,
  }
end)()

-- Name wird via player_name.txt gesetzt

emu.log(string.format("Challenge: Segment %d/%d (%s), already done %s",
        segIdx, #segments, seg.name, fmt(baseTotal)))

-- ---- Savestate-Ops im exec-Callback ausfuehren --------------------
local function runInExec(op)
  local ref
  ref = emu.addMemoryCallback(function()
    emu.removeMemoryCallback(ref, emu.callbackType.exec, EXEC_S, EXEC_E, CPU)
    op()
  end, emu.callbackType.exec, EXEC_S, EXEC_E, CPU)
end

-- Startet einen frischen Versuch am Segment-Anfang: Timer auf 0 und entweder erst das
-- Preview (Standbild des Startframes) oder direkt spielbar (PREVIEW_FRAMES == 0).
-- Gilt einheitlich fuer Segment 1, Mid-Relay-Segmente und Practice.
local function beginAttempt()
  segFrames = 0
  if PREVIEW_FRAMES > 0 then
    cdFrames = 0
    previewState = startState
    previewReady = true
    phase = "preview"
    if type(emu.muteAudio) == "function" then
      emu.muteAudio(true)
    end
  else
    phase = "play"
    if type(emu.muteAudio) == "function" then
      emu.muteAudio(false)
    end
  end
end

local function dropInOp(data)
  flog("dropInOp execute...")
  if data then
    local ok, err = pcall(emu.loadSavestate, data)
    flog("loadSavestate -> " .. (ok and "OK" or ("ERROR: " .. tostring(err))))
  else
    flog("No Savestate data to load (seg.state not set)")
  end
  startState = emu.createSavestate()
  previewState = startState
  previewReady = true
  applyMusicMute()               -- geladener State bringt $57=$C0 mit -> sofort wieder stumm
  kills.resetAttempt()           -- VOR readBases: Zaehler-Baseline eines Versuchs ist immer 0
  baseDone = readBases(doneList)
  baseFail = readBases(failList)
  -- log baseline values for done condition
  if doneList then
    for i, c in ipairs(doneList) do
      local v = read_addr(c)
      flog(string.format("doneList[%d] src=%s op=%s baseline=%s cur=%s",
              i, c.counter and ("counter:" .. c.counter) or string.format("0x%X", c.addr or 0),
              tostring(c.op), tostring(baseDone and baseDone[i]), tostring(v)))
    end
  end
  if failList then
    for i, c in ipairs(failList) do
      local v = read_addr(c)
      flog(string.format("failList[%d] src=%s op=%s baseline=%s cur=%s",
              i, c.counter and ("counter:" .. c.counter) or string.format("0x%X", c.addr or 0),
              tostring(c.op), tostring(baseFail and baseFail[i]), tostring(v)))
    end
  end
  beginAttempt()
  flog(string.format("dropInOp done, phase=%s (PREVIEW_FRAMES=%d)", phase, PREVIEW_FRAMES))
  busy = false
end

local function goOp()
  emu.log("Challenge: goOp ausfuehren...")
  local ok, err = pcall(emu.loadSavestate, startState)  -- sauberer Start nach Preview
  flog("goOp: loadSavestate -> " .. (ok and "OK" or ("ERROR: " .. tostring(err))))
  applyMusicMute()               -- geladener State bringt $57=$C0 mit -> sofort wieder stumm
  kills.resetAttempt()           -- Startstate zurueckgeladen -> Gegner sind wieder da
  if failPreviewPending then
    failPreviewPending = false   -- Fail-Preview: Versuch laeuft weiter, Timer behaelt seinen Stand
  else
    segFrames = 0
  end
  phase = "play"
  busy = false
  emu.log("Relay: goOp done, Phase set to play.")
end

local function failOp()
  emu.log("Relay: failOp (Restart after Death)...")
  emu.loadSavestate(startState)              -- Tod -> Neustart, Timer laeuft weiter
  applyMusicMute()                           -- geladener State bringt $57=$C0 mit -> sofort wieder stumm
  kills.resetAttempt()                       -- Segment startet neu -> Gegner-Zaehler bei 0
  -- In der Challenge unterbricht ein Tod die Aufnahme NICHT: der Puffer laeuft durchgehend
  -- weiter, damit das Replay die Tode 1:1 reproduziert und die Replay-Zeit zur eingereichten
  -- Zeit passt. Nur ein bewusster Retry (L+R -> resetChallenge) bzw. Practice startet neu.
  if PRACTICE then                           -- Practice: jeder Versuch wird frisch getimed + aufgenommen
    resetSpikeAttempt()
    baseDone = readBases(doneList)
    baseFail = readBases(failList)
    beginAttempt()                           -- erst Preview, dann play (auch aus pdone-Screen)
  elseif FAIL_PREVIEW and PREVIEW_FRAMES > 0 then
    -- "Get Ready nach Tod" (Setting): Timer anhalten (segFrames bleibt stehen - die Preview-
    -- Phase zaehlt nicht hoch) und das Standbild zeigen. goOp laesst den Timer dank
    -- failPreviewPending weiterlaufen statt ihn zu nullen. Polls sind play-gated, das
    -- Input-Log bleibt also identisch zu einem Lauf ohne diese Pause.
    failPreviewPending = true
    cdFrames = 0
    previewReady = false
    phase = "preview"
    if type(emu.muteAudio) == "function" then
      emu.muteAudio(true)
    end
  end
  busy = false
end

-- reloadSettings=true (bewusster L+R-Reset): die Engine wird neu injiziert, damit geaenderte
-- Challenge-Settings sofort greifen (etwas Latenz durch den Script-Reload). reloadSettings=false
-- (z. B. Auto-Reset bei Tod): schneller In-Memory-Reset ohne Settings-Refresh - wichtig, weil
-- das potenziell sehr oft passiert. Bei ROM-Wechsel ist der Pfad ohnehin ein voller Reload.
local function resetChallenge(reloadSettings)
  local firstSeg = segments[1]
  if not firstSeg then return end

  -- Ein bewusster Reset auf Segment 1 zaehlt als neuer Versuch (siehe ATTEMPTS_FILE
  -- oben). Vor dem moeglichen ROM-Wechsel speichern, damit der Skript-Neustart den
  -- erhoehten Wert per loadAttempts() wieder aufgreift.
  if not REPLAY then
    attempts = attempts + 1
    saveAttempts(attempts)
    setP("attempts", attempts)
  end

  local info = emu.getRomInfo() or {}
  local currentRom = normalizePath(info.path)
  local targetRom = normalizePath(firstSeg.rom)

  if currentRom == targetRom then
    -- Settings-Reload-Pfad: statt eines In-Memory-Resets die Engine vom ChallengeManager
    -- neu injizieren lassen -> frische Challenge-Settings + __FORCE_RESET (kein ROM-Reload).
    -- seg=0 setzt den "frischer Lauf"-Sentinel; der neu geladene Script initialisiert von
    -- vorn. Bis dahin legt reloadPending onFrame still. Schlaegt das Schreiben fehl, faellt
    -- es auf den bisherigen In-Memory-Reset zurueck, damit ein Reset immer funktioniert.
    if reloadSettings and writeReloadRequest() then
      emu.log("Challenge: Reset -> engine reload requested (fresh settings).")
      setP("reset_hold_guard", "1")   -- Neustart: gehaltene Combo darf nicht sofort neu ausloesen
      setP("seg", 0)
      setP("total", 0)
      setP("splits", "")
      setP("finished", 0)
      reloadPending = true
    else
      -- In-Memory-Reset: entweder gewollt (reloadSettings=false, z. B. Auto-Reset bei Tod)
      -- oder Fallback, falls das Reload-Signal nicht geschrieben werden konnte.
      emu.log("Challenge: Resetting challenge to Segment 1 (in-memory)...")
      setP("seg", 1)
      setP("total", 0)
      setP("splits", "")
      setP("finished", 0)

      segIdx = 1
      seg = segments[1]
      doneList = condList(seg.done)
      failList = condList(seg.fail)
      kills.resetRun()                  -- neuer Lauf -> Gegner-Gesamtzaehler auf 0
      kills.bind(seg, doneList)
      baseTotal = 0
      segFrames = 0
      retries = 0
      phase = "init"
      cdFrames = 0
      busy = false
      initSpikeMode()
    end
  else
    emu.log("Challenge: Loading Segment 1 ROM -> " .. firstSeg.rom)
    if reloadSettings then setP("reset_hold_guard", "1") end   -- s.o.: Neustart per ROM-Wechsel
    setP("seg", 0)
    setP("total", 0)
    setP("splits", "")
    emu.loadRom(firstSeg.rom:gsub("/", "\\"), firstSeg.patch and firstSeg.patch:gsub("/", "\\") or "")
  end
end

-- Springt im Replay auf ein anderes Segment (geclampt auf 1..#segments; ausserhalb des
-- Replay-Modus ein No-op). Ein Segment ist auch im Replay eine eigene Skript-Instanz - der
-- Sprung schreibt daher nur den Persist so um, als waere das Replay regulaer bis dorthin
-- gekommen, und laedt die Segment-ROM: die frische Instanz spielt seg<N>.inputs ab (wie nach
-- completeSegment). Gesamtzeit und Splits werden aus den Aufnahme-Kopfzeilen rekonstruiert,
-- damit HUD-Zeit und Endabrechnung nach einem Sprung stimmen. Ein Sprung auf das aktuelle
-- Segment (L auf Segment 1, R auf dem letzten) startet es einfach neu.
nav.skip = function(target)
  if not REPLAY or #segments == 0 then return end
  target = math.max(1, math.min(#segments, math.floor(target)))

  local total, splits = 0, {}
  for i = 1, target - 1 do
    local f = math.floor(nav.frames(i) or 0)
    total = total + f
    splits[#splits + 1] = (segments[i].name or ""):gsub("[|;]", " ") .. ";" .. f
  end
  setP("seg", target)
  setP("total", total)
  setP("splits", table.concat(splits, "|"))
  setP("finished", 0)          -- nach dem Endbildschirm zurueckspulen -> Lauf laeuft wieder
  setP("kills_total", 0)       -- Gegner-Zaehler des Laufs: nach einem Sprung nicht rekonstruierbar

  local t = segments[target]
  emu.log(string.format("Replay: skip to Segment %d/%d (%s)", target, #segments, tostring(t.name)))
  emu.loadRom(t.rom:gsub("/", "\\"), t.patch and t.patch:gsub("/", "\\") or "")
end

-- ---- Anzeige / Ablauf --------------------------------------------
-- "RESET IN Xs"-Anzeige, waehrend die Reset-Combo gehalten wird (Challenge UND Practice).
local function drawResetCountdown()
  if resetHoldFrames > 0 then
    local secondsLeft = string.format("%.1f", (RESET_HOLD_FRAMES - resetHoldFrames) / 60)
    -- Hellblau (0x66CCFF) statt Dunkelblau: das dunkle Blau war auf dem hellen/orangenen
    -- Hintergrund kaum lesbar. Schwarzer Schatten (0x000000) fuer zusaetzlichen Kontrast.
    emu.drawString(80, 80, "RESET IN " .. secondsLeft .. "s", 0x66CCFF, 0x000000)
  end
end

-- Einfacher Wort-Umbruch fuer die Achievement-Beschreibung (HUD-Font ~6px/Zeichen).
local function wrapText(s, maxLen)
  local lines, cur = {}, ""
  for word in (s or ""):gmatch("%S+") do
    if #cur == 0 then
      cur = word
    elseif #cur + 1 + #word <= maxLen then
      cur = cur .. " " .. word
    else
      lines[#lines + 1] = cur
      cur = word
    end
  end
  if #cur > 0 then lines[#lines + 1] = cur end
  return lines
end

-- "ACHIEVEMENT UNLOCKED!"-Popup unten auf dem Done-Screen: goldene Box mit blinkendem
-- Header; bei mehreren frisch freigeschalteten Achievements rotiert die Anzeige alle
-- 4 Sekunden durch (mit "(i/n)"-Zaehler). Gefuellt aus submit_result.txt (Zeilen "ach;..").
local function drawAchievementPopup()
  local n = #submitAchievements
  if n == 0 then return end
  achFrame = achFrame + 1

  local idx = (math.floor(achFrame / 240) % n) + 1
  local a = submitAchievements[idx]

  -- WICHTIG: in LOGISCHEN (unskalierten) Koordinaten arbeiten. Bei HUD-Groesse != Big ist
  -- surfaceScale > 1 und emu.drawString ist gewrappt (multipliziert x/y mit surfaceScale +
  -- Overscan) - erwartet also logische Koordinaten. Fuer die BREITE reicht getScreenSize().
  --
  -- Fuer die vertikale Verankerung (Box haengt unten) MUSS aber die tatsaechlich SICHTBARE
  -- Hoehe her: getScreenSize() ruft intern SetOverscan({}) auf und liefert die VOLLE Framehoehe
  -- OHNE Overscan -> zu gross. Bottom-Anchoring daran schiebt Box-Boden + letzte Textzeile in
  -- den abgeschnittenen unteren Overscan (Achievement lief unten aus dem Bild). Die sichtbare
  -- Hoehe kommt aus getDrawSurfaceSize().visibleHeight (in SKALIERTEN Pixeln -> /surfaceScale
  -- = logisch). Fallback auf getScreenSize().height fuer den unwahrscheinlichen nil-Fall.
  local sz = emu.getScreenSize() or {}
  local ds = emu.getDrawSurfaceSize() or {}
  local W = sz.width or 256
  local H = ds.visibleHeight and math.floor(ds.visibleHeight / surfaceScale) or sz.height or 224

  local descLines = wrapText(a.desc, 38)
  if #descLines > 2 then descLines = { descLines[1], descLines[2] } end

  local boxH = 28 + #descLines * 10
  local boxW = W - 4
  -- Am unteren sichtbaren Rand verankern, aber nie ueber den oberen Rand hinaus (Clamp).
  local x0, y0 = 2, math.max(2, H - boxH - 4)

  drawRect(x0, y0, boxW, boxH, 0x18000000, true)   -- fast deckender dunkler Grund
  drawRect(x0, y0, boxW, boxH, 0xFFD700, false)    -- goldener Rahmen

  local headerCol = (achFrame % 32 < 16) and 0xFFD700 or 0xFFFFFF
  local header = "* ACHIEVEMENT UNLOCKED! *"
  if n > 1 then header = header .. string.format(" (%d/%d)", idx, n) end
  emu.drawString(x0 + 6, y0 + 4, header, headerCol, 0x000000)
  emu.drawString(x0 + 6, y0 + 15, a.name, 0xFFD700, 0x000000)
  for i, line in ipairs(descLines) do
    emu.drawString(x0 + 6, y0 + 15 + i * 10, line, 0xCCCCCC, 0x000000)
  end
end

-- Kleine HUD-String-Caches: Segment-Zaehler und die formatierte Segment-PB aendern sich nur
-- bei Segmentwechsel bzw. PB-Update, muessen also nicht jeden Frame neu gebaut werden (drawHud
-- laeuft 60x/s). Die Zeit selbst aendert sich jeden Frame und bleibt daher live formatiert.
local hudSegIdxCache
local hudSegCounterStr = ""
local function segCounterString()
  if segIdx ~= hudSegIdxCache then
    hudSegIdxCache = segIdx
    hudSegCounterStr = string.format("Segment %d/%d", segIdx, #segments)
  end
  return hudSegCounterStr
end
local hudPbFramesCache = false   -- false = noch nicht berechnet (nil = Segment ohne PB)
local hudPbStr = nil
local function segPbString()
  local pb = pbSeg[seg.name]
  if pb ~= hudPbFramesCache then
    hudPbFramesCache = pb
    hudPbStr = pb and fmt(pb) or nil
  end
  return hudPbStr
end

local _drawHudErrLogged = false
local function drawHud()
  local ok, err = pcall(function()
    if PRACTICE then
    if phase == "pdone" then
      -- Practice-Ergebnis-Screen: Run-PB neben bester Practice-Zeit, darunter die
      -- letzten 4 abgeschlossenen Practice-Laeufe. (Stil wie der finale Done-Screen.)
      local ds = emu.getDrawSurfaceSize() or {}
      emu.drawRectangle(0, 0, ds.width or 256, ds.height or 240, 0x40000000, true)

      local last = practiceTimes[#practiceTimes]
      local isBest = practiceBest and last and last <= practiceBest
      emu.drawString(4, 12, "PRACTICE  " .. fmt(last or 0) .. (isBest and "  (best!)" or ""),
                     isBest and 0x00FF00 or 0xFFFF00, 0x000000)

      local y = 24
      local pbStr   = pbSeg[seg.name] and fmt(pbSeg[seg.name]) or "--"
      local bestStr = practiceBest and fmt(practiceBest) or "--"
      emu.drawString(4, y, "PB(run): " .. pbStr .. "   Best: " .. bestStr, 0xFFFFFF, 0x000000)
      y = y + 12

      emu.drawString(4, y, "Last runs:", 0xCCCCCC, 0x000000)
      y = y + 10
      local n = #practiceTimes
      for i = n, math.max(1, n - 3), -1 do
        local t = practiceTimes[i]
        local col = (practiceBest and t <= practiceBest) and 0x00FF00 or 0xFFFFFF
        emu.drawString(12, y, fmt(t), col, 0x000000)
        y = y + 10
      end

      y = y + 4
      emu.drawString(4, y, "Clears: " .. practiceClears, 0xFFFF00, 0x000000)
      y = y + 10
      emu.drawString(4, y, "Press any button to restart", 0x888888, 0x000000)
      if inputDisplay and inputDisplay.enabled then inputDisplay.draw() end
      return
    end
    hud(4, 0, "PRACTICE  " .. fmt(segFrames), 0xFFFF00)
    hud(4, 1, string.format("Seg %d/%d: %s", segIdx, #segments, seg.name), 0xCCCCCC)
    if SHOW_PBS and pbSeg[seg.name] then
      hud(4, 2, "PB " .. fmt(pbSeg[seg.name]) .. " (not updated)", 0x888888)
    end
    local gtxt, ghit = kills.goalLine(doneList, baseDone)
    if gtxt then
      hud(4, 3, gtxt, ghit and 0x00FF00 or 0xFFCC00)
    elseif kills.visible() then
      local kt = kills.target()
      hud(4, 3, kills.label() .. " " .. kills.get() .. (kt and ("/" .. kt) or ""), 0xFFCC00)
    end
    -- Clears oben rechts: getScreenSize() liefert die tatsaechliche Bildschirmbreite
    -- unabhaengig von der HUD-Surface. Zeichenbreite wird ueber die Base-Font geschaetzt
    -- (ca. 6px pro Zeichen bei 1x) und auf die aktuelle textScale/surfaceScale umgerechnet.
    local ctxt = "Clears: " .. practiceClears
    local screenSize = emu.getScreenSize() or {}
    local sw = screenSize.width or 256
    -- Jedes Zeichen ist ca. 6px breit bei base font (1x).
    -- Im Wrapper wird mit textScale gezeichnet auf surfaceScale-Surface,
    -- ergibt Bildschirmbreite = charWidth * textScale / surfaceScale pro Zeichen.
    local charW = 6 * textScale / surfaceScale
    local cw = #ctxt * charW
    hud(sw - cw - 2, 0, ctxt, 0xFFFF00)
    drawResetCountdown()                        -- L+R-Countdown auch im Practice zeigen
    if inputDisplay and inputDisplay.enabled then inputDisplay.draw() end
    return
  end
  if phase == "done" and segIdx == #segments then
    -- Hintergrund abdunkeln, damit die Zusammenfassung gut lesbar ist (Alpha invertiert:
    -- niedriges Alpha = staerker deckend; 0x40000000 ~ 75% schwarz). Volle Surface inkl.
    -- Overscan abdecken, damit der gesamte sichtbare Bereich gedimmt wird.
    local ds = emu.getDrawSurfaceSize() or {}
    emu.drawRectangle(0, 0, ds.width or 256, ds.height or 240, 0x40000000, true)

    local total = baseTotal + segFrames
    emu.drawString(4, 12, "DONE!  Total: " .. fmt(total), 0x00FF00, 0x000000)
    local y = 22
    if SHOW_PBS then
      if prevTotalPB then
        local d = total - prevTotalPB        -- Vergleich Gesamtzeit zur Gesamt-PB
        if d <= 0 then
          emu.drawString(4, y, string.format("NEW PB!  -%s vs old PB %s", fmt(-d), fmt(prevTotalPB)), 0x00FF00, 0x000000)
        else
          emu.drawString(4, y, string.format("+%s vs PB %s", fmt(d), fmt(prevTotalPB)), 0xFF4040, 0x000000)
        end
      elseif isNewTotalPB then
        emu.drawString(4, y, "First completion - new PB!", 0x00FF00, 0x000000)
      end
      y = y + 10
    end
    for i, sp in ipairs(splitsList()) do
      local nameLine = string.format("%d. %s", i, sp.name)
      emu.drawString(4, y, nameLine, 0xFFFFFF, 0x000000)
      y = y + 10

      local col = 0xCCCCCC
      local timeLine = "   Run: " .. fmt(sp.frames)
      if SHOW_PBS then
        local pb = pbSeg[sp.name]
        if pb then
          timeLine = timeLine .. "  PB: " .. fmt(pb)
          if sp.frames <= pb then col = 0xFFFF00 end   -- dieser Lauf haelt die Segment-PB (Gelb)
        end
      end
      emu.drawString(4, y, timeLine, col, 0x000000)
      y = y + 10
    end

    if SHOW_PBS and pbTotal then
      local tcol = total <= pbTotal and 0x00FF00 or 0xCCCCCC
      emu.drawString(4, y, "Best Total: " .. fmt(pbTotal), tcol, 0x000000)
      y = y + 10
    end

    if SHOW_PBS then
      -- Sum of Best: theoretisch moegliche Zeit, wenn man in JEDEM Segment seine Gold-Split
      -- (Segment-PB) trifft = Summe aller Segment-PBs. Nur sinnvoll, wenn fuer jedes Segment
      -- eine PB vorliegt; sonst ist die Summe unvollstaendig.
      local sob, complete = 0, true
      for _, s in ipairs(segments) do
        local pb = pbSeg[s.name]
        if pb then sob = sob + pb else complete = false; break end
      end
      if complete then
        emu.drawString(4, y, "Sum of Best: " .. fmt(sob), 0xFFFF00, 0x000000)
      else
        emu.drawString(4, y, "Sum of Best: -- (need a gold in every segment)", 0x888888, 0x000000)
      end
      y = y + 10
    end

    y = y + 4
    emu.drawString(4, y, "Player: " .. getP("name", PLAYER), 0x00FF00, 0x000000)
    y = y + 10

    -- Bestenlisten-Submit (jeder abgeschlossene Lauf, nicht nur neue Gesamt-PBs -
    -- der Server nimmt ohnehin das Minimum pro Spieler fuers Ranking).
    if REPLAY then
      local rmsg = REPLAY_PLAYER and ("REPLAY: " .. REPLAY_PLAYER .. " (No Submit)") or "REPLAY MODE (No Submit)"
      emu.drawString(4, y, rmsg, 0xFF4040, 0x000000)
      y = y + 10
      emu.drawString(4, y, "L/R: prev/next segment (rewatch)", 0x888888, 0x000000)
    elseif submitState == "idle" then
      emu.drawString(4, y, "Press START to submit to leaderboard", 0xFFFF00, 0x000000)
    elseif submitState == "sent" then
      emu.drawString(4, y, "Submitting...", 0xFFFF00, 0x000000)
    else -- done
      emu.drawString(4, y, submitMsg, submitOk and 0x00FF00 or 0xFF4040, 0x000000)
      -- A failed submit (e.g. not logged in with Twitch) does NOT lose the run: the
      -- done screen stays up, so the player can log in via Challenge > Settings and
      -- press START again to retry (see the input handler below).
      if not submitOk then
        y = y + 10
        emu.drawString(4, y, "Press START to try again", 0xFFFF00, 0x000000)
      end
    end
    y = y + 10
    -- Export (lokal): SELECT packt den Lauf + Geist zum Teilen. Unabhaengig vom Submit,
    -- daher auch ohne Login/Netz nutzbar. Im Replay-Modus nicht anbieten.
    if not REPLAY then
      if exportFlashFrames > 0 then
        emu.drawString(4, y, "Export: save dialog opened", 0x00FF00, 0x000000)
      else
        emu.drawString(4, y, "Press SELECT to export run (share)", 0x00CCFF, 0x000000)
      end
      y = y + 10
    end
    emu.drawString(4, y, "Hold " .. comboLabel() .. " to Restart", 0x888888, 0x000000)

    -- Frisch freigeschaltete Achievements (nach erfolgreichem Submit) als Popup unten.
    if submitState == "done" and submitOk then
      drawAchievementPopup()
    end
  else
    -- Dynamischer Zeilenzaehler: ausgeblendete Elemente (Segment-Info/Delta, s. Settings)
    -- hinterlassen keine Luecke, das HUD rueckt zusammen.
    local line = 0
    local total = baseTotal + segFrames
    if REPLAY then
      hud(4, line, string.format("REPLAY  %s  [%d/%d]", fmt(total), segIdx, #segments), 0xFF4040); line = line + 1
      if REPLAY_PLAYER then hud(4, line, "by " .. REPLAY_PLAYER, 0xFFCC00); line = line + 1 end
      hud(4, line, seg.name, 0xCCCCCC); line = line + 1
      -- Navigations-Hinweis nur am Segment-Anfang (und im Preview) einblenden, damit das HUD
      -- waehrend des Zuschauens schlank bleibt.
      if phase ~= "play" or segFrames < 240 then
        hud(4, line, "L/R: prev/next segment", 0x888888); line = line + 1
      end
    elseif SHOW_SEGMENT then
      hud(4, line, fmt(total) .. "  " .. segCounterString(), 0xFFFFFF); line = line + 1
      hud(4, line, seg.name, 0xCCCCCC); line = line + 1
    else
      hud(4, line, fmt(total), 0xFFFFFF); line = line + 1
    end

    if SHOW_PBS then
      local pbStr = segPbString()
      if pbStr then
        hud(4, line, "PB " .. pbStr, 0xCCCCCC); line = line + 1
        if SHOW_DELTA and phase == "play" then    -- Live-Delta: gruen wenn vor der PB, rot wenn dahinter
          local delta = segFrames - pbSeg[seg.name]
          local col = delta <= 0 and 0x00FF00 or 0xFF4040
          local sign = delta <= 0 and "-" or "+"
          hud(4, line, sign .. fmt(math.abs(delta)), col); line = line + 1   -- eigene Zeile (skaliert sauber)
        end
      else
        hud(4, line, "PB --", 0x888888); line = line + 1
      end
    end

    -- Ziel-Fortschritt ("Score 1200/5000", "Kills 3/10"): aus der done-Bedingung abgeleitet,
    -- damit man auch Werte sieht, die das Spiel selbst nicht einblendet. Ziel erreicht -> gruen.
    -- Ohne Ziel-Bedingung bleibt der reine Gegner-Zaehler (nur bei kills.show = true).
    local gtxt, ghit = kills.goalLine(doneList, baseDone)
    if gtxt then
      hud(4, line, gtxt, ghit and 0x00FF00 or 0xFFCC00); line = line + 1
    elseif kills.visible() then
      local kt = kills.target()
      hud(4, line, kills.label() .. " " .. kills.get() .. (kt and ("/" .. kt) or ""),
          0xFFCC00); line = line + 1
    end
  end

    drawResetCountdown()
    if inputDisplay and inputDisplay.enabled then inputDisplay.draw() end
  end)
  if not ok and not _drawHudErrLogged then
    _drawHudErrLogged = true
    flog("ERROR in drawHud: " .. tostring(err))
  end
end

local function finishRelay(total)
  emu.log("=== CHALLENGE DONE: " .. fmt(total) .. " ===")
  emu.displayMessage("Challenge", "DONE  " .. fmt(total))
  if not REPLAY then
    local ok, err = pcall(function()
      local f = assert(io.open(RESULT_FILE, "w"))
      f:write("challenge;" .. CHALLENGE .. "\n")
      f:write("name;" .. getP("name", PLAYER) .. "\n")
      f:write("total;" .. total .. "\n")
      for i, sp in ipairs(splitsList()) do
        f:write("split;" .. i .. ";" .. sp.name .. ";" .. sp.frames .. "\n")
      end
      f:close()
    end)
    emu.log("Result File -> " .. (ok and RESULT_FILE or ("ERROR: " .. tostring(err))))
    prevTotalPB = pbTotal                      -- PB VOR diesem Lauf merken (fuer Vergleich/Anzeige)
    isNewTotalPB = (not pbTotal) or (total < pbTotal)
    if isNewTotalPB then                       -- Gesamt-PB nur bei echter Verbesserung aktualisieren
      pbTotal = total
      savePBs()
    end
    stream.onFinish(total, isNewTotalPB)        -- Stream-Stats: Finish + Best-Run + Gesamt-PB-Zaehler

    -- Promote temporary recordings to completed run replay files
    emu.log("Spike: Challenge completed. Promoting temporary recordings.")
    for i = 1, #segments do
      local src = SCRIPT_DIR .. "recordings/temp_seg" .. math.floor(i) .. ".inputs"
      local dest = SCRIPT_DIR .. "recordings/seg" .. math.floor(i) .. ".inputs"
      os.remove(dest)
      os.rename(src, dest)
    end

    setP("finished", 1)                        -- markiert echten Abschluss (vom ChallengeManager geprueft)
  end
  setP("seg", 0)                             -- naechster Lauf startet frisch
end

-- ---- Bestenlisten-Submit (Datei-IPC mit dem C#-ChallengeManager) --
-- Der Trigger ist BEWUSST datenlos: die Lauf-Daten liest der ChallengeManager aus
-- dem Core-persist (von dieser eingebetteten Engine gesetzt), damit eine gefaelschte
-- Trigger-Datei keine erfundene Zeit einschleusen kann. Signieren (HMAC) + HTTP-POST
-- passieren im C#-Teil (siehe Challenge/LEADERBOARD_API.md).
local function writeSubmitRequest()
  os.remove(SUBMIT_RESULT)                   -- altes Resultat verwerfen
  local ok, err = pcall(function()
    local f = assert(io.open(SUBMIT_REQUEST, "w"))
    f:write("submit\n")                      -- Inhalt egal; dient nur als Signal
    f:close()
  end)
  emu.log("Submit-Request -> " .. (ok and SUBMIT_REQUEST or ("ERROR: " .. tostring(err))))
  return ok
end

-- Datenloser Export-Trigger (wie der Submit-Trigger): der ChallengeManager packt den
-- gerade beendeten Lauf und oeffnet den Speichern-Dialog. Kein Resultat-Round-Trip.
local function writeExportRequest()
  local ok, err = pcall(function()
    local f = assert(io.open(EXPORT_REQUEST, "w"))
    f:write("export\n")                      -- Inhalt egal; dient nur als Signal
    f:close()
  end)
  emu.log("Export-Request -> " .. (ok and EXPORT_REQUEST or ("ERROR: " .. tostring(err))))
  return ok
end

-- Liest das vom ChallengeManager geschriebene Resultat (1. Zeile ok/error,
-- 2. Zeile Anzeigetext). Liefert true, sobald ein Resultat vorlag.
local function pollSubmitResult()
  local f = io.open(SUBMIT_RESULT, "r")
  if not f then return false end
  local status = f:read("*l") or "error"
  local msg = f:read("*l") or ""
  -- Zeilen 3+: "ach;<Name>;<Beschreibung>" pro frisch freigeschaltetem Achievement
  -- (vom ChallengeManager aus der Server-Antwort uebernommen, ASCII-bereinigt).
  submitAchievements = {}
  while true do
    local line = f:read("*l")
    if not line then break end
    local name, desc = line:match("^ach;([^;]*);(.*)$")
    if name and #name > 0 then
      submitAchievements[#submitAchievements + 1] = { name = name, desc = desc or "" }
    end
  end
  f:close()
  status = status:match("^%s*(.-)%s*$")
  msg = msg:match("^%s*(.-)%s*$")
  submitOk = (status == "ok")
  submitMsg = msg
  submitState = "done"
  achFrame = 0
  return true
end

local function completeSegment()
  flog("completeSegment: enter")
  local newTotal = baseTotal + segFrames
  flog("completeSegment: newTotal=" .. tostring(newTotal))
  setP("total", newTotal)
  flog("completeSegment: setP total done")
  splitsAppend(seg.name, segFrames)
  flog("completeSegment: splitsAppend done")
  local newPB = updateSegmentPB(seg.name, segFrames)
  flog("completeSegment: updateSegmentPB done")
  emu.log(string.format("DONE Segment %d (%s) in %s  [Tries %d]",
          segIdx, seg.name, fmt(segFrames), retries + 1))
  stream.onClear(newPB)     -- Stream-Stats: Deathless-Streak + PB-Zaehler (jedes Segment, inkl. letztem)
  phase = "done"
  flog("completeSegment: phase set to done")
  if segIdx < #segments then
    local nxt = segments[segIdx + 1]
    setP("seg", segIdx + 1)
    flog("completeSegment: setP seg done")
    emu.log("loadRom -> " .. nxt.rom)

    -- Debug-Log completeSegment to file
    local lf = io.open(SCRIPT_DIR .. "recordings/lua_log.txt", "w")
    if lf then
      lf:write("nxt.rom=" .. tostring(nxt.rom) .. "\n")
      lf:write("nxt.patch=" .. tostring(nxt.patch) .. "\n")
      lf:close()
    end

    flog("completeSegment: about to call emu.loadRom to load " .. tostring(nxt.rom))
    emu.loadRom(nxt.rom:gsub("/", "\\"), nxt.patch and nxt.patch:gsub("/", "\\") or "")
    flog("completeSegment: loadRom call completed")
  else
    finishRelay(newTotal)
  end
end

-- ---- Pro-Frame-Logik (startFrame; KEINE Savestate-Aufrufe hier!) --
-- Zeichnet den PB-Ghost fuer den aktuellen Play-Frame: aufgezeichnete WELT-Position minus
-- LIVE-Kamera. Nur wenn on-screen und (falls Room konfiguriert) im selben Raum wie der Spieler.
-- Ist der Ghost noch nicht gestartet (i<1) oder schon "im Ziel" (i>ghLen), wird nichts gezeichnet.
local function drawGhost()
  local i = segFrames
  if i < 1 or i > ghLen then return end
  if ghostAddrs.room then
    if emu.read(ghostAddrs.room, MEM) ~= ghRoom[i] then return end
  end
  local sx = ghX[i] - emu.read16(ghostAddrs.camera_x, MEM)
  local sy = ghY[i] - emu.read16(ghostAddrs.camera_y, MEM)
  if sx > -16 and sx < 256 and sy > -32 and sy < 224 then
    -- WICHTIG: drawRect (nicht emu.drawRectangle direkt) — es rechnet surfaceScale + Overscan
    -- ein, genau wie der gepatchte emu.drawString. Sonst landet das Rechteck bei skalierter HUD
    -- (surfaceScale>1, Default) auf der falschen Position, waehrend der Name korrekt sitzt.
    -- Schlanker Marker: deutlich schmaler + niedriger als das Spieler-Sprite, UNTEN-buendig
    -- (die Unterkante bleibt bei sy+24, also am "Fuss"), horizontal auf der alten Breite zentriert.
    local GW, GH = 8, 14
    local gx = sx + math.floor((16 - GW) / 2)   -- zentriert (alte Box war 16 breit)
    local gy = sy + (24 - GH)                    -- unten-buendig (alte Box war 24 hoch)
    -- Bei sehr niedriger Opacity (<=10) die Box ganz weglassen -> nur der Name als Marker.
    if GHOST_OPACITY > 10 then
      if not GHOST_OUTLINE then
        drawRect(gx, gy, GW, GH, GHOST_FILL, true)  -- halbtransparente Fuellung (User-Farbe)
      end
      drawRect(gx, gy, GW, GH, GHOST_BORDER, false) -- Rahmen (User-Farbe)
    end
    emu.drawString(gx, gy - 9, ghPlayer, GHOST_NAME_COLOR, GHOST_NAME_BG)
  end
end

local function _rawOnFrame()
  -- Reload angefordert (L+R bei gleicher ROM): bis der ChallengeManager die Engine neu
  -- injiziert hat, keine Spiel-/Reset-Logik mehr ausfuehren (sonst doppelte Trigger im
  -- Wartefenster). Der Script-Neustart ersetzt diese Instanz ohnehin gleich komplett.
  if reloadPending then
    return
  end

  -- Musik-Mute (UI-Setting): Master-Musiklautstaerke pro Frame im SPC-RAM auf 0 halten (nur Musik;
  -- SFX schreiben ihre Voice-Volumes direkt und bleiben hoerbar). Fangt v.a. einen Musikwechsel
  -- mitten im Segment ab (Sublevel/Song-Init setzt $57 selbst auf $C0); die Resets ziehen den Wert
  -- ausserdem sofort nach dem Savestate-Load nach (siehe applyMusicMute).
  applyMusicMute()

  -- Input-Polling fuer Reset (siehe RESET_COMBO in games.lua). Im Replay zaehlt fuer die Combo
  -- der PHYSISCHE Stand des Zuschauers (nav, im inputPolled gelesen) - emu.getInput(0) liefert
  -- hier sonst die ABGESPIELTEN Tasten, ein im Lauf gehaltenes L+R wuerde das Replay resetten.
  local comboDown
  if REPLAY then
    comboDown = nav.combo
  else
    comboDown = comboHeld(emu.getInput(0) or {})
  end

  -- Reset-Combo waehrend des "GET READY"-Previews ignorieren: der Spieler haelt dort oft
  -- schon Tasten bereit, das soll keinen versehentlichen Restart ausloesen.
  if phase == "preview" then
    -- Waehrend des "GET READY"-Previews die Combo ignorieren UND den Latch NICHT anfassen: der
    -- Input ist hier geblankt (saehe faelschlich "losgelassen" aus). Wuerden wir hier entlatchen,
    -- loeste eine ueber die Preview gehaltene Combo danach sofort erneut aus (z. B. Practice-Fail-
    -- Preview, wo failOp in-script laeuft und resetLatched sonst ueberdauern muss).
  elseif comboDown then
    if not resetLatched and not resetNeedsRelease then
      resetHoldFrames = resetHoldFrames + 1
      if resetHoldFrames >= RESET_HOLD_FRAMES then
        resetHoldFrames = 0
        resetLatched = true              -- weiter gehalten zaehlt NICHT erneut (kein Blinken)
        flog(string.format("reset combo triggered: phase=%s busy=%s PRACTICE=%s", tostring(phase), tostring(busy), tostring(PRACTICE)))
        if PRACTICE then
          if not busy then busy = true; runInExec(failOp) end   -- Practice: Versuch neu starten
        else
          stream.onRunRestart(true)               -- Stream-Stats: bewusster Reset = neuer Versuch
          resetChallenge(true)                   -- bewusster Reset -> Settings frisch reinladen
        end
        return
      end
    end
  else
    resetHoldFrames = 0
    resetLatched = false                 -- Tasten losgelassen -> wieder scharf
  end

  -- Replay-Navigation: L = ein Segment zurueck, R = ein Segment vor (in jeder Phase, auch auf
  -- dem Endbildschirm). Ausgeloest wird beim LOSLASSEN, damit die Reset-Combo (Default L+R)
  -- weiter funktioniert: sobald beide Schultertasten zusammen gehalten werden, ist der Sprung
  -- fuer diesen Tastendruck abgeblockt und nur die Combo laeuft weiter.
  if REPLAY then
    if nav.l or nav.r then
      if nav.l and nav.r then
        nav.dir, nav.blocked = 0, true
      elseif not nav.blocked then
        nav.dir = nav.l and -1 or 1
      end
    else
      local dir = nav.blocked and 0 or nav.dir
      nav.dir, nav.blocked = 0, false
      if dir ~= 0 then
        nav.skip(segIdx + dir)             -- loadRom -> diese Instanz wird gleich ersetzt
        return
      end
    end
  end

  if phase == "init" then
    if not busy then
      busy = true
      local data = nil
      if seg.state then
        local ok = pcall(function()
          local f = assert(io.open(seg.state, "rb"))
          data = f:read("*a"); f:close()
        end)
        emu.log("read state " .. seg.state .. " -> " ..
                (ok and (#data .. " B") or "ERROR (File/IO?)"))
      end
      runInExec(function() dropInOp(data) end)
    end
    drawHud()

  elseif phase == "preview" then
    -- Standbild des Startframes halten, bis PREVIEW_FRAMES um sind. segFrames bleibt 0
    -- -> der Timer startet erst in der play-Phase. Gehaltene Inputs werden durchs Neuladen
    -- verschluckt -> der Spieler kann nur schauen/planen.
    if not busy and previewState then
      busy = true
      runInExec(function()
        pcall(emu.loadSavestate, previewState)
        busy = false
      end)
    end
    emu.clearScreen()
    drawHud()
    -- "GET READY" + Fortschrittsbalken, der sich ueber die Preview-Dauer FUELLT
    -- (leer -> voll). cdFrames wird erst weiter unten erhoeht, also passt der Stand hier.
    local grX, grText = 100, "GET READY"
    emu.drawString(grX, 100, grText, 0xFFFF00, 0x000000)
    local barLen = 20
    local filled = math.max(0, math.min(barLen, math.ceil(cdFrames / PREVIEW_FRAMES * barLen)))
    local barText = "[" .. string.rep("|", filled) .. string.rep(".", barLen - filled) .. "]"
    local sc = textScale / surfaceScale
    local grW = #grText * 6
    local barW = #barText * 3
    local barX = grX + (grW - barW) * sc / 2
    emu.drawString(barX, 112, barText, 0x00FF00, 0x000000)
    cdFrames = cdFrames + 1
    if cdFrames >= PREVIEW_FRAMES then
      phase = "go"
      goStuckFrames = 0
      if type(emu.muteAudio) == "function" then
        emu.muteAudio(false)
      end
      emu.log("Challenge: Preview done, Start Go Phase.")
      flog("preview done -> phase=go")
    end

  elseif phase == "go" then
    if not busy then
      busy = true
      runInExec(goOp)
    end
    goStuckFrames = goStuckFrames + 1
    if goStuckFrames == 120 then
      flog("WARNING: stuck in phase=go for 120 frames, busy=" .. tostring(busy) .. " (goOp callback never fired?)")
    end
    drawHud()

  elseif phase == "play" then
    segFrames = segFrames + 1
    if segFrames % 300 == 0 then
      local px, py = "?", "?"
      local ok = pcall(function()
        px = emu.read16(ghostAddrs.player_x, MEM)
        py = emu.read16(ghostAddrs.player_y, MEM)
      end)
      flog(string.format("play heartbeat: segFrames=%d player=(%s,%s)", segFrames, tostring(px), tostring(py)))
    end
    if spikeMode == "record" then
      ghostPush(emu.read16(ghostAddrs.player_x, MEM),
                emu.read16(ghostAddrs.player_y, MEM),
                ghostAddrs.room and emu.read(ghostAddrs.room, MEM) or 0)
    end
    -- Gegner-Zaehler fortschreiben. MUSS vor dem done-Check laufen, damit ein "toete X
    -- Gegner"-Segment im selben Frame fertig werden kann, in dem der letzte Kill passiert.
    local killed = kills.update()
    if killed > 0 then
      stream.onKill(killed)                   -- Stream-Stats (gedrosselt, s. Modul)
    end
    if anyCondMet(doneList, baseDone) then
      if spikeMode == "record" then
        local ok, err = pcall(saveRecordedInputs, SPIKE_FILE, segFrames)
        if not ok then
          flog("ERROR in saveRecordedInputs: " .. tostring(err))
        end
        -- PB-Ghost speichern, wenn dieser Lauf ein neuer Segment-PB ist (oder noch keiner existiert).
        local pbGhostPath = SCRIPT_DIR .. "recordings/pb_seg" .. math.floor(segIdx) .. ".ghost"
        local prevPB = pbSeg[seg.name]
        local existing = io.open(pbGhostPath, "r")
        if existing then existing:close() end
        if (not prevPB) or (segFrames < prevPB) or (not existing) then
          local gok, gerr = pcall(saveRecordedGhost, pbGhostPath)
          if not gok then flog("ERROR in saveRecordedGhost: " .. tostring(gerr)) end
        end
      end
      if PRACTICE then
        practiceClears = practiceClears + 1
        practiceTimes[#practiceTimes + 1] = segFrames
        if not practiceBest or segFrames < practiceBest then practiceBest = segFrames end
        practiceArmed = false
        phase = "pdone"
      else
        local ok, err = pcall(completeSegment)
        if not ok then
          flog("ERROR in completeSegment: " .. tostring(err))
        end
      end
    elseif not busy and anyCondMet(failList, baseFail) then
      -- Auto-Reset (UI-Setting, s. AUTO_RESET oben): statt nur den Segment-Save neu zu laden,
      -- startet der GANZE Lauf neu - in "always" bei jedem Fail, in "first" nur in Segment 1.
      -- Kommt vor dem normalen failOp-Pfad und return-t, hat also Vorrang.
      if not PRACTICE and not REPLAY and (AUTO_RESET == "always" or (AUTO_RESET == "first" and segIdx == 1)) then
        stream.onDeath()                        -- Stream-Stats: Tod zaehlen ...
        stream.onRunRestart(false)              -- ... und der ganze Lauf startet neu
        resetChallenge(false)
        return
      end
      busy = true
      retries = retries + 1
      stream.onDeath()                          -- Stream-Stats: Tod/Segment-Neustart zaehlen
      runInExec(failOp)
    end
    if GHOST_SHOW then drawGhost() end
    drawHud()

  elseif phase == "done" then
    -- Auf dem finalen Done-Screen: START sendet das Ergebnis an die Bestenliste (jeder
    -- abgeschlossene Lauf, nicht nur neue Gesamt-PBs).
    if segIdx == #segments then
      -- START submits the run. A failed submit (submitState "done" + not ok, e.g. the
      -- player wasn't logged in with Twitch) is retryable: the done screen is still up
      -- and the run isn't lost, so after logging in via Challenge > Settings the player
      -- can press START again to re-send it.
      if submitState == "idle" or (submitState == "done" and not submitOk) then
        if physicalStartPressed then
          if not startLatched then
            startLatched = true
            if writeSubmitRequest() then
              submitState = "sent"
            end
          end
        else
          startLatched = false
        end
      elseif submitState == "sent" then
        submitPollFrames = submitPollFrames + 1
        if submitPollFrames >= 15 then      -- ~4x/s statt 60x/s: Result-Datei seltener oeffnen
          submitPollFrames = 0
          pollSubmitResult()                -- wird "done", sobald der ChallengeManager geantwortet hat
        end
      end

      -- SELECT exportiert den gerade beendeten Lauf (lokal, unabhaengig vom Submit).
      -- Edge-getriggert; nach dem Druck kurz eine Bestaetigung, dann wieder erneut moeglich.
      if exportFlashFrames > 0 then exportFlashFrames = exportFlashFrames - 1 end
      if not REPLAY then
        if physicalSelectPressed then
          if not selectLatched then
            selectLatched = true
            if writeExportRequest() then exportFlashFrames = 180 end
          end
        else
          selectLatched = false
        end
      end
    end
    drawHud()

  elseif phase == "pdone" then
    -- Practice-Ergebnis-Screen: eine beliebige Nicht-Richtungstaste startet den naechsten
    -- Versuch. Erst nach Loslassen scharfschalten, damit der gehaltene Sprung vom Clear
    -- nicht sofort neu startet. Der Tastendruck wird im inputPolled-Callback gelesen
    -- (pdoneButtonHeld) - hier im startFrame ist der Input geblankt (pdone blockt Eingaben).
    if not pdoneButtonHeld then
      practiceArmed = true
    elseif practiceArmed and not busy then
      practiceArmed = false
      busy = true
      runInExec(failOp)                     -- failOp setzt im Practice phase zurueck auf "play"
    end
    drawHud()
  end
end

local _onFrameErrLogged = false
local function onFrame()
  local ok, err = pcall(_rawOnFrame)
  if not ok and not _onFrameErrLogged then
    _onFrameErrLogged = true
    flog("ERROR in onFrame: " .. tostring(err))
  end
end

emu.addEventCallback(onFrame, emu.eventType.startFrame)

-- Nach dem letzten Segment: Eingaben blockieren, damit man nicht weiterspielen
-- kann. Das Spiel laeuft normal weiter -> Musik bleibt an, kein Sound-Brummen.
-- Die Reset-Combo wird durchgelassen (sonst kein Restart vom Done-Screen).
emu.addEventCallback(function()
  -- Physische Reset-Combo VOR jeglichem Blanken lesen: nach einem Combo-Reset (Skript-Neustart)
  -- verlangt resetNeedsRelease erst eine echte Freigabe, bevor wieder ausgeloest werden kann.
  -- Muss hier (inputPolled) passieren, nicht im startFrame - dort ist der Input in preview/pdone/
  -- done bereits geblankt und saehe faelschlich "losgelassen" aus.
  local phys = emu.getInput(0) or {}
  if resetNeedsRelease and not comboHeld(phys) then
    resetNeedsRelease = false
  end

  -- Replay-Navigation: den PHYSISCHEN Stand hier festhalten - weiter unten ersetzt die
  -- Aufnahme den Input (play) bzw. wird er geblankt (preview/done). Im startFrame-Callback
  -- saehe emu.getInput(0) im Replay die abgespielten Tasten, nicht den Zuschauer.
  if REPLAY then
    nav.l, nav.r, nav.combo = phys.l or false, phys.r or false, comboHeld(phys)
  end

  -- Spike: record/replay during play phase
  if phase == "play" then
    spikePollCounter = spikePollCounter + 1
    if spikeMode == "replay" then
      local v = spikeInputs[spikePollCounter]
      if v then
        emu.setInput(unpackInto(replayInput, v), 0)   -- entpackt in eine wiederverwendete Tabelle
      else
        emu.setInput(BLANK_INPUT, 0)
      end
    elseif spikeMode == "record" then
      recordPush(packInput(emu.getInput(0) or {}))    -- gepackt + RLE, kein Pro-Frame-Alloc
    end
  end

  -- Waehrend des "GET READY"-Previews Eingaben blocken. Das Bild ist per Savestate-Reload eh
  -- eingefroren; so kann der Spieler in Ruhe die Inputs planen, ohne dass etwas durchschlaegt.
  if phase == "preview" then
    emu.setInput(BLANK_INPUT, 0)
    return
  end

  -- Practice-Ergebnis-Screen: physischen Controller HIER lesen (vor dem Blanken) und den
  -- Restart-Tastendruck merken; im startFrame ist der Input danach geblankt. Dann Eingaben
  -- blocken, damit das Level im Hintergrund still steht.
  if PRACTICE then
    if phase == "pdone" then
      local input = emu.getInput(0) or {}
      pdoneButtonHeld = input.a or input.b or input.x or input.y
                        or input.l or input.r or input.select or input.start or false
      emu.setInput(BLANK_INPUT, 0)
    else
      pdoneButtonHeld = false
    end
    return
  end
  if phase == "done" and segIdx == #segments then
    local input = emu.getInput(0) or {}
    physicalStartPressed = input.start
    physicalSelectPressed = input.select
    if not comboHeld(input) then
      emu.setInput(BLANK_INPUT, 0)
    end
  else
    physicalStartPressed = false
    physicalSelectPressed = false
  end
end, emu.eventType.inputPolled)

-- Stream-Overlay: einmalig beim Skriptstart den aktuellen Stand rausschreiben (auch nach jedem
-- Segment-Neustart), damit das Overlay Records/Segment sofort zeigt - nicht erst nach dem 1. Event.
stream.init()
