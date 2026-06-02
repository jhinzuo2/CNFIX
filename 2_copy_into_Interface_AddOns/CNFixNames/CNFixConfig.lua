-- CNFixConfig.lua — options panel for CNFix.
-- Pushes settings to CNFixEnglish.dll via the \1CNFXCFG\1 control string and
-- stores them in CNFixNamesDB (account-wide). Five checkboxes + an English/Pinyin
-- name-style radio. Master ("CNFix") greys out the rest when off (state kept).

local CFG_CTRL = "\1CNFXCFG\1"
local CFG_SCALE = "\1CNFXSCALE\1"
local CFG_THRESH = "\1CNFXTHRS\1"
local CFG_DIST  = "\1CNFXDIST\1"

-- ---- defaults: everything ON, English mode ----
local DEFAULTS = {
  master = true, social = true, unitframes = true,
  groupfinder = true, realtime = true, pinyin = false,  -- groupfinder always on (LFG always English)
  overhead = true,                                        -- floating overhead/3D names
  -- (v2.7.0) ONE clean toggle per surface, all under "Surfaces":
  --   surfaceTooltips   : translate the unit-NAME line of tooltips. Drives the DLL
  --                       leaf SetText hook (slot 8 -> g_surface_tooltipName) which
  --                       owns GameTooltipTextLeft1 and re-asserts on every engine
  --                       repaint so it can't revert to Chinese, PLUS a Lua-side
  --                       name-match backup so the tooltip reads identically to the
  --                       overhead / unit frame. Body lines stay with WoWTranslate.
  --   surfaceNameplates : keep default (anonymous) nameplate names English. Drives
  --                       the DLL nameplate gate (slot 9) AND the Lua enforcer that
  --                       re-applies only when the engine reverts a plate to Chinese.
  -- (the old "Experimental Surfaces", "Deep SetText hook" and "Display Consistency"
  -- sections are gone -- their behaviour folded into these two clean toggles).
  -- (v2.7.3) Tooltips default OFF: WoWTranslate owns tooltips out of the box, and
  -- CNFix does not touch GameTooltip at all unless the user opts in. This avoids
  -- the two addons fighting over the tooltip name line. Nameplates default ON.
  surfaceTooltips   = false,
  surfaceNameplates = true,
  nameScale         = 1.0,       -- floating overhead name size (0.5x = half, 2.0 = double)
  nameThresh        = 1.0,       -- distance threshold (1.0 = default 4.0 units; higher = bigger uniform zone)
  nameDistMul       = 1.0,       -- distance growth rate (1.0 = default 0.3x; higher = faster growth at range)
}

local function DB()
  if type(CNFixNamesDB) ~= "table" then CNFixNamesDB = {} end
  for k, v in pairs(DEFAULTS) do
    if CNFixNamesDB[k] == nil then CNFixNamesDB[k] = v end
  end
  -- (v2.7.3) One-time migration: v2.7.0-2 shipped surfaceTooltips defaulting ON,
  -- which let CNFix fight WoWTranslate over the tooltip name line. The corrected
  -- default is OFF (WoWTranslate owns tooltips). Flip the stale saved value ONCE so
  -- existing users get the fixed behavior without manually unchecking; the migration
  -- flag makes it a single reset that still lets the user opt back in afterward.
  if not CNFixNamesDB.__tooltipDefaultMigrated then
    CNFixNamesDB.__tooltipDefaultMigrated = true
    CNFixNamesDB.surfaceTooltips = false
  end
  return CNFixNamesDB
end

-- ---- restore overhead-name CVars (undo damage from an earlier build) ----
-- An earlier build flipped UnitNamePlayer/UnitNamePlayerGuild to "0" to dirty
-- plates; a missed restore left them stuck OFF, hiding ALL overhead names (saved
-- to disk, surviving relaunch). Restore them on entering the world -- CVars are
-- only reliably settable AFTER login, not at addon-load (the engine applies the
-- saved values during login and would clobber a load-time SetCVar). We NEVER set
-- these to "0" anywhere again.
local function HealNameCVars()
  pcall(SetCVar, "UnitNamePlayer", "1")
  pcall(SetCVar, "UnitNamePlayerGuild", "1")
end
local healFrame = CreateFrame("Frame")
healFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
healFrame:RegisterEvent("PLAYER_LOGIN")
healFrame:SetScript("OnEvent", HealNameCVars)

-- ---- rebuild floating overhead names (toggle-driven, bulletproof) ----
-- Pulse the overhead-name CVars: toggling them dirties every 3D float so the names
-- recompose through the DLL hooks (this is what makes the Pinyin and master toggles
-- switch instantly). We pulse not just the PLAYER name CVars but also the PET /
-- GUARDIAN / TOTEM / NPC name CVars, because a hunter pet / warlock minion float
-- ("<Owner>'s Minion") is a PET/GUARDIAN overhead name -- pulsing only
-- UnitNamePlayer never dirtied it, so a pet's owner name never switched on a
-- Pinyin/English toggle (it kept the stale baked value). 
--   * UnitNamePlayer / UnitNamePlayerGuild keep their HARD restore to "1" (the
--     anti-strand safety from earlier builds: they must never be left off or all
--     player overhead names vanish).
--   * The pet/guardian/totem/NPC CVars are CAPTURED before the pulse and restored
--     to their captured value, so we never force-ENABLE a name type the user chose
--     to disable -- we only momentarily flip it to dirty the float, then put it back.
-- Called ONLY on explicit user toggles (Pinyin/master/overhead) and on a debounced
-- contextual-arrival pulse, never on a bare timer, so it can't cause continuous
-- flicker.
local PULSE_EXTRA_CVARS = {
  "UnitNameFriendlyPets", "UnitNameFriendlyGuardians", "UnitNameFriendlyTotems",
  "UnitNameEnemyPets", "UnitNameEnemyGuardians", "UnitNameEnemyTotems",
  "UnitNameNonCombatCreatureName", "UnitNameNPC",
}
local pulseFrame, pulseState = nil, 0
local pulseSaved = {}      -- captured values of PULSE_EXTRA_CVARS for the current pulse
local function ensurePulseFrame()
  if pulseFrame then return end
  pulseFrame = CreateFrame("Frame"); pulseFrame.e = 0
  pulseFrame:SetScript("OnUpdate", function()
    pulseFrame.e = pulseFrame.e + (arg1 or 0)
    if pulseState == 1 then
      pcall(SetCVar, "UnitNamePlayer", "1")
      pcall(SetCVar, "UnitNamePlayerGuild", "1")
      -- restore the pet/guardian/totem/NPC CVars to whatever they were before the
      -- pulse (capture-restore: never force-enable a user-disabled name type)
      for i = 1, table.getn(PULSE_EXTRA_CVARS) do
        local cv = PULSE_EXTRA_CVARS[i]
        local v = pulseSaved[cv]
        if v ~= nil then pcall(SetCVar, cv, v) end
      end
      pulseState = 0; pulseFrame.e = 0; return
    end
    if pulseFrame.e >= 2 then            -- idle watchdog: never stay stuck off
      pulseFrame.e = 0
      local ok, v = pcall(GetCVar, "UnitNamePlayer")
      if ok and v == "0" then pcall(SetCVar, "UnitNamePlayer", "1") end
    end
  end)
end
local function PulseOverheadNames()
  ensurePulseFrame()
  pcall(SetCVar, "UnitNamePlayer", "0")        -- dirty player plates for ONE frame
  pcall(SetCVar, "UnitNamePlayerGuild", "0")
  -- Capture-then-dirty the pet/guardian/totem/NPC name CVars so pet floats recompose.
  pulseSaved = {}
  for i = 1, table.getn(PULSE_EXTRA_CVARS) do
    local cv = PULSE_EXTRA_CVARS[i]
    local ok, cur = pcall(GetCVar, cv)
    if ok and cur ~= nil then
      pulseSaved[cv] = cur
      -- only flip a CVar that is currently ON (flipping an already-off one and back
      -- does nothing useful and the float is already hidden anyway)
      if cur == "1" then pcall(SetCVar, cv, "0") end
    end
  end
  pulseState = 1                                -- next frame: restore
end
CNFix_PulseOverheadNames = PulseOverheadNames

-- ---- push current config to the DLL (reuses a hidden FontString) ----
local cfgPusher
local lastOverhead, lastPinyin
local function PushConfig()
  local db = DB()
  if not cfgPusher then
    local f = CreateFrame("Frame"); f:Hide()
    cfgPusher = f:CreateFontString(nil, "BACKGROUND")
    cfgPusher:SetFont("Fonts\\FRIZQT__.TTF", 10)
    if not cfgPusher:GetFont() then cfgPusher:SetFont("Fonts\\ARIALN.TTF", 10) end
  end
  local function b(x) if x then return "1" else return "0" end end
  -- Positional CFG string (v2.7.0):
  --   slots 0..6  -- master, social, unitframes, groupfinder, realtime, pinyin, overhead
  --   slot 7      -- legacy tooltipOwnedByOther (unused; literal "0")
  --   slot 8      -- surfaceTooltips  (drives the DLL leaf hook on the tooltip NAME line)
  --   slot 9      -- surfaceNameplates
  --   slot 10     -- legacy deepHook flag (always "0" now: the leaf installs by signature
  --                  and is gated purely by the surface flags above)
  local s = CFG_CTRL .. b(db.master) .. b(db.social) .. b(db.unitframes)
            .. "1" .. b(db.realtime) .. b(db.pinyin) .. b(db.overhead)
            .. "0"
            .. b(db.surfaceTooltips) .. b(db.surfaceNameplates)
            .. "0"
  pcall(function() cfgPusher:SetText(s) end)
  -- Rebuild floating names immediately when anything that changes their rendered
  -- text flips: the overhead/master toggle (English<->Chinese) OR the
  -- English/Pinyin radio. (v2.1 bug: a pinyin flip called PushConfig but never
  -- pulsed, since `eff` was unchanged -- so baked overhead names kept the old
  -- style until the plate happened to rebuild on its own.)
  local eff = db.master and db.overhead
  local pin = db.pinyin and true or false
  if (lastOverhead ~= nil and lastOverhead ~= eff)
     or (lastPinyin ~= nil and lastPinyin ~= pin) then PulseOverheadNames() end
  lastOverhead = eff
  lastPinyin = pin
end
CNFix_PushConfig = PushConfig   -- exposed so the main file can push on load

-- ---- push name scale to the DLL ----
local scalePusher
local function PushScale()
  local db = DB()
  if not scalePusher then
    local f = CreateFrame("Frame"); f:Hide()
    scalePusher = f:CreateFontString(nil, "BACKGROUND")
    scalePusher:SetFont("Fonts\\FRIZQT__.TTF", 10)
    if not scalePusher:GetFont() then scalePusher:SetFont("Fonts\\ARIALN.TTF", 10) end
  end
  -- Encode scale as 3 digits: 050..300 (0.50x..3.00x)
  local v = math.floor((db.nameScale or 1.0) * 100 + 0.5)
  if v < 50 then v = 50 end
  if v > 300 then v = 300 end
  local s = CFG_SCALE .. string.format("%03d", v)
  pcall(function() scalePusher:SetText(s) end)
end

local function PushThresh()
  local db = DB()
  if not threshPusher then
    local f = CreateFrame("Frame"); f:Hide()
    threshPusher = f:CreateFontString(nil, "BACKGROUND")
    threshPusher:SetFont("Fonts\\FRIZQT__.TTF", 10)
    if not threshPusher:GetFont() then threshPusher:SetFont("Fonts\\ARIALN.TTF", 10) end
  end
  -- Invert the value: UI shows 0.2-3.0 (low=close, far=range)
  -- DLL receives inverted: 3.0->0.33, 1.0->1.0, 0.2->5.0
  -- This makes higher UI values = names stay big at further distance
  local inverted = 1.0 / (db.nameThresh or 1.0)
  local v = math.floor(inverted * 100 + 0.5)
  if v < 20 then v = 20 end
  if v > 500 then v = 500 end
  local s = CFG_THRESH .. string.format("%03d", math.min(v, 300))
  pcall(function() threshPusher:SetText(s) end)
end

local function PushDist()
  local db = DB()
  if not distPusher then
    local f = CreateFrame("Frame"); f:Hide()
    distPusher = f:CreateFontString(nil, "BACKGROUND")
    distPusher:SetFont("Fonts\\FRIZQT__.TTF", 10)
    if not distPusher:GetFont() then distPusher:SetFont("Fonts\\ARIALN.TTF", 10) end
  end
  local v = math.floor((db.nameDistMul or 1.0) * 100 + 0.5)
  if v < 20 then v = 20 end
  if v > 300 then v = 300 end
  local s = CFG_DIST .. string.format("%03d", v)
  pcall(function() distPusher:SetText(s) end)
end

-- ---- the panel ----
local panel
local checks = {}   -- key -> checkbox frame
local radioEng, radioPin
local scaleSlider, scaleVal
local threshSlider, threshVal
local distSlider, distVal

local function Refresh()
  local db = DB()
  -- reflect state
  for key, cb in pairs(checks) do
    cb:SetChecked(db[key])
  end
  if radioEng then
    radioEng:SetChecked(not db.pinyin)
    radioPin:SetChecked(db.pinyin)
  end
  -- master off -> grey out + disable the others (state remembered in DB)
  local on = db.master
  for key, cb in pairs(checks) do
    if key ~= "master" then
      if on then cb:Enable() else cb:Disable() end
      local lbl = cb.label
      if lbl then
        if on then lbl:SetTextColor(0.9, 0.9, 0.9) else lbl:SetTextColor(0.5, 0.5, 0.5) end
      end
    end
  end
  if radioEng then
    if on then radioEng:Enable(); radioPin:Enable()
    else radioEng:Disable(); radioPin:Disable() end
  end
  if scaleSlider and scaleSlider._cnfixRefresh then
    scaleSlider._cnfixRefresh(on)
  end
  if threshSlider and threshSlider._cnfixRefresh then
    threshSlider._cnfixRefresh(on)
  end
  if distSlider and distSlider._cnfixRefresh then
    distSlider._cnfixRefresh(on)
  end
  -- sync slider positions with DB values
  if scaleSlider then
    scaleSlider:SetValue(DB().nameScale or 1.0)
  end
  if scaleVal then
    scaleVal:SetText(string.format("%.1fx", DB().nameScale or 1.0))
  end
  if threshSlider then
    threshSlider:SetValue(DB().nameThresh or 1.0)
  end
  if threshVal then
    threshVal:SetText(string.format("%.1fx", DB().nameThresh or 1.0))
  end
  if distSlider then
    distSlider:SetValue(DB().nameDistMul or 1.0)
  end
  if distVal then
    distVal:SetText(string.format("%.1fx", DB().nameDistMul or 1.0))
  end
end

local function MakeCheck(parent, key, text, sub, x, y)
  local cb = CreateFrame("CheckButton", "CNFixCheck_" .. key, parent, "UICheckButtonTemplate")
  cb:SetWidth(22); cb:SetHeight(22)
  cb:SetPoint("TOPLEFT", x, y)
  local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  lbl:SetText(text)
  cb.label = lbl
  if key == "master" then lbl:SetTextColor(0.3, 1.0, 0.3) end  -- master = green
  if sub then
    local s = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    s:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 4, 2)
    s:SetText(sub)
  end
  cb:SetScript("OnClick", function()
    DB()[key] = cb:GetChecked() and true or false
    Refresh(); PushConfig()
    if CNFix_RefreshSurfaces then CNFix_RefreshSurfaces() end  -- hooks + restores; no Update calls
  end)
  checks[key] = cb
  return cb
end

local function BuildPanel()
  if panel then return panel end
  panel = CreateFrame("Frame", "CNFixPanel", UIParent)
  panel:SetWidth(320); panel:SetHeight(500)
  panel:SetPoint("CENTER", 0, 0)
  panel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  panel:SetMovable(true); panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function() panel:StartMoving() end)
  panel:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
  panel:Hide()

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -16)
  title:SetText("CNFix")

  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  -- master
  MakeCheck(panel, "master", "CNFix", "Translate Chinese names", 22, -44)

  -- divider 1
  local d1 = panel:CreateTexture(nil, "ARTWORK")
  d1:SetTexture(0.4, 0.4, 0.4, 0.6); d1:SetHeight(1)
  d1:SetPoint("TOPLEFT", 18, -86); d1:SetPoint("TOPRIGHT", -18, -86)

  -- name style radios
  local styleHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  styleHdr:SetPoint("TOPLEFT", 20, -96)
  styleHdr:SetText("Name style")

  radioEng = CreateFrame("CheckButton", "CNFixRadioEng", panel, "UIRadioButtonTemplate")
  radioEng:SetPoint("TOPLEFT", 24, -112)
  local le = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  le:SetPoint("LEFT", radioEng, "RIGHT", 3, 0); le:SetText("English")

  radioPin = CreateFrame("CheckButton", "CNFixRadioPin", panel, "UIRadioButtonTemplate")
  radioPin:SetPoint("LEFT", le, "RIGHT", 16, 0)
  local lp = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  lp:SetPoint("LEFT", radioPin, "RIGHT", 3, 0); lp:SetText("Pinyin")

  radioEng:SetScript("OnClick", function()
    DB().pinyin = false; Refresh(); PushConfig()
    if CNFix_RefreshSurfaces then CNFix_RefreshSurfaces() end
  end)
  radioPin:SetScript("OnClick", function()
    DB().pinyin = true; Refresh(); PushConfig()
    if CNFix_RefreshSurfaces then CNFix_RefreshSurfaces() end
  end)

  -- surfaces header
  local surfHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  surfHdr:SetPoint("TOPLEFT", 20, -142)
  surfHdr:SetText("Surfaces")

  -- (v2.7.0) ONE clean checkbox per surface. Tooltips + Nameplates fold in what
  -- used to be the "Experimental Surfaces", "Deep SetText hook" and "Display
  -- Consistency" sections -- no more duplicate switches for the same surface.
  MakeCheck(panel, "social", "Social", nil, 22, -158)
  MakeCheck(panel, "unitframes", "Default UnitFrames", nil, 22, -184)
  MakeCheck(panel, "overhead", "Overhead Names", nil, 22, -210)
  MakeCheck(panel, "surfaceTooltips", "Tooltips", nil, 22, -236)
  MakeCheck(panel, "surfaceNameplates", "Nameplates", nil, 22, -262)

  -- name scale slider
  local scaleHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  scaleHdr:SetPoint("TOPLEFT", 20, -290)
  scaleHdr:SetText("Name Scale")

  scaleSlider = CreateFrame("Slider", "CNFixScaleSlider", panel, "OptionsSliderTemplate")
  scaleSlider:SetWidth(200)
  scaleSlider:SetHeight(16)
  scaleSlider:SetPoint("TOPLEFT", 24, -306)
  scaleSlider:SetMinMaxValues(0.5, 3.0)
  pcall(function() scaleSlider:SetValueStep(0.1) end)
  scaleSlider:SetValue(DB().nameScale or 1.0)
  -- label showing current value
  scaleVal = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  scaleVal:SetPoint("LEFT", scaleSlider, "RIGHT", 8, 0)
  scaleVal:SetText(string.format("%.1fx", DB().nameScale or 1.0))
  scaleSlider:SetScript("OnValueChanged", function()
    local v = scaleSlider:GetValue()
    DB().nameScale = v
    scaleVal:SetText(string.format("%.1fx", v))
    PushScale()
    -- Refresh names to apply new scale immediately
    if CNFix_ThrottledRefreshNames then
      CNFix_ThrottledRefreshNames()
    end
  end)
  -- master off -> grey out slider (vanilla Slider has no Enable/Disable;
  -- use alpha + block input via EnableMouse instead)
  scaleSlider._cnfixRefresh = function(on)
    if on then scaleSlider:SetAlpha(1.0); scaleSlider:EnableMouse(true)
    else scaleSlider:SetAlpha(0.5); scaleSlider:EnableMouse(false) end
  end

  -- distance threshold slider (how far names stay at full size)
  local threshHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  threshHdr:SetPoint("TOPLEFT", 20, -334)
  threshHdr:SetText("Keep Size At Range")

  threshSlider = CreateFrame("Slider", "CNFixThreshSlider", panel, "OptionsSliderTemplate")
  threshSlider:SetWidth(200)
  threshSlider:SetHeight(16)
  threshSlider:SetPoint("TOPLEFT", 24, -350)
  threshSlider:SetMinMaxValues(0.2, 3.0)
  pcall(function() threshSlider:SetValueStep(0.1) end)
  threshSlider:SetValue(DB().nameThresh or 1.0)
  threshVal = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  threshVal:SetPoint("LEFT", threshSlider, "RIGHT", 8, 0)
  threshVal:SetText(string.format("%.1fx", DB().nameThresh or 1.0))
  threshSlider:SetScript("OnValueChanged", function()
    local v = threshSlider:GetValue()
    DB().nameThresh = v
    threshVal:SetText(string.format("%.1fx", v))
    PushThresh()
    -- Refresh names to apply new threshold immediately
    if CNFix_ThrottledRefreshNames then
      CNFix_ThrottledRefreshNames()
    end
  end)
  threshSlider._cnfixRefresh = function(on)
    if on then threshSlider:SetAlpha(1.0); threshSlider:EnableMouse(true)
    else threshSlider:SetAlpha(0.5); threshSlider:EnableMouse(false) end
  end

  -- distance growth multiplier slider (how fast names grow with distance)
  local distHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  distHdr:SetPoint("TOPLEFT", 20, -378)
  distHdr:SetText("Distance Size")

  distSlider = CreateFrame("Slider", "CNFixDistSlider", panel, "OptionsSliderTemplate")
  distSlider:SetWidth(200)
  distSlider:SetHeight(16)
  distSlider:SetPoint("TOPLEFT", 24, -394)
  distSlider:SetMinMaxValues(0.5, 5.0)
  pcall(function() distSlider:SetValueStep(0.1) end)
  distSlider:SetValue(DB().nameDistMul or 1.0)
  distVal = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  distVal:SetPoint("LEFT", distSlider, "RIGHT", 8, 0)
  distVal:SetText(string.format("%.1fx", DB().nameDistMul or 1.0))
  distSlider:SetScript("OnValueChanged", function()
    local v = distSlider:GetValue()
    DB().nameDistMul = v
    distVal:SetText(string.format("%.1fx", v))
    PushDist()
    -- Refresh names to apply new distance multiplier immediately
    if CNFix_ThrottledRefreshNames then
      CNFix_ThrottledRefreshNames()
    end
  end)
  distSlider._cnfixRefresh = function(on)
    if on then distSlider:SetAlpha(1.0); distSlider:EnableMouse(true)
    else distSlider:SetAlpha(0.5); distSlider:EnableMouse(false) end
  end

  -- divider 2
  local d2 = panel:CreateTexture(nil, "ARTWORK")
  d2:SetTexture(0.4, 0.4, 0.4, 0.6); d2:SetHeight(1)
  d2:SetPoint("TOPLEFT", 18, -424); d2:SetPoint("TOPRIGHT", -18, -424)

  -- realtime (separate, with grey disclaimer)
  local rt = MakeCheck(panel, "realtime", "Real-time Contextual names", nil, 22, -436)
  local disc = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  disc:SetPoint("TOPLEFT", rt, "BOTTOMLEFT", 4, 0)
  disc:SetText("(toggle off may reduce framerate drop)")

  Refresh()
  return panel
end

local function Toggle()
  BuildPanel()
  if panel:IsShown() then panel:Hide() else Refresh(); panel:Show() end
end
CNFix_TogglePanel = Toggle

-- ---- minimap button (adapted directly from GudaPlates' working code) ----
local minimapAngle = 220
local function BuildMinimap()
  if CNFixMinimapButton then return end
  if CNFixNamesDB and CNFixNamesDB.minimapAngle then minimapAngle = CNFixNamesDB.minimapAngle end

  local minimapButton = CreateFrame("Button", "CNFixMinimapButton", Minimap)
  minimapButton:SetWidth(32)
  minimapButton:SetHeight(32)
  minimapButton:SetFrameStrata("MEDIUM")
  minimapButton:SetMovable(true)
  minimapButton:EnableMouse(true)
  minimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)
  minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local minimapIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
  minimapIcon:SetTexture("Interface\\Icons\\INV_Misc_Rune_06")
  minimapIcon:SetWidth(20)
  minimapIcon:SetHeight(20)
  minimapIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  minimapIcon:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)

  local minimapBorder = minimapButton:CreateTexture(nil, "OVERLAY")
  minimapBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  minimapBorder:SetWidth(52)
  minimapBorder:SetHeight(52)
  minimapBorder:SetPoint("CENTER", minimapButton, "CENTER", 10, -10)

  local function UpdateMinimapButtonPosition()
    local rad = math.rad(minimapAngle)
    local x = math.cos(rad) * 80
    local y = math.sin(rad) * 80
    minimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - x, y - 52)
  end
  UpdateMinimapButtonPosition()

  minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  minimapButton:RegisterForDrag("LeftButton", "RightButton")
  minimapButton:SetScript("OnDragStart", function()
    this.dragging = true
    this:LockHighlight()
  end)
  minimapButton:SetScript("OnDragStop", function()
    this.dragging = false
    this:UnlockHighlight()
    if CNFixNamesDB then CNFixNamesDB.minimapAngle = minimapAngle end
  end)
  minimapButton:SetScript("OnUpdate", function()
    if this.dragging then
      local xpos, ypos = GetCursorPosition()
      local xmin, ymin = Minimap:GetLeft() or 400, Minimap:GetBottom() or 400
      local mscale = Minimap:GetEffectiveScale()
      local dx = xmin - xpos / mscale + 70
      local dy = ypos / mscale - ymin - 70
      minimapAngle = math.deg(math.atan2(dy, dx))
      UpdateMinimapButtonPosition()
    end
  end)
  minimapButton:SetScript("OnClick", function()
    Toggle()
  end)
  minimapButton:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText("CNFix")
    GameTooltip:AddLine("Click to open settings", 1, 1, 1)
    GameTooltip:AddLine("Drag to move", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ---- slash command ----
SLASH_CNFIX1 = "/cnfix"
SlashCmdList["CNFIX"] = function(msg)
  msg = string.lower(msg or "")
  if msg == "show" or msg == "" then
    Toggle()
  elseif msg == "debug" then
    DB().debug = not DB().debug
    DEFAULT_CHAT_FRAME:AddMessage("CNFix: debug = " .. tostring(DB().debug) .. " (/reload to see surface report)")
  else
    DEFAULT_CHAT_FRAME:AddMessage("CNFix: /cnfix show — open settings")
  end
end

-- ---- boot: build minimap, push initial config a moment after load ----
local booted = false
local boot = CreateFrame("Frame")
boot:RegisterEvent("VARIABLES_LOADED")   -- SavedVariables ready (vanilla)
boot:RegisterEvent("PLAYER_LOGIN")       -- fallback
boot:SetScript("OnEvent", function()
  if booted then return end
  booted = true
  DB()            -- ensures CNFixNamesDB exists + has defaults
  BuildMinimap()
  PushConfig()    -- send saved settings to the DLL
  PushScale()     -- send name scale to the DLL
  PushThresh()    -- send distance threshold to the DLL
  PushDist()      -- send distance multiplier to the DLL
end)
