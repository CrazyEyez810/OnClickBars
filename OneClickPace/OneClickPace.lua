-- OneClickPace
-- Tells you when a quest spot is contested. While you stand in one area
-- working a quest, it times your progress there and says whether to keep
-- going, whether you are just unlucky with drops, or whether other players
-- are taking the mobs and you should leave and come back later.
--
-- It only judges a quest while its progress happens in one small area.
-- Quests you finish on the way between hubs (progress spread along a route)
-- are marked "on the way" and never judged. It reads only the quest log,
-- your position and the XP message for kills, and takes no actions.

local ADDON = ...

-- Distances in yards (UnitPosition is in yards).
local CAMP_RADIUS = 110   -- progress within this distance counts as the same spot
local LEAVE_RADIUS = 160  -- walking this far from the spot ends the attempt
local ROAM_GAP = 220      -- progress this far from the previous progress is a new spot

-- Verdict thresholds in seconds.
local MIN_WAIT = 180       -- never call a spot contested before 3 minutes without progress
local WAIT_FACTOR = 3      -- or 3 times your usual gap between progress, if longer
local SLOW_ETA = 15 * 60   -- more than 15 minutes left at this pace is slow
local UNLUCKY_KILLS = 4    -- this many kills without a drop is bad luck, not contention

local DB, CHAR
local frame
local snapshot = {}        -- questID -> { title, objectives = { {have, need, type, text} } }
local scanQueued = false
local alerted = {}         -- questID -> true once the contested alert played this attempt

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickPace:|r " .. msg)
end

local function Now()
    return time()
end

local function Position()
    local y, x, _, instance = UnitPosition("player")
    if not x or not y then return nil end
    return x, y, instance
end

local function Distance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    if seconds < 60 then return seconds .. "s" end
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 60 then return minutes .. "m" end
    return ("%dh %dm"):format(math.floor(minutes / 60), minutes % 60)
end

-- Quest log --------------------------------------------------------------

-- Quest IDs and titles in the log. Forever has the C_QuestLog list; Classic
-- Era has the older GetQuestLogTitle.
local function QuestList()
    local list = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID and info.questID > 0 then
                list[#list + 1] = { id = info.questID, title = info.title }
            end
        end
    elseif GetNumQuestLogEntries then
        for i = 1, GetNumQuestLogEntries() do
            local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and questID and questID > 0 then
                list[#list + 1] = { id = questID, title = title }
            end
        end
    end
    return list
end

local function ReadObjectives(questID)
    local objectives = {}
    local raw = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
    for i, o in ipairs(raw or {}) do
        local have, need = o.numFulfilled, o.numRequired
        if (not have or not need) and o.text then
            local a, b = o.text:match("(%d+)%s*/%s*(%d+)")
            have, need = tonumber(a), tonumber(b)
        end
        objectives[i] = { have = have or 0, need = need or 0, type = o.type, text = o.text or "" }
    end
    return objectives
end

local function Remaining(quest)
    local left = 0
    for _, o in ipairs(quest.objectives) do
        if o.need > o.have then left = left + (o.need - o.have) end
    end
    return left
end

-- Attempts ---------------------------------------------------------------

-- One attempt = progress on one quest in one spot. Kept per character so a
-- /reload in the middle of a camp keeps the timer.
local function Attempts()
    CHAR.attempts = CHAR.attempts or {}
    return CHAR.attempts
end

local function EndAttempt(questID)
    Attempts()[questID] = nil
    alerted[questID] = nil
end

-- A quest whose progress keeps landing far from the last progress is done
-- on the way between places, so it is never judged. /pace roam and
-- /pace camp override this per quest.
local function IsRoaming(questID)
    local manual = CHAR.manualRoaming and CHAR.manualRoaming[questID]
    if manual ~= nil then return manual end
    local gaps = CHAR.gaps and CHAR.gaps[questID]
    if not gaps or gaps.total < 2 then return false end
    return gaps.far / gaps.total >= 0.5
end

local function NoteGap(questID, far)
    CHAR.gaps = CHAR.gaps or {}
    local gaps = CHAR.gaps[questID] or { total = 0, far = 0 }
    gaps.total = gaps.total + 1
    if far then gaps.far = gaps.far + 1 end
    CHAR.gaps[questID] = gaps
end

local function OnProgress(questID, amount)
    local x, y, instance = Position()
    if not x then return end
    local now = Now()
    CHAR.lastTick = CHAR.lastTick or {}
    local last = CHAR.lastTick[questID]
    if last and last.instance == instance then
        NoteGap(questID, Distance(x, y, last.x, last.y) > ROAM_GAP)
    end
    CHAR.lastTick[questID] = { x = x, y = y, instance = instance, t = now }

    local attempts = Attempts()
    local a = attempts[questID]
    if a and (a.instance ~= instance or Distance(x, y, a.x, a.y) > CAMP_RADIUS) then
        EndAttempt(questID)
        a = nil
    end
    if not a then
        a = { x = x, y = y, instance = instance, start = now, ticks = {}, kills = 0 }
        attempts[questID] = a
    end
    for _ = 1, amount do a.ticks[#a.ticks + 1] = now end
    a.kills = 0
    -- Keep the spot centered on recent progress.
    a.x = (a.x * 2 + x) / 3
    a.y = (a.y * 2 + y) / 3
end

-- Ends attempts you walked away from or that changed zone or instance.
local function PruneAttempts()
    local x, y, instance = Position()
    for questID, a in pairs(Attempts()) do
        if not snapshot[questID] or not x or a.instance ~= instance
            or Distance(x, y, a.x, a.y) > LEAVE_RADIUS then
            EndAttempt(questID)
        end
    end
end

-- The attempt you are standing in: unfinished, not on the way, most recent
-- progress first.
local function ActiveAttempt()
    local best, bestID
    for questID, a in pairs(Attempts()) do
        local quest = snapshot[questID]
        if quest and Remaining(quest) > 0 and not IsRoaming(questID) and #a.ticks > 0 then
            if not best or a.ticks[#a.ticks] > best.ticks[#best.ticks] then
                best, bestID = a, questID
            end
        end
    end
    return best, bestID
end

-- Verdict ----------------------------------------------------------------

-- Returns verdict ("ok", "slow", "unlucky", "other", "contested"), the
-- seconds per progress, the estimated seconds left and the wait so far.
local function Judge(a, remaining, objectiveType, now)
    local ticks = a.ticks
    local last = ticks[#ticks]
    local waited = now - last
    local usual
    if #ticks >= 2 then
        usual = (last - ticks[1]) / (#ticks - 1)
    end
    local perTick = math.max(usual or 0, waited, 1)
    if usual and waited < usual then perTick = usual end
    local eta = remaining * perTick

    local limit = math.max(MIN_WAIT, WAIT_FACTOR * (usual or 60))
    if waited >= limit then
        if a.kills >= UNLUCKY_KILLS then
            -- Killing, but no progress: bad drop luck for items, the wrong
            -- mob for kill quests.
            return objectiveType == "monster" and "other" or "unlucky", perTick, eta, waited
        end
        return "contested", perTick, eta, waited
    end
    if eta > SLOW_ETA then return "slow", perTick, eta, waited end
    return "ok", perTick, eta, waited
end

local VERDICT = {
    ok = { "|cff33ff33", "Keep going" },
    slow = { "|cffffd100", "Slow here: think about coming back later" },
    unlucky = { "|cffffd100", "Unlucky drops: the mobs are here, keep killing" },
    other = { "|cffffd100", "Kills here aren't the quest mob" },
    contested = { "|cffff4040", "Contested: leave and come back later" },
}

local LABEL, VALUE, ORANGE = "|cffd8d8d8", "|cffffffff", "|cffff9933"

-- Panel ------------------------------------------------------------------

local function Lines()
    local a, questID = ActiveAttempt()
    if not a then return nil end
    local quest = snapshot[questID]
    local now = Now()
    local objectiveType
    for _, o in ipairs(quest.objectives) do
        if o.need > o.have then objectiveType = o.type break end
    end
    local remaining = Remaining(quest)
    local verdict, perTick, eta, waited = Judge(a, remaining, objectiveType, now)
    local color, text = VERDICT[verdict][1], VERDICT[verdict][2]

    local lines = { VALUE .. (quest.title or ("Quest " .. questID)) }
    for _, o in ipairs(quest.objectives) do
        if o.need > o.have then lines[#lines + 1] = LABEL .. "  " .. o.text end
    end
    lines[#lines + 1] = ("%sHere %s%s%s, last progress %s%s ago"):format(LABEL, VALUE,
        FormatDuration(now - a.start), LABEL, VALUE, FormatDuration(waited))
    if #a.ticks >= 2 then
        lines[#lines + 1] = ("%sPace %s1 per %s%s, done in %s~%s"):format(LABEL, VALUE,
            FormatDuration(perTick), LABEL, VALUE, FormatDuration(eta))
    end
    if a.kills > 0 then
        lines[#lines + 1] = ("%sKills since last progress: %s%d"):format(LABEL, VALUE, a.kills)
    end
    lines[#lines + 1] = color .. text
    return lines, verdict, questID, color, text
end

local function Alert(questID, title)
    if alerted[questID] or DB.alerts == false then return end
    alerted[questID] = true
    local msg = (title or "This quest") .. " is contested. Leave and come back later."
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
        RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
    end
    if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

local function Update()
    if not frame or not DB then return end
    PruneAttempts()
    local lines, verdict, questID, color, text = Lines()
    if not lines or DB.enabled == false then
        frame:Hide()
        return
    end
    if verdict == "contested" then Alert(questID, snapshot[questID].title) end
    frame:Show()
    if DB.collapsed then
        frame.header:SetText(ORANGE .. "PACE  " .. color .. text)
        frame.text:Hide()
        frame:SetSize(frame.header:GetStringWidth() + 46, math.max(frame.header:GetStringHeight() + 16, 30))
    else
        frame.header:SetText(ORANGE .. "PACE")
        frame.text:SetText(table.concat(lines, "\n"))
        frame.text:Show()
        local width = math.max(frame.header:GetStringWidth() + 22, frame.text:GetStringWidth())
        frame:SetSize(width + 24, frame.header:GetStringHeight() + frame.text:GetStringHeight() + 22)
    end
    frame.toggle:SetCollapsed(DB.collapsed)
end

local function CreatePanel()
    if frame then return end
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "OneClickPaceFrame", UIParent, template)
    frame:SetSize(220, 120)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.75)
        frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    frame.header = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.header:SetPoint("TOPLEFT", 12, -8)
    frame.header:SetJustifyH("LEFT")
    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.text:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -6)
    frame.text:SetJustifyH("LEFT")
    frame.text:SetSpacing(2)

    -- Gold window-style button: a dash collapses, a box opens.
    local GOLD = { 1, 0.82, 0, 1 }
    local toggle = CreateFrame("Button", nil, frame)
    toggle:SetSize(16, 16)
    toggle:SetPoint("TOPRIGHT", -6, -6)
    local bg = toggle:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0)
    for _, edge in ipairs({
        { "TOPLEFT", "TOPRIGHT", 0 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0 },
        { "TOPLEFT", "BOTTOMLEFT", 1 }, { "TOPRIGHT", "BOTTOMRIGHT", 1 },
    }) do
        local t = toggle:CreateTexture(nil, "BORDER")
        t:SetColorTexture(unpack(GOLD))
        t:SetPoint(edge[1])
        t:SetPoint(edge[2])
        if edge[3] == 1 then t:SetWidth(1) else t:SetHeight(1) end
    end
    local function Line(w, h, x, y)
        local t = toggle:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(unpack(GOLD))
        t:SetSize(w, h)
        t:SetPoint("CENTER", toggle, "CENTER", x, y)
        return t
    end
    local dash = Line(8, 2, 0, -3)
    local box = { Line(8, 1, 0, 4), Line(8, 1, 0, -4), Line(1, 8, -4, 0), Line(1, 8, 4, 0) }
    function toggle:SetCollapsed(collapsed)
        dash:SetShown(not collapsed)
        for _, t in ipairs(box) do t:SetShown(collapsed and true or false) end
    end
    toggle:SetScript("OnEnter", function() bg:SetColorTexture(1, 1, 1, 0.2) end)
    toggle:SetScript("OnLeave", function() bg:SetColorTexture(1, 1, 1, 0) end)
    toggle:SetScript("OnClick", function()
        DB.collapsed = not DB.collapsed
        Update()
    end)
    frame.toggle = toggle

    local pos = DB.pos
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
    frame:SetScale(DB.scale or 0.9)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        DB.pos = { point, relPoint, x, y }
    end)
    frame:Hide()
end

-- Scanning ---------------------------------------------------------------

local function Scan()
    scanQueued = false
    local fresh = {}
    for _, q in ipairs(QuestList()) do
        fresh[q.id] = { title = q.title, objectives = ReadObjectives(q.id) }
    end
    for questID, quest in pairs(fresh) do
        local old = snapshot[questID]
        if old then
            local gained = 0
            for i, o in ipairs(quest.objectives) do
                local before = old.objectives[i]
                if before and o.have > before.have then gained = gained + (o.have - before.have) end
            end
            if gained > 0 then OnProgress(questID, gained) end
        end
    end
    snapshot = fresh
    Update()
end

local function QueueScan()
    if scanQueued then return end
    scanQueued = true
    C_Timer.After(0.3, Scan)
end

-- Kills ------------------------------------------------------------------

-- "%s dies, you gain %d experience." as a pattern, to count kills.
local KILL_PATTERN
do
    local fmt = _G.COMBATLOG_XPGAIN_FIRSTPERSON
    if fmt then
        local pattern = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
        pattern = pattern:gsub("%%s", ".+")
        pattern = pattern:gsub("%%d", "%%d+")
        KILL_PATTERN = "^" .. pattern
    end
end

local function OnKill()
    local x, y, instance = Position()
    if not x then return end
    for _, a in pairs(Attempts()) do
        if a.instance == instance and Distance(x, y, a.x, a.y) <= LEAVE_RADIUS then
            a.kills = a.kills + 1
        end
    end
end

-- Events -----------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
pcall(events.RegisterEvent, events, "QUEST_REMOVED")
pcall(events.RegisterEvent, events, "QUEST_TURNED_IN")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        OneClickPaceDB = OneClickPaceDB or {}
        OneClickPaceChar = OneClickPaceChar or {}
        DB, CHAR = OneClickPaceDB, OneClickPaceChar
        return
    end
    if not DB then return end
    if event == "PLAYER_ENTERING_WORLD" then
        CreatePanel()
        QueueScan()
    elseif event == "QUEST_LOG_UPDATE" then
        QueueScan()
    elseif event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN" then
        if arg1 then
            EndAttempt(arg1)
            if CHAR.gaps then CHAR.gaps[arg1] = nil end
            if CHAR.lastTick then CHAR.lastTick[arg1] = nil end
            if CHAR.manualRoaming then CHAR.manualRoaming[arg1] = nil end
        end
        QueueScan()
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        if KILL_PATTERN and type(arg1) == "string" and arg1:match(KILL_PATTERN) then
            OnKill()
            Update()
        end
    end
end)

-- Refresh the timer every second while the panel is up.
C_Timer.NewTicker(1, function()
    if frame and DB then Update() end
end)

-- Slash command ----------------------------------------------------------

SLASH_ONECLICKPACE1 = "/pace"
SlashCmdList.ONECLICKPACE = function(input)
    local cmd, arg = strsplit(" ", strlower(strtrim(input or "")), 2)
    local _, questID = ActiveAttempt()
    if cmd == "" or cmd == "on" or cmd == "off" then
        if cmd == "" then DB.enabled = DB.enabled == false else DB.enabled = cmd == "on" end
        Print("Panel: " .. (DB.enabled ~= false and "on" or "off"))
        Update()
    elseif cmd == "collapse" then
        DB.collapsed = not DB.collapsed
        Update()
    elseif cmd == "scale" and tonumber(arg or "") then
        DB.scale = math.max(0.5, math.min(3, tonumber(arg)))
        if frame then frame:SetScale(DB.scale) end
    elseif cmd == "alerts" then
        DB.alerts = arg ~= "off"
        Print("Contested alert: " .. (DB.alerts and "on" or "off"))
    elseif cmd == "roam" or cmd == "camp" then
        -- Override for the quest on the panel: "roam" = done on the way,
        -- never judged; "camp" = always judged.
        if not questID then
            Print("No quest on the panel right now.")
            return
        end
        CHAR.manualRoaming = CHAR.manualRoaming or {}
        CHAR.manualRoaming[questID] = cmd == "roam"
        Print((snapshot[questID] and snapshot[questID].title or "Quest") .. ": "
            .. (cmd == "roam" and "marked as done on the way." or "always judged."))
        Update()
    elseif cmd == "reset" then
        CHAR.attempts, CHAR.gaps, CHAR.lastTick = {}, {}, {}
        alerted = {}
        Print("Cleared all quest timers.")
        Update()
    else
        Print("/pace (show or hide), /pace collapse, /pace scale 1.2, /pace alerts on|off, "
            .. "/pace roam (this quest is done on the way), /pace camp, /pace reset")
    end
end
