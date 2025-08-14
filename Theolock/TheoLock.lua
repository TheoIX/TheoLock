-- TheoLock - Warlock smart-cast (Turtle WoW 1.12-safe) + pfUI fallback scan

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

-- -------- Utils --------
local function pct(unit)
    local hp, max = UnitHealth(unit), UnitHealthMax(unit)
    if not hp or not max or max == 0 then return 1 end
    return hp / max
end

local function normalizeAuraName(s)
    if not s then return nil end
    -- Strip trailing parenthetical suffixes like " (Rank 3)"
    s = string.gsub(s, "%s*%b()", "")
    return s
end

local function recentlyCast(spell, window)
    window = window or 2.0
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
    -- escape Lua pattern magic chars
    return (string.gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function HasDebuff(unit, name)
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

-- -------- pfUI fallback scanning --------
-- We try to find pfUI's target frame once and cache it.
local function findPfTargetFrame()
    -- quick direct guesses first (cheap)
    local guessNames = { "pfTarget", "pfUITarget", "pfUI.uf.target", "pfUITargetFrame", "pfUnitFrameTarget" }
    for _, n in ipairs(guessNames) do
        local f = getglobal(n)
        if f and f.GetObjectType and f:GetObjectType() == "Frame" then
            return f
        end
    end

    -- throttle expensive enumeration
    local now = GetTime()
    if (now - (TheoLock.pfLastScan or 0)) < TheoLock.pfScanCooldown then
        return TheoLock.pfTargetFrame
    end
    TheoLock.pfLastScan = now

    -- brute force: enumerate all frames and pick a likely pf target frame
    if EnumerateFrames then
        local f = EnumerateFrames()
        while f do
            if f.GetName and f:GetName() then
                local nm = string.lower(f:GetName())
                if string.find(nm, "pf") and string.find(nm, "target") and f.GetObjectType and f:GetObjectType() == "Frame" then
                    TheoLock.pfTargetFrame = f
                    return f
                end
            end
            f = EnumerateFrames(f)
        end
    end
    return TheoLock.pfTargetFrame
end

-- recursively check any FontString text within a frame & its children
local function frameTreeHasText(frame, needleLower)
    if not frame or not frame.IsShown or not frame:IsShown() then return false end

    -- regions: textures / fontstrings
    local r1, r2, r3, r4, r5, r6, r7, r8 = frame:GetRegions()
    local regions = { r1, r2, r3, r4, r5, r6, r7, r8 }
    for _, r in ipairs(regions) do
        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
            local t = r:GetText()
            if t and string.find(string.lower(t), needleLower, 1, true) then
                return true
            end
        end
    end

    -- children: recurse
    local c = { frame:GetChildren() }
    for _, child in ipairs(c) do
        if frameTreeHasText(child, needleLower) then
            return true
        end
    end

    return false
end

-- Check pfUI target frame for a raw string (case-insensitive).
local function pfuiTargetHasString(str)
    local f = TheoLock.pfTargetFrame or findPfTargetFrame()
    if not f then return false end
    return frameTreeHasText(f, string.lower(str))
end

-- Wrapper for DoT checks that falls back to pfUI string scan (target only).
local function TargetHasDotWithFallback(dotName)
    -- 1) normal tooltip-based scan
    if HasDebuff("target", dotName) then return true end

    -- 2) pfUI fallback only for specific DoTs
    local n = normalizeAuraName(dotName)
    if n == "Corruption" or n == "Curse of Agony" then
        if pfuiTargetHasString(n) then
            return true
        end
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
        -- any new cast cancels channel state
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

    -- TOP PRIO: Keep DoTs up (Corruption -> Curse of Agony), using pfUI fallback if needed
    if safeHostileTarget() and not TargetHasDotWithFallback("Corruption") and not recentlyCast("Corruption", 2.5) then
        if cast("Corruption") then return end
    end
    if safeHostileTarget() and not TargetHasDotWithFallback("Curse of Agony") and not recentlyCast("Curse of Agony", 2.5) then
        if cast("Curse of Agony") then return end
    end

    -- Nightfall proc: Shadow Bolt (buff is "Shadow Trance" on 1.12)
    if safeHostileTarget() and HasBuff("player", "Shadow Trance") then
        if cast("Shadow Bolt") then return end
    end

    -- Pet safety: Health Funnel if pet exists and <50%
    if UnitExists("pet") and not UnitIsDeadOrGhost("pet") and pct("pet") < 0.50 then
        TheoLock.channelSpell = "Health Funnel" -- prime guard for cores without arg1
        if cast("Health Funnel") then return end
    end

    -- Self sustain: Drain Life if player <50%
    if safeHostileTarget() and pct("player") < 0.50 then
        if cast("Drain Life") then return end
    end

    -- Fallback
    if safeHostileTarget() then
        cast("Drain Soul")
    end
end

-- -------- Slash command --------
SLASH_THEOLOCK1 = "/theolock"
SlashCmdList["THEOLOCK"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "TheoLock: channeling=%s (%s) | lastCast=%s age=%.1fs | pfTarget=%s",
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


