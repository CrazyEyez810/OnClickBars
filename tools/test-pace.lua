-- Runs OneClickPace against a fake game to check its verdicts.
-- Usage: luajit tools/test-pace.lua OneClickPace/OneClickPace.lua

local file = arg[1]

-- Fake world -------------------------------------------------------------
local clock = 1000
local px, py = 0, 0
local quests = {}          -- { {id, title, objectives = { {have, need, type, text} } } }
local panelText, panelShown = "", false
local alerts = {}
local tickers = {}

function time() return clock end
function UnitPosition() return py, px, 0, 1 end
function GetNumQuestLogEntries() return #quests end
function GetQuestLogTitle(i)
    local q = quests[i]
    return q.title, 10, 0, false, false, false, 0, q.id
end
C_QuestLog = {
    GetQuestObjectives = function(id)
        for _, q in ipairs(quests) do
            if q.id == id then
                local out = {}
                for i, o in ipairs(q.objectives) do
                    out[i] = { numFulfilled = o.have, numRequired = o.need, type = o.type,
                        text = ("%s: %d/%d"):format(o.text, o.have, o.need), finished = o.have >= o.need }
                end
                return out
            end
        end
    end,
}
C_Timer = {
    After = function(_, fn) fn() end,
    NewTicker = function(_, fn) tickers[#tickers + 1] = fn end,
}
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) print("  chat: " .. msg) end }
RaidWarningFrame, ChatTypeInfo = {}, { RAID_WARNING = {} }
function RaidNotice_AddMessage(_, msg) alerts[#alerts + 1] = msg end
function strsplit(sep, s, n) local a, b = s:match("^(.-)" .. sep .. "(.*)$") if a then return a, b end return s end
strlower, strtrim = string.lower, function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
SlashCmdList = {}
UIParent = {}

local scripts = {}
local function Dummy(name)
    local obj = {}
    return setmetatable(obj, { __index = function(_, key)
        if key == "SetScript" then
            return function(self, event, fn) scripts[self] = scripts[self] or {} scripts[self][event] = fn end
        elseif key == "SetText" then
            return function(self, text) if rawget(self, "isBody") then panelText = text end end
        elseif key == "Show" then
            return function(self) if rawget(self, "isPanel") then panelShown = true end end
        elseif key == "Hide" then
            return function(self) if rawget(self, "isPanel") then panelShown = false end end
        elseif key == "GetStringWidth" or key == "GetStringHeight" then
            return function() return 100 end
        elseif key == "CreateFontString" then
            return function(self)
                local fs = Dummy()
                if rawget(self, "isPanel") then
                    local count = (rawget(self, "fontCount") or 0) + 1
                    rawset(self, "fontCount", count)
                    if count == 2 then rawset(fs, "isBody", true) end
                end
                return fs
            end
        elseif key == "CreateTexture" then
            return function() return Dummy() end
        end
        return function() end
    end })
end
local frames = {}
function CreateFrame(kind, name)
    local f = Dummy()
    if name == "OneClickPaceFrame" then rawset(f, "isPanel", true) end
    frames[#frames + 1] = f
    return f
end

-- Load the addon ---------------------------------------------------------
local chunk = assert(loadfile(file))
chunk("OneClickPace")
local eventFrame = frames[1]
local OnEvent = scripts[eventFrame].OnEvent
local function Fire(event, ...) OnEvent(eventFrame, event, ...) end
local function Tick() for _, fn in ipairs(tickers) do fn() end end
local function Wait(seconds) clock = clock + seconds Tick() end
local function Progress(questIndex, n)
    local o = quests[questIndex].objectives[1]
    o.have = o.have + (n or 1)
    Fire("QUEST_LOG_UPDATE")
end
local function Kill() Fire("CHAT_MSG_COMBAT_XP_GAIN", "Kolkar Bloodcharger dies, you gain 120 experience.") end
local function Verdict()
    if not panelShown then return "(panel hidden)" end
    return panelText:match("[^\n]*$"):gsub("|c%x%x%x%x%x%x%x%x", "")
end

Fire("ADDON_LOADED", "OneClickPace")
Fire("PLAYER_ENTERING_WORLD")

local failures = 0
local function Expect(label, want)
    local got = Verdict()
    local ok = got:find(want, 1, true) ~= nil
    if not ok then failures = failures + 1 end
    print(("%s %s -> %s"):format(ok and "PASS" or "FAIL", label, got))
end

-- Scenario 1: a camp that goes contested ---------------------------------
quests = { { id = 101, title = "Kolkar Booty", objectives = { { have = 0, need = 8, type = "item", text = "Kolkar Booty Key" } } } }
Fire("QUEST_LOG_UPDATE")
px, py = 1000, 1000
for _ = 1, 3 do Wait(45) Kill() Progress(1) end
Expect("camp, steady progress", "Keep going")
Wait(120)
Expect("camp, 2 min without progress", "Keep going")
Wait(120)
Expect("camp, 4 min without progress or kills", "Contested")
print(("  alerts so far: %d"):format(#alerts))

-- Scenario 2: same wait, but killing without drops -----------------------
quests[1].objectives[1].have = 0
SlashCmdList.ONECLICKPACE("reset")
Fire("QUEST_LOG_UPDATE")
for _ = 1, 2 do Wait(40) Kill() Progress(1) end
for _ = 1, 6 do Wait(40) Kill() end
Expect("camp, killing with no drops", "Unlucky")

-- Scenario 3: walking away ends the attempt -------------------------------
px, py = 1400, 1000
Wait(5)
Expect("walked 400 yards away", "(panel hidden)")

-- Scenario 4: Raptor Horns on the way between hubs ------------------------
SlashCmdList.ONECLICKPACE("reset")
quests[2] = { id = 202, title = "Raptor Horns", objectives = { { have = 0, need = 5, type = "item", text = "Intact Raptor Horn" } } }
Fire("QUEST_LOG_UPDATE")
local route = { { 0, 0 }, { 500, 200 }, { 1100, 300 }, { 1600, 800 } }
for i, p in ipairs(route) do
    px, py = p[1], p[2]
    Wait(300)
    Kill()
    Progress(2)
    if i >= 3 then Expect(("raptor horn %d, %d yards from the last"):format(i, 600), "(panel hidden)") end
end
Wait(400)
Expect("standing still after roaming horns", "(panel hidden)")

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
