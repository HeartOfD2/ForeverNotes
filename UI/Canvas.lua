-- ForeverNotes drawing board: a minimal paint surface bound to a stored drawing note.
-- Strokes are kept in 0..1000 units (independent of window size and aspect ratio), drawn with Line objects.
-- Tools: pen, eraser (paints the canvas color), line, rectangle, ellipse; palette, five widths, undo, redo, clear.
-- Mouse handling uses OnUpdate only while the left button is held.
local _, ns = ...
local L = ns.L
local Store, Kit, Theme = ns.Store, ns.Kit, ns.Theme

local Canvas = {}
ns.Canvas = Canvas

local UNITS = 1000
local ELLIPSE_SEGMENTS = 32
local MIN_STEP2 = 16 -- pen points closer than 4 units are skipped (squared distance)
local WIDTHS = { 1, 2, 4, 7, 12 }
local PALETTE = {
    { 1, 1, 1 }, { 0.62, 0.62, 0.62 }, { 0, 0, 0 }, { 0.92, 0.26, 0.26 }, { 0.96, 0.60, 0.20 }, { 0.96, 0.85, 0.30 },
    { 0.40, 0.80, 0.35 }, { 0.20, 0.75, 0.70 }, { 0.30, 0.65, 0.95 }, { 0.40, 0.45, 0.90 }, { 0.68, 0.45, 0.90 },
    { 0.92, 0.45, 0.75 },
}

-- Vector icons for the tool buttons (unit square, origin bottom left), added to the kit's glyph table.
local function Ellipse(cx, cy, rx, ry, steps)
    local segs = {}
    for i = 0, steps - 1 do
        local a1, a2 = (i / steps) * 2 * math.pi, ((i + 1) / steps) * 2 * math.pi
        segs[#segs + 1] = { cx + rx * math.cos(a1), cy + ry * math.sin(a1), cx + rx * math.cos(a2), cy + ry * math.sin(a2) }
    end
    return segs
end
Kit.GLYPHS.pen = { { 0.22, 0.22, 0.30, 0.45 }, { 0.22, 0.22, 0.45, 0.30 }, { 0.30, 0.45, 0.45, 0.30 },
    { 0.30, 0.45, 0.70, 0.85 }, { 0.45, 0.30, 0.85, 0.70 }, { 0.70, 0.85, 0.85, 0.70 } }
Kit.GLYPHS.eraser = { { 0.15, 0.35, 0.45, 0.15 }, { 0.45, 0.15, 0.85, 0.55 }, { 0.85, 0.55, 0.55, 0.75 },
    { 0.55, 0.75, 0.15, 0.35 }, { 0.30, 0.25, 0.70, 0.65 } }
Kit.GLYPHS.line = { { 0.2, 0.2, 0.8, 0.8 } }
Kit.GLYPHS.rect = { { 0.2, 0.28, 0.8, 0.28 }, { 0.8, 0.28, 0.8, 0.72 }, { 0.8, 0.72, 0.2, 0.72 }, { 0.2, 0.72, 0.2, 0.28 } }
Kit.GLYPHS.ellipse = Ellipse(0.5, 0.5, 0.34, 0.25, 16)
Kit.GLYPHS.undo = { { 0.22, 0.58, 0.42, 0.78 }, { 0.22, 0.58, 0.42, 0.38 }, { 0.22, 0.58, 0.68, 0.58 },
    { 0.68, 0.58, 0.82, 0.46 }, { 0.82, 0.46, 0.82, 0.28 } }
Kit.GLYPHS.redo = { { 0.78, 0.58, 0.58, 0.78 }, { 0.78, 0.58, 0.58, 0.38 }, { 0.78, 0.58, 0.32, 0.58 },
    { 0.32, 0.58, 0.18, 0.46 }, { 0.18, 0.46, 0.18, 0.28 } }

---------------------------------------------------------------------------
-- Geometry (pure functions, testable offline)
---------------------------------------------------------------------------

-- Segments of one stroke as { x1, y1, x2, y2 } in drawing units; the count matches Store.StrokeSegments.
function Canvas.Segments(stroke)
    local p, kind, out = stroke.p, stroke.t, {}
    if kind == "pen" or kind == "erase" then
        if #p <= 2 then
            out[1] = { p[1], p[2], math.min(UNITS, p[1] + 1), p[2] }
        else
            for i = 1, #p - 3, 2 do out[#out + 1] = { p[i], p[i + 1], p[i + 2], p[i + 3] } end
        end
    elseif kind == "line" then
        out[1] = { p[1], p[2], p[3], p[4] }
    elseif kind == "rect" then
        local x1, y1, x2, y2 = p[1], p[2], p[3], p[4]
        out[1] = { x1, y1, x2, y1 }
        out[2] = { x2, y1, x2, y2 }
        out[3] = { x2, y2, x1, y2 }
        out[4] = { x1, y2, x1, y1 }
    elseif kind == "ellipse" then
        local cx, cy = (p[1] + p[3]) / 2, (p[2] + p[4]) / 2
        local rx, ry = math.abs(p[3] - p[1]) / 2, math.abs(p[4] - p[2]) / 2
        for i = 0, ELLIPSE_SEGMENTS - 1 do
            local a1, a2 = (i / ELLIPSE_SEGMENTS) * 2 * math.pi, ((i + 1) / ELLIPSE_SEGMENTS) * 2 * math.pi
            out[#out + 1] = { cx + rx * math.cos(a1), cy + ry * math.sin(a1), cx + rx * math.cos(a2), cy + ry * math.sin(a2) }
        end
    end
    return out
end

local function Clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

---------------------------------------------------------------------------
-- Line pools
---------------------------------------------------------------------------

local function NewPool(surface)
    return { surface = surface, n = 0 }
end

local function Take(pool)
    pool.n = pool.n + 1
    local line = pool[pool.n]
    if not line then
        line = pool.surface:CreateLine(nil, "ARTWORK")
        pool[pool.n] = line
    end
    line:Show()
    return line
end

local function Release(pool)
    for i = pool.n + 1, #pool do pool[i]:Hide() end
end

local function Reset(pool)
    pool.n = 0
end

local function Place(pool, seg, w, h, thickness, r, g, b)
    local line = Take(pool)
    line:SetThickness(thickness)
    line:SetColorTexture(r, g, b, 1)
    line:SetStartPoint("TOPLEFT", pool.surface, seg[1] / UNITS * w, -seg[2] / UNITS * h)
    line:SetEndPoint("TOPLEFT", pool.surface, seg[3] / UNITS * w, -seg[4] / UNITS * h)
end

---------------------------------------------------------------------------
-- Methods
---------------------------------------------------------------------------

local Methods = {}

-- Pixel thickness for a stored width: grows with the surface so a drawing keeps its look when resized.
function Methods:Thickness(width)
    local w, h = self.surface:GetWidth(), self.surface:GetHeight()
    local scale = Clamp(math.min(w, h) / 360, 0.6, 3)
    return math.max(1, width * scale)
end

function Methods:CanvasColor()
    local T = Theme.Get(Theme.CtxOf(self))
    return T.canvasBg or T.inputBg or { 0, 0, 0 }
end

function Methods:Ink()
    if self.color then return self.color end
    local T = Theme.Get(Theme.CtxOf(self))
    return T.text
end

function Methods:Render()
    self.renderQueued = false
    local surface = self.surface
    local w, h = surface:GetWidth(), surface:GetHeight()
    Reset(self.pool)
    local note = Store.GetNote(self.nid)
    if note and note.kind == "drawing" and w and h and w > 1 and h > 1 then
        local bg = self:CanvasColor()
        for _, stroke in ipairs(note.drawing.strokes) do
            local c = stroke.t == "erase" and bg or stroke.c
            local thickness = self:Thickness(stroke.w)
            for _, seg in ipairs(Canvas.Segments(stroke)) do
                Place(self.pool, seg, w, h, thickness, c[1], c[2], c[3])
            end
        end
    end
    Release(self.pool)
    Reset(self.preview)
    Release(self.preview)
    self:UpdateButtons()
end

function Methods:QueueRender()
    if self.renderQueued then return end
    self.renderQueued = true
    C_Timer.After(0, function()
        if self.renderQueued then self:Render() end
    end)
end

function Methods:UpdateButtons()
    local note = Store.GetNote(self.nid)
    local strokes = note and note.kind == "drawing" and #note.drawing.strokes or 0
    local enabled = note ~= nil and note.kind == "drawing"
    self.undoButton:SetAlpha(strokes > 0 and 1 or 0.35)
    self.redoButton:SetAlpha(#self.redo > 0 and 1 or 0.35)
    self.clearButton:SetEnabled(strokes > 0)
    self.surface:EnableMouse(enabled)
end

function Methods:SetNote(nid)
    self:CancelStroke()
    local note = nid and Store.GetNote(nid)
    self.nid = note and note.kind == "drawing" and nid or nil
    self.redo = {}
    self:Render()
end

function Methods:Flush() end -- strokes are saved as they are finished

---------------------------------------------------------------------------
-- Drawing with the mouse
---------------------------------------------------------------------------

function Methods:Cursor()
    local surface = self.surface
    local scale = surface:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    local left, top = surface:GetLeft(), surface:GetTop()
    local w, h = surface:GetWidth(), surface:GetHeight()
    if not (scale and scale > 0 and left and top and w and h and w > 0 and h > 0) then return nil end
    local x = (cx / scale - left) / w * UNITS
    local y = (top - cy / scale) / h * UNITS
    return math.floor(Clamp(x, 0, UNITS) + 0.5), math.floor(Clamp(y, 0, UNITS) + 0.5)
end

function Methods:Limit()
    local note = Store.GetNote(self.nid)
    return note and Store.CountSegments(note.drawing) or 0
end

function Methods:DrawPreview()
    local stroke = self.current
    local surface = self.surface
    local w, h = surface:GetWidth(), surface:GetHeight()
    Reset(self.preview)
    local c = stroke.t == "erase" and self:CanvasColor() or stroke.c
    local thickness = self:Thickness(stroke.w)
    for _, seg in ipairs(Canvas.Segments(stroke)) do Place(self.preview, seg, w, h, thickness, c[1], c[2], c[3]) end
    Release(self.preview)
end

function Methods:StartStroke()
    if not self.nid then return end
    local x, y = self:Cursor()
    if not x then return end
    if self:Limit() >= Store.MAX_SEGMENTS then
        ns.Say(L["This drawing is full. Delete something or start a new one."])
        return
    end
    local tool = self.tool
    local c = self:Ink()
    self.current = { t = tool, c = { c[1], c[2], c[3] }, w = self.width, p = { x, y } }
    self.lastX, self.lastY = x, y
    self.base = self:Limit()
    if tool == "pen" or tool == "erase" then
        self:DrawPreview()
    else
        self.current.p[3], self.current.p[4] = x, y
    end
    self.surface:SetScript("OnUpdate", function() self:Track() end)
end

function Methods:Track()
    local stroke = self.current
    if not stroke then return end
    if not IsMouseButtonDown("LeftButton") then
        self:FinishStroke()
        return
    end
    local x, y = self:Cursor()
    if not x then return end
    local p = stroke.p
    if stroke.t == "pen" or stroke.t == "erase" then
        local dx, dy = x - self.lastX, y - self.lastY
        if dx * dx + dy * dy < MIN_STEP2 then return end
        if self.base + Store.StrokeSegments(stroke) + 1 > Store.MAX_SEGMENTS then
            self:FinishStroke()
            ns.Say(L["This drawing is full. Delete something or start a new one."])
            return
        end
        p[#p + 1], p[#p + 2] = x, y
        self.lastX, self.lastY = x, y
        -- only the newest segment is added to the preview
        local surface = self.surface
        local w, h = surface:GetWidth(), surface:GetHeight()
        local c = stroke.t == "erase" and self:CanvasColor() or stroke.c
        Place(self.preview, { p[#p - 3], p[#p - 2], p[#p - 1], p[#p] }, w, h, self:Thickness(stroke.w), c[1], c[2], c[3])
    else
        p[3], p[4] = x, y
        self:DrawPreview()
    end
end

function Methods:CancelStroke()
    self.current = nil
    self.surface:SetScript("OnUpdate", nil)
    Reset(self.preview)
    Release(self.preview)
end

function Methods:FinishStroke()
    local stroke = self.current
    self.current = nil
    self.surface:SetScript("OnUpdate", nil)
    if not stroke then return end
    local p = stroke.p
    -- a click without movement makes a dot for pen/eraser and nothing for shapes
    if (stroke.t == "line" or stroke.t == "rect" or stroke.t == "ellipse") and p[1] == p[3] and p[2] == p[4] then
        Reset(self.preview)
        Release(self.preview)
        return
    end
    local ok, why = Store.AddStroke(self.nid, stroke)
    if ok then
        self.redo = {}
    elseif why == "limit" then
        ns.Say(L["This drawing is full. Delete something or start a new one."])
    end
    self:Render()
end

function Methods:Undo()
    if not self.nid then return end
    local stroke = Store.PopStroke(self.nid)
    if stroke then self.redo[#self.redo + 1] = stroke end
    self:Render()
end

function Methods:Redo()
    if not self.nid then return end
    local stroke = table.remove(self.redo)
    if stroke then Store.AddStroke(self.nid, stroke) end
    self:Render()
end

function Methods:Clear()
    if self.nid then Store.ClearDrawing(self.nid) end
    self.redo = {}
    self:Render()
end

---------------------------------------------------------------------------
-- Selection of tool, color, width
---------------------------------------------------------------------------

function Methods:SetTool(tool)
    self.tool = tool
    for key, button in pairs(self.toolButtons) do button:SetActive(key == tool) end
end

function Methods:SetInk(color)
    self.color = color
    for _, swatch in ipairs(self.swatches) do
        swatch:SetSelected(color ~= nil and swatch.color[1] == color[1] and swatch.color[2] == color[2]
            and swatch.color[3] == color[3])
    end
end

function Methods:SetStrokeWidth(width)
    self.width = width
    for _, button in ipairs(self.widthButtons) do Theme.Refresh(button) end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local ROW = 24

local function WidthButton(parent, width, onClick, canvas)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(ROW - 2, ROW - 2)
    b.dot = b:CreateTexture(nil, "ARTWORK")
    local size = 2 + width * 1.2
    b.dot:SetSize(size, size)
    b.dot:SetPoint("CENTER")
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    Theme.Bind(b.hl, function(self, T) Theme.Paint(self, T.hover) end)
    Theme.Bind(b, function(self, T)
        Theme.Paint(self.dot, canvas.width == width and T.accent or T.textDim)
    end)
    b:SetScript("OnClick", onClick)
    Kit.Tooltip(b, L["Stroke width %d"]:format(width), "ANCHOR_TOP")
    return b
end

local function PickColor(initial, onPick)
    if not (ColorPickerFrame and type(ColorPickerFrame.SetupColorPickerAndShow) == "function") then return false end
    return pcall(function()
        ColorPickerFrame:SetupColorPickerAndShow({
            r = initial[1], g = initial[2], b = initial[3], hasOpacity = false,
            swatchFunc = function() onPick(ColorPickerFrame:GetColorRGB()) end,
            cancelFunc = function(previous)
                if type(previous) == "table" and previous.r then onPick(previous.r, previous.g, previous.b) end
            end,
        })
    end)
end

-- opts: toolbar (default true)
function Canvas.Create(parent, opts)
    opts = opts or {}
    local c = CreateFrame("Frame", nil, parent)
    for k, fn in pairs(Methods) do c[k] = fn end
    c.tool, c.width, c.redo = "pen", 2, {}
    c.toolButtons, c.swatches, c.widthButtons = {}, {}, {}

    local barH = 0
    if opts.toolbar ~= false then
        barH = ROW * 3 + 4
        local bar = CreateFrame("Frame", nil, c)
        bar:SetPoint("TOPLEFT")
        bar:SetPoint("TOPRIGHT")
        bar:SetHeight(barH)
        c.bar = bar

        -- row 1: tools, undo, redo, clear
        local previous
        local names = { pen = L["Pen"], eraser = L["Eraser"], line = L["Line"], rect = L["Rectangle"],
            ellipse = L["Ellipse"] }
        for _, tool in ipairs({ "pen", "eraser", "line", "rect", "ellipse" }) do
            local key = tool == "eraser" and "erase" or tool
            local button = Kit.IconButton(bar, ROW - 2, tool, function() c:SetTool(key) end, names[tool])
            if previous then button:SetPoint("LEFT", previous, "RIGHT", 2, 0) else button:SetPoint("TOPLEFT", 0, -1) end
            c.toolButtons[key] = button
            previous = button
        end
        c.undoButton = Kit.IconButton(bar, ROW - 2, "undo", function() c:Undo() end, L["Undo"])
        c.undoButton:SetPoint("LEFT", previous, "RIGHT", 14, 0)
        c.redoButton = Kit.IconButton(bar, ROW - 2, "redo", function() c:Redo() end, L["Redo"])
        c.redoButton:SetPoint("LEFT", c.undoButton, "RIGHT", 2, 0)
        c.clearButton = Kit.ConfirmButton(bar, 62, L["Clear"], function() c:Clear() end, ROW - 2)
        c.clearButton:SetPoint("TOPRIGHT", 0, -1)

        -- row 2: widths and the custom color
        previous = nil
        for _, width in ipairs(WIDTHS) do
            local button = WidthButton(bar, width, function() c:SetStrokeWidth(width) end, c)
            if previous then button:SetPoint("LEFT", previous, "RIGHT", 2, 0) else button:SetPoint("TOPLEFT", 0, -ROW - 1) end
            c.widthButtons[#c.widthButtons + 1] = button
            previous = button
        end
        local custom = Kit.Swatch(bar, ROW - 8, { 0.5, 0.5, 0.5 }, function(self)
            local start = c.color or c:Ink()
            PickColor(start, function(r, g, b)
                self:SetColor({ r, g, b })
                c:SetInk(self.color)
            end)
        end)
        custom:SetPoint("LEFT", previous, "RIGHT", 14, 0)
        Kit.Tooltip(custom, L["Custom color"], "ANCHOR_TOP")
        c.swatches[#c.swatches + 1] = custom
        custom.isCustom = true

        -- row 3: palette
        previous = nil
        for _, color in ipairs(PALETTE) do
            local swatch = Kit.Swatch(bar, ROW - 8, color, function(self) c:SetInk(self.color) end)
            if previous then swatch:SetPoint("LEFT", previous, "RIGHT", 2, 0) else swatch:SetPoint("TOPLEFT", 0, -2 * ROW - 3) end
            c.swatches[#c.swatches + 1] = swatch
            previous = swatch
        end
        c:SetTool("pen")
    else
        c.undoButton = CreateFrame("Frame", nil, c)
        c.redoButton = CreateFrame("Frame", nil, c)
        c.clearButton = CreateFrame("Button", nil, c)
        c.undoButton:Hide()
        c.redoButton:Hide()
        c.clearButton:Hide()
    end

    local surface = Kit.Panel(c, "canvasBg", "border", "input")
    surface:SetPoint("TOPLEFT", 0, -barH)
    surface:SetPoint("BOTTOMRIGHT")
    surface:SetClipsChildren(true)
    surface:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then c:StartStroke() end
    end)
    surface:SetScript("OnHide", function() c:CancelStroke() end)
    surface:SetScript("OnSizeChanged", function() c:QueueRender() end)
    c.surface = surface
    c.pool = NewPool(surface)
    c.preview = NewPool(surface)

    Store.OnChanged(function(kind, id)
        if kind == "note" and id == c.nid and not c.current then c:QueueRender() end
    end)
    Theme.Bind(c, function() c:QueueRender() end) -- theme change: eraser color and default ink follow
    c:SetScript("OnShow", function() c:QueueRender() end)
    c:SetScript("OnHide", function() c:CancelStroke() end)
    return c
end
