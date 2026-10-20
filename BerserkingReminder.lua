--[[
    Berserking Reminder 1.0.0
    Shows the Troll racial Berserking whenever it's off cooldown during a fight, so you
    remember to use it. "/berserk always" shows it out of combat as well.

    Built for WoW: Forever, which runs the modern (Midnight 12.x) addon API. In combat that
    API hides cooldown timers from addons, but it still says whether a cooldown is running
    (the isActive flag is never secret), and that's all this reminder needs.

    It only does anything on characters that know Berserking, so non-Troll characters
    never see it. Type /berserk (or /bzr) in game for the commands.
]]

local ADDON_NAME = ...

----------------------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------------------

local TICK         = 0.1    -- display refresh interval
local GCD_MAX      = 1.5    -- a cooldown this short is only the global cooldown
local TEST_SECONDS = 10
local ICON_SIZE    = 52

local BERSERKING_SPELLS = { 20554, 26296, 26297 }   -- the mana, rage and energy versions
local DEFAULT_ICON = "Interface\\Icons\\Racial_Troll_Berserk"

local FONT   = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local PREFIX = "|cffff8c33Berserking Reminder:|r "

local DEFAULTS = {
    enabled         = true,
    locked          = true,
    point           = { "CENTER", "CENTER", 70, 140 },   -- just right of Well Fed Reminder's spot
    scale           = 1,
    showOutOfCombat = false,
    sound           = true,
}

local STYLES = {
    ready    = { r = 1.00, g = 0.55, b = 0.20, label = "Berserking ready",       pulse = true },
    test     = { r = 1.00, g = 0.55, b = 0.20, label = "Test: Berserking ready", pulse = true },
    tracking = { r = 0.60, g = 0.60, b = 0.60, label = "Berserking",             pulse = false },
    unlocked = { r = 0.55, g = 0.80, b = 1.00, label = "Drag me, /berserk lock", pulse = false },
}

----------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------

local db                        -- BerserkingReminderDB, ready after ADDON_LOADED
local frame                     -- the icon
local spellID, spellName        -- this character's Berserking, if it has one
local spellIcon
local testUntil
local shownState
local inCombat   = false
local gcdOnly    = false        -- the last cooldown update showed only the global cooldown
local swipeStale = true         -- the cooldown swipe needs setting again ("tracking" only)
local wasReady                  -- readiness at the previous refresh, for the alert sound
local lastError

----------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = CopyDefaults(v, {})
            else
                dst[k] = v
            end
        end
    end
    return dst
end

local function FormatTime(seconds)
    seconds = math.max(0, math.ceil(seconds))
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end
    return tostring(seconds)
end

local function OnOff(value)
    return value and "|cff40ff40on|r" or "|cffff4040off|r"
end

local function PlayAlert()
    local kit = (SOUNDKIT and SOUNDKIT.MAP_PING) or 3175
    pcall(PlaySound, kit, "Master")
end

-- Secret values (Midnight-era API): addon code may not compare or test them, so every
-- value read from cooldown data is checked with issecretvalue() before it is used.
local issecretvalue, canaccesstable = issecretvalue, canaccesstable

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function Plain(v)                 -- the value, or nil if it's secret
    if IsSecret(v) then return nil end
    return v
end

local function IsTrue(fn, ...)          -- true only for a plain, truthy result of fn(...)
    if type(fn) ~= "function" then return false end
    local ok, result = pcall(fn, ...)
    if not ok or IsSecret(result) then return false end
    return result and true or false
end

----------------------------------------------------------------------------------------
-- Finding Berserking
----------------------------------------------------------------------------------------

local function Knows(id)
    return IsTrue(IsPlayerSpell, id) or IsTrue(IsSpellKnown, id)
        or IsTrue(C_SpellBook and C_SpellBook.IsSpellKnown, id)
end

local function SpellName(id)
    local getName = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
    if not getName then return nil end
    local ok, name = pcall(getName, id)
    if ok and type(name) == "string" and not IsSecret(name) then return name end
    return nil
end

local function SpellTexture(id)
    local getTexture = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
    if not getTexture then return nil end
    local ok, texture = pcall(getTexture, id)
    if ok and texture and not IsSecret(texture) then return texture end
    return nil
end

local function FindBerserking()
    for _, id in ipairs(BERSERKING_SPELLS) do
        if Knows(id) then return id end
    end

    -- Any other version of the spell: look it up by its name in this client's language.
    local name = SpellName(BERSERKING_SPELLS[1])
    if name and C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, name)
        if ok and type(info) == "table" then
            local id = Plain(info.spellID)
            if type(id) == "number" and Knows(id) then return id end
        end
    end
    return nil
end

local function UpdateSpell()
    spellID = FindBerserking()
    spellName = spellID and SpellName(spellID) or nil
    spellIcon = spellID and SpellTexture(spellID) or nil
end

----------------------------------------------------------------------------------------
-- Reading the cooldown
----------------------------------------------------------------------------------------

local function GetCooldown(id)          -- the spell's cooldown info table, or nil
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, id)
        if ok and type(info) == "table" and (not canaccesstable or canaccesstable(info)) then
            return info
        end
    elseif GetSpellCooldown then                                 -- older clients
        local ok, start, duration = pcall(GetSpellCooldown, id)
        if ok then return { startTime = start, duration = duration } end
    end
    return nil
end

-- Returns true (off cooldown), false (cooling down) or nil (can't tell right now),
-- plus when the cooldown ends if the timer is readable.
local function ReadReady()
    if not spellID then return nil end
    local info = GetCooldown(spellID)
    if not info then return nil end

    local start, duration = Plain(info.startTime), Plain(info.duration)
    if type(start) == "number" and type(duration) == "number" then
        if start <= 0 or duration <= GCD_MAX then return true end   -- ready, or just the global cooldown
        return false, start + duration
    end

    local active = Plain(info.isActive)                          -- never secret, even in combat
    if type(active) ~= "boolean" then return nil end
    if not active or gcdOnly then return true end
    return false
end

-- isOnGCD is only reliable while a cooldown update is being handled, so it's noted here
-- and used by ReadReady until the next update.
local function NoteGlobalCooldown()
    gcdOnly = false
    local info = spellID and GetCooldown(spellID)
    if info and Plain(info.isActive) == true and Plain(info.isOnGCD) == true then
        gcdOnly = true
    end
end

local function InCombat()
    return inCombat or IsTrue(InCombatLockdown) or IsTrue(UnitAffectingCombat, "player")
end

----------------------------------------------------------------------------------------
-- What to show
----------------------------------------------------------------------------------------

-- Returns nil (show nothing) or one of the STYLES keys.
local function ComputeState(now, ready, combat)
    if testUntil then
        if now < testUntil then return "test" end
        testUntil = nil
    end
    if not db.locked then return "unlocked" end
    if not db.enabled or not spellID then return nil end
    if IsTrue(UnitIsDeadOrGhost, "player") or IsTrue(UnitOnTaxi, "player") then return nil end
    if not combat and not db.showOutOfCombat then return nil end

    if ready == true then return "ready" end
    if ready == nil and combat then return "tracking" end    -- can't tell: show the cooldown swipe
    return nil
end

local function ClearSwipe()
    local cd = frame.cooldown
    if cd.Clear then cd:Clear() else cd:SetCooldown(0, 0) end
end

local function Refresh()
    if not frame or not db then return end
    local now = GetTime()
    local combat = InCombat()

    local ok, ready = pcall(ReadReady)
    if not ok then lastError, ready = tostring(ready), nil end

    local state = ComputeState(now, ready, combat)

    if state == "ready" and combat and wasReady == false and db.sound then
        PlayAlert()                                  -- came off cooldown mid-fight
    end
    if ready ~= nil then wasReady = ready end

    if not state then
        if frame:IsShown() then
            frame.pulse:Stop()
            ClearSwipe()
            frame:EnableMouse(false)
            frame:Hide()
        end
        shownState = nil
        return
    end

    if state ~= shownState then
        shownState = state
        local style = STYLES[state]
        frame.border:SetColorTexture(style.r, style.g, style.b, 1)
        frame.label:SetText(style.label)
        frame.label:SetTextColor(style.r, style.g, style.b)
        frame.icon:SetTexture(spellIcon or DEFAULT_ICON)
        frame:EnableMouse(state == "unlocked")
        if style.pulse then
            if not frame.pulse:IsPlaying() then frame.pulse:Play() end
        else
            frame.pulse:Stop()
        end
        ClearSwipe()
        swipeStale = true
        frame:Show()
    end

    if state == "tracking" and swipeStale then
        swipeStale = false
        local info = GetCooldown(spellID)
        if info then
            -- the timer may be secret here; cooldown frames accept secret values
            local set = pcall(function() frame.cooldown:SetCooldown(info.startTime, info.duration) end)
            if not set then lastError = "couldn't show the cooldown swipe" end
        end
    end
end

----------------------------------------------------------------------------------------
-- The icon
----------------------------------------------------------------------------------------

local function CreateIcon()
    local f = CreateFrame("Frame", "BerserkingReminderIcon", UIParent)
    f:SetSize(ICON_SIZE, ICON_SIZE)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    if f.SetDontSavePosition then f:SetDontSavePosition(true) end
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:Hide()

    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetAllPoints()

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 3, -3)
    f.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local ok, cd = pcall(CreateFrame, "Cooldown", nil, f, "CooldownFrameTemplate")
    if not ok or not cd then cd = CreateFrame("Cooldown", nil, f) end
    cd:SetAllPoints(f.icon)
    f.cooldown = cd

    f.label = f:CreateFontString(nil, "OVERLAY")
    f.label:SetFont(FONT, 12, "OUTLINE")
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -4)

    f.pulse = f:CreateAnimationGroup()
    f.pulse:SetLooping("BOUNCE")
    local fade = f.pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.5)
    fade:SetDuration(0.7)
    fade:SetSmoothing("IN_OUT")

    f:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        db.point = { point, relativePoint, x, y }
    end)
    return f
end

local function ApplyLayout()
    if not frame then return end
    local p = db.point
    frame:ClearAllPoints()
    frame:SetPoint(p[1] or "CENTER", UIParent, p[2] or "CENTER", tonumber(p[3]) or 0, tonumber(p[4]) or 0)
    frame:SetScale(db.scale)
end

----------------------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------------------

local function ShowHelp()
    Print("commands (/berserk or /bzr):")
    local lines = {
        "  unlock / lock - unlock to drag the icon, lock when done",
        "  test - preview the reminder for 10 seconds",
        string.format("  scale <0.5-3> - icon size (now %.2f)", db.scale),
        "  always - also show it out of combat when it's ready (now " .. OnOff(db.showOutOfCombat) .. ")",
        "  sound - ping when it comes off cooldown mid-fight (now " .. OnOff(db.sound) .. ")",
        "  on / off - turn the reminder on or off (now " .. OnOff(db.enabled) .. ")",
        "  status - what the addon sees right now",
        "  reset - restore all defaults",
    }
    for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage(line) end
end

local function PrintStatus()
    if not spellID then
        Print("this character doesn't have Berserking (the Troll racial), so the reminder stays off")
        return
    end
    local ok, ready, endsAt = pcall(ReadReady)
    if not ok then ready = nil end
    local name = (spellName or "Berserking") .. " (spell " .. spellID .. ")"
    if ready == true then
        Print(name .. ": ready")
    elseif ready == false and endsAt then
        Print(name .. ": " .. FormatTime(endsAt - GetTime()) .. " left")
    elseif ready == false then
        Print(name .. ": on cooldown (the timer is hidden from addons in combat)")
    else
        Print(name .. ": can't read the cooldown right now")
    end
    if not db.showOutOfCombat and not InCombat() then
        Print("it only shows in combat - /berserk always shows it out of combat too")
    end
    if lastError then Print("last error: " .. lastError) end
end

local function HandleSlash(msg)
    if not db or not frame then return end
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd, rest = string.lower(cmd or ""), rest or ""

    if cmd == "" or cmd == "help" then
        ShowHelp()
    elseif cmd == "unlock" or cmd == "move" then
        db.locked = false
        Print("unlocked - drag the icon where you want it, then type /berserk lock")
    elseif cmd == "lock" then
        db.locked = true
        Print("locked")
    elseif cmd == "test" then
        testUntil = GetTime() + TEST_SECONDS
        Print("showing a 10 second preview")
    elseif cmd == "scale" then
        local n = tonumber(rest)
        if n and n >= 0.5 and n <= 3 then
            db.scale = n
            ApplyLayout()
            Print(string.format("scale set to %.2f", n))
        else
            Print("usage: /berserk scale <0.5 - 3>")
        end
    elseif cmd == "always" then
        db.showOutOfCombat = not db.showOutOfCombat
        Print("show out of combat too: " .. OnOff(db.showOutOfCombat))
    elseif cmd == "sound" then
        db.sound = not db.sound
        Print("ping when it comes off cooldown mid-fight: " .. OnOff(db.sound))
        if db.sound then PlayAlert() end
    elseif cmd == "on" or cmd == "enable" then
        db.enabled = true
        Print("enabled")
    elseif cmd == "off" or cmd == "disable" then
        db.enabled = false
        Print("disabled - /berserk on turns it back on")
    elseif cmd == "status" then
        PrintStatus()
    elseif cmd == "reset" then
        BerserkingReminderDB = CopyDefaults(DEFAULTS, {})
        db = BerserkingReminderDB
        ApplyLayout()
        Print("settings reset")
    else
        Print("unknown command \"" .. cmd .. "\"")
        ShowHelp()
    end

    Refresh()
end

SLASH_BERSERKINGREMINDER1 = "/berserk"
SLASH_BERSERKINGREMINDER2 = "/bzr"
SlashCmdList.BERSERKINGREMINDER = HandleSlash

----------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------

local RUNTIME_EVENTS = {
    "SPELLS_CHANGED", "SPELL_UPDATE_COOLDOWN", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
}

local function Sanitize()
    if type(db.point) ~= "table" then db.point = CopyDefaults(DEFAULTS.point, {}) end
    if type(db.scale) ~= "number" or db.scale < 0.5 or db.scale > 3 then db.scale = 1 end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
        BerserkingReminderDB = CopyDefaults(DEFAULTS, BerserkingReminderDB or {})
        db = BerserkingReminderDB
        Sanitize()
        frame = CreateIcon()
        ApplyLayout()

    elseif event == "PLAYER_LOGIN" then
        UpdateSpell()
        for _, name in ipairs(RUNTIME_EVENTS) do
            pcall(self.RegisterEvent, self, name)
        end
        C_Timer.NewTicker(TICK, Refresh)
        Refresh()

    elseif event == "SPELLS_CHANGED" then
        UpdateSpell()
        Refresh()

    elseif event == "SPELL_UPDATE_COOLDOWN" then
        NoteGlobalCooldown()
        swipeStale = true
        Refresh()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        Refresh()

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        Refresh()

    else
        Refresh()
    end
end)
