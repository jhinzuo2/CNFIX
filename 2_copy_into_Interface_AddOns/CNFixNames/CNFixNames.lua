-- CNFixNames — companion to CNFixEnglish.dll (layered meaning names).
--
-- The DLL does ALL the display work locally and instantly (learned Google
-- meanings -> WoW glossary -> smart readable composition), so names are never
-- raw Chinese and never lag. This addon's ONLY job is to feed the learning
-- loop: it nudges WoWTranslate to Google-translate the names currently on
-- screen, so WoWTranslate caches them; the DLL then harvests those into its
-- permanent learned glossary (CNFix_learned.txt) and upgrades the display.
--
-- It does NOT touch any UI text itself (that's the DLL's job) and never changes
-- name data, so invites/whispers are unaffected.

local NAME_CACHE_PREFIX = "\1wt_name:"

local function HasForeign(text)
    if not text then return false end
    for i = 1, string.len(text) do
        local b = string.byte(text, i)
        if (b >= 227 and b <= 237) or b == 208 or b == 209 then return true end
    end
    return false
end


-- ===== LIVE PUSH to the DLL (real-time Google override) =====
-- WoWTranslate translates names into its IN-MEMORY cache immediately, but its
-- file only flushes on /reload. To make the better Google name override the
-- DLL's offline CC-CEDICT name in REAL TIME, we read WoWTranslate's memory cache
-- each tick and push new pairs straight to the DLL via a hidden control string.
local CTRL = "\1CNFX\1"
local pusher = nil
local function EnsurePusher()
    if pusher then return pusher end
    local f = CreateFrame("Frame"); f:Hide()
    pusher = f:CreateFontString(nil, "BACKGROUND")
    pusher:SetFont("Fonts\\FRIZQT__.TTF", 10)        -- explicit font (SetText needs one)
    if not pusher:GetFont() then pusher:SetFont("Fonts\\ARIALN.TTF", 10) end
    return pusher
end
local pushed = {}    -- zh -> en already pushed at this value
local function PushPair(zh, en)
    if not zh or not en or zh == "" or en == "" then return end
    if HasForeign(en) then return end                  -- never push a still-Chinese value
    if pushed[zh] == en then return end
    local ok = pcall(function() EnsurePusher():SetText(CTRL .. zh .. "\1" .. en) end)
    if ok then
        pushed[zh] = en
        -- A Google name just reached the DLL. Let CNFixExtend repaint any
        -- visible frame still showing the word-sub for this name (the DLL
        -- only re-resolves on a fresh SetText). Optional / load-order safe.
        if CNFix_OnUpgrade then pcall(CNFix_OnUpgrade, zh, en) end
    end
end
-- Strip the "\1wt_name:" prefix to recover the raw Chinese key. WoWTranslate
-- stores player names under "\1wt_name:"..name, but guild names and ranks under
-- the SAME prefix with a "guild:"/"rank:" infix (NameCacheKey("guild:"..name)).
-- The overhead guild getter looks the guild up by its BARE string, so we must
-- strip that infix too or the DLL learns "guild:<zh>" and the guild never matches.
local function NameFromKey(k)
    local p = NAME_CACHE_PREFIX
    if string.sub(k, 1, string.len(p)) == p then
        local rest = string.sub(k, string.len(p) + 1)
        local _, ge = string.find(rest, "^guild:")
        if ge then return string.sub(rest, ge + 1) end
        local _, re = string.find(rest, "^rank:")
        if re then return string.sub(rest, re + 1) end
        return rest
    end
    return nil
end
-- Sweep WoWTranslate's live memory cache and push any new Google name to the DLL.
-- Incremental sync: only process cache keys we haven't seen before. A full
-- re-scan every tick scales with the cache size (which balloons in crowded
-- areas) and caused periodic stutter. We remember processed keys and a count,
-- and bail out instantly when nothing new has been added.
local syncSeen = {}
local syncLastCount = 0
local function SyncLiveCache()
    if not WoWTranslateCache then return end
    -- (perf) Single combined pass. Previously this did a FULL count-scan of the WT
    -- cache every tick (1s) purely to detect growth, THEN a second full scan to
    -- harvest -- i.e. two O(n) iterations per second over a cache that can hold
    -- thousands of entries, whenever names were actively arriving. Now we make ONE
    -- pass that simultaneously counts the cache and harvests any unseen keys. If the
    -- count is unchanged since last time, WoWTranslate (which only ever ADDS to its
    -- cache) has nothing new, so we still pay one scan -- but never two -- and the
    -- harvest work is bounded to 25 keys/tick to smooth spikes.
    local count, handled = 0, 0
    for key, meaning in pairs(WoWTranslateCache) do
        count = count + 1
        if not syncSeen[key] and handled < 25 then
            syncSeen[key] = true
            if meaning and not HasForeign(meaning) then
                local zh = NameFromKey(key)
                if zh then PushPair(zh, meaning)
                elseif HasForeign(key) and string.len(key) <= 45 then PushPair(key, meaning) end
            end
            handled = handled + 1
        end
    end
    -- If we hit the per-tick cap there may be more unseen keys; force the next tick
    -- to scan again by leaving syncLastCount behind the real count. Otherwise record
    -- the count so a tick with no growth and nothing new still does just one scan.
    if handled >= 25 then syncLastCount = count - 1 else syncLastCount = count end
end
-- Clear the incremental-sweep state so the next SyncLiveCache re-pushes every
-- name currently in WoWTranslate's cache (used after the realtime toggle is
-- re-enabled, since keys marked "seen" while it was off are otherwise skipped).
function CNFix_ResetSync()
    syncSeen = {}
    syncLastCount = 0
end

-- Ask WoWTranslate to translate a name (fills its Google cache; the DLL harvests
-- it). Skips names WoWTranslate already has. Safe no-op if WoWTranslate absent.
local requested = {}
local function RequestName(zh)
    if not zh or zh == "" or not HasForeign(zh) then return end
    -- (v2.7.0) If WoWTranslate ALREADY has a translation -- under either its name
    -- key ("\1wt_name:"..zh) OR its raw-text key (zh, where idiomatic line
    -- translations live) -- push it to the DLL RIGHT NOW instead of leaving it for
    -- the next 1-3s SyncLiveCache tick. This closes the window where the tooltip
    -- shows WoWTranslate's contextual ("Yesterday's Evening Breeze") while the
    -- overhead/frame still show the compose word-sub ("YesterdayOfEveningWind"):
    -- the contextual lands in g_learned immediately, so resolve_name() returns it
    -- on the very next draw and every surface agrees word-for-word.
    if WoWTranslate_CacheGet then
        local hit = WoWTranslate_CacheGet(NAME_CACHE_PREFIX .. zh) or WoWTranslate_CacheGet(zh)
        if hit and hit ~= "" and not HasForeign(hit) then
            PushPair(zh, hit)
            requested[zh] = true
            return
        end
    end
    if requested[zh] then return end
    if WoWTranslate_API and WoWTranslate_API.IsAvailable and WoWTranslate_API.IsAvailable() then
        requested[zh] = true
        WoWTranslate_API.Translate(zh, function(translation)
            if translation and translation ~= "" then
                if WoWTranslate_CacheSave then WoWTranslate_CacheSave(NAME_CACHE_PREFIX .. zh, translation) end
                PushPair(zh, translation)            -- push to DLL immediately (real-time)
            end
        end, "zh")
    end
end

-- ===== Exposed for CNFixExtend.lua (extra UI surfaces) =====
-- Single naming authority: the new surfaces reuse these exact functions
-- (raw WoWTranslate value via PushPair, same as the unit frames) so every
-- surface agrees. No separate cache / beautify / guid stack.
CNFix_HasForeign  = HasForeign
CNFix_PushPair    = PushPair
CNFix_RequestName = RequestName
CNFix_LearnedPairs = pushed   -- zh -> en (every Google pair pushed this session); read-only for /who reverse search
CNFix_NameCachePrefix = NAME_CACHE_PREFIX

-- Discover Chinese names on screen and request translation for each.
local function DiscoverWho()
    if not GetNumWhoResults or not GetWhoInfo then return end
    local total = GetNumWhoResults() or 0
    if total > 50 then total = 50 end
    for i = 1, total do local nm = GetWhoInfo(i); if nm and HasForeign(nm) then RequestName(nm) end end
end
local function DiscoverGuild()
    if not GetNumGuildMembers or not GetGuildRosterInfo then return end
    local n = GetNumGuildMembers() or 0
    if n > 100 then n = 100 end
    for i = 1, n do local nm = GetGuildRosterInfo(i); if nm and HasForeign(nm) then RequestName(nm) end end
end
local function DiscoverFriends()
    if not GetNumFriends or not GetFriendInfo then return end
    local n = GetNumFriends() or 0
    for i = 1, n do local nm = GetFriendInfo(i); if nm and HasForeign(nm) then RequestName(nm) end end
end
local function DiscoverGroup()
    local n = GetNumRaidMembers and GetNumRaidMembers() or 0
    if n > 0 then for i=1,n do local nm=UnitName("raid"..i); if nm and HasForeign(nm) then RequestName(nm) end end
    else n = GetNumPartyMembers and GetNumPartyMembers() or 0
        for i=1,n do local nm=UnitName("party"..i); if nm and HasForeign(nm) then RequestName(nm) end end end
    local t = UnitName and UnitName("target"); if t and HasForeign(t) then RequestName(t) end
    local m = UnitName and UnitName("mouseover"); if m and HasForeign(m) then RequestName(m) end
end
-- nameplates + any other on-screen CJK FontStrings (LFG titles, etc.)
local function DiscoverWorld()
    if not WorldFrame or not WorldFrame.GetChildren then return end
    local kids = { WorldFrame:GetChildren() }
    for i = 1, table.getn(kids) do
        local plate = kids[i]
        if plate and plate.GetRegions then
            for _, o in pairs({ plate:GetRegions() }) do
                if o and o.GetObjectType and o:GetObjectType() == "FontString" and o.GetText then
                    local txt = o:GetText()
                    if txt and HasForeign(txt) and not string.find(txt, "^Level ") then
                        local lt = string.find(txt, " <", 1, true)
                        RequestName(lt and string.sub(txt,1,lt-1) or txt)
                        -- (v2.6.0) also harvest the OWNER in a pet/companion suffix
                        -- "<Owner's Pet>" (WT/English form) or "<Owner的宠物>" (raw CN
                        -- form). Relation-agnostic: cut at the possessive ("'s" or 的)
                        -- so Pet/Minion/Companion/Guardian all isolate the same owner.
                        -- Requesting it makes the owner's contextual land in g_learned,
                        -- which the multi-run DLL hook then renders inside the suffix.
                        local op = string.find(txt, "<", 1, true)
                        if op then
                            local cl = string.find(txt, ">", op, true)
                            local inside = cl and string.sub(txt, op+1, cl-1) or string.sub(txt, op+1)
                            if inside and inside ~= "" then
                                local ap = string.find(inside, "'s", 1, true)        -- English possessive
                                local de = string.find(inside, string.char(231,154,132), 1, true) -- 的
                                local cut = ap or de
                                local owner = cut and string.sub(inside, 1, cut-1) or inside
                                owner = string.gsub(owner, "^%s+", "")
                                owner = string.gsub(owner, "%s+$", "")
                                if owner ~= "" and HasForeign(owner) then RequestName(owner) end
                            end
                        end
                    end
                end
            end
        end
    end
end

local boot = CreateFrame("Frame")
local tries = 0
boot:SetScript("OnUpdate", function()
    tries = tries + 1
    if WoWTranslateDB then
        WoWTranslateDB.translatePlayerNames = true
        WoWTranslateDB.translateGuildNames = true
        if WoWTranslate_SetTranslatePlayerNames then WoWTranslate_SetTranslatePlayerNames(true) end
        if WoWTranslate_SetTranslateGuildNames then WoWTranslate_SetTranslateGuildNames(true) end
        boot:SetScript("OnUpdate", nil)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFixNames|r ready: feeding the learning loop (DLL shows meanings).")
    elseif tries > 600 then
        boot:SetScript("OnUpdate", nil)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFixNames|r loaded (WoWTranslate not detected; DLL still shows local meanings).")
    end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("WHO_LIST_UPDATE"); ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:RegisterEvent("FRIENDLIST_UPDATE"); ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE"); ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
ev:SetScript("OnEvent", function()
    if event=="WHO_LIST_UPDATE" then DiscoverWho()
    elseif event=="GUILD_ROSTER_UPDATE" then DiscoverGuild()
    elseif event=="FRIENDLIST_UPDATE" then DiscoverFriends()
    else DiscoverGroup() end
end)

-- Force the open social panels to redraw so their rows re-call SetText and the
-- DLL re-applies the (possibly upgraded) translation. The DLL can't repaint a
-- row on its own; it only acts when the client sets the row text. Without this,
-- a name stays at its first-drawn value until you reopen the panel.
local function ForceRedraws()
    if FriendsFrameWhoFrame and FriendsFrameWhoFrame:IsVisible() and WhoList_Update then
        pcall(WhoList_Update)
    end
    if FriendsListFrame and FriendsListFrame:IsVisible() and FriendsList_Update then
        pcall(FriendsList_Update)
    end
    if GuildFrame and GuildFrame:IsVisible() then
        if GuildStatus_Update then pcall(GuildStatus_Update) end
        if GuildRoster_Update then pcall(GuildRoster_Update) end
    end
end

CNFix_ForceRedraws = ForceRedraws

local tick = CreateFrame("Frame")
local acc = 0          -- light cadence (cheap work)
local heavyAcc = 0     -- slow cadence (expensive scans)
local wasRealtime = nil
tick:SetScript("OnUpdate", function()
    -- Respect the "Real-time Contextual names" toggle: when off, skip all the
    -- WoWTranslate discovery/sync work entirely (saves CPU / reduces fps drop).
    if CNFixNamesDB and CNFixNamesDB.realtime == false then wasRealtime = false; return end
    -- On an off->on transition, force a full re-sweep: SyncLiveCache marks a key
    -- "seen" BEFORE pushing, so any name WoWTranslate cached while realtime was off
    -- (and the DLL therefore refused to learn) would never be re-pushed. Resetting
    -- the seen-set re-pushes everything currently in the cache.
    if wasRealtime == false and CNFix_ResetSync then CNFix_ResetSync() end
    wasRealtime = true
    acc = acc + arg1
    heavyAcc = heavyAcc + arg1
    -- light: incremental cache sync (cheap; early-outs when nothing new) ~1s
    if acc >= 1.0 then
        acc = 0
        SyncLiveCache()
    end
    -- heavy: nameplate/world + panel discovery scans, only every ~3s. These
    -- iterate many frames and scale with crowd size, so running them less often
    -- removes the periodic stutter in busy areas. New names still get picked up
    -- within a couple seconds.
    if heavyAcc >= 3.0 then
        heavyAcc = 0
        DiscoverWorld(); DiscoverGroup(); DiscoverWho(); DiscoverGuild(); DiscoverFriends()
        SyncLiveCache()
    end
end)


-- Allow long English names in the mail recipient box. Vanilla caps it at 12
-- (real WoW names are <=12), but our DISPLAYED English names can be longer
-- (e.g. "SummerRainLotus"). The DLL reverse-swaps to the real <=12-char Chinese
-- name before sending, so widening the box is safe.
local mailFix = CreateFrame("Frame")
mailFix:RegisterEvent("MAIL_SHOW")
mailFix:RegisterEvent("PLAYER_ENTERING_WORLD")
mailFix:SetScript("OnEvent", function()
    if SendMailNameEditBox and SendMailNameEditBox.SetMaxLetters then
        SendMailNameEditBox:SetMaxLetters(40)
    end
end)

-- A hidden probe FontString: writing zh to it runs the SAME DLL resolver the
-- real frames use; reading it back reveals what the DLL CURRENTLY renders zh as,
-- i.e. whether the contextual pair is live in the DLL's learned map yet. A unique
-- per-call color defeats the DLL's per-key result cache so every probe is fresh.
local traceProbe
local function DLLRenders(zh, salt)
    if not traceProbe then
        local pf = CreateFrame("Frame"); pf:Hide()
        traceProbe = pf:CreateFontString(nil, "BACKGROUND")
        traceProbe:SetFont("Fonts\\FRIZQT__.TTF", 10)
        if not traceProbe:GetFont() then traceProbe:SetFont("Fonts\\ARIALN.TTF", 10) end
    end
    local ok = pcall(function()
        traceProbe:SetText("|cff0000" .. string.format("%02x", math.mod(salt or 0, 256)) .. zh)
    end)
    if not ok then return "?" end
    local _, t = pcall(function() return traceProbe:GetText() end)
    if type(t) ~= "string" then return "?" end
    local a, b = string.find(t, "^|c%x%x%x%x%x%x%x%x")
    if a then t = string.sub(t, b + 1) end
    return t
end

local function line(label, val) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFix|r " .. label .. ": " .. tostring(val)) end

-- /cnfix         -> quick status
-- /cnfix trace   -> per-link break locator for the current target (or mouseover)
SLASH_CNFIX1 = "/cnfix"
SlashCmdList["CNFIX"] = function(msg)
    msg = msg and string.lower(msg) or ""
    if string.find(msg, "trace", 1, true) then
        local unit = (UnitExists and UnitExists("target")) and "target"
                  or ((UnitExists and UnitExists("mouseover")) and "mouseover" or nil)
        if not unit then line("trace", "no target/mouseover - target a Chinese-named unit and retry"); return end
        local zh = UnitName and UnitName(unit)
        if not (zh and HasForeign(zh)) then line("trace", "unit '" .. tostring(zh) .. "' is not Chinese-named"); return end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFix trace|r ===== " .. zh .. " (" .. unit .. ") =====")
        -- LINK 1: does WoWTranslate have a contextual translation, and under which key?
        local nameHit = WoWTranslate_CacheGet and WoWTranslate_CacheGet("\1wt_name:" .. zh)
        local rawHit  = WoWTranslate_CacheGet and WoWTranslate_CacheGet(zh)
        line("1. WT name-key (\\1wt_name:zh)", nameHit or "MISS")
        line("1. WT raw-key   (zh)", rawHit or "MISS")
        -- LINK 2: was it pushed to the DLL this session?
        line("2. addon pushed this session", (CNFix_LearnedPairs and CNFix_LearnedPairs[zh]) or "NO")
        -- LINK 3: what does the DLL render the name as RIGHT NOW? (the ground truth)
        line("3. DLL renders name as", DLLRenders(zh, math.random(0, 255)))
        -- LINK 4: realtime gate (off here disables BOTH the sweep and DLL learning)
        line("4. realtime toggle", (CNFixNamesDB and CNFixNamesDB.realtime ~= false) and "ON" or "OFF (this blocks learning!)")
        -- GUILD link (if the unit is guilded)
        local g = GetGuildInfo and GetGuildInfo(unit)
        if g and HasForeign(g) then
            local gHit = WoWTranslate_CacheGet and WoWTranslate_CacheGet("\1wt_name:guild:" .. g)
            line("G. guild '" .. g .. "' WT-cached", gHit or "MISS")
            line("G. guild pushed this session", (CNFix_LearnedPairs and CNFix_LearnedPairs[g]) or "NO")
            line("G. DLL renders guild as", DLLRenders(g, math.random(0, 255)))
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCNFix trace|r  If 1=hit but 3 still word-sub: learning is blocked (check link 4 / DLL). If 1=MISS: WoWTranslate hasn't translated it yet.")
        return
    end
    local n = 0
    if WoWTranslateCache then for _ in pairs(WoWTranslateCache) do n = n + 1 end end
    line("status", "addon loaded. WoWTranslate API=" .. tostring(WoWTranslate_API ~= nil)
        .. ", cached entries=" .. n .. ", realtime="
        .. ((CNFixNamesDB and CNFixNamesDB.realtime ~= false) and "ON" or "OFF")
        .. ". Use '/cnfix trace' on a target to locate a break.")
end
