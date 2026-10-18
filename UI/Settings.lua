-- Page registry and settings pages, described once as data and drawn by two renderers: Settings.RenderKit (our own
-- options window, Kit form blocks) and the EllesmereUI renderer in Integration/EUIPages.lua (EllesmereUI.Widgets).
-- Row types (all may carry tip and cond = function() -> bool, evaluated when the page is built):
--   header { text }                               toggle { text, get, set }
--   slider { text, min, max, step, get, set }     dropdown { text, values() -> labels, order, get, set }
--   button { text, onClick }                      color { text, get() -> r, g, b, set(r, g, b) }
--   palette { text, colors, get() -> r, g, b | nil, set(r, g, b) }    text { text }
--   preview { text }  sample sentence in the chosen font
-- refresh = true: other rows may show a changed value afterwards (renderers re-read the page).
local _, ns = ...
local L = ns.L
local Theme, Kit = ns.Theme, ns.Kit

local Settings = {}
ns.Settings = Settings

---------------------------------------------------------------------------
-- Registry: modules and pages in the order of the EllesmereUI section "Notes"
---------------------------------------------------------------------------

-- view = constructor in ns.Views (tree and list pages), form = row set below. Built at call time (locale is final
-- only after ADDON_LOADED).
function Settings.Modules()
    return {
        { key = "Notebook", title = L["Notebook"], desc = L["Notes, drawings and sticky notes."], pages = {
            { key = "notes", label = L["Notes"], view = "Notebook" },
            { key = "drawings", label = L["Drawings"], view = "Drawings" },
        } },
        { key = "Players", title = L["Players"], desc = L["Notes and notes about players."], pages = {
            { key = "players", label = L["Player Notes"], view = "Players" },
            { key = "ignore", label = L["Ignore List"], view = "IgnoreList" },
        } },
        { key = "Settings", title = L["Settings"], desc = L["Appearance, popup, sticky notes, ignoring and transfer."],
            pages = {
                { key = "general", label = L["General"], form = "general" },
                { key = "popup", label = L["Target Popup"], form = "popup" },
                { key = "sticky", label = L["Sticky Notes"], form = "sticky" },
                { key = "ignoreSettings", label = L["Ignore & Sound"], form = "ignoreSettings" },
                { key = "transfer", label = L["Export / Import"], view = "Transfer" },
            } },
    }
end

-- page, module of a page key (nil when unknown).
function Settings.FindPage(key)
    for _, module in ipairs(Settings.Modules()) do
        for _, page in ipairs(module.pages) do
            if page.key == key then return page, module end
        end
    end
    return nil
end

-- Builds the view of a page into host; returns the view (Refresh, optional Select).
function Settings.BuildView(page, host)
    local make = ns.Views and ns.Views[page.view]
    if not make then return nil end
    return make(host)
end

-- Selects sel ({ nid } or { player }) in a built view; false when the view cannot take it (yet).
function Settings.Select(view, sel)
    if not (view and sel) then return false end
    if sel.nid and view.Select then
        view:Select("note", sel.nid)
        return true
    end
    if sel.player then
        if view.Select then
            view:Select("header", sel.player)
            return true
        end
        if view.SelectKey then
            view:SelectKey(sel.player)
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Row sets
---------------------------------------------------------------------------

local function Bool(t, key)
    return function() return t[key] and true or false end
end

local function SetBool(t, key, after)
    return function(value)
        t[key] = value and true or false
        if after then after() end
    end
end

local function MiniChanged()
    if ns.Mini and ns.Mini.ApplySettings then ns.Mini.ApplySettings() end
end

local function PopupChanged()
    if ns.Popup then ns.Popup.Refresh() end
end

local function StickyChanged()
    if ns.Stickies then ns.Stickies.ApplySettings() end
end

local function ThemeValues()
    local values, order = {}, {}
    for i, theme in ipairs(Theme.List()) do
        values[theme.key] = theme.label
        order[i] = theme.key
    end
    return values, order
end

local function LanguageValues()
    return { auto = L["Automatic"], enUS = "English", deDE = "Deutsch" }, { "auto", "enUS", "deDE" }
end

-- The palette marks a color only while the accent is an own color.
local function PaletteGet()
    if Theme.AccentMode() ~= "custom" then return nil end
    return Theme.CustomAccent()
end

local function Reload()
    if type(ReloadUI) == "function" then ReloadUI() end
end

local function GeneralRows(host)
    local s = ns.db.settings
    local mini = s.mini
    return {
        { type = "header", text = L["APPEARANCE"] },
        { type = "dropdown", text = L["Theme"], values = ThemeValues, get = Theme.Current,
            set = function(key) Theme.Set(key) end,
            tip = host == "eui"
                and L["Look of the ForeverNotes windows (options window, mini window, target popup, sticky notes). This EllesmereUI window keeps its own look."]
                or L["Look of the ForeverNotes windows: options window, mini window, target popup and sticky notes."] },
        { type = "dropdown", text = L["Font"], values = function() return ns.Fonts.Values() end,
            get = function() return ns.Fonts.Current() end,
            set = function(key) Theme.SetFontChoice(key) end,
            tip = L["Font of all ForeverNotes texts. \"EllesmereUI font\" follows the font set in EllesmereUI (only while it is installed and enabled)."] },
        { type = "preview", text = L["The quick brown fox jumps over the lazy dog. 0123456789"] },
        { type = "dropdown", text = L["Accent color"], values = Theme.AccentModes, get = Theme.AccentMode,
            set = function(mode) Theme.SetAccentMode(mode) end, refresh = true,
            tip = L["Highlight color of every theme: buttons, switches, tabs, the popup glow and sticky notes."] },
        { type = "palette", text = L["Own color"], colors = Theme.PALETTE, get = PaletteGet,
            set = function(r, g, b) Theme.SetCustomAccent(r, g, b) end, refresh = true,
            tip = L["Click a color to use it as the accent."] },
        { type = "color", text = L["Pick any color"], get = Theme.CustomAccent,
            set = function(r, g, b) Theme.SetCustomAccent(r, g, b) end, refresh = true,
            tip = L["Opens the color picker. The chosen color becomes the accent."] },

        { type = "header", text = L["MINI WINDOW"] },
        { type = "button", text = L["Open the mini window"], onClick = function() ns.ToggleMini() end },
        { type = "slider", text = L["Scale"], min = 0.7, max = 1.5, step = 0.05,
            get = function() return mini.scale or 1 end,
            set = function(value)
                mini.scale = value
                MiniChanged()
            end, tip = L["Size of the whole mini window."] },
        { type = "toggle", text = L["Lock position and size"], get = Bool(mini, "lock"), set = SetBool(mini, "lock", MiniChanged),
            tip = L["Prevents moving and resizing the mini window by accident."] },

        { type = "header", text = L["MINIMAP"] },
        { type = "toggle", text = L["Show the minimap button"],
            get = function() return not (s.minimap and s.minimap.hide) end,
            set = function(value)
                s.minimap.hide = not value
                if ns.MinimapButton then ns.MinimapButton.Apply() end
            end,
            tip = L["Left-click opens ForeverNotes, right-click the mini window. Drag it to move it along the minimap."] },

        { type = "header", text = L["LANGUAGE"] },
        { type = "dropdown", text = L["Language"], values = LanguageValues,
            get = function() return s.language or "auto" end,
            set = function(key)
                s.language = key
                ns.Say(L["The language changes after a reload (/reload)."])
            end,
            tip = L["Automatic uses the EllesmereUI language when it is installed, else the language of the game."] },

        { type = "header", text = "EllesmereUI", cond = ns.HasEUI },
        { type = "toggle", text = L["Integrate into EllesmereUI"], cond = ns.HasEUI,
            get = Bool(s, "integrateEUI"),
            set = SetBool(s, "integrateEUI", function()
                ns.Say(L["The EllesmereUI integration changes after a reload (/reload)."])
            end),
            tip = L["Adds the section \"Notes\" to the EllesmereUI options window. Without it, /forevernotes opens the ForeverNotes window."] },

        { type = "text", text = L["Language and integration changes take effect after a reload."] },
        { type = "button", text = L["Reload now"], onClick = Reload },
    }
end

local function PopupRows()
    local popup = ns.db.settings.popup
    local reset = function() if ns.Popup then ns.Popup.ResetGeometry() end end
    return {
        { type = "header", text = L["TARGET POPUP"] },
        { type = "toggle", text = L["Show the popup when targeting a player"], get = Bool(popup, "enabled"),
            set = SetBool(popup, "enabled", PopupChanged),
            tip = L["Shows the notes of the player you target. Without notes it is a slim bar with a + button."] },
        { type = "toggle", text = L["Glow when notes exist"], get = Bool(popup, "glow"), set = SetBool(popup, "glow", PopupChanged),
            tip = L["A pulsing strip at the bottom edge of the collapsed popup tells you that this player has notes."] },
        { type = "toggle", text = L["Hide in combat"], get = Bool(popup, "hideInCombat"),
            set = SetBool(popup, "hideInCombat", PopupChanged), tip = L["Hides the popup while you are in combat."] },
        { type = "toggle", text = L["Hide in instances"], get = Bool(popup, "hideInInstance"),
            set = SetBool(popup, "hideInInstance", PopupChanged),
            tip = L["Hides the popup in dungeons and raids, where player names are often hidden from addons."] },
        { type = "header", text = L["POSITION"] },
        { type = "button", text = L["Reset position and size"], onClick = reset },
    }
end

local function StickyRows()
    local cfg = ns.db.settings.sticky
    return {
        { type = "header", text = L["NEW STICKY NOTES"] },
        { type = "slider", text = L["Width"], min = 160, max = 500, step = 10,
            get = function() return cfg.w end, set = function(value) cfg.w = value end,
            tip = L["Width of sticky notes you open from now on."] },
        { type = "slider", text = L["Height"], min = 90, max = 500, step = 10,
            get = function() return cfg.h end, set = function(value) cfg.h = value end,
            tip = L["Height of sticky notes you open from now on."] },
        { type = "header", text = L["ALL STICKY NOTES"] },
        { type = "slider", text = L["Text size"], min = 10, max = 18, step = 1,
            get = function() return cfg.size end,
            set = function(value)
                cfg.size = value
                StickyChanged()
            end },
        { type = "slider", text = L["Opacity"], min = 0.3, max = 1, step = 0.05,
            get = function() return cfg.alpha or 1 end,
            set = function(value)
                cfg.alpha = value
                StickyChanged()
            end, tip = L["Transparency of all sticky notes. Lower values let you see through them."] },
        { type = "toggle", text = L["Hide in combat"], get = Bool(cfg, "hideInCombat"),
            set = SetBool(cfg, "hideInCombat", StickyChanged),
            tip = L["Sticky notes step aside while you are in combat and come back afterwards."] },
        { type = "button", text = L["Close all"], onClick = function() if ns.Stickies then ns.Stickies.CloseAll() end end },
        { type = "header", text = L["HOW IT WORKS"] },
        { type = "text", text = table.concat({
            L["Press \"Sticky\" on a note to put it on the screen."],
            L["Drag the bar to move it, the corner to resize it. The lock keeps both."],
            L["Drop it at the edge of another sticky note to dock it there: same size, moves along. Pull it away to undock."],
            L["Click the text to write; Esc or \"Done\" shows it formatted again."],
        }, "\n") },
    }
end

local function IgnoreRows()
    local cfg = ns.db.settings.ignore
    return {
        { type = "header", text = L["WARNING"] },
        { type = "toggle", text = L["Play a sound when an ignored player is targeted"], get = Bool(cfg, "soundOn"),
            set = SetBool(cfg, "soundOn"), tip = L["Warns you each time you target someone on your ignore list."] },
        { type = "dropdown", text = L["Sound"], values = function() return ns.Ignore.Sounds() end,
            get = function() return cfg.sound end,
            set = function(key)
                cfg.sound = key
                ns.Ignore.Play(key)
            end, tip = L["Picking a sound plays it."] },
        { type = "dropdown", text = L["Sound channel"], values = function() return ns.Ignore.Channels() end,
            get = function() return cfg.channel or "Master" end,
            set = function(key) cfg.channel = key end,
            tip = L["The volume slider that controls the warning sound."] },
        { type = "button", text = L["Play the sound"], onClick = function() ns.Ignore.Play() end },
        { type = "slider", text = L["Repeat warning after (seconds)"], min = 0, max = 300, step = 5,
            get = function() return cfg.throttle or 30 end, set = function(value) cfg.throttle = value end,
            tip = L["The same player triggers the warning at most once in this time. 0 warns on every targeting."] },
        { type = "toggle", text = L["Show a chat message"], get = Bool(cfg, "chat"), set = SetBool(cfg, "chat"),
            tip = L["Prints a line in the chat window (only you see it)."] },
        { type = "header", text = L["TARGET POPUP"] },
        { type = "toggle", text = L["Mark the popup in red"], get = Bool(cfg, "markPopup"),
            set = SetBool(cfg, "markPopup", PopupChanged),
            tip = L["Ignored players get a red edge, a red strip and their reason in the target popup."] },
        { type = "header", text = L["BLIZZARD IGNORE LIST"] },
        { type = "toggle", text = L["Also keep the Blizzard ignore list up to date"], get = Bool(cfg, "syncWoW"),
            set = SetBool(cfg, "syncWoW"),
            tip = L["New entries are also added to the game's ignore list, removed ones are removed from it. Blocks that player's chat and whispers."] },
    }
end

local FORMS = { general = GeneralRows, popup = PopupRows, sticky = StickyRows, ignoreSettings = IgnoreRows }

-- Rows of a form page for a host ("eui" | "standalone"); rows whose cond fails are left out.
function Settings.Rows(form, host)
    local make = FORMS[form]
    if not make then return {} end
    local rows = {}
    for _, row in ipairs(make(host)) do
        if not row.cond or row.cond() then rows[#rows + 1] = row end
    end
    return rows
end

---------------------------------------------------------------------------
-- Standalone renderer (Kit form blocks in a scroll area)
---------------------------------------------------------------------------

local PAD_X, GAP_Y = 6, 2

-- Builds rows into a scroll area filling parent; returns the area with :Refresh() (re-read every value).
function Settings.RenderKit(parent, rows)
    local area = Kit.ScrollArea(parent)
    area:SetAllPoints()
    area.rows = {}
    local child = area.child

    local function Wrap(fn)
        if not fn then return nil end
        return function(...)
            fn(...)
            area:Refresh()
        end
    end

    for _, r in ipairs(rows) do
        local row
        if r.type == "header" then
            row = Kit.SectionHeader(child, r.text)
        elseif r.type == "toggle" then
            row = Kit.ToggleRow(child, r.text, r.get, Wrap(r.set), r.tip)
        elseif r.type == "slider" then
            row = Kit.SliderRow(child, r.text, r.min, r.max, r.step, r.get, r.set, r.tip)
        elseif r.type == "dropdown" then
            row = Kit.DropdownRow(child, r.text, r.values, r.get, Wrap(r.set), r.tip)
        elseif r.type == "button" then
            row = Kit.ButtonRow(child, r.text, r.onClick, r.tip)
        elseif r.type == "color" then
            row = Kit.ColorRow(child, r.text, r.get, Wrap(r.set), r.tip)
        elseif r.type == "palette" then
            row = Kit.PaletteRow(child, r.text, r.colors, r.get, Wrap(r.set), r.tip)
        elseif r.type == "text" then
            row = Kit.TextRow(child, r.text)
        elseif r.type == "preview" then
            row = Kit.PreviewRow(child, r.text)
        end
        if row then area.rows[#area.rows + 1] = row end
    end

    function area:Layout()
        local y = 0
        for _, row in ipairs(self.rows) do
            if row.Measure then row:Measure() end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", PAD_X, -y)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", -PAD_X, -y)
            y = y + (row.rowHeight or 30) + GAP_Y
        end
        self:SetContentHeight(y + 12)
    end

    function area:Refresh()
        for _, row in ipairs(self.rows) do row:Update() end
    end

    -- wrapped text changes its height with the width
    child:HookScript("OnSizeChanged", function() area:Layout() end)
    area:Layout()
    area:Refresh()
    return area
end
