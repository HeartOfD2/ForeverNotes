-- Optional EllesmereUI integration: one sidebar section "Notes" with the same modules and pages as our own options
-- window (UI/OptionsWindow.lua). Runs only when EllesmereUI is loaded and settings.integrateEUI is on; RegisterPlugin
-- works only at load, so switching the setting takes effect after /reload. This is the only file that touches
-- EllesmereUI.Widgets; settings pages are drawn here from the row descriptions in UI/Settings.lua.
local _, ns = ...
local L = ns.L
local Settings = ns.Settings

local PLUGIN_ID = "ForeverNotes"
local HOST_H = 560 -- fixed height of tree + editor pages; the lists scroll inside

local function IsPrebuild()
    local E = EllesmereUI
    return type(E) == "table" and type(E.IsSearchPrebuild) == "function" and E.IsSearchPrebuild() or false
end

local function Pad()
    return EllesmereUI.CONTENT_PAD or 45
end

local views = {}  -- page key -> view
local byName = {} -- localized page name (what EUI hands back) -> page

---------------------------------------------------------------------------
-- Renderer: row descriptions -> EllesmereUI.Widgets (searchable by EUI)
---------------------------------------------------------------------------

-- Re-read the values of EUI's widgets on the page (after a row changed others, e.g. accent mode).
local function RefreshEUIPage()
    local E = EllesmereUI
    if type(E.RefreshPage) == "function" then pcall(E.RefreshPage, E) end
end

-- Own frames (palette, text) are never built during EUI's search pre-build; they only reserve space then.
local function PaletteRow(parent, y, row)
    if IsPrebuild() then return 40 end
    local host = ns.Views.Host(parent, y, 40)
    local label = ns.Kit.Text(host, 14, "text")
    label:SetPoint("LEFT", 20, 0)
    label:SetText(row.text)
    local palette = ns.Kit.Palette(host, row.colors, row.get, function(r, g, b)
        row.set(r, g, b)
        RefreshEUIPage()
    end, 20)
    palette:SetPoint("RIGHT", -20, 0)
    if row.tip then ns.Kit.Tooltip(host, { row.text, row.tip }, "ANCHOR_TOPLEFT") end
    host:EnableMouse(row.tip ~= nil)
    return 40
end

-- Sample sentence in the chosen font (a Kit text: it follows the font setting by itself).
local function PreviewRow(parent, y, row)
    if IsPrebuild() then return 52 end
    local host = ns.Views.Host(parent, y - 4, 44)
    local box = ns.Kit.Panel(host, "inputBg", "border", "input")
    box:SetPoint("TOPLEFT", 20, 0)
    box:SetPoint("BOTTOMRIGHT", -20, 0)
    local text = ns.Kit.Text(box, 16, "text")
    text:SetPoint("LEFT", 12, 0)
    text:SetPoint("RIGHT", -12, 0)
    text:SetWordWrap(false)
    text:SetText(row.text)
    return 52
end

local function TextRow(parent, y, row)
    local h = 20 + 16 * select(2, row.text:gsub("\n", "\n"))
    if IsPrebuild() then return h end
    local text = parent:CreateFontString(nil, "OVERLAY")
    ns.Theme.SetFont(text, 13)
    text:SetTextColor(0.75, 0.75, 0.75)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    text:SetPoint("TOPLEFT", parent, "TOPLEFT", Pad() + 20, y - 6)
    text:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(Pad() + 20), y - 6)
    if text.SetSpacing then text:SetSpacing(4) end
    text:SetText(row.text)
    return math.max(h, math.floor((text:GetStringHeight() or 0) + 14))
end

local function Render(parent, yOffset, rows)
    local W = EllesmereUI.Widgets
    if type(W) ~= "table" then return 1 end
    local y = yOffset
    for _, row in ipairs(rows) do
        local set = row.set
        if set and row.refresh then
            set = function(...)
                row.set(...)
                RefreshEUIPage()
            end
        end
        local _, h
        if row.type == "header" then
            _, h = W:SectionHeader(parent, row.text, y, row.tip)
        elseif row.type == "toggle" then
            _, h = W:Toggle(parent, row.text, y, function() return row.get() and true or false end, set, row.tip)
        elseif row.type == "slider" then
            _, h = W:Slider(parent, row.text, y, row.min, row.max, row.step, row.get, set, row.tip)
        elseif row.type == "dropdown" then
            local values, order = row.values()
            _, h = W:Dropdown(parent, row.text, y, values, row.get, set, order, row.tip)
        elseif row.type == "button" then
            _, h = W:Button(parent, row.text, y, row.onClick)
        elseif row.type == "color" then
            _, h = W:ColorPicker(parent, row.text, y, row.get, set, false)
        elseif row.type == "palette" then
            h = PaletteRow(parent, y, row)
        elseif row.type == "text" then
            h = TextRow(parent, y, row)
        elseif row.type == "preview" then
            h = PreviewRow(parent, y, row)
        end
        y = y - (h or 0)
    end
    return math.abs(y)
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local function BuildPage(page, parent, y)
    if page.view then
        if IsPrebuild() then return 600 end -- no frames of our own while EUI pre-builds for search
        local host = ns.Views.Host(parent, y, HOST_H)
        views[page.key] = Settings.BuildView(page, host)
        return HOST_H - y
    end
    return Render(parent, y, Settings.Rows(page.form, "eui"))
end

local function RestorePage(page)
    ns.Theme.CheckLive() -- accent or font may have changed while the page was hidden
    local view = views[page.key]
    if view and view.Refresh then view:Refresh() end
end

-- Host entry point (router).
local function Open(pageKey, sel)
    local page, module = Settings.FindPage(pageKey or "notes")
    if not page then page, module = Settings.FindPage("notes") end
    local E = EllesmereUI
    if not (type(E) == "table" and type(E.OpenPlugin) == "function") then
        ns.Say(L["EllesmereUI is missing or too old (no plugin API)."])
        return false
    end
    local ok, opened = pcall(E.OpenPlugin, PLUGIN_ID, module.key, page.label)
    if not (ok and opened) then
        ns.Say(L["EllesmereUI is missing or too old (no plugin API)."])
        return false
    end
    if sel and not Settings.Select(views[page.key], sel) then
        -- the page may still be building
        C_Timer.After(0.2, function() Settings.Select(views[page.key], sel) end)
    end
    return true
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local function Module(module)
    local names = {}
    for i, page in ipairs(module.pages) do
        names[i] = page.label
        byName[page.label] = page
    end
    return {
        key = module.key,
        title = module.title,
        description = module.desc,
        pages = names,
        buildPage = function(pageName, parent, y)
            local page = byName[pageName]
            if page then return BuildPage(page, parent, y) end
            return 1
        end,
        onPageCacheRestore = function(pageName)
            local page = byName[pageName]
            if page then RestorePage(page) end
        end,
    }
end

local function Register()
    local E = EllesmereUI
    if type(E) ~= "table" then
        ns.registerResult = "no EllesmereUI"
        return
    end
    if not ns.db.settings.integrateEUI then
        ns.registerResult = "integration off"
        return
    end
    if type(E.RegisterPlugin) ~= "function" then
        ns.registerResult = "no RegisterPlugin"
        return
    end
    local modules = {}
    for i, module in ipairs(Settings.Modules()) do modules[i] = Module(module) end
    -- The section label must not start with "EUI"/"Ellesmere" (EUI rejects the whole registration).
    local ok, result = pcall(E.RegisterPlugin, PLUGIN_ID, { label = L["Notes"], modules = modules })
    ns.registerResult = ok and result or ("error: " .. tostring(result))
    if ok and result ~= false then
        ns.hosts.eui = {
            Open = Open,
            IsShown = function() return false end, -- EUI's panel opens and closes itself
            Hide = function() end,
        }
    end
end

ns.OnReady(Register)
