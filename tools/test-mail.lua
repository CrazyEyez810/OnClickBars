-- Loads OneClickMail with stubs and checks which bag items each rule picks.
-- Usage: luajit tools/test-mail.lua OneClickMail/OneClickMail.lua
local items = {
  { id = 2447, name = "Peacebloom", classID = 7 },
  { id = 2318, name = "Light Leather", classID = 7 },
  { id = 783, name = "Light Hide", classID = 7 },
  { id = 2589, name = "Linen Cloth", classID = 7 },
  { id = 2996, name = "Bolt of Linen Cloth", classID = 7 },
  { id = 2770, name = "Copper Ore", classID = 7 },
  { id = 2840, name = "Copper Bar", classID = 7 },
  { id = 2835, name = "Rough Stone", classID = 7 },
  { id = 2862, name = "Rough Sharpening Stone", classID = 0 },
  { id = 10940, name = "Strange Dust", classID = 7 },
  { id = 7067, name = "Elemental Earth", classID = 7 },
  { id = 769, name = "Chunk of Boar Meat", classID = 7 },
  { id = 2681, name = "Roasted Boar Meat", classID = 0 },
  { id = 6291, name = "Raw Brilliant Smallfish", classID = 0 },
  { id = 1, name = "Green Belt", classID = 4, quality = 2 },
  { id = 2, name = "Bound Green Belt", classID = 4, quality = 2, bound = true },
  { id = 3, name = "White Shirt", classID = 4, quality = 1 },
  { id = 6948, name = "Hearthstone", classID = 15 },
  { id = 4, name = "Quest Thing", classID = 12 },
}
local byId = {} for _, it in ipairs(items) do byId[it.id] = it end
C_Item = { GetItemInfoInstant = function(id) local it = byId[id] return id, nil, nil, nil, 134400, it.classID end }
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and #items or 0 end,
  GetContainerItemInfo = function(bag, slot) local it = items[slot] if not it then return nil end
    return { itemID = it.id, stackCount = 1, isBound = it.bound, quality = it.quality or 1, hyperlink = "|cff|Hitem:"..it.id.."|h[" .. it.name .. "]|h|r", isLocked = false } end,
}
local captured
function CreateFrame() return setmetatable({}, { __index = function(t, k) if k == "SetScript" then return function(_, ev, fn) captured = fn end end return function() end end }) end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
SlashCmdList = {}
UnitName = function() return "Me" end
GetRealmName = function() return "Realm" end
UnitClass = function() return "Shaman", "SHAMAN" end
UnitFactionGroup = function() return "Horde" end
UnitLevel = function() return 10 end
time = os.time
strlower, strtrim = string.lower, function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
hooksecurefunc = function() end
-- Expose the local matcher by loading the file with a debug hook on the upvalue.
local chunk = assert(loadfile(arg[1]))
chunk("OneClickMail")
captured(nil, "ADDON_LOADED", "OneClickMail")
-- Find MatchingItems through the debug library.
local function upvalue(fn, name)
  local i = 1
  while true do local n, v = debug.getupvalue(fn, i) if not n then return end if n == name then return v end i = i + 1 end
end
local SlashFn = SlashCmdList.ONECLICKMAIL
local DB = OneClickMailDB
local OnEvent = captured
-- MatchingItems is reachable from StartAuto -> MatchingItems; walk upvalues.
local StartAuto = upvalue(OnEvent, "StartAuto")
local MatchingItems = upvalue(StartAuto, "MatchingItems")
local function names(rules)
  local tab = { rules = rules, custom = {} }
  local out = {}
  for _, it in ipairs(MatchingItems(tab)) do out[#out + 1] = it.name end
  return table.concat(out, ", ")
end
for _, key in ipairs({ "herbs", "leather", "cloth", "mining", "enchanting", "cooking", "greens" }) do
  print(key .. ": " .. names({ [key] = true }))
end
local all = { herbs = true, leather = true, cloth = true, mining = true, gems = true, enchanting = true, cooking = true, greens = true }
print("never sent with every rule on: " .. (names(all):find("Hearthstone") and "HEARTHSTONE SENT" or "") .. (names(all):find("Quest Thing") and "QUEST SENT" or "") .. (names(all):find("Bound") and "BOUND SENT" or "") .. "ok")
