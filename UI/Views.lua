-- ForeverNotes views: host-independent screens built from Kit widgets. A host (options window page, EUI page, mini window)
-- passes an empty frame; the view fills it and keeps itself in sync with the store.
-- Notebook and Players share one tree view: headers (groups / players) with their notes below, editor on the right.
local _, ns = ...
local L = ns.L
local Store, Kit, Editor = ns.Store, ns.Kit, ns.Editor

local Views = {}
ns.Views = Views

local LIST_W, ROW_H, BAR_H, GAP = 220, 22, 28, 12
local NONE = "_none" -- id of the pseudo group for notes without a group

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Empty frame for a view inside an EUI page. ctx "eui" makes every Kit widget below use the EllesmereUI look.
function Views.Host(parent, y, height, ctx)
    local pad = type(EllesmereUI) == "table" and EllesmereUI.CONTENT_PAD or 45
    local host = CreateFrame("Frame", nil, parent)
    host.fnCtx = ctx or "eui"
    host:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)
    host:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -pad, y)
    host:SetHeight(height)
    return host
end

-- Empty frame filling parent, for a view in one of our own windows (inherits the window's theme context).
function Views.FillHost(parent)
    local host = CreateFrame("Frame", nil, parent)
    host:SetAllPoints()
    return host
end

local function IdNum(id) return tonumber(tostring(id):match("%d+")) or 0 end

-- Oldest first: a note keeps its place in the tree while it is being edited (the store sorts by last change).
local function ByCreated(ids)
    local notes = ns.db.notes
    table.sort(ids, function(a, b)
        local ca, cb = notes[a].created or 0, notes[b].created or 0
        if ca ~= cb then return ca < cb end
        return IdNum(a) < IdNum(b)
    end)
    return ids
end

local function Stamp(t, short)
    if not t or t == 0 then return "-" end
    if ns.locale == "deDE" then return date(short and "%d.%m.%y" or "%d.%m.%Y %H:%M", t) end
    return date(short and "%y-%m-%d" or "%Y-%m-%d %H:%M", t)
end
Views.Stamp = Stamp

-- "5 min ago", "3 h ago", "2 d ago", else the date; "-" when never.
function Views.Ago(t)
    if not t or t == 0 then return "-" end
    local seconds = time() - t
    if seconds < 90 then return L["just now"] end
    if seconds < 3600 then return L["%d min ago"]:format(math.floor(seconds / 60 + 0.5)) end
    if seconds < 86400 then return L["%d h ago"]:format(math.floor(seconds / 3600 + 0.5)) end
    if seconds < 7 * 86400 then return L["%d d ago"]:format(math.floor(seconds / 86400 + 0.5)) end
    return Stamp(t, true)
end

local function CountText(n, kind)
    if kind == "drawing" then return n == 1 and L["1 drawing"] or L["%d drawings"]:format(n) end
    return n == 1 and L["1 note"] or L["%d notes"]:format(n)
end

-- A just-created note nobody wrote into.
local function IsBlank(note)
    if not note or (note.title or "") ~= "" then return false end
    if note.kind == "drawing" then return #note.drawing.strokes == 0 end
    return (note.text or "") == ""
end

local function SameColor(a, b)
    return a and b and math.abs(a[1] - b[1]) < 0.001 and math.abs(a[2] - b[2]) < 0.001 and math.abs(a[3] - b[3]) < 0.001
end

---------------------------------------------------------------------------
-- Tree view
---------------------------------------------------------------------------

-- cfg:
--   kinds        set of store change kinds that matter, e.g. { group = true, note = true }
--   emptyText    shown in the tree when there are no headers
--   headers()    ordered list of { id, label, color = {r,g,b}|nil, notes = { nid, ... }, virtual = bool, player = entry }
--   buildHead(view, panel) -> fill(header)   right-hand panel for a selected header
--   buildBar(view, bar)                      buttons along the bottom
--   moveMenu(view, button)                   optional: opens a menu to move the selected note (shows a button)
--   moveLabel(note) -> text                  label of that button
local function TreeView(host, cfg)
    local v = { host = host, items = {}, collapsed = {}, fresh = {}, noteHeader = {}, headers = {}, kind = cfg.kind or "text" }

    -- tree ------------------------------------------------------------------
    local side = Kit.Panel(host, "bgAlt", "border", "panel")
    side:SetPoint("TOPLEFT")
    side:SetPoint("BOTTOMLEFT", 0, BAR_H + GAP)
    side:SetWidth(LIST_W)
    v.side = side

    v.list = Kit.ScrollList(side, ROW_H, {
        create = function(row)
            row.toggle = CreateFrame("Button", nil, row)
            row.toggle:SetSize(18, ROW_H)
            row.toggle:SetPoint("LEFT", 2, 0)
            row.arrow = Kit.Glyph(row.toggle, "right", 10, "textDim")
            row.arrow:SetPoint("CENTER")
            row.toggle:SetScript("OnClick", function()
                local item = row.item
                if item and item.kind == "header" then
                    v.collapsed[item.id] = not v.collapsed[item.id] or nil
                    v:Refresh()
                end
            end)
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetSize(8, 8)
            row.dot:SetPoint("LEFT", 22, 0)
            row.text = Kit.Text(row, 12)
            row.text:SetWordWrap(false)
            row.meta = Kit.Text(row, 10, "textDim")
            row.meta:SetPoint("RIGHT", -6, 0)
        end,
        update = function(row, item)
            row.text:ClearAllPoints()
            if item.kind == "header" then
                local h = item.h
                row.toggle:Show()
                row.arrow:SetKind(v.collapsed[h.id] and "right" or "down")
                if h.color then
                    row.dot:SetColorTexture(h.color[1], h.color[2], h.color[3], 1)
                    row.dot:Show()
                else
                    row.dot:Hide()
                end
                row.text:SetPoint("LEFT", 36, 0)
                row.text:SetPoint("RIGHT", -34, 0)
                row.text:SetText(h.label)
                row.meta:SetText(tostring(#h.notes))
            else
                local note = Store.GetNote(item.id)
                row.toggle:Hide()
                row.dot:Hide()
                row.text:SetPoint("LEFT", 30, 0)
                row.text:SetPoint("RIGHT", -64, 0)
                row.text:SetText(Store.NoteTitle(note))
                row.meta:SetText(note and Stamp(note.updated, true) or "")
            end
        end,
        onClick = function(_, item)
            v:Select(item.kind, item.id)
        end,
        isSelected = function(item)
            local sel = v.sel
            return sel ~= nil and sel.kind == item.kind and sel.id == item.id
        end,
    })
    v.list:SetPoint("TOPLEFT", 4, -4)
    v.list:SetPoint("BOTTOMRIGHT", -4, 4)
    v.empty = Kit.Hint(side, cfg.emptyText)

    -- right side: editor for a note, panel for a header, or a hint -----------
    local right = CreateFrame("Frame", nil, host)
    right:SetPoint("TOPLEFT", LIST_W + GAP, 0)
    right:SetPoint("BOTTOMRIGHT", 0, BAR_H + GAP)
    v.hint = Kit.Hint(right, L["Select an entry on the left or create a new one."])

    local np = CreateFrame("Frame", nil, right)
    np:SetAllPoints()
    np:Hide()
    v.noteP = np
    local del = Kit.ConfirmButton(np, 76, L["Delete"], function() v:DeleteSelectedNote() end, 26)
    del:SetPoint("TOPRIGHT")
    local leftmost = del
    if cfg.moveMenu then
        v.move = Kit.Button(np, 140, "", function(button) cfg.moveMenu(v, button) end, 26)
        v.move:SetPoint("TOPRIGHT", del, "TOPLEFT", -6, 0)
        leftmost = v.move
    end
    v.stickyBtn = Kit.Button(np, 76, L["Sticky"], function()
        local sel = v.sel
        if sel and sel.kind == "note" and ns.Stickies then ns.Stickies.Toggle(sel.id) end
    end, 26)
    v.stickyBtn:SetPoint("TOPRIGHT", leftmost, "TOPLEFT", -6, 0)
    Kit.Tooltip(v.stickyBtn, { L["Sticky note"], L["Puts this note on the screen as a small window."] }, "ANCHOR_TOP")
    leftmost = v.stickyBtn
    v.title = Kit.EditBox(np, 100, 26, { placeholder = L["Title"], maxLetters = 80, size = 14,
        onChange = function(text, userInput)
            local sel = v.sel
            if userInput and sel and sel.kind == "note" then Store.UpdateNote(sel.id, { title = text }) end
        end })
    v.meta = Kit.Text(np, 11, "textDim")
    v.meta:SetWordWrap(false)
    v.ed = cfg.makeBody and cfg.makeBody(np) or Editor.Create(np, { toolbar = true, framed = true, size = 13,
        hint = L["Click to write.  [ ] makes a checkbox, - a list, 1. a numbered list."] })

    -- Wide: title and buttons in one line. Narrow (small windows): title alone, buttons on the meta line below.
    local function LayoutNote(narrow)
        if v.narrow == narrow then return end
        v.narrow = narrow
        v.title:ClearAllPoints()
        v.meta:ClearAllPoints()
        v.ed:ClearAllPoints()
        del:ClearAllPoints()
        v.title:SetPoint("TOPLEFT")
        if narrow then
            v.title:SetPoint("TOPRIGHT")
            del:SetPoint("TOPRIGHT", 0, -32)
            v.meta:SetPoint("LEFT", np, "TOPLEFT", 2, -45)
            v.meta:SetPoint("RIGHT", leftmost, "LEFT", -8, 0)
            v.ed:SetPoint("TOPLEFT", 0, -64)
        else
            v.title:SetPoint("TOPRIGHT", leftmost, "TOPLEFT", -8, 0)
            del:SetPoint("TOPRIGHT")
            v.meta:SetPoint("TOPLEFT", 2, -32)
            v.meta:SetPoint("TOPRIGHT", -2, -32)
            v.ed:SetPoint("TOPLEFT", 0, -52)
        end
        v.ed:SetPoint("BOTTOMRIGHT")
    end
    LayoutNote(false)

    v.headP = CreateFrame("Frame", nil, right)
    v.headP:SetAllPoints()
    v.headP:Hide()
    v.fillHead = cfg.buildHead(v, v.headP)

    local bar = CreateFrame("Frame", nil, host)
    bar:SetPoint("BOTTOMLEFT")
    bar:SetPoint("BOTTOMRIGHT")
    bar:SetHeight(BAR_H)
    cfg.buildBar(v, bar)

    -- The same view sits in EUI's wide panel and in the resizable options window: fit tree width and note header.
    host:HookScript("OnSizeChanged", function(self, w)
        w = w or self:GetWidth()
        if not w or w <= 0 then return end
        local listW = math.max(170, math.min(LIST_W, math.floor(w * 0.34)))
        side:SetWidth(listW)
        right:SetPoint("TOPLEFT", listW + GAP, 0)
        LayoutNote(w - listW - GAP < 470)
    end)

    -- data ------------------------------------------------------------------
    function v:Rebuild()
        self.headers = cfg.headers()
        wipe(self.items)
        wipe(self.noteHeader)
        for _, h in ipairs(self.headers) do
            self.items[#self.items + 1] = { kind = "header", h = h, id = h.id }
            for _, nid in ipairs(h.notes) do self.noteHeader[nid] = h end
            if not self.collapsed[h.id] then
                for _, nid in ipairs(h.notes) do
                    self.items[#self.items + 1] = { kind = "note", h = h, id = nid }
                end
            end
        end
    end

    function v:HeaderById(id)
        for _, h in ipairs(self.headers) do
            if h.id == id then return h end
        end
    end

    function v:SelIndex()
        local sel = self.sel
        if not sel then return nil end
        for i, item in ipairs(self.items) do
            if item.kind == sel.kind and item.id == sel.id then return i end
        end
    end

    function v:ShowSelection()
        local sel = self.sel
        local note = sel and sel.kind == "note" and Store.GetNote(sel.id) or nil
        if note then
            self.hint:Hide()
            self.headP:Hide()
            self.noteP:Show()
            if not self.title.edit:HasFocus() then self.title:SetText(note.title or "") end
            self.meta:SetText(L["Created %s, updated %s"]:format(Stamp(note.created), Stamp(note.updated)))
            if self.move then self.move:SetLabel(cfg.moveLabel(note)) end
            self.stickyBtn:SetVariant(ns.Stickies and ns.Stickies.IsOpen(sel.id) and "primary" or "normal")
            if self.shownNid ~= sel.id then
                self.shownNid = sel.id
                self.ed:SetNote(sel.id)
            end
            return
        end
        if self.shownNid then
            self.shownNid = nil
            self.ed:SetNote(nil)
        end
        self.noteP:Hide()
        local header = sel and sel.kind == "header" and self:HeaderById(sel.id) or nil
        if header then
            self.hint:Hide()
            self.headP:Show()
            self.fillHead(header)
        else
            self.headP:Hide()
            self.hint:Show()
        end
    end

    -- Redraw from the store; a selection that no longer exists is dropped.
    function v:Refresh()
        self:Rebuild()
        local sel = self.sel
        if sel then
            local exists
            if sel.kind == "note" then
                exists = Store.GetNote(sel.id) ~= nil and self.noteHeader[sel.id] ~= nil
            else
                exists = self:HeaderById(sel.id) ~= nil
            end
            if not exists then self.sel = nil end
        end
        self.list:SetItems(self.items)
        self.empty:SetShown(#self.items == 0)
        self:ShowSelection()
    end

    -- An empty note that was just created and abandoned would only clutter the list.
    function v:DiscardFresh(keepId)
        local sel = self.sel
        if not (sel and sel.kind == "note" and sel.id ~= keepId and self.fresh[sel.id]) then return end
        self.fresh[sel.id] = nil
        local note = Store.GetNote(sel.id)
        if IsBlank(note) then
            self.busy = true
            Store.DeleteNote(sel.id)
            self.busy = false
            self.dirty = true
        end
    end

    function v:Select(kind, id)
        self.title:ClearFocus()
        self.ed:Flush()
        self:Rebuild()
        self:DiscardFresh(kind == "note" and id or nil)
        self.sel = kind and { kind = kind, id = id } or nil
        if kind == "note" then
            local h = self.noteHeader[id]
            if h then self.collapsed[h.id] = nil end
        elseif kind == "header" then
            self.collapsed[id] = nil
        end
        self:Refresh()
        local index = self:SelIndex()
        if index then self.list:ScrollTo(index) end
    end

    -- create() returns the id of a new note; it is selected and ready for typing.
    function v:AddNote(create)
        local nid = create()
        if not nid then return end
        self.fresh[nid] = true
        self:Select("note", nid)
        if self.ed.Edit then self.ed:Edit() end
    end

    function v:DeleteSelectedNote()
        local sel = self.sel
        if not (sel and sel.kind == "note") then return end
        local index = self:SelIndex() or 1
        self.fresh[sel.id] = nil
        self.busy = true
        Store.DeleteNote(sel.id)
        self.busy = false
        self.sel = nil
        self:Rebuild()
        local item = self.items[math.min(index, #self.items)]
        if item then self:Select(item.kind, item.id) else self:Select(nil) end
    end

    Store.OnChanged(function(kind)
        if v.busy or not cfg.kinds[kind] then return end
        if host:IsVisible() then v:Refresh() else v.dirty = true end
    end)
    host:SetScript("OnShow", function()
        if v.dirty then
            v.dirty = false
            v:Refresh()
        end
    end)
    host:SetScript("OnHide", function()
        v.ed:Flush()
        v:DiscardFresh(nil)
    end)

    v:Refresh()
    return v
end

---------------------------------------------------------------------------
-- Notebook: groups with text notes
---------------------------------------------------------------------------

local function NotebookHeaders(kind)
    local list = {}
    local loose = ByCreated(Store.ListNotes({ kind = kind, ungrouped = true }))
    if #loose > 0 then
        list[#list + 1] = { id = NONE, label = L["Ungrouped"], virtual = true, notes = loose }
    end
    for _, group in ipairs(Store.ListGroups()) do
        list[#list + 1] = { id = group.id, label = group.name, color = group.color,
            notes = ByCreated(Store.ListNotes({ kind = kind, group = group.id })) }
    end
    return list
end
Views.NotebookHeaders = NotebookHeaders -- also used by the export list

local function NewNoteInContext(v)
    local sel, gid = v.sel, nil
    if sel and sel.kind == "header" and sel.id ~= NONE then
        gid = sel.id
    elseif sel and sel.kind == "note" then
        local note = Store.GetNote(sel.id)
        gid = note and note.group
    end
    v:AddNote(function() return Store.CreateNote({ kind = v.kind, group = gid }) end)
end

local function BuildGroupPanel(v, panel)
    local drawing = v.kind == "drawing"
    local heading = Kit.Text(panel, 16, "header")
    heading:SetPoint("TOPLEFT", 2, -4)
    heading:SetText(L["Ungrouped"])
    local hintText = Kit.Text(panel, 12, "textDim")
    hintText:SetPoint("TOPLEFT", 2, -34)
    hintText:SetPoint("TOPRIGHT", -2, -34)
    hintText:SetJustifyV("TOP")
    hintText:SetText(drawing and L["Drawings without a group appear here. Pick a group from the button above a drawing to file it."]
        or L["Notes without a group appear here. Pick a group from the button above a note to file it."])

    local name = Kit.EditBox(panel, 100, 26, { placeholder = L["Group name"], maxLetters = 40, size = 14,
        onChange = function(text, userInput)
            local sel = v.sel
            if userInput and sel and sel.kind == "header" and sel.id ~= NONE then Store.RenameGroup(sel.id, text) end
        end })
    name:SetPoint("TOPLEFT")
    name:SetPoint("TOPRIGHT")
    v.groupName = name

    local colorLabel = Kit.Text(panel, 12, "textDim")
    colorLabel:SetPoint("TOPLEFT", 2, -40)
    colorLabel:SetText(L["Color"])
    local swatches = {}
    for i, color in ipairs(Store.GROUP_COLORS) do
        swatches[i] = Kit.Swatch(panel, 22, color, function()
            local sel = v.sel
            if sel and sel.kind == "header" and sel.id ~= NONE then Store.SetGroupColor(sel.id, color) end
        end)
        swatches[i]:SetPoint("TOPLEFT", (i - 1) * 26, -60)
    end

    local newNote = Kit.Button(panel, 190, drawing and L["New drawing in this group"] or L["New note in this group"],
        function() NewNoteInContext(v) end, 26, "primary")
    newNote:SetPoint("TOPLEFT", 0, -100)
    local up = Kit.Button(panel, 90, L["Move up"], function()
        if v.sel then Store.MoveGroup(v.sel.id, -1) end
    end, 26)
    up:SetPoint("LEFT", newNote, "RIGHT", 8, 0)
    local down = Kit.Button(panel, 90, L["Move down"], function()
        if v.sel then Store.MoveGroup(v.sel.id, 1) end
    end, 26)
    down:SetPoint("LEFT", up, "RIGHT", 6, 0)
    local keep = Kit.ConfirmButton(panel, 190, L["Delete group, keep notes"], function()
        if v.sel then Store.DeleteGroup(v.sel.id, false) end
    end, 26)
    keep:SetPoint("TOPLEFT", 0, -140)
    local wipeAll = Kit.ConfirmButton(panel, 190, L["Delete group and notes"], function()
        if v.sel then Store.DeleteGroup(v.sel.id, true) end
    end, 26)
    wipeAll:SetPoint("LEFT", keep, "RIGHT", 8, 0)
    local count = Kit.Text(panel, 12, "textDim")
    count:SetPoint("TOPLEFT", 2, -180)

    local groupOnly = { name, colorLabel, up, down, keep, wipeAll }
    for _, swatch in ipairs(swatches) do groupOnly[#groupOnly + 1] = swatch end

    return function(h)
        local virtual = h.virtual and true or false
        heading:SetShown(virtual)
        hintText:SetShown(virtual)
        for _, widget in ipairs(groupOnly) do widget:SetShown(not virtual) end
        if drawing then
            newNote:SetLabel(virtual and L["New drawing"] or L["New drawing in this group"])
        else
            newNote:SetLabel(virtual and L["New note"] or L["New note in this group"])
        end
        count:SetText(CountText(#h.notes, v.kind))
        count:ClearAllPoints()
        count:SetPoint("TOPLEFT", 2, virtual and -140 or -180)
        if not virtual then
            if not name.edit:HasFocus() then name:SetText(h.label) end
            for i, swatch in ipairs(swatches) do swatch:SetSelected(SameColor(swatch.color, h.color)) end
        end
    end
end

local function GroupMenu(v, button)
    local sel = v.sel
    local note = sel and Store.GetNote(sel.id)
    if not note then return end
    local items = {}
    for _, group in ipairs(Store.ListGroups()) do
        items[#items + 1] = { text = group.name, color = group.color, checked = note.group == group.id,
            func = function()
                v.collapsed[group.id] = nil
                Store.UpdateNote(sel.id, { group = group.id })
            end }
    end
    items[#items + 1] = { text = L["No group"], checked = note.group == nil,
        func = function() Store.UpdateNote(sel.id, { group = false }) end }
    Kit.OpenMenu(button, items)
end

local function GroupedView(host, kind)
    local drawing = kind == "drawing"
    return TreeView(host, {
        kind = kind,
        kinds = { group = true, note = true, sticky = true },
        emptyText = drawing and L["No drawings yet. Create one with the buttons below."]
            or L["No notes yet. Create one with the buttons below."],
        headers = function() return NotebookHeaders(kind) end,
        makeBody = drawing and function(panel)
            local canvas = ns.Canvas.Create(panel)
            return canvas
        end or nil,
        buildHead = BuildGroupPanel,
        moveMenu = GroupMenu,
        moveLabel = function(note)
            local group = Store.GetGroup(note.group)
            return group and group.name or L["No group"]
        end,
        buildBar = function(v, bar)
            local newNote = Kit.Button(bar, 120, drawing and L["New drawing"] or L["New note"],
                function() NewNoteInContext(v) end, 26, "primary")
            newNote:SetPoint("LEFT")
            local newGroup = Kit.Button(bar, 110, L["New group"], function()
                local gid = Store.CreateGroup(L["New group"])
                v:Select("header", gid)
                v.groupName:SetFocus()
            end, 26)
            newGroup:SetPoint("LEFT", newNote, "RIGHT", 6, 0)
        end,
    })
end

function Views.Notebook(host) return GroupedView(host, "text") end

function Views.Drawings(host) return GroupedView(host, "drawing") end

---------------------------------------------------------------------------
-- Players: notes about players
---------------------------------------------------------------------------

local function PlayerHeaders()
    local list = {}
    for _, player in ipairs(Store.ListPlayers()) do
        local r, g, b = Store.ClassColor(player.class)
        list[#list + 1] = { id = player.key, label = Store.PlayerLabel(player.key), color = { r, g, b },
            notes = ByCreated(Store.PlayerNotes(player.key)), player = player }
    end
    return list
end
Views.PlayerHeaders = PlayerHeaders

local function BuildPlayerPanel(v, panel)
    local name = Kit.Text(panel, 18, false)
    name:SetPoint("TOPLEFT", 2, -4)
    local info = Kit.Text(panel, 12, "textDim")
    info:SetPoint("TOPLEFT", 2, -34)
    local newNote = Kit.Button(panel, 150, L["New note"], function()
        local sel = v.sel
        if sel and sel.kind == "header" then
            v:AddNote(function() return Store.CreatePlayerNote(sel.id) end)
        end
    end, 26, "primary")
    newNote:SetPoint("TOPLEFT", 0, -64)
    local deleteAll = Kit.ConfirmButton(panel, 190, L["Delete all notes"], function()
        local sel = v.sel
        if not (sel and sel.kind == "header") then return end
        for _, nid in ipairs(Store.PlayerNotes(sel.id)) do Store.DeleteNote(nid, true) end
        Store.Changed("note")
        Store.Changed("player", sel.id)
    end, 26)
    deleteAll:SetPoint("LEFT", newNote, "RIGHT", 8, 0)

    return function(h)
        name:SetText(h.label)
        name:SetTextColor(Store.ClassColor(h.player and h.player.class))
        local parts = { CountText(#h.notes) }
        if h.player and h.player.realm and h.player.realm ~= "" then parts[#parts + 1] = h.player.realm end
        local seen = h.player and h.player.seen or 0
        parts[#parts + 1] = seen > 0 and L["Last seen %s"]:format(Views.Ago(seen)) or L["Not seen yet"]
        info:SetText(table.concat(parts, "  -  "))
    end
end

local function AddPlayer(v, text, info)
    local key, name, realm = Store.ParseName(text)
    if not key then
        ns.Say(L["Enter a player name."])
        return
    end
    if Store.GetPlayer(key) then
        v:Select("header", key)
        return
    end
    v:AddNote(function() return Store.CreatePlayerNote(key, info or { name = name, realm = realm }) end)
end

function Views.Players(host)
    return TreeView(host, {
        kinds = { player = true, note = true, sticky = true },
        emptyText = L["No player notes yet. Add a player below or target one in the world."],
        headers = PlayerHeaders,
        buildHead = BuildPlayerPanel,
        buildBar = function(v, bar)
            local input
            input = Kit.EditBox(bar, 170, 26, { placeholder = L["Name or Name-Realm"], maxLetters = 60,
                onEnter = function(text)
                    AddPlayer(v, text)
                    input:SetText("")
                end })
            input:SetPoint("LEFT")
            local add = Kit.Button(bar, 70, L["Add"], function()
                AddPlayer(v, input:GetText())
                input:SetText("")
            end, 26, "primary")
            add:SetPoint("LEFT", input, "RIGHT", 6, 0)
            local target = Kit.Button(bar, 80, L["Target"], function()
                local key, info = Store.TargetKey()
                if not key then
                    ns.Say(L["No player targeted."])
                    return
                end
                AddPlayer(v, key, info)
            end, 26)
            target:SetPoint("LEFT", add, "RIGHT", 6, 0)
        end,
    })
end
