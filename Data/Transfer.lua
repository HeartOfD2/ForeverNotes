-- ForeverNotes export/import: notes (text and drawings, with their group or player) and optionally the ignore list as one
-- line of text "FN1:" + Base64(JSON). The decoder never runs code: it parses JSON itself and every value is checked
-- before anything is written. No frames in here.
local _, ns = ...
local L = ns.L
local Store = ns.Store

local Transfer = {}
ns.Transfer = Transfer

local PREFIX = "FN1:"
local VERSION = 1
local MAX_CODE = 3000000 -- characters; far above any real export, protects against pasted garbage
local MAX_RECORDS = 2000
local MAX_DEPTH = 8

---------------------------------------------------------------------------
-- Base64 (arithmetic only: Lua 5.1 has no bit operators)
---------------------------------------------------------------------------

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENCODE, DECODE = {}, {}
for i = 1, 64 do
    local c = ALPHABET:sub(i, i)
    ENCODE[i - 1] = c
    DECODE[c:byte()] = i - 1
end

function Transfer.B64Encode(data)
    local out, n = {}, 0
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local value = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(value / 262144) % 64
        local c2 = math.floor(value / 4096) % 64
        local c3 = math.floor(value / 64) % 64
        local c4 = value % 64
        n = n + 1
        out[n] = ENCODE[c1] .. ENCODE[c2] .. (b and ENCODE[c3] or "=") .. (c and ENCODE[c4] or "=")
    end
    return table.concat(out)
end

function Transfer.B64Decode(text)
    text = text:gsub("%s", "")
    if text == "" or #text % 4 ~= 0 or text:find("[^%w%+/=]") then return nil end
    local out, n = {}, 0
    for i = 1, #text, 4 do
        local c1, c2, c3, c4 = text:byte(i, i + 3)
        local pad3, pad4 = c3 == 61, c4 == 61
        local v1, v2 = DECODE[c1], DECODE[c2]
        local v3, v4 = pad3 and 0 or DECODE[c3], pad4 and 0 or DECODE[c4]
        if not (v1 and v2 and v3 and v4) or (pad3 and not pad4) or ((pad3 or pad4) and i + 3 < #text) then return nil end
        local value = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
        local b1, b2, b3 = math.floor(value / 65536), math.floor(value / 256) % 256, value % 256
        n = n + 1
        out[n] = pad3 and string.char(b1) or pad4 and string.char(b1, b2) or string.char(b1, b2, b3)
    end
    return table.concat(out)
end

---------------------------------------------------------------------------
-- JSON (small, strict, no code execution)
---------------------------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function EncodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or ("\\u%04x"):format(c:byte())
    end) .. '"'
end

local function IsArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

local function Encode(value, out)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = EncodeString(value)
    elseif kind == "number" then
        out[#out + 1] = value == math.floor(value) and ("%d"):format(value) or ("%.6g"):format(value)
    elseif kind == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif kind == "table" then
        if IsArray(value) then
            out[#out + 1] = "["
            for i = 1, #value do
                if i > 1 then out[#out + 1] = "," end
                Encode(value[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            for _, key in ipairs(keys) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = EncodeString(key) .. ":"
                Encode(value[key], out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end

function Transfer.JSONEncode(value)
    local out = {}
    Encode(value, out)
    return table.concat(out)
end

local function Utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
    return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

-- Returns value, or nil + message. A tiny recursive-descent parser over `text`.
function Transfer.JSONDecode(text)
    local pos = 1
    local Value

    local function Skip()
        pos = text:find("[^ \t\r\n]", pos) or #text + 1
    end

    local function String()
        local out, n = {}, 0
        pos = pos + 1
        while true do
            local stop = text:find('["\\]', pos)
            if not stop then return nil end
            n = n + 1
            out[n] = text:sub(pos, stop - 1)
            if text:sub(stop, stop) == '"' then
                pos = stop + 1
                return table.concat(out)
            end
            local esc = text:sub(stop + 1, stop + 1)
            n = n + 1
            if esc == "u" then
                local hex = text:match("^%x%x%x%x", stop + 2)
                if not hex then return nil end
                out[n] = Utf8(tonumber(hex, 16))
                pos = stop + 6
            else
                local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f" }
                if not map[esc] then return nil end
                out[n] = map[esc]
                pos = stop + 2
            end
        end
    end

    function Value(depth)
        if depth > MAX_DEPTH then return nil end
        Skip()
        local c = text:sub(pos, pos)
        if c == "{" then
            local obj = {}
            pos = pos + 1
            Skip()
            if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                Skip()
                if text:sub(pos, pos) ~= '"' then return nil end
                local key = String()
                if not key then return nil end
                Skip()
                if text:sub(pos, pos) ~= ":" then return nil end
                pos = pos + 1
                local v = Value(depth + 1)
                if v == nil then return nil end
                obj[key] = v
                Skip()
                local d = text:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then return nil end
            end
        elseif c == "[" then
            local arr = {}
            pos = pos + 1
            Skip()
            if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                local v = Value(depth + 1)
                if v == nil then return nil end
                arr[#arr + 1] = v
                Skip()
                local d = text:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then return nil end
            end
        elseif c == '"' then
            return String()
        elseif text:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif text:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        else
            local number = text:match("^-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not number or number == "" then return nil end
            pos = pos + #number
            return tonumber(number)
        end
    end

    local ok, value = pcall(Value, 1)
    if not ok or value == nil then return nil, "json" end
    Skip()
    if pos <= #text then return nil, "json" end
    return value
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

local function CopyColor(c) return { c[1], c[2], c[3] } end

local function NoteRecord(id)
    local note = Store.GetNote(id)
    if not note then return nil end
    local rec = { k = note.kind, t = note.title or "", c = note.created, u = note.updated }
    if note.kind == "text" then rec.x = note.text or "" else rec.d = note.drawing end
    if note.player then
        local player = Store.GetPlayer(note.player)
        rec.p = note.player
        if player and player.class then rec.pc = player.class end
    elseif note.group then
        local group = Store.GetGroup(note.group)
        if group then
            rec.g = group.name
            rec.gc = CopyColor(group.color)
        end
    end
    return rec
end

-- opts.notes = list of note ids, opts.ignore = include the ignore list. Returns the code string.
function Transfer.Encode(opts)
    local payload = { v = VERSION, notes = {} }
    for _, id in ipairs(opts.notes or {}) do
        local rec = NoteRecord(id)
        if rec then payload.notes[#payload.notes + 1] = rec end
    end
    if opts.ignore then
        payload.ignore = {}
        for _, entry in ipairs(Store.ListIgnored()) do
            payload.ignore[#payload.ignore + 1] = { key = entry.key, n = entry.name, r = entry.realm, c = entry.class,
                why = entry.reason, a = entry.added }
        end
    end
    return PREFIX .. Transfer.B64Encode(Transfer.JSONEncode(payload))
end

---------------------------------------------------------------------------
-- Import
---------------------------------------------------------------------------

-- Returns the payload table, or nil + reason: "empty" | "prefix" | "size" | "base64" | "json" | "version" | "shape".
function Transfer.Decode(code)
    if type(code) ~= "string" or code:find("^%s*$") then return nil, "empty" end
    code = code:gsub("^%s+", ""):gsub("%s+$", "")
    if code:sub(1, #PREFIX) ~= PREFIX then return nil, "prefix" end
    if #code > MAX_CODE then return nil, "size" end
    local json = Transfer.B64Decode(code:sub(#PREFIX + 1))
    if not json then return nil, "base64" end
    local payload, why = Transfer.JSONDecode(json)
    if not payload then return nil, why or "json" end
    if type(payload) ~= "table" or payload.v ~= VERSION then return nil, "version" end
    if type(payload.notes) ~= "table" or #payload.notes + (type(payload.ignore) == "table" and #payload.ignore or 0) > MAX_RECORDS then
        return nil, "shape"
    end
    return payload
end

local function Str(value, limit)
    if type(value) ~= "string" then return "" end
    return value:sub(1, limit or 20000)
end

local function Time(value)
    value = tonumber(value)
    if value and value > 0 and value < 4102444800 then return math.floor(value) end
    return nil
end

local function Color(value)
    if type(value) ~= "table" then return nil end
    local r, g, b = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
    if r and g and b then return { r, g, b } end
end

-- Group by name, created when missing.
local function GroupFor(name, color)
    name = Str(name, 40)
    if name == "" then return nil end
    for _, group in ipairs(Store.ListGroups()) do
        if group.name == name then return group.id end
    end
    return Store.CreateGroup(name, Color(color))
end

local function Existing(rec, groupId, playerKey)
    local ids = playerKey and Store.PlayerNotes(playerKey) or Store.ListNotes({ kind = rec.kind })
    for _, id in ipairs(ids) do
        local note = Store.GetNote(id)
        if note.kind == rec.kind and (note.title or "") == rec.title and (playerKey or note.group) == (playerKey or groupId) then
            if rec.kind == "text" then
                if (note.text or "") == rec.text then return true end
            elseif Store.CountSegments(note.drawing) == Store.CountSegments(rec.drawing) then
                return true
            end
        end
    end
    return false
end

-- Writes a decoded payload. Returns { notes, skipped, groups, ignore, truncated }.
function Transfer.Import(payload)
    local result = { notes = 0, skipped = 0, groups = 0, ignore = 0, truncated = 0 }
    local groupsBefore = #Store.ListGroups()
    for _, raw in ipairs(payload.notes or {}) do
        if type(raw) == "table" and (raw.k == "text" or raw.k == "drawing") then
            local rec = { kind = raw.k, title = Str(raw.t, 80), text = Str(raw.x) }
            if rec.kind == "drawing" then
                local drawing, truncated = Store.SanitizeDrawing(raw.d)
                rec.drawing = drawing
                if truncated then result.truncated = result.truncated + 1 end
            end
            local groupId, playerKey, playerInfo
            if type(raw.p) == "string" and raw.p ~= "" then
                local key, name, realm = Store.ParseName(raw.p)
                if key then
                    playerKey = key
                    playerInfo = { name = name, realm = realm, class = type(raw.pc) == "string" and raw.pc:sub(1, 20) or nil }
                end
            elseif raw.g then
                groupId = GroupFor(raw.g, raw.gc)
            end
            if Existing(rec, groupId, playerKey) then
                result.skipped = result.skipped + 1
            else
                local id, note
                if playerKey then
                    Store.EnsurePlayer(playerKey, playerInfo)
                    id, note = Store.CreateNote({ kind = rec.kind, title = rec.title, text = rec.text, player = playerKey })
                else
                    id, note = Store.CreateNote({ kind = rec.kind, title = rec.title, text = rec.text, group = groupId })
                end
                if note then
                    if rec.drawing then note.drawing = rec.drawing end
                    note.created = Time(raw.c) or note.created
                    note.updated = Time(raw.u) or note.updated
                    result.notes = result.notes + 1
                end
            end
        end
    end
    result.groups = #Store.ListGroups() - groupsBefore
    if type(payload.ignore) == "table" then
        for _, raw in ipairs(payload.ignore) do
            if type(raw) == "table" and type(raw.key) == "string" then
                local key, name, realm = Store.ParseName(raw.key)
                if key and not Store.IsIgnored(key) then
                    Store.AddIgnored(key, { name = name, realm = realm,
                        class = type(raw.c) == "string" and raw.c:sub(1, 20) or nil }, Str(raw.why, 120))
                    local entry = Store.GetIgnored(key)
                    if entry then entry.added = Time(raw.a) or entry.added end
                    result.ignore = result.ignore + 1
                end
            end
        end
    end
    Store.Changed("note")
    Store.Changed("group")
    Store.Changed("player")
    return result
end

-- Human readable message for a Decode failure.
function Transfer.Why(reason)
    if reason == "empty" then return L["Paste a code first."] end
    if reason == "prefix" then return L["That is no ForeverNotes code (it starts with FN1:)."] end
    if reason == "version" then return L["This code was made by a newer version."] end
    if reason == "size" then return L["The code is too long."] end
    return L["The code is damaged or incomplete."]
end
