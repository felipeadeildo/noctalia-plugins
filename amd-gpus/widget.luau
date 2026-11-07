-- One AMD GPU on the bar, read from sysfs by PCI address.
--
-- Noctalia's built-in sysmon shows a single GPU and sums VRAM across cards.
-- This widget pins one card. It reads power/runtime_status first and never
-- touches the other files while the card is suspended: reading
-- gpu_busy_percent or the hwmon sensors resumes a sleeping dGPU.

local pci = noctalia.string.trim(noctalia.getConfig("pci") or "")
local label = noctalia.getConfig("label") or "GPU"
local hideWhenAsleep = noctalia.getConfig("hide_when_asleep") == true
local base = "/sys/bus/pci/devices/" .. pci

local vramTotal = nil -- bytes, constant per card
local tempPath = nil  -- hwmon temp1_input, resolved once
local reading = false

noctalia.setUpdateInterval(noctalia.getConfig("interval") or 2000)
barWidget.setGlyph("gpu-usage")

local function number(raw)
  return raw and tonumber(noctalia.string.trim(raw)) or nil
end

local function mib(bytes)
  return string.format("%d MiB", math.floor(bytes / 1048576 + 0.5))
end

local function showMissing()
  barWidget.setGlyph("gpu-usage")
  barWidget.setText(label .. " ?")
  barWidget.setColor("error", "script")
  barWidget.setTooltip({ { label, "PCI " .. (pci ~= "" and pci or "não configurado") .. " não encontrado" } })
end

local function showAsleep()
  if hideWhenAsleep then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setGlyph("hibernate")
  barWidget.setText(label)
  barWidget.setColor("on_surface_variant", "script")
  barWidget.setGlyphColor("on_surface_variant", "script")
  barWidget.setTooltip({ { label, "dormindo (runtime suspend)" } })
end

local function showAwake(busy, used, temp)
  barWidget.setVisible(true)
  barWidget.setGlyph("gpu-usage")
  -- %2d keeps the width fixed from 0% to 99% (the bar font is monospaced)
  barWidget.setText(string.format("%s %2d%%", label, busy or 0))
  barWidget.setColor("on_surface")
  barWidget.setGlyphColor("on_surface")

  local rows = { { "GPU", label }, { "Uso", string.format("%d%%", busy or 0) } }
  if used and vramTotal then
    table.insert(rows, { "VRAM", mib(used) .. " / " .. mib(vramTotal) })
  end
  if temp then
    table.insert(rows, { "Temperatura", string.format("%d °C", math.floor(temp / 1000 + 0.5)) })
  end
  barWidget.setTooltip(rows)
end

local function resolveCard()
  if not noctalia.fileExists(base .. "/power/runtime_status") then
    return false
  end
  if vramTotal == nil then
    vramTotal = number(noctalia.readFile(base .. "/mem_info_vram_total"))
  end
  if tempPath == nil then
    local entries = noctalia.listDir(base .. "/hwmon")
    for _, name in ipairs(entries or {}) do
      if string.sub(name, 1, 5) == "hwmon" then
        tempPath = base .. "/hwmon/" .. name .. "/temp1_input"
        break
      end
    end
  end
  return true
end

-- Reads busy %, VRAM used and temperature in parallel (3 of the 4 async slots)
-- and renders once all three have answered.
local function readAwake()
  local pending = tempPath and 3 or 2
  local busy, used, temp

  local function done()
    pending -= 1
    if pending == 0 then
      reading = false
      showAwake(busy, used, temp)
    end
  end

  noctalia.readFileAsync(base .. "/gpu_busy_percent", function(raw)
    busy = number(raw)
    done()
  end)
  noctalia.readFileAsync(base .. "/mem_info_vram_used", function(raw)
    used = number(raw)
    done()
  end)
  if tempPath then
    noctalia.readFileAsync(tempPath, function(raw)
      temp = number(raw)
      done()
    end)
  end
end

function update()
  if reading then
    return
  end
  if not resolveCard() then
    showMissing()
    return
  end

  reading = true
  local accepted = noctalia.readFileAsync(base .. "/power/runtime_status", function(raw)
    if raw == nil or noctalia.string.trim(raw) ~= "active" then
      reading = false
      showAsleep()
      return
    end
    readAwake()
  end)
  if not accepted then
    reading = false
  end
end

function onClick()
  if noctalia.commandExists("amdgpu_top") then
    noctalia.runInTerminal("amdgpu_top")
  end
end

update()
