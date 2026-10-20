-- OneClickBars
-- Save the action bars of one character as a profile for its class, then
-- load that profile on any other character of the same class on the account.
-- After a load, spells you have not learned yet are placed in their saved
-- slot the moment you learn them.

local ADDON = ...

local SCHEMA = 2
local MAX_SLOTS = 180
local NUM_PET_SLOTS = _G.NUM_PET_ACTION_SLOTS or 10

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
local autoFillQueued = false
local petQueued = false
local petDoneThisSession = {}
-- True while this addon is moving actions, so the hooks below can tell our
-- changes apart from the player's.
local applying = false

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

-- Runs fn with the applying flag set and always clears it, even on error.
local function WithApplying(fn, ...)
    applying = true
    local ok, a, b = pcall(fn, ...)
    applying = false
    ClearCursor()
    if not ok then
        Print("Error: " .. tostring(a))
        return nil
    end
    return a, b
end

-- Profiles ----------------------------------------------------------------

local function SortedNames(list)
    local names = {}
    for name in pairs(list) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function ClassProfiles()
    local classFile = ClassKey()
    DB.profiles[classFile] = DB.profiles[classFile] or {}
    return DB.profiles[classFile]
end

-- The profile picked in the window for this class, or the first one.
local function SelectedName()
    local list = ClassProfiles()
    local name = DB.selected[(ClassKey())]
    if name and list[name] then return name end
    return SortedNames(list)[1]
end

local function SelectedProfile()
    local name = SelectedName()
    return name and ClassProfiles()[name], name
end

local function SelectProfile(name)
    DB.selected[(ClassKey())] = name
end

-- Profile data from version 1.1 was one profile per class. Wrap it as
-- "Default" so it keeps working.
local function Migrate()
    DB.profiles = DB.profiles or {}
    DB.selected = DB.selected or {}
    if (DB.schema or 1) < 2 then
        for classFile, p in pairs(DB.profiles) do
            if p.slots then
                DB.profiles[classFile] = { Default = p }
                DB.selected[classFile] = "Default"
            end
        end
    end
    DB.schema = SCHEMA

    CHAR.filled = CHAR.filled or {}
    CHAR.userSlots = CHAR.userSlots or {}
    if CHAR.applied and not CHAR.profile then CHAR.profile = "Default" end
    CHAR.schema = SCHEMA
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
    local index = { byNameBody = {}, account = {}, character = {} }
    for i = 1, MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS do
        local name, _, body = GetMacroInfo(i)
        if name then
            index.byNameBody[name .. "\n" .. (body or "")] = index.byNameBody[name .. "\n" .. (body or "")] or i
            local scope = i > MAX_ACCOUNT_MACROS and index.character or index.account
            scope[name] = scope[name] or i
        end
    end
    return index
end

-- Exact name and body first, then the same name in the same scope (account
-- or character), then the same name anywhere. Creates the macro if missing.
local function FindOrCreateMacro(entry, index, quiet)
    local key = entry.name .. "\n" .. (entry.body or "")
    local sameScope = entry.perChar and index.character or index.account
    local otherScope = entry.perChar and index.account or index.character
    local id = index.byNameBody[key] or sameScope[entry.name] or otherScope[entry.name]
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
        index.byNameBody[key] = newId
        local scope = perChar and index.character or index.account
        scope[entry.name] = newId
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

    -- Anything else (flyouts, companions) is left untouched on load.
    return { t = "keep" }
end

local function ReadAllSlots()
    local slots, count = {}, 0
    for slot = 1, MAX_SLOTS do
        local entry = ReadSlot(slot)
        if entry then
            slots[slot] = entry
            if entry.t ~= "keep" then count = count + 1 end
        end
    end
    return slots, count
end

-- Keybindings -------------------------------------------------------------

local function ReadBindings()
    local out, count = {}, 0
    for i = 1, GetNumBindings() do
        local command = GetBinding(i)
        if command then
            local keys = { GetBindingKey(command) }
            if #keys > 0 then
                out[command] = keys
                count = count + 1
            end
        end
    end
    return count > 0 and out or nil
end

-- Replaces every binding with the saved set. Skipped when nothing was saved,
-- so a bad save can't wipe all keys.
local function ApplyBindings(saved)
    if not saved or not next(saved) then return false end
    for i = 1, GetNumBindings() do
        local command = GetBinding(i)
        if command then
            for _, key in ipairs({ GetBindingKey(command) }) do
                SetBinding(key)
            end
        end
    end
    for command, keys in pairs(saved) do
        for _, key in ipairs(keys) do
            SetBinding(key, command)
        end
    end
    SaveBindings(GetCurrentBindingSet())
    return true
end

-- Which extra action bars are switched on --------------------------------

local function ReadBars()
    if not GetActionBarToggles then return nil end
    local n = select("#", GetActionBarToggles())
    if n == 0 then return nil end
    local bars = { n = n }
    for i = 1, n do
        bars[i] = select(i, GetActionBarToggles()) and true or false
    end
    return bars
end

local function ApplyBars(bars)
    if not bars or not SetActionBarToggles then return false end
    local current = ReadBars()
    local same = current and current.n == bars.n
    if same then
        for i = 1, bars.n do
            if current[i] ~= bars[i] then same = false break end
        end
    end
    if same then return false end
    local ok = pcall(SetActionBarToggles, unpack(bars, 1, bars.n))
    if ok and MultiActionBar_Update then pcall(MultiActionBar_Update) end
    return ok
end

-- Pet bar -----------------------------------------------------------------

local function PetFamily()
    if not UnitExists("pet") then return nil end
    return UnitCreatureFamily("pet") or UnitName("pet")
end

local function ReadPetBar()
    local layout = {}
    for slot = 1, NUM_PET_SLOTS do
        local name, _, isToken, _, _, autoCastEnabled = GetPetActionInfo(slot)
        if name then
            layout[slot] = { name = name, token = isToken and true or nil, autocast = autoCastEnabled and true or nil }
        end
    end
    return layout
end

local function PickupPetSpellByName(name)
    if C_SpellBook and C_SpellBook.HasPetSpells and Enum and Enum.SpellBookSpellBank then
        local bank = Enum.SpellBookSpellBank.Pet
        for i = 1, (C_SpellBook.HasPetSpells() or 0) do
            local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
            if item and item.name == name then
                C_SpellBook.PickupSpellBookItem(i, bank)
                return GetCursorInfo() ~= nil
            end
        end
    elseif HasPetSpells then
        for i = 1, (HasPetSpells() or 0) do
            if GetSpellBookItemName(i, BOOKTYPE_PET) == name then
                PickupSpellBookItem(i, BOOKTYPE_PET)
                return GetCursorInfo() ~= nil
            end
        end
    end
    return false
end

-- Moves pet spells into their saved slots and matches autocast. Attack,
-- Follow and the stance buttons are never moved: dropping one off the bar
-- would delete it.
local function ApplyPetBar(profile)
    local family = PetFamily()
    local layout = family and profile and profile.pets and profile.pets[family]
    if not layout then return false end
    for slot, entry in pairs(layout) do
        if not entry.token then
            local curName, _, curToken = GetPetActionInfo(slot)
            if curName ~= entry.name and not curToken then
                ClearCursor()
                if PickupPetSpellByName(entry.name) then
                    PickupPetAction(slot)
                end
                ClearCursor()
            end
            local name, _, _, _, allowed, enabled = GetPetActionInfo(slot)
            if name == entry.name and allowed and (enabled and true or false) ~= (entry.autocast or false) then
                pcall(TogglePetAutocast, slot)
            end
        end
    end
    petDoneThisSession[family] = true
    return true
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

-- Makes the bars match the saved slots exactly. Fills `filled` with the
-- slots that were placed.
local function ApplySlots(slots, ctx, filled)
    local placed, waiting = 0, 0
    for slot = 1, MAX_SLOTS do
        local entry = slots[slot]
        if entry then
            if entry.t ~= "keep" then
                if Place(slot, entry, ctx) then
                    placed = placed + 1
                    if filled then filled[slot] = true end
                else
                    waiting = waiting + 1
                end
            end
        elseif GetActionInfo(slot) then
            ClearSlot(slot)
        end
    end
    return placed, waiting
end

-- Track slots the player changes by hand, so auto-fill leaves them alone.
local function MarkUserSlot(slot)
    if not applying and CHAR and CHAR.userSlots and type(slot) == "number" then
        CHAR.userSlots[slot] = true
    end
end
if PlaceAction then hooksecurefunc("PlaceAction", MarkUserSlot) end
if PickupAction then hooksecurefunc("PickupAction", MarkUserSlot) end

-- Save --------------------------------------------------------------------

local function DoSave(name)
    local classFile, className = ClassKey()
    local slots, count = WithApplying(ReadAllSlots)
    if not slots then return end

    local list = ClassProfiles()
    local old = list[name]
    local pets = (old and old.pets) or {}
    local family = PetFamily()
    if family then pets[family] = ReadPetBar() end

    list[name] = {
        slots = slots,
        count = count,
        bindings = ReadBindings(),
        bars = ReadBars(),
        pets = pets,
        savedFrom = CharName(),
        savedAt = time(),
    }
    SelectProfile(name)

    CHAR.applied = true
    CHAR.profile = name
    CHAR.filled = {}
    CHAR.userSlots = {}
    for slot in pairs(slots) do CHAR.filled[slot] = true end

    Print(("Saved %d actions as the %s profile \"%s\"."):format(count, className, name))
    OneClickBars_UpdateStatus()
end

StaticPopupDialogs["ONECLICKBARS_OVERWRITE"] = {
    text = "Replace the %s profile \"%s\" with this character's bars?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data) DoSave(data) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function CreateNamedProfile(name)
    name = strtrim(name or "")
    if name == "" then return end
    if InCombatLockdown() then
        Print("Can't read action bars in combat.")
        return
    end
    if ClassProfiles()[name] then
        local _, className = ClassKey()
        StaticPopup_Show("ONECLICKBARS_OVERWRITE", className, name, name)
    else
        DoSave(name)
    end
end

local function PopupEditBox(popup)
    return popup.editBox or popup.EditBox or (popup.GetEditBox and popup:GetEditBox())
end

StaticPopupDialogs["ONECLICKBARS_NEWPROFILE"] = {
    text = "Name for the new %s profile:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 32,
    OnAccept = function(self)
        local box = PopupEditBox(self)
        CreateNamedProfile(box and box:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        CreateNamedProfile(self:GetText())
        self:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function OneClickBars_Save()
    if InCombatLockdown() then
        Print("Can't read action bars in combat.")
        return
    end
    local profile, name = SelectedProfile()
    if not profile then
        DoSave("Default")
    elseif profile.savedFrom ~= CharName() then
        local _, className = ClassKey()
        StaticPopup_Show("ONECLICKBARS_OVERWRITE", className, name, name)
    else
        DoSave(name)
    end
end

function OneClickBars_NewProfile()
    local _, className = ClassKey()
    StaticPopup_Show("ONECLICKBARS_NEWPROFILE", className)
end

StaticPopupDialogs["ONECLICKBARS_DELETE"] = {
    text = "Delete the %s profile \"%s\"?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        ClassProfiles()[data] = nil
        Print("Deleted profile \"" .. data .. "\".")
        OneClickBars_UpdateStatus()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function DeleteSelected()
    local profile, name = SelectedProfile()
    if not profile then
        Print("No profile to delete.")
        return
    end
    local _, className = ClassKey()
    StaticPopup_Show("ONECLICKBARS_DELETE", className, name, name)
end

-- Load and undo -----------------------------------------------------------

local function TakeSnapshot()
    local slots = ReadAllSlots()
    return {
        slots = slots,
        bindings = ReadBindings(),
        bars = ReadBars(),
        char = {
            applied = CHAR.applied,
            profile = CHAR.profile,
            filled = CHAR.filled,
            userSlots = CHAR.userSlots,
        },
        at = time(),
    }
end

local function DoLoad(quietIfMissing)
    local _, className = ClassKey()
    local profile, name = SelectedProfile()
    if not profile then
        if not quietIfMissing then
            Print("No " .. className .. " profile yet. Set up your bars on a " .. className .. " and press Save.")
        end
        return
    end

    local result = WithApplying(function()
        CHAR.undo = TakeSnapshot()
        local filled = {}
        local placed, waiting = ApplySlots(profile.slots, NewContext(false), filled)
        local keys = DB.copyBindings ~= false and ApplyBindings(profile.bindings)
        local bars = ApplyBars(profile.bars)
        local pet = ApplyPetBar(profile)
        CHAR.applied = true
        CHAR.profile = name
        CHAR.filled = filled
        CHAR.userSlots = {}
        return { placed = placed, waiting = waiting, keys = keys, bars = bars, pet = pet }
    end)
    if not result then return end

    local msg = ("Loaded \"%s\" from %s: %d placed."):format(name, profile.savedFrom or "?", result.placed)
    if result.waiting > 0 then
        msg = msg .. (" %d not known yet; they will be placed as you learn them."):format(result.waiting)
    end
    if result.keys then msg = msg .. " Keybindings copied." end
    if result.pet then msg = msg .. " Pet bar set." end
    Print(msg)
    if result.bars then
        Print("Switched on the same action bars as the saved character. Type /reload if one doesn't appear.")
    end
    OneClickBars_UpdateStatus()
end

local ResetGuideLater -- set in the RestedXP section

function OneClickBars_Load()
    if InCombatLockdown() then
        pendingAfterCombat = "load"
        Print("In combat. Bars will load when combat ends.")
        return
    end
    DoLoad(false)
    if UnitLevel("player") <= 1 then
        if DB.resetGuide ~= false then ResetGuideLater() end
        if DB.levelingSetup ~= false then C_Timer.After(1, OneClickBars_Setup) end
    end
end

local UndoSetup -- set in the leveling setup section

function OneClickBars_Undo()
    local snap, setup = CHAR.undo, CHAR.setupUndo
    if not snap and not setup then
        Print("Nothing to undo.")
        return
    end
    if InCombatLockdown() then
        Print("Can't change action bars or settings in combat.")
        return
    end
    if snap then
        local done = WithApplying(function()
            ApplySlots(snap.slots, NewContext(true))
            ApplyBindings(snap.bindings)
            ApplyBars(snap.bars)
            local c = snap.char or {}
            CHAR.applied = c.applied
            CHAR.profile = c.profile
            CHAR.filled = c.filled or {}
            CHAR.userSlots = c.userSlots or {}
            return true
        end)
        if done then
            CHAR.undo = nil
            Print("Restored your bars and keybindings from before the last load.")
        end
    end
    if setup then
        UndoSetup(setup)
        CHAR.setupUndo = nil
        CHAR.setupDone = nil
        Print("Restored the game and RestedXP settings from before the leveling setup.")
    end
    OneClickBars_UpdateStatus()
end

-- Auto-fill: place newly learned spells (and newly looted items) in their
-- saved slots. Filled slots and slots you changed by hand are left alone,
-- except to upgrade a spell to a higher rank of the same spell.
local function AutoFill()
    autoFillQueued = false
    if not (CHAR and CHAR.applied) or DB.autoFill == false then return end
    if InCombatLockdown() then
        pendingAfterCombat = pendingAfterCombat or "fill"
        return
    end

    local profile = CHAR.profile and ClassProfiles()[CHAR.profile]
    if not profile then return end

    local placed = WithApplying(function()
        local ctx = NewContext(true)
        local count = 0
        local placedNames = {}

        for slot = 1, MAX_SLOTS do
            local entry = profile.slots[slot]
            if entry and entry.t ~= "keep" and not CHAR.userSlots[slot] then
                local kind, curId = GetActionInfo(slot)
                local target = entry.t == "spell" and ResolveSpell(entry, ctx.book)
                if kind == "spell" and target and curId == target then
                    CHAR.filled[slot] = true
                elseif not CHAR.filled[slot]
                    or (target and kind == "spell" and GetSpellName(curId) == entry.name) then
                    if Place(slot, entry, ctx) then
                        CHAR.filled[slot] = true
                        count = count + 1
                        if entry.t == "spell" then placedNames[entry.name] = true end
                    end
                end
            end
        end

        -- The game may drop a newly learned spell on a free slot by itself.
        -- Remove that copy if the profile has the slot empty.
        if next(placedNames) then
            for slot = 1, MAX_SLOTS do
                if not profile.slots[slot] and not CHAR.userSlots[slot] then
                    local kind, curId = GetActionInfo(slot)
                    if kind == "spell" and placedNames[GetSpellName(curId) or ""] then
                        ClearSlot(slot)
                    end
                end
            end
        end
        return count
    end)

    if placed and placed > 0 then
        Print(("Placed %d new action%s from your profile."):format(placed, placed == 1 and "" or "s"))
    end
end

local function QueueAutoFill()
    if autoFillQueued then return end
    autoFillQueued = true
    C_Timer.After(1, AutoFill)
end

-- When a pet is summoned, set up its bar once per session.
local function QueuePetBar()
    if petQueued or not (CHAR and CHAR.applied) then return end
    petQueued = true
    C_Timer.After(1.5, function()
        petQueued = false
        local family = PetFamily()
        if not family or petDoneThisSession[family] or InCombatLockdown() then return end
        local profile = CHAR.profile and ClassProfiles()[CHAR.profile]
        if WithApplying(ApplyPetBar, profile) then
            Print("Pet bar set for " .. family .. ".")
        end
    end)
end

-- Opening cinematic -------------------------------------------------------

local function SkipCinematic()
    if DB.skipIntro == false or UnitLevel("player") > 1 then return end
    C_Timer.After(0.1, function()
        if CinematicFrame_CancelCinematic then
            pcall(CinematicFrame_CancelCinematic)
        elseif CanCancelScene and CanCancelScene() then
            pcall(CancelScene)
        elseif StopCinematic then
            pcall(StopCinematic)
        end
    end)
end

local function SkipMovie()
    if DB.skipIntro == false or UnitLevel("player") > 1 then return end
    C_Timer.After(0.1, function()
        if MovieFrame and MovieFrame.StopMovie then
            pcall(MovieFrame.StopMovie, MovieFrame)
        end
    end)
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

-- Leveling setup ----------------------------------------------------------

-- Client settings that cut clicks while leveling. Names and defaults checked
-- against the Forever 1.60.1 CVar list. CVars missing on a client are skipped.
local LEVELING_CVARS = {
    { "SoftTargetInteract", "3" },            -- interact key works with keyboard and mouse
    { "SoftTargetIconGameObject", "1" },      -- icons on quest objects and chests
    { "SoftTargetInteractArc", "1" },         -- interact with objects in a forward arc
    { "autoLootDefault", "1" },
    { "lootUnderMouse", "1" },
    { "autoQuestWatch", "1" },
    { "autoQuestProgress", "1" },
    { "instantQuestText", "1" },
    { "showQuestLevel", "1" },                -- saved per character
    { "nameplateShowEnemies", "1" },
    { "nameplateTargetRadialPosition", "1" }, -- keep the target's plate on screen
    { "enableFloatingCombatText", "1" },
    { "xpBarText", "1" },
    { "autoDismount", "1" },
    { "autoStand", "1" },
}

-- RestedXP options that are off on new characters.
local RXP_SWITCHES = { "enableTrainerAutomation", "enableQuestRewardAutomation", "autoSellJunk" }

local GetCVarValue = (C_CVar and C_CVar.GetCVar) or GetCVar
local SetCVarValue = (C_CVar and C_CVar.SetCVar) or SetCVar
local pendingSetup = false

local function RXPProfile()
    local rxp = GetRXP()
    return rxp and rxp.settings and rxp.settings.profile
end

local function DoLevelingSetup(quiet)
    if InCombatLockdown() then
        -- Some of these CVars can't be changed in combat.
        pendingSetup = true
        if not quiet then Print("In combat. Leveling setup will run when combat ends.") end
        return
    end

    local undo = CHAR.setupUndo or { cvars = {}, rxp = {} }
    local changed = 0
    for _, pair in ipairs(LEVELING_CVARS) do
        local name, value = pair[1], pair[2]
        local current = GetCVarValue(name)
        if current ~= nil and current ~= value then
            pcall(SetCVarValue, name, value)
            if GetCVarValue(name) == value then
                if undo.cvars[name] == nil then undo.cvars[name] = current end
                changed = changed + 1
            end
        end
    end

    local rxpProfile = RXPProfile()
    local switched = 0
    if rxpProfile then
        for _, key in ipairs(RXP_SWITCHES) do
            if not rxpProfile[key] then
                if undo.rxp[key] == nil then undo.rxp[key] = rxpProfile[key] or false end
                rxpProfile[key] = true
                switched = switched + 1
            end
        end
    end

    if next(undo.cvars) or next(undo.rxp) then CHAR.setupUndo = undo end
    CHAR.setupDone = true

    if changed + switched > 0 or not quiet then
        local msg = ("Leveling setup: %d game settings changed."):format(changed)
        if rxpProfile then
            msg = msg .. (" RestedXP trainer, quest reward and junk automation on (%d changed)."):format(switched)
        end
        Print(msg)
    end
    if not GetBindingKey("INTERACTTARGET") then
        Print("Bind a key to \"Interact With Target\" in Key Bindings. It talks to NPCs, loots and clicks quest objects.")
    end
    local lea = _G.LeaPlusDB
    if lea and rxpProfile then
        if lea.AutomateQuests == "On" and rxpProfile.enableQuestAutomation then
            Print("Leatrix Plus and RestedXP both accept quests. Turn off \"Automate quests\" in Leatrix so you only take guide quests.")
        end
        if lea.AutoSellJunk == "On" and rxpProfile.autoSellJunk then
            Print("Leatrix Plus and RestedXP both sell junk. Turn off \"Sell junk automatically\" in Leatrix.")
        end
    end
    OneClickBars_UpdateStatus()
end

function OneClickBars_Setup()
    DoLevelingSetup(false)
end

UndoSetup = function(undo)
    for name, value in pairs(undo.cvars or {}) do
        pcall(SetCVarValue, name, value)
    end
    local rxpProfile = RXPProfile()
    if rxpProfile then
        for key, value in pairs(undo.rxp or {}) do
            rxpProfile[key] = value
        end
    end
end

-- Talent reminders --------------------------------------------------------

-- Most-picked Forever Enhancement leveling order (talentsforever.com,
-- October 2026). Forever reworked the trees, so Classic orders don't apply.
local TALENT_TIPS = {
    SHAMAN = {
        [10] = "Thundering Strikes", [11] = "Thundering Strikes", [12] = "Thundering Strikes",
        [13] = "Thundering Strikes", [14] = "Thundering Strikes",
        [15] = "Mental Dexterity", [16] = "Mental Dexterity", [17] = "Mental Dexterity",
        [18] = "Improved Ghost Wolf", [19] = "Improved Ghost Wolf",
        [20] = "Shamanistic Focus",
    },
}

local function TalentTip(level)
    if DB.talentTips == false then return end
    local tips = TALENT_TIPS[(ClassKey())]
    local talent = tips and tips[level]
    if not talent then return end
    local text = ("Level %d: put your talent point in %s."):format(level, talent)
    Print(text)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
        RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
    end
end

-- Window ------------------------------------------------------------------

local frame

local function CycleProfile(step)
    local names = SortedNames(ClassProfiles())
    if #names == 0 then return end
    local current = SelectedName()
    local index = 1
    for i, name in ipairs(names) do
        if name == current then index = i end
    end
    index = ((index - 1 + step) % #names) + 1
    SelectProfile(names[index])
    OneClickBars_UpdateStatus()
end

function OneClickBars_UpdateStatus()
    if not frame or not DB then return end
    local _, className = ClassKey()
    local profile, name = SelectedProfile()
    if profile then
        frame.profileName:SetText(name)
        frame.status:SetText(("%s: %d actions\nfrom %s"):format(className, profile.count or 0, profile.savedFrom or "?"))
    else
        frame.profileName:SetText("No profile")
        frame.status:SetText("No " .. className .. " profile saved yet")
    end
    local multiple = #SortedNames(ClassProfiles()) > 1
    frame.prev:SetEnabled(multiple)
    frame.next:SetEnabled(multiple)
    frame.undo:SetEnabled(CHAR ~= nil and (CHAR.undo ~= nil or CHAR.setupUndo ~= nil))
end

local function Button(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, height)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateWindow()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "OneClickBarsFrame", UIParent, template)
    frame:SetSize(240, 290)
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

    -- Profile picker: < name >
    frame.prev = Button(frame, "<", 28, 24, function() CycleProfile(-1) end)
    frame.prev:SetPoint("TOPLEFT", 20, -34)
    frame.next = Button(frame, ">", 28, 24, function() CycleProfile(1) end)
    frame.next:SetPoint("TOPRIGHT", -20, -34)
    frame.profileName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.profileName:SetPoint("LEFT", frame.prev, "RIGHT", 4, 0)
    frame.profileName:SetPoint("RIGHT", frame.next, "LEFT", -4, 0)

    local load = Button(frame, "Load bars", 200, 34, OneClickBars_Load)
    load:SetPoint("TOP", 0, -64)
    load:SetNormalFontObject("GameFontNormalLarge")
    load:SetHighlightFontObject("GameFontHighlightLarge")

    local save = Button(frame, "Save bars", 98, 26, OneClickBars_Save)
    save:SetPoint("TOPLEFT", load, "BOTTOMLEFT", 0, -6)
    local new = Button(frame, "New profile", 98, 26, OneClickBars_NewProfile)
    new:SetPoint("TOPRIGHT", load, "BOTTOMRIGHT", 0, -6)

    frame.undo = Button(frame, "Undo", 200, 26, OneClickBars_Undo)
    frame.undo:SetPoint("TOP", load, "BOTTOM", 0, -38)

    local setup = Button(frame, "Leveling setup", 200, 26, OneClickBars_Setup)
    setup:SetPoint("TOP", frame.undo, "BOTTOM", 0, -6)

    local guide = Button(frame, "Reset RestedXP guide", 200, 26, OneClickBars_ResetGuide)
    guide:SetPoint("TOP", setup, "BOTTOM", 0, -6)

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
_G.BINDING_NAME_ONECLICKBARS_UNDO = "Undo last load and setup"
_G.BINDING_NAME_ONECLICKBARS_SETUP = "Leveling setup"
_G.BINDING_NAME_ONECLICKBARS_RESETGUIDE = "Reset RestedXP guide"
_G.BINDING_NAME_ONECLICKBARS_TOGGLE = "Show or hide the window"

-- Slash command -----------------------------------------------------------

local function OnOff(arg)
    return arg ~= "off"
end

SLASH_ONECLICKBARS1 = "/1cb"
SLASH_ONECLICKBARS2 = "/ocb"
SlashCmdList.ONECLICKBARS = function(input)
    local cmd, arg = strsplit(" ", strtrim(input or ""), 2)
    cmd = strlower(cmd or "")
    local argLower = arg and strlower(strtrim(arg))
    if cmd == "" then
        OneClickBars_Toggle()
    elseif cmd == "load" then
        OneClickBars_Load()
    elseif cmd == "save" then
        OneClickBars_Save()
    elseif cmd == "undo" then
        OneClickBars_Undo()
    elseif cmd == "new" and argLower ~= "on" and argLower ~= "off" then
        if arg and strtrim(arg) ~= "" then
            CreateNamedProfile(arg)
        else
            OneClickBars_NewProfile()
        end
    elseif cmd == "new" then
        DB.autoNew = OnOff(argLower)
        Print("Auto-load on new level 1 characters: " .. argLower)
    elseif cmd == "use" and arg then
        local name = strtrim(arg)
        if ClassProfiles()[name] then
            SelectProfile(name)
            Print("Selected profile \"" .. name .. "\".")
            OneClickBars_UpdateStatus()
        else
            Print("No profile named \"" .. name .. "\".")
        end
    elseif cmd == "scale" and tonumber(argLower or "") then
        DB.scale = math.max(0.5, math.min(3, tonumber(argLower)))
        frame:SetScale(DB.scale)
    elseif cmd == "auto" then
        DB.autoFill = OnOff(argLower)
        Print("Placing spells as you learn them: " .. (DB.autoFill and "on" or "off"))
    elseif cmd == "keys" then
        DB.copyBindings = OnOff(argLower)
        Print("Copy keybindings on load: " .. (DB.copyBindings and "on" or "off"))
    elseif cmd == "intro" then
        DB.skipIntro = OnOff(argLower)
        Print("Skip the opening cinematic: " .. (DB.skipIntro and "on" or "off"))
    elseif cmd == "list" then
        local any = false
        for classFile, list in pairs(DB.profiles) do
            for name, p in pairs(list) do
                any = true
                Print(("%s \"%s\": %d actions from %s"):format(classFile, name, p.count or 0, p.savedFrom or "?"))
            end
        end
        if not any then Print("No profiles saved yet.") end
    elseif cmd == "guide" and argLower == "here" then
        if not (RXPCData and RXPCData.currentGuideName) then
            Print("Load a guide in RestedXP first.")
            return
        end
        local faction = UnitFactionGroup("player")
        DB.rxpTarget = DB.rxpTarget or {}
        DB.rxpTarget[faction] = { group = RXPCData.currentGuideGroup, name = RXPCData.currentGuideName }
        Print(faction .. " starting guide set to " .. RXPCData.currentGuideName .. ".")
    elseif cmd == "guide" and (argLower == "on" or argLower == "off") then
        DB.resetGuide = argLower == "on"
        Print("Reset RestedXP guide on level 1 characters: " .. argLower)
    elseif cmd == "guide" then
        OneClickBars_ResetGuide()
    elseif cmd == "setup" and (argLower == "on" or argLower == "off") then
        DB.levelingSetup = argLower == "on"
        Print("Leveling setup on new level 1 characters: " .. argLower)
    elseif cmd == "setup" then
        OneClickBars_Setup()
    elseif cmd == "talents" then
        DB.talentTips = OnOff(argLower)
        Print("Talent reminders: " .. (DB.talentTips and "on" or "off"))
    elseif cmd == "delete" then
        DeleteSelected()
    else
        Print("/1cb (show/hide), load, save, undo, new [name], use <name>, list, delete, scale 1.5, "
            .. "auto on|off, keys on|off, intro on|off, new on|off, setup, setup on|off, talents on|off, "
            .. "guide, guide here, guide on|off")
    end
end

-- Events ------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("UNIT_PET")
events:RegisterEvent("CINEMATIC_START")
events:RegisterEvent("PLAYER_LEVEL_UP")
pcall(events.RegisterEvent, events, "PLAY_MOVIE")
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_TAB")
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_SKILL_LINE")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        OneClickBarsDB = OneClickBarsDB or {}
        DB = OneClickBarsDB
        if OneClickBarsChar == nil then isNewCharacter = true end
        OneClickBarsChar = OneClickBarsChar or {}
        CHAR = OneClickBarsChar
        Migrate()
        CreateWindow()
        CreateMinimapButton()
        return
    end
    if not DB then return end

    if event == "CINEMATIC_START" then
        SkipCinematic()
    elseif event == "PLAY_MOVIE" then
        SkipMovie()
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
            if DB.levelingSetup ~= false then
                C_Timer.After(6, function() DoLevelingSetup(true) end)
            end
        elseif CHAR.applied then
            QueueAutoFill()
            QueuePetBar()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        TalentTip(arg1)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingSetup then
            pendingSetup = false
            DoLevelingSetup(true)
        end
        local pending = pendingAfterCombat
        pendingAfterCombat = nil
        if pending == "load" then
            DoLoad(false)
        elseif pending == "fill" then
            QueueAutoFill()
        end
    elseif event == "UNIT_PET" then
        if arg1 == "player" then QueuePetBar() end
    elseif CHAR.applied then
        QueueAutoFill()
    end
end)
