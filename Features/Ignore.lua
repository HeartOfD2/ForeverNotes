-- ForeverNotes ignore list behaviour: add/remove (optionally mirrored to the Blizzard ignore list), warning sound,
-- chat line when an ignored player is targeted. The popup marks the target itself (UI/Popup.lua).
-- Secret target data (instances, combat) gives no key from Store.TargetKey: then there is no warning and no error.
local _, ns = ...
local L = ns.L
local Store = ns.Store

local Ignore = {}
ns.Ignore = Ignore

local BLIZZARD_LIMIT = 50
local CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }

-- Curated SOUNDKIT keys (all present in the Forever beta, V-N6); only those that exist at runtime are offered.
local SOUND_KEYS = { "RAID_WARNING", "READY_CHECK", "UI_RAID_BOSS_WHISPER_WARNING", "ALARM_CLOCK_WARNING_2",
    "ALARM_CLOCK_WARNING_3", "AUCTION_WINDOW_OPEN", "IG_MAINMENU_OPEN", "TELL_MESSAGE", "MAP_PING", "UI_BNET_TOAST" }

local function Settings() return ns.db.settings.ignore end

local function LSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true) or nil
end

local function Pretty(key)
    return (key:gsub("_", " "):lower():gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

-- values (key -> label) and order for a dropdown
function Ignore.Sounds()
    local values, order = {}, {}
    for _, key in ipairs(SOUND_KEYS) do
        if SOUNDKIT and SOUNDKIT[key] ~= nil then
            values[key] = Pretty(key)
            order[#order + 1] = key
        end
    end
    local lsm = LSM()
    if lsm then
        local ok, hash = pcall(lsm.HashTable, lsm, "sound")
        if ok and type(hash) == "table" then
            local names = {}
            for name in pairs(hash) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local key = "lsm:" .. name
                values[key] = name
                order[#order + 1] = key
            end
        end
    end
    return values, order
end

function Ignore.Channels()
    local values = { Master = L["Master"], SFX = L["Effects"], Music = L["Music"], Ambience = L["Ambience"],
        Dialog = L["Dialog"] }
    return values, CHANNELS
end

function Ignore.Play(key, channel)
    key = key or Settings().sound
    channel = channel or Settings().channel or "Master"
    if type(key) == "string" and key:sub(1, 4) == "lsm:" then
        local lsm = LSM()
        local path = lsm and lsm:Fetch("sound", key:sub(5), true)
        if path and PlaySoundFile then PlaySoundFile(path, channel) end
    elseif SOUNDKIT and SOUNDKIT[key] ~= nil then
        PlaySound(SOUNDKIT[key], channel)
    elseif SOUNDKIT and SOUNDKIT.RAID_WARNING ~= nil then
        PlaySound(SOUNDKIT.RAID_WARNING, channel)
    end
end

-- Name as the Blizzard list wants it: plain for our own realm, else Name-Realm.
local function WoWName(entry)
    local name, realm = entry.name, entry.realm
    if not name then return nil end
    if realm and realm ~= "" and realm ~= Store.MyRealm() then return name .. "-" .. realm end
    return name
end

-- Call from click handlers only (the Blizzard list rejects protected calls from other paths).
function Ignore.Add(key, info, reason)
    local ok, why = Store.AddIgnored(key, info, reason)
    if not ok then return false, why end
    if Settings().syncWoW and C_FriendList and C_FriendList.AddIgnore then
        local entry = Store.GetIgnored(key)
        local name = entry and WoWName(entry)
        local full = C_FriendList.GetNumIgnores and C_FriendList.GetNumIgnores() or 0
        if not name then
            ns.Say(L["Could not add to the Blizzard ignore list."])
        elseif full >= BLIZZARD_LIMIT then
            ns.Say(L["The Blizzard ignore list is full."])
        elseif pcall(C_FriendList.AddIgnore, name) then
            Store.SetIgnoreWoW(key, true)
        else
            ns.Say(L["Could not add to the Blizzard ignore list."])
        end
    end
    return true
end

function Ignore.Remove(key)
    local entry = Store.GetIgnored(key)
    if not entry then return false end
    local wow, name = entry.wow, WoWName(entry)
    Store.RemoveIgnored(key)
    if wow and name and C_FriendList and C_FriendList.DelIgnore then pcall(C_FriendList.DelIgnore, name) end
    return true
end

---------------------------------------------------------------------------
-- Warning when an ignored player is targeted; a secret target name gives no key and no warning
---------------------------------------------------------------------------

local lastWarned = {}

function Ignore.OnTarget()
    local key = Store.TargetKey() -- nil for secret or non-player targets
    if not key then return end
    Store.MarkSeen(key)
    local entry = Store.GetIgnored(key)
    if not entry then return end
    local cfg = Settings()
    local now = GetTime()
    if lastWarned[key] and now - lastWarned[key] < (cfg.throttle or 30) then return end
    lastWarned[key] = now
    if cfg.soundOn then Ignore.Play() end
    if cfg.chat then
        local reason = entry.reason or ""
        ns.Say(reason ~= "" and L["Ignored player targeted: %s (%s)"]:format(Store.PlayerLabel(key), reason)
            or L["Ignored player targeted: %s"]:format(Store.PlayerLabel(key)))
    end
end

ns.OnReady(function()
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:SetScript("OnEvent", function() Ignore.OnTarget() end)
end)
