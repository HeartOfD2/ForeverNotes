-- ForeverNotes data layer: groups, notes (text|drawing), players, ignore list, sticky state, change notification.
-- No frames in here. Views register with Store.OnChanged and redraw themselves.
local _, ns = ...
local L = ns.L

local Store = {}
ns.Store = Store

-- Limits for drawings (segments per drawing, coordinate range)
Store.MAX_SEGMENTS = 4000
Store.COORD_MAX = 1000
Store.MIN_WIDTH, Store.MAX_WIDTH = 1, 12
local MAX_TITLE, MAX_TEXT, MAX_GROUP_NAME, MAX_REASON = 80, 20000, 40, 120
local ELLIPSE_SEGMENTS = 32
local STROKE_TYPES = { pen = true, erase = true, line = true, rect = true, ellipse = true }

Store.GROUP_COLORS = {
    { 0.93, 0.36, 0.36 }, { 0.96, 0.60, 0.27 }, { 0.96, 0.82, 0.32 }, { 0.55, 0.80, 0.38 },
    { 0.30, 0.78, 0.62 }, { 0.32, 0.72, 0.90 }, { 0.40, 0.55, 0.95 }, { 0.65, 0.48, 0.92 },
    { 0.88, 0.48, 0.80 }, { 0.72, 0.72, 0.72 },
}

local function DB() return ns.db end

local function Now() return time() end

local function Clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function Trim(text, limit)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if limit and #text > limit then text = text:sub(1, limit) end
    return text
end

local function CleanColor(color)
    if type(color) ~= "table" then return nil end
    local r, g, b = tonumber(color[1]), tonumber(color[2]), tonumber(color[3])
    if not (r and g and b) then return nil end
    return { Clamp(r, 0, 1), Clamp(g, 0, 1), Clamp(b, 0, 1) }
end

local function NextId(prefix)
    local db = DB()
    db.seq = db.seq + 1
    return prefix .. db.seq
end

-- ---------------------------------------------------------------- change notification
local listeners = {}

function Store.OnChanged(fn)
    listeners[#listeners + 1] = fn
end

-- kind: "group" | "note" | "player" | "ignore" | "sticky"; id may be nil (whole kind changed)
local function Changed(kind, id)
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], kind, id)
        if not ok then geterrorhandler()(err) end
    end
end
Store.Changed = Changed

-- ---------------------------------------------------------------- groups
function Store.GetGroup(id) return id and DB().groups[id] end

function Store.ListGroups()
    local list = {}
    for id, group in pairs(DB().groups) do
        list[#list + 1] = { id = id, name = group.name, color = group.color, order = group.order or 0 }
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return list
end

function Store.CreateGroup(name, color)
    local db = DB()
    local id = NextId("g")
    local count = 0
    for _ in pairs(db.groups) do count = count + 1 end
    name = Trim(name, MAX_GROUP_NAME)
    if name == "" then name = L["New group"] end
    db.groups[id] = {
        name = name,
        color = CleanColor(color) or Store.GROUP_COLORS[(count % #Store.GROUP_COLORS) + 1],
        order = db.seq,
    }
    Changed("group", id)
    return id
end

function Store.RenameGroup(id, name)
    local group = Store.GetGroup(id)
    name = Trim(name, MAX_GROUP_NAME)
    if not group or name == "" then return false end
    group.name = name
    Changed("group", id)
    return true
end

function Store.SetGroupColor(id, color)
    local group, clean = Store.GetGroup(id), CleanColor(color)
    if not group or not clean then return false end
    group.color = clean
    Changed("group", id)
    return true
end

-- direction -1 = up, +1 = down in the list order
function Store.MoveGroup(id, direction)
    local list = Store.ListGroups()
    for i = 1, #list do
        if list[i].id == id then
            local other = list[i + direction]
            if not other then return false end
            local groups = DB().groups
            groups[id].order, groups[other.id].order = other.order, list[i].order
            if groups[id].order == groups[other.id].order then groups[id].order = groups[id].order + direction end
            Changed("group")
            return true
        end
    end
    return false
end

-- Notes of the deleted group become ungrouped unless deleteNotes is true.
function Store.DeleteGroup(id, deleteNotes)
    local db = DB()
    if not db.groups[id] then return false end
    local doomed = {}
    for nid, note in pairs(db.notes) do
        if note.group == id then
            if deleteNotes then doomed[#doomed + 1] = nid else note.group = nil end
        end
    end
    db.groups[id] = nil
    for i = 1, #doomed do Store.DeleteNote(doomed[i], true) end
    Changed("group", id)
    Changed("note")
    return true
end

-- ---------------------------------------------------------------- notes
function Store.GetNote(id) return id and DB().notes[id] end

-- Shown name: title, else first line of the text, else a placeholder.
function Store.NoteTitle(note)
    if not note then return "" end
    if note.title and note.title ~= "" then return note.title end
    if note.kind == "text" and note.text and note.text ~= "" then
        local first = note.text:match("^[^\r\n]+")
        if first then
            first = Trim(first, 40)
            if first ~= "" then return first end
        end
    end
    return note.kind == "drawing" and L["Untitled drawing"] or L["Untitled note"]
end

-- opts: kind = "text"|"drawing", title, text, group, player (key)
function Store.CreateNote(opts)
    opts = opts or {}
    local db = DB()
    local kind = opts.kind == "drawing" and "drawing" or "text"
    local id = NextId("n")
    local now = Now()
    local note = {
        kind = kind,
        title = Trim(opts.title, MAX_TITLE),
        created = now,
        updated = now,
    }
    if kind == "text" then
        note.text = tostring(opts.text or ""):sub(1, MAX_TEXT)
    else
        note.drawing = { v = 1, strokes = {} }
    end
    if opts.group and db.groups[opts.group] then note.group = opts.group end
    db.notes[id] = note
    if opts.player then
        local player = db.players[opts.player]
        if player then
            note.player = opts.player
            note.group = nil
            player.notes[#player.notes + 1] = id
        end
    end
    Changed("note", id)
    if note.player then Changed("player", note.player) end
    return id, note
end

local EDITABLE = { title = MAX_TITLE, text = MAX_TEXT }

-- fields: title, text (text notes), group (id or false to clear). Bumps "updated" only when something changed.
function Store.UpdateNote(id, fields)
    local note = Store.GetNote(id)
    if not note or type(fields) ~= "table" then return false end
    local changed = false
    for key, limit in pairs(EDITABLE) do
        local value = fields[key]
        if value ~= nil and not (key == "text" and note.kind ~= "text") then
            value = key == "title" and Trim(value, limit) or tostring(value):sub(1, limit)
            if note[key] ~= value then
                note[key] = value
                changed = true
            end
        end
    end
    if fields.group ~= nil and not note.player then
        local target = fields.group and DB().groups[fields.group] and fields.group or nil
        if note.group ~= target then
            note.group = target
            changed = true
        end
    end
    if changed then
        note.updated = Now()
        Changed("note", id)
    end
    return changed
end

function Store.DeleteNote(id, silent)
    local db = DB()
    local note = db.notes[id]
    if not note then return false end
    local playerKey = note.player
    if playerKey and db.players[playerKey] then
        local list = db.players[playerKey].notes
        for i = #list, 1, -1 do
            if list[i] == id then table.remove(list, i) end
        end
        if #list == 0 then db.players[playerKey] = nil end
    end
    db.notes[id] = nil
    if not silent then
        Changed("note", id)
        if playerKey then Changed("player", playerKey) end
    end
    return true
end

-- Non-player notes. opts: kind, group (id), ungrouped (true). Newest first.
function Store.ListNotes(opts)
    opts = opts or {}
    local list = {}
    for id, note in pairs(DB().notes) do
        if not note.player
                and (not opts.kind or note.kind == opts.kind)
                and (not opts.group or note.group == opts.group)
                and (not opts.ungrouped or not note.group) then
            list[#list + 1] = id
        end
    end
    local notes = DB().notes
    table.sort(list, function(a, b)
        local ua, ub = notes[a].updated or 0, notes[b].updated or 0
        if ua ~= ub then return ua > ub end
        return a > b
    end)
    return list
end

-- ---------------------------------------------------------------- drawings
-- A drawing is { v = 1, strokes = { { t, c = {r,g,b}, w, p = { x1, y1, x2, y2, ... } } } }, coordinates integer 0..1000.
local function StrokeSegments(stroke)
    local t, count = stroke.t, #stroke.p / 2
    if t == "pen" or t == "erase" then return math.max(1, count - 1) end
    if t == "rect" then return 4 end
    if t == "ellipse" then return ELLIPSE_SEGMENTS end
    return 1 -- line
end
Store.StrokeSegments = StrokeSegments

function Store.CountSegments(drawing)
    local total = 0
    if drawing and drawing.strokes then
        for i = 1, #drawing.strokes do total = total + StrokeSegments(drawing.strokes[i]) end
    end
    return total
end

-- Returns a clean copy of one stroke, or nil when it is unusable (also used by the import).
local function CleanStroke(raw)
    if type(raw) ~= "table" or not STROKE_TYPES[raw.t] or type(raw.p) ~= "table" then return nil end
    local points = {}
    for i = 1, #raw.p do
        local value = tonumber(raw.p[i])
        if not value then return nil end
        points[i] = Clamp(math.floor(value + 0.5), 0, Store.COORD_MAX)
    end
    local n = #points
    if n < 2 or n % 2 ~= 0 then return nil end
    if raw.t ~= "pen" and raw.t ~= "erase" and n ~= 4 then return nil end
    return {
        t = raw.t,
        c = CleanColor(raw.c) or { 1, 1, 1 },
        w = Clamp(math.floor((tonumber(raw.w) or 2) + 0.5), Store.MIN_WIDTH, Store.MAX_WIDTH),
        p = points,
    }
end
Store.CleanStroke = CleanStroke

-- Whole drawing from untrusted input: keeps valid strokes up to the segment limit. Returns the drawing and a "truncated" flag.
function Store.SanitizeDrawing(raw)
    local drawing = { v = 1, strokes = {} }
    if type(raw) ~= "table" or type(raw.strokes) ~= "table" then return drawing, false end
    local total = 0
    for i = 1, #raw.strokes do
        local stroke = CleanStroke(raw.strokes[i])
        if stroke then
            local segments = StrokeSegments(stroke)
            if total + segments > Store.MAX_SEGMENTS then return drawing, true end
            total = total + segments
            drawing.strokes[#drawing.strokes + 1] = stroke
        end
    end
    return drawing, false
end

-- Returns true, or false plus "limit" / "invalid" / "missing".
function Store.AddStroke(id, raw)
    local note = Store.GetNote(id)
    if not note or note.kind ~= "drawing" then return false, "missing" end
    local stroke = CleanStroke(raw)
    if not stroke then return false, "invalid" end
    local drawing = note.drawing
    if Store.CountSegments(drawing) + StrokeSegments(stroke) > Store.MAX_SEGMENTS then return false, "limit" end
    drawing.strokes[#drawing.strokes + 1] = stroke
    note.updated = Now()
    Changed("note", id)
    return true
end

-- Removes and returns the last stroke (undo); the canvas keeps it for redo.
function Store.PopStroke(id)
    local note = Store.GetNote(id)
    if not note or note.kind ~= "drawing" then return nil end
    local strokes = note.drawing.strokes
    local stroke = table.remove(strokes)
    if stroke then
        note.updated = Now()
        Changed("note", id)
    end
    return stroke
end

function Store.ClearDrawing(id)
    local note = Store.GetNote(id)
    if not note or note.kind ~= "drawing" then return false end
    note.drawing.strokes = {}
    note.updated = Now()
    Changed("note", id)
    return true
end

-- ---------------------------------------------------------------- players
function Store.MyRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "")
    end
    return realm
end

-- "Name" or "Name-Realm" typed by the user -> key, name, realm. Realm spaces are removed (Forever realm names).
function Store.ParseName(input)
    input = Trim(input, 60)
    if input == "" then return nil end
    local name, realm = input:match("^([^%-]+)%-(.+)$")
    name = Trim(name or input)
    if name == "" then return nil end
    realm = realm and realm:gsub("%s", "") or nil
    if not realm or realm == "" then realm = Store.MyRealm() end
    return name .. "-" .. realm, name, realm
end

-- Current target as "Name-Realm" plus info; players only. Secret values (instances/combat) -> nil, never an error.
function Store.TargetKey()
    local exists = UnitExists("target")
    if ns.IsSecret(exists) or not exists then return nil end
    local isPlayer = UnitIsPlayer("target")
    if ns.IsSecret(isPlayer) or not isPlayer then return nil end
    local name, realm = UnitName("target")
    if ns.IsSecret(name) or ns.IsSecret(realm) or not name then return nil end
    local _, class = UnitClass("target")
    if ns.IsSecret(class) then class = nil end
    local key, cleanName, cleanRealm = Store.ParseName(realm and realm ~= "" and (name .. "-" .. realm) or name)
    if not key then return nil end
    return key, { name = cleanName, realm = cleanRealm, class = class }
end

function Store.GetPlayer(key) return key and DB().players[key] end

-- Shown name: "Name", or "Name-Realm" for players from another realm.
function Store.PlayerLabel(key)
    local player = Store.GetPlayer(key)
    local entry = player or DB().ignore[key]
    local name = entry and entry.name or (key and key:match("^(.-)%-")) or key or "?"
    local realm = entry and entry.realm or (key and key:match("%-(.+)$"))
    if realm and realm ~= Store.MyRealm() then return name .. "-" .. realm end
    return name
end

function Store.ClassColor(class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    return 0.85, 0.85, 0.85
end

local function EnsurePlayer(key, info)
    local players = DB().players
    local player = players[key]
    if not player then
        player = { notes = {} }
        players[key] = player
    end
    if info then
        player.name = info.name or player.name
        player.realm = info.realm or player.realm
        player.class = info.class or player.class
    end
    player.name = player.name or key:match("^(.-)%-") or key
    player.realm = player.realm or key:match("%-(.+)$")
    return player
end
Store.EnsurePlayer = EnsurePlayer

-- Creates an empty text note for a player (creating the player entry if needed).
function Store.CreatePlayerNote(key, info)
    if not key then return nil end
    EnsurePlayer(key, info)
    return Store.CreateNote({ kind = "text", player = key })
end

-- Notes of a player as ids, newest first.
function Store.PlayerNotes(key)
    local player = Store.GetPlayer(key)
    if not player then return {} end
    local notes, list = DB().notes, {}
    for i = 1, #player.notes do
        if notes[player.notes[i]] then list[#list + 1] = player.notes[i] end
    end
    table.sort(list, function(a, b)
        local ua, ub = notes[a].updated or 0, notes[b].updated or 0
        if ua ~= ub then return ua > ub end
        return a > b
    end)
    return list
end

-- Removes the player entry if it has no notes left (e.g. after the last note was emptied).
function Store.DropPlayerIfEmpty(key)
    local player = Store.GetPlayer(key)
    if player and #player.notes == 0 then
        DB().players[key] = nil
        Changed("player", key)
    end
end

-- Players with at least one note, sorted by name.
function Store.ListPlayers()
    local list = {}
    for key, player in pairs(DB().players) do
        list[#list + 1] = { key = key, name = player.name or key, realm = player.realm, class = player.class,
            count = #player.notes, seen = player.seen or 0 }
    end
    table.sort(list, function(a, b)
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.key < b.key
    end)
    return list
end

-- Remembers when a known player (with notes or on the ignore list) was last seen, i.e. targeted. Writes at most once a
-- minute per player so a fight with many target switches does not flood the views.
local SEEN_STEP = 60
function Store.MarkSeen(key)
    local player, entry = key and DB().players[key], key and DB().ignore[key]
    if not (player or entry) then return false end
    local now = Now()
    local last = math.max(player and player.seen or 0, entry and entry.seen or 0)
    if now - last < SEEN_STEP then return false end
    if player then player.seen = now end
    if entry then entry.seen = now end
    if player then Changed("player", key) end
    if entry then Changed("ignore", key) end
    return true
end

-- ---------------------------------------------------------------- ignore list
function Store.IsIgnored(key) return key ~= nil and DB().ignore[key] ~= nil end

function Store.GetIgnored(key) return key and DB().ignore[key] end

-- info: { name, realm, class }; the key alone is enough (parsed). Returns false, "exists" when already listed.
function Store.AddIgnored(key, info, reason)
    if not key then return false, "invalid" end
    local list = DB().ignore
    if list[key] then return false, "exists" end
    info = info or {}
    list[key] = {
        name = info.name or key:match("^(.-)%-") or key,
        realm = info.realm or key:match("%-(.+)$"),
        class = info.class,
        reason = Trim(reason, MAX_REASON),
        added = Now(),
        wow = false,
    }
    Changed("ignore", key)
    return true
end

function Store.SetIgnoreReason(key, reason)
    local entry = Store.GetIgnored(key)
    if not entry then return false end
    entry.reason = Trim(reason, MAX_REASON)
    Changed("ignore", key)
    return true
end

-- Remember whether the Blizzard ignore list was updated for this entry (see Features/Ignore.lua).
function Store.SetIgnoreWoW(key, value)
    local entry = Store.GetIgnored(key)
    if entry then entry.wow = value and true or false end
end

function Store.RemoveIgnored(key)
    local list = DB().ignore
    if not (key and list[key]) then return false end
    list[key] = nil
    Changed("ignore", key)
    return true
end

function Store.ListIgnored()
    local list = {}
    for key, entry in pairs(DB().ignore) do
        list[#list + 1] = { key = key, name = entry.name or key, realm = entry.realm, class = entry.class,
            reason = entry.reason or "", added = entry.added or 0, wow = entry.wow, seen = entry.seen or 0 }
    end
    table.sort(list, function(a, b)
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.key < b.key
    end)
    return list
end

-- ---------------------------------------------------------------- sticky state
-- note.sticky = { open, x, y, w, h, folded, lock, dock }; created on first use, removed with ClearSticky.
local STICKY_FIELDS = { open = true, x = true, y = true, w = true, h = true, folded = true, lock = true, dock = true }

function Store.GetSticky(id)
    local note = Store.GetNote(id)
    return note and note.sticky
end

function Store.SetSticky(id, fields)
    local note = Store.GetNote(id)
    if not note or type(fields) ~= "table" then return false end
    note.sticky = note.sticky or {}
    for key, value in pairs(fields) do
        if STICKY_FIELDS[key] then note.sticky[key] = value end
    end
    Changed("sticky", id)
    return true
end

function Store.ClearSticky(id)
    local note = Store.GetNote(id)
    if not (note and note.sticky) then return false end
    note.sticky = nil
    Changed("sticky", id)
    return true
end

-- Notes whose sticky window is open (restored after login).
function Store.OpenStickies()
    local list = {}
    for id, note in pairs(DB().notes) do
        if note.sticky and note.sticky.open then list[#list + 1] = id end
    end
    table.sort(list)
    return list
end

-- ---------------------------------------------------------------- integrity
-- Repairs dangling references after load or import: unknown groups, missing notes, orphaned player links.
function Store.Validate()
    local db = DB()
    for id, note in pairs(db.notes) do
        if type(note) ~= "table" then
            db.notes[id] = nil
        else
            note.kind = note.kind == "drawing" and "drawing" or "text"
            if note.group and not db.groups[note.group] then note.group = nil end
            if note.kind == "drawing" and type(note.drawing) ~= "table" then
                note.drawing = { v = 1, strokes = {} }
            end
            if note.player and not db.players[note.player] then note.player = nil end
            note.created = note.created or Now()
            note.updated = note.updated or note.created
        end
    end
    for key, player in pairs(db.players) do
        if type(player.notes) ~= "table" then player.notes = {} end
        for i = #player.notes, 1, -1 do
            local note = db.notes[player.notes[i]]
            if not note then
                table.remove(player.notes, i)
            else
                note.player = key
            end
        end
        if #player.notes == 0 then db.players[key] = nil end
    end
    -- a note linked to a player must be in that player's list
    for id, note in pairs(db.notes) do
        if note.player then
            local player = db.players[note.player]
            local found = false
            if player then
                for _, nid in ipairs(player.notes) do
                    if nid == id then found = true break end
                end
            end
            if not found then note.player = nil end
        end
    end
end

ns.OnReady(Store.Validate)
