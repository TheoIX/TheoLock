-- TheoLock - Warlock smart-cast (Turtle WoW 1.12-safe)
-- Rewritten to mirror the warrior script style:
--  * One function per spell / ability
--  * Main handler calls them in priority order
--  * DoTs/curses are driven ONLY by actual debuffs on the target
--  * No "recentlyCast" throttle -> resists are handled naturally

local TheoLock = CreateFrame("Frame", "TheoLockFrame")

TheoLock.isChanneling   = false
TheoLock.channelSpell   = nil

-- Last cast info (for /theolock status only)
TheoLock.lastCastName   = nil
TheoLock.lastCastAt     = 0

-- pfUI target frame cache
TheoLock.pfTargetFrame  = nil
TheoLock.pfLastScan     = 0
TheoLock.pfScanCooldown = 0.25 -- seconds between heavy frame enumerations

-- PvP mode toggle: /lockbg
TheoLock.pvpMode        = false

-- -------- Small utils --------

local function pct(unit)
    local hp, max = UnitHealth(unit), UnitHealthMax(unit)
    if not hp or not max or max == 0 then return 1 end
    return hp / max
end

local function normalizeAuraName(s)
    if not s then return nil end
    -- Strip " (Rank X)" etc
    s = string.gsub(s, "%s*%b()", "")
    return s
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
    ["Corruption"]            = "Spell_Shadow_AbominationExplosion",
    ["Curse of Agony"]        = "Spell_Shadow_CurseOfSargeras",
    ["Siphon Life"]           = "Spell_Shadow_Requiem",
    ["Curse of Exhaustion"]   = "Spell_Shadow_GrimWard",
    ["Curse of Tongues"]      = "Spell_Shadow_CurseOfTounges", -- note spelling
    ["Curse of the Elements"] = "Spell_Shadow_ChillTouch",
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
        if frameTreeHasText(child, needleLower) then
            return true
        end
    end

    return false
end

local function pfuiTargetHasString(str)
    local f = TheoLock.pfTargetFrame or findPfTargetFrame()
    if not f then return false end
    return frameTreeHasText(f, string.lower(str))
end

-- Robust "does the target have this DoT/curse?" check.
local function TargetHasDotRobust(dotName)
    if not UnitExists("target") then return false end

    -- First: icon + tooltip
    if HasDebuffByIcon("target", dotName) then return true end
    if HasDebuffByTooltip("target", dotName) then return true end

    -- Fallback: pfUI text scan, using normalized name
    local n = normalizeAuraName(dotName)
    if n and pfuiTargetHasString(n) then
        return true
    end

    return false
end

-- Any warlock curse currently on the target?
local function TargetHasAnyWarlockCurse()
    return TargetHasDotRobust("Curse of Agony")
        or TargetHasDotRobust("Curse of Exhaustion")
        or TargetHasDotRobust("Curse of Tongues")
        or TargetHasDotRobust("Curse of the Elements")
end

local function safeHostileTarget()
    return UnitExists("target") and not UnitIsDeadOrGhost("target") and UnitCanAttack("player", "target")
end

-- Generic cast wrapper: respects Health Funnel channel, updates lastCast info
local function cast(spell)
    -- Do not interrupt Health Funnel once channeling
    if TheoLock.isChanneling and TheoLock.channelSpell == "Health Funnel" then
        return true
    end

    CastSpellByName(spell)
    TheoLock.lastCastName = spell
    TheoLock.lastCastAt   = GetTime()
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
        -- Non-channel casts reset the channel state
        TheoLock.isChanneling = false
        TheoLock.channelSpell = nil
    end
end)

TheoLock:RegisterEvent("SPELLCAST_CHANNEL_START")
TheoLock:RegisterEvent("SPELLCAST_CHANNEL_STOP")
TheoLock:RegisterEvent("SPELLCAST_START")

-- =====================================================================
--  ROTATION ABILITY FUNCTIONS (one per spell, like warrior script)
-- =====================================================================

-- 1) Nightfall proc: Shadow Trance → instant Shadow Bolt
local function CastNightfallShadowBolt()
    if not safeHostileTarget() then return false end
    if not HasBuff("player", "Shadow Trance") then return false end
    return cast("Shadow Bolt")
end

-- 2) PvP mode: class-targeted disruptive curse (after Nightfall)
local function CastPvPCurse()
    if not TheoLock.pvpMode then return false end
    if not safeHostileTarget() then return false end

    local _, classFile = UnitClass("target")
    if not classFile then return false end

    local melee  = { WARRIOR=true, PALADIN=true, HUNTER=true, ROGUE=true }
    local casters = { MAGE=true, WARLOCK=true, PRIEST=true, DRUID=true, SHAMAN=true }

    local desired
    if melee[classFile] then
        desired = "Curse of Exhaustion"
    elseif casters[classFile] then
        desired = "Curse of Tongues"
    end
    if not desired then return false end

    -- Only cast if that curse is actually missing
    if TargetHasDotRobust(desired) then return false end

    return cast(desired)
end

-- 3) PvE: Curse of the Elements (when PvP mode is OFF)
local function CastCurseOfElements()
    if TheoLock.pvpMode then return false end
    if not safeHostileTarget() then return false end
    if TargetHasDotRobust("Curse of the Elements") then return false end
    return cast("Curse of the Elements")
end

-- 4) Corruption upkeep
local function CastCorruption()
    if not safeHostileTarget() then return false end
    if TargetHasDotRobust("Corruption") then return false end
    return cast("Corruption")
end

-- 5) Curse of Agony: only if no other warlock curse is present
local function CastCurseOfAgony()
    if not safeHostileTarget() then return false end
    if TargetHasAnyWarlockCurse() then return false end
    return cast("Curse of Agony")
end

-- 6) Siphon Life upkeep
local function CastSiphonLife()
    if not safeHostileTarget() then return false end
    if TargetHasDotRobust("Siphon Life") then return false end
    return cast("Siphon Life")
end

-- 7) Pet safety: Health Funnel if pet exists and <50% HP
local function CastHealthFunnel()
    if not UnitExists("pet") or UnitIsDeadOrGhost("pet") then return false end
    if pct("pet") >= 0.50 then return false end
    TheoLock.channelSpell = "Health Funnel"
    return cast("Health Funnel")
end

-- 8) Self sustain: Drain Life if player <50% HP
local function CastDrainLife()
    if not safeHostileTarget() then return false end
    if pct("player") >= 0.50 then return false end
    return cast("Drain Life")
end

-- 9) Filler / execute: Drain Soul ONLY if all three core DoTs are present
local function CastDrainSoulExecute()
    if not safeHostileTarget() then return false end

    local hasCorr = TargetHasDotRobust("Corruption")
    local hasCoA  = TargetHasDotRobust("Curse of Agony")
    local hasSL   = TargetHasDotRobust("Siphon Life")

    if not (hasCorr and hasCoA and hasSL) then
        return false
    end

    return cast("Drain Soul")
end

-- =====================================================================
--  MAIN PULSE (called from /theolock, like the warrior rotation)
-- =====================================================================

function TheoLock:Pulse()
    -- Never break an ongoing Health Funnel channel
    if TheoLock.isChanneling and TheoLock.channelSpell == "Health Funnel" then
        return
    end

    -- Priority list, top to bottom:

    -- 1) Nightfall proc: instant Shadow Bolt
    if CastNightfallShadowBolt() then return end

    -- 2) PvP disruptive curses (CoEx / CoT), when enabled
    if CastPvPCurse() then return end

    -- 3) PvE: Curse of the Elements (only when PvP mode OFF)
    if CastCurseOfElements() then return end

    -- 4) Core DoT upkeep
    if CastCorruption() then return end
    if CastCurseOfAgony() then return end
    if CastSiphonLife() then return end

    -- 5) Pet safety
    if CastHealthFunnel() then return end

    -- 6) Self sustain
    if CastDrainLife() then return end

    -- 7) Filler / execute
    if CastDrainSoulExecute() then return end

    -- Else: do nothing on this press; next press will try again
end

-- -------- Slash commands --------

SLASH_THEOLOCK1 = "/theolock"
SlashCmdList["THEOLOCK"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "TheoLock: pvpMode=%s | chann=%s (%s) | last=%s age=%.1fs | pfTarget=%s",
            tostring(TheoLock.pvpMode),
            tostring(TheoLock.isChanneling),
            tostring(TheoLock.channelSpell or "none"),
            tostring(TheoLock.lastCastName or "none"),
            (GetTime() - (TheoLock.lastCastAt or 0)),
            tostring((TheoLock.pfTargetFrame and (TheoLock.pfTargetFrame:GetName() or "unnamed")) or "nil")
        ))
        return
    end

    TheoLock:Pulse()
end

-- /lockbg: toggle PvP mode on/off (class-targeted curses)
SLASH_LOCKBG1 = "/lockbg"
SlashCmdList["LOCKBG"] = function()
    TheoLock.pvpMode = not TheoLock.pvpMode
    DEFAULT_CHAT_FRAME:AddMessage(
        "TheoLock PvP mode: " ..
        (TheoLock.pvpMode and "ON (class-targeted curses)" or "OFF")
    )
end
