-- CNFixExtend.lua  --  extra UI-surface coverage for CNFix (Lua 5.0 / WoW 1.12)
--
-- Adds four surfaces the base addon doesn't cover:
--   (1) WorldMap mouseover dot names      [ISOLATED -- see block at bottom]
--   (2) Inspect frame player name
--   (3) Trade frame recipient name
--   (4) Right-click drop-down title / items
--
-- DESIGN RULE (matches the stable CNFixNames.lua, NOT the experimental branch):
--   * ONE naming authority -- the raw WoWTranslate Google value, the same value
--     stable PushPair feeds the DLL for the unit frames. We never reformat it,
--     so every surface agrees with the unit frames.
--   * We only ever WRITE a name we already have from WoWTranslate's cache, using
--     the DLL's "\2" passthrough marker so the DLL writes it verbatim (it never
--     re-composes or re-translates a \2 string). If we don't have the name yet,
--     we RequestName(zh) -- WoWTranslate fetches it, stable PushPair feeds the
--     DLL -- and we re-apply once, a moment later.
--   * Inspect/Trade/DropDown FontStrings are NOT tooltips, so the DLL's own
--     SetText hook already translates them once the name is known; these
--     handlers only add (a) discovery of names the DLL has never seen and
--     (b) an immediate one-shot write for the just-opened frame.
--
-- DELIBERATELY NOT PORTED from the experimental branch (these caused the drift):
--   canonicalize / beautify / rank insertion, guidCache, ttCache, transformLine,
--   lineCache, resolveEnglish, the tooltip scanner + OnUpdate poller, the resize
--   ticker, WoWTranslate suppression, SetUnit/SetHyperlink bypasses, AddLine
--   hooks. None of that is present here.

local PT     = "\2"            -- DLL passthrough marker: "write the rest verbatim"
local PREFIX = "\1wt_name:"    -- WoWTranslate name-cache key prefix

-- ---- tiny helpers (no dependency on the experimental resolution stack) ----
local function isCJK(s)
    return type(s) == "string" and CNFix_HasForeign and CNFix_HasForeign(s)
end
local function isClean(s)
    return type(s) == "string" and s ~= "" and not isCJK(s)
end
-- Write English to a FontString through the DLL passthrough (verbatim, no
-- re-compose). Guarded; only ever writes a clean (non-CJK) value.
-- EXPERIMENT (revertible): CamelCase a clean English name into a single
-- whitespace-free token (matches the DLL tokenize() used by who/nameplate/social
-- and the overhead path). These surfaces carry BARE names (no rank), so the whole
-- value is tokenized. TO REVERT: delete camelToken and restore writeClean to just
-- `pcall(fs.SetText, fs, PT .. en)`.
local function camelToken(s)
    if type(s) ~= "string" or s == "" then return s end
    local out, boundary = "", true
    for i = 1, string.len(s) do
        local c = string.byte(s, i)
        if c == 32 or c == 9 or c == 44 or c == 46 or c == 59 or c == 58 or c == 47 or c == 92
           or c == 45 or c == 95 or c == 39 or c == 34 or c == 40 or c == 41 or c == 91 or c == 93
           or c == 33 or c == 63 or c == 61 or c == 43 or c == 38 then
            boundary = true
        else
            if boundary and c >= 97 and c <= 122 then c = c - 32 end
            out = out .. string.char(c); boundary = false
        end
    end
    if out == "" then return s end
    return out
end
-- Probe FontString: writing zh runs the SAME DLL resolver the real frames use,
-- so reading it back gives exactly what the DLL renders zh as in the CURRENT mode
-- (pinyin -> romanized; English -> CamelCase). A unique per-call color defeats the
-- DLL's per-key result cache so each probe reflects the live mode/learned state.
local _probe
local function dllOf(zh)
    if not (zh and zh ~= "") then return nil end
    if not _probe then
        local pf = CreateFrame("Frame"); pf:Hide()
        if pf.CreateFontString then
            _probe = pf:CreateFontString(nil, "BACKGROUND")
            if _probe.SetFont then _probe:SetFont("Fonts\\FRIZQT__.TTF", 10) end
            if _probe.GetFont and not _probe:GetFont() then _probe:SetFont("Fonts\\ARIALN.TTF", 10) end
        end
    end
    if not (_probe and _probe.SetText and _probe.GetText) then return nil end
    local salt = string.format("%02x", math.mod(math.random(0, 255), 256))
    -- (perf) pcall the methods directly rather than allocating a closure per call.
    if not pcall(_probe.SetText, _probe, "|cff0000" .. salt .. zh) then return nil end
    local ok, t = pcall(_probe.GetText, _probe)
    if not ok or type(t) ~= "string" then return nil end
    local a, b = string.find(t, "^|c%x%x%x%x%x%x%x%x")
    if a then t = string.sub(t, b + 1) end
    return t
end
-- Write the DLL's rendering of `zh` to a FontString via the \2 passthrough so
-- inspect/trade/dropdown match overhead/who in BOTH modes:
--   pinyin mode  -> the DLL's romanization (e.g. "WeiLiang")
--   English mode -> the CamelCase contextual English (`en`, tokenized)
local function writeName(fs, zh, en)
    if not (fs and fs.SetText) then return end
    if CNFixNamesDB and CNFixNamesDB.pinyin then
        local py = dllOf(zh)                                   -- DLL romanization (pinyin)
        if isClean(py) then pcall(fs.SetText, fs, PT .. py) end
        return
    end
    if isClean(en) then pcall(fs.SetText, fs, PT .. camelToken(en)) end   -- CamelCase English
end
-- Raw WoWTranslate Google value for a Chinese name (nil until cached). NO
-- reformatting -- identical to what stable PushPair sends the DLL.
local function wtName(zh)
    if not (WoWTranslate_CacheGet and zh and zh ~= "") then return nil end
    local ok, v = pcall(WoWTranslate_CacheGet, PREFIX .. zh)
    if ok and isClean(v) then return v end
    return nil
end
-- Ask WoWTranslate to fetch a name we don't have yet (feeds the DLL via the
-- base addon's PushPair). No-op for non-CJK or when WT is absent.
local function request(zh)
    if isCJK(zh) and CNFix_RequestName then pcall(CNFix_RequestName, zh) end
end
-- Respect the CNFix master toggle (the only toggle these surfaces honour).
local function enabled()
    if type(CNFixNamesDB) ~= "table" then return true end
    return CNFixNamesDB.master ~= false
end

-- ---- minimal one-shot scheduler (single shared frame, no per-call leak) ----
-- Used to re-apply a name once WoWTranslate's async result arrives for a
-- freshly-opened frame, and to walk a drop-down one frame after it opens.
-- It is NOT a poller: each entry fires exactly once, and the frame hides
-- itself when nothing is pending.
local timers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:Hide()
timerFrame:SetScript("OnUpdate", function()
    local n = table.getn(timers)
    if n == 0 then timerFrame:Hide(); return end
    local dt = arg1 or 0
    local survivors, due = {}, {}
    for i = 1, n do
        local t = timers[i]
        t.e = t.e + dt
        if t.e >= t.delay then table.insert(due, t.fn) else table.insert(survivors, t) end
    end
    for i = n + 1, table.getn(timers) do table.insert(survivors, timers[i]) end  -- defensive
    timers = survivors                                  -- swap BEFORE firing, so a callback's
    for i = 1, table.getn(due) do pcall(due[i]) end     -- own after() appends to the live list
    if table.getn(timers) == 0 then timerFrame:Hide() end
end)
local function after(delay, fn)
    table.insert(timers, { delay = delay, e = 0, fn = fn })
    timerFrame:Show()
end

-- ============================================================
-- (2) INSPECT FRAME  --  player name at the top
-- ============================================================
-- The name FontString is named on most clients but anonymous on some custom
-- ones, so we try the known names first, then fall back to walking
-- InspectFrame's regions for the FontString that currently holds the zh.
local function findInspectNameFS(zh)
    local names = { "InspectFrameUnitName", "InspectNameText", "InspectTitleText",
                    "InspectFrameNameText", "InspectFramePortraitName" }
    for i = 1, table.getn(names) do
        local fs = getglobal(names[i])
        if fs and fs.SetText then return fs end
    end
    if InspectFrame and InspectFrame.GetRegions and zh and zh ~= "" then
        local regions = { InspectFrame:GetRegions() }
        for i = 1, table.getn(regions) do
            local r = regions[i]
            if r and r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
                local ok, t = pcall(function() return r:GetText() end)
                if ok and t and (t == zh or string.find(t, zh, 1, true)) then return r end
            end
        end
    end
    return nil
end

local function applyInspect()
    if not enabled() then return end
    local zh = UnitName and UnitName("target")
    if not (zh and isCJK(zh)) then return end
    request(zh)                          -- ensure it's fetched/learned
    local en = wtName(zh)
    local pinyin = CNFixNamesDB and CNFixNamesDB.pinyin
    if not en and not pinyin then return end   -- english needs the WT value; pinyin doesn't
    local fs = findInspectNameFS(zh)
    if not fs then return end
    writeName(fs, zh, en)
    if fs.SetWidth then pcall(fs.SetWidth, fs, 0) end   -- auto-fit longer English
end

-- Run now, and once more shortly after to catch WoWTranslate's async arrival.
local function inspectRefresh()
    applyInspect()
    after(1.5, applyInspect)
end

local iEv = CreateFrame("Frame")
iEv:RegisterEvent("PLAYER_LOGIN")
iEv:RegisterEvent("INSPECT_READY")
iEv:RegisterEvent("UNIT_INVENTORY_CHANGED")
iEv:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        if InspectFrame_Show then
            local orig = InspectFrame_Show
            InspectFrame_Show = function(unit) pcall(orig, unit); inspectRefresh() end
        end
    elseif event == "INSPECT_READY" then
        inspectRefresh()
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if InspectFrame and InspectFrame.IsShown and InspectFrame:IsShown() then
            applyInspect()
        end
    end
end)

-- ============================================================
-- (3) TRADE FRAME  --  recipient name
-- ============================================================
local function applyTrade()
    if not enabled() then return end
    local fs = getglobal("TradeFrameRecipientNameText")
    if not fs then return end
    local zh = UnitName and UnitName("npc")
    if not (zh and isCJK(zh)) then return end
    request(zh)
    local en = wtName(zh)
    if en or (CNFixNamesDB and CNFixNamesDB.pinyin) then writeName(fs, zh, en) end
end

local tEv = CreateFrame("Frame")
tEv:RegisterEvent("TRADE_SHOW")
tEv:RegisterEvent("TRADE_UPDATE")
tEv:SetScript("OnEvent", function()
    applyTrade()
    after(1.5, applyTrade)
end)

-- ============================================================
-- (4) RIGHT-CLICK DROP-DOWN  --  gold title + any CJK item
-- ============================================================
-- Walk the open DropDownList<i> tree; for each CJK FontString, write the known
-- WoWTranslate value (\2 passthrough) and request any we don't have yet.
-- (No transformLine, no per-line cache -- exact bare-name lookup only, which is
-- what the unit-popup title is.)
local function walkTranslate(frame, depth)
    if not frame or depth > 4 then return end
    if frame.GetRegions then
        local regions = { frame:GetRegions() }
        for i = 1, table.getn(regions) do
            local r = regions[i]
            if r and r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
                local ok, t = pcall(function() return r:GetText() end)
                if ok and t and isCJK(t) then
                    local en = wtName(t)
                    if en or (CNFixNamesDB and CNFixNamesDB.pinyin) then
                        writeName(r, t, en)
                        if r.SetWidth then pcall(r.SetWidth, r, 0) end
                    end
                    if not en then request(t) end   -- fetch English so it's ready if they switch back
                end
            end
        end
    end
    if frame.GetChildren then
        local kids = { frame:GetChildren() }
        for i = 1, table.getn(kids) do walkTranslate(kids[i], depth + 1) end
    end
end

-- Widen a list so the longest button text fits (cosmetic; self-contained;
-- mirrors vanilla UIDropDownMenu_RefreshAll width logic). pcall-guarded.
local function widenList(list)
    if not (list and list.SetWidth and list.GetName) then return end
    local maxW = 0
    for b = 1, 32 do
        local fs = getglobal(list:GetName() .. "Button" .. b .. "NormalText")
        if fs and fs.GetStringWidth then
            local ok, w = pcall(function() return fs:GetStringWidth() end)
            if ok and w and w > maxW then maxW = w end
        end
    end
    if maxW > 0 then
        local pad = 32
        pcall(list.SetWidth, list, maxW + pad)
        for b = 1, 32 do
            local btn = getglobal(list:GetName() .. "Button" .. b)
            if btn and btn.SetWidth then pcall(btn.SetWidth, btn, maxW + pad - 6) end
        end
    end
end

local function fixDropDowns()
    if not enabled() then return end
    for lvl = 1, 4 do
        local list = getglobal("DropDownList" .. lvl)
        if list and list.IsShown and list:IsShown() then
            pcall(walkTranslate, list, 0)
            pcall(widenList, list)
        end
    end
end

-- A drop-down's buttons are populated one frame AFTER it opens, so defer the
-- walk by a single tick. One-shot via the shared scheduler -- not a poller.
local function deferredFix() after(0.03, fixDropDowns) end

if UnitPopup_ShowMenu then
    local orig = UnitPopup_ShowMenu
    UnitPopup_ShowMenu = function(dropdownMenu, which, unit, name, userData)
        pcall(orig, dropdownMenu, which, unit, name, userData)
        deferredFix()
    end
end
if ToggleDropDownMenu then
    local orig = ToggleDropDownMenu
    ToggleDropDownMenu = function(...)
        local ok, ret = pcall(orig, unpack(arg))
        deferredFix()
        if ok then return ret end
    end
end

-- ============================================================
-- (1) WORLDMAP MOUSEOVER  --  map-dot player names      [ISOLATED]
-- ============================================================
-- The DLL skips *Tooltip* frames by design (lesson #5), so WorldMap dot names
-- stay Chinese unless WE translate them. WoWTranslate does NOT touch
-- WorldMapTooltip, so there is no ownership conflict and none of the
-- GameTooltip instability applies -- this block is WorldMapTooltip-ONLY.
--
-- Map names get populated three ways, so we cover all three (and only on
-- WorldMapTooltip): the tooltip's AddLine, its tooltip-wide SetText, and direct
-- writes to its line FontStrings. AddLine CREATES those line FontStrings lazily
-- -- which is exactly why a line-only hook installed at login missed them and
-- nothing translated. So after AddLine we re-walk and re-hook the lines, and an
-- OnShow scan is the final safety net for any path the method hooks miss.
-- Same clean primitives as the other surfaces: exact WT lookup (wtName), \2
-- passthrough write, request-if-unknown, and it naturally "applies once" on the
-- next show after WoWTranslate returns.
--   NO transformLine, NO canonicalize, NO resize ticker, NO OnUpdate polling,
--   NO WT suppression, NO GameTooltip. Delete this whole block to drop map
--   support -- nothing else depends on it.
local WMTIP = "WorldMapTooltip"

-- Translate one CJK map line: returns the \2-wrapped English if WT already
-- knows it; otherwise requests it (so the NEXT show is translated) and nil.
local function wmTranslate(text)
    if type(text) ~= "string" or not isCJK(text) then return nil end
    if string.byte(text) == 2 then return nil end    -- already a \2 passthrough
    -- Pinyin mode: render via the DLL probe (same path inspect/trade/dropdown use)
    -- so the map mouseover stays consistent with the rest in BOTH modes.
    if CNFixNamesDB and CNFixNamesDB.pinyin then
        local py = dllOf(text)
        if isClean(py) then return PT .. py end
        return nil
    end
    local en = wtName(text)
    if en then return PT .. camelToken(en) end       -- CamelCase contextual English
    request(text)
    return nil
end

-- Instance SetText hook on a single line FontString.
local function hookWMLine(fs)
    if not (fs and fs.SetText) or fs.__cnfixWM then return end
    fs.__cnfixWM = true
    local orig = fs.SetText
    fs.SetText = function(self, text)
        if enabled() then
            local rep = wmTranslate(text)
            if rep then return orig(self, rep) end
        end
        return orig(self, text)
    end
end

-- (Re-)hook every existing line FontString (TextLeft/Right 1..32).
local function hookWMLines()
    for i = 1, 32 do
        hookWMLine(getglobal(WMTIP .. "TextLeft"  .. i))
        hookWMLine(getglobal(WMTIP .. "TextRight" .. i))
    end
end

-- One-shot scan of the shown lines (called from OnShow) -- NOT a poller.
-- Catches names set by a path the method hooks didn't intercept.
local function scanWM()
    if not enabled() then return end
    for i = 1, 32 do
        local fs = getglobal(WMTIP .. "TextLeft" .. i)
        if fs and fs.GetText then
            local ok, t = pcall(function() return fs:GetText() end)
            if ok then
                local rep = wmTranslate(t)
                if rep then pcall(fs.SetText, fs, rep) end
            end
        end
    end
end

local function installWorldMap()
    local tip = WorldMapTooltip
    if not tip then return end
    hookWMLines()
    -- AddLine: translate the added text inline, THEN re-hook (a new TextLeft
    -- FontString may have just been created by the original AddLine).
    if tip.AddLine and not tip.__cnfixWMAdd then
        tip.__cnfixWMAdd = true
        local orig = tip.AddLine
        tip.AddLine = function(self, text, r, g, b, wrap)
            local out = text
            if enabled() then local rep = wmTranslate(text); if rep then out = rep end end
            local ok, ret = pcall(orig, self, out, r, g, b, wrap)
            pcall(hookWMLines)
            if ok then return ret end
        end
    end
    -- Tooltip-wide SetText.
    if tip.SetText and not tip.__cnfixWMSet then
        tip.__cnfixWMSet = true
        local orig = tip.SetText
        tip.SetText = function(self, text)
            local out = text
            if enabled() then local rep = wmTranslate(text); if rep then out = rep end end
            return orig(self, out)
        end
    end
    -- OnShow scan (safety net), chained so any existing handler still runs.
    if tip.GetScript and not tip.__cnfixWMShow then
        tip.__cnfixWMShow = true
        local prev = tip:GetScript("OnShow")
        tip:SetScript("OnShow", function()
            if prev then pcall(prev) end
            scanWM()
        end)
    end
end

local wmEv = CreateFrame("Frame")
wmEv:RegisterEvent("PLAYER_LOGIN")
wmEv:RegisterEvent("WORLD_MAP_UPDATE")   -- re-run is idempotent (guards above)
wmEv:SetScript("OnEvent", function() pcall(installWorldMap) end)

-- ============================================================
-- (5) LIVE GOOGLE-NAME UPGRADE  --  any visible surface still on word-sub
-- ============================================================
-- WHY: the DLL prefers the Google ("contextual") name (resolve() checks
-- g_learned BEFORE smart_compose) but only re-resolves a frame when that frame
-- runs SetText again. A name drawn before its Google value arrived stays on the
-- word-sub fallback until something repaints it. (Tooltips look right because
-- WoWTranslate repaints them every hover; a warm CNFix_learned.txt looks right
-- because the Google name is already learned at first draw.)
--
-- RULE (per spec): when Google learns  ChineseName -> MagicNeverDies, every
-- visible surface whose TRUE SOURCE is ChineseName must be re-set to
-- ChineseName so the DLL resolves it to the Google hit. We NEVER feed the
-- fallback English (MagicNoDeath) back in -- that loses the source and the DLL
-- cannot upgrade it. For a frame that only exposes fallback text we recover the
-- Chinese via fb2zh (a fallback->Chinese map we build as we observe frames).
--
-- COVERAGE: Blizzard unit frames (named), plus a bounded source-recovery walk
-- over WorldFrame (nameplates) and UIParent (pfUI/custom unit frames, social &
-- group rows). The who list also gets a safe full repaint (WhoList_Update). We
-- still must NOT call FriendsList_Update / GuildRoster_Update (they open the
-- social window on this client) -- those rows are handled by the walk instead.

local function dbg(msg)
    if CNFixNamesDB and CNFixNamesDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFix UP|r " .. msg)
    end
end

-- strip WoW color/link formatting so a decorated display matches a bare key
local function stripFmt(s)
    if type(s) ~= "string" then return "" end
    local r = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    r = string.gsub(r, "|r", "")
    r = string.gsub(r, "|H.-|h", "")
    r = string.gsub(r, "|h", "")
    r = string.gsub(r, "^%s+", "")
    r = string.gsub(r, "%s+$", "")
    return r
end
-- leading color escape of a string ("" if none) so we can re-wrap a recovered name
local function leadingColor(s)
    local a, b = string.find(s, "^|c%x%x%x%x%x%x%x%x")
    if a then return string.sub(s, 1, b) end
    return ""
end

-- fallback->Chinese recovery map: DLL display (bare) -> original Chinese source.
-- Built whenever we observe a frame whose Chinese source we already know
-- (e.g. a unit frame: UnitName gives the source, GetText gives the display).
local fb2zh = {}
local function noteDisplay(display, zh)
    if type(display) ~= "string" then return end
    local b = string.byte(display)
    if b and b < 32 then return end                 -- skip control-prefixed (\1/\2)
    local bare = stripFmt(display)
    if bare == "" or isCJK(bare) then return end     -- only record ASCII (fallback/google)
    if zh and isCJK(zh) then fb2zh[bare] = zh end
end

-- Given a FontString's current text, return (textToWrite, sourceZh) such that
-- writing textToWrite makes the DLL re-resolve the name. nil if unrecoverable.
local function recoverSource(cur)
    if type(cur) ~= "string" or cur == "" then return nil, nil end
    local b = string.byte(cur)
    if b and b < 32 then return nil, nil end          -- our \1 push / \2 passthrough -- never touch
    local bare = stripFmt(cur)
    if bare == "" then return nil, nil end
    if isCJK(bare) then return cur, bare end          -- still Chinese: re-set verbatim (keeps color)
    local zh = fb2zh[bare]                             -- ASCII fallback: recover the Chinese
    if zh then return leadingColor(cur) .. zh, zh end  -- re-wrap with the original color
    return nil, nil
end

local resetCount = 0
-- Generic repaint of one FontString: recover its Chinese source and, if that
-- name just upgraded, re-set it so the DLL renders the Google value.
local function repaintFS(fs, pend)
    if not (fs and fs.GetText and fs.SetText) then return end
    local ok, cur = pcall(function() return fs:GetText() end)
    if not ok or type(cur) ~= "string" or cur == "" then return end
    local writeText, srcZh = recoverSource(cur)
    if not (writeText and srcZh and pend[srcZh]) then return end
    pcall(fs.SetText, fs, writeText)
    local ok2, newc = pcall(function() return fs:GetText() end)
    if ok2 then noteDisplay(newc, srcZh) end
    resetCount = resetCount + 1
    dbg("walk-reset src=" .. srcZh .. " before=" .. cur .. " after=" .. tostring(ok2 and newc or "?"))
end

-- Bounded recursive walk: re-set any name FontString whose source just upgraded.
local function walkRepaint(frame, pend, depth, budget)
    if not frame or depth > 5 or budget.n <= 0 then return end
    if frame.GetRegions then
        local rs = { frame:GetRegions() }
        for i = 1, table.getn(rs) do
            if budget.n <= 0 then return end
            local r = rs[i]
            if r and r.GetObjectType and r.GetText and r:GetObjectType() == "FontString" then
                budget.n = budget.n - 1
                repaintFS(r, pend)
            end
        end
    end
    if frame.GetChildren then
        local ks = { frame:GetChildren() }
        for i = 1, table.getn(ks) do
            if budget.n <= 0 then return end
            walkRepaint(ks[i], pend, depth + 1, budget)
        end
    end
end

-- ============================================================
-- (v2.6.0) DEFAULT NAMEPLATE ENGLISH ENFORCER  --  fixes "revert to Chinese"
-- ============================================================
-- Default Blizzard nameplate name FontStrings are ANONYMOUS at the C level and the
-- 1.12 engine repaints them through an internal C++ path that BYPASSES the Lua
-- :SetText glue. So the glue hook translates a plate once on first paint, then the
-- engine overwrites it back to Chinese on a later refresh and the English "reverts".
-- (deepHook could intercept the leaf, but it bails on anonymous frames and steals
-- raw Chinese from WoWTranslate's tooltip harvest -- so it's the wrong tool here.)
--
-- FIX (pure addon-side, no DLL flag change): a lightly throttled enforcer walks
-- WorldFrame and, for any name FontString whose text is CURRENTLY Chinese (the
-- engine just reverted it), re-:SetText the SAME string from Lua. That round-trips
-- through the glue hook (0x79D760 -> translate_preserving, now MULTI-RUN) and renders
-- English. CJK-ONLY trigger means when our English is still showing we do nothing --
-- no churn, no flicker, no fight with the engine's name colour. Bounded by interval +
-- depth + budget so cost stays in line with the existing event-driven walkRepaint.
-- Now driven by the single "Nameplates" toggle (surfaceNameplates): gated by master + surfaceNameplates.
local NP_INTERVAL = 0.12     -- seconds between sweeps (~8/s; engine reverts are slow)
local NP_DEPTH    = 3        -- WorldFrame -> plate -> name-region container
local NP_BUDGET   = 120      -- max FontStrings inspected per sweep

-- (v2.7.1) Nameplate enforcer with UPGRADE support.
-- Two jobs, both routing through the Lua glue (0x79D760 -> translate_preserving),
-- whose resolve() cache is invalidated the moment a contextual is learned:
--   1. CJK plate (engine just wrote / reverted to raw Chinese): re-SetText it so
--      the glue translates it, and RECORD the word-sub -> zh mapping in fb2zh so
--      we can recover it later even for players we never targeted.
--   2. English plate already showing a word-sub: if we know its raw zh (fb2zh) and
--      re-resolving that zh through the glue now yields a DIFFERENT (contextual)
--      string, re-SetText the raw zh so the plate upgrades word-sub -> contextual.
--      This is the fix for plates that used to stick on the word-sub until a
--      /reload or a nameplate toggle, because the engine doesn't re-set an
--      unchanged plate name on its own and the old CJK-only check skipped English.
-- The upgrade re-set happens at most once per (plate, target-text) because after
-- it lands, cur == the contextual and the guard below stops re-writing.
-- npUpExamined throttles the (relatively costly) dllOf probe: once we've checked a
-- given word-sub and found no better form yet, we don't re-probe it until either a
-- contextual lands (CNFix_OnUpgrade clears the set) or the displayed text changes.
local npUpExamined = {}
local function npEnforceFS(fs)
    if not (fs and fs.GetText and fs.SetText) then return end
    -- (perf) pcall the method directly instead of wrapping it in a fresh closure
    -- each call -- this runs on every nameplate FontString ~8x/sec, so the closure
    -- allocation was needless GC churn.
    local ok, cur = pcall(fs.GetText, fs)
    if not ok or type(cur) ~= "string" or cur == "" then return end
    local b = string.byte(cur)
    if b and b < 32 then return end            -- our \1 push / \2 passthrough -- never touch
    if isCJK(cur) then
        -- Raw Chinese on the plate: round-trip through the glue so it translates.
        -- (perf) Throttle by the exact CJK string: if we already round-tripped this
        -- text and it came back STILL Chinese (the DLL hasn't learned it yet), don't
        -- re-SetText it every 0.12s sweep -- that was repeated no-op SetText churn on
        -- untranslatable plates. The throttle is cleared on every contextual arrival
        -- (CNFix_ClearNpUpgradeThrottle), so a name becomes re-checkable the moment
        -- something new is learned.
        if npUpExamined[cur] then return end
        pcall(fs.SetText, fs, cur)
        local ok2, rendered = pcall(fs.GetText, fs)
        if ok2 and type(rendered) == "string" then
            noteDisplay(rendered, stripFmt(cur))
            if isCJK(rendered) then npUpExamined[cur] = true end  -- still Chinese -> stop hammering
        end
        return
    end
    -- English on the plate: try to UPGRADE it if a better (contextual) form is now
    -- known. Recover the raw zh from the displayed word-sub via fb2zh.
    local bare = stripFmt(cur)
    if bare == "" then return end
    if npUpExamined[bare] then return end       -- already checked this word-sub; no new contextual yet
    local zh = fb2zh[bare]
    if not zh then npUpExamined[bare] = true; return end   -- unknown source -> can't upgrade; don't re-probe
    -- Ask the DLL what it renders zh as RIGHT NOW (live g_learned). dllOf uses a
    -- unique salt internally so it always reflects the current learned state.
    local nowRender = dllOf and dllOf(zh)
    if type(nowRender) ~= "string" or nowRender == "" then npUpExamined[bare] = true; return end
    if isCJK(nowRender) then npUpExamined[bare] = true; return end        -- DLL still has no clean translation
    if stripFmt(nowRender) == bare then npUpExamined[bare] = true; return end  -- unchanged -> no churn
    -- A contextual (or otherwise improved) translation exists: re-set the raw zh so
    -- the glue renders the new value, preserving the plate's current colour.
    pcall(fs.SetText, fs, leadingColor(cur) .. zh)
    local ok3, newc = pcall(fs.GetText, fs)
    if ok3 and type(newc) == "string" then noteDisplay(newc, zh) end
end
-- Cleared whenever a contextual upgrade lands so stuck word-subs get re-examined
-- on the next sweep (one probe per word-sub, then re-throttled).
CNFix_ClearNpUpgradeThrottle = function() npUpExamined = {} end

local function npWalk(frame, depth, budget)
    if not frame or depth > NP_DEPTH or budget.n <= 0 then return end
    if frame.IsShown and not frame:IsShown() then return end   -- skip hidden plates (cheap)
    if frame.GetRegions then
        local rs = { frame:GetRegions() }
        for i = 1, table.getn(rs) do
            if budget.n <= 0 then return end
            local r = rs[i]
            if r and r.GetObjectType and r.GetText and r:GetObjectType() == "FontString" then
                budget.n = budget.n - 1
                npEnforceFS(r)
            end
        end
    end
    if frame.GetChildren then
        local ks = { frame:GetChildren() }
        for i = 1, table.getn(ks) do
            if budget.n <= 0 then return end
            npWalk(ks[i], depth + 1, budget)
        end
    end
end

local npFrame = CreateFrame("Frame")
local npAccum = 0
local npBudget = { n = 0 }      -- (perf) reused across sweeps; no per-sweep table alloc
npFrame:SetScript("OnUpdate", function()
    npAccum = npAccum + (arg1 or 0)
    if npAccum < NP_INTERVAL then return end
    npAccum = 0
    local db = CNFixNamesDB
    if db and db.master == false then return end           -- master off -> idle
    if not (db and db.surfaceNameplates) then return end    -- (v2.7.0) single clean "Nameplates" toggle
    local wf = getglobal("WorldFrame")
    if not wf then return end
    npBudget.n = NP_BUDGET
    pcall(npWalk, wf, 0, npBudget)
end)

-- Named Blizzard unit-name FontStrings (cheapest, exact, color-free path).
local UNIT_ROWS = {
    { unit = "target",    fs = { "TargetFrameTextureFrameName", "TargetFrameNameText" } },
    { unit = "player",    fs = { "PlayerFrameTextureFrameName", "PlayerName" } },
    { unit = "mouseover", fs = { "MouseoverFrameTextureFrameName" } },
}
for i = 1, 4 do
    UNIT_ROWS[table.getn(UNIT_ROWS) + 1] =
        { unit = "party" .. i, fs = { "PartyMemberFrame" .. i .. "TextureFrameName" } }
end

-- Re-set a Blizzard unit frame from its RAW name, and harvest its fallback->zh
-- (works even when the Blizzard frame is hidden under pfUI -- GetText still
-- returns the DLL's output, which is exactly the fallback string the visible
-- pfUI frame is stuck on, so the walk can then recover it).
local function repaintUnit(row, pend)
    if not UnitExists(row.unit) then return end
    local nm = UnitName(row.unit)
    if not (nm and isCJK(nm)) then return end
    local match = pend[nm] ~= nil
    for j = 1, table.getn(row.fs) do
        local fs = getglobal(row.fs[j])
        if fs and fs.SetText and fs.GetText then
            local ok, cur = pcall(function() return fs:GetText() end)
            if ok then noteDisplay(cur, nm) end          -- harvest fallback->zh
            if match then
                pcall(fs.SetText, fs, nm)
                local ok2, aft = pcall(function() return fs:GetText() end)
                dbg("unit=" .. row.unit .. " fs=" .. row.fs[j] .. " src=" .. nm
                    .. " before=" .. tostring(ok and cur or "?")
                    .. " after=" .. tostring(ok2 and aft or "?"))
            end
        end
    end
end

local pendingUpgrade = {}
local upgradeQueued  = false
local throttledOverheadPulse   -- fwd (defined below; min-interval pulse throttle)
local function flushUpgrade()
    upgradeQueued = false
    local pend = pendingUpgrade
    pendingUpgrade = {}
    if not (UnitExists and UnitName) then return end
    local db = CNFixNamesDB
    if db and db.master == false then return end

    if CNFixNamesDB and CNFixNamesDB.debug then
        for zh, en in pairs(pend) do dbg("upgrade " .. zh .. " -> " .. tostring(en)) end
    end
    resetCount = 0

    -- 1. Named Blizzard unit frames (also harvests fallback->zh for the walk)
    if not (db and db.unitframes == false) then
        for i = 1, table.getn(UNIT_ROWS) do repaintUnit(UNIT_ROWS[i], pend) end
        if getglobal("RaidGroupButton1") then
            for i = 1, 40 do
                repaintUnit({ unit = "raid" .. i, fs = { "RaidGroupButton" .. i .. "Name" } }, pend)
            end
        end
    end

    -- 2. Bounded walk for nameplates + custom unit frames (pfUI) + social/group rows
    local budget = { n = 150 }   -- was 800: cut per-upgrade frame-walk cost (mouseover stutter)
    pcall(walkRepaint, getglobal("WorldFrame"), pend, 0, budget)   -- nameplates
    pcall(walkRepaint, getglobal("UIParent"),   pend, 0, budget)   -- pfUI / social / group

    -- 3. Who list: safe full repaint when visible (rows re-resolve via the DLL)
    if not (db and db.social == false)
       and WhoList_Update
       and FriendsFrameWhoFrame and FriendsFrameWhoFrame.IsVisible
       and FriendsFrameWhoFrame:IsVisible() then
        pcall(WhoList_Update)
    end

    -- 4. Floating 3D overhead names + guild tags are engine-baked text objects,
    -- not FontStrings, so the SetText repaints above can't reach them. They render
    -- through the overhead GETTER hooks, which read the DLL's live g_learned, so a
    -- float adopts a freshly-learned contextual on its NEXT recompose. The engine
    -- only recomposes a plate when it's dirtied, which can be many seconds away --
    -- that was the "3D float takes ages / needs a toggle" lag. Pulse the plate
    -- dirty-bit CVars ONCE here. This runs only when a contextual actually arrived
    -- (event-driven and debounced into one pulse by CNFix_OnUpgrade), so unlike a
    -- periodic pulse it does not cause continuous flicker -- it fires a single
    -- recompose right when there is genuinely something new to show.
    if not (db and db.overhead == false) then
        throttledOverheadPulse()
    end

    dbg("flush done: walk-resets=" .. resetCount .. " fb2zh-size=" .. (function()
        local c = 0; for _ in pairs(fb2zh) do c = c + 1 end; return c end)())
end

-- (v2.7.2) Min-interval throttle for the overhead/3D-float pulse. Each pulse is a
-- one-frame plate recompose; firing one per contextual during a mass harvest (zone
-- load, crowded city) could stutter. This caps the pulse rate WITHOUT dropping the
-- final update: if a pulse is requested while we're inside the cooldown, we set a
-- pending flag and schedule ONE trailing pulse for when the cooldown expires, so a
-- burst of N arrivals collapses to at most one pulse now + one pulse ~interval
-- later. Worst-case a float waits PULSE_MIN_INTERVAL before it recomposes -- kept
-- well under a noticeable delay.
local PULSE_MIN_INTERVAL = 1.5     -- seconds; max one pulse per this window
local lastPulseAt   = -1000
local pulsePending  = false
throttledOverheadPulse = function()
    if not CNFix_PulseOverheadNames then return end
    local now = GetTime and GetTime() or 0
    if (now - lastPulseAt) >= PULSE_MIN_INTERVAL then
        lastPulseAt = now
        pcall(CNFix_PulseOverheadNames)
        return
    end
    -- Inside cooldown: ensure exactly one trailing pulse fires when it expires.
    if pulsePending then return end
    pulsePending = true
    local wait = PULSE_MIN_INTERVAL - (now - lastPulseAt)
    if wait < 0.05 then wait = 0.05 end
    after(wait, function()
        pulsePending = false
        lastPulseAt = GetTime and GetTime() or 0
        pcall(CNFix_PulseOverheadNames)
    end)
end

-- Called from CNFixNames.lua PushPair whenever a Google name reaches the DLL.
-- Debounced: a burst of pushes collapses into a single repaint pass.
function CNFix_OnUpgrade(zh, en)
    if not (zh and isCJK(zh)) then return end
    pendingUpgrade[zh] = en or true
    -- A new contextual just reached the DLL: allow the nameplate enforcer to
    -- re-probe word-subs it had previously parked, so a plate stuck on the
    -- word-sub gets upgraded on the next ~0.12s sweep instead of waiting for a
    -- /reload or a nameplate toggle.
    if CNFix_ClearNpUpgradeThrottle then CNFix_ClearNpUpgradeThrottle() end
    if not upgradeQueued then
        upgradeQueued = true
        after(0.10, flushUpgrade)
    end
end
-- ============================================================
-- (6) /WHO REVERSE SEARCH  --  English partial -> Chinese, Blizzard-style
-- ============================================================
-- The server only knows the ORIGINAL Chinese name. The DLL reverse-swaps
-- whisper/invite/trade/target/mail (exact key), but it does NOT hook SendWho,
-- so a /who typed in English never reaches the server as Chinese. We bridge it
-- here in Lua, and -- unlike an exact-key swap -- we mirror vanilla /who's
-- PARTIAL ordered-substring behavior: any contiguous run of the (normalized)
-- English name matches. "thew", "winds", "windsme", "the winds", "meet" all
-- resolve to "Thewindsmeet".
--
-- PIPELINE: normalize the typed query -> scan every learned English name
-- (CNFix_LearnedPairs = the zh->en pairs pushed this session, plus the
-- WoWTranslate name cache for anything not yet pushed) -> keep those whose
-- normalized English CONTAINS the normalized query -> pick the best candidate
-- (exact > prefix > shortest substring) -> SendWho(thatChineseName). We never
-- send English to the server. If nothing matches we pass the filter through
-- unchanged, so Chinese / wildcard / structured /who still work the vanilla way.

-- comparison key only (never displayed): lowercase, strip whitespace + punctuation
local function lookupNormalize(s)
    if type(s) ~= "string" then return "" end
    local r = string.lower(s)
    r = string.gsub(r, "%s+", "")
    r = string.gsub(r, "%p", "")
    return r
end

if SendWho then
    local origSendWho = SendWho
    SendWho = function(filter)
        -- pass through anything that isn't a bare English name query
        if type(filter) ~= "string" or filter == "" then return origSendWho(filter) end
        if isCJK(filter)                       -- already Chinese
           or string.find(filter, "%d")        -- level filter (names have no digits)
           or string.find(filter, '"') then    -- structured who-filter (n-"..", z-"..")
            dbg("/who passthrough typed=" .. filter)
            return origSendWho(filter)
        end
        local nq = lookupNormalize(filter)
        if nq == "" then return origSendWho(filter) end

        local bestZh, bestEn, bestScore, bestLen
        local matches = {}                      -- debug only
        local seen = {}
        local function consider(zh, en)
            if not (zh and en) or seen[zh] then return end
            if string.sub(zh, 1, 6) == "guild:" or string.sub(zh, 1, 5) == "rank:" then return end
            if not isCJK(zh) then return end
            local ne = lookupNormalize(en)
            if ne == "" then return end
            local pos = string.find(ne, nq, 1, true)   -- plain contiguous substring
            if not pos then return end
            seen[zh] = true
            local score = (ne == nq) and 0 or (pos == 1 and 1 or 2)   -- exact > prefix > substring
            table.insert(matches, en .. "->" .. zh)
            if (not bestZh) or score < bestScore
               or (score == bestScore and string.len(ne) < bestLen) then
                bestZh, bestEn, bestScore, bestLen = zh, en, score, string.len(ne)
            end
        end

        -- source 1: names pushed to the DLL this session (authoritative display)
        local lp = CNFix_LearnedPairs
        if type(lp) == "table" then for zh, en in pairs(lp) do consider(zh, en) end end
        -- source 2: WoWTranslate's name cache (catches names not yet pushed)
        local wc  = WoWTranslateCache
        local pfx = CNFix_NameCachePrefix or "\1wt_name:"
        local pl  = string.len(pfx)
        if type(wc) == "table" then
            for k, v in pairs(wc) do
                if type(k) == "string" and string.sub(k, 1, pl) == pfx then
                    consider(string.sub(k, pl + 1), v)
                end
            end
        end

        if CNFixNamesDB and CNFixNamesDB.debug and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFix /who|r typed=" .. filter
                .. " norm=" .. nq
                .. " matches=[" .. table.concat(matches, ", ") .. "]"
                .. " chosen=" .. (bestZh and (bestEn .. "->" .. bestZh) or "none")
                .. " send=" .. tostring(bestZh or filter))
        end
        return origSendWho(bestZh or filter)
    end
end

-- ============================================================
-- (6.5) /WHISPER ROUTING SUFFIX  --  optional trailing "*" reverse-lookup
-- ============================================================
-- COLLISION CASE: two players appear with the same English name in the user's
-- view -- one is a real server-native player called "Holylight", the other is
-- a Chinese-named player (e.g. 聖光) that CNFix renders as "Holylight". The
-- DLL's chat reverse-swap is keyed on EXACT zh<->en, so when the user types
-- "/w Holylight hi", the swap doesn't fire (the typed name IS already a real
-- server name), and the whisper goes to the wrong player.
--
-- OPT-IN ROUTING: append "*" to the target name to force CNFix to reverse-
-- lookup the typed English form to its Chinese original and send there.
--   /w Holylight  hi    -> raw "Holylight" (default WoW, the real player)
--   /w Holylight* hi    -> reverse-lookup -> /w 聖光 hi
-- Without the trailing "*", we do NOTHING -- the default WoW whisper path is
-- preserved byte-for-byte. Users who never see a collision never notice this
-- feature exists.
--
-- We hook the slash dispatch by wrapping SendChatMessage's caller chain at the
-- ChatFrame_OpenChat path. The cleanest single-point intercept on 1.12 is
-- the SLASH_*1/SlashCmdList pair for /w, /whisper, /tell, /t. Wrapping the
-- existing dispatch keeps things stack-safe and doesn't require touching
-- DEFAULT_CHAT_FRAME's edit box.
--
-- HARD RULES OBSERVED
-- - opt-in only: no "*" -> pass through unchanged
-- - one-shot, synchronous: no OnUpdate, no polling, no async wait
-- - reuses the SAME reverse-lookup tables as /who (CNFix_LearnedPairs +
--   WoWTranslateCache "\1wt_name:" entries) so we don't drift from the
--   established matcher
-- - if "*" is present but no reverse match found: keep the typed name
--   (with the "*" stripped) and pass through normally; surface a one-line
--   hint so the user knows the lookup miss happened
-- - case-insensitive (server is anyway), normalized-substring match
--   identical to /who -- a partial English form like "winds*" still
--   resolves to the unique Chinese target if one exists

local function whisperReverseLookup(typed)
    -- Returns Chinese name if there's a unique reverse-lookup hit, else nil.
    -- Same matcher /who uses; we share the exact algorithm so behaviour
    -- stays consistent across the two surfaces.
    if type(typed) ~= "string" or typed == "" then return nil end
    if isCJK(typed) then return typed end  -- already Chinese, nothing to do
    local nq = lookupNormalize(typed)
    if nq == "" then return nil end

    local bestZh, bestEn, bestScore, bestLen
    local seen = {}
    local function consider(zh, en)
        if not (zh and en) or seen[zh] then return end
        if string.sub(zh, 1, 6) == "guild:" or string.sub(zh, 1, 5) == "rank:" then return end
        if not isCJK(zh) then return end
        local ne = lookupNormalize(en)
        if ne == "" then return end
        local pos = string.find(ne, nq, 1, true)
        if not pos then return end
        seen[zh] = true
        local score = (ne == nq) and 0 or (pos == 1 and 1 or 2)
        if (not bestZh) or score < bestScore
           or (score == bestScore and string.len(ne) < bestLen) then
            bestZh, bestEn, bestScore, bestLen = zh, en, score, string.len(ne)
        end
    end
    local lp = CNFix_LearnedPairs
    if type(lp) == "table" then for zh, en in pairs(lp) do consider(zh, en) end end
    local wc  = WoWTranslateCache
    local pfx = CNFix_NameCachePrefix or "\1wt_name:"
    local pl  = string.len(pfx)
    if type(wc) == "table" then
        for k, v in pairs(wc) do
            if type(k) == "string" and string.sub(k, 1, pl) == pfx then
                consider(string.sub(k, pl + 1), v)
            end
        end
    end
    return bestZh
end

-- Print the collision hint at most once per session per typed name, so we
-- never spam the chat frame even if the user pastes the same wrong whisper
-- a dozen times.
local hintedNames = {}
local function maybeHint(typed)
    if not DEFAULT_CHAT_FRAME or hintedNames[typed] then return end
    hintedNames[typed] = true
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff66ccffCNFix:|r no translated player matches \"" .. typed
        .. "\"; whispering raw name. (Try /who " .. typed
        .. " to see candidates.)")
end

-- Hook SendChatMessage -- this is the lowest-level chat send API, and every
-- whisper path (slash dispatch, edit-box whisper mode, macro, programmatic
-- addon call) ultimately funnels through here. Wrapping SlashCmdList alone
-- is NOT enough on 1.12 because of how the edit box transitions:
--
-- When the user types "/w Hoblin* " (note the trailing space), the chat edit
-- box parses the slash command, extracts "Hoblin*" as the target via
-- ChatEdit_ExtractTellTarget, flips the edit box into whisper mode (pink
-- prefix "To Hoblin*:"), and clears the slash + name from the input. The
-- user then types just the message and presses Enter. The slash handler
-- in SlashCmdList["WHISPER"] never sees the message text -- the chat frame
-- skips it and calls SendChatMessage("msg", "WHISPER", nil, "Hoblin*")
-- directly. So the only reliable single-point intercept is here.
--
-- We rewrite target only when:
--   msgType == "WHISPER"   AND   target ends in "*"
-- Strip the "*", reverse-lookup using the same matcher /who uses, and if
-- a unique Chinese name resolves, swap it in. Otherwise strip the "*"
-- anyway (so the whisper still goes through to the raw typed name) and
-- print a one-time hint. /r and /reply route by server-tracked identity,
-- never carry "*", so they pass through untouched.
local cnfixWrappedSendChat = false
local function installSendChatWrap()
    if cnfixWrappedSendChat then return end
    if type(SendChatMessage) ~= "function" then return end
    cnfixWrappedSendChat = true
    local origSendChatMessage = SendChatMessage
    SendChatMessage = function(msg, msgType, language, target)
        if msgType == "WHISPER" and type(target) == "string" and target ~= ""
           and string.sub(target, -1) == "*" then
            local stripped = string.sub(target, 1, -2)
            if stripped ~= "" then
                local zh = whisperReverseLookup(stripped)
                if zh and zh ~= stripped then
                    if CNFixNamesDB and CNFixNamesDB.debug and DEFAULT_CHAT_FRAME then
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "|cff66ccffCNFix /w*|r " .. stripped .. " -> " .. zh)
                    end
                    target = zh
                else
                    maybeHint(stripped)
                    target = stripped
                end
            end
        end
        return origSendChatMessage(msg, msgType, language, target)
    end
end
installSendChatWrap()
-- Re-arm shortly after login in case another addon wraps SendChatMessage
-- after CNFixExtend loads. Idempotent via the cnfixWrappedSendChat guard --
-- if we've already wrapped, we don't wrap again (avoids recursion).
local rearmChat = CreateFrame("Frame")
rearmChat:RegisterEvent("PLAYER_LOGIN")
rearmChat:RegisterEvent("PLAYER_ENTERING_WORLD")
rearmChat:SetScript("OnEvent", function()
    installSendChatWrap()
    rearmChat:UnregisterAllEvents()
    rearmChat:SetScript("OnEvent", nil)
end)

-- ============================================================
-- (6.6) /MAIL ROUTING SUFFIX  --  opt-in trailing "*" on mail "To:"
-- ============================================================
-- Same routing pattern as /whisper. Default behavior (no "*") goes to the
-- raw server-known name -- which 99% of the time is the translated Chinese
-- player anyway, because the DLL's existing reverse-swap on SendChatMessage
-- ALSO fires on SendMail's parameter table (it's the same English-alias
-- substitution path). The "*" is only useful in the rare collision case
-- where two players share the same English name -- one a real English
-- native and one a CNFix-translated Chinese name.
--
-- Wrapping SendMail itself catches:
--   - the in-game Mail UI "To:" input
--   - macros that call SendMail directly
--   - any addon-driven mail sending
-- WoW 1.12 signature: SendMail(target, subject, body)
local cnfixWrappedSendMail = false
local function installSendMailWrap()
    if cnfixWrappedSendMail then return end
    if type(SendMail) ~= "function" then return end
    cnfixWrappedSendMail = true
    local origSendMail = SendMail
    SendMail = function(target, subject, body)
        if type(target) == "string" and target ~= ""
           and string.sub(target, -1) == "*" then
            local stripped = string.sub(target, 1, -2)
            if stripped ~= "" then
                local zh = whisperReverseLookup(stripped)
                if zh and zh ~= stripped then
                    if CNFixNamesDB and CNFixNamesDB.debug and DEFAULT_CHAT_FRAME then
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "|cff66ccffCNFix mail*|r " .. stripped .. " -> " .. zh)
                    end
                    target = zh
                else
                    maybeHint(stripped)
                    target = stripped
                end
            end
        end
        return origSendMail(target, subject, body)
    end
end
installSendMailWrap()
local rearmMail = CreateFrame("Frame")
rearmMail:RegisterEvent("PLAYER_LOGIN")
rearmMail:RegisterEvent("PLAYER_ENTERING_WORLD")
rearmMail:SetScript("OnEvent", function()
    installSendMailWrap()
    rearmMail:UnregisterAllEvents()
    rearmMail:SetScript("OnEvent", nil)
end)

-- ============================================================
-- (6.7) SYSTEM MESSAGE / EMOTE NAME SUBSTITUTION
-- ============================================================
-- WoWTranslate explicitly SKIPS CHAT_MSG_SYSTEM and CHAT_MSG_EMOTE (per their
-- SYSTEM_EVENTS table), so CNFix can fill the gap without colliding. We don't
-- attempt full template translation ("X 已上线" -> "X has come online"); we
-- just substitute every CJK name token in the message with its known English
-- form. The boilerplate stays in CJK but the names become readable, which is
-- 60% of the practical value at near-zero risk.
--
-- HOW IT WORKS
-- - Hook each ChatFrame's OnEvent (same surface WT uses, but our wrapper
--   runs the original first, then patches arg1 if we find substitutions).
-- - Only for CHAT_MSG_SYSTEM and CHAT_MSG_EMOTE -- other events are left
--   untouched (WT owns those).
-- - Scan the message for the longest zh keys in CNFix_LearnedPairs and
--   WoWTranslateCache "\1wt_name:" entries, replace each with its English
--   form. Per-session memo so repeat messages skip the scan.
--
-- HARD RULES
-- - no OnUpdate, no polling
-- - event-driven only
-- - if no CJK in arg1, fast-reject
-- - never touches hyperlinks (substitutions are pure-text only, the engine's
--   |H...|h wrappers don't contain CJK player names anyway)
-- - skips silently on any error; original message always reaches the frame

local sysCache = {}     -- per-session original_text -> substituted_text
-- Sorted-by-length-desc snapshot of zh names, rebuilt lazily on first miss
-- so a fresh chat after big harvest catches new names.
local sortedZhNames = nil
local sortedZhNamesAt = 0
local function refreshSortedZhNames()
    sortedZhNames = {}
    local lp = CNFix_LearnedPairs
    if type(lp) == "table" then
        for zh, en in pairs(lp) do
            if type(zh) == "string" and type(en) == "string"
               and isCJK(zh) and not isCJK(en)
               and string.len(zh) >= 6 and string.len(zh) <= 36
               and string.len(en) > 0 and string.len(en) <= 40 then
                table.insert(sortedZhNames, { zh = zh, en = en, len = string.len(zh) })
            end
        end
    end
    -- Also harvest WT name cache entries the user has seen this session.
    local wc  = WoWTranslateCache
    local pfx = CNFix_NameCachePrefix or "\1wt_name:"
    local pl  = string.len(pfx)
    if type(wc) == "table" then
        for k, v in pairs(wc) do
            if type(k) == "string" and type(v) == "string"
               and string.sub(k, 1, pl) == pfx then
                local zh = string.sub(k, pl + 1)
                if isCJK(zh) and not isCJK(v)
                   and string.len(zh) >= 6 and string.len(zh) <= 36
                   and string.len(v) > 0 and string.len(v) <= 40 then
                    table.insert(sortedZhNames, { zh = zh, en = v, len = string.len(zh) })
                end
            end
        end
    end
    table.sort(sortedZhNames, function(a, b) return a.len > b.len end)
    sortedZhNamesAt = GetTime and GetTime() or 0
end

local function substituteNamesInText(text)
    if type(text) ~= "string" or text == "" then return text, false end
    if not isCJK(text) then return text, false end
    local cached = sysCache[text]
    if cached then return cached, cached ~= text end
    -- Refresh sorted table at most every 30s, or if it doesn't exist yet.
    local now = GetTime and GetTime() or 0
    if not sortedZhNames or (now - sortedZhNamesAt) > 30 then
        refreshSortedZhNames()
    end
    local out = text
    local replaced = false
    -- Longest-first ensures "苟到牛十级" gets matched before "苟到".
    for i = 1, table.getn(sortedZhNames) do
        local entry = sortedZhNames[i]
        if string.find(out, entry.zh, 1, true) then
            -- string.gsub with plain pattern (use gsub-with-string-find loop
            -- because Lua 5.0's gsub doesn't have a "plain" flag).
            local rebuilt = ""
            local pos = 1
            while true do
                local s, e = string.find(out, entry.zh, pos, true)
                if not s then
                    rebuilt = rebuilt .. string.sub(out, pos)
                    break
                end
                rebuilt = rebuilt .. string.sub(out, pos, s - 1) .. entry.en
                pos = e + 1
                replaced = true
            end
            out = rebuilt
        end
    end
    sysCache[text] = out
    return out, replaced
end

-- The actual filter: hook ChatFrame:OnEvent. We use the same per-frame
-- approach WT uses (it's the reliable 1.12 idiom). 60s watchdog re-hook
-- because UPDATE_CHAT_WINDOWS sometimes replaces OnEvent handlers.
--
-- CRITICAL LUA 5.0 CAVEAT (the bug fixed in v2.5.10):
-- Inside an OnEvent function, `arg1` is a GLOBAL variable that the engine
-- writes before invoking the handler. If we write `arg1 = newArg1` inside
-- the wrapper, Lua 5.0 creates a LOCAL `arg1` that shadows the global --
-- the original handler then reads the still-Chinese global and our work is
-- silently discarded. We must use `setglobal("arg1", newArg1)` so the
-- write reaches the actual global the next handler reads.
local CNFIX_SYSEMOTE_EVENTS = { CHAT_MSG_SYSTEM = true, CHAT_MSG_EMOTE = true }
local function hookChatFrameSysEmote(frame)
    if not frame or frame.CNFixSysEmoteHooked then return end
    local orig = frame:GetScript("OnEvent")
    if not orig then return end
    frame.CNFixSysEmoteHooked = true
    frame.CNFix_OrigOnEvent = orig
    frame:SetScript("OnEvent", function()
        if event and CNFIX_SYSEMOTE_EVENTS[event] and type(arg1) == "string" then
            local newArg1, replaced = substituteNamesInText(arg1)
            if replaced then
                -- MUST be setglobal -- a bare `arg1 = ...` would create a
                -- LOCAL and the original handler would still see the
                -- original Chinese global. This was the v2.5.9 silent bug.
                setglobal("arg1", newArg1)
            end
        end
        return orig()
    end)
end
local function hookAllChatFramesSysEmote()
    local n = NUM_CHAT_WINDOWS or 7
    for i = 1, n do
        hookChatFrameSysEmote(getglobal("ChatFrame" .. i))
    end
end
hookAllChatFramesSysEmote()
-- One-shot re-arm after login + a slow watchdog. 60s matches WT's interval
-- so we re-hook on roughly the same cadence; the cheap idempotency check
-- prevents any double-wrap.
local sysRearm = CreateFrame("Frame")
sysRearm:RegisterEvent("PLAYER_LOGIN")
sysRearm:RegisterEvent("PLAYER_ENTERING_WORLD")
sysRearm:SetScript("OnEvent", function() hookAllChatFramesSysEmote() end)
local sysWatch = CreateFrame("Frame")
local sysWatchT = 0
sysWatch:SetScript("OnUpdate", function()
    sysWatchT = sysWatchT + (arg1 or 0)
    if sysWatchT >= 60 then
        sysWatchT = 0
        for i = 1, (NUM_CHAT_WINDOWS or 7) do
            local f = getglobal("ChatFrame" .. i)
            if f and not f.CNFixSysEmoteHooked then hookChatFrameSysEmote(f) end
        end
    end
end)

-- ============================================================
-- (7) UNITFRAME GOOGLE HARVEST  --  bridge the tooltip's contextual name
-- ============================================================
-- PROBLEM (observed): the tooltip shows WoWTranslate's contextual name
-- ("Overlord Warrior") but the unit frame stays on the DLL word-sub
-- ("DespotWarGeneral"). WoWTranslate caches the DISPLAYED name under its NAME
-- key ("\1wt_name:"..name); the base RequestName early-returns when that key is
-- already cached and never PushPairs it, so the DLL never learns the contextual
-- value for that exact UnitName -- the frame is stuck on smart_compose.
--
-- FIX (per spec): on target / mouseover / party / raid, take UnitName(unit) as
-- the AUTHORITATIVE Chinese source, read WoWTranslate's translation under BOTH
-- its name key AND its raw-text key, and PushPair(UnitName(unit), value) so the
-- DLL learns it under the EXACT key the frame resolves with -- then force a
-- repaint (CNFix_OnUpgrade) even if PushPair de-duped. This never depends on the
-- tooltip's internal Chinese key matching UnitName. If WT hasn't translated the
-- name yet we request it and re-check a moment later (async arrival).

local NAMEKEY = CNFix_NameCachePrefix or "\1wt_name:"

-- WoWTranslate's translation for a bare Chinese name, trying both cache keys.
local function wtAny(zh)
    if not (WoWTranslate_CacheGet and type(zh) == "string") then return nil end
    local function good(v) return type(v) == "string" and v ~= "" and v ~= zh and not isCJK(v) end
    local v = WoWTranslate_CacheGet(NAMEKEY .. zh)   -- name key (exactly what the tooltip shows)
    if good(v) then return v, "name" end
    v = WoWTranslate_CacheGet(zh)                    -- raw-text key (idiomatic line translation)
    if good(v) then return v, "raw" end
    return nil
end

-- Names we've already learned+repainted this session. Once a name is learned,
-- the DLL resolves it contextually on every future draw, so we only need to
-- repaint once (the cold-encounter fix) -- not on every mouseover tick.
local harvested = {}

-- Replicate the DLL's tokenize() EXACTLY (the no-space CamelCase form the DLL
-- renders a learned name as), so we can recognise when the DLL has actually
-- resolved zh through the learned (Google) value rather than smart_compose.
local function tokenizeLikeDLL(s)
    if type(s) ~= "string" then return "" end
    local out, boundary = "", true
    for i = 1, string.len(s) do
        local c = string.byte(s, i)
        if c < 128 then
            -- the DLL's boundary set: space tab , . ; : / \ - _ ' " ( ) [ ] ! ? = + &
            if c==32 or c==9 or c==44 or c==46 or c==59 or c==58 or c==47 or c==92
               or c==45 or c==95 or c==39 or c==34 or c==40 or c==41 or c==91 or c==93
               or c==33 or c==63 or c==61 or c==43 or c==38 then
                boundary = true
            else
                if boundary and c >= 97 and c <= 122 then c = c - 32 end   -- a-z -> A-Z at a boundary
                out = out .. string.char(c)
                boundary = false
            end
        else
            out = out .. string.char(c)
            boundary = false
        end
    end
    if out == "" then return s end
    return out
end

-- A hidden probe FontString. Writing zh to it runs the SAME DLL resolver the
-- real frames use; reading it back tells us what the DLL currently renders zh
-- as -- i.e. whether the learned (Google) entry is live yet. We wrap zh in a
-- UNIQUE color each call so the DLL's per-key result cache can't return a stale
-- value -- every probe is a genuine fresh resolve of the current learned map.
local probeFS
local function dllRender(zh, salt)
    if not probeFS then
        local pf = CreateFrame("Frame")
        if pf and pf.Hide then pcall(pf.Hide, pf) end
        if pf and pf.CreateFontString then
            local ok, fs = pcall(function() return pf:CreateFontString(nil, "BACKGROUND") end)
            if ok and fs then
                if fs.SetFont then pcall(fs.SetFont, fs, "Fonts\\FRIZQT__.TTF", 10) end
                probeFS = fs
            end
        end
    end
    if not (probeFS and probeFS.SetText and probeFS.GetText) then return nil end
    local wrapped = "|cff0000" .. string.format("%02x", math.mod(salt or 0, 256)) .. zh
    pcall(probeFS.SetText, probeFS, wrapped)
    local ok, t = pcall(probeFS.GetText, probeFS)
    if not ok or type(t) ~= "string" then return nil end
    local a, b = string.find(t, "^|c%x%x%x%x%x%x%x%x")   -- strip the color the DLL preserved
    if a then t = string.sub(t, b + 1) end
    return t
end

-- Confirm the DLL has learned zh -> en BEFORE repainting. Probe the resolver;
-- only repaint once it actually renders the tokenized Google name. Retry a few
-- times (covers any push/learn lag or a slightly-late SyncLiveCache push). If it
-- never converges, the learn was rejected (glossary / validation) -- we log that
-- and repaint anyway (no worse than before).
local function confirmAndRepaint(zh, en, attempt)
    local want = tokenizeLikeDLL(en)
    local got  = dllRender(zh, attempt)
    local hit  = (got == want)
    dbg("confirm zh=" .. zh .. " en=" .. en .. " want=" .. want
        .. " dllOut=" .. tostring(got) .. " dllLearnedHit=" .. tostring(hit)
        .. " attempt=" .. attempt)
    if hit then
        if CNFix_OnUpgrade then pcall(CNFix_OnUpgrade, zh, en) end   -- learned is live -> repaint now
        return
    end
    if attempt < 2 then    -- was 6: fewer probe+repaint retries (mouseover stutter)
        if CNFix_PushPair then pcall(CNFix_PushPair, zh, en) end     -- re-assert the push
        after(0.10, function() confirmAndRepaint(zh, en, attempt + 1) end)
    else
        dbg("confirm GAVE UP zh=" .. zh .. " dllOut=" .. tostring(got)
            .. " -- DLL never learned it (likely glossary/validation reject)")
        if CNFix_OnUpgrade then pcall(CNFix_OnUpgrade, zh, en) end
    end
end

local guildDone = {}
-- Transfer WoWTranslate's guild translation to the floating overhead guild text.
-- The overhead guild getter (hooked) resolves the BARE guild string, so we push
-- that exact string into the DLL, then pulse once so the (already-built) plate
-- rebuilds and the getter hook returns the translated guild. WoWTranslate caches
-- guilds under "\1wt_name:guild:"..guild (visible in its tooltip); we read that,
-- and if it's not there yet we ask WoWTranslate to translate it and RETRY on the
-- next harvest (we only mark a guild done once it has actually been pushed, so an
-- async/queue miss never strands it).
local function harvestGuild(unit)
    if not (GetGuildInfo and CNFix_PushPair) then return end
    local g = GetGuildInfo(unit)
    if not (g and isCJK(g)) then return end
    if guildDone[g] then return end
    local function good(v) return type(v) == "string" and v ~= "" and v ~= g and not isCJK(v) end
    local function land(en)
        guildDone[g] = true
        pcall(CNFix_PushPair, g, en)                                   -- learn bare guild into DLL
        throttledOverheadPulse()                                       -- rebuild plate once (throttled)
    end
    local cached = WoWTranslate_CacheGet and WoWTranslate_CacheGet("\1wt_name:guild:" .. g)
    if good(cached) then land(cached); return end
    -- not cached yet: ask WoWTranslate to translate+cache it; retry next harvest
    if WoWTranslate_ResolveGuildDisplayName then
        pcall(WoWTranslate_ResolveGuildDisplayName, g, function(en) if good(en) then land(en) end end)
    end
end

local function harvestUnit(unit)
    if not (UnitExists and UnitExists(unit) and UnitName) then return end
    harvestGuild(unit)
    local zh = UnitName(unit)
    if not (zh and isCJK(zh)) then return end
    if harvested[zh] then return end          -- already learned + repainted
    local en, via = wtAny(zh)
    if en then
        harvested[zh] = true
        if CNFix_PushPair then pcall(CNFix_PushPair, zh, en) end     -- learn into the DLL
        dbg("harvest unit=" .. unit .. " UnitName=" .. zh .. " en=" .. en
            .. " key=" .. via .. " zh==UnitName=true -> confirm-then-repaint")
        confirmAndRepaint(zh, en, 1)                                 -- repaint only after DLL confirms
    else
        if CNFix_RequestName then pcall(CNFix_RequestName, zh) end
        dbg("harvest unit=" .. unit .. " UnitName=" .. zh .. " no WT value yet -> requested (re-check pending)")
    end
end

local HUNITS = { "target", "mouseover", "party1", "party2", "party3", "party4" }
local function harvestAll()
    for i = 1, table.getn(HUNITS) do harvestUnit(HUNITS[i]) end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, 40 do harvestUnit("raid" .. i) end
    end
end

-- async re-check: WT's name translation lands a moment after the first hover.
local recheckQ = false
local function scheduleRecheck()
    if recheckQ then return end
    recheckQ = true
    after(0.8, harvestAll)
    after(1.8, function() recheckQ = false; harvestAll() end)
end

local hEv = CreateFrame("Frame")
hEv:RegisterEvent("PLAYER_TARGET_CHANGED")
hEv:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
hEv:RegisterEvent("PARTY_MEMBERS_CHANGED")
hEv:RegisterEvent("RAID_ROSTER_UPDATE")
hEv:SetScript("OnEvent", function()
    local e = event
    if e == "UPDATE_MOUSEOVER_UNIT" then harvestUnit("mouseover")
    elseif e == "PLAYER_TARGET_CHANGED" then harvestUnit("target")
    else harvestAll() end
    scheduleRecheck()
end)

-- ============================================================
-- (6) HARVEST CATCH-UP PULSE  --  rebuild stale floating names
-- ============================================================
-- The DLL harvests WoWTranslate's whole cache into CNFix_learned.txt and into
-- live memory continuously. But floating overhead names already baked before a
-- name was harvested stay stale (the engine caches the 3D text). When WT's
-- cache GROWS, pulse the overhead names once so the newly-known contextual
-- names take effect on screen. Change-driven (only on growth), low frequency,
-- so it never causes continuous flicker.
local lastCacheN = -1
local catchup = CreateFrame("Frame")
catchup.e = 0
catchup:SetScript("OnUpdate", function()
    catchup.e = catchup.e + (arg1 or 0)
    if catchup.e < 10 then return end                 -- check at most every 10s
    catchup.e = 0
    -- (perf) This handler used to call WoWTranslate_CacheStats() every 10s purely to
    -- detect cache growth and then pulse the overhead names. The periodic pulse was
    -- disabled (it caused ~10s flicker), which left only an expensive full WT-cache
    -- pairs() scan that drove no behavior. Overhead-name catch-up is already handled
    -- the correct way: SyncLiveCache harvests new contextuals and PushPair ->
    -- CNFix_OnUpgrade fires the debounced, 1.5s-throttled overhead pulse only when a
    -- name actually arrives. So we no longer scan the WT cache here at all. The frame
    -- is kept (cheap accumulate-and-return) so the structure is intact if a future
    -- change wants to reuse it.
    -- lastCacheN retained for reference; intentionally unused now.
    lastCacheN = lastCacheN
end)

-- ============================================================
-- (8) EVENT-DRIVEN UNIT HARVEST  --  pets, nameplates, mobs
-- ============================================================
-- Fills the contextual cache for units that NEVER pass through who/inspect/
-- trade/dropdown -- specifically:
--   * hunter pets, warlock summons, and other companions (UnitName("pet"),
--     UnitName("partypet1..4")), and
--   * NPCs / players you see on a default Blizzard nameplate after targeting
--     or mousing over them (UnitName("target"), UnitName("mouseover"),
--     UnitName("targettarget") catches another player's pet).
--
-- Each event fires once; we request() the name if it's CJK and we haven't
-- already asked for it. request() is a no-op if WT lacks an API and is
-- idempotent at the WT layer. When WT resolves the name, the existing
-- onWTArrive -> PushPair -> DLL learned-cache path renders it everywhere the
-- DLL touches (overhead/plates/unit frames) on the next natural redraw.
--
-- Strictly event-driven -- no OnUpdate, no per-frame walks, no polling. The
-- per-name dedup table prevents request spam on rapid mouseover sweeps.
local huntSeen = {}
local function huntOne(unit)
    if not (UnitExists and UnitName and UnitExists(unit)) then return end
    local nm = UnitName(unit)
    if not (nm and isCJK(nm)) then return end
    if huntSeen[nm] then return end
    huntSeen[nm] = true
    request(nm)
end
local huntEv = CreateFrame("Frame")
huntEv:RegisterEvent("PLAYER_TARGET_CHANGED")
huntEv:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
huntEv:RegisterEvent("UNIT_PET")
huntEv:RegisterEvent("PARTY_MEMBERS_CHANGED")
huntEv:SetScript("OnEvent", function()
    if not enabled() then return end
    huntOne("target")
    huntOne("mouseover")
    huntOne("targettarget")           -- another player's current target/pet
    huntOne("pet")                    -- our own pet (hunter/warlock/etc.)
    huntOne("partypet1"); huntOne("partypet2")
    huntOne("partypet3"); huntOne("partypet4")
end)

-- ============================================================
-- (9) DEFAULT TOOLTIP NAME LINE  --  GameTooltip line 1
-- ============================================================
-- The DLL's SetText hook DOES carve out GameTooltipTextLeft1 and translates
-- it through the standard FontString surface, but the 1.12 engine sometimes
-- populates tooltip lines via an internal C path that never enters the Lua
-- :SetText glue -- which is why some hovers translated and others didn't
-- ("sometimes works, sometimes doesn't"). Wrapping GameTooltip:SetUnit at
-- the Lua level closes that gap deterministically: every time the engine
-- builds a unit tooltip we get one synchronous shot at line 1 AFTER the
-- engine has finished populating it, with no polling or OnUpdate ticker.
--
-- COEXISTENCE WITH WOWTRANSLATE
-- We call whatever SetUnit chain is already in place (`wrappedOrig`). If WT
-- wrapped first, WT runs as normal -- its tooltip BODY translation and any
-- other tooltip features keep working. If WT later overwrites our line 1
-- via its deferred UpdateTooltipPlayerNames, that's fine: the user
-- explicitly said NOT to fight WT. We never touch the per-line FontString
-- SetText, never call ClearLines, never call AddLine, never call Show, and
-- never silence WT's defer frame.
--
-- IDEMPOTENCY
-- - skip if line 1 starts with PT/PASS markers (already ours)
-- - skip if line 1 is already non-CJK (WT got there first / English name)
-- - in-session zh->translated cache so repeat hovers are O(1) and don't
--   re-hit the DLL or WT cache
-- - request() the contextual name once per unseen ZH so the NEXT hover
--   renders the nicer learned form
--
-- HARD RULES OBSERVED
-- - event-driven only (no OnUpdate, no polling, no ticker)
-- - one translation per tooltip update if needed
-- - cached results
-- - no per-frame scanning, no body lines, no AddLine hook
-- - no GameTooltip:Show() call (the engine already sized it for line 1)
-- - no SetHyperlink swallowing, no global error handlers
-- - no ClearLines, no tooltip rebuild
local tipCache = {}              -- per-session zh -> translated string (no marker)
-- (v2.6.0) The authoritative "what every other surface shows" form for a raw
-- Chinese name: dllOf() pushes zh through a hidden probe FontString that runs the
-- EXACT same DLL resolver the unit frames / nameplates / overhead use, so the value
-- read back IS the canonical render in the current mode (English CamelCase or pinyin
-- romanization). Using this as the tooltip's name guarantees the tooltip can never
-- disagree with the float/frame -- and as the contextual gets learned, all surfaces
-- upgrade together because dllOf reflects live g_learned state. We still request()
-- so an unseen name's nicer contextual is fetched for next hover.
-- (v2.7.4) NOTE: the former canonNameForm()/translateTooltipLine1() Lua tooltip
-- rewriters were removed -- the DLL leaf hook is now the single owner of the
-- tooltip name line (see below). Keeping them would re-strip the PvP rank the leaf
-- correctly preserves.
-- (v2.7.4) The DLL leaf SetText hook is now the SINGLE owner of the tooltip name
-- line when "Tooltips" is on: it translates GameTooltipTextLeft1 on every engine
-- SetText, preserves a leading PvP rank ("Scout ", "Senior Sergeant "), CamelCases
-- only the name, and re-asserts on WoWTranslate's rebuild so it can't revert. The
-- old Lua-side CASE A/B rewrites here are therefore redundant AND harmful: CASE B
-- resolved the rankless UnitName and overwrote the leaf's rank-prefixed line,
-- stripping the rank. We no longer touch GameTooltipTextLeft1 from Lua at all --
-- the leaf handles it, the addon does not fight it. When "Tooltips" is OFF,
-- WoWTranslate owns tooltips and we likewise do nothing.
if GameTooltip and type(GameTooltip.SetUnit) == "function" and not GameTooltip.__cnfixSetUnit then
    GameTooltip.__cnfixSetUnit = true
    -- We intentionally do NOT wrap SetUnit anymore. Leaving GameTooltip:SetUnit
    -- untouched removes the timing perturbation that fought WoWTranslate's own
    -- SetUnit/OnShow defer (the flash-and-revert / per-player inconsistency), and
    -- the leaf hook already covers the name line when the user opts in. The flag
    -- above just prevents any earlier-loaded copy from re-wrapping.
end
