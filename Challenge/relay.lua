--==================================================================
--  Game Relay - Mesen "Special" (custom build with emu.loadRom + persist)
--------------------------------------------------------------------
--  Multi-game relay in ONE Lua script: switches ROMs via emu.loadRom,
--  and carries progress via emu.setPersist/getPersist across the script
--  restarts triggered by ROM changes.
--
--  Savestate functions (createSavestate/loadSavestate) may only run
--  inside an exec memory callback -> hence the runInExec() helper.
--
--  >> On the FIRST run, verify in the script log:
--     (1) After ROM change, "Relay instance: Segment 2/.." appears
--         (= script restart after loadRom works, the core mechanism)
--     (2) "loadSavestate -> OK" (= level drop-in works)
--==================================================================

------------------------------- CONFIG -------------------------------
-- Determines the path to the script directory.
local function getScriptDir()
  -- When the engine is loaded embedded via ChallengeManager, the challenge
  -- directory is injected as a global variable __CHALLENGE_DIR (there is no
  -- relay.lua file on disk that could be found here in that case).
  if type(__CHALLENGE_DIR) == "string" and #__CHALLENGE_DIR > 0 then
    local d = __CHALLENGE_DIR:gsub("\\", "/")
    if not d:match("/$") then d = d .. "/" end
    return d
  end

  -- Find the filename of this script (e.g. "relay.lua")
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local scriptName = source:match("([^/\\]+)$") or "relay.lua"

  -- Search package.path for the directory containing the script
  for path in string.gmatch(package.path, "[^;]+") do
    local dir = path:match("(.*)[/\\]%?%.lua$") or path:match("(.*)[/\\]%?[/\\]init%.lua$")
    if dir then
      dir = dir:gsub("\\", "/")
      if not dir:match("/$") then dir = dir .. "/" end
      -- Check if the script file exists in this directory
      local f = io.open(dir .. scriptName, "r")
      if f then
        f:close()
        return dir
      end
    end
  end

  -- Fallback if the search fails
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
end


-- Load configuration from games.lua
local challengeConfig = dofile(SCRIPT_DIR .. "games.lua")
local CHALLENGE = challengeConfig.challenge or "Kaizo Challenge #1"
local segments = challengeConfig.segments
-- Reset combo: the user can override it in Challenge Settings (__RESET_BUTTONS,
-- e.g. "l,r" or "select"). If none is injected, the challenge's resetCombo or default
-- applies. Buttons are emu.getInput() keys (a,b,x,y,l,r,select,start,up,down,left,right).
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
-- Hold duration until reset: per setting either tap (1 frame) or classic ~0.5s (30 frames).
local RESET_HOLD_FRAMES = (type(__RESET_HOLD_FRAMES) == "number" and __RESET_HOLD_FRAMES >= 1)
  and math.floor(__RESET_HOLD_FRAMES) or 30

-- Stable challenge ID for the leaderboard (matches server-side validation rules).
-- Prefers the explicit "id" field from games.lua; otherwise a slug is derived
-- from the display name.
local function slugify(s)
  s = tostring(s or ""):lower()
  s = s:gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if #s == 0 then s = "challenge" end
  return s
end
local CHALLENGE_ID = challengeConfig.id or slugify(CHALLENGE)

-- Version stamp for recording headers (injected from C#): which emulator core and engine
-- produced this run. Written only, not checked - a recording from another build might
-- desync, but a warning is only useful once recordings actually carry these fields.
-- Older recordings do not have them; readers must handle them optionally.
local EMU_VERSION    = (type(__EMU_VERSION) == "string" and __EMU_VERSION) or ""
local ENGINE_VERSION = (type(__ENGINE_VERSION) == "string" and __ENGINE_VERSION) or ""

-- Forward declarations for scope sharing
local PRACTICE = false
local segIdx = 1
local getP, setP

-- ==========================================
-- AP14 REPLAY MODE & RECORD SYSTEM
-- ==========================================
local REPLAY = __REPLAY_DIR ~= nil
-- Name of the player whose run is being replayed (injected by ChallengeManager from the
-- replay header). Only used for display in the replay HUD.
local REPLAY_PLAYER = (type(__REPLAY_PLAYER) == "string" and #__REPLAY_PLAYER > 0) and __REPLAY_PLAYER or nil
local BLANK_INPUT = {
  up = false, down = false, left = false, right = false,
  a = false, b = false, x = false, y = false,
  l = false, r = false, select = false, start = false
}

local SPIKE_FILE = ""
local spikeMode = "record" -- "record" or "replay"
local spikeInputs = {}          -- Replay: packed input value per poll (expanded from RLE)
local spikePollCounter = 0
local replayInput = {}          -- Reused table for setInput in replay (no per-frame alloc)

local btnKeys = {"up", "down", "left", "right", "a", "b", "x", "y", "l", "r", "select", "start"}
local btnChars = {
  up="u", down="d", left="l", right="r",
  a="A", b="B", x="X", y="Y",
  l="L", r="R", select="s", start="S"
}

-- 12 buttons <-> packed integer (bit i = btnKeys[i]). Done arithmetically (no <<)
-- so it works regardless of Lua version; v remains an integer.
local function packInput(input)
  local v, bit = 0, 1
  for i = 1, #btnKeys do
    if input[btnKeys[i]] then v = v + bit end
    bit = bit * 2
  end
  return v
end
-- Writes the 12 buttons from a packed integer into a (reusable) table.
local function unpackInto(tbl, v)
  local bit = 1
  for i = 1, #btnKeys do
    tbl[btnKeys[i]] = math.floor(v / bit) % 2 == 1
    bit = bit * 2
  end
  return tbl
end

-- ---- Recording: RLE over packed values ------------------------------------------
-- Instead of holding a raw input table per frame (~550 B/frame, GC load on long
-- segments), a packed 12-bit value per frame is RLE-encoded: a new run is only started
-- when input changes. Numbers reside inline in arrays -> virtually zero per-frame alloc.
local recVals = {}     -- Run values (packed)
local recRuns = {}     -- Run lengths
local recCurVal = nil  -- Current active run
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

-- Loads the recording into spikeInputs as PACKED values (one entry per poll). Supports
-- the current RLE format (GINP2, lines "<hex3>*<count>") and the legacy line format (GINP1,
-- 12-char string per poll), so replays created before the change continue to work.
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
      if hexv then                                   -- GINP2: packed value + run length
        local v = tonumber(hexv, 16)
        for _ = 1, tonumber(cnt) do
          spikeInputs[#spikeInputs + 1] = v
        end
      elseif #line >= 12 then                        -- GINP1 (legacy): 12-char string
        spikeInputs[#spikeInputs + 1] = packInput(deserializeInput(line))
      end
    end
  end
  f:close()
end

-- ---- Replay navigation (L = previous segment, R = next segment) --------------------
-- State AND helpers reside intentionally in ONE table: relay.lua is close to Lua's limit
-- of 200 file-scope locals (see comment on stream module), so navigation costs just 1 local.
-- l/r/combo is filled in inputPolled callback from the PHYSICAL controller (in replay, the
-- recording replaces input afterwards), and evaluated in onFrame.
--   dir     = queued direction (-1/1), executed on release
--   blocked = blocked for this button press (both shoulder buttons = reset combo)
local nav = { l = false, r = false, combo = false, dir = 0, blocked = false }

-- Segment length from recording header. "frames=" is the true segment time; older
-- replays (prior to this line) fall back to "polls=" - with 1 poll/frame that is the
-- exact same number; for multi-polling games it is only an approximation for the HUD.
nav.frames = function(idx)
  if not REPLAY then return nil end
  local f = io.open(__REPLAY_DIR .. "seg" .. math.floor(idx) .. ".inputs", "r")
  if not f then return nil end
  local frames, polls
  for line in f:lines() do
    if line == "" or line:match("^%s*$") then break end   -- Empty line = end of header
    frames = tonumber(line:match("^frames=(%d+)")) or frames
    polls  = tonumber(line:match("^polls=(%d+)")) or polls
  end
  f:close()
  return frames or polls
end

-- Writes the RLE recording (GINP2). The current active run is finalized before writing.
-- frames = segment time in frames; stored in header so replay navigation (L/R) when
-- skipping can reconstruct total time and splits for skipped segments.
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
    f:write("emu=" .. EMU_VERSION .. "\n")
    f:write("engine=" .. ENGINE_VERSION .. "\n")
    f:write("\n") -- Empty line separating header from data
    for i = 1, #recVals do
      f:write(string.format("%03X*%d\n", recVals[i], recRuns[i]))
    end
    f:close()
  end
end

-- ==========================================
-- LIVE GHOST (position log)
-- ==========================================
-- Optional semi-transparent PB ghost. Records WORLD position per play frame (+ room ID);
-- rendered relative to the LIVE camera. This keeps the ghost aligned even with speed
-- differences: if you are faster, the ghost scrolls out of view behind you (lower world X).
-- SMW defaults; overridable per segment via seg.ghost (retro games). Persistent PB ghost:
-- recordings/pb_seg<idx>.ghost. Room matching is coarse (translevel) and can be refined
-- via seg.ghost.room (address) or disabled with room=false.
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
-- Opacity (0..100, user-selectable): 100 = fully visible, low = faint. NOTE: Mesen
-- INVERTS the alpha byte in drawRectangle (0 = opaque, 255 = transparent - see
-- DrawRectangleCommand.h). Therefore calculate in "visibility" and pass (255 - visibility)
-- so a HIGHER slider value = more visible. Fill is ~0.42x as opaque as border
-- (translucent body + solid outline).
local GHOST_OPACITY = (type(__GHOST_OPACITY) == "number") and math.max(0, math.min(100, math.floor(__GHOST_OPACITY))) or 30
local ghBorderVis = math.floor(255 * GHOST_OPACITY / 100 + 0.5)   -- Target border opacity
local ghFillVis   = math.floor(ghBorderVis * 0.42 + 0.5)          -- Fill fainter than border
local GHOST_FILL   = (255 - ghFillVis)   * 0x1000000 + GHOST_RGB  -- Pass inverted byte to Mesen
local GHOST_BORDER = (255 - ghBorderVis) * 0x1000000 + GHOST_RGB
-- Name label with its OWN opacity (setting __GHOST_NAME_OPACITY, independent of body above):
-- keeps the name readable even when ghost body is very faint - or fades as well. Same
-- inverted alpha semantics as above (drawString inverts alpha byte just like drawRectangle,
-- see DrawStringCommand.h). The black shadow (bg) fades with the same opacity so a solid
-- black box does not remain behind a faded name.
-- Default 100 -> ghNameVis 255 -> byte 0 -> fully opaque = exact previous behaviour.
local GHOST_NAME_OPACITY = (type(__GHOST_NAME_OPACITY) == "number") and math.max(0, math.min(100, math.floor(__GHOST_NAME_OPACITY))) or 100
local ghNameVis = math.floor(255 * GHOST_NAME_OPACITY / 100 + 0.5)
local GHOST_NAME_COLOR = (255 - ghNameVis) * 0x1000000 + GHOST_RGB
local GHOST_NAME_BG    = (255 - ghNameVis) * 0x1000000            -- Black shadow, same opacity
-- Outline only (setting): draw only the border, no fill.
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

-- ==========================================
-- AUTO RESET ON DEATH - death detection
-- ==========================================
-- Dedicated death check for "Auto Reset on Death" (UI setting): ONLY checked per play
-- frame when the setting is enabled; if matched, the ENTIRE run restarts (see
-- resetChallenge). Intentionally INDEPENDENT of the games.lua "fail" condition (which only
-- reloads the segment and can be arbitrarily configured). SMW default: player animation $0071 == 9
-- (death animation). This is SMW specific! Overridable per segment via seg.death (retro
-- games), or seg.death=false to disable for that segment (e.g. retro segments in a
-- mixed challenge).
local DEATH_DEFAULT = { addr = 0x0071, value = 0x09, size = 1 }
local deathCheck = DEATH_DEFAULT
local function resolveDeathCheck(s)
  local o = s and s.death
  if o == false then return nil end               -- Disabled for this segment
  if type(o) ~= "table" then return DEATH_DEFAULT end
  return { addr = o.addr or DEATH_DEFAULT.addr, value = o.value or DEATH_DEFAULT.value, size = o.size or 1 }
end

-- ==========================================
-- MUTE MUSIC - "Mute music (keep sound effects)"
-- ==========================================
-- UI setting (injected by ChallengeManager via __MUTE_MUSIC): forces the N-SPC/AddmusicK
-- master music volume in SPC RAM to 0 every frame. This affects ONLY music (all 8 channels
-- run through this master multiplier); sound effects write their DSP voice volumes directly
-- and bypass it -> SFX remain fully audible (replaces the old mixer-channel approach,
-- which missed channels 7/8 = music and muted SFX on channels 1-6). Pure SPC RAM write
-- without emulation/timing impact -> fair/replay-neutral. No restore needed: when mute is
-- disabled, we do not poke, and the sound engine (or fresh savestate on settings reload)
-- maintains normal volume ($C0). SMW/AMK default address $0057; overridable per segment via
-- seg.music_mute={addr=..} (retro games with different sound engine) or seg.music_mute=false
-- to disable for that segment.
local MUTE_MUSIC = (__MUTE_MUSIC == true)
local MUSIC_MUTE_DEFAULT = { addr = 0x0057 }
local musicMuteAddr = MUSIC_MUTE_DEFAULT
local function resolveMusicMute(s)
  local o = s and s.music_mute
  if o == false then return nil end               -- Disabled for this segment
  if type(o) ~= "table" then return MUSIC_MUTE_DEFAULT end
  return { addr = o.addr or MUSIC_MUTE_DEFAULT.addr }
end

-- Sets master music volume in SPC RAM to 0 (no-op if mute disabled / turned off for segment).
-- Called in two places: (1) immediately AFTER every savestate load (dropInOp/goOp/failOp) -
-- the loaded state carries normal volume ($C0), which would otherwise un-mute music for 1 frame;
-- (2) per frame in onFrame, so music changes mid-segment (sublevel/song init setting $57 to $C0)
-- are silenced again immediately.
local function applyMusicMute()
  if MUTE_MUSIC and musicMuteAddr then
    pcall(emu.write, musicMuteAddr.addr, 0, emu.memType.spcMemory)
  end
end

-- Recording buffer (one position per play frame)
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
  f:write("emu=" .. EMU_VERSION .. "\n")
  f:write("engine=" .. ENGINE_VERSION .. "\n")
  f:write("\n")
  for i = 1, ghRecN do
    f:write(ghRecX[i] .. "," .. ghRecY[i] .. "," .. ghRecRoom[i] .. "\n")
  end
  f:close()
end

-- Display buffer (loaded PB ghost)
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
  -- Resolve auto-reset death check for this segment (SMW default, overridable via seg.death).
  deathCheck = resolveDeathCheck(segments[math.floor(segIdx)])
  -- Resolve music mute address for this segment (SMW/AMK default $0057, overridable via seg.music_mute).
  musicMuteAddr = resolveMusicMute(segments[math.floor(segIdx)])
  -- Ghost: resolve addresses for this segment, clear recording buffer, load PB ghost.
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

-- Resolve paths in segments (make relative to GAMES directory)
for _, seg in ipairs(segments) do
  if seg.rom and not seg.rom:match("^[A-Za-z]:") and not seg.rom:match("^/") then
    seg.rom = GAMES .. seg.rom
  end
  if seg.state and not seg.state:match("^[A-Za-z]:") and not seg.state:match("^/") then
    seg.state = GAMES .. seg.state
  end
end

-- Debug output: log segments, order and paths
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
  -- Injected player name from ChallengeManager (from Challenge Settings) takes precedence.
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

local PLAYER    = getPlayerName()  -- Player name (read from player_name.txt if present)
-- Preview: before each segment start (and each practice attempt), the start frame
-- is displayed frozen for PREVIEW_FRAMES frames BEFORE gameplay + timer start, so
-- the player can prepare their inputs. Injected by ChallengeManager via __PREVIEW_FRAMES
-- (Challenge Settings). 0 = off (start immediately). Replaces old countdown.
local PREVIEW_FRAMES = (type(__PREVIEW_FRAMES) == "number") and math.max(0, math.floor(__PREVIEW_FRAMES)) or 60
-- Setting "Get Ready after Death": after a fail condition, PAUSE segment timer and
-- display GET READY frozen frame, then resume play (timer continues from old value -
-- death still costs the elapsed time, only pause duration is free).
-- Irrelevant for replays: polls are counted only in play phase (record AND replay),
-- so pause is invisible in input log - hence disabled in replay mode.
local FAIL_PREVIEW = (__FAIL_PREVIEW == true) and (not REPLAY)
-- goOp: do NOT reset timer (fail preview resumes attempt instead of restarting)
local failPreviewPending = false
local FPS       = 60.0988
local RESULT_FILE = GAMES .. "relay_result.txt"

-- File IPC with C# ChallengeManager for leaderboard submit:
-- On done screen, engine writes SUBMIT_REQUEST on START press; ChallengeManager
-- signs (HMAC) and sends result, writing outcome to SUBMIT_RESULT which engine
-- displays.
local SUBMIT_REQUEST = SCRIPT_DIR .. "submit_request.txt"
local SUBMIT_RESULT  = SCRIPT_DIR .. "submit_result.txt"

-- Export IPC: on done screen, engine writes EXPORT_REQUEST on SELECT press; ChallengeManager
-- bundles completed run (inputs + ghosts) into .creplay and opens save dialog.
-- Purely local, no login/network required (unlike submit).
local EXPORT_REQUEST = SCRIPT_DIR .. "export_request.txt"

-- Settings reload IPC: a reset on SAME ROM writes RELOAD_REQUEST; ChallengeManager
-- re-injects engine (with __FORCE_RESET) and rebuilds header from CURRENT config ->
-- changed Challenge Settings take effect immediately without full restart.
-- Persist store survives script reload, so the signal suffices.
-- On ROM change, no extra signal is needed: emu.loadRom triggers re-injection
-- with fresh settings anyway.
local RELOAD_REQUEST = SCRIPT_DIR .. "reload_request.txt"
local function writeReloadRequest()
  local ok, err = pcall(function()
    local f = assert(io.open(RELOAD_REQUEST, "w"))
    f:write("reload\n")                      -- Content does not matter; signal only
    f:close()
  end)
  emu.log("Reload-Request -> " .. (ok and RELOAD_REQUEST or ("ERROR: " .. tostring(err))))
  return ok
end

-- ---- Personal Bests (local: per segment + total) ----------------
-- Displayed via "Show Personal Bests" in challenge menu (injected as __SHOW_PBS).
-- PBs are ALWAYS tracked (even when display is off), so they exist as soon as
-- enabled. Stored locally in pb.txt in challenge folder.
local SHOW_PBS = (__SHOW_PBS == true)

-- Individually toggleable live HUD elements (injected by ChallengeManager via __HUD_SEGMENT/__HUD_DELTA
-- from Challenge Settings). If missing (older UI), defaults to "on" (~= false).
-- SHOW_SEGMENT hides segment counter + name, SHOW_DELTA hides running +/- against segment PB
-- (only active with SHOW_PBS and existing PB).
local SHOW_SEGMENT = (__HUD_SEGMENT ~= false)
local SHOW_DELTA   = (__HUD_DELTA ~= false)

-- Auto Reset on Death (injected by ChallengeManager via __AUTO_RESET_ON_DEATH): when enabled,
-- checks a dedicated death condition per play frame (deathCheck, SMW default $0071==9); if matched,
-- the ENTIRE run restarts from Segment 1 (counted as attempt) instead of just segment.
-- Independent of games.lua "fail" condition. SMW specific (see DEATH_DEFAULT / seg.death);
-- default off. No effect in practice mode (where failOp already restarts attempt).
local AUTO_RESET_ON_DEATH = (__AUTO_RESET_ON_DEATH == true)

-- HUD size (injected by ChallengeManager via __HUD_SS: 1 = Big, 2 = Normal, 3 = Small, 4 = Smaller).
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

-- Big (surfaceScale=1): start at y=12 with 10px spacing (original values, overscan safe).
-- Scaled modes: start at y=2 with 8px spacing (wrapper handles overscan offset).
local hudStartY  = surfaceScale == 1 and 12 or 2
local hudLineGap = surfaceScale == 1 and 10 or 8
local function hudLineY(n) return hudStartY + n * hudLineGap end
local function hud(x, lineIdx, text, color, bg)
  emu.drawString(x, hudLineY(lineIdx), text, color or 0xFFFFFF, bg or 0x000000)
end

local PB_FILE  = SCRIPT_DIR .. "pb.txt"
local pbSeg    = {}    -- [segment name] = best frames
local pbTotal  = nil   -- Best total run in frames
local prevTotalPB  = nil    -- Total PB BEFORE this run (for comparison on done screen)
local isNewTotalPB = false  -- Did THIS run set a new total PB? (display only)

local function loadPBs()
  pbSeg, pbTotal = {}, nil
  local f = io.open(PB_FILE, "r")
  if not f then return end
  for line in f:lines() do
    -- Read frames leniently as number (including "6213.0"): older builds wrote the
    -- total across persist roundtrip as a float, which the earlier
    -- "%d+" pattern could not load (-> pbTotal was always nil and
    -- each run was falsely considered a new PB). Normalize to integer frames.
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
  -- Always write as integer (no "6213.0"): the persist roundtrip may convert
  -- total into a float; otherwise loadPBs() fails to load it back.
  if pbTotal then f:write("total;" .. math.floor(pbTotal) .. "\n") end
  f:close()
end

-- ---- Attempt counter (across total play history, survives segment reloads) ---
-- An "attempt" = an intentional restart of the ENTIRE challenge on Segment 1 (reset
-- combo). A death mid-segment only reloads segment save (see failOp) and does
-- NOT count as a new attempt. Sent as "tries" during submit so the
-- server shows the actual attempt count rather than a simple submission counter.
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

-- Sets segment PB (local display) if faster. Server-side segment PBs are
-- NOT pushed from here, but derived on run submit from the run splits
-- (from trusted core persist, not from pb.txt) - see submit handler.
local function updateSegmentPB(name, frames)
  if REPLAY then return false end
  local prev = pbSeg[name]
  if not prev or frames < prev then
    pbSeg[name] = frames
    savePBs()
    return true            -- New segment PB (for stream stats: pbs++)
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
  -- Fail = $08C2 Bit 13 (0x2000, death/damage drop) - verify in-game.
  -- Level-Clear = $08C2 Bit 1 (0x0002, level transition/fadeout) - verify in-game.
  { name = "DKC2 - Pirate Panic", rom = "DKC2 - Pirate Panic.smc",
    state = "states/DKC2 - Pirate Panic.state",
    done = { addr = 0x08C2, op = "anybits", value = 0x0002, size = 2 },
    fail = { addr = 0x08BE, op = "decreased", size = 2 } },
--]]
----------------------------- END CONFIG -----------------------------

local MEM = emu.memType.snesWorkRam
local EXEC_S, EXEC_E, CPU = 0x000000, 0xFFFFFF, emu.cpuType.snes

-- ==========================================
-- ENEMY COUNTER ("kills") - per segment
-- ==========================================
-- Counts enemies defeated by the player per attempt. Based on the SMW sprite status
-- table $14C8 (12 slots, 1 byte per slot) scanned every play frame: when a slot transitions
-- from an ALIVE status (08 normal, 09 stunned/carryable, 0A kicked, 0B carried) to a DEAD
-- status (02 tossed, 03 squished, 04 spinjump kill, 05 burned in lava), that counts as a
-- kill. Enemies swallowed by Yoshi (07 -> 00) also count. A slot transitioning from alive
-- to 00 does NOT count - that is standard despawn at screen edge.
--
-- The counter is ATTEMPT-local (death/segment restart resets it to 0 because savestate
-- brings enemies back). Additionally, a total run counter runs concurrently (persisted
-- as "kills_total", surviving ROM switches between segments) for stream stats;
-- this also counts kills from failed attempts.
--
-- games.lua, per segment (all optional):
--   kills = false                     -- Disable counter for this segment (e.g. retro games)
--   kills = { addr = 0x14C8, slots = 12, stride = 1, label = "Enemies", show = true,
--             alive = { 0x08, 0x09, 0x0A, 0x0B }, dead = { 0x02, 0x03, 0x04, 0x05 },
--             yoshi = true }          -- Count 07 -> 00 (swallowed by Yoshi)
-- Target segment ("defeat X enemies"):
--   done = { kills = 10 }             -- Shorthand for { counter = "kills", op = "atleast", value = 10 }
--
-- NOTE: Module resides in ONE IIFE - relay.lua is near Lua's 200 file-scope locals limit,
-- HINT: Module resides in ONE IIFE - relay.lua is near Lua's limit of 200 file-scope locals,
-- so this entire counter costs only a single local variable.
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
    if o == false then return nil end                 -- Disabled for this segment
    if type(o) ~= "table" then o = {} end
    return {
      addr   = o.addr   or DEF.addr,
      slots  = o.slots  or DEF.slots,
      stride = o.stride or DEF.stride,
      label  = o.label  or DEF.label,
      show   = o.show,                                -- nil = automatic (only with target)
      yoshi  = (o.yoshi ~= false),
      alive  = toSet(o.alive or DEF.alive),
      dead   = toSet(o.dead  or DEF.dead),
    }
  end

  return {
    -- Call on every segment change (including in-memory reset): applies segment configuration
    -- and reads target from "counter" conditions in done list.
    bind = function(s, doneL)
      cfg = build(s and s.kills)
      target = nil
      if cfg then
        if type(s) == "table" and type(s.kills) == "table" and s.kills.target then
          target = s.kills.target                      -- Display only (target without done condition)
        end
        for _, c in ipairs(doneL or {}) do
          if c.counter == "kills" and c.value then target = c.value end
        end
      end
      runTotal = tonumber(getP("kills_total", 0)) or 0
      prev = {}
      n = 0
    end,
    -- New attempt (savestate load): reset slot snapshot and attempt counter.
    resetAttempt = function()
      prev = {}
      n = 0
    end,
    -- New run: reset total run kill counter as well.
    resetRun = function()
      runTotal = 0
      setP("kills_total", 0)
    end,
    -- Per play frame: scan status table and count new kills. Returns kills
    -- for this frame (0 if none occurred).
    update = function()
      if not cfg then return 0 end
      local got = 0
      for i = 0, cfg.slots - 1 do
        local st = emu.read(cfg.addr + i * cfg.stride, MEM)
        local p = prev[i]
        if p then
          if cfg.alive[p] and cfg.dead[st] then
            got = got + 1
          elseif cfg.yoshi and p == 0x07 and st == 0x00 then   -- Swallowed by Yoshi
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
    -- Show HUD line? Always with target, otherwise only if kills.show = true.
    visible  = function()
      if not cfg then return false end
      if cfg.show ~= nil then return cfg.show == true end
      return target ~= nil
    end,
  }
end)()

-- ---- Helpers -------------------------------------------------------
local function read_addr(d)
  -- Virtual "address": conditions can read the kill counter instead of RAM
  -- ({ counter = "kills", op = "atleast", value = 10 }). All ops function
  -- identically - baseline at attempt start is always 0.
  if d.counter then
    if d.counter == "kills" then return kills.get() end
    return 0
  end
  local sz = d.size or 1
  if     sz == 1 then return emu.read(d.addr,  MEM)
  elseif sz == 2 then return emu.read16(d.addr, MEM)
  -- 3-byte (e.g. Mario score $0F34-$0F36): no read24 exists - read 32-bit and mask out
  -- the extra high byte (at $0F34 that is Luigi's score low byte).
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
  -- Baseline-relative: "increased/decreased by at least value since attempt start".
  -- Used for e.g. "collect X coins" (increasedby) regardless of coin count at segment start.
  elseif op == "increasedby" then return cur >= baseline + (d.value or 1)
  elseif op == "decreasedby" then return cur <= baseline - (d.value or 1)
  -- Bitmasks (value = mask, NOT baseline-relative): for games with flag bytes, e.g.
  -- DKC2 $08C2 (death = bit 13 = 0x2000, level fadeout = bit 1 = 0x0002). For >8 bits,
  -- set size = 2, otherwise only low byte is read. (Lua 5.4 bitwise operators.)
  elseif op == "anybits"   then return (cur & (d.value or 0)) ~= 0
  elseif op == "allbits"   then return (cur & (d.value or 0)) == (d.value or 0)
  elseif op == "nobits"    then return (cur & (d.value or 0)) == 0
  end
  return false
end

-- "done"/"fail" in games.lua accept ONE condition ({ addr=.., op=.. }) OR
-- a LIST of conditions ({ { addr=.., op=.. }, { .. }, .. }) - triggered as soon
-- as ANY of them matches (OR logic). Intended especially for fail: e.g. death OR
-- start+select exit should both restart the segment (without resetting total time).
-- RAM addresses and trigger conditions can be configured per game engine.
-- In addition, shorthand { kills = N } ("defeat N enemies") normalizes to a standard
-- condition on the enemy counter (see read_addr/kills).
local function condList(c)
  if not c then return nil end
  local list = (c.addr or c.counter or c.kills) and { c } or c   -- Single condition -> 1-element list
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

-- Read baseline values (values at attempt start) for each condition in the list.
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
-- GOAL PROGRESS IN HUD - "Score 1200/5000"
-- ==========================================
-- Many goal conditions count values that the game itself does NOT display: SMW does not
-- show score during a level, and engine kill counters have no game HUD. This derives
-- a progress line: CURRENT VALUE / REQUIRED VALUE.
--
-- Only threshold ops with progression are displayed:
--   atleast                  -> absolute value / value
--   increasedby/decreasedby  -> delta from segment start / value (e.g. "score points")
-- nonzero/equals/changed/bitmasks have no intermediate values -> no progress line.
--
-- Per condition optional in games.lua:
--   label = "Score"   -- HUD label (otherwise automatic, see KNOWN / counter label)
--   mul   = 10        -- Display multiplier: SMW stores score as points/10 -> mul = 10
--   show  = false     -- Never show this condition in HUD
--
-- Attached to kills module rather than file-scope local: relay.lua is near the limit
-- of 200 locals (the do-block local below is only active locally).
do
  -- Known SMW addresses: meaningful label + multiplier so older games.lua files
  -- (without label/mul) display properly right away.
  local KNOWN = {
    [0x0F34] = { label = "Score", mul = 10 },   -- Mario score, RAM value = points / 10
    [0x0DBF] = { label = "Coins" },
    [0x18D2] = { label = "Combo" },             -- Consecutive stomps
    [0x0DBE] = { label = "Lives" },
  }

  -- Returns label, current value, target value (both scaled with mul) - or nil if
  -- segment has no displayable goal or attempt is not running yet (no baselines).
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

  -- Formatted HUD line: (text, goalReached) or nil.
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

-- Reset shortcut: all buttons in RESET_COMBO must be held simultaneously.
local function comboHeld(input)
  if #RESET_COMBO == 0 then return false end   -- No button -> never triggered (not "always")
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

-- ---- Persist (survives ROM switches + script restarts) ------------
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

-- ---- Runtime (one instance = one segment) -------------------------
if __FORCE_RESET then
  emu.setPersist(PFX .. "seg", nil)
  emu.setPersist(PFX .. "total", nil)
  emu.setPersist(PFX .. "splits", nil)
  emu.log("Relay: FORCE RESET requested. Cleared persist values.")
end

-- Practice Mode (injected by ChallengeManager via __PRACTICE_SEGMENT): practice a single
-- segment WITHOUT scoring (no PB/total/splits/finished writes, no submit).
local PRACTICE_SEG = (type(__PRACTICE_SEGMENT) == "number" and __PRACTICE_SEGMENT > 0)
                     and math.floor(__PRACTICE_SEGMENT) or nil
PRACTICE = PRACTICE_SEG ~= nil
local practiceClears = 0
-- In-memory only (NOT persisted): finished practice attempts for this session.
-- A new practice session reloads the script freshly -> list starts empty.
local practiceTimes = {}        -- All finished practice times (chronological)
local practiceBest  = nil       -- Best finished practice time this session
local practiceArmed = false     -- Restart latch: armed only after button release

local attempts = 0
if not REPLAY then
  attempts = loadAttempts()
  setP("attempts", attempts)   -- Keep persist updated even without reset in this session
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
    setP("id", CHALLENGE_ID)     -- For leaderboard submit (read by ChallengeManager)
    setP("challenge", CHALLENGE)
    setP("finished", 0)          -- Set to 1 only on actual completion
    setP("kills_total", 0)       -- Run enemy kill counter (see kills module)
    emu.log("Relay: FRISCHER LAUF initialisiert.")
  end
  if segIdx > #segments then segIdx = #segments end
end
segIdx = math.floor(segIdx)

local seg = segments[segIdx]
-- Normalized condition lists for active segment (see condList). Must be updated
-- on every seg change without script restart (in-memory resetChallenge).
local doneList = condList(seg.done)
local failList = condList(seg.fail)
kills.bind(seg, doneList)        -- Configure enemy counter for this segment (target from done)

-- Validation: is the correct ROM loaded?
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
  return -- Stop script execution since loadRom initiates a reboot
end
initSpikeMode()
local baseTotal = getP("total", 0)     -- Frames from previous segments
local segFrames = 0
local retries   = 0
local phase     = "init"               -- init -> preview -> go -> play -> done (Practice: + pdone)
local cdFrames  = 0
local previewReady = false             -- Freeze state captured at clean frame boundary?
local previewState                      -- Separate frozen state for preview (keeps startState pristine)
local busy      = false                -- Exec op is pending
local reloadPending = false            -- Reload request written; engine waiting for C# re-injection
local goStuckFrames = 0                -- Diagnostics: frames spent waiting in "go" for goOp callback
local startState
local baseDone, baseFail
local resetHoldFrames = 0
local resetLatched    = false   -- After reset: count again only after buttons released
-- A combo reset restarts the script (engine reload or ROM switch). If combo is held,
-- fresh instance would trigger immediately (especially in tap mode -> infinite retry loop).
-- resetChallenge sets a persist flag; here we consume it once and require release
-- before next reset.
local resetNeedsRelease = (tostring(getP("reset_hold_guard", "0")) == "1")
setP("reset_hold_guard", "0")
local submitState     = "idle"  -- idle -> sent (waiting for result) -> done
local submitPollFrames = 0      -- Rate limit: poll submit_result.txt ~4x/s instead of every frame
local submitMsg       = ""      -- Status reported by ChallengeManager (1st line = ok/error)
local submitOk        = false
local submitAchievements = {}   -- Achievements unlocked by this submit ({name=, desc=})
local achFrame        = 0       -- Frame counter for popup blink/rotation
local startLatched    = false   -- Edge detection for START submit
local physicalStartPressed = false
local selectLatched   = false   -- Edge detection for SELECT export
local physicalSelectPressed = false
local exportFlashFrames = 0     -- >0: briefly show "export dialog opened" prompt
local pdoneButtonHeld = false   -- Physical non-directional button press on practice result screen

-- ==========================================
-- STREAM OVERLAY - Statistics for OBS (Stream Stats)
-- ==========================================
-- Optional feature (UI setting "Stream overlay", injected via __STREAM_OVERLAY/__STREAM_DIR):
-- engine writes write-only stats.json + text/*.txt to stream/ directory next to Mesen.exe
-- on each run event (death, clear, finish, reset). A self-contained overlay.html
-- renders this as an OBS browser source. Session numbers live in session.dat (key=value)
-- updated read-modify-write per event to survive segment restarts;
-- "Reset stream stats" button simply deletes session.dat.
-- NOTE: Module resides in ONE IIFE returning a table (stream). Lua limits chunks to
-- 200 file-scope locals; relay.lua is near that limit, so helper functions are encapsulated
-- in an inner function (its own local budget) - costing only 1 local in main chunk.
local stream = (function()
  local STREAM_DIR = (type(__STREAM_DIR) == "string" and #__STREAM_DIR > 0) and __STREAM_DIR or nil
  if STREAM_DIR and not STREAM_DIR:match("/$") then STREAM_DIR = STREAM_DIR .. "/" end
  local enabled = (__STREAM_OVERLAY == true) and STREAM_DIR ~= nil and not REPLAY

  -- Enemy kills occur in bursts (unlike deaths/clears). They are buffered and written
  -- at most once per second; any other event flushes the buffer immediately.
  local pendingKills, killRenderAt = 0, 0
  local function takeKills()
    local k = pendingKills
    pendingKills = 0
    return k
  end

  -- Seconds -> "H:MM:SS" or "M:SS" (for playtime; fmt() is for frame times).
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

  -- Read session.dat (if missing -> fresh session with current start time).
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

  -- Writes stats.json (for overlay.html) + individual text/*.txt (for OBS text sources).
  local function render(s, state)
    if not STREAM_DIR then return end
    local now = os.time()
    local playSec = math.max(0, now - (s.session_start or now))
    local dph = playSec > 0 and math.floor(s.deaths / (playSec / 3600) + 0.5) or 0
    local frate = s.runs_started > 0 and math.floor(s.finishes / s.runs_started * 100 + 0.5) or 0
    local runTime = fmt(baseTotal + segFrames)

    -- Sum of Best + Golds (segments with personal best) analogous to HUD.
    local sob, complete, golds = 0, true, 0
    for _, sg in ipairs(segments) do
      local pb = pbSeg[sg.name]
      if pb then sob = sob + pb; golds = golds + 1 else complete = false end
    end

    -- Nemesis + segment breakdown (in segment order).
    local nemName, nemN = nil, 0
    local segParts = {}
    for _, sg in ipairs(segments) do
      local d = s.segd[sg.name] or 0
      if d > nemN then nemN = d; nemName = sg.name end
      segParts[#segParts + 1] = string.format('{"name":"%s","deaths":%d}', jsonEsc(sg.name), d)
    end

    -- Enemy counter: segment (current attempt, with goal if any), run and session.
    local killTarget = kills.target()
    local killStr = tostring(kills.get()) .. (killTarget and ("/" .. killTarget) or "")

    -- Goal progress of segment ("Score 1200/5000") - matches HUD, see kills.goalInfo.
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

    -- Individual text files for OBS "Text (GDI+)" sources.
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
      ["session_kills"]  = s.kills,                 -- Entire session
    }
    pcall(function()
      for name, val in pairs(texts) do
        local f = io.open(STREAM_DIR .. "text/" .. name .. ".txt", "w")
        if f then f:write(tostring(val)); f:close() end
      end
    end)
  end

  -- Event hooks (no-op if overlay is off). Each performs load -> mutate -> save -> render.
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
    -- Enemies defeated (n = kills in this frame). Can occur in bursts (e.g. a shell
    -- clearing a row), so written at most once per second; remainder
    -- remains buffered and is flushed on next write (takeKills).
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
    -- New run begins (combo reset counts as reset; auto reset on death only run restart).
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

-- Name is set via player_name.txt

emu.log(string.format("Challenge: Segment %d/%d (%s), already done %s",
        segIdx, #segments, seg.name, fmt(baseTotal)))

-- ---- Execute savestate ops in exec callback ----------------------
local function runInExec(op)
  local ref
  ref = emu.addMemoryCallback(function()
    emu.removeMemoryCallback(ref, emu.callbackType.exec, EXEC_S, EXEC_E, CPU)
    op()
  end, emu.callbackType.exec, EXEC_S, EXEC_E, CPU)
end

-- Starts a fresh attempt at segment start: timer at 0 and either preview
-- (frozen start frame) or playable immediately (PREVIEW_FRAMES == 0).
-- Applies uniformly to Segment 1, mid-relay segments and practice mode.
local function beginAttempt()
  segFrames = 0
  if PREVIEW_FRAMES > 0 then
    cdFrames = 0
    previewReady = false     -- Freeze state captured freshly on first preview frame
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
  applyMusicMute()               -- Loaded state brings $57=$C0 -> silence immediately
  kills.resetAttempt()           -- BEFORE readBases: counter baseline of attempt is always 0
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
  local ok, err = pcall(emu.loadSavestate, startState)  -- Clean start after preview
  flog("goOp: loadSavestate -> " .. (ok and "OK" or ("ERROR: " .. tostring(err))))
  applyMusicMute()               -- Loaded state brings $57=$C0 -> silence immediately
  kills.resetAttempt()           -- Start state reloaded -> enemies restored
  if failPreviewPending then
    failPreviewPending = false   -- Fail preview: attempt continues, timer keeps running
  else
    segFrames = 0
  end
  phase = "play"
  busy = false
  emu.log("Relay: goOp done, Phase set to play.")
end

local function failOp()
  emu.log("Relay: failOp (Restart after Death)...")
  emu.loadSavestate(startState)              -- Death -> restart, timer keeps running
  applyMusicMute()                           -- Loaded state brings $57=$C0 -> silence immediately
  kills.resetAttempt()                       -- Segment restarts -> enemy counter at 0
  -- In challenge mode, death does NOT interrupt recording: buffer continues uninterrupted
  -- so replay reproduces deaths 1:1 and replay time matches submitted time.
  -- Only intentional retry (reset combo -> resetChallenge) or practice mode restarts freshly.
  if PRACTICE then                           -- Practice: every attempt timed and recorded freshly
    resetSpikeAttempt()
    baseDone = readBases(doneList)
    baseFail = readBases(failList)
    beginAttempt()                           -- Preview first, then play (also from pdone screen)
  elseif FAIL_PREVIEW and PREVIEW_FRAMES > 0 then
    -- "Get Ready after Death" (setting): pause timer (segFrames frozen - preview
    -- phase does not increment) and display frozen frame. goOp keeps timer running
    -- via failPreviewPending instead of resetting to 0. Polls are play-gated,
    -- so input log remains identical to a run without this pause.
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

-- reloadSettings=true (intentional reset): engine is re-injected so changed
-- Challenge Settings take effect immediately (slight latency from script reload).
-- reloadSettings=false (e.g. auto reset on death): fast in-memory reset without refresh -
-- critical because this can occur frequently. On ROM switch, path is full reload anyway.
local function resetChallenge(reloadSettings)
  local firstSeg = segments[1]
  if not firstSeg then return end

  -- An intentional reset on Segment 1 counts as a new attempt (see ATTEMPTS_FILE
  -- above). Save before potential ROM switch so script restart picks up incremented
  -- value via loadAttempts().
  if not REPLAY then
    attempts = attempts + 1
    saveAttempts(attempts)
    setP("attempts", attempts)
  end

  local info = emu.getRomInfo() or {}
  local currentRom = normalizePath(info.path)
  local targetRom = normalizePath(firstSeg.rom)

  if currentRom == targetRom then
    -- Settings reload path: re-inject engine from ChallengeManager instead of in-memory
    -- reset -> fresh Challenge Settings + __FORCE_RESET (no ROM reload).
    -- seg=0 sets "fresh run" sentinel; newly loaded script initializes from beginning.
    -- Until then, reloadPending silences onFrame. If write fails, falls back to
    -- in-memory reset so resets always succeed.
    if reloadSettings and writeReloadRequest() then
      emu.log("Challenge: Reset -> engine reload requested (fresh settings).")
      setP("reset_hold_guard", "1")   -- Restart: held combo must not trigger immediately
      setP("seg", 0)
      setP("total", 0)
      setP("splits", "")
      setP("finished", 0)
      reloadPending = true
    else
      -- In-memory reset: either intentional (reloadSettings=false, e.g. auto reset on death)
      -- or fallback if reload signal could not be written.
      emu.log("Challenge: Resetting challenge to Segment 1 (in-memory)...")
      setP("seg", 1)
      setP("total", 0)
      setP("splits", "")
      setP("finished", 0)

      segIdx = 1
      seg = segments[1]
      doneList = condList(seg.done)
      failList = condList(seg.fail)
      kills.resetRun()                  -- New run -> reset total enemy counter to 0
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
    if reloadSettings then setP("reset_hold_guard", "1") end   -- Restart via ROM switch
    setP("seg", 0)
    setP("total", 0)
    setP("splits", "")
    emu.loadRom(firstSeg.rom:gsub("/", "\\"), firstSeg.patch and firstSeg.patch:gsub("/", "\\") or "")
  end
end

-- Skips to another segment in replay mode (clamped to 1..#segments; no-op outside replay).
-- A segment is its own script instance in replay mode as well - skip rewrites persist store
-- as if replay had progressed there normally, and loads segment ROM: fresh instance plays
-- seg<N>.inputs (as after completeSegment). Total time and splits are reconstructed from
-- recording headers so HUD time and summary match after skip. Skipping to current segment
-- (L on Segment 1, R on last) simply restarts it.
-- segment (L on Segment 1, R on last) simply restarts it.
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
  setP("finished", 0)          -- Rewind after done screen -> run active again
  setP("kills_total", 0)       -- Total enemy kills: cannot be reconstructed after skip

  local t = segments[target]
  emu.log(string.format("Replay: skip to Segment %d/%d (%s)", target, #segments, tostring(t.name)))
  emu.loadRom(t.rom:gsub("/", "\\"), t.patch and t.patch:gsub("/", "\\") or "")
end

-- ---- Display / Workflow ------------------------------------------
-- "RESET IN Xs" display while reset combo is held (challenge AND practice).
local function drawResetCountdown()
  if resetHoldFrames > 0 then
    local secondsLeft = string.format("%.1f", (RESET_HOLD_FRAMES - resetHoldFrames) / 60)
    -- Light blue (0x66CCFF) instead of dark blue: dark blue was barely readable on bright/orange
    -- background. Black shadow (0x000000) for added contrast.
    emu.drawString(80, 80, "RESET IN " .. secondsLeft .. "s", 0x66CCFF, 0x000000)
  end
end

-- Simple word wrap for achievement description (HUD font ~6px/char).
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

-- "ACHIEVEMENT UNLOCKED!" popup at bottom of done screen: golden box with blinking header;
-- when multiple achievements unlocked, display rotates every 4 seconds (with "(i/n)" counter).
-- Populated from submit_result.txt (lines "ach;..").
local function drawAchievementPopup()
  local n = #submitAchievements
  if n == 0 then return end
  achFrame = achFrame + 1

  local idx = (math.floor(achFrame / 240) % n) + 1
  local a = submitAchievements[idx]

  -- NOTE: Operate in LOGICAL (unscaled) coordinates. When HUD size != Big,
  -- surfaceScale > 1 and emu.drawString is wrapped (multiplies x/y by surfaceScale +
  -- overscan) - expecting logical coordinates. getScreenSize() suffices for WIDTH.
  --
  -- For vertical anchoring (box pinned at bottom), the actual VISIBLE height is REQUIRED:
  -- getScreenSize() calls SetOverscan({}) internally and returns FULL frame height WITHOUT
  -- overscan -> too large. Bottom anchoring to that pushes box bottom + last text line
  -- into clipped lower overscan. Visible height comes from getDrawSurfaceSize().visibleHeight
  -- (in SCALED pixels -> /surfaceScale = logical). Fallback to getScreenSize().height for
  -- unexpected nil cases.
  local sz = emu.getScreenSize() or {}
  local ds = emu.getDrawSurfaceSize() or {}
  local W = sz.width or 256
  local H = ds.visibleHeight and math.floor(ds.visibleHeight / surfaceScale) or sz.height or 224

  local descLines = wrapText(a.desc, 38)
  if #descLines > 2 then descLines = { descLines[1], descLines[2] } end

  local boxH = 28 + #descLines * 10
  local boxW = W - 4
  -- Anchor to bottom visible edge, clamped never to exceed top edge.
  local x0, y0 = 2, math.max(2, H - boxH - 4)

  drawRect(x0, y0, boxW, boxH, 0x18000000, true)   -- Dark opaque background
  drawRect(x0, y0, boxW, boxH, 0xFFD700, false)    -- Golden border

  local headerCol = (achFrame % 32 < 16) and 0xFFD700 or 0xFFFFFF
  local header = "* ACHIEVEMENT UNLOCKED! *"
  if n > 1 then header = header .. string.format(" (%d/%d)", idx, n) end
  emu.drawString(x0 + 6, y0 + 4, header, headerCol, 0x000000)
  emu.drawString(x0 + 6, y0 + 15, a.name, 0xFFD700, 0x000000)
  for i, line in ipairs(descLines) do
    emu.drawString(x0 + 6, y0 + 15 + i * 10, line, 0xCCCCCC, 0x000000)
  end
end

-- Small HUD string caches: segment counter and formatted segment PB change only on
-- segment change / PB update, so they do not need rebuilding every frame (drawHud
-- runs 60x/s). Time itself changes every frame and remains live formatted.
local hudSegIdxCache
local hudSegCounterStr = ""
local function segCounterString()
  if segIdx ~= hudSegIdxCache then
    hudSegIdxCache = segIdx
    hudSegCounterStr = string.format("Segment %d/%d", segIdx, #segments)
  end
  return hudSegCounterStr
end
local hudPbFramesCache = false   -- false = not computed yet (nil = segment has no PB)
local hudPbStr = nil
local function segPbString()
  local pb = pbSeg[seg.name]
  if pb ~= hudPbFramesCache then
    hudPbFramesCache = pb
    hudPbStr = pb and fmt(pb) or nil
  end
  return hudPbStr
end

local function drawHud()
  if PRACTICE then
    if phase == "pdone" then
      -- Practice result screen: Run PB alongside best practice time, followed by
      -- last 4 completed practice runs. (Styled like final done screen.)
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
    -- Clears top right: getScreenSize() returns actual screen width independent of HUD
    -- surface. Character width estimated via base font (~6px per char at 1x) and
    -- converted to current textScale/surfaceScale.
    local ctxt = "Clears: " .. practiceClears
    local screenSize = emu.getScreenSize() or {}
    local sw = screenSize.width or 256
    -- Each character is ~6px wide with base font (1x).
    -- Wrapper draws with textScale on surfaceScale surface,
    -- giving screen width = charWidth * textScale / surfaceScale per char.
    local charW = 6 * textScale / surfaceScale
    local cw = #ctxt * charW
    hud(sw - cw - 2, 0, ctxt, 0xFFFF00)
    drawResetCountdown()                        -- Show reset countdown in practice mode too
    return
  end
  if phase == "done" and segIdx == #segments then
    -- Darken background for readability (alpha inverted: low alpha = more opaque;
    -- 0x40000000 ~ 75% black). Cover full surface including overscan so entire
    -- visible area is dimmed.
    local ds = emu.getDrawSurfaceSize() or {}
    emu.drawRectangle(0, 0, ds.width or 256, ds.height or 240, 0x40000000, true)

    local total = baseTotal + segFrames
    emu.drawString(4, 12, "DONE!  Total: " .. fmt(total), 0x00FF00, 0x000000)
    local y = 22
    if SHOW_PBS then
      if prevTotalPB then
        local d = total - prevTotalPB        -- Total time comparison against total PB
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
          if sp.frames <= pb then col = 0xFFFF00 end   -- This run holds segment PB (Yellow)
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
      -- Sum of Best: theoretical best time if achieving gold split (segment PB) in EVERY segment
      -- = sum of all segment PBs. Meaningful only if PB exists for every segment;
      -- otherwise sum is incomplete.
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

    -- Leaderboard submit (every completed run, not only new total PBs -
    -- server takes minimum per player for ranking anyway).
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
    -- Export (local): SELECT bundles run + ghost for sharing. Independent of submit,
    -- usable without login/network. Not offered in replay mode.
    if not REPLAY then
      if exportFlashFrames > 0 then
        emu.drawString(4, y, "Export: save dialog opened", 0x00FF00, 0x000000)
      else
        emu.drawString(4, y, "Press SELECT to export run (share)", 0x00CCFF, 0x000000)
      end
      y = y + 10
    end
    emu.drawString(4, y, "Hold " .. comboLabel() .. " to Restart", 0x888888, 0x000000)

    -- Newly unlocked achievements (after successful submit) as popup at bottom.
    if submitState == "done" and submitOk then
      drawAchievementPopup()
    end
  else
    -- Dynamic line counter: hidden elements (segment info / delta, see settings)
    -- leave no gap, HUD compacts vertically.
    local line = 0
    local total = baseTotal + segFrames
    if REPLAY then
      hud(4, line, string.format("REPLAY  %s  [%d/%d]", fmt(total), segIdx, #segments), 0xFF4040); line = line + 1
      if REPLAY_PLAYER then hud(4, line, "by " .. REPLAY_PLAYER, 0xFFCC00); line = line + 1 end
      hud(4, line, seg.name, 0xCCCCCC); line = line + 1
      -- Show navigation hint only at segment start (and in preview) to keep HUD
      -- compact during playback.
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
        if SHOW_DELTA and phase == "play" then    -- Live delta: green when ahead of PB, red when behind
          local delta = segFrames - pbSeg[seg.name]
          local col = delta <= 0 and 0x00FF00 or 0xFF4040
          local sign = delta <= 0 and "-" or "+"
          hud(4, line, sign .. fmt(math.abs(delta)), col); line = line + 1   -- Dedicated line (scales cleanly)
        end
      else
        hud(4, line, "PB --", 0x888888); line = line + 1
      end
    end

    -- Goal progress ("Score 1200/5000", "Kills 3/10"): derived from done condition so values
    -- not displayed by game itself are visible. Goal reached -> green.
    -- Without goal condition, pure enemy counter remains (only with kills.show = true).
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
    prevTotalPB = pbTotal                      -- Remember PB BEFORE this run (for comparison/display)
    isNewTotalPB = (not pbTotal) or (total < pbTotal)
    if isNewTotalPB then                       -- Update total PB only on genuine improvement
      pbTotal = total
      savePBs()
    end
    stream.onFinish(total, isNewTotalPB)        -- Stream stats: finish + best run + total PB counter

    -- Promote temporary recordings to completed run replay files
    emu.log("Spike: Challenge completed. Promoting temporary recordings.")
    for i = 1, #segments do
      local src = SCRIPT_DIR .. "recordings/temp_seg" .. math.floor(i) .. ".inputs"
      local dest = SCRIPT_DIR .. "recordings/seg" .. math.floor(i) .. ".inputs"
      os.remove(dest)
      os.rename(src, dest)
    end

    setP("finished", 1)                        -- Mark real completion (verified by ChallengeManager)
  end
  setP("seg", 0)                             -- Next run starts fresh
end

-- ---- Leaderboard Submit (file IPC with C# ChallengeManager) ----------
-- The trigger is INTENTIONALLY dataless: run data is read by ChallengeManager
-- from core persist store (set by embedded engine), so forged trigger files
-- cannot inject fake times. Signing (HMAC) + HTTP POST happen in C#
-- (matching server-side validation rules).
local function writeSubmitRequest()
  os.remove(SUBMIT_RESULT)                   -- Clear previous result
  local ok, err = pcall(function()
    local f = assert(io.open(SUBMIT_REQUEST, "w"))
    f:write("submit\n")                      -- Content does not matter; signal only
    f:close()
  end)
  emu.log("Submit-Request -> " .. (ok and SUBMIT_REQUEST or ("ERROR: " .. tostring(err))))
  return ok
end

-- Dataless export trigger (like submit trigger): ChallengeManager bundles
-- completed run and opens save dialog. No result round trip required.
local function writeExportRequest()
  local ok, err = pcall(function()
    local f = assert(io.open(EXPORT_REQUEST, "w"))
    f:write("export\n")                      -- Content does not matter; signal only
    f:close()
  end)
  emu.log("Export-Request -> " .. (ok and EXPORT_REQUEST or ("ERROR: " .. tostring(err))))
  return ok
end

-- Reads result written by ChallengeManager (1st line ok/error, 2nd line display text).
-- Returns true once a result is present.
local function pollSubmitResult()
  local f = io.open(SUBMIT_RESULT, "r")
  if not f then return false end
  local status = f:read("*l") or "error"
  local msg = f:read("*l") or ""
  -- Lines 3+: "ach;<Name>;<Description>" per newly unlocked achievement
  -- (passed from server response by ChallengeManager, ASCII sanitised).
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
  stream.onClear(newPB)     -- Stream stats: deathless streak + PB counter (every segment, incl. last)
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

-- ---- Per-frame logic (startFrame; NO savestate calls here!) -----------
-- Draws PB ghost for current play frame: recorded WORLD position minus
-- LIVE camera. Only when on-screen and (if room configured) in same room as player.
-- If ghost has not started yet (i<1) or already finished (i>ghLen), nothing is drawn.
local function drawGhost()
  local i = segFrames
  if i < 1 or i > ghLen then return end
  if ghostAddrs.room then
    if emu.read(ghostAddrs.room, MEM) ~= ghRoom[i] then return end
  end
  local sx = ghX[i] - emu.read16(ghostAddrs.camera_x, MEM)
  local sy = ghY[i] - emu.read16(ghostAddrs.camera_y, MEM)
  if sx > -16 and sx < 256 and sy > -32 and sy < 224 then
    -- NOTE: drawRect (not emu.drawRectangle directly) - accounts for surfaceScale + overscan,
    -- exactly like patched emu.drawString. Otherwise rectangle lands at incorrect position
    -- with scaled HUD (surfaceScale>1, default) while name sits correctly.
    -- Slim marker: noticeably narrower + shorter than player sprite, bottom-aligned
    -- (bottom edge remains at sy+24, i.e. at "feet"), centered horizontally on old width.
    local GW, GH = 8, 14
    local gx = sx + math.floor((16 - GW) / 2)   -- Centered (old box was 16 wide)
    local gy = sy + (24 - GH)                    -- Bottom-aligned (old box was 24 high)
    -- On very low opacity (<=10) omit box entirely -> name only as marker.
    if GHOST_OPACITY > 10 then
      if not GHOST_OUTLINE then
        drawRect(gx, gy, GW, GH, GHOST_FILL, true)  -- Semi-transparent fill (user color)
      end
      drawRect(gx, gy, GW, GH, GHOST_BORDER, false) -- Border (user color)
    end
    emu.drawString(gx, gy - 9, ghPlayer, GHOST_NAME_COLOR, GHOST_NAME_BG)
  end
end

local function onFrame()
  -- Reload requested (reset combo on same ROM): until ChallengeManager re-injects
  -- the engine, suppress further game/reset logic (prevents double triggers during
  -- wait window). The script restart will replace this instance entirely anyway.
  if reloadPending then
    return
  end

  -- Music mute (UI setting): hold master music volume at 0 in SPC RAM every frame (music only;
  -- SFX write voice volumes directly and remain audible). Catches music changes mid-segment
  -- (sublevel/song init resetting $57 to $C0); resets also re-apply value immediately after
  -- savestate load (see applyMusicMute).
  applyMusicMute()

  -- Input polling for reset (see RESET_COMBO in games.lua). In replay mode, combo uses
  -- the PHYSICAL state of spectator (nav, read in inputPolled) - otherwise emu.getInput(0)
  -- returns REPLAYED buttons, and held L+R during run would reset replay.
  local comboDown
  if REPLAY then
    comboDown = nav.combo
  else
    comboDown = comboHeld(emu.getInput(0) or {})
  end

  -- Ignore reset combo during "GET READY" preview: player often buffers buttons there,
  -- which should not trigger an accidental restart.
  if phase == "preview" then
    -- Ignore combo during "GET READY" preview AND do NOT touch latch: input is blanked here
    -- (would falsely appear "released"). Unlatching here would cause a held combo to trigger
    -- immediately after preview (e.g. practice fail preview where failOp runs in-script
    -- and resetLatched must survive across attempts).
  elseif comboDown then
    if not resetLatched and not resetNeedsRelease then
      resetHoldFrames = resetHoldFrames + 1
      if resetHoldFrames >= RESET_HOLD_FRAMES then
        resetHoldFrames = 0
        resetLatched = true              -- Holding continues NOT to trigger (no flashing)
        flog(string.format("reset combo triggered: phase=%s busy=%s PRACTICE=%s", tostring(phase), tostring(busy), tostring(PRACTICE)))
        if PRACTICE then
          if not busy then busy = true; runInExec(failOp) end   -- Practice: restart attempt
        else
          stream.onRunRestart(true)               -- Stream stats: intentional reset = new attempt
          resetChallenge(true)                   -- Intentional reset -> reload settings freshly
        end
        return
      end
    end
  else
    resetHoldFrames = 0
    resetLatched = false                 -- Buttons released -> armed again
  end

  -- Replay navigation: L = previous segment, R = next segment (in any phase, including
  -- done screen). Triggered on RELEASE so reset combo (default L+R) continues working:
  -- as soon as both shoulder buttons are held together, skip is blocked for that press
  -- and only combo executes.
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
        nav.skip(segIdx + dir)             -- loadRom -> this instance will be replaced immediately
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
    -- Hold frozen frame until PREVIEW_FRAMES elapse. segFrames remains 0 -> timer starts
    -- only in play phase. Held inputs swallowed by reload -> player can only plan/watch.
    -- swallowed by reload -> player can only plan/watch.
    if not busy then
      busy = true
      if not previewReady then
        -- First preview frame: capture a SEPARATE freeze state at clean frame boundary
        -- (scanline 0, before frame present at ~scanline 225). For frozen image only!
        -- NOTE: DO NOT overwrite startState - that remains pristine segment start state
        -- (otherwise spawn point drifts 1 frame further on each restart). Segment state
        -- may reside in late vblank scanline; reloading there would skip present ->
        -- frame limiter would not engage -> loop (and cdFrames) would race.
        runInExec(function()
          previewState = emu.createSavestate()
          previewReady = true
          busy = false
        end)
      else
        runInExec(function()
          emu.loadSavestate(previewState)
          busy = false
        end)
      end
    end
    -- NOTE: Savestate reload resets emulator frame counter every frame. As a result,
    -- all HUD draw commands receive the same frame number and do NOT expire automatically
    -- (they overlap -> full bar obscures shorter ones, appearing permanently full).
    -- Clear old draw commands every frame and redraw cleanly.
    emu.clearScreen()
    drawHud()
    -- "GET READY" + progress bar filling over preview duration (empty -> full).
    -- cdFrames increments further below, so value matches here.
    local grX, grText = 100, "GET READY"
    emu.drawString(grX, 100, grText, 0xFFFF00, 0x000000)
    local barLen = 20
    local filled = math.max(0, math.min(barLen, math.ceil(cdFrames / PREVIEW_FRAMES * barLen)))
    local barText = "[" .. string.rep("|", filled) .. string.rep(".", barLen - filled) .. "]"
    -- Align progress bar centered under "GET READY". Fixed font widths (unscaled):
    -- "GET READY" = 9 chars at 6px; bar characters ([ ] | .) are all 3px wide.
    -- Convert to logical coordinates using textScale/surfaceScale (matching drawString wrapper).
    -- Note: emu.measureString cannot be used here - HUD scale wrapper passes a 3rd argument,
    -- causing core function to abort with "too many parameters" (Lua error -> aborts onFrame).
    -- causing core function to abort with "too many parameters" (Lua error -> aborts onFrame).
    local sc = textScale / surfaceScale
    local grW = #grText * 6
    local barW = #barText * 3
    local barX = grX + (grW - barW) * sc / 2
    emu.drawString(barX, 112, barText, 0x00FF00, 0x000000)
    -- Count frames only once freeze state is captured (otherwise single unthrottled
    -- launch frame would count towards preview).
    if previewReady then
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
    -- Update enemy counter. MUST run before done check so a "defeat X enemies"
    -- segment can finish in the exact frame where final kill occurs.
    local killed = kills.update()
    if killed > 0 then
      stream.onKill(killed)                   -- Stream stats (throttled, see module)
    end
    -- Auto Reset on Death (UI setting): dedicated death check (SMW default $0071==9),
    -- INDEPENDENT of games.lua fail condition. If matched, entire run restarts (in-memory
    -- reset, no settings reload). Evaluated BEFORE done/fail and returns -> takes priority over failOp.
    if AUTO_RESET_ON_DEATH and not PRACTICE and deathCheck and not busy then
      local cur = (deathCheck.size == 2) and emu.read16(deathCheck.addr, MEM) or emu.read(deathCheck.addr, MEM)
      if cur == deathCheck.value then
        stream.onDeath()                        -- Stream stats: count death...
        stream.onRunRestart(false)              -- ...and auto-reset restarts entire run
        resetChallenge(false)
        return
      end
    end
    if anyCondMet(doneList, baseDone) then
      if spikeMode == "record" then
        local ok, err = pcall(saveRecordedInputs, SPIKE_FILE, segFrames)
        if not ok then
          flog("ERROR in saveRecordedInputs: " .. tostring(err))
        end
        -- Save PB ghost if this run is a new segment PB (or none exists yet).
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
      busy = true
      retries = retries + 1
      stream.onDeath()                          -- Stream stats: count death / segment restart
      runInExec(failOp)
    end
    if GHOST_SHOW then drawGhost() end
    drawHud()

  elseif phase == "done" then
    -- On final done screen: START submits result to leaderboard (every completed run,
    -- not only new total PBs).
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
        if submitPollFrames >= 15 then      -- ~4x/s instead of 60x/s: open result file less frequently
          submitPollFrames = 0
          pollSubmitResult()                -- Becomes "done" once ChallengeManager has responded
        end
      end

      -- SELECT exports completed run (local, independent of submit).
      -- Edge triggered; shows brief confirmation after press, then available again.
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
    -- Practice result screen: any non-directional button starts next attempt.
    -- Armed only after button release so held jump from clear does not restart immediately.
    -- Button press is read in inputPolled callback (pdoneButtonHeld) - here in startFrame,
    -- input is blanked (pdone blocks inputs).
    if not pdoneButtonHeld then
      practiceArmed = true
    elseif practiceArmed and not busy then
      practiceArmed = false
      busy = true
      runInExec(failOp)                     -- failOp in practice resets phase back to "play"
    end
    drawHud()
  end
end

emu.addEventCallback(onFrame, emu.eventType.startFrame)

-- After final segment: block inputs so gameplay cannot continue.
-- Emulation runs normally -> music stays on, no audio buzzing.
-- Reset combo is passed through (otherwise restart from done screen would not work).
emu.addEventCallback(function()
  -- Read physical reset combo BEFORE any input blanking: after combo reset (script restart),
  -- resetNeedsRelease requires actual release before triggering again.
  -- Must happen here (inputPolled), not in startFrame - there input in preview/pdone/done
  -- is already blanked and would falsely appear "released".
  local phys = emu.getInput(0) or {}
  if resetNeedsRelease and not comboHeld(phys) then
    resetNeedsRelease = false
  end

  -- Replay navigation: capture PHYSICAL input state here - further down,
  -- recording replaces input (play) or blanks it (preview/done). In startFrame callback,
  -- emu.getInput(0) in replay mode would see replayed buttons, not spectator inputs.
  if REPLAY then
    nav.l, nav.r, nav.combo = phys.l or false, phys.r or false, comboHeld(phys)
  end

  -- Spike: record/replay during play phase
  if phase == "play" then
    spikePollCounter = spikePollCounter + 1
    if spikeMode == "replay" then
      local v = spikeInputs[spikePollCounter]
      if v then
        emu.setInput(unpackInto(replayInput, v), 0)   -- Unpacks into reusable table
      else
        emu.setInput(BLANK_INPUT, 0)
      end
    elseif spikeMode == "record" then
      recordPush(packInput(emu.getInput(0) or {}))    -- Packed + RLE, no per-frame alloc
    end
  end

  -- Block inputs during "GET READY" preview. Image is frozen via savestate reload anyway;
  -- this allows player to buffer inputs without unintended actuation.
  if phase == "preview" then
    emu.setInput(BLANK_INPUT, 0)
    return
  end

  -- Practice result screen: read physical controller HERE (before blanking) and note
  -- restart button press; input is blanked in startFrame afterwards. Then block inputs
  -- so level remains stationary in background.
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

-- Stream overlay: write current state once on script startup (including after each segment
-- restart) so overlay shows records/segment immediately - without waiting for 1st event.
stream.init()
