-- TheoLock - Warlock smart-cast (Turtle WoW 1.12-safe)
-- Additions in this version:
--  * "recent cast" throttle reduced from 3.0s to 1.4s
--  * Nightfall (Shadow Trance) moved to absolute top priority
--  * Toggleable PvP mode (/lockbg):
--      - vs WARRIOR/PALADIN/HUNTER/ROGUE => top-prio Curse of Exhaustion (if missing)
--      - vs MAGE/WARLOCK/PRIEST/DRUID/SHAMAN => top-prio Curse of Tongues (if missing)
--  * NEW: Adds Curse of the Elements detection + priority above Corruption/CoA/Siphon Life
--    (All other logic unchanged; DoT upkeep and fillers proceed as usual.)

local TheoLock = CreateFrame("Frame", "TheoLockFrame")
TheoLock.isChanneling = false
TheoLock.channelSpell = nil

-- Track last cast to avoid instant re-casts while auras apply
TheoLock.lastCastName = nil
TheoLock.lastCastAt = 0

-- pfUI target frame cache
TheoLock.pfTargetFrame = nil
TheoLock.pfLastScan = 0
TheoLock.pfScanCooldown = 0.25 -- seconds between heavy frame enumerations

-- nudge logic: after casting Corruption, prefer CoA on next pulse
TheoLock.preferCoAUntil = 0

-- PvP mode toggle
TheoLock.pvpMode = false

-- -------- Utils --------
local function pct(unit)
    local hp, max = UnitHealth(unit), UnitHealthMax(unit)
    if not hp or not max or max == 0 then return 1 end
    return hp / max
end

local function normalizeAuraName(s)
    if not s then return nil end
    s = string.gsub(s, "%s*%b()", "") -- strip " (Rank X)"
    return s
end

local function recentlyCast(spell, window)
    window = window or 1.4 -- reduced from 3.0s -> 1.4s
    return (TheoLock.lastCastName == spell) and ((GetTime() - (TheoLock.lastCastAt or 0)) < window)
end

-- Hidden tooltip for aura name scanning (1.12-safe)
local scanTip = CreateFrame("GameTooltip", "TheoLockScanTip", UIParent, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

local function AuraNameAt(unit, index, isDebuff)
    scanTip:ClearLines()
    if isDebuff then
        local tex = UnitDebuff(unit, index)
        if not tex then return nil end
        if scanTip.SetUnitDebuff then scanTip:SetUnitDebuff(unit, index) end
    else
        local tex = UnitBuff(unit, index)
        if not tex then return nil end
        if scanTip.SetUnitBuff then scanTip:SetUnitBuff(unit, index) end
    end
    local left = getglobal("TheoLockScanTipTextLeft1")
    return left and left:GetText() or nil
end

local function escapePattern(s)
    return (string.gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- -------- Debuff detection: ICON -> TOOLTIP -> pfUI fallback --------
-- Known icon keys (tail of the texture path) on 1.12
local DOT_ICON_TAIL = {
    ["Corruption"]              = "Spell_Shadow_AbominationExplosion",
    ["Curse of Agony"]          = "Spell_Shadow_CurseOfSargeras",
    ["Siphon Life"]             = "Spell_Shadow_Requiem",
    ["Curse of Exhaustion"]     = "Spell_Shadow_GrimWard",          -- user-supplied
    ["Curse of Tongues"]        = "Spell_Shadow_CurseOfTounges",     -- user-supplied (note texture spelling)
    ["Curse of the Elements"]   = "Spell_Shadow_ChillTouch",         -- new
}

local function HasDebuffByIcon(unit, spell)
    local key = DOT_ICON_TAIL[spell]
    if not key then return false end
    for i = 1, 16 do
        local tex = UnitDebuff(unit, i)
        if not tex then break end
        if string.find(tex, key, 1, true) then
            return true
        end
    end
    return false
end

local function HasDebuffByTooltip(unit, name)
    if not UnitExists(unit) then return false end
    name = normalizeAuraName(name)
    local prefix = "^" .. escapePattern(name)
    for i = 1, 16 do
        local n = AuraNameAt(unit, i, true)
        if not n then break end
        n = normalizeAuraName(n)
        if n == name or string.find(n, prefix) then
            return true
        end
    end
    return false
end

local function HasBuff(unit, name)
    if not UnitExists(unit) then return false end
    name = normalizeAuraName(name)
    local prefix = "^" .. escapePattern(name)
    for i = 1, 16 do
        local n = AuraNameAt(unit, i, false)
        if not n then break end
        n = normalizeAuraName(n)
        if n == name or string.find(n, prefix) then
            return true
        end
    end
    return false
end

-- -------- pfUI fallback scanning (last resort) --------
local function findPfTargetFrame()
    local guessNames = { "pfTarget", "pfUITarget", "pfUI.uf.target", "pfUITargetFrame", "pfUnitFrameTarget" }
    for _, n in ipairs(guessNames) do
        local f = getglobal(n)
        if f and f.GetObjectType and f:GetObjectType() == "Frame" then
            return f
        end
    end
    local now = GetTime()
    if (now - (TheoLock.pfLastScan or 0)) < TheoLock.pfScanCooldown then
        return TheoLock.pfTargetFrame
    end
    TheoLock.pfLastScan = now
    if EnumerateFrames then
        local f = EnumerateFrames()
        while f do
            if f.GetName and f:GetName() then
                local nm = string.lower(f:GetName())
                if string.find(nm, "pf", 1, true) and string.find(nm, "target", 1, true)
                   and f.GetObjectType and f:GetObjectType() == "Frame" then
                    TheoLock.pfTargetFrame = f
                    return f
                end
            end
            f = EnumerateFrames(f)
        end
    end
    return TheoLock.pfTargetFrame
end

local function frameTreeHasText(frame, needleLower)
    if not frame or not frame.IsShown or not frame:IsShown() then return false end
    local regions = { frame:GetRegions() }
    for _, r in ipairs(regions) do
        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
            local t = r:GetText()
            if t and string.find(string.lower(t), needleLower, 1, true) then
                return true
            end
        end
    end
    local children = { frame:GetChildren() }
    for _, child in ipairs(children) do
        if frameTreeHasText(child, needleLower) then return true end
    end
    return false
end

local function pfuiTargetHasString(str)
    local f = TheoLock.pfTargetFrame or findPfTargetFrame()
    if not f then return false end
    return frameTreeHasText(f, string.lower(str))
end

local function TargetHasDotRobust(dotName)
    if HasDebuffByIcon("target", dotName) then return true end
    if HasDebuffByTooltip("target", dotName) then return true end
    local n = normalizeAuraName(dotName)
    if n == "Corruption" or n == "Curse of Agony" or n == "Siphon Life" or n == "Curse of Exhaustion" or n == "Curse of Tongues" or n == "Curse of the Elements" then
        if pfuiTargetHasString(n) then return true end
    end
    return false
end

local function safeHostileTarget()
    return UnitExists("target") and not UnitIsDeadOrGhost("target") and UnitCanAttack("player", "target")
end

local function cast(spell)
    -- Do not interrupt Health Funnel once channeling
    if TheoLock.isChanneling and TheoLock.channelSpell == "Health Funnel" then
        return true
    end
    CastSpellByName(spell)
    TheoLock.lastCastName = spell
    TheoLock.lastCastAt = GetTime()
    -- hint: if we just applied Corruption, prefer CoA next for a short window (reduced to 1.4s)
    if spell == "Corruption" then
        TheoLock.preferCoAUntil = GetTime() + 1.4
    end
    return true
end

-- -------- Events (1.12 uses globals 'event', 'arg1', ...) --------
TheoLock:SetScript("OnEvent", function()
    if event == "SPELLCAST_CHANNEL_START" then
        TheoLock.isChanneling = true
        if arg1 and arg1 ~= "" then
            TheoLock.channelSpell = arg1
        end
    elseif event == "SPELLCAST_CHANNEL_STOP" then
        TheoLock.isChanneling = false
        TheoLock.channelSpell = nil
    elseif event == "SPELLCAST_START" then
        TheoLock.isChanneling = false
        TheoLock.channelSpell = nil
    end
end)

TheoLock:RegisterEvent("SPELLCAST_CHANNEL_START")
TheoLock:RegisterEvent("SPELLCAST_CHANNEL_STOP")
TheoLock:RegisterEvent("SPELLCAST_START")

-- -------- Core logic --------
function TheoLock:Pulse()
    -- Respect ongoing Health Funnel
    if TheoLock.isChanneling and TheoLock.channelSpell == "Health Funnel" then
        return
    end

    -- ABSOLUTE TOP PRIO: Nightfall proc (Shadow Trance)
    if safeHostileTarget() and HasBuff("player", "Shadow Trance") then
        if cast("Shadow Bolt") then return end
    end

    -- PvP mode: class-targeted disruptive curse at TOP priority (after Nightfall)
    if TheoLock.pvpMode and safeHostileTarget() then
        local _, classFile = UnitClass("target")
        if classFile then
            local melee = { WARRIOR=true, PALADIN=true, HUNTER=true, ROGUE=true }
            local castr = { MAGE=true, WARLOCK=true, PRIEST=true, DRUID=true, SHAMAN=true }
            local desired
            if melee[classFile] then
                desired = "Curse of Exhaustion"
            elseif castr[classFile] then
                desired = "Curse of Tongues"
            end
            if desired and not TargetHasDotRobust(desired) and not recentlyCast(desired, 1.4) then
                if cast(desired) then return end
            end
        end
    end

    -- NEW: Curse of the Elements (priority above Corr/CoA/SL)
    if safeHostileTarget() and not TargetHasDotRobust("Curse of the Elements") and not recentlyCast("Curse of the Elements", 1.4) then
        if cast("Curse of the Elements") then return end
    end

    -- TOP PRIO BUCKET: Keep DoTs up (Corruption -> CoA -> Siphon Life)
    if safeHostileTarget() and not TargetHasDotRobust("Corruption") and not recentlyCast("Corruption", 1.4) then
        if cast("Corruption") then return end
    end

    -- If we recently applied Corruption, strongly try CoA next if it’s missing
    if safeHostileTarget() and GetTime() < (TheoLock.preferCoAUntil or 0)
       and not TargetHasDotRobust("Curse of the Elements")
       and not TargetHasDotRobust("Curse of Agony") and not recentlyCast("Curse of Agony", 1.4) then
        if cast("Curse of Agony") then return end
    end

    -- Regular CoA upkeep (if not already caught by the preference above)
    if safeHostileTarget()
       and not TargetHasDotRobust("Curse of the Elements")
       and not TargetHasDotRobust("Curse of Agony") and not recentlyCast("Curse of Agony", 1.4) then
        if cast("Curse of Agony") then return end
    end

    -- Siphon Life upkeep (same priority bucket as CoA, above fillers)
    if safeHostileTarget() and not TargetHasDotRobust("Siphon Life") and not recentlyCast("Siphon Life", 1.4) then
        if cast("Siphon Life") then return end
    end

    -- Pet safety: Health Funnel if pet exists and <50%
    if UnitExists("pet") and not UnitIsDeadOrGhost("pet") and pct("pet") < 0.50 then
        TheoLock.channelSpell = "Health Funnel"
        if cast("Health Funnel") then return end
    end

    -- Self sustain: Drain Life if player <50%
    if safeHostileTarget() and pct("player") < 0.50 then
        if cast("Drain Life") then return end
    end

    -- Filler / Execute: ONLY Drain Soul if all three core DoTs are present
    if safeHostileTarget() then
        local hasCorr = TargetHasDotRobust("Corruption")
        local hasCoA  = TargetHasDotRobust("Curse of Agony")
        local hasSL   = TargetHasDotRobust("Siphon Life")
        if hasCorr and hasCoA and hasSL then
            cast("Drain Soul")
        end
        -- else: do nothing; next press will attempt to (re)apply missing DoTs
    end
end

-- -------- Slash commands --------
SLASH_THEOLOCK1 = "/theolock"
SlashCmdList["THEOLOCK"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "TheoLock: pvpMode=%s | chann=%s (%s) | last=%s age=%.1fs | preferCoA=%.1fs | pfTarget=%s",
            tostring(TheoLock.pvpMode),
            tostring(TheoLock.isChanneling),
            tostring(TheoLock.channelSpell or "none"),
            tostring(TheoLock.lastCastName or "none"),
            (GetTime() - (TheoLock.lastCastAt or 0)),
            math.max(0, (TheoLock.preferCoAUntil or 0) - GetTime()),
            tostring((TheoLock.pfTargetFrame and (TheoLock.pfTargetFrame:GetName() or "unnamed")) or "nil")
        ))
        return
    end
    TheoLock:Pulse()
end

-- /lockbg: toggle PvP mode on/off
SLASH_LOCKBG1 = "/lockbg"
SlashCmdList["LOCKBG"] = function()
    TheoLock.pvpMode = not TheoLock.pvpMode
    DEFAULT_CHAT_FRAME:AddMessage("TheoLock PvP mode: " .. (TheoLock.pvpMode and "ON (class-targeted curses)" or "OFF"))
end
