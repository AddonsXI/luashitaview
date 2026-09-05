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
* The item picker: search your bags or the whole item database, and pick a slot.
*
* Your bags are scanned live. The all-items mode sweeps the game's item database once,
* locally, reading data the client already holds. Nothing is ever sent to the server.
*
* The job filter defaults to the job the open profile is for, taken from its filename,
* which is reliable because that is how LuAshitacast decides which profile to load.
--]]

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
    -- Fixed on. Gear that cannot go in the slot you are filling was never an
    -- answer, so the control that turned this off only ever made the list worse.
    slotFilter = { true },

    -- 0 means every job. Anything else is a job id, tested as a bit against the mask.
    jobFilter = 0,

    -- The job the open profile is for, so the filter can default to it.
    profileJob = nil,

    -- The number the level box holds. 0 means show every level.
    levelFilter = { 0 },

    -- 1 treats that number as a ceiling, 2 as a floor for narrowing to endgame gear.
    levelMode = 1,

    -- 1 alphabetical, 2 by level. Level by default, since the highest you can wear is
    -- usually what you are reaching for.
    sortMode = 2,
    inventory = nil,
    owned = nil,

    -- Whether Recent Picks is expanded. Remembered between sessions.
    recentOpen = true,

    -- The last few things picked, newest first, capped at RECENT_CAP.
    recent = {},
};

-- Every container Your bags can read, in the order the game shows them. Wardrobe 5 to 8
-- are ids 13 to 16; see the note on BagChoices in grid.lua for why they matter.
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

-- Ears and rings share one mask each, because either of the pair takes the item. The
-- name is lowercased once and every test made against that, so a caller passing 'ring1'
-- gets the shared mask rather than a single slot's.
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

--[[
* Whether a recent pick belongs in the list for the slot being edited. Recents are drawn
* above the filtered list from a loop of their own, so without this they ignore the slot
* rule entirely and will happily offer a body piece for a hands slot.
--]]
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
    -- A name nothing resolves stays offered, the same as in the main list: refusing what
    -- cannot be checked would hide gear the database simply lacks.
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

--[[
* Keyed by lowercased name rather than by id, because a name is what a profile
* holds, and the same piece can carry more than one id.
--]]
M.IsFavorite = function(favorites, name)
    if (favorites == nil) or (name == nil) then
        return false;
    end
    return favorites[string.lower(name)] == true;
end

M.IsStarred = function(name)
    return M.IsFavorite(state.favorites, name);
end

--[[
* The number to judge a piece by when narrowing to endgame gear.
*
* Retail gear past the level cap stops climbing in equip level and climbs in item level
* instead, so a level 99 character wears item level 119 pieces that all read 99. But
* accessories never carry an item level at all, so anything without one has to fall back
* to its equip level or a minimum would hide every ring, earring, neck and waist.
--]]
M.EffectiveLevel = function(row)
    local ilvl = row.ilvl or 0;
    if (ilvl > 0) then
        return ilvl;
    end
    return row.level or 0;
end

--[[
* Which of two rows sharing a name should be the one shown.
*
* Owned beats unowned, because the stage you hold is the stage LuAshitacast will equip
* and its stats are therefore the true ones. Among equals the higher id wins: an upgrade
* ladder runs upward through the item table, so the last rung is the finished weapon.
--]]
local function Better(a, b)
    local ao = (a.count or 0) > 0;
    local bo = (b.count or 0) > 0;
    if (ao ~= bo) then
        return ao;
    end
    return (a.id or 0) > (b.id or 0);
end

--[[
* Which rows to show and in what order. A name match outranks a stat match whatever the
* sort says: searching a stat reads the whole description, and anything named for the
* word is what you meant far more often than anything merely describing it.
--]]
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
        -- A favorite never overrides a filter; it only ranks. Every filter here is
        -- something the user set on purpose.
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

    --[[
    * One row per name, because a profile stores a piece by NAME and nothing else.
    *
    * FFXI carries a separate item id for every upgrade stage of a relic, mythic or
    * empyrean, all sharing one name. Burtgang exists eleven times and Excalibur ten,
    * and across the client's whole table 139 names are shared by 712 ids. Listed
    * separately they read as a choice between different pieces, and they are not:
    * picking any of them writes the identical line into the file.
    *
    * The survivor is the one you own, and the highest id otherwise.
    *
    * Measured off the client data rather than assumed: the stages form a strict ladder,
    * Burtgang running DMG 46 to 165 and Enmity nothing to +23, so the last id is the
    * finished weapon. Upgrading trades the old one in, so you hold one at a time, and
    * LuAshitacast matches by name against your bags rather than by id, so the stage you
    * own is the stage that equips. Owning one therefore makes its stats the true ones,
    * and owning none means you are browsing, where the name means the finished article.
    *
    * Counts are summed onto a copy rather than the cached row, since summing into the
    * source would grow it again on every frame.
    --]]
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

    --[[
    * One comparator for all four orders. A name match still outranks a stat match, and
    * a favorite still outranks the rest, whichever direction is chosen: reversing the
    * sort must not bury the row you searched for at the bottom.
    *
    * Levels compare on the effective level, so retail item level gear orders correctly
    * rather than every endgame piece tying at 99.
    --]]
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
            -- Ties fall back to the name, always the same way, so the order does not
            -- shuffle between frames.
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

-- Enforced here rather than where the list is drawn, so the stored list can never
-- grow unbounded. Fewer can SHOW, because RecentFits drops anything that cannot go
-- in the slot being edited.
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

--[[
* Picking fills the slot and leaves the panel exactly as it was.
*
* It used to close the picker outright, which meant the next slot reopened it
* with an empty search box, so filling a set from one stat search meant typing
* that search again for every slot. Nothing about choosing an item is a reason
* to throw the search away, so Done is the only thing that closes it.
--]]
local function DoPick(name)
    RememberPick(name);
    if (state.onPick ~= nil) then
        state.onPick(name);
    end
end

--[[
* The containers Your bags searches, as the list ScanInventory wants. Anything the
* character does not have is dropped, so a bag that was switched off and later lost, or
* one that lapsed with a subscription, cannot keep excluding itself invisibly.
*
* Returns nil, meaning every bag, when nothing has been switched off. That keeps the
* default identical to the behavior before bag picking existed.
--]]
M.SearchContainers = function()
    local available = items.AvailableBags();
    if (available == nil) or (state.bagPick == nil) then
        return nil;
    end
    local out = {};
    for id = 0, 16 do
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

--[[
* The label on the bags radio. It doubles as the only indication that bags have been
* switched off, so it has to answer that without a second control saying so.
--]]
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

--[[
* Re-aims the picker at a slot. The search text and every filter are left alone
* on purpose: only which slot is being edited changes, and the slot mask
* follows that on its own. Clearing the search here is what made picking feel
* like the panel had reset itself.
--]]
--[[
* inSlot is a FUNCTION returning the names the slot currently holds, not a list.
* The slot changes while the panel is open, so a snapshot taken here would say the
* piece you just added is not in it.
--]]
M.Open = function(slotName, currentName, onPick, onClear, inSlot)
    state.open = true;
    state.slotName = slotName;
    state.onPick = onPick;
    state.onClear = onClear;
    state.inSlot = inSlot;
    M.RescanBags();
    items.Dbg('Picker found ' .. tostring(slotName) .. ': ' .. #state.inventory .. ' owned equippable items across your bags.');
end

-- Test seams, and the only reader is picker-test. The pure helpers already take
-- a state table as an argument; these hand over the real one, and a way to pick
-- without a mouse, so the suite can pin what Open and DoPick leave alone.
--[[
* The slot the panel is editing, or nil when it is showing nothing. The grid marks
* this one, so the border cannot be left behind on a slot nobody is looking at.
--]]
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

    -- The earned level in the profile's job, so editing a PLD file while synced down on
    -- another job still shows the PLD gear you own.
    -- 119 is the last resort rather than 0, since the box now holds 1 to 119 and 119
    -- with Max is the position that hides nothing.
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

-- The icon on a picker row, and what the star beside it centers against.
local ROW_ICON = 16;

-- Below this the search box is too narrow to read what you typed, so it takes a
-- row of its own instead of sharing one with the count and the sort.
local SEARCH_MIN = 120;

-- ImGui's own horizontal item spacing, which the row widths have to account for.
local ITEM_GAP = 8;

local function DrawRow(row, showOwned, needle, noInSlot)
    --[[
    * The star is the whole favorite control: lit when on, faint when off, and it
    * sits before the icon so every row reads the same width.
    --]]
    --[[
    * The character on its own, with no button behind it. A framed button here was
    * taller than the icon beside it, which is what pulled the row out of line.
    *
    * Dropped to the middle of the icon it sits beside. A line of text is shorter
    * than the icon, so left alone it rides along the top of the row.
    --]]
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
    -- The number shown is the one Max and Min compare against, so a piece appearing or
    -- vanishing can be read straight off the row. An item level is prefixed i, which is
    -- how retail writes it, and nothing on a 75 era server ever has one.
    local label = row.name;
    local badge = items.LevelBadge(row);
    if (badge ~= nil) then
        label = string.format('[%s] %s', badge, row.name);
    end
    if (row.count ~= nil) and (row.count > 1) then
        label = label .. ' x' .. row.count;
    end
    -- Never seen in a bag, only decoded off a Storage Slip's Extra bytes; said plainly
    -- so it doesn't read as loose gear sitting in a container.
    if row.onSlip then
        label = label .. ' (on slip)';
    end
    local flags = 0;
    local clicked;
    --[[
    * Already in this slot reads as selected, which is what it is. Every entry of
    * a priority list is marked, so a long list says at a glance what is in it.
    *
    * Green text is a different thing: that one means you own it.
    --]]
    --[[
    * Recent Picks turns this off. The piece you just clicked is in the slot by
    * definition, so marking it there says nothing and reads as odd the moment you
    * click. Green in that list is left to mean the one thing it is worth meaning:
    * that you own it.
    --]]
    local here = (not noInSlot) and (state.present ~= nil)
        and (state.present[string.lower(row.name or '')] == true);
    if here then
        imgui.PushStyleColor(ImGuiCol_Header, theme.col.accentBg);
    end
    -- Green means you have it, which is the thing this list is asked most often.
    if showOwned and state.ownedNames
        and state.ownedNames[string.lower(row.name or '')] then
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.accent);
        clicked = imgui.Selectable(label .. '##item' .. row.id, here, flags);
        imgui.PopStyleColor();
    else
        clicked = imgui.Selectable(label .. '##item' .. row.id, here, flags);
    end
    if here then
        imgui.PopStyleColor();
    end

    -- Dragging a row is how gear reaches a slot other than the one already open. It is
    -- recorded rather than acted on: picker cannot see the editing state without a
    -- require cycle, so ui collects this after the panel draws.
    if imgui.IsItemHovered() and imgui.IsMouseDragging(0, 6.0) then
        pendingDrag = { name = row.name, id = row.id };
    end

    if imgui.IsItemHovered() then
        DrawRowTooltip(row.id);
    end

    -- When a search hit the stats rather than the name, the matching bit shows beside
    -- the row, which also makes a penalty like STR-7 obvious instead of a surprise.
    if (needle ~= nil) and (#needle > 0) then
        local hit = items.MatchedStat(items.GetItemInfo(row.id), needle);
        if (hit ~= nil) then
            imgui.SameLine();
            imgui.TextColored(theme.col.textDim, hit);
        end
    end

    return clicked;
end

--[[
* Which bags to search, as a pair of radio buttons and the chooser behind
* the left one. The label doubles as the button, so the state and the way to
* change it are the same control.
--]]
local function DrawBagMode()
        -- The label carries the state and opens the chooser, so switching bags off needs
        -- no second control and shows up in the one place you already look.
        -- Three hashes: the visible half changes, and with two the id would change with
        -- it and the popup would lose its anchor.
        if imgui.RadioButton(M.BagsLabel() .. '###lsvbagsmode', state.mode == 1) then
            if (state.mode == 1) then
                imgui.OpenPopup('##lsvbags');
            end
            state.mode = 1;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Click again to choose bags.');
        end
        -- The chevron is the only thing saying the label opens anything. A drawn arrow
        -- rather than a typed one, because the font is the game's and not ours.
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

        -- Useful for a wardrobe holding lockstyle gear, or one that lapsed with a
        -- subscription and still lists items that cannot be equipped.
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

--[[
* The level, job and sort filters, the search box, and the list of matches
* under them. One function because the search box is measured against where
* the filter row started, so the two cannot be separated.
--]]
local function DrawFiltersAndResults()
    --[[
    * Once a frame rather than once a row: the slot is asked for its names, and every
    * row then just looks itself up.
    *
    * Owning a piece is asked the same way the gear grid asks it, by name and across
    * every container. It used to read the bag scan the results come from, which is
    * only the bags you have ticked, so unticking a wardrobe made everything in it
    * stop counting as owned here while the grid still counted it. Two panels, one
    * piece, two answers.
    --]]
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
        --[[
        * The panel's inner width, taken once. Every row below is sized against it
        * rather than against whatever the row above happened to measure, which is
        * what left the search inheriting the filter row's width and going tiny on a
        * narrow panel.
        --]]
        local panelW = imgui.GetContentRegionAvail();

        -- A dropdown rather than a button that swaps its own text. As a button it
        -- worked and nobody could tell it was clickable; its two neighbours in this
        -- row are dropdowns, so this reads as one without having to be discovered.
        local function SetLevelMode(mode)
            state.levelMode = mode;
            if (state.config ~= nil) and (state.config.picker_levelmode ~= nil) then
                state.config.picker_levelmode[1] = mode;
            end
        end
        local jobs = items.JobList();
        local mine = items.GetMainJob();
        -- The star marks your own job in the list, where it saves hunting for it. On
        -- the closed control it would be telling you something you already know.
        local label = 'Any';
        for _, j in ipairs(jobs) do
            if (j.id == state.jobFilter) then
                label = j.abbr;
            end
        end

        -- Labelled to pair with Lvl beside it, so the row reads as two named
        -- filters rather than one bare dropdown and one labelled pair.
        --[[
        * Job, the level and its bound share whatever the row has left after the two
        * labels, so the row ends level with the one under it. Their old fixed widths
        * left the row short of the panel edge by however wide the panel was.
        *
        * Split in the proportion they had, so the level box stays the narrow one.
        --]]
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
        --[[
        * The number leads and the bound follows, so it reads as what it means:
        * level 75 max. The two touch so they read as one control.
        --]]
        imgui.AlignTextToFramePadding();
        imgui.TextDisabled('Lvl');
        imgui.SameLine();

        imgui.SetNextItemWidth(lvlW);
        imgui.InputInt('##lsvlevel', state.levelFilter, 0, 0);
        if imgui.IsItemHovered() then
            imgui.SetTooltip('The level for Max or Min.');
        end
        --[[
        * Equip levels run 1 to 99 and item levels 100 to 119, so the whole range any
        * item can sit at is 1 to 119. Nothing is lost at the top, where a bigger number
        * in Max matches the same equipment and in Min matches none, and 119 with Max is
        * still the position that hides nothing.
        --]]
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

        --[[
        * The count and the sort describe the same thing, the list under them, so
        * they share a row and sit together. Pinned to the right edge they read as
        * two unrelated controls with a gap between them.
        --]]
        -- Named by direction rather than by field: a control reading Lvl would look
        -- like the level filter above it. Level order first, because that is what the
        -- list is usually narrowed by and it is the default.
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
        --[[
        * Measured off the widest label plus the arrow, rather than pinned at a number.
        * It was 66, which cut Hi-Lo down to Hi-L, and the search beside it takes
        * whatever the row has left: a fixed width here spends the row's space on the
        * control that needs it least. The 10 is the frame padding either side.
        --]]
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
        --[[
        * The search shares the row with the count and the sort, because all three
        * are about the list underneath rather than about the filters above. It takes
        * what the row has left, so this row and the filters above it both end at the
        * panel edge.
        *
        * Below a readable width it drops to a row of its own rather than shrinking
        * into a box you cannot read what you typed in.
        --]]
        imgui.SameLine();
        local searchW = (rowLeft + panelW) - imgui.GetCursorScreenPos();
        if (searchW < SEARCH_MIN) then
            imgui.NewLine();
            searchW = panelW;
        end
        imgui.SetNextItemWidth(searchW);
        imgui.InputTextWithHint('##lsvsearch', 'Search a name or a stat', state.search, 64);

        -- Two footer rows, reserved at the with-spacing height so the trailing gap
        -- of each row is counted; one short and this child overflows its panel.
        -- The whole column. The slot buttons live under the gear grid now, so
        -- nothing needs reserving at the bottom.
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
            --[[
            * A drawn arrow rather than a typed one, matching the bag chooser
            * above: the font is the game's and not ours, so a typed chevron
            * is not guaranteed to have a glyph. The label toggles too, since
            * a 13px arrow is a small thing to have to hit.
            --]]
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
            -- The count only shows when collapsed, where it is the only clue
            -- to what is hidden. Open, the list itself says it.
            if state.recentOpen then
                imgui.TextDisabled('Recent Picks');
            else
                imgui.TextDisabled(string.format('Recent Picks (%d)', #shownRecent));
            end
            if imgui.IsItemClicked(0) then
                ToggleRecent();
            end
            if imgui.IsItemHovered() then
                -- Built from the constant, so the number cannot drift from the
                -- cap. Assembled first because the signature lint only checks
                -- calls that fit on one line.
                local help = 'Your last ' .. RECENT_CAP
                    .. ' things you picked.\nOnly the ones that fit this slot show.';
                imgui.SetTooltip(help);
            end

            -- The rule under it separates the recents from the search results,
            -- so collapsed there is nothing for it to separate.
            if state.recentOpen then
                for ri, rname in ipairs(shownRecent) do
                    local rid = items.ResolveItemId(rname);
                    if (rid ~= nil) then
                        items.RequestIcon(rid);
                        -- The level too, or the same piece reads differently here
                        -- than it does in the list a few rows down.
                        local rinfo = items.GetItemInfo(rid);
                        local rrow = { id = rid, name = rname,
                            level = rinfo and rinfo.level or nil,
                            ilvl = rinfo and rinfo.ilvl or nil };
                        --[[
                        * Its own id scope. The row's widget id is built from the
                        * item id, and a recent pick is usually still in the list
                        * below, so without this the same piece is two visible
                        * widgets sharing one id and ImGui says so in a red box.
                        --]]
                        -- Dimmer than the list under it, so the recent rows read
                        -- as a shortcut rather than as more results.
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

--[[
* The four things you can do to a slot other than pick gear for it. Sized
* from the panel so all four fit on one row at any width.
--]]
--[[
* The four things you can do to a slot other than pick gear for it. Drawn under the
* gear grid rather than in this panel, so it sits beside the slot it acts on and
* stays put whatever the panel underneath is showing.
*
* btnW comes from the grid's own cell size, so each button lands under one column.
--]]
M.DrawSlotActions = function(btnW)
    if (not state.open) then
        return;
    end
    imgui.SetCursorPosY(imgui.GetCursorPosY() + theme.ROW_GAP);
    btnW = btnW or math.max(64, (imgui.GetContentRegionAvail() - 24) / 4);
    --[[
    * Four verbs, one row. Clear Slot leads because it is the one people reach
    * for most, and it used to sit under Remove, which means the opposite thing.
    *
    * Displace rather than Displaced: every button here is an instruction. The
    * grid still shows the written keyword, which is Displaced.
    *
    * There is no Done. The panel is always aimed at some slot, so closing it
    * only ever emptied the column for no gain.
    --]]
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
        -- A set now opens with its first slot picked, so this is a rare state rather
        -- than the one people land in. It says the two things and stops.
        if (imgui.GetContentRegionAvail() >= 180) then
            imgui.TextColored(theme.col.textDim, 'Click a slot to change it.');
            imgui.TextColored(theme.col.textFaint, 'Drag equipment between slots');
            imgui.TextColored(theme.col.textFaint, 'or out of the list.');
        end
        return;
    end

    -- No AlignTextToFramePadding and no Spacing under it: nothing on this line is
    -- a widget, so both were padding the panel away from its own title.
    imgui.Text('Slot:');
    imgui.SameLine();
    -- Green matches the border round that slot on the grid.
    imgui.TextColored(theme.col.accent, tostring(state.slotName));

    DrawBagMode();
    DrawFiltersAndResults();
end

return M;
