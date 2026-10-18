-- ForeverNotes target popup: shows the notes of the targeted player. Movable, resizable, lockable, collapsible.
-- Collapsed (or without notes) it is a slim header bar; a pulsing strip at its bottom edge tells that notes exist.
-- An ignored target gets a red edge, a red strip and the reason (Features/Ignore.lua supplies the ignore list).
-- A plain, unprotected frame: shown and hidden in combat without restriction.
local _, ns = ...
local L = ns.L
local Store, Kit, Theme, Editor = ns.Store, ns.Kit, ns.Theme, ns.Editor

local Popup = {}
ns.Popup = Popup

local MIN_W, MIN_H = 230, 140
local NAV_H = 20
local win, ui
local state = {} -- key, info, nid (shown note), fresh (note created and not yet written), dismissed (key closed by the user)

local function Cfg() return ns.db.settings.popup end

local function DefaultGeometry()
    return { point = { "CENTER", "CENTER", 260, 120 }, w = 290, h = 200 }
end

local function IndexOf(list, value)
    for i = 1, #list do
        if list[i] == value then return i end
    end
end

local function InInstance()
    if type(IsInInstance) ~= "function" then return false end
    local inside = IsInInstance()
    if ns.IsSecret(inside) then return false end
    return inside and true or false
end

---------------------------------------------------------------------------
-- State helpers
---------------------------------------------------------------------------

-- An abandoned, still empty new note would only clutter the list.
local function DiscardFresh()
    local nid = state.fresh
    state.fresh = nil
    local note = nid and Store.GetNote(nid)
    if note and (note.title or "") == "" and (note.text or "") == "" then
        ui.busy = true
        Store.DeleteNote(nid)
        ui.busy = false
    end
end

local function HidePopup()
    if not win then return end
    ui.progHide = true
    win:Hide()
    ui.progHide = false
end

local function CollapsedHeight()
    local T = Theme.Get("user")
    return win.headerHeight + 2 * (T.inset or 1) + 2
end

---------------------------------------------------------------------------
-- Refresh: decide whether and how the popup shows
---------------------------------------------------------------------------

function Popup.Refresh()
    if not ns.db then return end
    local cfg = Cfg()
    local key, info = Store.TargetKey()
    if key ~= state.key then
        if ui and ui.ed then ui.ed:Flush() end
        if ui then DiscardFresh() end
        state.key, state.nid, state.dismissed = key, nil, nil
        if ui then ui.reason:Hide() end
    end
    state.info = info
    if not key or not cfg.enabled or state.dismissed == key
            or (cfg.hideInCombat and InCombatLockdown()) or (cfg.hideInInstance and InInstance()) then
        HidePopup()
        return
    end
    if not win then Popup.Create() end

    local notes = Store.PlayerNotes(key)
    local count = #notes
    if count > 0 then
        if not (state.nid and IndexOf(notes, state.nid)) then state.nid = notes[1] end
    else
        state.nid = nil
    end
    local ignored = Store.IsIgnored(key)
    local mark = ignored and ns.db.settings.ignore.markPopup and true or false
    local expanded = count > 0 and not cfg.collapsed
    local player = Store.GetPlayer(key)
    local class = player and player.class or (info and info.class) or (Store.GetIgnored(key) or {}).class

    win.title:SetText(Store.PlayerLabel(key))
    win.title:SetTextColor(Store.ClassColor(class))
    ui.collapse:SetShown(count > 0)
    ui.collapse:SetGlyph(cfg.collapsed and "down" or "up")
    ui.ignoreBtn:SetActive(ignored)
    ui.ignoreBtn:SetColorOverride(ignored and "danger" or nil)
    win.ignoredMark = mark
    Theme.Refresh(win)

    ui.nav:SetShown(expanded)
    ui.ed:SetShown(expanded)
    local entry = Store.GetIgnored(key)
    ui.ignoreLine:SetShown(expanded and mark)
    if mark then
        local reason = entry and entry.reason or ""
        ui.ignoreLine:SetText(reason ~= "" and L["Ignored: %s"]:format(reason) or L["Ignored"])
    end
    ui.ed:ClearAllPoints()
    ui.ed:SetPoint("TOPLEFT", ui.nav, "BOTTOMLEFT", 0, -4)
    ui.ed:SetPoint("BOTTOMRIGHT", win.content, "BOTTOMRIGHT")
    ui.nav:ClearAllPoints()
    ui.nav:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, (expanded and mark) and -16 or 0)
    ui.nav:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", 0, (expanded and mark) and -16 or 0)

    if expanded then
        local nid = state.nid
        local note = Store.GetNote(nid)
        local index = IndexOf(notes, nid) or 1
        ui.navLabel:SetText(("%d/%d  %s"):format(index, count, Store.NoteTitle(note)))
        ui.prev:SetAlpha(count > 1 and 1 or 0.35)
        ui.next:SetAlpha(count > 1 and 1 or 0.35)
        if ui.shownNid ~= nid then
            ui.shownNid = nid
            ui.ed:SetNote(nid)
        end
        win:SetHeight(math.max(MIN_H, cfg.geo.h or DefaultGeometry().h))
    else
        if ui.shownNid then
            ui.shownNid = nil
            ui.ed:SetNote(nil)
        end
        win:SetHeight(CollapsedHeight())
    end
    if win.grip then win.grip:SetShown(expanded and not win.locked) end

    if mark then
        ui.glow:SetColorKey("danger")
        ui.glow:Play()
    elseif count > 0 and not expanded and cfg.glow then
        ui.glow:SetColorKey("accent")
        ui.glow:Play()
    else
        ui.glow:Stop()
    end
    win:Show()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function Browse(step)
    local key = state.key
    local notes = key and Store.PlayerNotes(key) or {}
    if #notes < 2 then return end
    ui.ed:Flush()
    local i = IndexOf(notes, state.nid) or 1
    state.nid = notes[(i - 1 + step) % #notes + 1]
    Popup.Refresh()
end

function Popup.NewNote()
    local key, info = Store.TargetKey()
    if not key then
        ns.Say(L["Target a player first."])
        return
    end
    local cfg = Cfg()
    if ui then
        ui.ed:Flush()
        DiscardFresh()
    end
    local nid = Store.CreatePlayerNote(key, info)
    if not nid then return end
    state.fresh, state.nid, state.dismissed = nid, nid, nil
    cfg.collapsed = false
    Popup.Refresh()
    if win and win:IsShown() then
        ui.ed:Edit()
    else
        ns.Say(L["Note saved. Find it under Players."])
    end
end
ns.NewTargetNote = Popup.NewNote

function Popup.ToggleCollapsed()
    local cfg = Cfg()
    cfg.collapsed = not cfg.collapsed
    if ui then ui.ed:Flush() end
    Popup.Refresh()
end

local function AddIgnore(reason)
    local key = state.key
    if not key then return end
    local info = state.info or {}
    local player = Store.GetPlayer(key)
    if player then info = { name = player.name, realm = player.realm, class = player.class } end
    if ns.Ignore then
        ns.Ignore.Add(key, info, reason)
    else
        Store.AddIgnored(key, info, reason)
    end
end

function Popup.IgnoreClick()
    local key = state.key
    if not key then return end
    if Store.IsIgnored(key) then
        if ns.Ignore then ns.Ignore.Remove(key) else Store.RemoveIgnored(key) end
        ui.reason:Hide()
    elseif ui.reason:IsShown() then
        ui.reason:Hide()
    else
        ui.reasonInput:SetText("")
        ui.reason:Show()
        ui.reasonInput:SetFocus()
    end
end

-- Reset position and size (settings page button).
function Popup.ResetGeometry()
    local geo = Cfg().geo or {}
    for k in pairs(geo) do geo[k] = nil end
    for k, v in pairs(DefaultGeometry()) do geo[k] = v end
    Cfg().geo = geo
    if win then
        win.geo = geo
        win:ApplyGeometry()
    end
    Popup.Refresh()
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Popup.Create()
    local cfg = Cfg()
    cfg.geo = cfg.geo or DefaultGeometry()
    ui = {}
    local base = cfg.geo
    win = Kit.Window({
        name = "ForeverNotesPopup", escape = false, title = "", w = base.w or 290, h = base.h or 200,
        minW = MIN_W, minH = MIN_H, resizable = true, lockButton = true, geometry = base, dragAnywhere = false,
        onLock = function() if ui and ui.nav then Popup.Refresh() end end,
        onHide = function()
            if ui.ed then ui.ed:Flush() end
            if not ui.progHide and state.key then state.dismissed = state.key end
        end,
    })
    win.title.fnColor = nil -- the class color is set by hand
    -- Collapsed, the window is only a bar: remember the full height, not the bar's.
    local saveBase = win.SaveGeometry
    function win:SaveGeometry()
        local keepH = self.geo and self.geo.h
        saveBase(self)
        if self.geo and (Cfg().collapsed or self:GetHeight() < MIN_H - 1) and keepH then self.geo.h = keepH end
    end

    ui.collapse = win:AddTool("up", function() Popup.ToggleCollapsed() end, function()
        return Cfg().collapsed and L["Expand"] or L["Collapse"]
    end)
    ui.ignoreBtn = win:AddTool("ignore", function() Popup.IgnoreClick() end, function()
        local entry = state.key and Store.GetIgnored(state.key)
        if entry then
            return entry.reason ~= "" and L["Ignored: %s"]:format(entry.reason) or L["Ignored. Click to remove from the list."]
        end
        return L["Ignore this player"]
    end)
    ui.plusBtn = win:AddTool("plus", function() Popup.NewNote() end, L["New note for this player"])

    local content = win.content
    ui.ignoreLine = Kit.Text(content, 11, "danger")
    ui.ignoreLine:SetPoint("TOPLEFT", 2, 0)
    ui.ignoreLine:SetPoint("TOPRIGHT", -2, 0)
    ui.ignoreLine:SetWordWrap(false)

    ui.nav = CreateFrame("Frame", nil, content)
    ui.nav:SetHeight(NAV_H)
    ui.prev = Kit.IconButton(ui.nav, NAV_H, "left", function() Browse(-1) end, L["Previous note"])
    ui.prev:SetPoint("LEFT")
    ui.next = Kit.IconButton(ui.nav, NAV_H, "right", function() Browse(1) end, L["Next note"])
    ui.next:SetPoint("LEFT", ui.prev, "RIGHT", 2, 0)
    ui.del = Kit.ConfirmButton(ui.nav, 62, L["Delete"], function()
        local nid = state.nid
        if not nid then return end
        state.fresh = nil
        ui.shownNid = nil
        Store.DeleteNote(nid)
    end, NAV_H)
    ui.del:SetPoint("RIGHT")
    ui.navLabel = Kit.Text(ui.nav, 12)
    ui.navLabel:SetPoint("LEFT", ui.next, "RIGHT", 6, 0)
    ui.navLabel:SetPoint("RIGHT", ui.del, "LEFT", -6, 0)
    ui.navLabel:SetWordWrap(false)

    ui.ed = Editor.Create(content, { toolbar = true, framed = true, size = 12,
        hint = L["Click to write.  [ ] makes a checkbox, - a list, 1. a numbered list."] })

    -- strip along the bottom edge: notes exist (accent) or the player is ignored (red)
    ui.glow = Kit.Glow(win, { side = "BOTTOM", height = 12, colorKey = "accent" })

    -- the red edge for an ignored target (painted after the window's own look)
    Theme.Bind(win, function(self, T)
        if self.ignoredMark then Theme.Edge(self, T.danger) end
    end)

    -- reason prompt under the window
    ui.reason = Kit.Panel(win, "bgAlt", "border", "panel")
    ui.reason:SetPoint("TOPLEFT", win, "BOTTOMLEFT", 0, -4)
    ui.reason:SetPoint("TOPRIGHT", win, "BOTTOMRIGHT", 0, -4)
    ui.reason:SetHeight(64)
    ui.reason:Hide()
    local ask = Kit.Text(ui.reason, 11, "textDim")
    ask:SetPoint("TOPLEFT", 8, -6)
    ask:SetText(L["Reason (optional)"])
    ui.reasonInput = Kit.EditBox(ui.reason, 100, 22, { maxLetters = 120,
        onEnter = function(text)
            AddIgnore(text)
            ui.reason:Hide()
        end })
    ui.reasonInput:SetPoint("TOPLEFT", 8, -22)
    ui.reasonInput:SetPoint("TOPRIGHT", -150, -22)
    local confirm = Kit.Button(ui.reason, 64, L["Ignore"], function()
        AddIgnore(ui.reasonInput:GetText())
        ui.reason:Hide()
    end, 22, "danger")
    confirm:SetPoint("LEFT", ui.reasonInput, "RIGHT", 6, 0)
    local cancel = Kit.Button(ui.reason, 70, L["Cancel"], function() ui.reason:Hide() end, 22)
    cancel:SetPoint("LEFT", confirm, "RIGHT", 6, 0)

    return win
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

ns.OnReady(function()
    local events = CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
            "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA" }) do
        events:RegisterEvent(event)
    end
    events:SetScript("OnEvent", function() Popup.Refresh() end)
    Store.OnChanged(function(kind)
        if (kind == "note" or kind == "player" or kind == "ignore") and not (ui and ui.busy) then Popup.Refresh() end
    end)
    Theme.OnChange(function() if win and win:IsShown() then Popup.Refresh() end end)
end)
