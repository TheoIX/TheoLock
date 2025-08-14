-- TheoLock - Warlock smart-cast (Turtle WoW 1.12-safe) + robust DoT detection

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
    window = window or 3.0
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
    ["Corruption"]       = "Spell_Shadow_AbominationExplosion",
    ["Curse of Agony"]   = "Spell_Shadow_CurseOfSargeras",
}

local function HasDebuffByIcon(unit, spell)
    local key = DOT_ICON_TAIL[spell]
    if not key then return false end
    for i = 1, 16 do
        local tex = UnitDebuff(unit, i)
        if not tex then break end
        -- match end of path to be robust across interface paths
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
    local r1,r2,r3,r4,r5,r6,r7,r8 = frame:GetRegions()
    local regions = { r1,r2,r3,r4,r5,r6,r7,r8 }
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
    -- 1) Icon texture (most reliable and fast)
    if HasDebuffByIcon("target", dotName) then return true end
    -- 2) Tooltip name scan (rank-agnostic)
    if HasDebuffByTooltip("target", dotName) then return true end
    -- 3) pfUI frame text fallback (last resort)
    local n = normalizeAuraName(dotName)
    if n == "Corruption" or n == "Curse of Agony" then
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
    -- hint: if we just applied Corruption, prefer CoA next for a short window
    if spell == "Corruption" then
        TheoLock.preferCoAUntil = GetTime() + 3.0
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

    -- TOP PRIO: Keep DoTs up (Corruption -> Curse of Agony)
    if safeHostileTarget() and not TargetHasDotRobust("Corruption") and not recentlyCast("Corruption", 3.0) then
        if cast("Corruption") then return end
    end

    -- If we recently applied Corruption, strongly try CoA next if it’s missing
    if safeHostileTarget() and GetTime() < (TheoLock.preferCoAUntil or 0)
       and not TargetHasDotRobust("Curse of Agony") and not recentlyCast("Curse of Agony", 3.0) then
        if cast("Curse of Agony") then return end
    end

    -- Regular CoA upkeep (if not already caught by the preference above)
    if safeHostileTarget() and not TargetHasDotRobust("Curse of Agony") and not recentlyCast("Curse of Agony", 3.0) then
        if cast("Curse of Agony") then return end
    end

    -- Nightfall proc: Shadow Bolt (buff is "Shadow Trance" on 1.12)
    if safeHostileTarget() and HasBuff("player", "Shadow Trance") then
        if cast("Shadow Bolt") then return end
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
            "TheoLock: chann=%s (%s) | last=%s age=%.1fs | preferCoA=%.1fs | pfTarget=%s",
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
