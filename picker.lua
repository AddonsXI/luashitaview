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

-- All Items sweeps the client's own item table locally; nothing is ever sent to the server.

local imgui = require('imgui');
local items = require('items');
local prof = require('profile');
local theme = require('theme');

local M = {};

local state = {
    open = false,
    slotName = nil,
    onPick = nil,
    onClear = nil,
    search = { '' },
    mode = 1,
    -- Always on.
    slotFilter = { true },

    -- 0 means every job. Anything else is a job id, tested as a bit against the mask.
    jobFilter = 0,

    -- The job the open profile is for, so the filter can default to it.
    profileJob = nil,

    -- The number the level box holds. 0 means show every level.
    levelFilter = { 0 },

    -- 1 treats that number as a ceiling, 2 as a floor for narrowing to endgame gear.
    levelMode = 1,

    -- 1 alphabetical, 2 by level.
    sortMode = 2,
    inventory = nil,
    owned = nil,

    recentOpen = true,

    -- The last few things picked, newest first, capped at RECENT_CAP.
    recent = {},
};

-- Every container Your bags can read, in the order the game shows them. Wardrobe 5 to 8 are ids
-- 13 to 16.
local BagList = {
    { id = 0, label = 'Inventory' },
    { id = 1, label = 'Safe' },
    { id = 2, label = 'Storage' },
    { id = 4, label = 'Locker' },
    { id = 5, label = 'Satchel' },
    { id = 6, label = 'Sack' },
    { id = 7, label = 'Case' },
    { id = 8, label = 'Wardrobe' },
    { id = 9, label = 'Safe2' },
    { id = 10, label = 'Wardrobe2' },
    { id = 11, label = 'Wardrobe3' },
    { id = 12, label = 'Wardrobe4' },
    { id = 13, label = 'Wardrobe5' },
    { id = 14, label = 'Wardrobe6' },
    { id = 15, label = 'Wardrobe7' },
    { id = 16, label = 'Wardrobe8' },
    { id = items.SLIP_BAG, label = 'Storage Slips' },
};

-- Only the switched-off bags are stored, so the saved value is empty by default and a
-- bag the character gains later is searched without anyone having to opt in.
local function SaveBagPick()
    if (state.config == nil) or (state.config.picker_bags == nil) then
        return;
    end
    local off = {};
    for _, b in ipairs(BagList) do
        if (state.bagPick ~= nil) and (state.bagPick[b.id] == false) then
            off[#off + 1] = b.id;
        end
    end
    state.config.picker_bags = off;
end

-- Ears and rings share one mask each. Lowercased once, so 'ring1' gets the shared mask.
local function SlotMask(slotName)
    local lower = string.lower(slotName or '');
    local idx = prof.SlotIndex[lower];
    if (idx == nil) then
        return 0;
    end
    if (lower == 'ear1') or (lower == 'ear2') then
        return 0x1800;
    end
    if (lower == 'ring1') or (lower == 'ring2') then
        return 0x6000;
    end
    return bit.lshift(1, idx - 1);
end

-- Recents are drawn from a loop of their own, so without this they ignore the slot rule.
M.RecentFits = function(name, state)
    if (not state.slotFilter[1]) then
        return true;
    end
    local mask = SlotMask(state.slotName);
    if (mask == 0) then
        return true;
    end
    local id = items.ResolveItemId(name);
    local info = (id ~= nil) and items.GetItemInfo(id) or nil;
    -- A name nothing resolves stays offered, as in the main list.
    if (info == nil) or (info.slots == nil) then
        return true;
    end
    return bit.band(info.slots, mask) ~= 0;
end

-- Set when a row is dragged, read once by ui on the same frame. It is deliberately not
-- the drag state itself: that lives with the editing state, which picker cannot require.
local pendingDrag = nil;

M.TakePendingDrag = function()
    local d = pendingDrag;
    pendingDrag = nil;
    return d;
end

local SHOW_LIMIT = 400;

-- Keyed by lowercased name: a profile holds a name, and the same piece can carry more than one
-- id.
M.IsFavorite = function(favorites, name)
    if (favorites == nil) or (name == nil) then
        return false;
    end
    return favorites[string.lower(name)] == true;
end

M.IsStarred = function(name)
    return M.IsFavorite(state.favorites, name);
end

-- Retail gear past the cap climbs in item level, not equip level, but accessories never carry
-- one, so anything without falls back to its equip level.
M.EffectiveLevel = function(row)
    local ilvl = row.ilvl or 0;
    if (ilvl > 0) then
        return ilvl;
    end
    return row.level or 0;
end

-- Owned beats unowned; among equals the higher id wins, since an upgrade ladder runs upward
-- through the item table.
local function Better(a, b)
    local ao = (a.count or 0) > 0;
    local bo = (b.count or 0) > 0;
    if (ao ~= bo) then
        return ao;
    end
    return (a.id or 0) > (b.id or 0);
end

-- A name match outranks a stat match whatever the sort says.
M.FilterAndSort = function(source, state)
    local mask = SlotMask(state.slotName);
    local needle = string.lower(state.search[1] or '');

    local matches = {};
    local nameHit = {};
    local favOf = {};
    for _, row in ipairs(source or {}) do
        local pass = true;
        local fav = M.IsFavorite(state.favorites, row.name);
        if state.slotFilter[1] and (mask ~= 0) and (row.slots ~= nil) then
            pass = bit.band(row.slots, mask) ~= 0;
        end
        if pass and (state.jobFilter > 0) then
            pass = items.JobCanEquip(row.jobs, state.jobFilter);
        end
        -- A favorite never overrides a filter; it only ranks.
        if pass and (state.levelFilter[1] > 0) then
            if (state.levelMode == 2) then
                pass = M.EffectiveLevel(row) >= state.levelFilter[1];
            elseif (row.level ~= nil) then
                pass = row.level <= state.levelFilter[1];
            end
        end
        favOf[row] = fav;
        if pass and (#needle > 0) then
            local hay = row.search or string.lower(row.name);
            pass = string.find(hay, needle, 1, true) ~= nil;
            if pass then
                nameHit[row] = string.find(string.lower(row.name), needle, 1, true) ~= nil;
            end
        end
        if pass then
            matches[#matches + 1] = row;
        end
    end

    -- One row per name, because a profile stores a piece by name and every upgrade stage of a
    -- relic shares one. The survivor is the one you own, else the highest id. Counts are summed
    -- onto a copy, or the source would grow every frame.
    local order, byName = {}, {};
    for _, row in ipairs(matches) do
        local key = string.lower(row.name or '');
        local kept = byName[key];
        if (kept == nil) then
            byName[key] = { row = row, count = row.count or 0 };
            order[#order + 1] = key;
        else
            kept.count = kept.count + (row.count or 0);
            if Better(row, kept.row) then
                kept.row = row;
            end
        end
    end
    matches = {};
    for _, key in ipairs(order) do
        local kept = byName[key];
        local row = kept.row;
        if (kept.count ~= (row.count or 0)) then
            local merged = {};
            for k, v in pairs(row) do
                merged[k] = v;
            end
            merged.count = kept.count;
            nameHit[merged] = nameHit[row];
            row = merged;
        end
        matches[#matches + 1] = row;
    end

    -- One comparator for all four orders; a name match and a favorite outrank the rest
    -- whichever direction. Levels compare on the effective level.
    local byLevel = (state.sortMode == 2) or (state.sortMode == 3);
    local descending = (state.sortMode == 2) or (state.sortMode == 4);

    table.sort(matches, function(a, b)
        local na, nb = nameHit[a] or false, nameHit[b] or false;
        if (na ~= nb) then
            return na;
        end
        local fa, fb = favOf[a] or false, favOf[b] or false;
        if (fa ~= fb) then
            return fa;
        end
        if byLevel then
            local la, lb = M.EffectiveLevel(a), M.EffectiveLevel(b);
            if (la ~= lb) then
                if descending then
                    return la > lb;
                end
                return la < lb;
            end
            -- Ties fall back to the name so the order does not shuffle between frames.
            return string.lower(a.name) < string.lower(b.name);
        end
        local sa, sb = string.lower(a.name), string.lower(b.name);
        if descending then
            return sa > sb;
        end
        return sa < sb;
    end);

    return matches, nameHit, favOf;
end

-- Exported so the test suite caps at the same number the draw loop does.
M.ShowLimit = SHOW_LIMIT;

-- Enforced here so the stored list can never grow unbounded.
local RECENT_CAP = 6;
M.RecentCap = RECENT_CAP;

local function RememberPick(name)
    if (name == nil) or prof.Sentinels[string.lower(name)] then
        return;
    end
    for i, r in ipairs(state.recent) do
        if (string.lower(r) == string.lower(name)) then
            table.remove(state.recent, i);
            break;
        end
    end
    table.insert(state.recent, 1, name);
    while (#state.recent > RECENT_CAP) do
        table.remove(state.recent);
    end
end

local function SetSort(mode)
    state.sortMode = mode;
    if (state.config ~= nil) and (state.config.picker_sort ~= nil) then
        state.config.picker_sort[1] = mode;
    end
end

-- Picking leaves the panel as it was; Done is the only thing that closes it.
local function DoPick(name)
    RememberPick(name);
    if (state.onPick ~= nil) then
        state.onPick(name);
    end
end

-- Anything the character does not have is dropped, so a lost bag cannot keep excluding itself.
-- Nil means every bag.
M.SearchContainers = function()
    local available = items.AvailableBags();
    if (available == nil) or (state.bagPick == nil) then
        return nil;
    end
    local out = {};
    for id = 0, items.SLIP_BAG do
        if available[id] and (state.bagPick[id] ~= false) then
            out[#out + 1] = id;
        end
    end
    if (#out == 0) then
        return nil;
    end
    return out;
end

-- Exported for the suite only, so the bag choice can be set without a game to click in.
M.__setBagPick = function(pick)
    state.bagPick = pick;
end

-- Doubles as the only indication that bags have been switched off.
M.BagsLabel = function()
    local available = items.AvailableBags();
    if (available == nil) or (state.bagPick == nil) then
        return 'All Bags';
    end
    for id in pairs(available) do
        if (state.bagPick[id] == false) then
            return 'Some Bags';
        end
    end
    return 'All Bags';
end

M.RescanBags = function()
    state.inventory = items.ScanInventory(M.SearchContainers());
end

-- Only which slot changes; the search and filters are left alone.
-- inSlot is a FUNCTION returning the slot's names, since the slot changes while the panel is
-- open.
M.Open = function(slotName, currentName, onPick, onClear, inSlot)
    state.open = true;
    state.slotName = slotName;
    state.onPick = onPick;
    state.onClear = onClear;
    state.inSlot = inSlot;
    M.RescanBags();
    items.Dbg('Picker found ' .. tostring(slotName) .. ': ' .. #state.inventory .. ' owned equippable items across your bags.');
end

-- Test seams.
-- The grid marks this slot, so the border cannot be left on one nobody is looking at.
M.AimedAt = function()
    return state.open and state.slotName or nil;
end

M.State = function()
    return state;
end

M.DoPickForTest = function(name)
    DoPick(name);
end

M.SetConfig = function(config)
    state.config = config;

    -- Read once; this runs every frame, and re-reading would overwrite a change the
    -- user just made, one frame after they made it.
    if (not state.sortLoaded) and (config ~= nil) and (config.picker_sort ~= nil) and (config.picker_sort[1] ~= nil) then
        state.sortLoaded = true;
        state.sortMode = config.picker_sort[1];
    end
    if (not state.lvlModeLoaded) and (config ~= nil) and (config.picker_levelmode ~= nil)
        and (config.picker_levelmode[1] ~= nil) then
        state.lvlModeLoaded = true;
        state.levelMode = config.picker_levelmode[1];
    end
    if (not state.recentLoaded) and (config ~= nil) and (config.picker_recent_open ~= nil)
        and (config.picker_recent_open[1] ~= nil) then
        state.recentLoaded = true;
        state.recentOpen = (config.picker_recent_open[1] ~= false);
    end
    if (not state.bagsLoaded) and (config ~= nil) and (config.picker_bags ~= nil) then
        state.bagsLoaded = true;
        state.bagPick = {};
        for _, id in ipairs(config.picker_bags) do
            if (type(id) == 'number') then
                state.bagPick[id] = false;
            end
        end
    end
    if (not state.favLoaded) and (config ~= nil) and (config.picker_favorites ~= nil) then
        state.favLoaded = true;
        state.favorites = {};
        for _, name in ipairs(config.picker_favorites) do
            if (type(name) == 'string') and (#name > 0) then
                state.favorites[string.lower(name)] = true;
            end
        end
    end
end

-- The stored list keeps the name as picked, for anything that shows it back; the
-- lookup beside it is lowercased for matching.
M.ToggleFavorite = function(name)
    if (name == nil) or (#name == 0) then
        return;
    end
    state.favorites = state.favorites or {};
    local key = string.lower(name);
    local nowFavorite = (state.favorites[key] ~= true);
    if nowFavorite then
        state.favorites[key] = true;
    else
        state.favorites[key] = nil;
    end
    if (state.config ~= nil) and (state.config.picker_favorites ~= nil) then
        local list = state.config.picker_favorites;
        for i = #list, 1, -1 do
            if (type(list[i]) == 'string') and (string.lower(list[i]) == key) then
                table.remove(list, i);
            end
        end
        if nowFavorite then
            table.insert(list, name);
        end
    end
    return nowFavorite;
end

M.IsOpen = function()
    return state.open;
end

-- The profile always wins over a manual pick: a filter left on the last job would
-- silently hide gear once the open file changes.
M.SetProfileJob = function(jobId)
    state.profileJob = jobId;
    state.jobFilter = jobId or 0;

    -- The earned level in the profile's job, so a PLD file synced down still shows the PLD gear
    -- you own. 119 is the last resort, the position that hides nothing.
    state.levelFilter[1] = items.GetJobLevel(jobId) or items.GetMainJobLevel() or 119;
end

local function DrawRowTooltip(id)
    local info = items.GetItemInfo(id);
    if (info == nil) then
        return;
    end

    imgui.BeginTooltip();
    imgui.PushTextWrapPos(320);

    imgui.Text(info.name or '');

    local line = items.DescribeJobs(info.jobs);
    if (info.level ~= nil) and (info.level > 0) then
        line = string.format('Lv.%d  %s', info.level, line);
    end
    imgui.TextColored(theme.col.textDim, line);

    if (info.description ~= nil) and (#info.description > 0) then
        imgui.Separator();
        imgui.Text(info.description);
    end

    imgui.PopTextWrapPos();
    imgui.EndTooltip();
end

local ROW_ICON = 16;

-- Below this the search box takes a row of its own.
local SEARCH_MIN = 120;

-- ImGui's own horizontal item spacing, which the row widths have to account for.
local ITEM_GAP = 8;

local function DrawRow(row, showOwned, needle, noInSlot)
    -- Plain text rather than a button: a framed button was taller than the icon. Dropped to the
    -- icon's middle, since a line of text is shorter.
    local favorite = M.IsFavorite(state.favorites, row.name);
    imgui.SetCursorPosY(imgui.GetCursorPosY()
        + ((ROW_ICON - imgui.GetTextLineHeight()) * 0.5));
    imgui.TextColored(favorite and theme.col.accent or theme.col.textFaint, '*');
    if imgui.IsItemClicked(0) then
        M.ToggleFavorite(row.name);
    end
    imgui.SameLine();
    local ptr = items.GetIconPtr(row.id);
    if (ptr ~= nil) then
        imgui.Image(ptr, { ROW_ICON, ROW_ICON });
    else
        imgui.Dummy({ ROW_ICON, ROW_ICON });
    end
    imgui.SameLine();
    -- The number shown is the one Max and Min compare against. An item level is prefixed i.
    local label = row.name;
    local badge = items.LevelBadge(row);
    if (badge ~= nil) then
        label = string.format('[%s] %s', badge, row.name);
    end
    if (row.count ~= nil) and (row.count > 1) then
        label = label .. ' x' .. row.count;
    end
    local own = state.ownedNames and state.ownedNames[string.lower(row.name or '')];
    local slipNumber = row.slip or ((type(own) == 'number') and own or nil);
    if (slipNumber ~= nil) then
        label = label .. string.format(' (Slip %02d)', slipNumber);
    end
    local flags = 0;
    local clicked;
    -- Already in this slot reads as selected. Green text means you own it.
    -- Recent Picks turns this off: the piece just clicked is in the slot by definition.
    local here = (not noInSlot) and (state.present ~= nil)
        and (state.present[string.lower(row.name or '')] == true);
    if here then
        imgui.PushStyleColor(ImGuiCol_Header, theme.col.accentBg);
    end
    -- Green means you have it, which is the thing this list is asked most often.
    -- Orange means it is yours but on a slip, so it cannot be worn until fetched.
    if showOwned and (own == true) then
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.accent);
        clicked = imgui.Selectable(label .. '##item' .. row.id, here, flags);
        imgui.PopStyleColor();
    elseif showOwned and (slipNumber ~= nil) then
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.caution);
        clicked = imgui.Selectable(label .. '##item' .. row.id, here, flags);
        imgui.PopStyleColor();
    else
        clicked = imgui.Selectable(label .. '##item' .. row.id, here, flags);
    end
    if here then
        imgui.PopStyleColor();
    end

    -- Recorded rather than acted on: picker cannot see the editing state without a require
    -- cycle, so ui collects it after the panel draws.
    if imgui.IsItemHovered() and imgui.IsMouseDragging(0, 6.0) then
        pendingDrag = { name = row.name, id = row.id };
    end

    if imgui.IsItemHovered() then
        DrawRowTooltip(row.id);
    end

    -- When a search hit the stats, the matching bit shows beside the row.
    if (needle ~= nil) and (#needle > 0) then
        local hit = items.MatchedStat(items.GetItemInfo(row.id), needle);
        if (hit ~= nil) then
            imgui.SameLine();
            imgui.TextColored(theme.col.textDim, hit);
        end
    end

    return clicked;
end

local function DrawBagMode()
        -- The label carries the state and opens the chooser. Three hashes: the visible half
        -- changes, and with two the popup would lose its anchor.
        if imgui.RadioButton(M.BagsLabel() .. '###lsvbagsmode', state.mode == 1) then
            if (state.mode == 1) then
                imgui.OpenPopup('##lsvbags');
            end
            state.mode = 1;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Click again to choose bags.');
        end
        -- A drawn arrow: the font is the game's, so a typed chevron may have no glyph.
        imgui.SameLine(0, 7);
        if imgui.ArrowButton('##lsvbagsopen', ImGuiDir_Down) then
            state.mode = 1;
            imgui.OpenPopup('##lsvbags');
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Choose bags to search.');
        end
        imgui.SameLine();
        if imgui.RadioButton('All Items', state.mode == 2) then
            state.mode = 2;
            items.StartDbSweep();
        end

        -- For a wardrobe holding lockstyle gear, or one that lapsed with a subscription.
        if imgui.BeginPopup('##lsvbags') then
            local available = items.AvailableBags();
            if (available == nil) then
                imgui.TextDisabled('Cannot read bags yet.');
            else
                state.bagPick = state.bagPick or {};
                local changed = false;
                for _, b in ipairs(BagList) do
                    if available[b.id] then
                        local on = { state.bagPick[b.id] ~= false };
                        if imgui.Checkbox(b.label .. '##bag' .. b.id, on) then
                            state.bagPick[b.id] = on[1];
                            changed = true;
                        end
                    end
                end
                imgui.Separator();
                if imgui.SmallButton('All') then
                    state.bagPick = {};
                    changed = true;
                end
                imgui.SameLine();
                if imgui.SmallButton('Rescan') then
                    changed = true;
                end
                if changed then
                    M.RescanBags();
                    SaveBagPick();
                end
            end
            imgui.EndPopup();
        end
end

-- One function: the search box is measured against where the filter row started.
local function DrawFiltersAndResults()
    -- Once a frame, not once a row. Ownership is asked the same way the grid asks it, across
    -- every container rather than just the ticked bags.
    state.ownedNames = items.OwnedNames();
    state.present = {};
    if (state.inSlot ~= nil) then
        local ok, names = pcall(state.inSlot);
        if ok and (type(names) == 'table') then
            for _, n in ipairs(names) do
                if (type(n) == 'string') then
                    state.present[string.lower(n)] = true;
                end
            end
        end
    end
        -- Taken once; every row is sized against it rather than against the row above.
        local panelW = imgui.GetContentRegionAvail();

        -- A dropdown: as a button nobody could tell it was clickable.
        local function SetLevelMode(mode)
            state.levelMode = mode;
            if (state.config ~= nil) and (state.config.picker_levelmode ~= nil) then
                state.config.picker_levelmode[1] = mode;
            end
        end
        local jobs = items.JobList();
        local mine = items.GetMainJob();
        -- The star marks your own job in the list only.
        local label = 'Any';
        for _, j in ipairs(jobs) do
            if (j.id == state.jobFilter) then
                label = j.abbr;
            end
        end

        -- Job, the level and its bound share what the row has left, split in the proportion
        -- they had.
        local labelsW = imgui.CalcTextSize('Job') + imgui.CalcTextSize('Lvl');
        local share = panelW - labelsW - (ITEM_GAP * 3);
        local jobW = math.floor(share * 0.38);
        local lvlW = math.floor(share * 0.24);
        local modeW = share - jobW - lvlW;

        imgui.AlignTextToFramePadding();
        imgui.TextDisabled('Job');
        imgui.SameLine();
        imgui.SetNextItemWidth(jobW);
        if imgui.BeginCombo('##lsvjob', label, 0) then
            if imgui.Selectable('Any', state.jobFilter == 0, 0) then
                state.jobFilter = 0;
            end

            -- Your own job first, since it is the one you want nine times in ten.
            if (mine ~= nil) then
                local abbr = items.GetJobAbbr(mine) or '';
                if imgui.Selectable('*' .. abbr, state.jobFilter == mine, 0) then
                    state.jobFilter = mine;
                end
            end

            imgui.Separator();
            for _, j in ipairs(jobs) do
                if imgui.Selectable(j.abbr, state.jobFilter == j.id, 0) then
                    state.jobFilter = j.id;
                end
            end
            imgui.EndCombo();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show equipment this job can wear.');
        end
        imgui.SameLine();
        -- The two touch so they read as one control.
        imgui.AlignTextToFramePadding();
        imgui.TextDisabled('Lvl');
        imgui.SameLine();

        imgui.SetNextItemWidth(lvlW);
        imgui.InputInt('##lsvlevel', state.levelFilter, 0, 0);
        if imgui.IsItemHovered() then
            imgui.SetTooltip('The level for Max or Min.');
        end
        -- Equip levels run 1 to 99 and item levels 100 to 119; 119 with Max hides nothing.
        if (state.levelFilter[1] < 1) then
            state.levelFilter[1] = 1;
        elseif (state.levelFilter[1] > 119) then
            state.levelFilter[1] = 119;
        end
        imgui.SameLine(0, 0);

        imgui.SetNextItemWidth(modeW);
        if imgui.BeginCombo('##lsvlevelmode', (state.levelMode == 2) and 'Min' or 'Max', 0) then
            if imgui.Selectable('Max', state.levelMode ~= 2, 0) then
                SetLevelMode(1);
            end
            if imgui.Selectable('Min', state.levelMode == 2, 0) then
                SetLevelMode(2);
            end
            imgui.EndCombo();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Max hides equipment above the level.\nMin hides equipment below it.');
        end

        local source = state.inventory or {};
        if (state.mode == 2) then
            local sweep = items.DbSweep();
            if sweep.running then
                local pct = math.floor((sweep.nextId / sweep.maxId) * 100);
                imgui.Text(string.format('Reading item list... %d%%', pct));
            end
            source = sweep.results or {};
        end

        local matches, nameHit = M.FilterAndSort(source, state);
        local needle = string.lower(state.search[1] or '');

        -- Named by direction: a control reading Lvl would look like the level filter above it.
        local SORTS = {
            { mode = 2, label = 'Hi-Lo' },
            { mode = 3, label = 'Lo-Hi' },
            { mode = 1, label = 'A-Z' },
            { mode = 4, label = 'Z-A' },
        };
        local sortLabel = 'A-Z';
        local widestSort = 0;
        for _, o in ipairs(SORTS) do
            if (o.mode == state.sortMode) then
                sortLabel = o.label;
            end
            local w = imgui.CalcTextSize(o.label);
            if (w > widestSort) then
                widestSort = w;
            end
        end
        -- Measured off the widest label plus the arrow; 66 cut Hi-Lo down to Hi-L. The 10 is
        -- the frame padding either side.
        local SORT_W = widestSort + imgui.GetFrameHeight() + 10;
        local rowLeft = imgui.GetCursorScreenPos();
        imgui.AlignTextToFramePadding();
        if (#matches == 0) then
            imgui.TextDisabled('0 items');
        else
            imgui.TextDisabled(string.format('%d item%s', #matches, (#matches == 1) and '' or 's'));
        end
        imgui.SameLine();
        imgui.SetNextItemWidth(SORT_W);
        if imgui.BeginCombo('##lsvsort', sortLabel, 0) then
            for _, o in ipairs(SORTS) do
                if imgui.Selectable(o.label, state.sortMode == o.mode, 0) then
                    SetSort(o.mode);
                end
            end
            imgui.EndCombo();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('How to sort the list.');
        end
        -- Takes what the row has left; below a readable width it drops to a row of its own.
        imgui.SameLine();
        local searchW = (rowLeft + panelW) - imgui.GetCursorScreenPos();
        if (searchW < SEARCH_MIN) then
            imgui.NewLine();
            searchW = panelW;
        end
        imgui.SetNextItemWidth(searchW);
        imgui.InputTextWithHint('##lsvsearch', 'Search a name or a stat', state.search, 64);

        imgui.BeginChild('##lsvpickerlist', { 0, 0 }, 0);
        local shownRecent = {};
        if (state.mode == 1) and (#needle == 0) then
            for _, rname in ipairs(state.recent) do
                if M.RecentFits(rname, state) then
                    shownRecent[#shownRecent + 1] = rname;
                end
            end
        end
        if (#shownRecent > 0) then
            -- A drawn arrow, as in the bag chooser. The label toggles too, since a 13px arrow
            -- is a small target.
            local function ToggleRecent()
                state.recentOpen = not state.recentOpen;
                if (state.config ~= nil) and (state.config.picker_recent_open ~= nil) then
                    state.config.picker_recent_open[1] = state.recentOpen;
                end
            end

            if imgui.ArrowButton('##lsvrecentopen',
                state.recentOpen and ImGuiDir_Down or ImGuiDir_Right) then
                ToggleRecent();
            end
            imgui.SameLine(0, 4);
            imgui.AlignTextToFramePadding();
            -- The count only shows collapsed, where it is the only clue to what is hidden.
            if state.recentOpen then
                imgui.TextDisabled('Recent Picks');
            else
                imgui.TextDisabled(string.format('Recent Picks (%d)', #shownRecent));
            end
            if imgui.IsItemClicked(0) then
                ToggleRecent();
            end
            if imgui.IsItemHovered() then
                -- Assembled first: the signature lint only checks calls that fit on one line.
                local help = 'Your last ' .. RECENT_CAP
                    .. ' things you picked.\nOnly the ones that fit this slot show.';
                imgui.SetTooltip(help);
            end

            -- Nothing to separate when collapsed.
            if state.recentOpen then
                for ri, rname in ipairs(shownRecent) do
                    local rid = items.ResolveItemId(rname);
                    if (rid ~= nil) then
                        items.RequestIcon(rid);
                        -- The level too, or the same piece reads differently here than in the
                        -- list below.
                        local rinfo = items.GetItemInfo(rid);
                        local rrow = { id = rid, name = rname,
                            level = rinfo and rinfo.level or nil,
                            ilvl = rinfo and rinfo.ilvl or nil };
                        -- Its own id scope: a recent pick is usually still in the list below,
                        -- and two visible widgets sharing one id gets a red box.
                        -- Dimmer than the list under it.
                        imgui.PushID('recent');
                        imgui.PushStyleColor(ImGuiCol_Text, theme.col.textDim);
                        local pickedRecent = DrawRow(rrow, state.mode == 2, nil, true);
                        imgui.PopStyleColor();
                        imgui.PopID();
                        if pickedRecent then
                            DoPick(rname);
                        end
                    else
                        if imgui.Selectable(rname .. '##recent' .. ri, false, 0) then
                            DoPick(rname);
                        end
                    end
                end
                imgui.Separator();
            end
        end

        if (#matches == 0) then
            -- Reported above the box, so nothing is drawn in it.
        elseif (#matches > SHOW_LIMIT) then
            imgui.TextDisabled('Too many to list. Type to narrow the list.');
        else
            for _, row in ipairs(matches) do
                items.RequestIcon(row.id);
                if DrawRow(row, state.mode == 2, needle) then
                    DoPick(row.name);
                end
            end
        end
        imgui.EndChild();
end

-- Drawn under the gear grid beside the slot it acts on. btnW is the grid's own cell size.
M.DrawSlotActions = function(btnW)
    if (not state.open) then
        return;
    end
    imgui.SetCursorPosY(imgui.GetCursorPosY() + theme.ROW_GAP);
    btnW = btnW or math.max(64, (imgui.GetContentRegionAvail() - 24) / 4);
    -- Displace rather than Displaced: every button here is an instruction; the grid shows the
    -- written keyword. There is no Done: the panel is always aimed at some slot.
    if imgui.Button('Clear', { btnW, 0 }) then
        if (state.onClear ~= nil) then
            state.onClear();
        end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Takes this slot out of the set.\nAnother rule may then fill it.');
    end
    imgui.SameLine();
    if imgui.Button('Displace', { btnW, 0 }) then
        DoPick('Displaced');
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('For a slot another piece empties,\nlike ammo when an instrument goes on.');
    end
    imgui.SameLine();
    if imgui.Button('Ignore', { btnW, 0 }) then
        DoPick('Ignore');
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Leaves it alone. What you wear stays.\nUse this rather than disabling a slot.');
    end
    imgui.SameLine();
    if imgui.Button('Unequip', { btnW, 0 }) then
        DoPick('Remove');
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Takes it off, puts nothing back.');
    end
end

M.DrawPanel = function()
    if (not state.open) then
        imgui.Dummy({ 0, 8 });
        if (imgui.GetContentRegionAvail() >= 180) then
            imgui.TextColored(theme.col.textDim, 'Click a slot to change it.');
            imgui.TextColored(theme.col.textFaint, 'Drag equipment between slots');
            imgui.TextColored(theme.col.textFaint, 'or out of the list.');
        end
        return;
    end

    -- No AlignTextToFramePadding and no Spacing: nothing on this line is a widget.
    imgui.Text('Slot:');
    imgui.SameLine();
    -- Green matches the border round that slot on the grid.
    imgui.TextColored(theme.col.accent, tostring(state.slotName));

    DrawBagMode();
    DrawFiltersAndResults();
end

return M;
