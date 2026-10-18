-- ForeverNotes ignore list view: add by name or from the target, edit the reason, remove.
-- Host-independent like the other views (options window, EUI page, mini window tab).
local _, ns = ...
local L = ns.L
local Store, Kit = ns.Store, ns.Kit

local ROW_H = 22

-- opts.compact: no "Target" button, narrower name column (mini window).
function ns.Views.IgnoreList(host, opts)
    opts = opts or {}
    local v = { host = host, items = {} }

    local function Select(key)
        v.sel = key
        v:Refresh()
    end
    function v:SelectKey(key) Select(key) end

    local function Add(text, info)
        local key, name, realm = Store.ParseName(text)
        if not key then
            ns.Say(L["Enter a player name."])
            return
        end
        if Store.IsIgnored(key) then
            ns.Say(L["Already on the ignore list."])
            Select(key)
            return
        end
        ns.Ignore.Add(key, info or { name = name, realm = realm }, "")
        Select(key)
    end

    -- top bar
    local add = Kit.Button(host, 64, L["Add"], function()
        Add(v.input:GetText())
        v.input:SetText("")
    end, 24, "primary")
    add:SetPoint("TOPRIGHT")
    local leftmost = add
    if not opts.compact then
        local target = Kit.Button(host, 70, L["Target"], function()
            local key, info = Store.TargetKey()
            if not key then
                ns.Say(L["No player targeted."])
                return
            end
            Add(key, info)
        end, 24)
        target:SetPoint("TOPRIGHT", add, "TOPLEFT", -6, 0)
        leftmost = target
    end
    v.input = Kit.EditBox(host, 100, 24, { placeholder = L["Name or Name-Realm"], maxLetters = 60,
        onEnter = function(text)
            Add(text)
            v.input:SetText("")
        end })
    v.input:SetPoint("TOPLEFT")
    v.input:SetPoint("TOPRIGHT", leftmost, "TOPLEFT", -6, 0)

    -- detail strip for the selected entry
    local detail = Kit.Panel(host, "bgAlt", "border", "panel")
    detail:SetPoint("BOTTOMLEFT")
    detail:SetPoint("BOTTOMRIGHT")
    detail:SetHeight(66)
    v.name = Kit.Text(detail, 13)
    v.name:SetPoint("TOPLEFT", 8, -8)
    v.name:SetWordWrap(false)
    local remove = Kit.ConfirmButton(detail, 84, L["Remove"], function()
        if v.sel then ns.Ignore.Remove(v.sel) end
    end, 22)
    remove:SetPoint("TOPRIGHT", -8, -6)
    v.name:SetPoint("RIGHT", remove, "LEFT", -6, 0)
    v.reason = Kit.EditBox(detail, 100, 22, { placeholder = L["Reason (optional)"], maxLetters = 120,
        onChange = function(text, userInput)
            if userInput and v.sel then Store.SetIgnoreReason(v.sel, text) end
        end })
    v.reason:SetPoint("BOTTOMLEFT", 8, 8)
    v.reason:SetPoint("BOTTOMRIGHT", -8, 8)
    v.detail = detail

    -- list
    local side = Kit.Panel(host, "bgAlt", "border", "panel")
    side:SetPoint("TOPLEFT", v.input, "BOTTOMLEFT", 0, -8)
    side:SetPoint("BOTTOMRIGHT", detail, "TOPRIGHT", 0, 8)
    v.list = Kit.ScrollList(side, ROW_H, {
        create = function(row)
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetSize(8, 8)
            row.dot:SetPoint("LEFT", 8, 0)
            row.text = Kit.Text(row, 12)
            row.text:SetPoint("LEFT", 22, 0)
            row.text:SetWidth(opts.compact and 100 or 150)
            row.text:SetWordWrap(false)
            row.meta = Kit.Text(row, 10, "textDim")
            row.meta:SetPoint("LEFT", row.text, "RIGHT", 6, 0)
            row.meta:SetPoint("RIGHT", -6, 0)
            row.meta:SetWordWrap(false)
        end,
        update = function(row, item)
            local r, g, b = Store.ClassColor(item.class)
            row.dot:SetColorTexture(r, g, b, 1)
            row.text:SetText(Store.PlayerLabel(item.key))
            local ago = ns.Views.Ago(item.seen)
            row.meta:SetText(ago ~= "-" and ((item.reason or "") ~= "" and ago .. "  -  " .. item.reason or ago)
                or item.reason or "")
        end,
        onClick = function(_, item) Select(item.key) end,
        isSelected = function(item) return v.sel == item.key end,
    })
    v.list:SetPoint("TOPLEFT", 4, -4)
    v.list:SetPoint("BOTTOMRIGHT", -4, 4)
    v.empty = Kit.Hint(side, L["The ignore list is empty. Add a name above or ignore a target from the popup."])

    function v:Refresh()
        self.items = Store.ListIgnored()
        local found = false
        for _, item in ipairs(self.items) do
            if item.key == self.sel then found = true end
        end
        if not found then self.sel = nil end
        self.list:SetItems(self.items)
        self.empty:SetShown(#self.items == 0)
        self.detail:SetShown(self.sel ~= nil)
        if self.sel then
            self.name:SetText(Store.PlayerLabel(self.sel))
            local entry = Store.GetIgnored(self.sel)
            if not self.reason.edit:HasFocus() then self.reason:SetText(entry and entry.reason or "") end
        end
    end

    Store.OnChanged(function(kind)
        if kind ~= "ignore" then return end
        if host:IsVisible() then v:Refresh() else v.dirty = true end
    end)
    host:HookScript("OnShow", function()
        if v.dirty then
            v.dirty = false
            v:Refresh()
        end
    end)
    v:Refresh()
    return v
end
