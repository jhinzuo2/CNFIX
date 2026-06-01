-- CNFixConfig.lua — options panel for CNFix.
-- Pushes settings to CNFixEnglish.dll via the \1CNFXCFG\1 control string and
-- stores them in CNFixNamesDB (account-wide). Five checkboxes + an English/Pinyin
-- name-style radio. Master ("CNFix") greys out the rest when off (state kept).

local CFG_CTRL = "\1CNFXCFG\1"

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

-- ---- the panel ----
local panel
local checks = {}   -- key -> checkbox frame
local radioEng, radioPin

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
  panel:SetWidth(320); panel:SetHeight(372)
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

  -- divider 2
  local d2 = panel:CreateTexture(nil, "ARTWORK")
  d2:SetTexture(0.4, 0.4, 0.4, 0.6); d2:SetHeight(1)
  d2:SetPoint("TOPLEFT", 18, -296); d2:SetPoint("TOPRIGHT", -18, -296)

  -- realtime (separate, with grey disclaimer)
  local rt = MakeCheck(panel, "realtime", "Real-time Contextual names", nil, 22, -308)
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
end)
