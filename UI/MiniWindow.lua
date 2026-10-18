-- ForeverNotes mini window: a small free-floating notebook (tabs Notes / Players / Drawings / Ignore).
-- List -> click opens the editor; a back arrow returns. A plain, unprotected frame: usable in combat.
local _, ns = ...
local L = ns.L
local Store, Kit, Editor, Theme = ns.Store, ns.Kit, ns.Editor, ns.Theme

local Mini = {}
ns.Mini = Mini

local ROW_H = 24
local win, ui, ctx

local function Settings() return ns.db.settings.mini end

---------------------------------------------------------------------------
-- List contents per tab
---------------------------------------------------------------------------

-- Notes and drawings are shown under their group (a header row with color and count); notes without a group first.
local function NoteItems(kind)
    local items = {}
    local function Section(id, label, color, ids)
        if #ids == 0 then return end
        items[#items + 1] = { kind = "header", id = id, label = label, color = color, count = #ids }
        if ctx.collapsed[id] then return end
        for i, nid in ipairs(ids) do items[#items + 1] = { kind = "note", id = nid, stripe = i % 2 == 0 } end
    end
    Section("_none", L["Ungrouped"], nil, Store.ListNotes({ kind = kind, ungrouped = true }))
    for _, group in ipairs(Store.ListGroups()) do
        Section(group.id, group.name, group.color, Store.ListNotes({ kind = kind, group = group.id }))
    end
    return items
end

-- Total entries of a list (collapsed groups included).
local function CountEntries(items)
    local n, grouped = 0, false
    for _, item in ipairs(items) do
        if item.kind == "header" then
            grouped = true
            n = n + item.count
        end
    end
    return grouped and n or #items
end

local function PlayerItems()
    local items = {}
    for i, player in ipairs(Store.ListPlayers()) do
        items[#items + 1] = { kind = "player", id = player.key, player = player, stripe = i % 2 == 0 }
    end
    return items
end

local function PlayerNoteItems(key)
    local items = {}
    for i, nid in ipairs(Store.PlayerNotes(key)) do items[#items + 1] = { kind = "note", id = nid, stripe = i % 2 == 0 } end
    return items
end

local function CurrentItems()
    if ctx.tab == "notes" then return NoteItems("text") end
    if ctx.tab == "drawings" then return NoteItems("drawing") end
    if ctx.player then return PlayerNoteItems(ctx.player) end
    return PlayerItems()
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

-- An abandoned, still empty new text note would only clutter the list.
local function DiscardFresh()
    local nid = ctx.fresh
    ctx.fresh = nil
    local note = nid and Store.GetNote(nid)
    local blank = note and (note.title or "") == ""
        and (note.kind == "drawing" and #note.drawing.strokes == 0 or note.kind == "text" and (note.text or "") == "")
    if blank then
        ui.busy = true
        Store.DeleteNote(nid)
        ui.busy = false
    end
end

local function LeaveDetail()
    if ui.ed then ui.ed:Flush() end
    DiscardFresh()
    ctx.nid = nil
end

function Mini.Refresh()
    if not (win and win:IsShown()) then return end
    local note = ctx.nid and Store.GetNote(ctx.nid)
    if ctx.nid and not note then ctx.nid = nil end
    if ctx.player and not Store.GetPlayer(ctx.player) then ctx.player = nil end

    ui.tabs:Select(ctx.tab, true)
    local ignoreTab = ctx.tab == "ignore"
    ui.ignorePane:SetShown(ignoreTab)
    ui.listPane:SetShown(not ignoreTab and not note)
    ui.detail:SetShown(not ignoreTab and note ~= nil)
    if ignoreTab then
        if ui.ignoreView and ui.ignoreView.Refresh then ui.ignoreView:Refresh() end
        return
    end

    if note then
        if not ui.title.edit:HasFocus() then ui.title:SetText(note.title or "") end
        -- where this entry lives: tab > group or player
        local tabName = note.player and L["Players"] or note.kind == "drawing" and L["Drawings"] or L["Notes"]
        local group = Store.GetGroup(note.group)
        local place = note.player and Store.PlayerLabel(note.player) or group and group.name or L["Ungrouped"]
        ui.crumb:SetText(tabName .. "  >  " .. place)
        ui.groupBtn:SetShown(not note.player)
        if not note.player then ui.groupBtn:SetLabel(group and group.name or L["No group"]) end
        if note.kind == "text" then
            ui.canvasHolder:Hide()
            ui.ed:Show()
            if ui.shownNid ~= ctx.nid then
                ui.shownNid = ctx.nid
                ui.ed:SetNote(ctx.nid)
            end
        else
            ui.ed:Hide()
            if ui.shownNid then
                ui.shownNid = nil
                ui.ed:SetNote(nil)
            end
            ui.canvasHolder:Show()
            if not ui.canvas and ns.Canvas then
                ui.canvas = ns.Canvas.Create(ui.canvasHolder, { compact = true })
                ui.canvas:SetAllPoints()
            end
            ui.canvasHint:SetShown(ui.canvas == nil)
            if ui.canvas and ui.shownCanvas ~= ctx.nid then
                ui.shownCanvas = ctx.nid
                ui.canvas:SetNote(ctx.nid)
            end
        end
        return
    end

    -- list
    if ui.shownNid then
        ui.shownNid = nil
        ui.ed:SetNote(nil)
    end
    local topPlayers = ctx.tab == "players" and not ctx.player
    ui.back:SetShown(ctx.player ~= nil)
    ui.input:SetShown(topPlayers)
    ui.heading:SetShown(not topPlayers)
    ui.heading:ClearAllPoints()
    ui.heading:SetPoint("RIGHT", ui.new, "LEFT", -6, 0)
    if ctx.player then
        ui.heading:SetPoint("LEFT", ui.back, "RIGHT", 6, 0)
        ui.heading:SetText(Store.PlayerLabel(ctx.player))
    else
        ui.heading:SetPoint("LEFT", ui.back, "LEFT", 2, 0) -- the back button is hidden but still marks the top row
        ui.heading:SetText(ctx.tab == "drawings" and L["Drawings"] or L["Notes"])
    end
    local items = CurrentItems()
    local total = CountEntries(items)
    local base = ctx.player and Store.PlayerLabel(ctx.player)
        or ctx.tab == "drawings" and L["Drawings"] or ctx.tab == "players" and L["Players"] or L["Notes"]
    ui.heading:SetText(base .. "  (" .. total .. ")")
    ui.list:SetItems(items)
    ui.empty:SetShown(#items == 0)
    ui.empty:SetText(ctx.tab == "players" and not ctx.player and L["No player notes yet."]
        or L["Nothing here yet. Use + to create an entry."])
end

local function Open(nid)
    ctx.nid = nid
    Mini.Refresh()
end

function Mini.ShowTab(tab)
    if ctx.nid then LeaveDetail() end
    ctx.tab, ctx.player = tab, nil
    Settings().tab = tab
    Mini.Refresh()
end

function Mini.Back()
    if ctx.nid then
        LeaveDetail()
    elseif ctx.player then
        ctx.player = nil
    end
    Mini.Refresh()
end

function Mini.New()
    local nid
    if ctx.tab == "notes" then
        nid = Store.CreateNote({ kind = "text" })
    elseif ctx.tab == "drawings" then
        nid = Store.CreateNote({ kind = "drawing" })
    elseif ctx.tab == "players" then
        local key, info
        if ctx.player then
            key = ctx.player
        else
            local name, realm
            key, name, realm = Store.ParseName(ui.input:GetText())
            if not key then
                ns.Say(L["Enter a player name."])
                return
            end
            info = { name = name, realm = realm }
            ui.input:SetText("")
            ctx.player = key
        end
        nid = Store.CreatePlayerNote(key, info)
    end
    if not nid then return end
    ctx.fresh = nid
    Open(nid)
    if Store.GetNote(nid).kind == "text" then ui.ed:Edit() end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function Create()
    local mini = Settings()
    ctx = { tab = mini.tab or "notes", collapsed = {} }
    if ctx.tab ~= "notes" and ctx.tab ~= "players" and ctx.tab ~= "drawings" and ctx.tab ~= "ignore" then ctx.tab = "notes" end
    ui = {}
    win = Kit.Window({
        name = "ForeverNotesMini", title = "ForeverNotes", w = mini.w or 320, h = mini.h or 380, minW = 260, minH = 240,
        resizable = true, lockButton = true, geometry = mini,
        onShow = function()
            mini.shown = true
            Mini.Refresh()
        end,
        onHide = function()
            mini.shown = false
            if ui.ed then ui.ed:Flush() end
        end,
    })
    local content = win.content
    win:AddTool("expand", function() Mini.OpenInPanel() end, L["Open in the large window"])

    ui.tabs = Kit.Tabs(content, {
        { "notes", L["Notes"] }, { "players", L["Players"] }, { "drawings", L["Drawings"] }, { "ignore", L["Ignore"] },
    }, function(key) Mini.ShowTab(key) end, 24)
    ui.tabs:SetPoint("TOPLEFT")
    ui.tabs:SetPoint("TOPRIGHT")
    ui.tabs:Select(ctx.tab, true)

    local body = CreateFrame("Frame", nil, content)
    body:SetPoint("TOPLEFT", ui.tabs, "BOTTOMLEFT", 0, -6)
    body:SetPoint("BOTTOMRIGHT")

    -- list pane --------------------------------------------------------------
    local lp = CreateFrame("Frame", nil, body)
    lp:SetAllPoints()
    ui.listPane = lp
    ui.back = Kit.IconButton(lp, 22, "back", function() Mini.Back() end, L["Back"])
    ui.back:SetPoint("TOPLEFT")
    ui.heading = Kit.Text(lp, 13, "header")
    ui.heading:SetPoint("LEFT", ui.back, "RIGHT", 6, 0)
    ui.heading:SetWordWrap(false)
    ui.new = Kit.IconButton(lp, 22, "plus", function() Mini.New() end, L["New"])
    ui.new:SetPoint("TOPRIGHT")
    ui.heading:SetPoint("RIGHT", ui.new, "LEFT", -6, 0)
    ui.input = Kit.EditBox(lp, 100, 22, { placeholder = L["Name or Name-Realm"], maxLetters = 60,
        onEnter = function() Mini.New() end })
    ui.input:SetPoint("TOPLEFT", 0, 0)
    ui.input:SetPoint("TOPRIGHT", ui.new, "TOPLEFT", -6, 0)
    ui.list = Kit.ScrollList(lp, ROW_H, {
        create = function(row)
            row.headBg = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            row.headBg:SetAllPoints()
            Theme.Bind(row.headBg, function(self, T) Theme.Paint(self, T.accentSoft) end)
            row.zebra = row:CreateTexture(nil, "BACKGROUND", nil, -3)
            row.zebra:SetAllPoints()
            Theme.Bind(row.zebra, function(self, T) Theme.Paint(self, T.bgAlt) end)
            row.arrow = Kit.Glyph(row, "down", 10, "textDim")
            row.arrow:SetPoint("LEFT", 6, 0)
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetSize(8, 8)
            row.text = Kit.Text(row, 12)
            row.text:SetWordWrap(false)
            row.meta = Kit.Text(row, 10, "textDim")
            row.meta:SetPoint("RIGHT", -6, 0)
        end,
        update = function(row, item)
            row.dot:ClearAllPoints()
            row.text:ClearAllPoints()
            row.arrow:SetShown(item.kind == "header")
            row.headBg:SetShown(item.kind == "header")
            row.zebra:SetShown(item.stripe and true or false)
            Kit.SetTextColor(row.text, item.kind == "header" and "header" or "text")
            if item.kind == "header" then
                row.arrow:SetKind(ctx.collapsed[item.id] and "right" or "down")
                row.dot:SetPoint("LEFT", 22, 0)
                if item.color then
                    row.dot:SetColorTexture(item.color[1], item.color[2], item.color[3], 1)
                else
                    row.dot:SetColorTexture(0.5, 0.5, 0.5, 1)
                end
                row.dot:Show()
                row.text:SetPoint("LEFT", 36, 0)
                row.text:SetPoint("RIGHT", -40, 0)
                row.text:SetText(item.label)
                row.meta:SetText(tostring(item.count))
            elseif item.kind == "player" then
                local r, g, b = Store.ClassColor(item.player.class)
                row.dot:SetPoint("LEFT", 8, 0)
                row.dot:SetColorTexture(r, g, b, 1)
                row.dot:Show()
                row.text:SetPoint("LEFT", 22, 0)
                row.text:SetPoint("RIGHT", -90, 0)
                row.text:SetText(Store.PlayerLabel(item.id) .. "  (" .. item.player.count .. ")")
                row.meta:SetText(item.player.seen > 0 and ns.Views.Ago(item.player.seen) or L["not seen"])
            else
                local note = Store.GetNote(item.id)
                row.dot:Hide()
                row.text:SetPoint("LEFT", 36, 0)
                row.text:SetPoint("RIGHT", -64, 0)
                row.text:SetText(Store.NoteTitle(note))
                row.meta:SetText(note and ns.Views.Stamp(note.updated, true) or "")
            end
        end,
        onClick = function(_, item)
            if item.kind == "player" then
                ctx.player = item.id
                Mini.Refresh()
            elseif item.kind == "header" then
                ctx.collapsed[item.id] = not ctx.collapsed[item.id] or nil
                Mini.Refresh()
            else
                Open(item.id)
            end
        end,
    })
    ui.list:SetPoint("TOPLEFT", 0, -30)
    ui.list:SetPoint("BOTTOMRIGHT")
    ui.empty = Kit.Hint(lp, "")

    -- detail pane ------------------------------------------------------------
    local dp = CreateFrame("Frame", nil, body)
    dp:SetAllPoints()
    dp:Hide()
    ui.detail = dp
    local back = Kit.IconButton(dp, 22, "back", function() Mini.Back() end, L["Back"])
    back:SetPoint("TOPLEFT")
    local del = Kit.ConfirmButton(dp, 64, L["Delete"], function()
        local nid = ctx.nid
        if not nid then return end
        ctx.fresh = nil
        ctx.nid = nil
        Store.DeleteNote(nid)
        Mini.Refresh()
    end, 22)
    del:SetPoint("TOPRIGHT")
    ui.title = Kit.EditBox(dp, 100, 22, { placeholder = L["Title"], maxLetters = 80,
        onChange = function(text, userInput)
            if userInput and ctx.nid then Store.UpdateNote(ctx.nid, { title = text }) end
        end })
    ui.title:SetPoint("TOPLEFT", back, "TOPRIGHT", 6, 0)
    ui.title:SetPoint("TOPRIGHT", del, "TOPLEFT", -6, 0)
    -- info row: where this entry lives, and a button to file it into a group
    ui.groupBtn = Kit.Button(dp, 120, "", function(button)
        local note = ctx.nid and Store.GetNote(ctx.nid)
        if not note or note.player then return end
        local items = {}
        for _, group in ipairs(Store.ListGroups()) do
            items[#items + 1] = { text = group.name, color = group.color, checked = note.group == group.id,
                func = function() Store.UpdateNote(ctx.nid, { group = group.id }) end }
        end
        items[#items + 1] = { text = L["No group"], checked = note.group == nil,
            func = function() Store.UpdateNote(ctx.nid, { group = false }) end }
        Kit.OpenMenu(button, items)
    end, 20)
    ui.groupBtn:SetPoint("TOPRIGHT", 0, -28)
    ui.crumb = Kit.Text(dp, 11, "textDim")
    ui.crumb:SetPoint("TOPLEFT", 2, -31)
    ui.crumb:SetPoint("TOPRIGHT", ui.groupBtn, "TOPLEFT", -6, -3)
    ui.crumb:SetWordWrap(false)
    ui.ed = Editor.Create(dp, { toolbar = true, framed = true, size = 12,
        hint = L["Click to write.  [ ] makes a checkbox, - a list, 1. a numbered list."] })
    ui.ed:SetPoint("TOPLEFT", 0, -54)
    ui.ed:SetPoint("BOTTOMRIGHT")
    ui.canvasHolder = CreateFrame("Frame", nil, dp)
    ui.canvasHolder:SetPoint("TOPLEFT", 0, -54)
    ui.canvasHolder:SetPoint("BOTTOMRIGHT")
    ui.canvasHolder:Hide()
    ui.canvasHint = Kit.Hint(ui.canvasHolder, L["The drawing board is not available."])

    -- ignore pane (built by Views.IgnoreList) ----------------------------------
    local ip = CreateFrame("Frame", nil, body)
    ip:SetAllPoints()
    ip:Hide()
    ui.ignorePane = ip
    if ns.Views.IgnoreList then
        ui.ignoreView = ns.Views.IgnoreList(ip, { compact = true })
    else
        Kit.Hint(ip, L["The ignore list is not available."])
    end

    Store.OnChanged(function()
        if not ui.busy and win:IsShown() then Mini.Refresh() end
    end)
    win:SetScaleSaved(mini.scale)
    win:SetLocked(mini.lock)
    return win
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function Mini.Show()
    if not win then Create() end
    win:Show()
end

function Mini.Toggle()
    if not win then Create() end
    if win:IsShown() then win:Hide() else win:Show() end
end

-- Hands over to the large window (EllesmereUI section when integrated, else the ForeverNotes window; in combat always
-- the ForeverNotes window): the open entry, else the current tab. The mini window closes then.
function Mini.OpenInPanel()
    if not win then return end
    local opened
    if ctx.nid then
        opened = ns.RevealNote and ns.RevealNote(ctx.nid)
    elseif ns.OpenPanelPage then
        opened = ns.OpenPanelPage(ctx.tab, ctx.player)
    end
    if opened then win:Hide() end
end

-- Called by the options page after scale/lock changed.
function Mini.ApplySettings()
    if not win then return end
    local mini = Settings()
    win:SetScaleSaved(mini.scale)
    win:SetLocked(mini.lock)
end

ns.ToggleMini = Mini.Toggle

ns.OnReady(function()
    if Settings().shown then C_Timer.After(0, Mini.Show) end
end)
