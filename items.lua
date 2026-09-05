--[[
* Addons - Copyright (c) 2026 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
--]]

--[[
* Everything that has to ask the game something: item data, icons, bags, file paths.
*
* This is the only module that touches Ashita, which is what keeps the other three
* testable outside the game.
--]]

local ffi = require('ffi');
local d3d8 = require('d3d8');
local C = ffi.C;
local prof = require('profile');
local slipData = require('slipdata');

local M = {};

local iconCache = {};
local iconQueue = {};
local iconQueued = {};
local nameToId = {};
local itemInfoCache = {};

local dbSweep = { running = false, done = false, nextId = 1, maxId = 65535, perFrame = 1600, results = {} };

M.Debug = false;

M.Dbg = function(text)
    if M.Debug then
        print('[luashitaview] ' .. text);
    end
end

M.JobCount = 22;

M.GetCharacter = function()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local name = party:GetMemberName(0);
    local id = party:GetMemberServerId(0);
    if (name == nil) or (name == '') or (id == nil) or (id == 0) then
        return nil, nil;
    end
    return name, id;
end

M.GetMainJob = function()
    local jobId = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
    if ((type(jobId) == 'number') and (jobId > 0)) then
        return jobId;
    end
    return nil;
end

M.GetMainJobLevel = function()
    local level = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
    if ((type(level) == 'number') and (level > 0)) then
        return level;
    end
    return nil;
end

M.ActiveProfilePath = function(lacSettings)
    local name, id = M.GetCharacter();
    if (name == nil) then
        return nil;
    end
    local jobId = M.GetMainJob();
    if (jobId == nil) then
        return nil;
    end
    local jobAbbr = M.GetJobAbbr(jobId);
    if (jobAbbr == nil) or (#jobAbbr == 0) then
        return nil;
    end
    local root = M.LacRoot();
    local candidates = {
        string.format('%s%s_%u\\%s.lua', root, name, id, jobAbbr),
        string.format('%s%s_%s.lua', root, name, jobAbbr),
    };
    if (lacSettings ~= nil) and (type(lacSettings.DefaultProfile) == 'string') then
        table.insert(candidates, root .. lacSettings.DefaultProfile);
    end
    for _, path in ipairs(candidates) do
        if M.FileExists(path) then
            return path;
        end
    end
    return nil;
end

M.GetJobAbbr = function(jobId)
    local s = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', jobId);
    if (type(s) == 'string') then
        return (string.gsub(s, '%z*$', ''));
    end
    return nil;
end

-- Turns an item's job mask into readable text, like 'WAR/PLD/DRK'. Bit N is job N.
local jobTextCache = {};

M.DescribeJobs = function(mask)
    if (type(mask) ~= 'number') or (mask == 0) then
        return 'All Jobs';
    end

    local cached = jobTextCache[mask];
    if (cached ~= nil) then
        return cached;
    end

    local names = {};
    for j = 1, M.JobCount do
        if (bit.band(bit.rshift(mask, j), 1) == 1) then
            local abbr = M.GetJobAbbr(j);
            if (abbr ~= nil) and (#abbr > 0) then
                table.insert(names, abbr);
            end
        end
    end

    local text;
    if (#names == 0) or (#names >= M.JobCount) then
        text = 'All Jobs';
    else
        text = table.concat(names, '/');
    end

    jobTextCache[mask] = text;
    return text;
end

M.AllJobAbbrs = function()
    local out = {};
    for j = 1, M.JobCount do
        local a = M.GetJobAbbr(j);
        if (a ~= nil) and (#a > 0) then
            table.insert(out, a);
        end
    end
    return out;
end

local jobList = nil;

M.JobList = function()
    if (jobList ~= nil) then
        return jobList;
    end
    jobList = {};
    for j = 1, M.JobCount do
        local a = M.GetJobAbbr(j);
        if (a ~= nil) and (#a > 0) then
            table.insert(jobList, { id = j, abbr = a });
        end
    end
    return jobList;
end

-- The earned level in any job, unlike GetMainJobLevel, which drops under level sync.
M.GetJobLevel = function(jobId)
    if (jobId == nil) or (jobId <= 0) then
        return nil;
    end
    local level = AshitaCore:GetMemoryManager():GetPlayer():GetJobLevel(jobId);
    if ((type(level) == 'number') and (level > 0)) then
        return level;
    end
    return nil;
end

--[[
* Which job a profile is for, from its filename. Not a guess: LuAshitacast loads a
* profile by matching the job to its name, so for anything the game will actually load
* the name IS the job. Returns nil for anything else, which leaves the filter open.
--]]
M.JobFromProfileName = function(stem)
    if (type(stem) ~= 'string') or (#stem == 0) then
        return nil;
    end

    local candidate = string.gsub(stem, '%.lua$', '');
    candidate = string.gsub(candidate, '^.*_', '');
    candidate = string.gsub(candidate, '%d+$', '');
    candidate = string.lower(candidate);

    for _, j in ipairs(M.JobList()) do
        if (string.lower(j.abbr) == candidate) then
            return j.id;
        end
    end
    return nil;
end

--[[
* Splits an item's description into whole stats. Splitting on spaces breaks multi-word
* stats like 'Enhancing Magic Skill +7', but a stat almost always ends in its value, so
* words accumulate until one carries a number and that closes the phrase. A stat with
* no value of its own ('Latent effect: Regen') sits on its own line in the game's text,
* so line breaks are taken first and close the phrases the numbers cannot.
--]]
M.StatPhrases = function(description)
    if (type(description) ~= 'string') or (#description == 0) then
        return {};
    end

    -- Newlines both separate stats and wrap long sentences for display. A line that
    -- continues a sentence starts lowercase or with a quote, so those are rejoined
    -- first and only genuine stat breaks survive.
    local lines = {};
    for line in string.gmatch(description .. '\n', '([^\r\n]*)[\r\n]') do
        line = string.gsub(line, '^%s+', '');
        if (#line > 0) then
            local continues = (#lines > 0) and (string.match(line, '^[%l"\'(]') ~= nil);
            if continues then
                lines[#lines] = lines[#lines] .. ' ' .. line;
            else
                lines[#lines + 1] = line;
            end
        end
    end

    local phrases = {};

    for _, line in ipairs(lines) do
        local current = {};

        for word in string.gmatch(line, '%S+') do
            current[#current + 1] = word;
            if (string.find(word, '%d') ~= nil) then
                phrases[#phrases + 1] = table.concat(current, ' ');
                current = {};
            end
        end
        if (#current > 0) then
            phrases[#phrases + 1] = table.concat(current, ' ');
        end
    end

    return phrases;
end

M.MatchedStat = function(info, needle)
    if (info == nil) or (needle == nil) or (#needle == 0) then
        return nil;
    end
    if (info.description == nil) or (#info.description == 0) then
        return nil;
    end
    if (string.find(string.lower(info.name or ''), needle, 1, true) ~= nil) then
        return nil;
    end

    local hits = {};
    for _, phrase in ipairs(M.StatPhrases(info.description)) do
        if (string.find(string.lower(phrase), needle, 1, true) ~= nil) then
            hits[#hits + 1] = phrase;
            if (#hits >= 3) then
                break;
            end
        end
    end

    if (#hits == 0) then
        return nil;
    end
    -- A phrase can be a bare label like "Wyvern:" when the description breaks there,
    -- and a snippet ending in a colon reads like a sentence that lost its second half.
    local joined = table.concat(hits, ', ');
    return (string.gsub(joined, '[:%s]+$', ''));
end

-- An item with no mask is treated as unrestricted rather than wearable by nobody,
-- matching what the game does.
M.JobCanEquip = function(mask, jobId)
    if (jobId == nil) or (jobId <= 0) then
        return true;
    end
    if (type(mask) ~= 'number') or (mask == 0) then
        return true;
    end
    return bit.band(bit.rshift(mask, jobId), 1) == 1;
end

M.LacRoot = function()
    return string.format('%sconfig\\addons\\luashitacast\\', AshitaCore:GetInstallPath());
end

M.ReadFile = function(path)
    local f = io.open(path, 'rb');
    if (f == nil) then
        return nil;
    end
    local c = f:read('*a');
    f:close();
    return c;
end

M.WriteFile = function(path, bytes)
    local f = io.open(path, 'wb');
    if (f == nil) then
        return false;
    end
    f:write(bytes);
    f:close();
    return true;
end

M.FileExists = function(path)
    local f = io.open(path, 'rb');
    if (f ~= nil) then
        f:close();
        return true;
    end
    return false;
end

M.CreateDirectories = function(path)
    local backSlash = string.byte('\\');
    for c = 1, #path, 1 do
        if (path:byte(c) == backSlash) then
            local directory = string.sub(path, 1, c);
            if (ashita.fs.create_directory(directory) == false) then
                return false;
            end
        end
    end
    return true;
end

--[[
* Folder names that must never be walked. backups sits inside a character folder and
* holds every timestamped copy the addon has ever written, so scanning it would fill the
* profile list with 2024.10.04_10.27.04_THF.lua forever.
--]]
local SKIP_DIRS = { backups = true };

--[[
* The subfolders of a directory. Names are never guessed: frameworks ship their own
* character folder, Rag's ships Rag_5040 and expects you to rename it, and plenty of
* people never do. Enumerating covers any name at all, including ones nobody has seen.
*
* A folder is anything with no file extension, and the guess costs nothing when wrong:
* listing lua files inside a non-folder simply returns none.
--]]
M.ListSubdirs = function(dir)
    local out = {};
    local ok, entries = pcall(function()
        return ashita.fs.get_directory(dir);
    end);
    if ok and (type(entries) == 'table') then
        for _, e in pairs(entries) do
            if (type(e) == 'string') and (string.match(e, '%.%w+$') == nil)
                and (not SKIP_DIRS[string.lower(e)]) then
                table.insert(out, e);
            end
        end
    end
    table.sort(out, function(a, b) return string.lower(a) < string.lower(b); end);
    return out;
end

M.ListLua = function(dir)
    local out = {};
    local ok, entries = pcall(function()
        return ashita.fs.get_directory(dir, '.*\\.lua');
    end);
    if ok and (type(entries) == 'table') then
        for _, e in pairs(entries) do
            if (type(e) == 'string') then
                table.insert(out, e);
            end
        end
    end
    table.sort(out, function(a, b) return string.lower(a) < string.lower(b); end);
    return out;
end

-- Deliberately stricter than Windows requires: anything outside this set is more
-- likely a mistake than an intention.
M.ValidFileStem = function(stem)
    if (type(stem) ~= 'string') or (#stem == 0) then
        return false, 'A file needs a name.';
    end
    if (string.gsub(stem, '[^%w%s_%-]+', '') ~= stem) then
        return false, 'File names can use letters, numbers, spaces, _ and -.';
    end
    if (string.match(stem, '^%s') ~= nil) or (string.match(stem, '%s$') ~= nil) then
        return false, 'File names cannot start or end with a space.';
    end
    return true;
end

-- os.rename fails when the target exists, but with an unhelpful message, so the
-- collision is checked first and named plainly.
M.RenameFile = function(oldPath, newPath)
    local existing = io.open(newPath, 'rb');
    if (existing ~= nil) then
        existing:close();
        return false, 'A file with that name already exists.';
    end
    local ok, err = os.rename(oldPath, newPath);
    if (not ok) then
        return false, 'Could not rename file: ' .. tostring(err);
    end
    return true;
end

M.LacInstalled = function()
    local path = string.format('%saddons\\luashitacast\\luashitacast.lua', AshitaCore:GetInstallPath());
    local f = io.open(path, 'rb');
    if (f ~= nil) then
        f:close();
        return true;
    end
    return false;
end

M.DiscoverProfiles = function()
    local root = M.LacRoot();
    local name, id = M.GetCharacter();
    local yours, others, unsupported = {}, {}, {};
    local jobSet = {};
    for _, a in ipairs(M.AllJobAbbrs()) do
        jobSet[string.lower(a)] = true;
    end

    if (name ~= nil) then
        local charDir = string.format('%s%s_%u\\', root, name, id);
        for _, f in ipairs(M.ListLua(charDir)) do
            if (string.lower(f) ~= 'settings.lua') then
                table.insert(yours, { path = charDir .. f, label = name .. '_' .. id .. '\\' .. f });
            end
        end
    end

    for _, f in ipairs(M.ListLua(root)) do
        local stem = string.gsub(f, '%.lua$', '');
        local matched = false;
        if (name ~= nil) then
            local prefix = string.lower(name) .. '_';
            local lowered = string.lower(stem);
            if (string.sub(lowered, 1, #prefix) == prefix) and jobSet[string.sub(lowered, #prefix + 1)] then
                matched = true;
            end
        end
        local entry = { path = root .. f, label = f };
        if matched then
            table.insert(yours, entry);
        else
            table.insert(others, entry);
        end
    end

    -- LuAshitacast's older XML profiles are listed so they show as unsupported rather
    -- than silently missing.
    local okx, xml = pcall(function()
        return ashita.fs.get_directory(root, '.*\\.xml');
    end);
    if okx and (type(xml) == 'table') then
        for _, f in pairs(xml) do
            if (type(f) == 'string') then
                table.insert(unsupported, { path = root .. f, label = f });
            end
        end
    end

    --[[
    * Frameworks keep their own gear in a subfolder (BasicLuas puts blsets.lua in
    * common\), so that is scanned too. Only files that actually declare a sets table
    * are listed; the same folder holds pure logic files that are not profiles. The test
    * is the anchor rather than a full parse, so nothing is executed to build a list the
    * user has not asked to open yet.
    --]]
    -- Two levels down, because frameworks nest their gear a folder deeper than their
    -- own: common\J-GUI and defaults\includes both appear in real repositories.
    local mine = (name ~= nil) and string.lower(string.format('%s_%u', name, id)) or nil;
    local seen = {};
    local function Sweep(rel)
        local dir = root .. rel .. '\\';
        for _, f in ipairs(M.ListLua(dir)) do
            local full = dir .. f;
            if (not seen[string.lower(full)]) then
                seen[string.lower(full)] = true;
                local text = M.ReadFile(full);
                if (text ~= nil) and (prof.FindAnchor(text) ~= nil) then
                    table.insert(others, { path = full, label = rel .. '\\' .. f });
                end
            end
        end
    end

    for _, sub in ipairs(M.ListSubdirs(root)) do
        -- The character folder is already listed as yours, so skip it rather than
        -- offering every one of its profiles a second time.
        if (mine == nil) or (string.lower(sub) ~= mine) then
            Sweep(sub);
            for _, deeper in ipairs(M.ListSubdirs(root .. sub .. '\\')) do
                Sweep(sub .. '\\' .. deeper);
            end
        end
    end

    return { yours = yours, others = others, unsupported = unsupported };
end

M.LoadLacSettings = function()
    local defaults = {
        AddSetBackups = true,
        AddSetEquipScreenOrder = true,
        EquipBags = { 0, 8, 10, 11, 12, 13, 14, 15, 16 },
    };
    local name, id = M.GetCharacter();
    if (name == nil) then
        return defaults;
    end
    local path = string.format('%s%s_%u\\settings.lua', M.LacRoot(), name, id);
    local text = M.ReadFile(path);
    if (text == nil) then
        return defaults;
    end
    local parsed = prof.ParseCharSettings(text);
    if (parsed == nil) then
        return defaults;
    end
    for k, v in pairs(defaults) do
        if (parsed[k] == nil) then
            parsed[k] = v;
        end
    end
    if (#parsed.EquipBags == 0) then
        parsed.EquipBags = defaults.EquipBags;
    end
    local hasInventory = false;
    for _, b in ipairs(parsed.EquipBags) do
        if (b == 0) then
            hasInventory = true;
        end
    end
    if (not hasInventory) then
        table.insert(parsed.EquipBags, 1, 0);
    end
    return parsed;
end

M.BackupProfile = function(model, lacSettings)
    if (lacSettings ~= nil) and (lacSettings.AddSetBackups == false) then
        return true, nil;
    end
    local name, id = M.GetCharacter();
    if (name == nil) then
        return false, 'Not logged in; cannot create backup.';
    end
    local dir = string.format('%s%s_%u\\backups\\', M.LacRoot(), name, id);
    if (not M.CreateDirectories(dir)) then
        return false, 'Could not create backup folder.';
    end
    local stamp = os.date('%Y.%m.%d_%H.%M.%S');
    local target = string.format('%s%s_%s', dir, stamp, model.filename);
    if (not M.WriteFile(target, model.textAtLoad)) then
        return false, 'Could not write backup file.';
    end
    return true, target;
end

M.ListBackups = function(filename)
    local name, id = M.GetCharacter();
    if (name == nil) then
        return {};
    end
    local dir = string.format('%s%s_%u\\backups\\', M.LacRoot(), name, id);
    local out = {};
    local suffix = string.lower('_' .. filename);
    for _, f in ipairs(M.ListLua(dir)) do
        if (string.sub(string.lower(f), -#suffix) == suffix) then
            local stamp = string.sub(f, 1, #f - #suffix);
            table.insert(out, { file = f, path = dir .. f, stamp = stamp });
        end
    end
    table.sort(out, function(a, b) return a.file > b.file; end);
    return out;
end

--[[
* Restarts LuAshitacast so it picks the profile up off disk.
*
* /addon reload works whether or not it is already running, which is what makes
* this the whole story: no state to read, nothing to go stale, and no way to be
* tricked by the user unloading it behind our back.
*
* The trade is that LuAshitacast then loads the profile for the job you are ON,
* not the file you happen to be editing, and your cycles reset. Accepted on the
* user's call as far simpler than anything that has to track state.
--]]
M.QueueReload = function()
    AshitaCore:GetChatManager():QueueCommand(-1, '/addon reload luashitacast');
end


local function CreateTexture(itemId)
    local item = AshitaCore:GetResourceManager():GetItemById(itemId);
    if (item == nil) or (item.Bitmap == nil) or (item.ImageSize == 0) then
        return nil;
    end
    local device = d3d8.get_device();
    if (device == nil) then
        return nil;
    end
    local texturePtr = ffi.new('IDirect3DTexture8*[1]');
    local result = C.D3DXCreateTextureFromFileInMemoryEx(
        device, item.Bitmap, item.ImageSize,
        0xFFFFFFFF, 0xFFFFFFFF,
        1, 0,
        C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT,
        0xFF000000,
        nil, nil, texturePtr);
    if (result ~= C.S_OK) then
        return nil;
    end
    return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', texturePtr[0]));
end

M.RequestIcon = function(itemId)
    if (itemId == nil) or (itemId <= 0) or (itemId == 65535) then
        return;
    end
    if (iconCache[itemId] ~= nil) or iconQueued[itemId] then
        return;
    end
    iconQueued[itemId] = true;
    table.insert(iconQueue, itemId);
end

M.GetIconPtr = function(itemId)
    local cached = iconCache[itemId];
    if (cached == nil) then
        M.RequestIcon(itemId);
        return nil;
    end
    if (cached == false) then
        return nil;
    end
    return tonumber(ffi.cast('uint32_t', cached));
end

M.PumpIcons = function(maxPerFrame)
    local n = 0;
    while (#iconQueue > 0) and (n < (maxPerFrame or 8)) do
        local id = table.remove(iconQueue, 1);
        iconQueued[id] = nil;
        if (iconCache[id] == nil) then
            -- A failed icon is cached as false so it is never retried.
            local ok, tex = pcall(CreateTexture, id);
            if ok and (tex ~= nil) then
                iconCache[id] = tex;
            else
                iconCache[id] = false;
            end
        end
        n = n + 1;
    end
end

M.ResolveItemId = function(name)
    if (name == nil) or (#name == 0) then
        return nil;
    end
    local key = string.lower(name);
    local memo = nameToId[key];
    if (memo ~= nil) then
        if (memo == false) then
            return nil;
        end
        return memo;
    end
    local item = AshitaCore:GetResourceManager():GetItemByName(name, 0);
    if (item ~= nil) then
        nameToId[key] = item.Id;
        return item.Id;
    end

    -- Cached as false rather than nil; a nil would look like a cache miss and be
    -- retried every frame.
    nameToId[key] = false;
    return nil;
end

--[[
* Replaces the game's inline icon bytes with words so text renders in ImGui. The
* element and auto-translate icons are byte pairs starting 0xEF, which ImGui reads as
* the lead of a three byte UTF-8 character, so it swallows the pair AND the byte after
* it: an untouched description shows '?15' where the game shows an icon then '+15'.
* Any other high byte is dropped for the same reason.
--]]
local ICON_WORDS = {
    ['\239\31'] = 'Fire',      ['\239\32'] = 'Ice',
    ['\239\33'] = 'Wind',      ['\239\34'] = 'Earth',
    ['\239\35'] = 'Lightning', ['\239\36'] = 'Water',
    ['\239\37'] = 'Light',     ['\239\38'] = 'Darkness',
    ['\239\39'] = '',          ['\239\40'] = '',
};

local function CleanGameText(text)
    if (type(text) ~= 'string') then
        return nil;
    end

    text = string.gsub(text, '\239[\31-\40]', function(pair)
        return ICON_WORDS[pair] or '';
    end);

    text = string.gsub(text, '[\128-\255]', '');
    text = string.gsub(text, '%z', '');
    return text;
end

-- Exported only so the suite can reach it. Its failure mode looks like an
-- unrelated bug (a '+' vanishing, not an icon), so it is worth pinning.
M.CleanGameText = CleanGameText;


--[[
* One picker row, built in one place. It existed twice, once for your bags and once
* for the whole item database, and the two drifted: the item level was added to the
* row that the display and the level filter both read, and neither copy set it, so
* nothing ever showed an i119 and the filter compared against the equip level.
--]]
--[[
* How a piece's level is written wherever one is shown: the item level when it has
* one, prefixed i the way retail writes it, and the equip level otherwise. Every
* item level piece requires level 99, so printing both would say the same thing
* twice.
*
* Nil when there is neither, so callers can leave the badge off entirely.
--]]
M.LevelBadge = function(info)
    if (info == nil) then
        return nil;
    end
    if ((info.ilvl or 0) > 0) then
        return 'i' .. info.ilvl;
    end
    if ((info.level or 0) > 0) then
        return tostring(info.level);
    end
    return nil;
end

M.PickerRow = function(id, info, count, onSlip)
    return {
        id = id,
        name = info.name,
        count = count or 0,
        slots = info.slots,
        level = info.level or 0,
        ilvl = info.ilvl or 0,
        jobs = info.jobs,
        search = info.searchText,
        -- True when this row was never actually seen in a bag, only decoded off a
        -- Storage Slip's Extra bytes. Lets the picker say so instead of implying the
        -- piece sits loose in a container it was never scanned out of.
        onSlip = onSlip or nil,
    };
end

M.GetItemInfo = function(itemId)
    if (itemId == nil) or (itemId <= 0) then
        return nil;
    end
    local cached = itemInfoCache[itemId];
    if (cached ~= nil) then
        if (cached == false) then
            return nil;
        end
        return cached;
    end
    local item = AshitaCore:GetResourceManager():GetItemById(itemId);
    if (item == nil) then
        itemInfoCache[itemId] = false;
        return nil;
    end
    local info = {
        id = itemId,
        name = (item.Name ~= nil) and item.Name[1] or nil,
        description = (item.Description ~= nil) and CleanGameText(item.Description[1]) or nil,
        level = item.Level,
        -- One byte in the client data, read back as two, so the byte after it lands in
        -- the high half. Masked here or a 119 piece reads 375 and 29 items that have no
        -- item level at all read 256. Item levels only ever run 100 to 119.
        ilvl = bit.band(item.ItemLevel or 0, 0xFF),
        jobs = item.Jobs,
        slots = item.Slots,
        type = item.Type,
        stack = item.StackSize,
    };
    --[[
    * Lowercased once here; the alternative is lowercasing thousands of descriptions
    * on every keystroke.
    *
    * The item level joins it as i119 so it can be typed, since it appears nowhere in
    * the name or the description. Nothing is added when there is none, so a search
    * for i0 finds nothing rather than everything.
    --]]
    info.searchText = string.lower((info.name or '') .. ' ' .. (info.description or ''));
    if (info.ilvl > 0) then
        info.searchText = info.searchText .. ' i' .. info.ilvl;
    end

    if (info.name == nil) or (info.name == '') then
        itemInfoCache[itemId] = false;
        return nil;
    end
    itemInfoCache[itemId] = info;
    return info;
end

--[[
* A Storage Slip is an ordinary item sitting in a bag slot; what it holds is never
* sent to the client as its own container, only baked into the slip's 28 byte Extra
* field as a bitmask over a fixed, slip-specific item list. Bit N set means the
* (N+1)th item in slipdata's list for that slip has at least one stored on it - real
* quantity belongs to the Porter Moogle alone and never reaches the client, which is
* why every slip find below is recorded as count 1 rather than guessed at.
*
* The bit order and per-slip item lists come from Windower's public resources repo
* (resources_data/slips.lua); nothing in Ashita or the client names this mapping.
--]]
M.DecodeSlipContents = function(entry)
    if (entry == nil) or (entry.Id == nil) then
        return nil;
    end
    local candidates = slipData[entry.Id];
    if (candidates == nil) then
        return nil;
    end
    local extra = entry.Extra;
    if (type(extra) ~= 'string') or (#extra == 0) then
        return nil;
    end
    local out = {};
    for i, itemId in ipairs(candidates) do
        -- A 0 is a gap in the bit list (a retired or region-locked slot), not an item.
        if (itemId ~= 0) then
            local bitPos = i - 1;
            local byteVal = string.byte(extra, bit.rshift(bitPos, 3) + 1);
            if (byteVal ~= nil) and (bit.band(bit.rshift(byteVal, bit.band(bitPos, 7)), 1) == 1) then
                table.insert(out, itemId);
            end
        end
    end
    return out;
end

M.ScanInventory = function(containers)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local seen = {};
    for _, container in ipairs(containers or { 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }) do
        local maxSlots = inv:GetContainerCountMax(container);
        if (maxSlots ~= nil) and (maxSlots > 0) then
            for slotIndex = 1, maxSlots do
                local entry = inv:GetContainerItem(container, slotIndex);
                if (entry ~= nil) and (entry.Id ~= nil) and (entry.Id > 0) and (entry.Id ~= 65535) then
                    local info = M.GetItemInfo(entry.Id);
                    if (info ~= nil) and (info.slots ~= nil) and (info.slots ~= 0) then
                        local existing = seen[entry.Id];
                        if (existing ~= nil) and (not existing.onSlip) then
                            existing.count = existing.count + (entry.Count or 1);
                        else
                            -- A real bag find always replaces a slip-only placeholder rather
                            -- than adding to it, since the placeholder's count of 1 was a
                            -- guess, not something actually sitting in this slot.
                            seen[entry.Id] = M.PickerRow(entry.Id, info, entry.Count or 1);
                        end
                    end

                    -- A slip only adds a placeholder for an item nothing else has found
                    -- yet, whether that is a bag copy scanned earlier or later, or another
                    -- slip carrying the same item.
                    local slipItemIds = M.DecodeSlipContents(entry);
                    if (slipItemIds ~= nil) then
                        for _, slipItemId in ipairs(slipItemIds) do
                            if (seen[slipItemId] == nil) then
                                local slipInfo = M.GetItemInfo(slipItemId);
                                if (slipInfo ~= nil) and (slipInfo.slots ~= nil) and (slipInfo.slots ~= 0) then
                                    seen[slipItemId] = M.PickerRow(slipItemId, slipInfo, 1, true);
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local out = {};
    for _, row in pairs(seen) do
        table.insert(out, row);
    end
    table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name); end);
    return out;
end


local ownedNamesCache = { names = nil, at = 0 };

--[[
* The container ids this character actually has, as a set. A bag they have not bought or
* whose subscription has lapsed reports a max count of zero.
*
* Returns nil when the inventory cannot be read at all, which the caller must treat as
* "show everything": graying out every bag because the game was not ready would be worse
* than graying out none.
--]]
M.AvailableBags = function()
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then
        return nil;
    end
    local out = {};
    local any = false;
    for id = 0, 16 do
        local max = inv:GetContainerCountMax(id);
        if (type(max) == 'number') and (max > 0) then
            out[id] = true;
            any = true;
        end
    end
    if (not any) then
        return nil;
    end
    return out;
end

M.OwnedNames = function()
    local now = os.time();
    if (ownedNamesCache.names ~= nil) and ((now - ownedNamesCache.at) < 5) then
        return ownedNamesCache.names;
    end
    local names = {};
    -- On failure the previous list is returned, so a hiccup shows stale ownership dots
    -- instead of clearing every one of them.
    local ok, rows = pcall(M.ScanInventory, nil);
    if ok and (rows ~= nil) then
        for _, row in ipairs(rows) do
            names[string.lower(row.name)] = true;
        end
        ownedNamesCache.names = names;
        ownedNamesCache.at = now;
        return names;
    end
    return ownedNamesCache.names or {};
end

M.StartDbSweep = function()
    if dbSweep.running or dbSweep.done then
        return;
    end
    dbSweep.running = true;
    dbSweep.nextId = 1;
    dbSweep.results = {};
end

M.PumpDbSweep = function()
    if (not dbSweep.running) then
        return;
    end
    -- Swept in slices; walking all 65535 ids in one frame visibly hitches the game.
    local target = math.min(dbSweep.nextId + dbSweep.perFrame - 1, dbSweep.maxId);
    for id = dbSweep.nextId, target do
        local info = M.GetItemInfo(id);
        if (info ~= nil) and (info.slots ~= nil) and (info.slots ~= 0)
            and (info.name ~= nil) and (string.match(info.name, '%a') ~= nil) then
            table.insert(dbSweep.results, M.PickerRow(id, info, 0));
        end
    end
    dbSweep.nextId = target + 1;
    if (dbSweep.nextId > dbSweep.maxId) then
        dbSweep.running = false;
        dbSweep.done = true;
        table.sort(dbSweep.results, function(a, b) return string.lower(a.name) < string.lower(b.name); end);
        M.Dbg('Item scan done: ' .. #dbSweep.results .. ' equippable items indexed.');
    end
end

M.DbSweep = function()
    return dbSweep;
end

local pInterfaceHidden = ashita.memory.find('FFXiMain.dll', 0, '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0);

M.GetInterfaceHidden = function()
    if (pInterfaceHidden ~= 0) then
        local ptr = ashita.memory.read_uint32(pInterfaceHidden + 10);
        if (ptr ~= 0 and ashita.memory.read_uint8(ptr + 0xB4) == 1) then
            return true;
        end
    end

    local index = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    if (index == 0) then
        return true;
    end

    local flags = AshitaCore:GetMemoryManager():GetEntity():GetRenderFlags0(index);
    return (bit.band(flags, 0x200) ~= 0x200) or (bit.band(flags, 0x4000) ~= 0);
end

return M;
