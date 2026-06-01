-- CNFixSurface.lua — per-surface toggle enforcement (Lua 5.0 / WoW 1.12).
--
-- The DLL hooks SetText globally and translates CJK. To keep a surface in its
-- original language we tag text with "\2" (DLL passthrough = do not translate).
--
-- MECHANISM: per-FontString SetText hook ONLY (no polling). The hook is instant
-- (catches text as it's set -> no English flash) and never touches color (it
-- only prepends \2 to the text argument), so it can't cause the guild gold-flash.
-- We hook the row FontStrings directly, and to be robust on this custom client
-- we also DISCOVER name FontStrings by scanning each list button's children.
--
-- We NEVER call FriendsList_Update / GuildRoster_Update (they open the social
-- window on this client).

local PT = "\2"

local function isOff(key) return CNFixNamesDB and CNFixNamesDB[key] == false end
local function socialOff() return isOff("social") end
local function unitOff()   return isOff("unitframes") end

-- Replace a FontString's SetText so, while the surface is off, its text is
-- prefixed with the passthrough marker. FontStrings only (never bricks buttons).
local function HookFS(fs, keyfn)
  if not fs or fs.__cnfixHooked then return end
  if not fs.GetObjectType or fs:GetObjectType() ~= "FontString" then return end
  if type(fs.SetText) ~= "function" then return end
  fs.__cnfixHooked = true
  local orig = fs.SetText
  fs.SetText = function(self, txt)
    if txt and type(txt) == "string" and keyfn() and string.sub(txt, 1, 1) ~= PT then
      return orig(self, PT .. txt)
    end
    return orig(self, txt)
  end
end

-- Recursively hook every FontString in a frame's subtree (regions + child
-- frames). Robust against unknown names / nested structures (the friends list
-- name fontstring lives somewhere in the button subtree on this client).
local function HookTree(frame, keyfn, depth)
  if not frame or depth > 4 then return end
  if frame.GetRegions then
    local regions = { frame:GetRegions() }
    for i = 1, table.getn(regions) do
      local r = regions[i]
      if r and r.GetObjectType and r:GetObjectType() == "FontString" then
        HookFS(r, keyfn)
      end
    end
  end
  if frame.GetChildren then
    local kids = { frame:GetChildren() }
    for i = 1, table.getn(kids) do
      HookTree(kids[i], keyfn, depth + 1)
    end
  end
end
local function HookAllFontStrings(frame, keyfn)
  HookTree(frame, keyfn, 0)
end

local function HookSocial()
  -- WHO rows (named fontstrings — confirmed working)
  for i = 1, 17 do HookFS(getglobal("WhoFrameButton" .. i .. "Name"), socialOff) end
  -- FRIENDS rows: hook known names AND scan each button's children to catch
  -- whatever this client actually names the name-fontstring.
  for i = 1, 10 do
    HookFS(getglobal("FriendsFrameFriendButton" .. i .. "ButtonTextName"), socialOff)
    HookFS(getglobal("FriendsFrameFriendButton" .. i .. "Name"), socialOff)
    HookAllFontStrings(getglobal("FriendsFrameFriendButton" .. i), socialOff)
    HookAllFontStrings(getglobal("FriendsListFrameScrollFrameButton" .. i), socialOff)
  end
  -- whole friends container subtree (catches whatever this client names it)
  HookAllFontStrings(getglobal("FriendsFrameFriendsScrollFrame"), socialOff)
  HookAllFontStrings(getglobal("FriendsListFrame"), socialOff)
  -- GUILD rows
  for i = 1, 14 do
    HookFS(getglobal("GuildFrameButton" .. i .. "Name"), socialOff)
    HookAllFontStrings(getglobal("GuildFrameButton" .. i), socialOff)
  end
end

local function HookUnits()
  HookFS(getglobal("TargetFrameTextureFrameName"), unitOff)
  HookFS(getglobal("TargetFrameNameText"), unitOff)
  HookAllFontStrings(getglobal("TargetFrame"), unitOff)
  HookFS(getglobal("PlayerFrameTextureFrameName"), unitOff)
  HookAllFontStrings(getglobal("PlayerFrame"), unitOff)
  for i = 1, 4 do
    HookFS(getglobal("PartyMemberFrame" .. i .. "TextureFrameName"), unitOff)
    HookAllFontStrings(getglobal("PartyMemberFrame" .. i), unitOff)
  end
end

-- Event-driven INSTANT restore for the target name (no poll lag). When you
-- click a unit, re-set the real name with \2 immediately if unit frames are off.
local function setUnitNow(unit, names)
  if not unitOff() or not UnitExists(unit) then return end
  local n = UnitName(unit)
  if not n or n == "" then return end
  for idx = 1, table.getn(names) do
    local fs = getglobal(names[idx])
    if fs and fs.SetText and fs.GetObjectType and fs:GetObjectType() == "FontString" then
      fs:SetText(PT .. n); return
    end
  end
end
local function RestoreTargetNow()
  setUnitNow("target", { "TargetFrameTextureFrameName", "TargetFrameNameText", "TargetName" })
end

-- Direct restore used on toggle-change (re-sets visible rows with \2 once).
local function restoreRow(fs, name)
  if fs and fs.SetText and name and name ~= "" then fs:SetText(PT .. name) end
end
local function RestoreFriendsOnce()
  if not socialOff() then return end
  if not (FriendsFrameFriendsScrollFrame and FauxScrollFrame_GetOffset and GetFriendInfo) then return end
  local offset = FauxScrollFrame_GetOffset(FriendsFrameFriendsScrollFrame)
  for i = 1, 10 do
    local name = GetFriendInfo(offset + i)
    if name and name ~= "" then
      restoreRow(getglobal("FriendsFrameFriendButton" .. i .. "ButtonTextName"), name)
      restoreRow(getglobal("FriendsFrameFriendButton" .. i .. "Name"), name)
    end
  end
end

-- Instant WHO revert on toggle (re-set visible rows with \2). Mirrors friends.
local function RestoreWhoOnce()
  if not socialOff() then return end
  if not (WhoListScrollFrame and FauxScrollFrame_GetOffset and GetWhoInfo) then return end
  local offset = FauxScrollFrame_GetOffset(WhoListScrollFrame)
  for i = 1, 17 do
    local fs = getglobal("WhoFrameButton" .. i .. "Name")
    if fs and fs:IsVisible() then
      local name = GetWhoInfo(offset + i)
      if name and name ~= "" then fs:SetText(PT .. name) end
    end
  end
end

-- Instant GUILD revert on toggle (re-set visible rows with \2).
local function RestoreGuildOnce()
  if not socialOff() then return end
  if not (GuildListScrollFrame and FauxScrollFrame_GetOffset and GetGuildRosterInfo) then return end
  local offset = FauxScrollFrame_GetOffset(GuildListScrollFrame)
  for i = 1, 14 do
    local fs = getglobal("GuildFrameButton" .. i .. "Name")
    if fs and fs:IsVisible() then
      local name = GetGuildRosterInfo(offset + i)
      if name and name ~= "" then fs:SetText(PT .. name) end
    end
  end
end

-- Called by the config panel on any toggle/radio change. Hooks (so future
-- redraws are tagged) + one direct restore pass. NO Update() calls.
local function RefreshSurfaces()
  HookSocial(); HookUnits()
  RestoreWhoOnce()
  RestoreFriendsOnce()
  RestoreGuildOnce()
  RestoreTargetNow()
end
CNFix_RefreshSurfaces = RefreshSurfaces

-- (re)hook rows as panels create them. Safe events only (no Update calls).
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("FRIENDLIST_UPDATE")
ev:RegisterEvent("WHO_LIST_UPDATE")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:SetScript("OnEvent", function()
  if event == "PLAYER_TARGET_CHANGED" then
    HookUnits(); RestoreTargetNow()        -- instant target restore, no poll
  else
    HookSocial(); HookUnits()
  end
end)

-- brief warm-up: hook rows for the first few seconds as frames spawn (NO poll
-- restore afterward — the hooks handle everything, so no flash, no color fight).
local warm, acc, n = CreateFrame("Frame"), 0, 0
warm:SetScript("OnUpdate", function()
  acc = acc + (arg1 or 0)
  if acc < 0.5 then return end
  acc = 0
  HookSocial(); HookUnits()
  n = n + 1
  if n >= 12 then warm:SetScript("OnUpdate", nil) end   -- stop after ~6s
end)
