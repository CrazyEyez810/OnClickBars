-- OneClickMail
-- Mails items to your own alts by rules, so you never pick a stranger from
-- the name autofill. Adds a "One Click" tab to the mailbox next to Inbox and
-- Send Mail. Inside it, each alt has its own tab with rules (herbs, leather,
-- cloth and so on, plus items you drop in). Click Send, or let it send
-- automatically when you open the mailbox, like RestedXP turns in quests
-- when you talk to an NPC.
--
-- Alts are remembered when they log in with this addon, so each alt needs
-- to log in once. Soulbound items, quest items and the hearthstone are
-- never sent.

local ADDON = ...

local MAX_ATTACH = _G.ATTACHMENTS_MAX_SEND or 12
local NEVER_SEND = { [6948] = true } -- Hearthstone

local DB
local panel, mailTab
local selected = 1
local sending = nil     -- { key, count, auto } while a mail is in flight
local autoQueue = nil   -- alt keys still to send to after opening the mailbox

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickMail:|r " .. msg)
end

local function CharKey(name, realm)
    return name .. "-" .. realm
end

local function MyKey()
    return CharKey(UnitName("player"), GetRealmName())
end

-- Item rules ---------------------------------------------------------------

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local TRADE_GOODS, CONSUMABLE, WEAPON, ARMOR, QUEST = 7, 0, 2, 4, 12

local function IdSet(list)
    local set = {}
    for _, id in ipairs(list) do set[id] = true end
    return set
end

-- Each category matches by item ID or by name, and only within the listed
-- item classes, so a name match can't pull in an unrelated item.
local CATEGORIES = {
    { key = "herbs", label = "Herbs", classes = { TRADE_GOODS }, ids = IdSet({
        2447, 765, 2449, 785, 2450, 2452, 3820, 2453, 3355, 3369, 3356, 3357, 3818, 3821,
        3358, 3819, 4625, 8831, 8836, 8838, 8839, 8845, 8846, 13464, 13463, 13465, 13466,
        13467, 13468, 19726,
    }) },
    { key = "leather", label = "Leather and hides", classes = { TRADE_GOODS },
        patterns = { "Leather$", "Leather Scraps$", " Hide$", " Scale$" } },
    { key = "cloth", label = "Cloth", classes = { TRADE_GOODS },
        patterns = { " Cloth$" }, exclude = { "^Bolt of " } },
    { key = "mining", label = "Ore, bars and stone", classes = { TRADE_GOODS },
        patterns = { " Ore$", " Bar$", "^Rough Stone$", "^Coarse Stone$", "^Heavy Stone$",
            "^Solid Stone$", "^Dense Stone$" } },
    { key = "gems", label = "Gems", classes = { TRADE_GOODS }, ids = IdSet({
        774, 818, 1210, 1206, 1705, 1529, 3864, 7909, 7910, 12800, 12361, 12364, 12799,
    }) },
    { key = "enchanting", label = "Enchanting materials", classes = { TRADE_GOODS },
        patterns = { " Dust$", " Shard$", "Magic Essence$", "Astral Essence$", "Mystic Essence$",
            "Nether Essence$", "Eternal Essence$", "^Nexus Crystal$" } },
    -- Meat names only as trade goods, so cooked food like "Roasted Boar Meat"
    -- stays; raw fish is a consumable, so "Raw ..." matches both.
    { key = "cooking", label = "Raw meat and fish", classes = { TRADE_GOODS },
        patterns = { " Meat$", " Flank$", " Liver$", " Egg$", "^Raw " },
        also = { classes = { CONSUMABLE }, patterns = { "^Raw " } } },
    { key = "greens", label = "Green gear to disenchant", classes = { WEAPON, ARMOR }, quality = 2 },
}

local function InClasses(classID, classes)
    for _, c in ipairs(classes) do
        if c == classID then return true end
    end
    return false
end

local function MatchesCategory(cat, item)
    if cat.also and InClasses(item.classID, cat.also.classes) then
        for _, pattern in ipairs(cat.also.patterns) do
            if item.name:find(pattern) then return true end
        end
    end
    if not InClasses(item.classID, cat.classes) then return false end
    if cat.quality then return item.quality == cat.quality end
    if cat.ids then return cat.ids[item.id] or false end
    for _, pattern in ipairs(cat.exclude or {}) do
        if item.name:find(pattern) then return false end
    end
    for _, pattern in ipairs(cat.patterns or {}) do
        if item.name:find(pattern) then return true end
    end
    return false
end

local function MatchesTab(tab, item)
    if item.bound or item.classID == QUEST or NEVER_SEND[item.id] then return false end
    if tab.custom and tab.custom[item.id] then return true end
    for _, cat in ipairs(CATEGORIES) do
        if tab.rules and tab.rules[cat.key] and MatchesCategory(cat, item) then return true end
    end
    return false
end

-- Bags -----------------------------------------------------------------------

local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or _G.GetContainerNumSlots
local PickupItem = (C_Container and C_Container.PickupContainerItem) or _G.PickupContainerItem

local function SlotInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if not info then return nil end
        return info.itemID, info.stackCount, info.isBound, info.quality, info.hyperlink, info.isLocked
    end
    local _, count, locked, quality, _, _, link, _, _, itemID, bound = GetContainerItemInfo(bag, slot)
    return itemID, count, bound, quality, link, locked
end

local function BagItems()
    local items = {}
    for bag = 0, (_G.NUM_BAG_SLOTS or 4) do
        for slot = 1, (GetNumSlots(bag) or 0) do
            local id, count, bound, quality, link, locked = SlotInfo(bag, slot)
            if id and link and not locked then
                local _, _, _, _, _, classID = GetItemInfoInstant(id)
                items[#items + 1] = {
                    bag = bag, slot = slot, id = id, count = count or 1, bound = bound,
                    quality = quality, link = link, name = link:match("%[(.-)%]") or "",
                    classID = classID,
                }
            end
        end
    end
    return items
end

local function MatchingItems(tab)
    local out = {}
    for _, item in ipairs(BagItems()) do
        if MatchesTab(tab, item) then out[#out + 1] = item end
    end
    return out
end

-- Alts and tabs --------------------------------------------------------------

local function RememberMe()
    local name, realm = UnitName("player"), GetRealmName()
    if not name or not realm then return end
    local _, class = UnitClass("player")
    DB.chars[CharKey(name, realm)] = {
        name = name, realm = realm, faction = UnitFactionGroup("player"),
        class = class, level = UnitLevel("player"), seen = time(),
    }
end

-- Tabs for alts you can mail from this character: same faction and realm,
-- not this character.
local function VisibleTabs()
    local me = DB.chars[MyKey()]
    local list = {}
    for _, tab in ipairs(DB.tabs) do
        local alt = DB.chars[tab.key]
        if alt and tab.key ~= MyKey() and me and alt.faction == me.faction and alt.realm == me.realm then
            list[#list + 1] = tab
        end
    end
    return list
end

local function Recipient(key)
    local alt = DB.chars[key]
    if not alt then return nil end
    if alt.realm == GetRealmName() then return alt.name end
    return alt.name .. "-" .. alt.realm
end

local function SummaryLines(items)
    local counts, order = {}, {}
    for _, item in ipairs(items) do
        if not counts[item.name] then
            counts[item.name] = 0
            order[#order + 1] = item.name
        end
        counts[item.name] = counts[item.name] + item.count
    end
    local lines = {}
    for _, name in ipairs(order) do lines[#lines + 1] = ("%d x %s"):format(counts[name], name) end
    return lines
end

-- Sending --------------------------------------------------------------------

local UpdatePanel -- defined with the panel

-- Sends one mail of up to 12 matching items to the tab's alt. Returns the
-- number of items attached, or nil with a reason.
local function SendBatch(tab, auto)
    if sending then return nil, "busy" end
    local recipient = Recipient(tab.key)
    if not recipient then return nil, "unknown alt" end
    local items = MatchingItems(tab)
    if #items == 0 then return nil, "nothing to send" end

    ClearCursor()
    if ClearSendMail then ClearSendMail() end
    local attached = 0
    for i = 1, math.min(#items, MAX_ATTACH) do
        local item = items[i]
        PickupItem(item.bag, item.slot)
        ClickSendMailItemButton(attached + 1)
        if GetCursorInfo() then
            ClearCursor()
        else
            attached = attached + 1
        end
    end
    if attached == 0 then return nil, "couldn't attach items" end
    if GetSendMailPrice and GetSendMailPrice() > GetMoney() then
        ClearSendMail()
        return nil, "not enough money for postage"
    end

    sending = { key = tab.key, count = attached, auto = auto, at = GetTime() }
    SendMail(recipient, ("OneClickMail: %d item%s"):format(attached, attached == 1 and "" or "s"), "")
    -- If the client blocks sending without a click, no result ever comes.
    C_Timer.After(6, function()
        if sending and sending.at and GetTime() - sending.at >= 6 then
            sending = nil
            autoQueue = nil
            if ClearSendMail then ClearSendMail() end
            Print("The mail didn't go through. Click Send on the One Click tab instead.")
            if UpdatePanel then UpdatePanel() end
        end
    end)
    if UpdatePanel then UpdatePanel() end
    return attached
end

-- Sends the next batch for the alts queued when the mailbox opened.
local function ContinueAuto()
    while autoQueue and #autoQueue > 0 do
        local key = autoQueue[1]
        local tab
        for _, t in ipairs(DB.tabs) do if t.key == key then tab = t end end
        local count = tab and SendBatch(tab, true)
        if count then return end
        table.remove(autoQueue, 1)
    end
    autoQueue = nil
end

local function StartAuto()
    if DB.autoBlocked then return end
    local queue = {}
    for _, tab in ipairs(VisibleTabs()) do
        if tab.auto and #MatchingItems(tab) > 0 then queue[#queue + 1] = tab.key end
    end
    if #queue == 0 then return end
    autoQueue = queue
    C_Timer.After(0.5, ContinueAuto)
end

-- Panel ------------------------------------------------------------------------

local altButtons = {}
local checkboxes = {}
local customButtons = {}
local addMenu

local function SelectedTab()
    local tabs = VisibleTabs()
    if selected > #tabs then selected = #tabs end
    if selected < 1 then selected = 1 end
    return tabs[selected], tabs
end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and ("|c%s"):format(c.colorStr or "ffffffff") or "|cffffffff"
end

UpdatePanel = function()
    if not panel or not panel:IsShown() then return end
    local tab, tabs = SelectedTab()

    for i, button in ipairs(altButtons) do button:Hide() end
    for i, t in ipairs(tabs) do
        local button = altButtons[i]
        if not button then
            button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            button:SetSize(80, 22)
            button:SetScript("OnClick", function(self)
                selected = self.index
                UpdatePanel()
            end)
            altButtons[i] = button
        end
        local alt = DB.chars[t.key]
        button.index = i
        button:SetText(alt and alt.name or t.key)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", panel, "TOPLEFT", 4 + ((i - 1) % 3) * 84, -4 - math.floor((i - 1) / 3) * 24)
        button:Show()
        if i == selected then button:LockHighlight() else button:UnlockHighlight() end
    end
    local n = #tabs
    panel.add:ClearAllPoints()
    panel.add:SetPoint("TOPLEFT", panel, "TOPLEFT", 4 + (n % 3) * 84, -4 - math.floor(n / 3) * 24)

    local rows = math.floor(n / 3) + 1
    local top = -8 - rows * 24
    panel.body:ClearAllPoints()
    panel.body:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, top)
    panel.body:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

    if not tab then
        panel.body:Hide()
        panel.empty:Show()
        return
    end
    panel.empty:Hide()
    panel.body:Show()

    local alt = DB.chars[tab.key]
    panel.to:SetText("Send to: " .. ClassColor(alt and alt.class) .. (Recipient(tab.key) or tab.key))
    for _, box in ipairs(checkboxes) do box:SetChecked(tab.rules[box.key] and true or false) end
    panel.auto:SetChecked(tab.auto and true or false)

    -- Custom items as icons; click one to remove it.
    for _, b in ipairs(customButtons) do b:Hide() end
    local i = 0
    for id in pairs(tab.custom) do
        i = i + 1
        local b = customButtons[i]
        if not b then
            b = CreateFrame("Button", nil, panel.body)
            b:SetSize(24, 24)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b:SetScript("OnClick", function(self)
                local t = SelectedTab()
                if t then t.custom[self.itemID] = nil end
                GameTooltip:Hide()
                UpdatePanel()
            end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.itemID)
                GameTooltip:AddLine("Click to stop sending this item", 1, 1, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            customButtons[i] = b
        end
        b.itemID = id
        local _, _, _, _, icon = GetItemInfoInstant(id)
        b.icon:SetTexture(icon or 134400)
        b:ClearAllPoints()
        b:SetPoint("LEFT", panel.drop, "RIGHT", 4 + (i - 1) * 26, 0)
        b:Show()
    end

    local items = MatchingItems(tab)
    local lines = SummaryLines(items)
    if #lines == 0 then
        panel.preview:SetText("|cffaaaaaaNothing in your bags matches these rules.")
    else
        local shown = {}
        for k = 1, math.min(#lines, 8) do shown[k] = lines[k] end
        if #lines > 8 then shown[#shown + 1] = ("and %d more"):format(#lines - 8) end
        panel.preview:SetText(table.concat(shown, "\n"))
    end

    local batch = math.min(#items, MAX_ATTACH)
    if sending then
        panel.send:SetText("Sending...")
        panel.send:Disable()
    elseif batch == 0 then
        panel.send:SetText("Nothing to send")
        panel.send:Disable()
    else
        local mails = math.ceil(#items / MAX_ATTACH)
        panel.send:SetText(("Send %d item%s%s"):format(batch, batch == 1 and "" or "s",
            mails > 1 and (" (1 of %d mails)"):format(mails) or ""))
        panel.send:Enable()
    end
end

local function ShowAddMenu()
    if not addMenu then
        addMenu = CreateFrame("Frame", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
        addMenu:SetFrameStrata("DIALOG")
        if addMenu.SetBackdrop then
            addMenu:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            addMenu:SetBackdropColor(0, 0, 0, 0.95)
        end
        addMenu.buttons = {}
        addMenu.title = addMenu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        addMenu.title:SetPoint("TOPLEFT", 10, -10)
        addMenu.title:SetText("Mail to which character?")
    end
    for _, b in ipairs(addMenu.buttons) do b:Hide() end

    local me = DB.chars[MyKey()]
    local taken = {}
    for _, t in ipairs(DB.tabs) do taken[t.key] = true end
    local choices = {}
    for key, alt in pairs(DB.chars) do
        if key ~= MyKey() and not taken[key] and me and alt.faction == me.faction and alt.realm == me.realm then
            choices[#choices + 1] = key
        end
    end
    table.sort(choices)

    if #choices == 0 then
        addMenu:Hide()
        Print("No other characters to add. Log in on each alt once with OneClickMail installed and it will show up here.")
        return
    end
    for i, key in ipairs(choices) do
        local b = addMenu.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, addMenu, "UIPanelButtonTemplate")
            b:SetSize(160, 22)
            b:SetScript("OnClick", function(self)
                DB.tabs[#DB.tabs + 1] = { key = self.key, rules = {}, custom = {}, auto = false }
                addMenu:Hide()
                local _, tabs = SelectedTab()
                for idx, t in ipairs(tabs) do if t.key == self.key then selected = idx end end
                UpdatePanel()
            end)
            addMenu.buttons[i] = b
        end
        local alt = DB.chars[key]
        b.key = key
        b:SetText(ClassColor(alt.class) .. alt.name .. "|r  " .. (alt.level or ""))
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", addMenu, "TOPLEFT", 10, -28 - (i - 1) * 24)
        b:Show()
    end
    addMenu:SetSize(180, 38 + #choices * 24)
    addMenu:ClearAllPoints()
    addMenu:SetPoint("TOPLEFT", panel.add, "BOTTOMLEFT", 0, -2)
    addMenu:Show()
end

local function CreatePanel()
    if panel or not MailFrame then return end
    panel = CreateFrame("Frame", "OneClickMailPanel", MailFrame)
    local area = InboxFrame or MailFrame
    panel:SetPoint("TOPLEFT", area, "TOPLEFT", 20, -70)
    panel:SetPoint("BOTTOMRIGHT", MailFrame, "BOTTOMRIGHT", -20, 90)
    panel:Hide()

    panel.add = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.add:SetSize(26, 22)
    panel.add:SetText("+")
    panel.add:SetScript("OnClick", ShowAddMenu)
    panel.add:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add a character to mail to")
        GameTooltip:Show()
    end)
    panel.add:SetScript("OnLeave", function() GameTooltip:Hide() end)

    panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -40)
    panel.empty:SetWidth(280)
    panel.empty:SetJustifyH("LEFT")
    panel.empty:SetText("Click + to add one of your characters. Each one gets its own tab with rules for what to send it.")

    local body = CreateFrame("Frame", nil, panel)
    panel.body = body

    panel.to = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.to:SetPoint("TOPLEFT", 4, 0)

    for i, cat in ipairs(CATEGORIES) do
        local box = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
        box:SetSize(24, 24)
        box:SetPoint("TOPLEFT", body, "TOPLEFT", ((i - 1) % 2) * 150, -22 - math.floor((i - 1) / 2) * 22)
        box.key = cat.key
        local label = box.Text or box.text or _G[box:GetName() or ""]
        if not label then
            label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", box, "RIGHT", 2, 0)
        end
        label:SetText(cat.label)
        box:SetScript("OnClick", function(self)
            local tab = SelectedTab()
            if tab then tab.rules[self.key] = self:GetChecked() and true or nil end
            UpdatePanel()
        end)
        checkboxes[#checkboxes + 1] = box
    end

    -- Drop target for always-send items.
    panel.drop = CreateFrame("Button", nil, body, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel.drop:SetSize(120, 26)
    panel.drop:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -114)
    if panel.drop.SetBackdrop then
        panel.drop:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
        panel.drop:SetBackdropBorderColor(1, 0.82, 0, 1)
    end
    local dropText = panel.drop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dropText:SetPoint("CENTER")
    dropText:SetText("Drop an item here")
    local function TakeCursorItem()
        local kind, itemID = GetCursorInfo()
        local tab = SelectedTab()
        if kind == "item" and itemID and tab then
            tab.custom[itemID] = true
            ClearCursor()
            UpdatePanel()
        end
    end
    panel.drop:SetScript("OnReceiveDrag", TakeCursorItem)
    panel.drop:SetScript("OnClick", TakeCursorItem)

    panel.auto = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
    panel.auto:SetSize(24, 24)
    panel.auto:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -146)
    local autoLabel = panel.auto.Text or panel.auto.text
    if not autoLabel then
        autoLabel = panel.auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        autoLabel:SetPoint("LEFT", panel.auto, "RIGHT", 2, 0)
    end
    autoLabel:SetText("Send automatically when I open the mailbox")
    panel.auto:SetScript("OnClick", function(self)
        local tab = SelectedTab()
        if tab then tab.auto = self:GetChecked() and true or false end
    end)

    panel.previewTitle = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.previewTitle:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -176)
    panel.previewTitle:SetText("Ready to send:")
    panel.preview = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.preview:SetPoint("TOPLEFT", panel.previewTitle, "BOTTOMLEFT", 0, -4)
    panel.preview:SetWidth(290)
    panel.preview:SetJustifyH("LEFT")

    panel.send = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.send:SetSize(200, 26)
    panel.send:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 4, 4)
    panel.send:SetScript("OnClick", function()
        local tab = SelectedTab()
        if not tab then return end
        local count, reason = SendBatch(tab, false)
        if not count and reason ~= "busy" then Print("Not sent: " .. reason .. ".") end
    end)

    panel.remove = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.remove:SetSize(80, 26)
    panel.remove:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 4)
    panel.remove:SetText("Remove")
    panel.remove:SetScript("OnClick", function()
        local tab = SelectedTab()
        if not tab then return end
        for i, t in ipairs(DB.tabs) do
            if t == tab then table.remove(DB.tabs, i) break end
        end
        UpdatePanel()
    end)

    panel:SetScript("OnShow", UpdatePanel)
end

-- Mailbox tab ------------------------------------------------------------------

local function ShowOneClick()
    if not panel then return end
    if InboxFrame then InboxFrame:Hide() end
    if SendMailFrame then SendMailFrame:Hide() end
    for i = 1, 2 do
        local t = _G["MailFrameTab" .. i]
        if t and PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(t) end
    end
    if PanelTemplates_SelectTab then PanelTemplates_SelectTab(mailTab) end
    panel:Show()
    UpdatePanel()
end

local function HideOneClick()
    if panel then panel:Hide() end
    if addMenu then addMenu:Hide() end
    if mailTab and PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(mailTab) end
end

local function CreateMailTab()
    if mailTab or not MailFrameTab2 then return end
    local ok, tab = pcall(CreateFrame, "Button", "OneClickMailTab", MailFrame, "CharacterFrameTabButtonTemplate")
    if not ok then
        ok, tab = pcall(CreateFrame, "Button", "OneClickMailTab", MailFrame, "PanelTabButtonTemplate")
    end
    if not ok then return end
    mailTab = tab
    tab:SetText("One Click")
    tab:SetPoint("LEFT", MailFrameTab2, "RIGHT", -16, 0)
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
    if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(tab) end
    tab:SetScript("OnClick", ShowOneClick)
    if MailFrameTab_OnClick then hooksecurefunc("MailFrameTab_OnClick", HideOneClick) end
end

-- Events -----------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("MAIL_SHOW")
events:RegisterEvent("MAIL_CLOSED")
events:RegisterEvent("MAIL_SEND_SUCCESS")
events:RegisterEvent("MAIL_FAILED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("ADDON_ACTION_BLOCKED")

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        OneClickMailDB = OneClickMailDB or {}
        DB = OneClickMailDB
        DB.chars = DB.chars or {}
        DB.tabs = DB.tabs or {}
        return
    end
    if not DB then return end
    if event == "PLAYER_ENTERING_WORLD" then
        RememberMe()
    elseif event == "MAIL_SHOW" then
        RememberMe()
        CreatePanel()
        CreateMailTab()
        StartAuto()
    elseif event == "MAIL_CLOSED" then
        HideOneClick()
        autoQueue = nil
        sending = nil
    elseif event == "MAIL_SEND_SUCCESS" then
        if sending then
            local alt = DB.chars[sending.key]
            Print(("Sent %d item%s to %s."):format(sending.count, sending.count == 1 and "" or "s",
                alt and alt.name or sending.key))
            local auto = sending.auto
            sending = nil
            if auto then C_Timer.After(1, ContinueAuto) end
        end
        UpdatePanel()
    elseif event == "MAIL_FAILED" then
        if sending then
            Print("The mail failed. Nothing was lost; the items are back in your bags.")
            sending = nil
            autoQueue = nil
            if ClearSendMail then ClearSendMail() end
        end
        UpdatePanel()
    elseif event == "BAG_UPDATE_DELAYED" then
        UpdatePanel()
    elseif event == "ADDON_ACTION_BLOCKED" then
        -- This client wants a click for each mail: stop sending on its own.
        if arg1 == ADDON and arg2 and tostring(arg2):find("SendMail") then
            DB.autoBlocked = true
            sending, autoQueue = nil, nil
            Print("This client needs a click for each mail, so automatic sending is off. Use the Send button.")
        end
    end
end)

SLASH_ONECLICKMAIL1 = "/ocm"
SlashCmdList.ONECLICKMAIL = function(input)
    local cmd = strlower(strtrim(input or ""))
    if cmd == "alts" then
        for key, alt in pairs(DB.chars) do
            Print(("%s: level %s %s, %s"):format(key, alt.level or "?", alt.class or "?", alt.faction or "?"))
        end
    elseif cmd == "forget" then
        Print("Type /ocm forget Name-Realm to remove a character.")
    elseif cmd:match("^forget ") then
        local key = strtrim(strtrim(input):sub(8))
        if DB.chars[key] then
            DB.chars[key] = nil
            for i = #DB.tabs, 1, -1 do if DB.tabs[i].key == key then table.remove(DB.tabs, i) end end
            Print("Forgot " .. key .. ".")
        else
            Print("No saved character named " .. key .. ". Type /ocm alts to see the list.")
        end
    elseif cmd == "auto on" then
        DB.autoBlocked = nil
        Print("Automatic sending allowed again.")
    else
        Print("Open a mailbox and click the One Click tab. /ocm alts lists your saved characters, "
            .. "/ocm forget Name-Realm removes one.")
    end
end
