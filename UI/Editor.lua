-- Note editor, one for every place a text note is written: notebook, mini window, target popup, sticky notes.
-- The text shows formatted; a click on it (or ne:Edit()) switches to writing, leaving the box formats it again.
--   [ ] task   [x] done      a click on the box ticks it
--   - item     * item        bullet list
--   1. item    1) item       numbered list (numbers run on by themselves)
-- Enter at the end of a list line starts the next one; Enter on an empty one ends the list. The toolbar
-- (or ne:LineButton(kind)) turns the line under the cursor into a checkbox / bullet / numbered line, or back.
--
--   local ne = ns.Editor.Create(parent, { toolbar = true, size = 13, framed = true, hint = "..." })
--   ne:SetValue(text)          show a text (keeps the cursor while writing)
--   ne.onChange = fn(text)     the user changed it (typing, ticking, buttons)
--   ne.onEditing = fn(on)      writing starts / ends
--   ne.canEdit = fn() -> bool  optional: may writing start now?
--   ne:SetNote(nid)            bind to a stored text note: loads it, saves edits (debounced), follows outside changes
--   ne:Edit()  ne:StopEditing()  ne:LineButton(kind)  ne:Progress() -> done, total  ne:SetFontSize(size)
--   ne.edit                    the EditBox (HasFocus, ClearFocus)
-- Paints only through Theme.Bind (via Kit), so theme, accent and font changes reach it live.
local _, ns = ...
local L = ns.L
local Theme, Kit = ns.Theme, ns.Kit
local Paint, Bind, Refresh = Theme.Paint, Theme.Bind, Theme.Refresh

local Editor = {}
ns.Editor = Editor

local PAD, TOOL_H, CHECK = 6, 22, 14
local SAVE_DELAY = 0.4 -- seconds of quiet typing before a bound note is written to the store

---------------------------------------------------------------------------
-- Lines (pure text functions, tested by /forevernotes probe editor)
---------------------------------------------------------------------------

local function IsBlank(text) return not text or not text:find("%S") end

-- kind ("check" | "bullet" | "number" | "text"), body, ticked, number
local function ParseLine(line)
    local mark, rest = line:match("^%s*%[([ xX]?)%]%s?(.*)$")
    if mark then return "check", rest, mark == "x" or mark == "X" end
    local item = line:match("^%s*[%-%*]%s+(.*)$")
    if item then return "bullet", item end
    local n, after = line:match("^%s*(%d+)[%.%)]%s+(.*)$")
    if n then return "number", after, nil, tonumber(n) end
    return "text", line
end
Editor.ParseLine = ParseLine

local function Lines(text)
    local out = {}
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end
Editor.Lines = Lines

-- Ticked and total checkboxes of a text.
function Editor.Progress(text)
    local done, total = 0, 0
    for _, line in ipairs(Lines(text)) do
        local kind, _, on = ParseLine(line)
        if kind == "check" then
            total = total + 1
            if on then done = done + 1 end
        end
    end
    return done, total
end

-- The marker a new line of this kind gets; numbers follow the line above.
local function Marker(kind, above)
    if kind == "check" then return "[ ] " end
    if kind == "bullet" then return "- " end
    local k, _, _, n = ParseLine(above or "")
    return ((k == "number" and n or 0) + 1) .. ". "
end

-- Line start / end (1-based, end inclusive) around a cursor position (0 = before the first character).
local function LineAt(text, cursor)
    local before = text:sub(1, cursor)
    local start = (before:match(".*()\n") or 0) + 1
    local stop = (text:find("\n", start, true) or (#text + 1)) - 1
    return start, stop
end

-- Turns the line under the cursor into a checkbox / bullet / numbered line, or back to plain text.
-- Returns the new text and cursor.
function Editor.ToggleLine(text, cursor, want)
    local start, stop = LineAt(text, cursor)
    local line = text:sub(start, stop)
    local kind, rest = ParseLine(line)
    local above
    if start > 1 then
        local a1, a2 = LineAt(text, start - 2)
        above = text:sub(a1, a2)
    end
    local new = (kind == want) and rest or (Marker(want, above) .. rest)
    return text:sub(1, start - 1) .. new .. text:sub(stop + 1), start - 1 + #new
end

-- The user just typed a line break at the end of a list line: carry the list on (or end it when that line
-- was empty). Returns the new text and cursor, nil when nothing is to be done.
function Editor.ContinueList(old, new, cursor)
    if #new ~= #old + 1 or new:sub(cursor, cursor) ~= "\n" then return end
    if new:sub(1, cursor - 1) .. new:sub(cursor + 1) ~= old then return end
    local s, e = LineAt(new, cursor - 1)
    local line = new:sub(s, e)
    local kind, rest = ParseLine(line)
    if kind == "text" then return end
    if IsBlank(rest) then
        -- empty list line + Enter: the list ends, the line becomes empty
        return new:sub(1, s - 1) .. new:sub(cursor + 1), s - 1
    end
    local m = Marker(kind, line)
    return new:sub(1, cursor) .. m .. new:sub(cursor + 1), cursor + #m
end

-- Flips the checkbox in line i of text; nil when that line has none.
function Editor.TickLine(text, i)
    local lines = Lines(text)
    local line = lines[i]
    if not line then return end
    local kind, _, on = ParseLine(line)
    if kind ~= "check" then return end
    lines[i] = line:gsub("%[[ xX]?%]", on and "[ ]" or "[x]", 1)
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Formatted view
---------------------------------------------------------------------------

local Methods = {} -- copied onto each editor frame

local function Row(ne, i)
    local r = ne.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, ne.view.child)
    local check = CreateFrame("Button", nil, r)
    check:SetSize(CHECK, CHECK)
    check:SetPoint("TOPLEFT", 1, -1) -- 1 px in: the scroll frame clips its left edge
    check.mark = Kit.Glyph(check, "check", CHECK - 2, "accent")
    check.mark:SetPoint("CENTER")
    check:SetScript("OnEnter", function(self) self.hovered = true; Refresh(self) end)
    check:SetScript("OnLeave", function(self) self.hovered = false; Refresh(self) end)
    check:SetScript("OnClick", function() ne:Tick(r.index) end)
    Bind(check, function(self, T) Theme.Box(self, T, "inputBg", self.hovered and "accent" or "textDim") end)
    r.check = check
    r.dot = r:CreateTexture(nil, "ARTWORK")
    r.dot:SetSize(5, 5)
    Bind(r.dot, function(self, T) Paint(self, T.accent) end)
    r.num = Kit.Text(r, ne.size, "textDim")
    r.num:SetJustifyH("RIGHT")
    r.num:SetWidth(18)
    r.num:SetPoint("TOPLEFT", 0, 0)
    r.text = Kit.Text(r, ne.size, "text")
    r.text:SetJustifyV("TOP")
    r.text:SetWordWrap(true)
    ne.rows[i] = r
    return r
end

local function SetSize(fs, size)
    if fs.fnSize ~= size then Kit.SetTextSize(fs, size) end
end

local function SetColor(fs, key)
    if fs.fnColor ~= key then Kit.SetTextColor(fs, key) end
end

function Methods:Render()
    if self.editing then return end
    local text, size = self.text or "", self.size
    local view = self.view
    local width = math.max(40, (view.child:GetWidth() or 0) - 2 * PAD)
    local y, shown, run = PAD, 0, nil -- run: number shown on the last numbered line
    local blank = IsBlank(text)
    local lines = blank and {} or Lines(text)
    for i, line in ipairs(lines) do
        local r = Row(self, i)
        r.index = i
        local kind, body, on, n = ParseLine(line)
        if kind == "number" then run = run and (run + 1) or n else run = nil end
        local indent = (kind == "text") and 0 or (kind == "number" and 24 or 20)
        r.check:SetShown(kind == "check")
        if kind == "check" then r.check.mark:SetShown(on and true or false) end
        r.dot:SetShown(kind == "bullet")
        r.dot:ClearAllPoints()
        r.dot:SetPoint("TOPLEFT", 6, -math.max(1, math.floor(size / 2 - 2)))
        r.num:SetShown(kind == "number")
        SetSize(r.num, size)
        if kind == "number" then r.num:SetText(run .. ".") end
        SetSize(r.text, size)
        SetColor(r.text, on and "textDim" or "text")
        r.text:ClearAllPoints()
        r.text:SetPoint("TOPLEFT", indent, kind == "check" and -1 or 0)
        r.text:SetWidth(width - indent)
        r.text:SetText(body ~= "" and body or " ")
        local h
        if body == "" and kind == "text" then
            h = math.floor(size * 0.6) -- an empty line is a small gap
        else
            h = math.max(r.text:GetStringHeight(), kind == "check" and (CHECK + 2) or size) + 3
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", PAD, -y)
        r:SetSize(width, h)
        r:Show()
        y = y + h
        shown = i
    end
    for i = shown + 1, #self.rows do self.rows[i]:Hide() end
    self.hint:SetShown(blank)
    if blank then
        SetSize(self.hint, size)
        self.hint:SetText(self.hintText or L["Click to write.  [ ] makes a checkbox, - a list, 1. a numbered list."])
    end
    -- the child fills at least the view, so a click anywhere below the text starts writing
    view:SetContentHeight(math.max(y + PAD, view.scroll:GetHeight()))
    self:UpdateProgress()
end

-- Renders on the next frame: coalesces size changes and theme repaints (no frame creation inside a repaint loop).
function Methods:QueueRender()
    if self.renderQueued then return end
    self.renderQueued = true
    C_Timer.After(0, function()
        self.renderQueued = false
        if self.editing then self:LayoutEdit() else self:Render() end
    end)
end

function Methods:UpdateProgress()
    if not self.progress then return end
    local done, total = Editor.Progress(self.text)
    self.progress:SetText(total > 0 and (done .. "/" .. total) or "")
end

function Methods:Progress() return Editor.Progress(self.text) end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

-- The edit box grows with its text inside the scroll area; a hidden font string measures the wrapped height.
function Methods:LayoutEdit()
    local area, edit, measure = self.area, self.edit, self.measure
    local width = math.max(40, (area.child:GetWidth() or 0) - 2 * PAD)
    SetSize(measure, self.size)
    measure:SetWidth(width)
    local text = edit:GetText()
    if text == "" or text:sub(-1) == "\n" then text = text .. " " end
    measure:SetText(text)
    local viewH = area.scroll:GetHeight()
    local h = math.max(measure:GetStringHeight() + self.size, viewH - 2 * PAD)
    edit:SetHeight(h)
    area:SetContentHeight(h + 2 * PAD)
    self:ShowCursor()
end

-- Scrolls so the cursor line is visible (cursor values come from OnCursorChanged, relative to the edit box top).
function Methods:ShowCursor()
    if not self.cursorY then return end
    local area = self.area
    local top = PAD - self.cursorY
    local bottom = top + self.cursorH + PAD
    local offset, viewH = area:GetOffset(), area.scroll:GetHeight()
    if top - PAD < offset then
        area:SetOffset(top - PAD)
    elseif bottom > offset + viewH then
        area:SetOffset(bottom - viewH)
    end
end

-- Every user edit: progress, debounced save of a bound note (SetNote), then the host's onChange.
local function Changed(self)
    self:UpdateProgress()
    self:ScheduleSave()
    if self.onChange then self.onChange(self.text) end
end

-- Pointer position in the coordinates of the frame (cursor pixels / effective scale).
local function PointerIn(frame)
    local x, y = GetCursorPosition()
    local scale = frame:GetEffectiveScale()
    if not scale or scale == 0 then scale = 1 end
    return x / scale, y / scale
end

-- UTF-8 characters of a string (so a measured prefix never ends inside a multi-byte character).
local function Chars(s)
    local out = {}
    for ch in s:gmatch("[^\128-\191][\128-\191]*") do out[#out + 1] = ch end
    return out
end

-- Character index (0 = before the first one) closest to a point, in a text laid out by the hidden measure font string
-- (wrapped at `width`, same font as the shown text). left/top are the screen position of the text's first line.
-- Wrapped lines are found by measuring prefixes, so the result is close, not pixel exact.
local function CharAtPoint(m, size, chars, width, left, top, cx, cy)
    SetSize(m, size)
    m:SetWidth(math.max(20, width))
    local function Height(k)
        m:SetText(table.concat(chars, "", 1, k))
        return m:GetStringHeight()
    end
    local function Width(a, b)
        m:SetText(table.concat(chars, "", a + 1, b))
        return m:GetStringWidth()
    end
    local lineH = math.max(1, #chars > 0 and Height(1) or size)
    -- first character of visual line v (0-based): smallest prefix that needs v + 1 lines, moved back to the start
    -- of its word (or line)
    local function LineStart(v)
        if v <= 0 then return 0 end
        local lo, hi = 1, #chars + 1
        while lo < hi do
            local mid = math.floor((lo + hi) / 2)
            if Height(mid) > (v + 0.5) * lineH then hi = mid else lo = mid + 1 end
        end
        if lo > #chars then return nil end
        local j = lo
        while j > 1 and chars[j - 1] ~= " " and chars[j - 1] ~= "\n" do j = j - 1 end
        if j == 1 then j = lo end
        return j - 1
    end
    local v = math.max(0, math.floor((top - cy) / lineH))
    local s = LineStart(v)
    while not s and v > 0 do
        v = v - 1
        s = LineStart(v)
    end
    s = s or 0
    local e = LineStart(v + 1) or #chars
    if chars[e] == "\n" then e = e - 1 end
    local tx = cx - left
    local best, bestDist = s, math.huge
    for c = s, math.max(s, e) do
        local d = math.abs((c > s and Width(s, c) or 0) - tx)
        if d < bestDist then best, bestDist = c, d end
    end
    return best
end

-- Text offset (same unit as the edit box cursor, 0 = before the first character) under a point of the formatted
-- view. Used to turn a mouse drag over the formatted text into a selection in the edit box.
function Methods:OffsetAt(cx, cy)
    local lines = Lines(self.text or "")
    local pos, total = 0, #(self.text or "")
    for i, line in ipairs(lines) do
        local r = self.rows[i]
        if r and r:IsShown() then
            local top = r:GetTop()
            local bottom = top - r:GetHeight()
            if i == 1 and cy > top then return 0 end
            if cy <= top and (cy > bottom or i == #lines) then
                local kind, body = ParseLine(line)
                local first = pos + #line - #body -- offset where the body starts
                if body == "" then return kind == "text" and pos or first end
                local fs, chars = r.text, Chars(body)
                local best = CharAtPoint(self.measure, self.size, chars, fs:GetWidth(), fs:GetLeft(), fs:GetTop(), cx, cy)
                return first + #table.concat(chars, "", 1, best)
            end
        end
        pos = pos + #line + 1
    end
    return total
end

-- Offset under a point of the raw text in the edit box (writing mode).
function Methods:EditOffsetAt(cx, cy)
    local edit = self.edit
    local chars = Chars(edit:GetText())
    local best = CharAtPoint(self.measure, self.size, chars, edit:GetWidth(), edit:GetLeft(), edit:GetTop(), cx, cy)
    return #table.concat(chars, "", 1, best)
end

-- Writing mode: if the game does not follow a mouse drag with a selection of its own, this does it. The press is
-- noted (edit box or the area around it); while the button is down and the pointer has moved, and the game's cursor
-- has not moved at all, the text between the press point and the pointer is highlighted.
function Methods:PressEdit()
    local x, y = PointerIn(self.area.child)
    local ok, anchor = pcall(self.EditOffsetAt, self, x, y)
    self.drag = { x = x, y = y, anchor = ok and anchor or nil }
end

function Methods:TrackDrag()
    local d = self.drag
    if not d then return end
    if not IsMouseButtonDown("LeftButton") or not self.editing then
        self.drag = nil
        return
    end
    local cur = self.edit:GetCursorPosition()
    if d.cursor == nil then
        d.cursor = cur
        return
    end
    local x, y = PointerIn(self.area.child)
    if not d.own and (math.abs(x - d.x) > 12 or math.abs(y - d.y) > 12) and cur ~= d.cursor then d.native = true end
    if d.native or not d.anchor or (math.abs(x - d.x) <= 12 and math.abs(y - d.y) <= 12 and not d.own) then return end
    local ok, to = pcall(self.EditOffsetAt, self, x, y)
    if not (ok and to) then return end
    d.own = true
    self.edit:SetCursorPosition(to)
    if to ~= d.anchor then self.edit:HighlightText(math.min(d.anchor, to), math.max(d.anchor, to)) end
end

-- Click on the formatted text: writing starts. A drag over it starts writing with that part selected.
function Methods:PressView()
    self.pressX, self.pressY = PointerIn(self.view.child)
end

function Methods:ReleaseView()
    local px, py = self.pressX, self.pressY
    self.pressX, self.pressY = nil, nil
    local x, y = PointerIn(self.view.child)
    local from, to
    if px and (math.abs(x - px) > 3 or math.abs(y - py) > 3) then
        local ok, a, b = pcall(function() return self:OffsetAt(px, py), self:OffsetAt(x, y) end)
        if ok and a and b and a ~= b then from, to = math.min(a, b), math.max(a, b) end
    end
    self:SetEditing(true)
    if from and self.editing then
        self.edit:SetCursorPosition(to)
        self.edit:HighlightText(from, to)
    end
end

-- A text from outside (the note changed elsewhere, another note selected).
function Methods:SetValue(text)
    self.text = text or ""
    if self.editing then
        if not self.edit:HasFocus() then self.edit:SetText(self.text) end
        self.lastText = self.edit:GetText()
    else
        self.view:SetOffset(0)
        self:Render()
    end
    self:UpdateProgress()
end

function Methods:GetValue() return self.text end

function Methods:SetFontSize(size)
    self.size = size
    Refresh(self.edit)
    self:QueueRender()
end

function Methods:SetEditing(on)
    on = on and true or false
    if on and self.canEdit and not self.canEdit() then return end
    if self.editing == on then
        if on and not self.edit:HasFocus() then self.edit:SetFocus() end
        return
    end
    self.editing = on
    self.view:SetShown(not on)
    self.area:SetShown(on)
    Refresh(self)
    if on then
        Refresh(self.edit) -- font before SetText
        self.edit:SetText(self.text)
        self.lastText = self.text
        self.area:SetOffset(0)
        self:LayoutEdit()
        self.edit:SetFocus()
        self.edit:SetCursorPosition(#self.text)
    else
        if self.edit:HasFocus() then self.edit:ClearFocus() end
        self:Render()
    end
    if self.onEditing then self.onEditing(on) end
end

function Methods:Edit() self:SetEditing(true) end
function Methods:StopEditing() self:SetEditing(false) end

-- The checkbox in line i flips.
function Methods:Tick(i)
    if self.canEdit and not self.canEdit() then return end
    local text = Editor.TickLine(self.text, i)
    if not text then return end
    self.text = text
    self:Render()
    Changed(self)
end

-- Toolbar: change the cursor's line while writing, else add a line of that kind and start writing.
function Methods:LineButton(kind)
    if self.canEdit and not self.canEdit() then return end
    if self.editing then
        local text, cursor = Editor.ToggleLine(self.edit:GetText(), self.edit:GetCursorPosition(), kind)
        self.lastText = text
        self.edit:SetText(text)
        self.edit:SetCursorPosition(cursor)
        self.text = text
        if not self.edit:HasFocus() then self.edit:SetFocus() end
    else
        local text = self.text or ""
        local lines = Lines(text)
        if text ~= "" and not text:find("\n$") then text = text .. "\n" end
        self.text = text .. Marker(kind, lines[#lines])
        self:SetEditing(true)
    end
    Changed(self)
end

---------------------------------------------------------------------------
-- Toolbar
---------------------------------------------------------------------------

-- "1." as a text icon button (no glyph reads as well as the digits).
local function NumberButton(parent, onClick, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    Bind(hl, function(self, T) Paint(self, T.hover) end)
    b.label = Kit.Text(b, 11, "textDim")
    b.label:SetPoint("CENTER", 0, 0)
    b.label:SetText("1.")
    b:SetScript("OnEnter", function() Kit.SetTextColor(b.label, "text") end)
    b:SetScript("OnLeave", function() Kit.SetTextColor(b.label, "textDim") end)
    b:SetScript("OnClick", onClick)
    Kit.Tooltip(b, tip, "ANCHOR_TOP")
    return b
end

-- The three line buttons in a row on any parent (sticky notes put them in their footer).
function Methods:ToolButtons(parent)
    local ne = self
    local check = Kit.IconButton(parent, 20, "checkbox", function() ne:LineButton("check") end,
        { L["Checkbox"], L["Turns the line into a checkbox: [ ] text"] })
    local bullet = Kit.IconButton(parent, 20, "bullets", function() ne:LineButton("bullet") end,
        { L["List"], L["Turns the line into a list item: - text"] })
    local number = NumberButton(parent, function() ne:LineButton("number") end,
        { L["Numbered list"], L["Turns the line into a numbered item: 1. text"] })
    bullet:SetPoint("LEFT", check, "RIGHT", 2, 0)
    number:SetPoint("LEFT", bullet, "RIGHT", 2, 0)
    return check, bullet, number
end

---------------------------------------------------------------------------
-- Binding to a stored note
---------------------------------------------------------------------------

-- Writes a pending edit to the store now (also on note switch, end of writing and hide).
function Methods:Flush()
    if self.saveTimer then
        self.saveTimer:Cancel()
        self.saveTimer = nil
    end
    if self.dirty and self.nid and ns.Store.GetNote(self.nid) then
        self.dirty = false
        self.saving = true
        ns.Store.UpdateNote(self.nid, { text = self.text })
        self.saving = false
    end
    self.dirty = false
end

-- nid = id of a text note, or nil to unbind (the editor then shows nothing).
function Methods:SetNote(nid)
    self:Flush()
    local note = nid and ns.Store.GetNote(nid)
    if note and note.kind ~= "text" then note = nil end
    self.nid = note and nid or nil
    if self.editing and self.edit:HasFocus() then self.edit:ClearFocus() end
    self:SetValue(note and note.text or "")
end

function Methods:ScheduleSave()
    if not self.nid then return end
    self.dirty = true
    if self.saveTimer then self.saveTimer:Cancel() end
    self.saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        self.saveTimer = nil
        self:Flush()
    end)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- Scroll areas pass the wheel on from their (mouse-enabled) child.
local function ForwardWheel(area)
    area.child:EnableMouseWheel(true)
    area.child:SetScript("OnMouseWheel", function(_, delta) area:GetScript("OnMouseWheel")(area, delta) end)
end

-- opts: toolbar (bool), size (font size, default 13), framed (input box look), hint (empty-state text)
function Editor.Create(parent, opts)
    opts = opts or {}
    local ne = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    for k, fn in pairs(Methods) do ne[k] = fn end
    ne.rows, ne.size, ne.text, ne.hintText, ne.framed = {}, opts.size or 13, "", opts.hint, opts.framed
    local bottom = opts.toolbar and TOOL_H or 0

    -- formatted text; a click anywhere on it starts writing
    local view = Kit.ScrollArea(ne)
    view:SetPoint("TOPLEFT", 0, 0)
    view:SetPoint("BOTTOMRIGHT", 0, bottom)
    view.child:EnableMouse(true)
    view.child:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then ne:PressView() end
    end)
    view.child:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ne:ReleaseView() end
    end)
    ForwardWheel(view)
    ne.view = view
    ne.hint = Kit.Text(view.child, ne.size, "textDim")
    ne.hint:SetPoint("TOPLEFT", PAD, -PAD)
    ne.hint:SetPoint("TOPRIGHT", -PAD, -PAD)
    ne.hint:SetJustifyV("TOP")
    ne.hint:SetWordWrap(true)

    -- writing: the raw text in a growing multi-line edit box
    local area = Kit.ScrollArea(ne)
    area:SetPoint("TOPLEFT", 0, 0)
    area:SetPoint("BOTTOMRIGHT", 0, bottom)
    area:Hide()
    area.child:EnableMouse(true)
    ForwardWheel(area)
    ne.area = area
    ne.measure = Kit.Text(area.child, ne.size, false)
    ne.measure:SetPoint("TOPLEFT", PAD, -PAD)
    ne.measure:SetWordWrap(true)
    ne.measure:SetAlpha(0)
    local edit = CreateFrame("EditBox", nil, area.child)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetPoint("TOPLEFT", PAD, -PAD)
    edit:SetPoint("TOPRIGHT", -PAD, -PAD)
    edit:SetHeight(20)
    Bind(edit, function(self, T)
        Theme.SetFont(self, ne.size)
        Paint(self, T.text)
        Kit.PaintSelection(self, T)
    end)
    ne.edit = edit
    -- a click below the text puts the cursor at the end
    area.child:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then ne:PressEdit() end
        edit:SetFocus()
        edit:SetCursorPosition(#edit:GetText())
    end)
    edit:HookScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then ne:PressEdit() end
    end)
    ne:SetScript("OnUpdate", function(self) if self.drag then self:TrackDrag() end end)

    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    edit:SetScript("OnTextChanged", function(self, userInput)
        ne:LayoutEdit()
        if not userInput then return end
        local text = self:GetText()
        local cont, cursor = Editor.ContinueList(ne.lastText or "", text, self:GetCursorPosition())
        if cont then
            ne.lastText = cont
            self:SetText(cont)
            self:SetCursorPosition(cursor)
            text = cont
        end
        ne.text, ne.lastText = text, text
        Changed(ne)
    end)
    edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
        ne.cursorY, ne.cursorH = y, h
        ne:ShowCursor()
    end)
    edit:SetScript("OnEditFocusLost", function() ne:SetEditing(false) end)
    Kit.AttachCaret(edit) -- after the SetScript calls above, they would drop its hooks

    if opts.toolbar then
        local bar = CreateFrame("Frame", nil, ne)
        bar:SetPoint("BOTTOMLEFT", 2, 1)
        bar:SetPoint("BOTTOMRIGHT", -2, 1)
        bar:SetHeight(TOOL_H - 2)
        bar.line = Kit.Divider(bar)
        bar.line:SetPoint("TOPLEFT", -2, 1)
        bar.line:SetPoint("TOPRIGHT", 2, 1)
        local check = ne:ToolButtons(bar)
        check:SetPoint("LEFT", 0, 0)
        ne.progress = Kit.Text(bar, 11, "textDim")
        ne.progress:SetPoint("RIGHT", -4, 0)
        ne.toolbar = bar
    end

    ns.Store.OnChanged(function(kind, id)
        if kind ~= "note" or id ~= ne.nid or ne.saving then return end
        local note = ns.Store.GetNote(id)
        if not note then
            ne:SetNote(nil)
        elseif note.text ~= ne.text and not (ne.editing and ne.edit:HasFocus()) then
            ne:SetValue(note.text)
        end
    end)

    ne:SetScript("OnSizeChanged", function(self) self:QueueRender() end)
    ne:SetScript("OnHide", function(self)
        if self.editing then self:SetEditing(false) end
        self:Flush()
    end)
    Bind(ne, function(self, T)
        if self.framed then
            Theme.Box(self, T, "inputBg", self.editing and "accent" or "border", "input")
            if self.editing then Theme.Edge(self, T.accent) end
        end
        self:QueueRender() -- font or size may have changed
    end)
    return ne
end
