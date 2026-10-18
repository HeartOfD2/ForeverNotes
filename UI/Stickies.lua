-- ForeverNotes sticky notes: any note (text or drawing) can sit on the screen as its own small window.
-- The bar moves it, the corner resizes it; buttons fold it to the bar, lock it, close it. State lives on the note
-- (note.sticky = { open, x, y, w, h, folded, lock, dock }), so open stickies come back after a reload.
-- Dropped at the edge of another sticky, a note docks there: it takes that note's size and moves with it.
-- Plain unprotected frames on one layer that can step aside in combat.
local _, ns = ...
local L = ns.L
local Store, Kit, Theme, Editor = ns.Store, ns.Kit, ns.Theme, ns.Editor

local Stickies = {}
ns.Stickies = Stickies

local BAR_H, FOOT_H = 26, 24
local MIN_W, MIN_H = 160, 90
local DOCK_GAP, SNAP, SNAP_W = 4, 18, 3
local DOCK_POINTS = { -- side of the host -> our point, host point, x, y
    RIGHT = { "TOPLEFT", "TOPRIGHT", DOCK_GAP, 0 },
    LEFT = { "TOPRIGHT", "TOPLEFT", -DOCK_GAP, 0 },
    BOTTOM = { "TOPLEFT", "BOTTOMLEFT", 0, -DOCK_GAP },
    TOP = { "BOTTOMLEFT", "TOPLEFT", 0, DOCK_GAP },
}
local OPPOSITE = { LEFT = "RIGHT", RIGHT = "LEFT", TOP = "BOTTOM", BOTTOM = "TOP" }

Stickies.BAR_H, Stickies.MIN_W, Stickies.MIN_H = BAR_H, MIN_W, MIN_H
Kit.GLYPHS.menu = { { 0.16, 0.5, 0.26, 0.5 }, { 0.45, 0.5, 0.55, 0.5 }, { 0.74, 0.5, 0.84, 0.5 } }

local frames, byId = {}, {}
local cascade = 0
local layer

local function Settings() return ns.db.settings.sticky end

local function Sticky(nid) return Store.GetSticky(nid) or {} end

local function Geo(f) return f.nid and Store.GetNote(f.nid) and (Store.GetNote(f.nid).sticky or {}) or {} end

-- State changes go through the store (it also announces them), never straight into the table.
local function Save(f, fields)
    if f.nid and Store.GetNote(f.nid) then Store.SetSticky(f.nid, fields) end
end

function Stickies.IsOpen(nid)
    local sticky = Store.GetSticky(nid)
    return sticky ~= nil and sticky.open == true
end

function Stickies.Count()
    local n = 0
    for _ in pairs(byId) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Docking
---------------------------------------------------------------------------

function Stickies.HostOf(f)
    local dock = Geo(f).dock
    local host = dock and byId[dock.id]
    if host and host ~= f then return host end
end

function Stickies.DockedTo(f)
    local out = {}
    for nid, x in pairs(byId) do
        local dock = x ~= f and Sticky(nid).dock
        if dock and dock.id == f.nid then out[#out + 1] = x end
    end
    return out
end

local function HangsOn(a, b)
    local x, guard = a, 0
    while x and guard < 50 do
        if x == b then return true end
        x, guard = Stickies.HostOf(x), guard + 1
    end
    return false
end

local function FullHeight(f)
    local g = Geo(f)
    if g.folded then return math.max(MIN_H, g.h or Settings().h) end
    return f:GetHeight()
end

-- Places the windows docked to f at f and gives them its size; what hangs on them follows.
function Stickies.Relayout(f, depth)
    if (depth or 0) > 20 then return end -- damaged saved data must not loop
    for _, x in ipairs(Stickies.DockedTo(f)) do
        local g = Geo(x)
        local pt = DOCK_POINTS[g.dock and g.dock.side]
        if pt then
            x:ClearAllPoints()
            x:SetPoint(pt[1], f, pt[2], pt[3], pt[4])
            x:SetWidth(f:GetWidth())
            x:SetHeight(g.folded and BAR_H or FullHeight(f))
            Stickies.Relayout(x, (depth or 0) + 1)
        end
    end
end

-- The open window and side f would dock to if it were dropped now.
function Stickies.FindSnap(f)
    local fl, fr, ft, fb = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (fl and ft and fr and fb) then return end
    local best, bestSide, bestDist
    for _, x in pairs(byId) do
        if x ~= f and x:IsShown() and not HangsOn(x, f) then
            local xl, xr, xt, xb = x:GetLeft(), x:GetRight(), x:GetTop(), x:GetBottom()
            if xl and xt and xr and xb then
                local taken = {}
                for _, y in ipairs(Stickies.DockedTo(x)) do taken[Geo(y).dock.side] = true end
                local vOverlap = ft > xb and fb < xt
                local hOverlap = fr > xl and fl < xr
                local tries = {
                    { "RIGHT", math.abs(fl - (xr + DOCK_GAP)), vOverlap },
                    { "LEFT", math.abs(fr - (xl - DOCK_GAP)), vOverlap },
                    { "BOTTOM", math.abs(ft - (xb - DOCK_GAP)), hOverlap },
                    { "TOP", math.abs(fb - (xt + DOCK_GAP)), hOverlap },
                }
                for _, t in ipairs(tries) do
                    if t[3] and t[2] <= SNAP and not taken[t[1]] and (not bestDist or t[2] < bestDist) then
                        best, bestSide, bestDist = x, t[1], t[2]
                    end
                end
            end
        end
    end
    return best, bestSide
end

local snapShown = {}

function Stickies.HideSnap()
    for _, x in ipairs(snapShown) do x.snapLine:Hide() end
    wipe(snapShown)
end

local function EdgeLine(x, side)
    local tex = x.snapLine
    tex:ClearAllPoints()
    if side == "LEFT" or side == "RIGHT" then
        tex:SetPoint("TOP" .. side)
        tex:SetPoint("BOTTOM" .. side)
        tex:SetWidth(SNAP_W)
    else
        tex:SetPoint(side .. "LEFT")
        tex:SetPoint(side .. "RIGHT")
        tex:SetHeight(SNAP_W)
    end
    tex:Show()
    snapShown[#snapShown + 1] = x
end

-- Both meeting edges light up while dragging.
function Stickies.ShowSnap(f)
    local x, side = Stickies.FindSnap(f)
    Stickies.HideSnap()
    if not x then return end
    EdgeLine(x, side)
    EdgeLine(f, OPPOSITE[side])
end

---------------------------------------------------------------------------
-- Window parts
---------------------------------------------------------------------------

local Paint, ApplyGeometry

local function SaveGeometry(f)
    local l, t = f:GetLeft(), f:GetTop()
    if not (l and t and f.nid) then return end
    if Stickies.HostOf(f) then return end -- docked: the host decides
    local g = Geo(f)
    local fields = { x = l, y = t, w = f:GetWidth() }
    if not g.folded then fields.h = f:GetHeight() end
    Save(f, fields)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
end

-- Free again where it is now, at the size it has now.
function Stickies.Undock(f)
    local g = Geo(f)
    local l, t = f:GetLeft(), f:GetTop()
    local fields = { dock = false }
    if l and t then
        fields.x, fields.y, fields.w = l, t, f:GetWidth()
        if not g.folded then fields.h = f:GetHeight() end
    end
    Save(f, fields)
    local now = Geo(f)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", now.x or 0, now.y or 0)
    Paint(f)
end

function Stickies.Dock(f, host, side)
    Save(f, { dock = { id = host.nid, side = side } })
    ApplyGeometry(f)
    Paint(f)
end

local function NewWindow()
    local f = Kit.Panel(layer, "bg", "border", "window")
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    if f.SetResizeBounds then f:SetResizeBounds(MIN_W, MIN_H, 1000, 1000) end

    -- bar: drag to move, double click folds
    local bar = CreateFrame("Button", nil, f)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(BAR_H)
    bar:RegisterForDrag("LeftButton")
    bar:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    Theme.Bind(bar.bg, function(self, T) Theme.Paint(self, T.bgAlt) end)
    bar.stripe = bar:CreateTexture(nil, "ARTWORK")
    bar.stripe:SetPoint("TOPLEFT")
    bar.stripe:SetPoint("TOPRIGHT")
    bar.stripe:SetHeight(3)
    f.bar = bar
    bar:SetScript("OnDragStart", function()
        if Geo(f).lock then return end
        if Stickies.HostOf(f) then Stickies.Undock(f) end -- pulled away: free again
        f:StartMoving()
        bar:SetScript("OnUpdate", function() Stickies.ShowSnap(f) end)
    end)
    bar:SetScript("OnDragStop", function()
        bar:SetScript("OnUpdate", nil)
        f:StopMovingOrSizing()
        Stickies.HideSnap()
        local host, side = Stickies.FindSnap(f)
        if host then Stickies.Dock(f, host, side) else SaveGeometry(f) end
    end)
    bar:SetScript("OnDoubleClick", function() Stickies.Fold(f) end)
    bar:SetScript("OnClick", function(_, button)
        if button == "RightButton" then f.menu:Click() end
    end)

    f.close = Kit.IconButton(bar, 20, "close", function() Stickies.Close(f.nid) end, L["Close"])
    f.close:SetPoint("RIGHT", -3, -1)
    f.lock = Kit.IconButton(bar, 20, "unlock", function()
        Save(f, { lock = not Geo(f).lock or false })
    end, function() return Geo(f).lock and L["Unlock window"] or L["Lock window"] end)
    f.lock:SetPoint("RIGHT", f.close, "LEFT", -1, 0)
    f.fold = Kit.IconButton(bar, 20, "up", function() Stickies.Fold(f) end, L["Fold to the bar"])
    f.fold:SetPoint("RIGHT", f.lock, "LEFT", -1, 0)
    f.menu = Kit.IconButton(bar, 20, "menu", function(self)
        local items = { { text = L["Open in the notes"], func = function() if ns.RevealNote then ns.RevealNote(f.nid) end end } }
        if Stickies.HostOf(f) then
            items[#items + 1] = { text = L["Undock"], func = function() Stickies.Undock(f) end }
        else
            items[#items + 1] = { text = L["Default size"], func = function()
                local s = Settings()
                Save(f, { w = s.w, h = s.h, folded = false })
                ApplyGeometry(f)
            end }
        end
        items[#items + 1] = { text = L["Close"], func = function() Stickies.Close(f.nid) end }
        Kit.OpenMenu(self, items)
    end, L["More"])
    f.menu:SetPoint("LEFT", 3, -1)
    f.title = Kit.Text(bar, 12)
    f.title:SetPoint("LEFT", f.menu, "RIGHT", 4, 0)
    f.title:SetPoint("RIGHT", f.fold, "LEFT", -4, 0)
    f.title:SetWordWrap(false)

    -- body: formatted text (editor) or a drawing (board)
    local body = CreateFrame("Frame", nil, f)
    body:SetPoint("TOPLEFT", 1, -BAR_H - 1)
    body:SetPoint("BOTTOMRIGHT", -1, FOOT_H + 1)
    f.body = body
    f.ne = Editor.Create(body, { size = Settings().size })
    f.ne:SetPoint("TOPLEFT", 4, -2)
    f.ne:SetPoint("BOTTOMRIGHT", -4, 0)
    f.ne.canEdit = function() return f.nid and not Geo(f).folded end
    f.ne.onEditing = function(on)
        f.editing = on or nil
        Paint(f)
    end
    f.ne.onChange = function() Paint(f) end
    f.canvas = ns.Canvas.Create(body, { toolbar = false })
    f.canvas:SetPoint("TOPLEFT", 4, -4)
    f.canvas:SetPoint("BOTTOMRIGHT", -4, 4)
    f.canvas:Hide()

    -- footer: line buttons (text) or undo/redo (drawing), progress, resize corner
    local foot = CreateFrame("Frame", nil, f)
    foot:SetPoint("BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", -1, 1)
    foot:SetHeight(FOOT_H)
    f.foot = foot
    foot.line = Kit.Divider(foot)
    foot.line:SetPoint("TOPLEFT")
    foot.line:SetPoint("TOPRIGHT")
    f.checkBtn, f.listBtn, f.numBtn = f.ne:ToolButtons(foot)
    f.checkBtn:SetPoint("LEFT", 6, 0)
    f.done = Kit.Button(foot, 56, L["Done"], function() f.ne:StopEditing() end, 18)
    f.done:SetPoint("LEFT", f.numBtn, "RIGHT", 6, 0)
    f.undoBtn = Kit.IconButton(foot, 20, "undo", function() f.canvas:Undo() end, L["Undo"])
    f.undoBtn:SetPoint("LEFT", 6, 0)
    f.redoBtn = Kit.IconButton(foot, 20, "redo", function() f.canvas:Redo() end, L["Redo"])
    f.redoBtn:SetPoint("LEFT", f.undoBtn, "RIGHT", 2, 0)
    f.progress = Kit.Text(foot, 11, "textDim")
    f.progress:SetPoint("RIGHT", -24, 0)

    f.grip = CreateFrame("Button", nil, f)
    f.grip:SetSize(14, 14)
    f.grip:SetPoint("BOTTOMRIGHT", -2, 2)
    f.grip:SetFrameLevel(f:GetFrameLevel() + 10)
    f.grip.glyph = Kit.Glyph(f.grip, "grip", 12, "textDim")
    f.grip.glyph:SetPoint("CENTER")
    f.grip:SetScript("OnMouseDown", function()
        if not Geo(f).lock then f:StartSizing("BOTTOMRIGHT") end
    end)
    f.grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SaveGeometry(f)
    end)
    f:SetScript("OnSizeChanged", function()
        if f.nid then Stickies.Relayout(f) end -- docked notes keep the same size
    end)

    -- bold accent line on the edge where two notes would meet
    f.snapBar = CreateFrame("Frame", nil, f)
    f.snapBar:SetAllPoints()
    f.snapBar:SetFrameLevel(f:GetFrameLevel() + 30)
    f.snapLine = f.snapBar:CreateTexture(nil, "OVERLAY")
    Theme.Bind(f.snapLine, function(self, T) Theme.Paint(self, T.accent) end)
    f.snapLine:Hide()

    frames[#frames + 1] = f
    return f
end

-- Color of the stripe: the note's group, the player's class, else the accent.
local function StripeColor(note)
    local group = note.group and Store.GetGroup(note.group)
    if group then return group.color end
    local player = note.player and Store.GetPlayer(note.player)
    if player and player.class then return { Store.ClassColor(player.class) } end
    return nil
end

Paint = function(f)
    local note = f.nid and Store.GetNote(f.nid)
    if not note then return end
    local color = StripeColor(note)
    if color then
        f.bar.stripe:SetColorTexture(color[1], color[2], color[3], 1)
    else
        local T = Theme.Get(Theme.CtxOf(f))
        f.bar.stripe:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
    end
    local title = Store.NoteTitle(note)
    if note.player then title = Store.PlayerLabel(note.player) .. " - " .. title end
    f.title:SetText(title)
    local g = note.sticky or {}
    f.lock:SetGlyph(g.lock and "lock" or "unlock")
    f.lock:SetActive(g.lock and true or false)
    f.fold:SetGlyph(g.folded and "down" or "up")
    local isText = note.kind == "text"
    f.checkBtn:SetShown(isText)
    f.listBtn:SetShown(isText)
    f.numBtn:SetShown(isText)
    f.done:SetShown(isText and f.editing and true or false)
    f.undoBtn:SetShown(not isText)
    f.redoBtn:SetShown(not isText)
    if isText then
        local done, total = f.ne:Progress()
        f.progress:SetText(total > 0 and ("%d/%d"):format(done, total) or "")
    else
        f.progress:SetText("")
    end
    f.grip:SetShown(not g.lock and not g.folded and not Stickies.HostOf(f))
end
Stickies.Paint = Paint

ApplyGeometry = function(f)
    local g, s = Geo(f), Settings()
    f.body:SetShown(not g.folded)
    f.foot:SetShown(not g.folded)
    if g.folded and f.ne then f.ne:StopEditing() end
    if Stickies.HostOf(f) then
        local host = Stickies.HostOf(f)
        Stickies.Relayout(host)
        return
    end
    f:ClearAllPoints()
    if not (g.x and g.y) then
        -- new on screen: a little cascade around the middle
        cascade = (cascade % 8) + 1
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local x = w / 2 - (g.w or s.w) / 2 + cascade * 24 - 96
        local y = h / 2 + 120 - cascade * 24
        Save(f, { x = x, y = y })
        g = Geo(f)
    end
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", g.x, g.y)
    f:SetWidth(math.max(MIN_W, g.w or s.w))
    f:SetHeight(g.folded and BAR_H or math.max(MIN_H, g.h or s.h))
    Stickies.Relayout(f)
end
Stickies.ApplyGeometry = ApplyGeometry

function Stickies.Fold(f)
    local g = Geo(f)
    if f.editing then f.ne:StopEditing() end
    if not g.folded then SaveGeometry(f) end
    Save(f, { folded = not g.folded })
    ApplyGeometry(f)
    Paint(f)
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

local function Bind(f, nid)
    f.nid = nid
    byId[nid] = f
    local note = Store.GetNote(nid)
    if note.kind == "text" then
        f.canvas:Hide()
        f.canvas:SetNote(nil)
        f.ne:Show()
        f.ne:SetFontSize(Settings().size)
        f.ne:SetNote(nid)
    else
        f.ne:SetNote(nil)
        f.ne:Hide()
        f.canvas:Show()
        f.canvas:SetNote(nid)
    end
end

function Stickies.Open(nid)
    local note = Store.GetNote(nid)
    if not note then return end
    local f = byId[nid]
    if not f then
        for _, x in ipairs(frames) do
            if not x.nid then
                f = x
                break
            end
        end
        f = f or NewWindow()
        Bind(f, nid)
    end
    Save(f, { open = true })
    ApplyGeometry(f)
    f:SetAlpha(Settings().alpha or 1)
    f:Show()
    f:Raise()
    Paint(f)
    -- notes that were docked here and are already open come back to it
    for _, x in ipairs(Stickies.DockedTo(f)) do
        ApplyGeometry(x)
        Paint(x)
    end
    return f
end

local function Release(f)
    f:Hide()
    if f.ne then f.ne:SetNote(nil) end
    if f.canvas then f.canvas:SetNote(nil) end
    byId[f.nid] = nil
    f.nid = nil
end

function Stickies.Close(nid)
    local f = byId[nid]
    if Store.GetNote(nid) and Store.GetSticky(nid) then Store.SetSticky(nid, { open = false }) end
    if not f then return end
    for _, x in ipairs(Stickies.DockedTo(f)) do Stickies.Undock(x) end -- they stay where they are
    if Stickies.HostOf(f) then
        local l, t = f:GetLeft(), f:GetTop()
        if l and t then Store.SetSticky(nid, { x = l, y = t, dock = false }) end
    end
    if f.editing then f.ne:StopEditing() end
    Release(f)
end

function Stickies.Toggle(nid)
    if Stickies.IsOpen(nid) then Stickies.Close(nid) else Stickies.Open(nid) end
end

function Stickies.CloseAll()
    local ids = {}
    for nid in pairs(byId) do ids[#ids + 1] = nid end
    for _, nid in ipairs(ids) do Stickies.Close(nid) end
end

-- After settings changed (size, transparency, combat behaviour).
function Stickies.ApplySettings()
    local s = Settings()
    for _, f in pairs(byId) do
        f:SetAlpha(s.alpha or 1)
        f.ne:SetFontSize(s.size)
    end
    if layer then layer:SetShown(not (s.hideInCombat and InCombatLockdown())) end
end

---------------------------------------------------------------------------
-- Following the store and the game
---------------------------------------------------------------------------

local function Sync(kind, id)
    if not next(byId) then return end
    if kind == "note" or kind == "sticky" or kind == "group" or kind == "player" then
        local gone = {}
        for nid, f in pairs(byId) do
            if not Store.GetNote(nid) then gone[#gone + 1] = f else Paint(f) end
        end
        for _, f in ipairs(gone) do
            for _, x in ipairs(Stickies.DockedTo(f)) do Stickies.Undock(x) end
            Release(f)
        end
    end
end

ns.OnReady(function()
    layer = CreateFrame("Frame", nil, UIParent)
    layer:SetAllPoints(UIParent)
    layer:SetFrameStrata("MEDIUM")
    Store.OnChanged(Sync)
    Theme.OnChange(function() for _, f in pairs(byId) do Paint(f) end end)

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:SetScript("OnEvent", function() Stickies.ApplySettings() end)

    -- reopen what was open; docks need every host open first
    for _, nid in ipairs(Store.OpenStickies()) do Stickies.Open(nid) end
    for _, f in pairs(byId) do
        if Stickies.HostOf(f) then
            ApplyGeometry(f)
            Paint(f)
        end
    end
    Stickies.ApplySettings()
end)
