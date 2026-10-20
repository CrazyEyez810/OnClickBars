-- OneClickBars
-- Save the action bars of one character as the profile for its class, then
-- load that profile on any other character of the same class on the account.
-- After a load, spells you have not learned yet are placed in their saved
-- slot the moment you learn them.

local ADDON = ...

local MAX_SLOTS = 180

local PickupSpell = (C_Spell and C_Spell.PickupSpell) or _G.PickupSpell
local PickupItem = (C_Item and C_Item.PickupItem) or _G.PickupItem
local GetSpellName = (C_Spell and C_Spell.GetSpellName) or function(id)
    return (GetSpellInfo(id))
end

local MacroConsts = _G.Constants and _G.Constants.MacroConsts
local MAX_ACCOUNT_MACROS = _G.MAX_ACCOUNT_MACROS
    or (MacroConsts and MacroConsts.MAX_ACCOUNT_MACROS) or 120
local MAX_CHARACTER_MACROS = _G.MAX_CHARACTER_MACROS
    or (MacroConsts and MacroConsts.MAX_CHARACTER_MACROS) or 18

local DB, CHAR
local isNewCharacter = false
local pendingAfterCombat = nil
local ResetGuideLater -- set in the RestedXP section
local autoFillQueued = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickBars:|r " .. msg)
end

local function ClassKey()
    local className, classFile = UnitClass("player")
    return classFile, className
end

local function CharName()
    return UnitName("player") .. "-" .. (GetRealmName() or "")
end

-- Spellbook ---------------------------------------------------------------

-- Map of spell name to the highest known rank (spellbook lists ranks in
-- ascending order, so the last match wins).
local function BuildSpellBook()
    local book = {}

    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    if item and item.spellID and item.name and not item.isPassive
                        and item.itemType == Enum.SpellBookItemType.Spell then
                        book[item.name] = { id = item.spellID, index = i, bank = bank }
                    end
                end
            end
        end
    elseif GetNumSpellTabs then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            for i = offset + 1, offset + numSpells do
                local spellType, spellId = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
                local name = GetSpellBookItemName(i, BOOKTYPE_SPELL)
                if spellType == "SPELL" and spellId and name
                    and not (IsPassiveSpell and IsPassiveSpell(i, BOOKTYPE_SPELL)) then
                    book[name] = { id = spellId, index = i, bank = BOOKTYPE_SPELL }
                end
            end
        end
    end

    return book
end

local function IsKnown(id)
    if not id then return false end
    local checks = {
        C_SpellBook and C_SpellBook.IsSpellKnown,
        _G.IsPlayerSpell,
        _G.IsSpellKnown,
    }
    for _, fn in ipairs(checks) do
        local ok, known = pcall(fn, id)
        if ok and known then return true end
    end
    return false
end

-- Returns the spell ID to place for a saved spell entry, plus its spellbook
-- slot when known, or nil when the character does not have the spell yet.
local function ResolveSpell(entry, book)
    local found = entry.name and book[entry.name]
    if found then
        return found.id, found
    end
    if IsKnown(entry.id) then
        return entry.id
    end
    local base = FindBaseSpellByID and FindBaseSpellByID(entry.id)
    if base and base ~= entry.id and IsKnown(base) then
        return base
    end
    return nil
end

-- Macros ------------------------------------------------------------------

local function BuildMacroIndex()
    local byNameBody, byName = {}, {}
    local last = MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS
    for i = 1, last do
        local name, _, body = GetMacroInfo(i)
        if name then
            byNameBody[name .. "\n" .. (body or "")] = i
            byName[name] = byName[name] or i
        end
    end
    return { byNameBody = byNameBody, byName = byName }
end

local function FindOrCreateMacro(entry, index, quiet)
    local id = index.byNameBody[entry.name .. "\n" .. (entry.body or "")]
        or index.byName[entry.name]
    if id then return id end

    local numAccount, numChar = GetNumMacros()
    local perChar = entry.perChar
    if perChar and numChar >= MAX_CHARACTER_MACROS then perChar = false end
    if not perChar and numAccount >= MAX_ACCOUNT_MACROS then perChar = true end
    if perChar and numChar >= MAX_CHARACTER_MACROS then
        if not quiet then
            Print("No room to create macro \"" .. entry.name .. "\". Delete a macro and load again.")
        end
        return nil
    end

    local ok, newId = pcall(CreateMacro, entry.name, entry.icon or "INV_Misc_QuestionMark", entry.body or "", perChar)
    if ok and newId then
        index.byNameBody[entry.name .. "\n" .. (entry.body or "")] = newId
        index.byName[entry.name] = newId
        return newId
    end
    return nil
end

-- Reading the bars --------------------------------------------------------

local function ReadSlot(slot)
    local kind, id, subType = GetActionInfo(slot)
    if not kind then return nil end

    if kind == "spell" then
        return { t = "spell", id = id, name = GetSpellName(id) }
    elseif kind == "macro" then
        local macroId = id
        if subType or not GetMacroInfo(macroId or 0) then
            -- Macros that show a spell report the spell ID here; the cursor
            -- gives the real macro index.
            macroId = nil
            local text = GetActionText and GetActionText(slot)
            if text and GetMacroIndexByName then
                local found = GetMacroIndexByName(text)
                if found and found > 0 then macroId = found end
            end
            if not macroId then
                ClearCursor()
                PickupAction(slot)
                local _, cursorId = GetCursorInfo()
                PlaceAction(slot)
                ClearCursor()
                macroId = cursorId
            end
        end
        local name, icon, body = GetMacroInfo(macroId or 0)
        if not name then return { t = "keep" } end
        return { t = "macro", name = name, icon = icon, body = body, perChar = macroId > MAX_ACCOUNT_MACROS }
    elseif kind == "item" then
        return { t = "item", id = id }
    elseif kind == "summonmount" and C_MountJournal then
        local _, spellId = C_MountJournal.GetMountInfoByID(id)
        return { t = "mount", id = id, spell = spellId }
    elseif kind == "equipmentset" then
        return { t = "set", name = id }
    end

    -- Anything else (pet actions, flyouts, companions) is left untouched on load.
    return { t = "keep" }
end

-- Placing actions ---------------------------------------------------------

-- Puts the saved entry on the cursor. Returns true if something was picked up.
local function PickupEntry(entry, ctx)
    ClearCursor()
    if entry.t == "spell" then
        local id, bookEntry = ResolveSpell(entry, ctx.book)
        if not id then return false end
        PickupSpell(id)
        if not GetCursorInfo() and bookEntry then
            if C_SpellBook and C_SpellBook.PickupSpellBookItem then
                C_SpellBook.PickupSpellBookItem(bookEntry.index, bookEntry.bank)
            elseif PickupSpellBookItem then
                PickupSpellBookItem(bookEntry.index, bookEntry.bank)
            end
        end
    elseif entry.t == "macro" then
        local id = FindOrCreateMacro(entry, ctx.macros, ctx.quiet)
        if id then PickupMacro(id) end
    elseif entry.t == "item" then
        PickupItem(entry.id)
    elseif entry.t == "mount" then
        if entry.spell then PickupSpell(entry.spell) end
    elseif entry.t == "set" and C_EquipmentSet then
        local setId = C_EquipmentSet.GetEquipmentSetID(entry.name)
        if setId then C_EquipmentSet.PickupEquipmentSet(setId) end
    end
    return GetCursorInfo() ~= nil
end

local function Place(slot, entry, ctx)
    local ok, picked = pcall(PickupEntry, entry, ctx)
    if ok and picked then
        PlaceAction(slot)
        ClearCursor()
        return true
    end
    ClearCursor()
    return false
end

local function ClearSlot(slot)
    ClearCursor()
    PickupAction(slot)
    ClearCursor()
end

local function NewContext(quiet)
    return { book = BuildSpellBook(), macros = BuildMacroIndex(), quiet = quiet }
end

-- Save --------------------------------------------------------------------

local function DoSave()
    local classFile, className = ClassKey()
    local slots, count = {}, 0
    for slot = 1, MAX_SLOTS do
        local entry = ReadSlot(slot)
        if entry then
            slots[slot] = entry
            if entry.t ~= "keep" then count = count + 1 end
        end
    end
    DB.profiles[classFile] = {
        slots = slots,
        savedFrom = CharName(),
        savedAt = time(),
        count = count,
    }
    CHAR.applied = true
    CHAR.filled = {}
    for slot in pairs(slots) do CHAR.filled[slot] = true end
    Print(("Saved %d actions as the %s profile."):format(count, className))
    if OneClickBars_UpdateStatus then OneClickBars_UpdateStatus() end
end

StaticPopupDialogs["ONECLICKBARS_OVERWRITE"] = {
    text = "Replace the %s bar profile saved from %s with this character's bars?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() DoSave() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function OneClickBars_Save()
    if InCombatLockdown() then
        Print("Can't change action bars in combat.")
        return
    end
    local classFile, className = ClassKey()
    local existing = DB.profiles[classFile]
    if existing and existing.savedFrom ~= CharName() then
        StaticPopup_Show("ONECLICKBARS_OVERWRITE", className, existing.savedFrom)
    else
        DoSave()
    end
end

-- Load --------------------------------------------------------------------

local function DoLoad(quietIfMissing)
    local classFile, className = ClassKey()
    local profile = DB.profiles[classFile]
    if not profile then
        if not quietIfMissing then
            Print("No " .. className .. " profile yet. Set up your bars on a " .. className .. " and press Save.")
        end
        return
    end

    local ctx = NewContext(false)
    local placed, waiting = 0, 0
    CHAR.filled = {}

    for slot = 1, MAX_SLOTS do
        local entry = profile.slots[slot]
        if entry then
            if entry.t ~= "keep" then
                if Place(slot, entry, ctx) then
                    placed = placed + 1
                    CHAR.filled[slot] = true
                else
                    waiting = waiting + 1
                end
            end
        elseif GetActionInfo(slot) then
            ClearSlot(slot)
        end
    end

    CHAR.applied = true
    local msg = ("Loaded %s bars from %s: %d placed."):format(className, profile.savedFrom or "?", placed)
    if waiting > 0 then
        msg = msg .. (" %d not known yet; they will be placed as you learn them."):format(waiting)
    end
    Print(msg)
end

function OneClickBars_Load()
    if InCombatLockdown() then
        pendingAfterCombat = "load"
        Print("In combat. Bars will load when combat ends.")
        return
    end
    DoLoad(false)
    if UnitLevel("player") <= 1 and DB.resetGuide ~= false then
        ResetGuideLater()
    end
end

-- Auto-fill: place newly learned spells (and newly looted items) in their
-- saved slots. Slots already filled are left alone, except to upgrade a
-- spell to a higher rank of the same spell.
local function AutoFill()
    autoFillQueued = false
    if not (CHAR and CHAR.applied) or DB.autoFill == false then return end
    if InCombatLockdown() then
        pendingAfterCombat = pendingAfterCombat or "fill"
        return
    end

    local profile = DB.profiles[(ClassKey())]
    if not profile then return end

    local ctx = NewContext(true)
    local placed = 0
    local placedNames = {}

    for slot = 1, MAX_SLOTS do
        local entry = profile.slots[slot]
        if entry and entry.t ~= "keep" then
            local kind, curId = GetActionInfo(slot)
            local doPlace = false
            if not CHAR.filled[slot] then
                doPlace = true
            elseif entry.t == "spell" and kind == "spell" and GetSpellName(curId) == entry.name then
                local target = ResolveSpell(entry, ctx.book)
                doPlace = target and target ~= curId
            end
            if doPlace then
                if entry.t == "spell" and kind == "spell" and curId == ResolveSpell(entry, ctx.book) then
                    CHAR.filled[slot] = true
                elseif Place(slot, entry, ctx) then
                    CHAR.filled[slot] = true
                    placed = placed + 1
                    if entry.t == "spell" then placedNames[entry.name] = true end
                end
            end
        end
    end

    -- The game may drop a newly learned spell on a free slot by itself.
    -- Remove that copy if the profile has the slot empty.
    if next(placedNames) then
        for slot = 1, MAX_SLOTS do
            if not profile.slots[slot] then
                local kind, curId = GetActionInfo(slot)
                if kind == "spell" and placedNames[GetSpellName(curId) or ""] then
                    ClearSlot(slot)
                end
            end
        end
    end

    if placed > 0 then
        Print(("Placed %d new action%s from your profile."):format(placed, placed == 1 and "" or "s"))
    end
end

local function QueueAutoFill()
    if autoFillQueued then return end
    autoFillQueued = true
    C_Timer.After(1, AutoFill)
end

-- RestedXP ----------------------------------------------------------------

-- Starting guide per faction. RestedXP pads level ranges, so "1-6" is stored
-- as "01-06". Change with /1cb guide here.
local RXP_DEFAULT = {
    Horde = { group = "RestedXP Forever Guide (H)", name = "01-06 Durotar" },
}

local function GetRXP()
    local ace = LibStub and LibStub("AceAddon-3.0", true)
    return ace and ace:GetAddon("RXPGuides", true)
end

local function NormalizeName(s)
    return (s:gsub("%d+", function(d) return tostring(tonumber(d)) end))
end

local function FindGuide(rxp, target)
    local guide = rxp.GetGuideTable(target.group, target.name)
    if guide then return guide end
    local wanted = NormalizeName(target.name)
    for _, g in pairs(rxp.guides or {}) do
        if type(g) == "table" and g.group == target.group and g.name
            and NormalizeName(g.name) == wanted then
            return g
        end
    end
end

local function ResetGuide(attempt)
    attempt = attempt or 1
    local rxp = GetRXP()
    if not rxp or not RXPCData then
        Print("RestedXP isn't loaded.")
        return
    end

    local faction = UnitFactionGroup("player")
    local target = (DB.rxpTarget and DB.rxpTarget[faction]) or RXP_DEFAULT[faction]
    if not target then
        Print("No starting guide set for " .. tostring(faction)
            .. ". Load the guide you want in RestedXP, then type /1cb guide here.")
        return
    end

    -- RestedXP loads its guide list over the first few seconds after login.
    local guide = FindGuide(rxp, target)
    if not guide then
        if attempt < 10 then
            C_Timer.After(2, function() ResetGuide(attempt + 1) end)
        else
            Print("Couldn't find the RestedXP guide \"" .. target.name .. "\".")
        end
        return
    end

    RXPCData.currentGuideGroup = guide.group
    RXPCData.currentGuideName = guide.name
    local ok, err = pcall(rxp.ResetGuideProgress)
    if not ok then
        Print("RestedXP reset failed: " .. tostring(err))
        return
    end
    Print("RestedXP reset to " .. guide.name .. ", step 1.")
end

function OneClickBars_ResetGuide()
    ResetGuide(1)
end

ResetGuideLater = function()
    if GetRXP() then C_Timer.After(2, function() ResetGuide(1) end) end
end

-- Window ------------------------------------------------------------------

local frame

function OneClickBars_UpdateStatus()
    if not frame then return end
    local classFile, className = ClassKey()
    local profile = DB.profiles[classFile]
    if profile then
        frame.status:SetText(("%s profile: %d actions\nfrom %s"):format(className, profile.count or 0, profile.savedFrom or "?"))
    else
        frame.status:SetText("No " .. className .. " profile saved yet")
    end
end

local function CreateWindow()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "OneClickBarsFrame", UIParent, template)
    frame:SetSize(240, 182)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        DB.frame = { point, relPoint, x, y }
    end)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.9)
    end

    local pos = DB.frame
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
    frame:SetScale(DB.scale or 1.2)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("OneClickBars")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() OneClickBars_Toggle() end)

    local load = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    load:SetSize(200, 34)
    load:SetPoint("TOP", 0, -36)
    load:SetText("Load bars")
    load:SetNormalFontObject("GameFontNormalLarge")
    load:SetHighlightFontObject("GameFontHighlightLarge")
    load:SetScript("OnClick", OneClickBars_Load)

    local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    save:SetSize(200, 26)
    save:SetPoint("TOP", load, "BOTTOM", 0, -6)
    save:SetText("Save these bars")
    save:SetScript("OnClick", OneClickBars_Save)

    local guide = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    guide:SetSize(200, 26)
    guide:SetPoint("TOP", save, "BOTTOM", 0, -6)
    guide:SetText("Reset RestedXP guide")
    guide:SetScript("OnClick", OneClickBars_ResetGuide)

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.status:SetPoint("TOP", guide, "BOTTOM", 0, -8)
    frame.status:SetWidth(220)

    if DB.hidden then frame:Hide() end
    OneClickBars_UpdateStatus()
end

-- Minimap button: click to show or hide the window, drag to move it around
-- the minimap edge.
local function CreateMinimapButton()
    local button = CreateFrame("Button", "OneClickBarsMinimapButton", Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    local coords = (CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS.SHAMAN) or { 0.25, 0.49609375, 0.25, 0.5 }
    icon:SetTexCoord(unpack(coords))
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT")

    local function UpdatePosition()
        local angle = math.rad(DB.minimapAngle or 200)
        local radius = (Minimap:GetWidth() / 2) + 5
        button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
    end

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            DB.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            self:ClearAllPoints()
            UpdatePosition()
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnClick", function() OneClickBars_Toggle() end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("OneClickBars")
        GameTooltip:AddLine("Click to show or hide the window.", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button.", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
end

function OneClickBars_Toggle()
    if not frame then return end
    if frame:IsShown() then
        frame:Hide()
        DB.hidden = true
    else
        frame:Show()
        DB.hidden = false
        OneClickBars_UpdateStatus()
    end
end

_G.BINDING_HEADER_ONECLICKBARS = "OneClickBars"
_G.BINDING_NAME_ONECLICKBARS_LOAD = "Load action bars"
_G.BINDING_NAME_ONECLICKBARS_RESETGUIDE = "Reset RestedXP guide"
_G.BINDING_NAME_ONECLICKBARS_TOGGLE = "Show or hide the window"

-- Slash command -----------------------------------------------------------

SLASH_ONECLICKBARS1 = "/1cb"
SLASH_ONECLICKBARS2 = "/ocb"
SlashCmdList.ONECLICKBARS = function(input)
    local cmd, arg = strsplit(" ", strlower(strtrim(input or "")), 2)
    if cmd == "" then
        OneClickBars_Toggle()
    elseif cmd == "load" then
        OneClickBars_Load()
    elseif cmd == "save" then
        OneClickBars_Save()
    elseif cmd == "scale" and tonumber(arg or "") then
        DB.scale = math.max(0.5, math.min(3, tonumber(arg)))
        frame:SetScale(DB.scale)
    elseif cmd == "auto" then
        DB.autoFill = arg ~= "off"
        Print("Placing spells as you learn them: " .. (DB.autoFill and "on" or "off"))
    elseif cmd == "new" then
        DB.autoNew = arg ~= "off"
        Print("Auto-load on new level 1 characters: " .. (DB.autoNew and "on" or "off"))
    elseif cmd == "list" then
        local any = false
        for classFile, p in pairs(DB.profiles) do
            any = true
            Print(("%s: %d actions from %s"):format(classFile, p.count or 0, p.savedFrom or "?"))
        end
        if not any then Print("No profiles saved yet.") end
    elseif cmd == "guide" and arg == "here" then
        if not (RXPCData and RXPCData.currentGuideName) then
            Print("Load a guide in RestedXP first.")
            return
        end
        local faction = UnitFactionGroup("player")
        DB.rxpTarget = DB.rxpTarget or {}
        DB.rxpTarget[faction] = { group = RXPCData.currentGuideGroup, name = RXPCData.currentGuideName }
        Print(faction .. " starting guide set to " .. RXPCData.currentGuideName .. ".")
    elseif cmd == "guide" and (arg == "on" or arg == "off") then
        DB.resetGuide = arg == "on"
        Print("Reset RestedXP guide on level 1 characters: " .. arg)
    elseif cmd == "guide" then
        OneClickBars_ResetGuide()
    elseif cmd == "delete" then
        local classFile, className = ClassKey()
        DB.profiles[classFile] = nil
        Print("Deleted the " .. className .. " profile.")
        OneClickBars_UpdateStatus()
    else
        Print("/1cb (show/hide), /1cb load, /1cb save, /1cb list, /1cb delete, /1cb scale 1.5, /1cb auto on|off, /1cb new on|off, /1cb guide, /1cb guide here, /1cb guide on|off")
    end
end

-- Events ------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_TAB")
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_SKILL_LINE")

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        OneClickBarsDB = OneClickBarsDB or {}
        DB = OneClickBarsDB
        DB.profiles = DB.profiles or {}
        if OneClickBarsChar == nil then isNewCharacter = true end
        OneClickBarsChar = OneClickBarsChar or {}
        CHAR = OneClickBarsChar
        CHAR.filled = CHAR.filled or {}
        CreateWindow()
        CreateMinimapButton()
    elseif event == "PLAYER_ENTERING_WORLD" then
        OneClickBars_UpdateStatus()
        local isInitialLogin = arg1
        if isInitialLogin and isNewCharacter and DB.autoNew ~= false and UnitLevel("player") <= 1 then
            isNewCharacter = false
            -- Give the spellbook a moment to load before placing spells.
            C_Timer.After(3, function()
                if InCombatLockdown() then
                    pendingAfterCombat = "load"
                else
                    DoLoad(true)
                end
            end)
            if DB.resetGuide ~= false and GetRXP() then
                C_Timer.After(5, function() ResetGuide(1) end)
            end
        elseif CHAR.applied then
            QueueAutoFill()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        local pending = pendingAfterCombat
        pendingAfterCombat = nil
        if pending == "load" then
            DoLoad(false)
        elseif pending == "fill" then
            QueueAutoFill()
        end
    elseif DB and CHAR and CHAR.applied then
        QueueAutoFill()
    end
end)
