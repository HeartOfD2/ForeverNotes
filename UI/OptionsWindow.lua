-- The ForeverNotes options window (standalone host): works without EllesmereUI and in combat (plain frame). Sidebar with
-- the modules as headings and their pages below, the page on the right. Pages are built on first use and cached;
-- tree and list views come from ns.Views, settings pages from the row descriptions in UI/Settings.lua.
local addonName, ns = ...
local L = ns.L
local Theme, Kit, Settings = ns.Theme, ns.Kit, ns.Settings
local Paint, Bind, Refresh = Theme.Paint, Theme.Bind, Theme.Refresh

local Options = {}
ns.Options = Options

local SIDE_W, GAP, NAV_H = 170, 12, 24
local LOGO = "Interface\\AddOns\\ForeverNotes\\Media\\Logo"

local win, ui

local function Saved()
    return ns.db.settings.options
end

local function Version()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    if type(get) ~= "function" then return nil end
    local ok, version = pcall(get, addonName, "Version")
    return ok and type(version) == "string" and version or nil
end

---------------------------------------------------------------------------
-- Sidebar
---------------------------------------------------------------------------

local function NavButton(parent, page)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(NAV_H)
    b.key = page.key
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.mark = b:CreateTexture(nil, "ARTWORK")
    b.mark:SetPoint("TOPLEFT")
    b.mark:SetPoint("BOTTOMLEFT")
    b.mark:SetWidth(2)
    b.text = Kit.Text(b, 12, false)
    b.text:SetPoint("LEFT", 16, 0)
    b.text:SetPoint("RIGHT", -6, 0)
    b.text:SetWordWrap(false)
    b.text:SetText(page.label)
    Bind(b, function(self, T)
        local active = ui and ui.current == self.key
        Paint(self.sel, T.select)
        self.sel:SetShown(active and true or false)
        Paint(self.hl, T.hover)
        Paint(self.mark, T.accent)
        self.mark:SetShown(active and true or false)
        Paint(self.text, active and T.text or T.textDim)
    end)
    b:SetScript("OnClick", function(self) Options.ShowPage(self.key) end)
    return b
end

local function BuildSidebar(side)
    -- brand block: logo, name, version
    local logo = side:CreateTexture(nil, "ARTWORK")
    logo:SetSize(30, 30)
    logo:SetPoint("TOPLEFT", 10, -10)
    logo:SetTexture(LOGO)
    local name = Kit.Text(side, 14, "header")
    name:SetPoint("TOPLEFT", logo, "TOPRIGHT", 8, -1)
    name:SetText(addonName)
    local version = Kit.Text(side, 10, "textDim")
    version:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    local v = Version()
    version:SetText(v and ("v" .. v) or "")
    local line = Kit.Divider(side)
    line:SetPoint("TOPLEFT", 10, -50)
    line:SetPoint("TOPRIGHT", -10, -50)

    ui.nav = {}
    local y = -60
    for _, module in ipairs(Settings.Modules()) do
        local heading = Kit.Text(side, 10, "accent")
        heading:SetPoint("TOPLEFT", 12, y - 4)
        heading:SetPoint("RIGHT", -8, 0)
        heading:SetWordWrap(false)
        heading:SetText(module.title)
        y = y - 20
        for _, page in ipairs(module.pages) do
            local b = NavButton(side, page)
            b:SetPoint("TOPLEFT", 4, y)
            b:SetPoint("TOPRIGHT", -4, y)
            ui.nav[#ui.nav + 1] = b
            y = y - NAV_H
        end
        y = y - 8
    end

    -- where else the pages live
    ui.hostHint = Kit.Text(side, 10, "textDim")
    ui.hostHint:SetPoint("BOTTOMLEFT", 12, 10)
    ui.hostHint:SetPoint("BOTTOMRIGHT", -8, 10)
    ui.hostHint:SetWordWrap(true)
    ui.hostHint:SetJustifyH("LEFT")
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function Create()
    local saved = Saved()
    ui = { pages = {} }
    win = Kit.Window({
        name = "ForeverNotesOptions", title = addonName, w = saved.w or 760, h = saved.h or 520, minW = 640, minH = 420,
        maxW = 1600, maxH = 1200, resizable = true, geometry = saved, strata = "HIGH",
        onShow = function()
            if ui.hostHint then
                ui.hostHint:SetText(ns.hosts.eui and L["Also in EllesmereUI: /forevernotes eui"] or "")
            end
            local entry = ui.current and ui.pages[ui.current]
            if entry then
                if entry.view and entry.view.Refresh then entry.view:Refresh() end
                if entry.form then entry.form:Refresh() end
            end
        end,
        onHide = function() Kit.CloseMenu() end,
    })

    -- the mini window for playing on the side: this window steps back while it is open
    win:AddTool("shrink", function()
        win:Hide()
        if ns.Mini and ns.Mini.Show then ns.Mini.Show() else ns.ToggleMini() end
    end, L["Open the mini window"])

    local content = win.content
    local side = Kit.Panel(content, "bgAlt", "border", "panel")
    side:SetPoint("TOPLEFT")
    side:SetPoint("BOTTOMLEFT")
    side:SetWidth(SIDE_W)
    ui.side = side
    BuildSidebar(side)

    local body = CreateFrame("Frame", nil, content)
    body:SetPoint("TOPLEFT", side, "TOPRIGHT", GAP, 0)
    body:SetPoint("BOTTOMRIGHT")
    ui.body = body
    ui.title = Kit.Text(body, 16, "header")
    ui.title:SetPoint("TOPLEFT", 2, -2)
    ui.title:SetPoint("RIGHT", -2, 0)
    ui.title:SetWordWrap(false)
    ui.crumb = Kit.Text(body, 11, "textDim")
    ui.crumb:SetPoint("TOPLEFT", ui.title, "BOTTOMLEFT", 0, -3)
    ui.crumb:SetPoint("RIGHT", -2, 0)
    ui.crumb:SetWordWrap(false)
    local line = Kit.Divider(body)
    line:SetPoint("TOPLEFT", 0, -42)
    line:SetPoint("TOPRIGHT", 0, -42)
    ui.area = CreateFrame("Frame", nil, body)
    ui.area:SetPoint("TOPLEFT", 0, -52)
    ui.area:SetPoint("BOTTOMRIGHT")
    return win
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

-- Shows a page (built on first use); sel = { nid } or { player } selects an entry there.
function Options.ShowPage(key, sel)
    if not win then Create() end
    local page, module = Settings.FindPage(key)
    if not page then page, module = Settings.FindPage("notes") end
    key = page.key
    for k, entry in pairs(ui.pages) do
        if k ~= key then entry.frame:Hide() end
    end
    local entry = ui.pages[key]
    if not entry then
        local frame = CreateFrame("Frame", nil, ui.area)
        frame:SetAllPoints()
        entry = { frame = frame }
        if page.view then
            entry.view = Settings.BuildView(page, ns.Views.FillHost(frame))
        else
            entry.form = Settings.RenderKit(frame, Settings.Rows(page.form, "standalone"))
        end
        ui.pages[key] = entry
    end
    entry.frame:Show()
    ui.current = key
    Saved().page = key
    ui.title:SetText(page.label)
    ui.crumb:SetText(module.title .. "  \194\183  " .. module.desc)
    for _, b in ipairs(ui.nav) do Refresh(b) end
    if entry.view and entry.view.Refresh then entry.view:Refresh() end
    if entry.form then entry.form:Refresh() end
    if sel then Settings.Select(entry.view, sel) end
    return true
end

-- Host entry point (router): opens the window on pageKey (nil = the last page).
function Options.Open(pageKey, sel)
    if not win then Create() end
    win:Show()
    return Options.ShowPage(pageKey or Saved().page or "notes", sel)
end

function Options.Toggle()
    if win and win:IsShown() then
        win:Hide()
    else
        Options.Open()
    end
end

function Options.IsShown()
    return win ~= nil and win:IsShown() and true or false
end

function Options.Hide()
    if win then win:Hide() end
end

-- Key of the shown page and its view or form (nil before the first open).
function Options.Current()
    if not ui then return nil end
    local entry = ui.pages[ui.current]
    return ui.current, entry and (entry.view or entry.form)
end

ns.hosts.standalone = { Open = Options.Open, IsShown = Options.IsShown, Hide = Options.Hide }
