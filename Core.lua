-- ForeverNotes core: namespace, locale choice, event dispatch, SavedVariables, combat queue, page router, slash,
-- compartment. EllesmereUI is optional: every access is guarded, nothing here needs it.
local addonName, ns = ...
local L = ns.L

ns.name = addonName
ForeverNotes = ns -- the only addon global besides SavedVariables, slash and compartment callbacks

-- With "## OptionalDeps: EllesmereUI" EUI loads before us when it is enabled, so this is final at file scope.
ns.euiAtFileLoad = type(EllesmereUI) == "table"

function ns.HasEUI()
    return type(EllesmereUI) == "table"
end

local PREFIX = "|cff6fbfff[ForeverNotes]|r "
local DB_VERSION = 1

local defaults = {
    version = DB_VERSION,
    seq = 0,
    settings = {
        -- theme and accent.mode get their default in UI/Theme.lua (they depend on whether EllesmereUI is loaded)
        accent = { r = 0.24, g = 0.61, b = 1 },
        language = "auto",   -- "auto" | "enUS" | "deDE", applied at load
        integrateEUI = true, -- Notes section in the EllesmereUI options window, applied at load
        options = { w = 760, h = 520, scale = 1, lock = false, page = "notes" },
        minimap = { hide = false, angle = 200 },
        mini = { shown = false, tab = "notes", w = 320, h = 380, scale = 1, lock = false },
        popup = { enabled = true, collapsed = false, hideInCombat = false, hideInInstance = true, lock = false, glow = true },
        sticky = { w = 220, h = 180, size = 12, alpha = 1, hideInCombat = false },
        ignore = { sound = "RAID_WARNING", channel = "Master", soundOn = true, chat = true, markPopup = true,
            syncWoW = false, throttle = 30 },
    },
    groups = {},
    notes = {},
    players = {},
    ignore = {},
}

local frame = CreateFrame("Frame")
local events = {}
local pending = {}
local readyCallbacks = {}

-- Secret values may not be compared, branched on or printed. Guard before use.
function ns.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) and true or false
end

function ns.SafeString(value, fallback)
    if value == nil or ns.IsSecret(value) then return fallback end
    return tostring(value)
end

function ns.Say(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text, 0.95, 0.92, 0.86)
end

-- Run an action now, or after combat ends when it touches protected frames.
function ns.Queue(action)
    if InCombatLockdown() then
        pending[#pending + 1] = action
    else
        action()
    end
end

-- Later modules register work that needs the database and the final locale (runs at the end of ADDON_LOADED).
function ns.OnReady(callback)
    if ns.db then
        callback()
    else
        readyCallbacks[#readyCallbacks + 1] = callback
    end
end

-- Fill missing keys of the saved table from the defaults, recursing into sub-tables.
local function MergeDefaults(db, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(db[key]) ~= "table" then db[key] = {} end
            MergeDefaults(db[key], value)
        elseif db[key] == nil then
            db[key] = value
        end
    end
end

local function Migrate(db)
    -- Version 1 is the first layout; later versions upgrade here, one step at a time.
    db.version = DB_VERSION
end

-- Language: the setting, else EllesmereUI.LOCALE (final inside our ADDON_LOADED, EUI loads first as an optional
-- dependency), else the client, else English.
local function ChooseLocale(choice)
    local locale
    if choice == "enUS" or choice == "deDE" then
        locale = choice
        ns.localeSource = "setting"
    else
        local eui = ns.HasEUI() and EllesmereUI.LOCALE or nil
        if type(eui) == "string" and eui ~= "" then
            locale = eui
            ns.localeSource = "EllesmereUI.LOCALE"
        else
            locale = type(GetLocale) == "function" and GetLocale() or nil
            ns.localeSource = "GetLocale"
        end
    end
    if type(locale) ~= "string" or locale == "" then locale = "enUS" end
    if locale == "enGB" then locale = "enUS" end
    ns.locale = locale
    ns.activeLocale = ns.locales[locale] or ns.locales.enUS
end

-- SavedVariables exist only from ADDON_LOADED on; never touch them at file scope.
function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")

    ns.euiAtLoad = ns.HasEUI()
    ns.localeAtLoad = ns.euiAtLoad and EllesmereUI.LOCALE or nil

    if type(ForeverNotesDB) ~= "table" then ForeverNotesDB = {} end
    MergeDefaults(ForeverNotesDB, defaults)
    Migrate(ForeverNotesDB)
    ns.db = ForeverNotesDB
    ChooseLocale(ForeverNotesDB.settings.language)

    for i = 1, #readyCallbacks do readyCallbacks[i]() end
    wipe(readyCallbacks)
end

function events:PLAYER_REGEN_ENABLED()
    for i = 1, #pending do pending[i]() end
    wipe(pending)
end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Feature hooks, filled by later files; the placeholders keep slash and compartment safe if a file failed to load.
function ns.ToggleMini()
    ns.Say(L["The mini window is not implemented yet."])
end

function ns.NewTargetNote()
    ns.Say(L["Notes for the target are not implemented yet."])
end

---------------------------------------------------------------------------
-- Page router: the same pages live in two hosts. "standalone" is our own options window (always there, works in
-- combat); "eui" is the Notes section in the EllesmereUI options window (only when EUI is loaded and the integration
-- is on). A host registers ns.hosts[key] = { Open(pageKey, sel) -> opened, IsShown(), Hide() };
-- sel = { nid = noteId } or { player = playerKey }.
---------------------------------------------------------------------------

ns.hosts = {}

-- Mini window tabs -> page keys.
local TAB_PAGE = { notes = "notes", drawings = "drawings", players = "players", ignore = "ignore" }

function ns.PreferredHost()
    return ns.hosts.eui and "eui" or "standalone"
end

-- Opens pageKey (nil = the host's default page) in hostKey (nil = preferred). Returns true when a window opened.
function ns.OpenPage(pageKey, sel, hostKey)
    local explicit = hostKey ~= nil
    hostKey = hostKey or ns.PreferredHost()
    if hostKey == "eui" then
        if not ns.hosts.eui then
            if ns.HasEUI() then
                ns.Say(L["The EllesmereUI integration is off. Turn it on under Settings > General, then /reload."])
            else
                ns.Say(L["EllesmereUI is not loaded. Use /forevernotes options."])
            end
            return false
        end
        if InCombatLockdown() then
            if explicit then
                ns.Say(L["The EllesmereUI window cannot be opened in combat. /forevernotes options works."])
                return false
            end
            hostKey = "standalone" -- our own window is not protected, it opens in combat too
        end
    end
    local host = ns.hosts[hostKey]
    if not host then return false end
    return host.Open(pageKey, sel) and true or false
end

-- Slash command: open the options window; a standalone window that is already open closes again.
function ns.OpenPanel(hostKey)
    local key = hostKey or ns.PreferredHost()
    if key == "eui" and InCombatLockdown() and not hostKey then key = "standalone" end
    -- EllesmereUI is loaded and the integration is switched on, but its section is not registered: say why, then
    -- the own window opens instead
    if key == "standalone" and not hostKey and not ns.hosts.eui and ns.HasEUI() and ns.db and ns.db.settings.integrateEUI then
        ns.Say(L["The EllesmereUI section is not active (%s). Try /reload."]:format(tostring(ns.registerResult)))
    end
    local host = ns.hosts[key]
    if key == "standalone" and host and host.IsShown() then
        host.Hide()
        return true
    end
    return ns.OpenPage(nil, nil, hostKey)
end

-- Opens the page of a mini window tab ("notes", "drawings", "players", "ignore"); with a player key that player is
-- selected. Returns true when it opened.
function ns.OpenPanelPage(tab, playerKey)
    return ns.OpenPage(TAB_PAGE[tab] or "notes", playerKey and { player = playerKey } or nil)
end

-- Jump to a note (sticky note menu, mini window hand-over) in the preferred host.
function ns.RevealNote(nid)
    local note = ns.Store and ns.Store.GetNote(nid)
    if not note then return false end
    local page = note.kind == "drawing" and "drawings" or "notes"
    if note.player then page = "players" end
    return ns.OpenPage(page, { nid = nid })
end

local function Help()
    ns.Say(L["Commands:"])
    ns.Say(L["/forevernotes - open or close the options window"])
    ns.Say(L["/forevernotes options - the ForeverNotes window (also in combat)"])
    if ns.HasEUI() then ns.Say(L["/forevernotes eui - the Notes section in EllesmereUI"]) end
    ns.Say(L["/forevernotes mini - toggle the mini window"])
    ns.Say(L["/forevernotes minimap - show or hide the minimap button"])
    ns.Say(L["/forevernotes note - new note for your target"])
end

SLASH_FOREVERNOTES1 = "/forevernotes"
SLASH_FOREVERNOTES2 = "/fnotes"
SlashCmdList["FOREVERNOTES"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        ns.OpenPanel()
    elseif cmd == "options" then
        ns.OpenPanel("standalone")
    elseif cmd == "eui" then
        ns.OpenPage(nil, nil, "eui")
    elseif cmd == "mini" then
        ns.ToggleMini()
    elseif cmd == "minimap" and ns.MinimapButton then
        ns.MinimapButton.Toggle()
    elseif cmd == "note" then
        ns.NewTargetNote()
    elseif ns.devCommands and ns.devCommands[cmd] then -- registered by files of the development checkout only
        ns.devCommands[cmd](rest:lower())
    elseif cmd == "help" then
        Help()
    else
        ns.Say(L["Unknown command."])
        Help()
    end
end

-- Addon compartment callbacks must be real globals (named in the TOC).
-- Same as the minimap button: left-click opens the main window (the EllesmereUI section when it is active, else our
-- own window), right-click toggles the mini window.
function ForeverNotes_OnCompartmentClick(_, mouseButton)
    if mouseButton == "RightButton" then
        ns.ToggleMini()
    else
        ns.OpenPanel()
    end
end

function ForeverNotes_OnCompartmentEnter(_, owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(addonName, 1, 0.82, 0.45)
    GameTooltip:AddLine(L["Left-click: open ForeverNotes"], 0.9, 0.9, 0.9)
    GameTooltip:AddLine(L["Right-click: mini window"], 0.9, 0.9, 0.9)
    GameTooltip:Show()
end

function ForeverNotes_OnCompartmentLeave()
    GameTooltip:Hide()
end
