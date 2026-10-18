-- ForeverNotes export/import view: everything, or ticked notes of one kind (notes, drawings, player notes) grouped by
-- group or player, optionally the ignore list; one line of text out. Paste a line to import.
local _, ns = ...
local L = ns.L
local Store, Kit, Transfer = ns.Store, ns.Kit, ns.Transfer

local ROW_H = 22

-- Headers with their notes for a filter: groups (notes, drawings) or players. "all" lists nothing: it exports everything.
local function Headers(filter)
    if filter == "notes" then return ns.Views.NotebookHeaders("text") end
    if filter == "drawings" then return ns.Views.NotebookHeaders("drawing") end
    if filter == "players" then return ns.Views.PlayerHeaders() end
    return {}
end

-- Counts for the "everything" summary: text notes, drawings, player notes, players.
local function Totals()
    local notes, drawings, playerNotes, players = 0, 0, 0, 0
    for _, note in pairs(ns.db.notes) do
        if note.player then
            playerNotes = playerNotes + 1
        elseif note.kind == "drawing" then
            drawings = drawings + 1
        else
            notes = notes + 1
        end
    end
    for _ in pairs(ns.db.players) do players = players + 1 end
    return notes, drawings, playerNotes, players
end

function ns.Views.Transfer(host)
    local v = { selected = {}, withIgnore = false, items = {}, filter = "all" }

    local function Heading(text, y)
        local fs = Kit.Text(host, 13, "header")
        fs:SetPoint("TOPLEFT", 0, y)
        fs:SetText(text)
        return fs
    end

    -- "all" / "some" / "none" of a header's notes are ticked
    local function HeaderState(h)
        local some, all = false, #h.notes > 0
        for _, nid in ipairs(h.notes) do
            if v.selected[nid] then some = true else all = false end
        end
        return all and "all" or (some and "some" or "none")
    end

    -- export ----------------------------------------------------------------
    Heading(L["EXPORT"], 0)
    local tabItems = { { "all", L["Everything"] }, { "notes", L["Notes"] }, { "drawings", L["Drawings"] },
        { "players", L["Player Notes"] } }
    v.tabs = Kit.Tabs(host, tabItems, function(key)
        v.filter = key
        v:Refresh()
    end, 24)
    v.tabs:SetPoint("TOPLEFT", 0, -22)
    v.tabs:SetPoint("TOPRIGHT", 0, -22)

    local side = Kit.Panel(host, "bgAlt", "border", "panel")
    side:SetPoint("TOPLEFT", 0, -52)
    side:SetPoint("TOPRIGHT", 0, -52)
    side:SetHeight(178)
    v.list = Kit.ScrollList(side, ROW_H, {
        create = function(row)
            row.box = Kit.Panel(row, "inputBg", "border", "input")
            row.box:SetSize(14, 14)
            row.check = Kit.Glyph(row.box, "check", 12, "accent")
            row.check:SetPoint("CENTER")
            row.part = Kit.Glyph(row.box, "minus", 12, "accent")
            row.part:SetPoint("CENTER")
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetSize(8, 8)
            row.text = Kit.Text(row, 12)
            row.text:SetWordWrap(false)
            row.meta = Kit.Text(row, 10, "textDim")
            row.meta:SetPoint("RIGHT", -6, 0)
            row.meta:SetWidth(100)
            row.meta:SetJustifyH("RIGHT")
            row.meta:SetWordWrap(false)
        end,
        update = function(row, item)
            row.box:ClearAllPoints()
            row.text:ClearAllPoints()
            row.text:SetPoint("RIGHT", -110, 0)
            if item.header then
                local h = item.header
                local state = HeaderState(h)
                row.box:SetPoint("LEFT", 6, 0)
                row.check:SetShown(state == "all")
                row.part:SetShown(state == "some")
                if h.color then
                    row.dot:SetColorTexture(h.color[1], h.color[2], h.color[3], 1)
                    row.dot:ClearAllPoints()
                    row.dot:SetPoint("LEFT", 28, 0)
                    row.dot:Show()
                    row.text:SetPoint("LEFT", 42, 0)
                else
                    row.dot:Hide()
                    row.text:SetPoint("LEFT", 28, 0)
                end
                Kit.SetTextColor(row.text, "header")
                row.text:SetText(h.label)
                row.meta:SetText(tostring(#h.notes))
            else
                row.dot:Hide()
                row.box:SetPoint("LEFT", 26, 0)
                row.check:SetShown(v.selected[item.id] and true or false)
                row.part:Hide()
                row.text:SetPoint("LEFT", 48, 0)
                Kit.SetTextColor(row.text, "text")
                local note = Store.GetNote(item.id)
                row.text:SetText(Store.NoteTitle(note))
                row.meta:SetText(note and ns.Views.Stamp(note.updated, true) or "")
            end
        end,
        onClick = function(_, item)
            if item.header then
                -- a header ticks or unticks all of its notes
                local on = HeaderState(item.header) ~= "all"
                for _, nid in ipairs(item.header.notes) do v.selected[nid] = on or nil end
            else
                v.selected[item.id] = not v.selected[item.id] or nil
            end
            v:UpdateCount()
            v.list:Refresh()
        end,
    })
    v.list:SetPoint("TOPLEFT", 4, -4)
    v.list:SetPoint("BOTTOMRIGHT", -4, 4)
    v.empty = Kit.Hint(side, L["No notes yet."])
    v.summary = Kit.Text(side, 12, "text")
    v.summary:SetPoint("LEFT", 16, 0)
    v.summary:SetPoint("RIGHT", -16, 0)
    v.summary:SetJustifyH("CENTER")
    v.summary:SetWordWrap(true)

    v.selectAll = Kit.Button(host, 100, L["Select all"], function()
        for _, item in ipairs(v.items) do
            if item.id then v.selected[item.id] = true end
        end
        v:UpdateCount()
        v.list:Refresh()
    end, 24)
    v.selectAll:SetPoint("TOPLEFT", 0, -238)
    v.selectNone = Kit.Button(host, 100, L["Select none"], function()
        for _, item in ipairs(v.items) do
            if item.id then v.selected[item.id] = nil end
        end
        v:UpdateCount()
        v.list:Refresh()
    end, 24)
    v.selectNone:SetPoint("LEFT", v.selectAll, "RIGHT", 6, 0)
    local ignoreBox = Kit.Checkbox(host, L["Include the ignore list"], function() return v.withIgnore end,
        function(value) v.withIgnore = value and true or false end)
    ignoreBox:SetPoint("TOPLEFT", 220, -240)
    local create = Kit.Button(host, 120, L["Create code"], function() v:MakeCode() end, 24, "primary")
    create:SetPoint("TOPRIGHT", 0, -238)

    v.codeOut = Kit.EditBox(host, 100, 26, { placeholder = L["The code appears here. Click it, press Ctrl+A, then Ctrl+C."] })
    v.codeOut:SetPoint("TOPLEFT", 0, -270)
    v.codeOut:SetPoint("TOPRIGHT", 0, -270)
    v.exportStatus = Kit.Text(host, 11, "textDim")
    v.exportStatus:SetPoint("TOPLEFT", 2, -302)
    v.exportStatus:SetPoint("TOPRIGHT", -2, -302)
    v.exportStatus:SetWordWrap(false)

    -- import ----------------------------------------------------------------
    Heading(L["IMPORT"], -330)
    v.codeIn = Kit.EditBox(host, 100, 26, { placeholder = L["Paste a code here (Ctrl+V)."] })
    v.codeIn:SetPoint("TOPLEFT", 0, -352)
    v.codeIn:SetPoint("TOPRIGHT", -130, -352)
    local import = Kit.Button(host, 120, L["Import"], function() v:RunImport() end, 26, "primary")
    import:SetPoint("TOPRIGHT", 0, -352)
    v.importStatus = Kit.Text(host, 12)
    v.importStatus:SetPoint("TOPLEFT", 2, -386)
    v.importStatus:SetPoint("TOPRIGHT", -2, -386)
    v.importStatus:SetJustifyV("TOP")

    -- Note ids the code would contain now: every note for "all", else the ticked ones of the shown filter.
    function v:ExportIds()
        local ids = {}
        if self.filter == "all" then
            for id in pairs(ns.db.notes) do ids[#ids + 1] = id end
            table.sort(ids)
            return ids
        end
        for _, h in ipairs(Headers(self.filter)) do
            for _, nid in ipairs(h.notes) do
                if self.selected[nid] then ids[#ids + 1] = nid end
            end
        end
        return ids
    end

    function v:UpdateCount()
        if self.filter == "all" then return end
        local n = #self:ExportIds()
        self.exportStatus:SetText(n == 1 and L["1 note selected."] or L["%d notes selected."]:format(n))
    end

    function v:SetFilter(key)
        if key ~= "all" and key ~= "notes" and key ~= "drawings" and key ~= "players" then key = "all" end
        self.filter = key
        self:Refresh()
    end

    function v:Refresh()
        for id in pairs(self.selected) do
            if not Store.GetNote(id) then self.selected[id] = nil end
        end
        self.tabs:Select(self.filter, true)
        local all = self.filter == "all"
        wipe(self.items)
        if not all then
            for _, h in ipairs(Headers(self.filter)) do
                if #h.notes > 0 then
                    self.items[#self.items + 1] = { header = h }
                    for _, nid in ipairs(h.notes) do self.items[#self.items + 1] = { id = nid } end
                end
            end
        end
        self.list:SetShown(not all)
        self.list:SetItems(self.items)
        self.selectAll:SetShown(not all)
        self.selectNone:SetShown(not all)
        local notes, drawings, playerNotes, players = Totals()
        self.summary:SetShown(all)
        self.summary:SetText(L["Everything: %d notes, %d drawings and %d notes about %d players."]:format(
            notes, drawings, playerNotes, players))
        self.empty:SetShown(not all and #self.items == 0)
        self.exportStatus:SetText("")
        self:UpdateCount()
    end

    function v:MakeCode()
        local ids = self:ExportIds()
        if #ids == 0 and not self.withIgnore then
            self.exportStatus:SetText(L["Select at least one note or include the ignore list."])
            return
        end
        local code = Transfer.Encode({ notes = ids, ignore = self.withIgnore })
        self.codeOut:SetText(code)
        self.exportStatus:SetText(L["%d notes in the code (%d characters)."]:format(#ids, #code))
        self.codeOut:SetFocus()
        self.codeOut.edit:HighlightText()
    end

    function v:RunImport()
        local payload, why = Transfer.Decode(self.codeIn:GetText())
        if not payload then
            Kit.SetTextColor(self.importStatus, "danger")
            self.importStatus:SetText(Transfer.Why(why))
            return
        end
        self.importing = true
        local result = Transfer.Import(payload)
        self.importing = false
        Kit.SetTextColor(self.importStatus, "text")
        local parts = { L["Imported %d notes."]:format(result.notes) }
        if result.skipped > 0 then parts[#parts + 1] = L["%d already existed and were skipped."]:format(result.skipped) end
        if result.groups > 0 then parts[#parts + 1] = L["%d groups created."]:format(result.groups) end
        if result.ignore > 0 then parts[#parts + 1] = L["%d ignore list entries added."]:format(result.ignore) end
        if result.truncated > 0 then parts[#parts + 1] = L["%d drawings were too large and cut."]:format(result.truncated) end
        self.importStatus:SetText(table.concat(parts, " "))
        self.codeIn:SetText("")
        self:Refresh()
    end

    host:SetScript("OnShow", function() v:Refresh() end)
    Store.OnChanged(function(kind)
        if (kind == "note" or kind == "group" or kind == "player") and host:IsVisible() and not v.importing then
            v:Refresh()
        end
    end)
    v:Refresh()
    return v
end
