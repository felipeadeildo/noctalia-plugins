-- Music Theme: themes Noctalia (and every enabled template) from the album
-- art of the playing track, then hands the theme back when playback stops.
--
-- Port of dms-music-theme 3.0.0 to Noctalia 5.4.1 (plugin API 43):
--   playerctl --follow status -> the active player and its status
--   playerctl metadata        -> its art URL (empty in status mode)
--   noctalia theme      -> Material palette from the cover
--   palettes/MusicTheme.json + `noctalia msg color-scheme-set custom ...`
-- The palette in use before the first track is saved in the plugin data dir
-- and put back after the hold time, when the player closes, when the plugin
-- is disabled, or on the next start if the shell went down mid-track.

local PALETTE = "MusicTheme"
local NEUTRAL_SATURATION = 0.2 -- below this a cover is black and white or washed out
local ART_GAP_MS = 3000        -- covers load after the track changes; not a stop
local ART_POLL_MS = 2000       -- catches track changes while the status stays Playing
local KEEPS_CHROMA = { ["m3-content"] = true, ["faithful"] = true, ["m3-monochrome"] = true }

local configHome = noctalia.getenv("XDG_CONFIG_HOME") or noctalia.expandPath("~/.config")
local paletteDir = configHome .. "/noctalia/palettes"
local palettePath = paletteDir .. "/" .. PALETTE .. ".json"
local dataDir = noctalia.pluginDataDir()
local statePath = dataDir .. "/state.json"
local coverDir = dataDir .. "/covers"
local paletteTmp = dataDir .. "/palette.json"

local settings = {}
local player = { status = "", name = "", art = "" }
local saved = { previous = nil } -- palette selection to restore, e.g. "wallpaper vibrant"
local shownKey = nil             -- cover|scheme currently on screen
local syncAt = nil               -- debounce deadline, ms
local artPollAt = 0              -- next art refresh while playing, ms
local holdUntil = 0              -- 0 no hold, -1 until the player closes, else ms
local busy = false               -- a generate/apply is in flight
local recovered = false          -- a palette survived from the previous session

local function log(msg)
  noctalia.log("music-theme: " .. msg)
end

local function loadSettings()
  settings.scheme = noctalia.getConfig("scheme") or "system"
  settings.hold = tonumber(noctalia.getConfig("hold") or "30") or 30
  settings.delay = noctalia.getConfig("delay_ms") or 500
  settings.ignore = noctalia.getConfig("ignore_players") or {}
end

local function saveState()
  noctalia.writeFile(statePath, noctalia.json.encode(saved))
end

local function loadState()
  local raw = noctalia.readFile(statePath)
  if raw then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      saved = decoded
    end
  end
  recovered = saved.previous ~= nil
end

-- djb2, only to name cached covers.
local function hash(text)
  local h = 5381
  for i = 1, #text do
    h = bit32.band(h * 33 + string.byte(text, i), 0xFFFFFFFF)
  end
  return string.format("%08x", h)
end

local function saturation(hex)
  local r = tonumber(string.sub(hex, 2, 3), 16) / 255
  local g = tonumber(string.sub(hex, 4, 5), 16) / 255
  local b = tonumber(string.sub(hex, 6, 7), 16) / 255
  local max = math.max(r, g, b)
  if max == 0 then
    return 0
  end
  return (max - math.min(r, g, b)) / max
end

local function chosenScheme()
  if settings.scheme ~= "system" then
    return settings.scheme
  end
  return noctalia.getSetting("theme.wallpaper_scheme") or "m3-tonal-spot"
end

-- Noctalia's generated token map -> palette file format of 5.4.1. The roles
-- the shell derives (surface_container, outline_variant) come from the
-- tokens it would use itself for a wallpaper palette.
local function toPaletteVariant(t)
  return {
    mPrimary = t.primary,
    mOnPrimary = t.on_primary,
    mSecondary = t.secondary,
    mOnSecondary = t.on_secondary,
    mTertiary = t.tertiary,
    mOnTertiary = t.on_tertiary,
    mError = t.error,
    mOnError = t.on_error,
    mSurface = t.surface,
    mOnSurface = t.on_surface,
    mSurfaceVariant = t.surface_container,
    mOnSurfaceVariant = t.on_surface_variant,
    mOutline = t.outline_variant,
    mShadow = t.shadow,
    mHover = t.hover,
    mOnHover = t.on_hover,
    terminal = {
      background = t.terminal_background,
      foreground = t.terminal_foreground,
      cursor = t.terminal_cursor,
      cursorText = t.terminal_cursor_text,
      selectionBg = t.terminal_selection_bg,
      selectionFg = t.terminal_selection_fg,
      normal = {
        black = t.terminal_normal_black,
        red = t.terminal_normal_red,
        green = t.terminal_normal_green,
        yellow = t.terminal_normal_yellow,
        blue = t.terminal_normal_blue,
        magenta = t.terminal_normal_magenta,
        cyan = t.terminal_normal_cyan,
        white = t.terminal_normal_white,
      },
      bright = {
        black = t.terminal_bright_black,
        red = t.terminal_bright_red,
        green = t.terminal_bright_green,
        yellow = t.terminal_bright_yellow,
        blue = t.terminal_bright_blue,
        magenta = t.terminal_bright_magenta,
        cyan = t.terminal_bright_cyan,
        white = t.terminal_bright_white,
      },
    },
  }
end

local function msg(args, cb)
  local argv = { "noctalia", "msg" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  return noctalia.runAsync(argv, cb or function(result)
    if result.exitCode ~= 0 then
      log("noctalia msg " .. table.concat(args, " ") .. " failed: " .. (result.stderr or ""))
    end
  end)
end

local function generate(cover, scheme, cb)
  noctalia.runAsync({ "noctalia", "theme", cover, "--scheme", scheme, "--both", "-o", paletteTmp }, function(result)
    if result.exitCode ~= 0 then
      log("noctalia theme failed for " .. cover .. ": " .. (result.stderr or ""))
      cb(nil)
      return
    end
    local raw = noctalia.readFile(paletteTmp)
    local tokens = raw and noctalia.json.decode(raw)
    cb(type(tokens) == "table" and tokens.dark and tokens or nil)
  end)
end

local function setPalette(tokens, key)
  noctalia.mkdirAll(paletteDir)
  local light = tokens.light or tokens.dark
  local ok, err = noctalia.writeFile(palettePath, noctalia.json.encode({
    dark = toPaletteVariant(tokens.dark),
    light = toPaletteVariant(light),
  }, true))
  if not ok then
    log("could not write " .. palettePath .. ": " .. tostring(err))
    busy = false
    return
  end
  msg({ "color-scheme-set", "custom", PALETTE }, function(result)
    busy = false
    if result.exitCode == 0 then
      shownKey = key
    else
      log("color-scheme-set failed: " .. (result.stderr or ""))
    end
  end)
end

-- Remember what was on screen before the first album palette, once.
local function withPrevious(cb)
  if saved.previous then
    cb()
    return
  end
  msg({ "color-scheme-get" }, function(result)
    local current = noctalia.string.trim(result.stdout or "")
    if result.exitCode == 0 and current ~= "" and current ~= "custom " .. PALETTE then
      saved.previous = current
      saveState()
    end
    cb()
  end)
end

local function applyCover(cover)
  local scheme = chosenScheme()
  local key = cover .. "|" .. scheme
  if busy or key == shownKey then
    return
  end
  busy = true
  generate(cover, scheme, function(tokens)
    if not tokens then
      busy = false
      return
    end
    local seed = tokens.dark.source_color
    if seed and saturation(seed) < NEUTRAL_SATURATION and not KEEPS_CHROMA[scheme] then
      -- Most schemes pin the chroma and turn a gray seed into a strong color
      -- with an arbitrary hue; m3-content keeps it neutral.
      generate(cover, "m3-content", function(neutral)
        if not neutral then
          busy = false
          return
        end
        withPrevious(function()
          setPalette(neutral, key)
        end)
      end)
      return
    end
    withPrevious(function()
      setPalette(tokens, key)
    end)
  end)
end

-- Turns an MPRIS art URL into a local file, downloading http(s) covers once.
local function withCoverFile(art, cb)
  if string.sub(art, 1, 7) == "file://" then
    cb(noctalia.string.urlDecode(string.sub(art, 8)))
    return
  end
  if string.match(art, "^https?://") then
    noctalia.mkdirAll(coverDir)
    local dest = coverDir .. "/" .. hash(art)
    if noctalia.fileExists(dest) then
      cb(dest)
      return
    end
    noctalia.download(art, dest, function(ok)
      cb(ok and dest or nil)
    end)
    return
  end
  if string.sub(art, 1, 1) == "/" then
    cb(art)
    return
  end
  cb(nil)
end

local function endHold()
  holdUntil = 0
end

local function restore()
  endHold()
  shownKey = nil
  if not saved.previous then
    return
  end
  local previous = saved.previous
  -- Only hand back a palette that is still ours: if the user picked another
  -- one meanwhile, leave it alone.
  msg({ "color-scheme-get" }, function(result)
    local current = noctalia.string.trim(result.stdout or "")
    if current == "custom " .. PALETTE then
      local args = { "color-scheme-set" }
      for word in string.gmatch(previous, "%S+") do
        table.insert(args, word)
      end
      msg(args)
      log("handed the theme back: " .. previous)
    end
    saved.previous = nil
    saveState()
  end)
end

-- Hold in ms: 0 restores now, -1 waits for the player to close.
local function holdTime()
  if player.name == "" then
    return 0
  end
  if settings.hold < 0 then
    return -1
  end
  local ms = settings.hold * 1000
  if player.status == "Playing" then
    return math.max(ms, ART_GAP_MS)
  end
  return ms
end

local function sync()
  local live = player.status == "Playing" and player.art ~= ""
  if live then
    recovered = false
    endHold()
    local art = player.art
    withCoverFile(art, function(cover)
      -- The track may have changed while the cover downloaded.
      if cover and player.art == art then
        applyCover(cover)
      end
    end)
    return
  end

  if not saved.previous then
    return
  end
  -- A palette left over from the previous session is stale: never hold it.
  local hold = recovered and 0 or holdTime()
  recovered = false
  if hold == 0 then
    restore()
  elseif holdUntil == 0 then
    holdUntil = hold < 0 and -1 or noctalia.nowMs() + hold
  end
end

local function scheduleSync()
  syncAt = noctalia.nowMs() + settings.delay
end

local function refreshArt()
  local name = player.name
  artPollAt = noctalia.nowMs() + ART_POLL_MS
  if name == "" then
    return
  end
  noctalia.runAsync({ "playerctl", "-p", name, "metadata", "mpris:artUrl" }, function(result)
    if player.name ~= name then
      return
    end
    local art = result.exitCode == 0 and noctalia.string.trim(result.stdout or "") or ""
    if art ~= player.art then
      player.art = art
      scheduleSync()
    end
  end)
end

-- playerctl follows the player whose status changed last, and falls back to
-- the next one when it closes. An empty line means no player is left.
local function onPlayerLine(line)
  local status, name = string.match(line, "^([^|]*)|(.*)$")
  status = status or ""
  name = name and noctalia.string.trim(name) or ""
  if name ~= player.name then
    player.art = ""
  end
  player.status = status
  player.name = name
  if status == "Playing" then
    endHold()
  end
  scheduleSync()
  refreshArt()
end

local function startStream()
  local ignore = {}
  for _, p in ipairs(settings.ignore) do
    local clean = string.gsub(p, "[^%w%._%-]", "")
    if clean ~= "" then
      table.insert(ignore, clean)
    end
  end
  local cmd = "playerctl --follow"
  if #ignore > 0 then
    cmd ..= " --ignore-player=" .. table.concat(ignore, ",")
  end
  cmd ..= " status --format '{{status}}|{{playerName}}' 2>/dev/null"
  if not noctalia.runStream(cmd, onPlayerLine) then
    log("could not start playerctl; is it installed?")
  end
end

function update()
  local now = noctalia.nowMs()
  if player.status == "Playing" and now >= artPollAt then
    refreshArt()
  end
  if syncAt and now >= syncAt then
    syncAt = nil
    sync()
  end
  if holdUntil > 0 and now >= holdUntil and not (player.status == "Playing" and player.art ~= "") then
    restore()
  end
end

function onConfigChanged()
  loadSettings()
  shownKey = nil -- scheme may have changed: regenerate
  scheduleSync()
end

function onExit(_signal, reason)
  if reason == "reload" or not saved.previous then
    return
  end
  -- The runtime is going away: hand the theme back without waiting. If this
  -- does not land (shutdown), the next start restores it from state.json.
  local args = { "noctalia", "msg", "color-scheme-set" }
  for word in string.gmatch(saved.previous, "%S+") do
    table.insert(args, word)
  end
  noctalia.runAsync(args)
  if reason == "disable" or reason == "uninstall" then
    saved.previous = nil
    saveState()
  end
end

loadSettings()
loadState()
noctalia.setUpdateInterval(250)
startStream()
scheduleSync()
