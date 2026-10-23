-- OneClickXP
-- An on-screen XP panel: current and rested XP, XP and kills to level, and
-- XP per hour with time to level and time to max level for this session,
-- this level and all time played. Click STATS to collapse it to one line.
-- Rates: session = XP since login; level = XP into this level over time
-- played this level; total = all XP earned over total time played.

local ADDON = ...

local DB, CHAR

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickXP:|r " .. msg)
end

-- Settings from OneClickBars 1.6, where this panel used to live, are
-- carried over the first time.
local function LoadSettings()
    if OneClickXPDB == nil then
        OneClickXPDB = {}
        local old = _G.OneClickBarsDB
        if type(old) == "table" then
            OneClickXPDB.pos = old.xpPos
            OneClickXPDB.collapsed = old.xpCollapsed
            OneClickXPDB.enabled = old.xpTracker
            if old.xpScale then
                OneClickXPDB.scale = old.xpScaleReduced and old.xpScale or old.xpScale * 0.75
            end
        end
    end
    DB = OneClickXPDB
    if OneClickXPChar == nil then
        OneClickXPChar = {}
        local old = _G.OneClickBarsChar
        if type(old) == "table" then OneClickXPChar.lastKillXP = old.lastKillXP end
    end
    CHAR = OneClickXPChar
end


-- XP needed to go from each level to the next (Classic values, which
-- Forever keeps; 4,084,700 to reach 60).
local XP_TABLE = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
    95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
    153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
}

local LABEL, VALUE, EXTRA = "|cffd8d8d8", "|cffffffff", "|cffffd100"

local xpFrame
local xpState = {
    sessionStart = nil, sessionGained = 0,
    lastXP = nil, lastMax = nil, lastLevel = nil,
    killXP = nil,
    playedTotal = nil, playedLevel = nil, playedAt = nil,
}
local quietPlayed = false

-- Ask the server for time played without printing it in chat.
local function RequestPlayedQuietly()
    quietPlayed = true
    C_Timer.After(3, function() quietPlayed = false end)
    RequestTimePlayed()
end

if ChatFrameUtil and ChatFrameUtil.DisplayTimePlayed then
    local original = ChatFrameUtil.DisplayTimePlayed
    ChatFrameUtil.DisplayTimePlayed = function(...)
        if quietPlayed then return end
        return original(...)
    end
elseif _G.ChatFrame_DisplayTimePlayed then
    local original = _G.ChatFrame_DisplayTimePlayed
    _G.ChatFrame_DisplayTimePlayed = function(...)
        if quietPlayed then return end
        return original(...)
    end
end

-- "%s dies, you gain %d experience." turned into a Lua pattern.
local KILL_PATTERN
do
    local fmt = _G.COMBATLOG_XPGAIN_FIRSTPERSON
    if fmt then
        local pattern = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
        pattern = pattern:gsub("%%s", ".+"):gsub("%%d", "(%%d+)")
        KILL_PATTERN = pattern
    end
end

-- Kills needed for the XP left. While rested, a kill gives double XP and
-- uses up rested XP equal to its base XP; after that it gives base XP.
local function KillsToLevel(left, base)
    if not base or base <= 0 then return nil end
    local kills = 0
    local rested = GetXPExhaustion() or 0
    if rested > 0 then
        local restedKills = math.ceil(rested / base)
        if restedKills * 2 * base >= left then
            return math.ceil(left / (2 * base))
        end
        left = left - restedKills * 2 * base
        kills = restedKills
    end
    return kills + math.ceil(left / base)
end

local function MaxLevel()
    return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

local function XPToMaxLevel()
    local level = UnitLevel("player")
    local left = UnitXPMax("player") - UnitXP("player")
    for l = level + 1, MaxLevel() - 1 do left = left + (XP_TABLE[l] or 0) end
    return left
end

local function TotalEarned()
    local total = UnitXP("player")
    for l = 1, UnitLevel("player") - 1 do total = total + (XP_TABLE[l] or 0) end
    return total
end

local function Played()
    if not xpState.playedAt then return nil, nil end
    local since = GetTime() - xpState.playedAt
    return xpState.playedTotal + since, xpState.playedLevel + since
end

local function FormatTime(xpLeft, perHour)
    if not perHour or perHour <= 0 then return "--" end
    local hours = xpLeft / perHour
    if hours < 1 then return ("%dmin"):format(math.max(1, math.floor(hours * 60))) end
    if hours < 24 then return ("%.1fh"):format(hours) end
    return ("%.1fdays"):format(hours / 24)
end

local function Rates()
    local session
    if xpState.sessionStart and xpState.sessionGained > 0 then
        local hours = (GetTime() - xpState.sessionStart) / 3600
        if hours > 0 then session = xpState.sessionGained / hours end
    end
    local total, level = Played()
    local levelRate = level and level > 0 and UnitXP("player") / (level / 3600) or nil
    local totalRate = total and total > 0 and TotalEarned() / (total / 3600) or nil
    return session, levelRate, totalRate
end

local ORANGE = "|cffff9933"

-- The stats as lines of colored text, laid out like XPTracker.
local function XPLines()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    if max <= 0 then return nil end
    local left = max - cur
    local toMax = XPToMaxLevel()
    local rested = GetXPExhaustion() or 0
    local session, levelRate, totalRate = Rates()
    local lines = {
        ("%sCurrent XP: %s%d %s( %d rested)"):format(LABEL, VALUE, cur, EXTRA, rested),
        ("%sXP to level: %s%d %s( %d%% )"):format(LABEL, VALUE, left, EXTRA, 100 - math.floor(cur / max * 100)),
    }
    if xpState.killXP and xpState.killXP > 0 then
        lines[#lines + 1] = ("%sKills to level: %s~%d %s( %d per kill)"):format(LABEL, VALUE,
            KillsToLevel(left, xpState.killXP), EXTRA, xpState.killXP)
    else
        lines[#lines + 1] = ("%sKills to level: %s--"):format(LABEL, VALUE)
    end

    local function Block(name, rate)
        lines[#lines + 1] = " "
        if rate then
            lines[#lines + 1] = ("%s%s: %s%d %s/ h %s( %.2f%% )"):format(LABEL, name, VALUE,
                math.floor(rate + 0.5), LABEL, EXTRA, rate / max * 100)
        else
            lines[#lines + 1] = ("%s%s: %s--"):format(LABEL, name, VALUE)
        end
        lines[#lines + 1] = ("%sTime to level: %s%s"):format(LABEL, VALUE, FormatTime(left, rate))
        lines[#lines + 1] = ("%sTime to level %d: %s%s"):format(LABEL, MaxLevel(), VALUE, FormatTime(toMax, rate))
    end
    Block("Session XP", session)
    Block("Level XP", levelRate)
    Block("Total XP", totalRate)
    return lines
end

-- Short summary for the collapsed header: level %, kills and time to level.
local function XPSummary()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    if max <= 0 then return "" end
    local left = max - cur
    local parts = { ("%d%%"):format(math.floor(cur / max * 100)) }
    if xpState.killXP and xpState.killXP > 0 then
        parts[#parts + 1] = ("~%d kills"):format(KillsToLevel(left, xpState.killXP))
    end
    local session, levelRate = Rates()
    local rate = session or levelRate
    if rate then parts[#parts + 1] = FormatTime(left, rate) end
    return table.concat(parts, "   ")
end

local function UpdateXPLine()
    if not xpFrame then return end
    local atMax = UnitLevel("player") >= MaxLevel()
    xpFrame:SetShown(DB.enabled ~= false and not atMax)
    if atMax then return end
    local collapsed = DB.collapsed
    if collapsed then
        xpFrame.header:SetText(ORANGE .. "STATS  " .. VALUE .. XPSummary() .. "  " .. LABEL .. "[+]")
        xpFrame.text:Hide()
        xpFrame:SetSize(xpFrame.header:GetStringWidth() + 24, xpFrame.header:GetStringHeight() + 16)
    else
        local lines = XPLines()
        if not lines then return end
        xpFrame.header:SetText(ORANGE .. "STATS  " .. LABEL .. "[-]")
        xpFrame.text:SetText(table.concat(lines, "\n"))
        xpFrame.text:Show()
        local width = math.max(xpFrame.header:GetStringWidth(), xpFrame.text:GetStringWidth())
        xpFrame:SetSize(width + 24, xpFrame.header:GetStringHeight() + xpFrame.text:GetStringHeight() + 22)
    end
    xpFrame.toggle:SetSize(xpFrame.header:GetStringWidth(), xpFrame.header:GetStringHeight() + 4)
end

local function CreateXPFrame()
    if xpFrame then return end
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    xpFrame = CreateFrame("Frame", "OneClickBarsXP", UIParent, template)
    xpFrame:SetSize(220, 240)
    xpFrame:SetClampedToScreen(true)
    xpFrame:SetMovable(true)
    xpFrame:EnableMouse(true)
    xpFrame:RegisterForDrag("LeftButton")
    if xpFrame.SetBackdrop then
        xpFrame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        xpFrame:SetBackdropColor(0, 0, 0, 0.75)
        xpFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    xpFrame.header = xpFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    xpFrame.header:SetPoint("TOPLEFT", 12, -8)
    xpFrame.header:SetJustifyH("LEFT")
    xpFrame.text = xpFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    xpFrame.text:SetPoint("TOPLEFT", xpFrame.header, "BOTTOMLEFT", 0, -6)
    xpFrame.text:SetJustifyH("LEFT")
    xpFrame.text:SetSpacing(2)

    -- Clicking the STATS line collapses or opens the panel; dragging it
    -- still moves the panel.
    xpFrame.toggle = CreateFrame("Button", nil, xpFrame)
    xpFrame.toggle:SetPoint("TOPLEFT", xpFrame.header, "TOPLEFT", 0, 2)
    xpFrame.toggle:RegisterForClicks("LeftButtonUp")
    xpFrame.toggle:RegisterForDrag("LeftButton")
    xpFrame.toggle:SetScript("OnClick", function()
        DB.collapsed = not DB.collapsed
        UpdateXPLine()
    end)
    xpFrame.toggle:SetScript("OnDragStart", function() xpFrame:StartMoving() end)
    xpFrame.toggle:SetScript("OnDragStop", function() xpFrame:GetScript("OnDragStop")(xpFrame) end)

    local pos = DB.pos
    if pos then
        xpFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        xpFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -20)
    end
    xpFrame:SetScale(DB.scale or 0.9)
    xpFrame:SetScript("OnDragStart", xpFrame.StartMoving)
    xpFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        DB.pos = { point, relPoint, x, y }
    end)
    local elapsed = 0
    xpFrame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            UpdateXPLine()
        end
    end)
end

local xpEvents = CreateFrame("Frame")
xpEvents:RegisterEvent("ADDON_LOADED")
xpEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
xpEvents:RegisterEvent("PLAYER_XP_UPDATE")
xpEvents:RegisterEvent("PLAYER_LEVEL_UP")
xpEvents:RegisterEvent("TIME_PLAYED_MSG")
xpEvents:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
xpEvents:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then LoadSettings() end
        return
    end
    if not DB then return end
    if event == "PLAYER_ENTERING_WORLD" then
        CreateXPFrame()
        if not xpState.sessionStart then
            xpState.sessionStart = GetTime()
            xpState.lastXP, xpState.lastMax = UnitXP("player"), UnitXPMax("player")
            xpState.lastLevel = UnitLevel("player")
            xpState.killXP = CHAR.lastKillXP
            C_Timer.After(2, RequestPlayedQuietly)
        end
        UpdateXPLine()
    elseif event == "PLAYER_XP_UPDATE" then
        local cur, max, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
        if xpState.lastXP then
            local gained = level == xpState.lastLevel and cur - xpState.lastXP
                or (xpState.lastMax - xpState.lastXP) + cur
            if gained > 0 then xpState.sessionGained = xpState.sessionGained + gained end
        end
        xpState.lastXP, xpState.lastMax, xpState.lastLevel = cur, max, level
        UpdateXPLine()
    elseif event == "PLAYER_LEVEL_UP" then
        -- Time played this level starts over.
        local total = Played()
        if total then
            xpState.playedTotal, xpState.playedLevel, xpState.playedAt = total, 0, GetTime()
        end
        UpdateXPLine()
    elseif event == "TIME_PLAYED_MSG" then
        xpState.playedTotal, xpState.playedLevel, xpState.playedAt = arg1, arg2, GetTime()
        UpdateXPLine()
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        local amount = KILL_PATTERN and tonumber(arg1:match(KILL_PATTERN) or "")
        -- "(+30 exp Rested bonus)": the base XP is the total minus the bonus.
        local extra = arg1:match("%((.-)%)")
        local bonus = extra and extra:lower():find("rest") and tonumber(extra:match("%+(%d+)"))
        if amount and bonus then amount = amount - bonus end
        if amount and amount > 0 then
            xpState.killXP = amount
            CHAR.lastKillXP = amount
            UpdateXPLine()
        end
    end
end)

-- Slash command -----------------------------------------------------------

SLASH_ONECLICKXP1 = "/oxp"
SlashCmdList.ONECLICKXP = function(input)
    local cmd, arg = strsplit(" ", strlower(strtrim(input or "")), 2)
    if cmd == "scale" and tonumber(arg or "") then
        DB.scale = math.max(0.5, math.min(3, tonumber(arg)))
        if xpFrame then xpFrame:SetScale(DB.scale) end
    elseif cmd == "" or cmd == "on" or cmd == "off" then
        if cmd == "" then DB.enabled = DB.enabled == false else DB.enabled = cmd == "on" end
        Print("XP panel: " .. (DB.enabled ~= false and "on" or "off"))
        UpdateXPLine()
    elseif cmd == "collapse" then
        DB.collapsed = not DB.collapsed
        UpdateXPLine()
    else
        Print("/oxp (show or hide), /oxp on|off, /oxp collapse, /oxp scale 1.2")
    end
end
