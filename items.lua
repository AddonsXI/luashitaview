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

-- The only module that touches Ashita; everything else stays testable outside the game.

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

-- LuAshitacast loads a profile by matching the job to its filename, so the name is the job. Nil
-- for anything else, which leaves the filter open.
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

-- Words accumulate until one carries a number, which closes a stat. Line breaks close first: a
-- stat with no value of its own sits on its own line in the game's text.
M.StatPhrases = function(description)
    if (type(description) ~= 'string') or (#description == 0) then
        return {};
    end

    -- A line continuing a sentence starts lowercase or with a quote and is rejoined first.
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
    -- A phrase can be a bare label like "Wyvern:" when the description breaks there.
    local joined = table.concat(hits, ', ');
    return (string.gsub(joined, '[:%s]+$', ''));
end

-- No mask means unrestricted, matching the game.
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

-- backups holds every timestamped copy ever written, so it is never walked.
local SKIP_DIRS = { backups = true };

-- Names are enumerated, never guessed: Rag's ships Rag_5040 and plenty of people never rename
-- it. A folder is anything with no file extension.
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

-- Stricter than Windows requires, on purpose.
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

-- os.rename fails on an existing target with an unhelpful message, so the collision is named
-- first.
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

    -- Older XML profiles are listed so they show as unsupported rather than missing.
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

    -- Frameworks keep gear in a subfolder (BasicLuas: common\blsets.lua). Only files declaring
    -- a sets table are listed, by anchor, so nothing is executed.
    -- Two levels down: common\J-GUI and defaults\includes both exist in real repositories.
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
        -- The character folder is already listed as yours.
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

-- /addon reload works whether or not it is running, so there is no state to read. LuAshitacast
-- then loads the profile for the job you are on, and cycles reset.
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

    -- false rather than nil: a nil would look like a miss and be retried every frame.
    nameToId[key] = false;
    return nil;
end

-- The element and auto-translate icons are byte pairs starting 0xEF, which ImGui reads as the
-- lead of a three byte character and swallows the byte after: '+15' shows as '?15'.
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

-- Exported for the suite.
M.CleanGameText = CleanGameText;


-- The item level when it has one, prefixed i as retail writes it, else the equip level. Nil
-- when there is neither.
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

M.PickerRow = function(id, info, count, slip)
    return {
        id = id,
        name = info.name,
        count = count or 0,
        slots = info.slots,
        level = info.level or 0,
        ilvl = info.ilvl or 0,
        jobs = info.jobs,
        search = info.searchText,
        -- The slip number when this was decoded off a slip and never seen in a bag.
        slip = slip or nil,
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
        -- One byte in the client data read back as two: unmasked, a 119 piece reads 375 and a
        -- piece with no item level reads 256.
        ilvl = bit.band(item.ItemLevel or 0, 0xFF),
        jobs = item.Jobs,
        slots = item.Slots,
        type = item.Type,
        stack = item.StackSize,
    };
    -- Lowercased once. The item level joins as i119 so it can be typed; nothing is added when
    -- there is none.
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

-- A slip's contents arrive as a bitmask in its Extra bytes, never as a container.
-- The count is not sent, so a stored piece is recorded as 1.
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

-- Storage Slips sit in the bag list as one more bag, under this id. The real ones stop at 16.
M.SLIP_BAG = 17;
local FIRST_SLIP = 29312;
local slipsSeen = false;

-- containers is the bag ids to report, or nil for every bag and the slips. Every bag is
-- still walked, because a slip can sit in a bag that is switched off.
M.ScanInventory = function(containers)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local want = nil;
    if (containers ~= nil) then
        want = {};
        for _, id in ipairs(containers) do
            want[id] = true;
        end
    end
    local wantSlips = (want == nil) or (want[M.SLIP_BAG] == true);
    local seen = {};
    local anySlip = false;
    for container = 0, 16 do
        local maxSlots = inv:GetContainerCountMax(container);
        if (maxSlots ~= nil) and (maxSlots > 0) then
            for slotIndex = 1, maxSlots do
                local entry = inv:GetContainerItem(container, slotIndex);
                if (entry ~= nil) and (entry.Id ~= nil) and (entry.Id > 0) and (entry.Id ~= 65535) then
                    if (want == nil) or want[container] then
                        local info = M.GetItemInfo(entry.Id);
                        if (info ~= nil) and (info.slots ~= nil) and (info.slots ~= 0) then
                            local existing = seen[entry.Id];
                            if (existing ~= nil) and (existing.slip == nil) then
                                existing.count = existing.count + (entry.Count or 1);
                            else
                                -- A bag copy replaces a slip placeholder rather than adding to it.
                                seen[entry.Id] = M.PickerRow(entry.Id, info, entry.Count or 1);
                            end
                        end
                    end

                    local slipItemIds = M.DecodeSlipContents(entry);
                    if (slipItemIds ~= nil) then
                        anySlip = true;
                        if wantSlips then
                            local slipNumber = entry.Id - FIRST_SLIP + 1;
                            for _, slipItemId in ipairs(slipItemIds) do
                                if (seen[slipItemId] == nil) then
                                    local slipInfo = M.GetItemInfo(slipItemId);
                                    if (slipInfo ~= nil) and (slipInfo.slots ~= nil) and (slipInfo.slots ~= 0) then
                                        seen[slipItemId] = M.PickerRow(slipItemId, slipInfo, 1, slipNumber);
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    slipsSeen = anySlip;
    local out = {};
    for _, row in pairs(seen) do
        table.insert(out, row);
    end
    table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name); end);
    return out;
end


local ownedNamesCache = { names = nil, at = 0 };

-- A bag not bought or lapsed reports a max count of zero. Nil when the inventory cannot be
-- read, which callers treat as show everything.
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
    if slipsSeen then
        out[M.SLIP_BAG] = true;
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
        -- true for a piece in a bag, the slip number for one that is only on a slip. Every
        -- test elsewhere asks for true, so slip gear still counts as not wearable.
        for _, row in ipairs(rows) do
            names[string.lower(row.name)] = row.slip or true;
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
