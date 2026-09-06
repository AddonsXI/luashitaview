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


local imgui = require('imgui');
local compat = require('compat');
local theme = require('theme');
local prof = require('profile');
local items = require('items');
local picker = require('picker');
local us = require('uistate');

local rules = require('rules');
local writer = require('writer');

local S = us.S;
local Status = us.Status;
local PushUndo, MarkDirty = us.PushUndo, us.MarkDirty;
local FirstEntry, EntryLabel = us.FirstEntry, us.EntryLabel;
local ResolveEntryId, WinningEntry = us.ResolveEntryId, us.WinningEntry;

local M = {};

local FIELD_W = 50;
local BUTTON_W = 110;

local CHAIN_NAME_MIN = 150;
local CHAIN_NAME_PAD = 16;

local ROW_ICON = 16;
local ROW_INDENT = 12;
local UNOWNED_ROWS = 8;
local TREE_INDENT = 16;
local CORNER_TEXT_Y = 17;
local RAW_PREVIEW_MAX = 200;
local LABEL_PAD = 12;


-- equip.lua resolves a STRING through gData.Constants.Containers, which stops at Wardrobe4, so
-- 'Wardrobe5' quietly means any bag. Wardrobe 5 to 8 are reachable only as the numbers 13 to
-- 16, so the last four carry a number.
local BagChoices = {
    { label = '(any)', value = nil },
    { label = 'Inventory', value = 'Inventory', id = 0 },
    { label = 'Safe', value = 'Safe', id = 1 },
    { label = 'Storage', value = 'Storage', id = 2 },
    { label = 'Temporary', value = 'Temporary', id = 3 },
    { label = 'Locker', value = 'Locker', id = 4 },
    { label = 'Satchel', value = 'Satchel', id = 5 },
    { label = 'Sack', value = 'Sack', id = 6 },
    { label = 'Case', value = 'Case', id = 7 },
    { label = 'Wardrobe', value = 'Wardrobe', id = 8 },
    { label = 'Safe2', value = 'Safe2', id = 9 },
    { label = 'Wardrobe2', value = 'Wardrobe2', id = 10 },
    { label = 'Wardrobe3', value = 'Wardrobe3', id = 11 },
    { label = 'Wardrobe4', value = 'Wardrobe4', id = 12 },
    { label = 'Wardrobe5', value = 13, id = 13 },
    { label = 'Wardrobe6', value = 14, id = 14 },
    { label = 'Wardrobe7', value = 15, id = 15 },
    { label = 'Wardrobe8', value = 16, id = 16 },
};

-- Built per entry so whatever the slot already holds is in it; an unrecognized value is
-- preserved verbatim with its type.
-- available nil enables everything. The entry's own bag is always enabled, so the file's value
-- stays selectable.
local function BagOptionsFor(entry, available)
    local labels, values, enabled = {}, {}, {};
    -- values[1] is a real nil: applying '(any)' has to clear the field, and Bag='' would not.
    for i, choice in ipairs(BagChoices) do
        labels[i] = choice.label;
        values[i] = choice.value;
        enabled[i] = (available == nil) or (choice.id == nil) or (available[choice.id] == true);
    end

    local bag = entry and entry.bag;
    if (bag == nil) then
        return labels, values, 1, enabled;
    end

    -- Matched against the value, so a numeric 13 selects Wardrobe5.
    for i, choice in ipairs(BagChoices) do
        if (choice.value ~= nil) and (choice.value == bag) then
            enabled[i] = true;
            return labels, values, i, enabled;
        end
    end

    local extra = #labels + 1;
    labels[extra] = tostring(bag) .. ' (kept as written)';
    values[extra] = bag;
    enabled[extra] = true;
    return labels, values, extra, enabled;
end

-- Exported for the suite.
M.BagOptionsFor = BagOptionsFor;

local SentinelHelp = {
    remove = 'Takes it off, puts nothing back.',
    displaced = 'For a slot another piece empties,\nlike ammo when an instrument goes on.',
    ignore = 'Leaves it alone. What you wear stays.\nUse this rather than disabling a slot.',
};

local function EntryTooltipLines(entry, lines)
    table.insert(lines, entry.name or '(unnamed)');
    if entry.sentinel then
        lines[#lines] = lines[#lines] .. ' (' .. entry.sentinel .. ')';
    end
    if (entry.augment ~= nil) then
        if (type(entry.augment) == 'string') then
            table.insert(lines, '  ' .. entry.augment);
        else
            for _, a in ipairs(entry.augment) do
                table.insert(lines, '  ' .. a);
            end
        end
    end
    if (entry.augPath ~= nil) then
        table.insert(lines, '  Path ' .. tostring(entry.augPath));
    end
    if (entry.level ~= nil) then
        table.insert(lines, '  Level ' .. tostring(entry.level));
    end
    if (entry.bag ~= nil) then
        table.insert(lines, '  Bag ' .. tostring(entry.bag));
    end
    if (entry.priority ~= nil) then
        table.insert(lines, '  Priority ' .. tostring(entry.priority));
    end
end

-- Clearing an empty slot burns no undo step and lights nothing.
local function ClearSlot(setModel, slotName)
    if (setModel.slots[slotName] == nil) then
        return;
    end
    PushUndo();
    setModel.slots[slotName] = nil;
    MarkDirty(setModel);
end

-- Clicking a slot that holds a list opens the list, not the picker: the picker's
-- callback replaces the whole slot, which would throw the other entries away.
M.ClickOpensList = function(slotValue)
    return (slotValue ~= nil) and (slotValue.kind == 'chain');
end

-- Augments count as one however many lines they run to.
M.CountDetailFields = function(entry)
    if (entry == nil) then
        return 0;
    end
    -- Counted one by one: ipairs stops at the first nil, and nil is the normal state here.
    local n = 0;
    if (entry.augment ~= nil) then n = n + 1; end
    if (entry.augPath ~= nil) then n = n + 1; end
    if (entry.augRank ~= nil) then n = n + 1; end
    if (entry.augTrial ~= nil) then n = n + 1; end
    if (entry.bag ~= nil) then n = n + 1; end
    if (entry.priority ~= nil) then n = n + 1; end
    if (entry.quantity ~= nil) then n = n + 1; end
    return n;
end

-- The form is addressed by position, so reordering around it would leave it editing a different
-- piece.
M.FollowSwap = function(sel, slotName, from, to)
    if (sel == nil) or (sel.slot ~= slotName) then
        return sel;
    end
    if (sel.index == from) then
        sel.index = to;
    elseif (sel.index == to) then
        sel.index = from;
    end
    return sel;
end

M.SlotHasAugments = function(slotValue)
    if (slotValue == nil) then
        return false;
    end
    local function HasAug(e)
        return (e ~= nil) and ((e.augment ~= nil) or (e.augPath ~= nil)
            or (e.augRank ~= nil) or (e.augTrial ~= nil));
    end
    if (slotValue.kind == 'item') then
        return HasAug(slotValue.item);
    end
    if (slotValue.kind == 'chain') then
        for _, e in ipairs(slotValue.entries or {}) do
            if HasAug(e) then
                return true;
            end
        end
    end
    return false;
end

-- The slot is looked up again when the pick arrives: an undo or a reopened profile in between
-- would otherwise append into a table the model no longer holds.
-- Case insensitive. A repeat can never be reached: the list picks the first entry you can wear.
local function ListNames(entries, itemName)
    local want = string.lower(itemName or '');
    for _, e in ipairs(entries or {}) do
        if (e.name ~= nil) and (string.lower(e.name) == want) then
            return true;
        end
    end
    return false;
end

-- A function, so the picker sees the piece you just added.
local function SlotNamesNow(setModel, slotName)
    return function()
        local v = setModel.slots[slotName];
        local out = {};
        if (v == nil) then
            return out;
        end
        if (v.kind == 'chain') then
            for _, e in ipairs(v.entries or {}) do
                out[#out + 1] = e.name;
            end
        elseif (v.kind == 'item') and (v.item ~= nil) then
            out[1] = v.item.name;
        end
        return out;
    end
end

-- A pick is ADDED to the slot's list. Clear still means the slot leaves the set.
local function OpenPickerToAppend(setModel, slotName)
    picker.Open(slotName, '', function(pickedName)
        local target = setModel.slots[slotName];
        if (target == nil) or (target.kind ~= 'chain') then
            return;
        end
        if ListNames(target.entries, pickedName) then
            Status(pickedName .. ' is already in this list', 'info');
            return;
        end
        PushUndo();
        table.insert(target.entries, 1, { name = pickedName });
        MarkDirty(setModel);
    end, function()
        ClearSlot(setModel, slotName);
    end, SlotNamesNow(setModel, slotName));
end

local function SetSlotItem(setModel, slotName, itemName)
    if prof.IsPlainItemNamed(setModel.slots[slotName], itemName) then
        return;
    end
    PushUndo();
    setModel.slots[slotName] = { kind = 'item', item = { name = itemName } };
    if prof.Sentinels[string.lower(itemName)] then
        setModel.slots[slotName].item.sentinel = string.lower(itemName);
    end
    MarkDirty(setModel);
end

local function CellText(dl, minX, minY, cell, color, text)
    local tw, th = imgui.CalcTextSize(text);
    dl:AddText({ minX + ((cell - tw) / 2), minY + ((cell - th) / 2) }, color, text);
end

-- Icons are 32 pixels square in the game's data; an exact multiple keeps every source pixel on
-- a clean block.
local ICON_NATIVE = 32;

-- The slot buttons under the grid are sized from this.
local CELL_PAD = 6;
local CELL = (ICON_NATIVE * 2) + (CELL_PAD * 2);
M.CellSize = function()
    return CELL;
end

-- Four cells with ImGui's 8 between them; anything lining up under the grid measures from here.
local GRID_W = (CELL * 4) + (8 * 3);

-- A chip's text plus the small button padding, used only to decide whether the next one fits.
local CHIP_PAD = theme.SMALL_BUTTON_PAD;
local CHIP_GAP = 6;

-- One chip is one item, so nothing wraps; the caller carries the full name in the tooltip.
-- limit and measure are arguments so the rule tests without ImGui.
local ELLIPSIS = '...';
local function FitLabel(prefix, name, pad, limit, measure)
    measure = measure or imgui.CalcTextSize;
    limit = limit or GRID_W;
    pad = pad or CHIP_PAD;
    local full = prefix .. name;
    if ((measure(full) + pad) <= limit) then
        return full;
    end
    local kept = name;
    while (#kept > 0)
        and ((measure(prefix .. kept .. ELLIPSIS) + pad) > limit) do
        kept = string.sub(kept, 1, #kept - 1);
    end
    return prefix .. kept .. ELLIPSIS;
end
M.GridWidth = function()
    return GRID_W;
end

-- In a _Priority set every slot is a list, so a single piece shows as a list of one. NOT marked
-- dirty: a one entry list means what the single item meant.
local function AsListIfPriority(setModel, slotName)
    local held = setModel.slots[slotName];
    if setModel.isPriority and (held ~= nil) and (held.kind == 'item')
        and (not held.locked) and (held.item ~= nil) and (not held.item.sentinel) then
        setModel.slots[slotName] = { kind = 'chain', entries = { held.item } };
    end
end

local function OpenSlot(setModel, slotName)
    AsListIfPriority(setModel, slotName);
    local slotValue = setModel.slots[slotName];
    local isOpaque = (slotValue ~= nil)
        and ((slotValue.kind == 'opaque') or (slotValue.locked == true));
    if isOpaque then
        -- Nothing to pick: the panel says why the slot is locked and offers the one thing
        -- allowed.
        S.detailSel = slotName;
        S.detailTarget = nil;
    elseif M.ClickOpensList(slotValue) then
        -- The list shows what is there; the picker adds to it.
        S.detailSel = slotName;
        S.detailTarget = nil;
        OpenPickerToAppend(setModel, slotName);
    else
        if (slotValue ~= nil) and (slotValue.kind == 'item') and (not slotValue.locked) then
            S.detailSel = slotName;
            S.detailTarget = nil;
        end
        local current = FirstEntry(slotValue);
        picker.Open(slotName, current and current.name or '', function(pickedName)
            SetSlotItem(setModel, slotName, pickedName);
        end, function()
            ClearSlot(setModel, slotName);
        end, SlotNamesNow(setModel, slotName));
    end
end
M.OpenSlot = OpenSlot;

-- In a _Priority set a slot that already holds something gains the piece as another option.
-- Everything else replaces.
local function AddToSlot(setModel, slotName, itemName)
    local held = setModel.slots[slotName];
    local holdsGear = (held ~= nil)
        and (((held.kind == 'item') and (held.item ~= nil) and (not held.item.sentinel))
            or ((held.kind == 'chain') and (#held.entries > 0)));
    if (not setModel.isPriority) or (not holdsGear)
        or prof.Sentinels[string.lower(itemName)] then
        SetSlotItem(setModel, slotName, itemName);
        return;
    end
    local entries = (held.kind == 'chain') and held.entries or { held.item };
    if ListNames(entries, itemName) then
        Status(itemName .. ' is already in this list', 'info');
        return;
    end
    -- At the TOP: the list wears the first entry you can use.
    PushUndo();
    local grown = { { name = itemName } };
    for _, e in ipairs(entries) do
        grown[#grown + 1] = e;
    end
    setModel.slots[slotName] = { kind = 'chain', entries = grown };
    MarkDirty(setModel);
end
M.AddToSlot = AddToSlot;
M.AsListIfPriority = AsListIfPriority;

-- Once per file, not once per cell: the test is a search through the whole file and the grid
-- asks sixteen times a frame.
local filterOnFor, filterOn = nil, false;
local function OwnedFilterOn()
    local text = (S.model ~= nil) and (S.model.textAtLoad or '') or '';
    if (filterOnFor ~= text) then
        filterOnFor = text;
        filterOn = writer.SkipsUnowned(text);
    end
    return filterOn;
end

-- With the filter in the file the game falls through to the first one you own, so a list with
-- any owned entry still swaps.
local function ChainHasOwned(slotValue, ownedNames)
    if (slotValue == nil) or (slotValue.kind ~= 'chain') then
        return false;
    end
    for _, entry in ipairs(slotValue.entries) do
        if entry.sentinel or ((entry.name ~= nil)
            and (ownedNames[string.lower(entry.name)] == true)) then
            return true;
        end
    end
    return false;
end

local function DrawSlotCell(setModel, slotName, editable, ghosts)
    local icon = ICON_NATIVE * 2;
    local pad = CELL_PAD;
    local cell = CELL;
    imgui.InvisibleButton('##cell_' .. slotName, { cell, cell });
    local hovered = imgui.IsItemHovered();
    local minX, minY = imgui.GetItemRectMin();
    local maxX, maxY = imgui.GetItemRectMax();
    local dl = imgui.GetWindowDrawList();

    local slotValue = setModel.slots[slotName];
    local ghost = (slotValue == nil) and ghosts[slotName] or nil;

    -- Opaque and locked slots are shown but never edited: writing a resolved value back
    -- would replace the profile's own code with whatever it evaluated to at load.
    local isOpaque = (slotValue ~= nil)
        and ((slotValue.kind == 'opaque') or (slotValue.locked == true));


    local bg = hovered and imgui.GetColorU32(theme.col.cellHover)
        or imgui.GetColorU32(theme.col.cellBg);
    dl:AddRectFilled({ minX, minY }, { maxX, maxY }, bg, 3.0);
    -- The slot the panel is editing, in the same green as its heading. Read from the picker: an
    -- empty slot has no detail to open, so tracking that left the border behind.
    if (picker.AimedAt() == slotName) then
        -- Half a pixel over the others: the green already says which cell.
        dl:AddRect({ minX, minY }, { maxX, maxY },
            imgui.GetColorU32(theme.col.accent), 3.0, 0, 1.5);
    else
        dl:AddRect({ minX, minY }, { maxX, maxY },
            imgui.GetColorU32(theme.col.cellBorder), 3.0, 0, 1.0);
    end

    local entry = FirstEntry(slotValue) or (ghost and FirstEntry(ghost.value));
    local tint = ghost and imgui.GetColorU32(theme.col.ghost)
        or imgui.GetColorU32({ 1.0, 1.0, 1.0, 1.0 });
    local unowned = false;
    local blocking = false;
    local covered = false;
    local slipNumber = nil;

    if (slotValue ~= nil) and (slotValue.kind == 'opaque') then
        CellText(dl, minX, minY, cell, imgui.GetColorU32(theme.col.code), '{}');
    elseif (entry == nil) or ((not entry.sentinel) and ((entry.name or '') == '')) then
        CellText(dl, minX, minY, cell, imgui.GetColorU32(theme.col.textFaint), slotName);
    elseif entry.sentinel == 'remove' then
        CellText(dl, minX, minY, cell, imgui.GetColorU32(theme.col.danger), 'X');
    elseif entry.sentinel then
        CellText(dl, minX, minY, cell, imgui.GetColorU32(theme.col.keyword), entry.sentinel);
    else
        local id = ResolveEntryId(entry);
        local ptr = (id ~= nil) and items.GetIconPtr(id) or nil;
        if (ptr ~= nil) then
            dl:AddImage(ptr, { minX + pad, minY + pad },
                { minX + pad + icon, minY + pad + icon }, { 0, 0 }, { 1, 1 }, tint);
        else
            local mark = (id == nil) and '?' or '...';
            local color = (id == nil) and imgui.GetColorU32(theme.col.caution)
                or imgui.GetColorU32(theme.col.textDim);
            CellText(dl, minX, minY, cell, color, mark);
        end
        if (id ~= nil) and (entry.name ~= nil) then
            local ownedNames = items.OwnedNames();
            local own = ownedNames[string.lower(entry.name)];
            if (own ~= true) then
                unowned = true;
                slipNumber = (type(own) == 'number') and own or nil;

                -- Green: the filter is in and the list holds something you own, so the game
                -- steps past this piece. Orange: you do not have it. Red: it is also the one
                -- the game reaches for, which kills the slot.
                local mark;
                if OwnedFilterOn() and setModel.isPriority
                    and ChainHasOwned(slotValue, ownedNames) then
                    covered = true;
                    mark = theme.col.accent;
                else
                    local winner = WinningEntry(slotValue, items.GetMainJobLevel());
                    blocking = (winner ~= nil) and (winner == entry);
                    mark = blocking and theme.col.danger or theme.col.caution;
                end
                dl:AddRectFilled({ maxX - 10, minY + 4 }, { maxX - 4, minY + 10 },
                    imgui.GetColorU32(mark), 1.0);
            end
        end
    end

    if (slotValue ~= nil) and (slotValue.kind == 'chain') and (#slotValue.entries > 1) then
        dl:AddText({ maxX - 12, maxY - CORNER_TEXT_Y }, imgui.GetColorU32(theme.col.accent),
            tostring(#slotValue.entries));
    end
    local cornerX = minX + 3;
    if (slotValue ~= nil) and (slotValue.locked == true) then
        dl:AddText({ cornerX, maxY - CORNER_TEXT_Y }, imgui.GetColorU32(theme.col.code), '{}');
        cornerX = cornerX + imgui.CalcTextSize('{}') + 3;
    end
    -- Augmented gear is otherwise indistinguishable from a plain copy of the same item.
    if M.SlotHasAugments(slotValue) then
        dl:AddText({ cornerX, maxY - CORNER_TEXT_Y }, imgui.GetColorU32(theme.col.accentDim), 'A');
    end

    if hovered then
        imgui.BeginTooltip();
        imgui.PushTextWrapPos(360);
        imgui.Text(slotName);
        if (slotValue == nil) and (ghost ~= nil) then
            imgui.TextDisabled('Inherited from ' .. ghost.from);
        end
        local shown = slotValue or (ghost and ghost.value);
        if (shown == nil) then
            imgui.TextDisabled(editable and 'Nothing here. Click to add equipment.' or 'Nothing in this slot.');
        elseif (shown.kind == 'opaque') then
            imgui.Text('Filled by code:');
            local raw = shown.raw or '(source not found)';
            if (#raw > RAW_PREVIEW_MAX) then
                raw = string.sub(raw, 1, RAW_PREVIEW_MAX) .. '...';
            end
            imgui.TextColored(theme.col.code, raw);
            imgui.TextDisabled('Save will not change it.');
        elseif (shown.kind == 'item') then
            if (not shown.item.sentinel) and ((shown.item.name or '') == '') then
                imgui.TextDisabled('Blank, so the game skips it.');
            else
                local lines = {};
                EntryTooltipLines(shown.item, lines);
                for _, l in ipairs(lines) do
                    imgui.Text(l);
                end
                if M.SlotHasAugments(slotValue) then
                    imgui.TextDisabled('The A on the cell marks these augments.');
                end
                if shown.item.sentinel then
                    imgui.TextDisabled(SentinelHelp[shown.item.sentinel] or '');
                elseif (ResolveEntryId(shown.item) == nil) then
                    imgui.TextColored(theme.col.caution, 'No item with this name.');
                else
                    local info = items.GetItemInfo(ResolveEntryId(shown.item));
                    if (info ~= nil) then
                        local line = items.DescribeJobs(info.jobs);
                        if ((info.ilvl or 0) > 0) then
                            line = string.format('Lv.%d i%d  %s', info.level or 0, info.ilvl, line);
                        elseif (info.level ~= nil) and (info.level > 0) then
                            line = string.format('Lv.%d  %s', info.level, line);
                        end
                        imgui.TextColored(theme.col.textDim, line);
                        if (info.description ~= nil) and (#info.description > 0) then
                            imgui.Separator();
                            imgui.Text(info.description);
                        end
                    end
                    local where = (slipNumber ~= nil)
                        and string.format('On Slip %02d, fetch it from the Porter Moogle.', slipNumber)
                        or nil;
                    if covered then
                        imgui.TextColored(theme.col.accent, (where or 'Not in your bags.') .. ' The list skips it.');
                    elseif blocking then
                        imgui.TextColored(theme.col.danger, (where or 'You do not own this.') .. ' It breaks the slot.');
                    elseif unowned then
                        imgui.TextColored(theme.col.caution, where or 'Not in your bags.');
                    end
                end
            end
        elseif (shown.kind == 'chain') and (#shown.entries == 0) then
            imgui.TextDisabled(editable and 'Empty list. Click to add equipment.' or 'Empty list.');
        elseif (shown.kind == 'chain') then
            -- Spelled out: this block is inside a hover tooltip, so a (?) could never be
            -- hovered.
            if setModel.isPriority then
                imgui.TextDisabled('Priority list, first one your level allows');
            else
                imgui.TextColored(theme.col.caution, 'Ignored: set is not _Priority');
            end

            -- The one the game would actually reach for, so it can be called out below.
            local winner = WinningEntry(shown, items.GetMainJobLevel());

            imgui.Separator();
            for i, e in ipairs(shown.entries) do
                local lines = {};
                EntryTooltipLines(e, lines);

                local id = ResolveEntryId(e);
                local info = (id ~= nil) and items.GetItemInfo(id) or nil;

                local head = string.format('%d. %s', i, lines[1]);
                if (info ~= nil) and ((info.ilvl or 0) > 0) then
                    head = string.format('%s   i%d', head, info.ilvl);
                elseif (info ~= nil) and (info.level ~= nil) and (info.level > 0) then
                    head = string.format('%s   Lv.%d', head, info.level);
                end

                if (e == winner) then
                    imgui.TextColored(theme.col.accent, head);
                else
                    imgui.Text(head);
                end

                -- Real indenting, so a wrapped description keeps its left edge.
                if (info ~= nil) and (info.description ~= nil) and (#info.description > 0) then
                    imgui.Indent(TREE_INDENT);
                    imgui.TextColored(theme.col.textDim, info.description);
                    imgui.Unindent(TREE_INDENT);
                end
            end
        end
        if (slotValue ~= nil) and (slotValue.locked == true) then
            imgui.TextColored(theme.col.code,
                'From profile code: ' .. tostring(slotValue.raw));
            imgui.TextDisabled('Save will not change it.');
        end
        imgui.PopTextWrapPos();
        imgui.EndTooltip();
    end

    -- A drop target cannot use IsItemHovered: while the mouse is held, hover reports false for
    -- everything but the active item, so a target drawn BEFORE the source never sees the
    -- release. The cursor against the cell's own rectangle owes nothing to draw order.
    local mx, my = imgui.GetMousePos();
    local overCell = (mx >= minX) and (mx <= maxX) and (my >= minY) and (my <= maxY);

    if editable then
        -- A release that completed a drop is not also a click, or the next cell opens the
        -- picker.
        if hovered and imgui.IsMouseReleased(0) and (S.drag == nil)
            and (not S.dropHandled) then
            OpenSlot(setModel, slotName);
        end
        if hovered and imgui.IsMouseDragging(0, 6.0) and (S.drag == nil) and (slotValue ~= nil) then
            local e = FirstEntry(slotValue);
            S.drag = { fromSlot = slotName, iconId = e and ResolveEntryId(e) or nil };
        end
        -- A drag that began in the picker carries a name instead of a source slot, and
        -- fills the slot rather than swapping with it.
        if (S.drag ~= nil) and S.drag.fromPicker and overCell and imgui.IsMouseReleased(0) then
            if us.FitsSlot({ name = S.drag.name }, slotName) then
                AddToSlot(setModel, slotName, S.drag.name);
                -- Shown the way clicking would, so a drop onto a list ends with the list open.
                -- Runs even for a refused repeat, because the list is what says why.
                AsListIfPriority(setModel, slotName);
                S.detailSel = slotName;
                S.detailTarget = nil;
            else
                Status('Does not fit in ' .. slotName, 'error');
            end
            S.drag = nil;
            S.dropHandled = true;
        end
        if (S.drag ~= nil) and (not S.drag.fromPicker) and overCell
            and imgui.IsMouseReleased(0) and (S.drag.fromSlot ~= slotName) then
            local moving = setModel.slots[S.drag.fromSlot];
            local target = setModel.slots[slotName];
            -- Both directions are checked: the swap also pushes the displaced item back
            -- into the source slot, and it has to fit there too.
            local okMove = us.FitsSlot(FirstEntry(moving), slotName);
            local okBack = us.FitsSlot(FirstEntry(target), S.drag.fromSlot);
            if okMove and okBack then
                PushUndo();
                setModel.slots[S.drag.fromSlot] = target;
                setModel.slots[slotName] = moving;
                MarkDirty(setModel);
            elseif (not okMove) then
                Status('Does not fit in ' .. slotName, 'error');
            else
                Status(slotName .. ' does not fit in ' .. S.drag.fromSlot, 'error');
            end
            S.drag = nil;
            S.dropHandled = true;
        end
    end
end

local function SyncDetailBufs(entry)
    if (type(entry.augment) == 'table') then
        S.augBuf[1] = table.concat(entry.augment, '\n');
    else
        S.augBuf[1] = entry.augment or '';
    end
    S.augPathBuf[1] = entry.augPath or '';
    S.augRankBuf[1] = (entry.augRank ~= nil) and tostring(entry.augRank) or '';
    S.augTrialBuf[1] = (entry.augTrial ~= nil) and tostring(entry.augTrial) or '';
    S.priorityBuf[1] = (entry.priority ~= nil) and tostring(entry.priority) or '';
    S.quantityBuf[1] = (entry.quantity ~= nil) and tostring(entry.quantity) or '';
    local labels, values, index, enabled = BagOptionsFor(entry, items.AvailableBags());
    S.bagLabels = labels;
    S.bagValues = values;
    S.bagEnabled = enabled;
    S.bagIndex = index;
end

local function ApplyDetailBufs(entry)
    local augText = S.augBuf[1] or '';
    local lines = {};
    for line in string.gmatch(augText, '[^\n]+') do
        local trimmed = string.match(line, '^%s*(.-)%s*$');
        if (#trimmed > 0) then
            table.insert(lines, trimmed);
        end
    end
    if (#lines == 0) then
        entry.augment = nil;
    elseif (#lines == 1) then
        entry.augment = lines[1];
    else
        entry.augment = lines;
    end
    entry.augPath = (#(S.augPathBuf[1] or '') > 0) and S.augPathBuf[1] or nil;
    entry.augRank = tonumber(S.augRankBuf[1]);
    entry.augTrial = tonumber(S.augTrialBuf[1]);
    entry.priority = tonumber(S.priorityBuf[1]);
    entry.quantity = tonumber(S.quantityBuf[1]);
    -- Reads the value beside the label rather than the label, so a numeric bag stays a
    -- number and an unrecognized one is written back exactly as it was found.
    entry.bag = S.bagValues and S.bagValues[S.bagIndex] or nil;
end

-- One implementation for a single item and an entry inside a list.
local function DrawEntryFields(setModel, entry, editable)
    if (S.detailTarget ~= entry) then
        SyncDetailBufs(entry);
        S.detailTarget = entry;
    end
    -- Labels before their boxes; ImGui puts a widget's label on its right.
    imgui.Text('Augments, one per line');
    imgui.InputTextMultiline('##aug', S.augBuf, 512, { 320, 54 });

    -- Every row starts its box at the same x. Only the first field of a row needs it.
    local LABEL_COL = imgui.CalcTextSize('Priority') + LABEL_PAD;

    local function Field(label, buf, len, width, help, col)
        imgui.Text(label);
        if (help ~= nil) and imgui.IsItemHovered() then
            imgui.SetTooltip(help);
        end
        if (col ~= nil) then
            imgui.SameLine(col);
        else
            imgui.SameLine();
        end
        imgui.SetNextItemWidth(width);
        imgui.InputText('##' .. label, buf, len);
        if (help ~= nil) and imgui.IsItemHovered() then
            imgui.SetTooltip(help);
        end
    end
    Field('Path', S.augPathBuf, 4, FIELD_W, nil, LABEL_COL);
    imgui.SameLine();
    Field('Rank', S.augRankBuf, 8, FIELD_W);
    imgui.SameLine();
    Field('Trial', S.augTrialBuf, 8, 60);

    -- Rag's own description: any integer works on any piece, highest equipped first. Used to
    -- control equip order for HP.
    Field('Priority', S.priorityBuf, 8, FIELD_W,
        'Equip order, not importance.\nHigher goes on first.\nUse any whole number.', LABEL_COL);
    imgui.SameLine();
    Field('Qty', S.quantityBuf, 8, FIELD_W);

    imgui.Text('Bag');
    imgui.SameLine(LABEL_COL);
    -- Wide enough for the preserved value label, the longest thing it can hold.
    imgui.SetNextItemWidth(190);
    local bagLabels = S.bagLabels or { '(any)' };
    if imgui.BeginCombo('##Bag', bagLabels[S.bagIndex] or '(any)') then
        for i, label in ipairs(bagLabels) do
            -- Shown but not offered, so the list still reads as the game's full set.
            if (S.bagEnabled ~= nil) and (S.bagEnabled[i] == false) then
                imgui.TextDisabled(label);
            elseif imgui.Selectable(label, i == S.bagIndex) then
                S.bagIndex = i;
            end
        end
        imgui.EndCombo();
    end

    if editable then
        if imgui.Button('Apply Details', { BUTTON_W, 0 }) then
            PushUndo();
            ApplyDetailBufs(entry);
            MarkDirty(setModel);
            S.detailTarget = nil;
            Status('Details changed', 'info');
        end
    end
end

-- The three controls that lead a list row. Returns true when this entry was removed.
local function DrawReorderControls(setModel, slotName, slotValue, i, btnH)
    -- Drawn arrows: ^ and v sit at different heights.
    if imgui.ArrowButton('##up' .. i, ImGuiDir_Up) and (i > 1) then
        PushUndo();
        slotValue.entries[i], slotValue.entries[i - 1] =
            slotValue.entries[i - 1], slotValue.entries[i];
        M.FollowSwap(S.detailEntry, slotName, i, i - 1);
        MarkDirty(setModel);
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Move up. The first one wins.');
    end
    imgui.SameLine();
    if imgui.ArrowButton('##down' .. i, ImGuiDir_Down) and (i < #slotValue.entries) then
        PushUndo();
        slotValue.entries[i], slotValue.entries[i + 1] =
            slotValue.entries[i + 1], slotValue.entries[i];
        M.FollowSwap(S.detailEntry, slotName, i, i + 1);
        MarkDirty(setModel);
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Move down');
    end
    imgui.SameLine();
    local removed = imgui.Button('X##rm' .. i, { btnH, btnH });
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Remove from this list');
    end
    return removed;
end

local function DrawChainDetail(setModel, slotName, slotValue, editable)
    if setModel.isPriority then
        imgui.Text(slotName .. ': Priority List');
        if imgui.IsItemHovered() then
            imgui.SetTooltip('The game wears the first piece your level allows,\n'
                .. 'even if you do not own it.');
        end
    else
        imgui.Text(slotName .. ': Item List');
        imgui.SameLine();
        imgui.TextColored(theme.col.caution, 'Does nothing in game');
    end
    -- The list is a drop target too. The cursor is tested against the rows' own rectangle:
    -- while a button is held ImGui reports every other widget as not hovered.
    local listTop = select(2, imgui.GetCursorScreenPos());
    local listLeft = select(1, imgui.GetCursorScreenPos());
    local removeAt = nil;
    for i, e in ipairs(slotValue.entries) do
        imgui.PushID('chain' .. i);
        local rowStartX = imgui.GetCursorPosX();
        local btnH = imgui.GetFrameHeight();
        if editable then
            if DrawReorderControls(setModel, slotName, slotValue, i, btnH) then
                removeAt = i;
            end
            imgui.SameLine();
        end
        -- The buttons are frame height; without this the icon and name ride the top of the row.
        imgui.AlignTextToFramePadding();
        imgui.TextDisabled(tostring(i));
        imgui.SameLine();
        local id = ResolveEntryId(e);
        local ptr = (id ~= nil) and items.GetIconPtr(id) or nil;
        -- An Image sits at the top of a frame-height row; the text beside it does not.
        imgui.SetCursorPosY(imgui.GetCursorPosY() + ((imgui.GetFrameHeight() - ROW_ICON) * 0.5));
        if (ptr ~= nil) then
            imgui.Image(ptr, { ROW_ICON, ROW_ICON });
        else
            imgui.Dummy({ ROW_ICON, ROW_ICON });
        end
        imgui.SameLine();
        -- The level the piece can be worn at, as the picker shows it. e.level is different: the
        -- level the profile pins this entry to.
        local label = e.name or '(unnamed)';
        local info = (id ~= nil) and items.GetItemInfo(id) or nil;
        local badge = items.LevelBadge(info);
        if (badge ~= nil) then
            label = string.format('[%s] %s', badge, label);
        end
        if (e.level ~= nil) then
            label = label .. ' (Lv' .. e.level .. ')';
        end
        local fieldCount = M.CountDetailFields(e);
        if (fieldCount > 0) then
            label = label .. ' (' .. fieldCount .. ')';
        end
        -- Capped at the grid's width: a Selectable otherwise spans the column and swallows the
        -- reorder buttons.
        local nameW = math.max(90, GRID_W - (imgui.GetCursorPosX() - rowStartX));
        local chosen = (S.detailEntry ~= nil) and (S.detailEntry.slot == slotName)
            and (S.detailEntry.index == i);
        if imgui.Selectable(label .. '##entry',
            chosen, 0, { nameW, 0 }) then
            if chosen then
                S.detailEntry = nil;
            else
                S.detailEntry = { slot = slotName, index = i };
            end
            S.detailTarget = nil;
        end
        imgui.PopID();
    end
    if editable and (S.drag ~= nil) and S.drag.fromPicker
        and imgui.IsMouseReleased(0) then
        local mx, my = imgui.GetMousePos();
        local listRight = listLeft + imgui.GetContentRegionAvail();
        local listBottom = select(2, imgui.GetCursorScreenPos());
        if (mx >= listLeft) and (mx <= listRight)
            and (my >= listTop) and (my <= listBottom) then
            if us.FitsSlot({ name = S.drag.name }, slotName) then
                AddToSlot(setModel, slotName, S.drag.name);
            else
                Status('Does not fit in ' .. slotName, 'error');
            end
            S.drag = nil;
            S.dropHandled = true;
        end
    end
    if (removeAt ~= nil) then
        PushUndo();
        table.remove(slotValue.entries, removeAt);
        -- The open form points at a position, not an entry, so removing a row above
        -- it would silently leave it editing a different piece of gear.
        S.detailEntry = nil;
        S.detailTarget = nil;
        if (#slotValue.entries == 0) then
            setModel.slots[slotName] = nil;
            S.detailSel = nil;
        end
        MarkDirty(setModel);
    end

    -- Stacked UNDER the list, so which entry is being edited stays visible.
    if (S.detailEntry ~= nil) and (S.detailEntry.slot == slotName) then
        local chosenEntry = slotValue.entries[S.detailEntry.index];
        if (chosenEntry == nil) then
            S.detailEntry = nil;
        else
            imgui.Separator();
            imgui.Text('Editing ' .. S.detailEntry.index .. ': ' .. (chosenEntry.name or ''));
            DrawEntryFields(setModel, chosenEntry, editable);
            imgui.Spacing();
        end
    end
    -- From GRID_W, not the content region: this panel draws inside the block's indent.
    if editable then
        local half = math.floor((GRID_W - 8) / 2);
        if imgui.Button('Add Item', { half, 0 }) then
            OpenPickerToAppend(setModel, slotName);
        end
        imgui.SameLine();
        if imgui.Button('Close Details', { GRID_W - half - 8, 0 }) then
            S.detailSel = nil;
        end
    elseif imgui.Button('Close Details', { GRID_W, 0 }) then
        S.detailSel = nil;
    end
end

local function DrawDetailPanel(setModel, editable)
    local slotName = S.detailSel;
    if (slotName == nil) then
        return;
    end
    local slotValue = setModel.slots[slotName];
    if (slotValue == nil) then
        S.detailSel = nil;
        return;
    end
    local isOpaque = (slotValue.kind == 'opaque') or (slotValue.locked == true);
    -- Its own gap, opened only once this panel is certain to draw something.
    if (not isOpaque) and (slotValue.kind ~= 'item') and (slotValue.kind ~= 'chain') then
        return;
    end
    imgui.SetCursorPosY(imgui.GetCursorPosY() + theme.ROW_GAP);

    if isOpaque then
        imgui.Text(slotName);
        imgui.TextWrapped('Filled by code in the file, so it cannot be edited here.');
        if editable then
            imgui.Spacing();
            if imgui.Button('Clear Slot', { -1, 0 }) then
                ClearSlot(setModel, slotName);
                S.detailSel = nil;
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Deletes the code as well as the slot.');
            end
        end
    elseif (slotValue.kind == 'item') then
        local entry = slotValue.item;
        if (S.detailTarget ~= entry) then
            SyncDetailBufs(entry);
            S.detailTarget = entry;
        end
        -- The count goes after ### so it stays out of the id: in front of it, filling
        -- in a field would change the id and silently reopen a section you had closed.
        local setCount = M.CountDetailFields(entry);
        local headerText = 'Augments & Extra Fields';
        if (setCount > 0) then
            headerText = headerText .. ' (' .. setCount .. ')';
        end
        -- A child of the grid's width; a header otherwise spans the whole column.
        imgui.BeginChild('##lsvaugbar', { GRID_W, 0 }, ImGuiChildFlags_AutoResizeY);
        local detailsOpen = imgui.CollapsingHeader(headerText .. '###lsvdetails');
        imgui.EndChild();
        if detailsOpen then
            imgui.Text(slotName .. ': ' .. (entry.name or ''));
            DrawEntryFields(setModel, entry, editable);
            imgui.Spacing();
        end

    elseif (slotValue.kind == 'chain') then
        DrawChainDetail(setModel, slotName, slotValue, editable);
    end
end

local function HasInertLists(setModel)
    if setModel.isPriority then
        return false;
    end
    for _, v in pairs(setModel.slots or {}) do
        if (v.kind == 'chain') and (#v.entries > 0) then
            return true;
        end
    end
    return false;
end

local function DrawSetHeader(setModel, editable)
    -- Only the chip is measured, against a fixed width: feeding the row's own height back into
    -- a placement drifts a pixel a frame.
    local rowW = 0;
    local function Fits(label)
        local w = imgui.CalcTextSize(label) + CHIP_PAD;
        if (rowW > 0) and ((rowW + CHIP_GAP + w) <= GRID_W) then
            rowW = rowW + CHIP_GAP + w;
            imgui.SameLine();
        else
            rowW = w;
        end
    end
    -- The name is plain text rather than a chip, so it carries no padding of its own.
    local nameLabel = FitLabel('', setModel.name, 0);
    imgui.Text(nameLabel);
    if (nameLabel ~= setModel.name) and imgui.IsItemHovered() then
        imgui.SetTooltip(setModel.name);
    end
    rowW = imgui.CalcTextSize(nameLabel);
    if us.IsChanged(setModel) then
        Fits('Unsaved');
        theme.Badge('Unsaved', 'accent', 'accentBg', 'Changed, but not saved.');
    end
    if setModel.hasOpaque then
        Fits('{} Code');
        theme.Badge('{} Code', 'code', 'codeBg', 'Slots marked {} come from code.\nSave keeps them as written.');
    end
    if HasInertLists(setModel) then
        Fits('Inert Lists');
        theme.Badge('Inert Lists', 'caution', 'cautionBg',
            'This set has item lists, but LuAshitacast only reads\nlists in sets ending in _Priority. These do nothing in game.');
    end
    if (setModel.fusedWith ~= nil) then
        Fits('Locked');
        theme.Badge('Locked', 'danger', 'dangerBg',
            'Shares a file block with ' .. table.concat(setModel.fusedWith, ', ') .. '.\nBoth stay locked until the file is fixed by hand.');
    elseif (setModel.kind == 'dynamic') then
        Fits('View Only');
        theme.Badge('View Only', 'caution', 'cautionBg', 'Built by code when loaded.\nThere is no file text to edit.');
    elseif (setModel.kind == 'group') then
        Fits('Folder');
        theme.Badge('Folder', 'caution', 'cautionBg', 'Folder of sets. View only.');
    elseif (not editable) then
        Fits('View Only');
        theme.Badge('View Only', 'caution', 'cautionBg', 'Cannot edit safely. Read only.');
    end

    -- One row, always.
    if (setModel.kind == 'set') then
        Fits('Compare');
        if imgui.SmallButton('Compare') then
            S.showCompare = true;
            S.compareWith = setModel.pairedWith;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('See which slots differ.');
        end
    end
    if (setModel.kind == 'set') and (not setModel.isPriority) and editable then
        Fits('Make Priority');
        -- Green, matching the Priority List badge.
        imgui.PushStyleColor(ImGuiCol_Button, theme.col.accentBg);
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.accent);
        local wantPriority = imgui.SmallButton('Make Priority');
        imgui.PopStyleColor(2);
        if wantPriority then
            S.makePriorityTarget = setModel.name;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Renames it to end in _Priority.\nSlots can then hold a list.');
        end
    end
    if (setModel.pairedWith ~= nil) then
        -- The id is built from the full name, so two twins that shorten alike are still two
        -- buttons.
        local twin = FitLabel('Twin: ', setModel.pairedWith);
        Fits(twin);
        if imgui.SmallButton(twin .. '##twin' .. setModel.pairedWith) then
            S.selected = setModel.pairedWith;
            S.detailSel = nil;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Shares a purpose with ' .. setModel.pairedWith
                .. '.\nClick to open it.');
        end
    end
    if (setModel.baseSet ~= nil) then
        local base = FitLabel('Inherits: ', setModel.baseSet);
        Fits(base);
        if imgui.SmallButton(base .. '##base' .. setModel.baseSet) then
            local baseName = string.match(setModel.baseSet, '^[^%.]+');
            if (prof.FindSet(S.model, baseName) ~= nil) then
                S.selected = prof.FindSet(S.model, baseName).name;
                S.detailSel = nil;
            end
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Faded equipment comes from ' .. setModel.baseSet
                .. '.\nClick to open it.');
        end
    end
end

local function DrawGroup(setModel, depth)
    for _, child in ipairs(setModel.children or {}) do
        imgui.PushID(child.name .. depth);
        if (child.kind == 'group') then
            if imgui.TreeNode(child.name) then
                DrawGroup(child, depth + 1);
                imgui.TreePop();
            end
        else
            if imgui.TreeNode(child.name) then
                for _, slotName in ipairs(prof.SlotNames) do
                    local v = child.slots[slotName];
                    if (v ~= nil) then
                        imgui.Text(slotName .. ': ' .. tostring(EntryLabel(v)));
                    end
                end
                imgui.TreePop();
            end
        end
        imgui.PopID();
    end
end


-- Only the entry the game would pick counts, so an unowned item further down a list is fine.
-- Returns nil with a reason when the file cannot take the filter. A native file that never
-- calls EvaluateLevels has nothing to rebuild the filtered lists.
local function FilterEligibility()
    if (S.model == nil) or (S.model.textAtLoad == nil) then
        return nil, 'no profile';
    end
    if writer.OwnedFilterPresent(S.model.textAtLoad) then
        return nil, 'installed';
    end
    -- A profile that already does this by hand must not get a second copy.
    if writer.AlreadyFiltersOwnership(S.model.textAtLoad) then
        return nil, 'already filters';
    end
    if (not prof.IsEditable(S.model, nil)) then
        return nil, 'not editable';
    end
    -- Installing splices into the file as loaded, so pending edits would be written over.
    if us.HasUnsaved() then
        return nil, 'unsaved';
    end
    if (S.model.kind ~= 'basiclua') and (S.model.kind ~= 'native') then
        return nil, 'dialect';
    end
    if (S.model.kind == 'native') and (not us.ProfileEvaluatesLevels()) then
        return nil, 'no rebuild';
    end

    local anyPriority = false;
    for _, s in ipairs(S.model.sets) do
        if (not s.deleted) and s.isPriority then
            anyPriority = true;
            break;
        end
    end
    if (not anyPriority) then
        return nil, 'no priority sets';
    end

    local text = S.model.textAtLoad;
    if (S.model.tableEnd == nil) then
        return nil, 'no sets table';
    end
    local callAt = rules.HandlerBodyStart(text, 'HandleDefault');
    if (callAt == nil) then
        return nil, 'no HandleDefault';
    end
    local nl = string.find(text, '\n', S.model.tableEnd, true);
    local blockAt = (nl == nil) and (#text + 1) or (nl + 1);
    if (blockAt >= callAt) then
        return nil, 'handler is above the sets table';
    end
    local indent = string.match(string.sub(text, callAt), '^([ \t]*)') or '    ';
    return { blockAt = blockAt, callAt = callAt, indent = ((#indent > 0) and indent or '    ') };
end

local function DrawFilterConfirm()
    if (S.filterPrompt == nil) then
        return;
    end
    local removing = (S.filterPrompt == 'remove');
    local title = removing and 'Turn Off##lsvfilter'
        or 'Grow Into Your Equipment##lsvfilter';
    imgui.OpenPopup(title);
    if imgui.BeginPopupModal(title, nil, ImGuiWindowFlags_AlwaysAutoResize) then
        if removing then
            imgui.Text('Restore ' .. S.model.filename
                .. ' to how LuAshitacast works on its own?');
            imgui.Spacing();
            imgui.TextDisabled('Unowned equipment will stop its slot from changing.');
            imgui.TextDisabled(
                "This is how LuAshitacast works, but it is easy to miss.");
        else
            imgui.Text('This writes a small block into ' .. S.model.filename .. '.');
            imgui.Spacing();
            imgui.TextDisabled('Priority lists will skip equipment you do not own,');
            imgui.TextDisabled('so the next piece down gets its turn instead.');
            imgui.TextDisabled('It rechecks a few seconds after your bags change,');
            imgui.TextDisabled('and turns itself off if anything goes wrong.');
            imgui.Spacing();
            imgui.TextDisabled('A backup is made first, and it can be turned off.');
        end
        imgui.Spacing();

        if imgui.Button(removing and 'Turn Off' or 'Turn On', { BUTTON_W, 0 }) then
            local plan = removing and true or FilterEligibility();
            S.filterPrompt = nil;
            if (plan ~= nil) then
                local edit;
                if removing then
                    edit = { op = 'removeownedfilter', name = 'the owned-equipment filter' };
                else
                    edit = { op = 'installownedfilter', name = 'the owned-equipment filter',
                        blockAt = plan.blockAt, callAt = plan.callAt,
                        kind = S.model.kind, indent = plan.indent };
                end
                us.FinishSave(S.model.textAtLoad, { edit });
                S.analysis = nil;
                S.rulesCache = nil;
            else
                Status('File changed, nothing written', 'error');
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { 100, 0 }) then
            S.filterPrompt = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

-- Shared, so the offer line and the panel cannot disagree about the count.
local function BlockedSlots()
    -- Any route counts, including a filter somebody hand wrote.
    local installed = writer.SkipsUnowned(S.model.textAtLoad or '');
    local blocked = {};
    local playerLevel = items.GetMainJobLevel();
    local ownedNames = items.OwnedNames();
    for _, s in ipairs(S.model.sets) do
        if (not s.deleted) and (s.kind == 'set') then
            for _, slotName in ipairs(prof.SlotNames) do
                local slotValue = s.slots[slotName];
                local winner = WinningEntry(slotValue, playerLevel);
                -- With the filter in, the game picks the first one you own, so only a list
                -- where you own nothing is still blocked.
                if installed and s.isPriority and (slotValue ~= nil)
                    and (slotValue.kind == 'chain') then
                    winner = nil;
                    local ownsSomething = false;
                    for _, entry in ipairs(slotValue.entries) do
                        if entry.sentinel or ((entry.name ~= nil)
                            and (ownedNames[string.lower(entry.name)] == true)) then
                            ownsSomething = true;
                            break;
                        end
                    end
                    if (not ownsSomething) then
                        winner = WinningEntry(slotValue, playerLevel);
                    end
                end
                if (winner ~= nil) and (not winner.sentinel) and ((winner.name or '') ~= '') then
                    local own = ownedNames[string.lower(winner.name)];
                    if (ResolveEntryId(winner) ~= nil) and (own ~= true) then
                        -- A list in a _Priority set collapses to the winner, so the slot never
                        -- swaps; any other slot just keeps what was on. Nothing is stuck once
                        -- the file skips what you do not own.
                        local stuck = (not installed) and s.isPriority
                            and (slotValue.kind == 'chain') and (#slotValue.entries > 1);
                        table.insert(blocked, { set = s.name, slot = slotName,
                            item = winner.name, stuck = stuck,
                            id = ResolveEntryId(winner),
                            slip = (type(own) == 'number') and own or nil });
                    end
                end
            end
        end
    end

    return blocked, installed;
end

-- A set marked _Priority is the point at which the filter has something to govern.
local function HasFallbackList(model)
    if (model == nil) then
        return false;
    end
    for _, s in ipairs(model.sets) do
        if (not s.deleted) and (s.kind == 'set') and s.isPriority then
            return true;
        end
    end
    return false;
end

-- At the foot of the unowned panel: it writes running code into a profile. Removal is never
-- gated.
-- Boxed only while open; folded it is one header line. Either way a child of the grid's width,
-- since a collapsing header spans whatever it is given.
local function BeginCapsule(boxed)
    if boxed then
        if (not compat.StaleLibs) then
            imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 4.0);
            imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 8 });
        end
        imgui.PushStyleColor(ImGuiCol_ChildBg, theme.col.panelSoft);
        imgui.BeginChild('##lsvexperimental', { GRID_W, 0 },
            bit.bor(ImGuiChildFlags_Borders, ImGuiChildFlags_AutoResizeY,
                ImGuiChildFlags_AlwaysUseWindowPadding));
    else
        imgui.PushStyleColor(ImGuiCol_ChildBg, { 0, 0, 0, 0 });
        imgui.BeginChild('##lsvexperimental', { GRID_W, 0 },
            ImGuiChildFlags_AutoResizeY);
    end
end

local function EndCapsule(boxed)
    imgui.EndChild();
    imgui.PopStyleColor();
    if boxed and (not compat.StaleLibs) then
        imgui.PopStyleVar(2);
    end
end

-- Last frame's answer, because the box has to be opened before the header that
-- says whether it is open. One frame behind is invisible on a click.
local expandedLastFrame = false;

local function DrawFilterOffer()
    if (S.model == nil) then
        return;
    end
    -- Every line here is short enough to fit without folding.
    local function Header()
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.caution);
        local open = imgui.CollapsingHeader('*Experimental###lsvexperimental',
            ImGuiTreeNodeFlags_DefaultOpen);
        imgui.PopStyleColor();
        return open;
    end
    if writer.OwnedFilterPresent(S.model.textAtLoad or '') then
        imgui.SetCursorPosY(imgui.GetCursorPosY() + theme.ROW_GAP);
        local boxed = expandedLastFrame;
        BeginCapsule(boxed);
        expandedLastFrame = Header();
        if expandedLastFrame then
            theme.WrapText('Safely skip unowned equipment', 'text');
            imgui.Spacing();
            if imgui.SmallButton('Turn Off') then
                S.filterPrompt = 'remove';
            end
        end
        EndCapsule(boxed);
        return;
    end
    -- Unsaved edits are the one blocker the reader can clear.
    local plan, why = FilterEligibility();
    if ((plan == nil) and (why ~= 'unsaved')) or (not HasFallbackList(S.model)) then
        return;
    end
    imgui.SetCursorPosY(imgui.GetCursorPosY() + theme.ROW_GAP);
    local boxed = expandedLastFrame;
    BeginCapsule(boxed);
    expandedLastFrame = Header();
    if (not expandedLastFrame) then
        EndCapsule(boxed);
        return;
    end
    theme.WrapText('List equipment you do not own yet.', 'text');
    theme.WrapText('Grow into your equipment over time.', 'text');
    imgui.Spacing();
    -- Green on both: Save First clears the only thing in the way and the button becomes Turn
    -- On.
    imgui.PushStyleColor(ImGuiCol_Button, theme.col.accentBg);
    imgui.PushStyleColor(ImGuiCol_Text, theme.col.accent);
    local pressed = imgui.SmallButton((plan == nil) and 'Save First' or 'Turn On');
    imgui.PopStyleColor(2);
    if pressed then
        if (plan == nil) then
            us.StartSave();
        else
            S.filterPrompt = 'install';
        end
    end
    EndCapsule(boxed);
end
local function DrawUnownedRow(b)
    imgui.Dummy({ ROW_INDENT, 0 });
    imgui.SameLine();
    imgui.AlignTextToFramePadding();
    local ptr = (b.id ~= nil) and items.GetIconPtr(b.id) or nil;
    if (b.id ~= nil) then
        items.RequestIcon(b.id);
    end
    imgui.SetCursorPosY(imgui.GetCursorPosY() + ((imgui.GetFrameHeight() - ROW_ICON) * 0.5));
    if (ptr ~= nil) then
        imgui.Image(ptr, { ROW_ICON, ROW_ICON });
    else
        imgui.Dummy({ ROW_ICON, ROW_ICON });
    end
    imgui.SameLine();
    local info = (b.id ~= nil) and items.GetItemInfo(b.id) or nil;
    local name = b.item;
    local badge = items.LevelBadge(info);
    if (badge ~= nil) then
        name = string.format('[%s] %s', badge, name);
    end
    imgui.Text(name);
    imgui.SameLine();
    local where = b.set .. ', ' .. b.slot;
    if (b.slip ~= nil) then
        where = where .. string.format(', on Slip %02d', b.slip);
    end
    imgui.TextDisabled(where);
end

local function DrawUnownedPanel()
    if (S.model == nil) then
        return;
    end
    local blocked, installed = BlockedSlots();
    -- Still opens for a filtered file with an empty list, so it can say so rather
    -- than vanish and read as the feature having gone.
    if (#blocked == 0) and (not installed) then
        return;
    end

    imgui.Spacing();

    -- Closed whenever the profile changes; ImGui keeps header state in memory only. The count
    -- sits after ### so buying a piece cannot reopen a closed section.
    if (S.unownedFor ~= S.model.path) then
        S.unownedFor = S.model.path;
        imgui.SetNextItemOpen(false, ImGuiCond_Always);
    end
    -- Green when the file skips what you do not own, red when every line is a slot that will
    -- not equip.
    local headColor = installed and theme.col.accent or theme.col.danger;
    imgui.PushStyleColor(ImGuiCol_Text, headColor);
    local open = imgui.CollapsingHeader(
        string.format('Equipment You Do Not Own (%d)###lsvunowned', #blocked));
    imgui.PopStyleColor();

    -- On the header itself: a collapsing header spans the full width, so a (?) after it lands
    -- past the edge.
    if imgui.IsItemHovered() then
        if installed then
            imgui.SetTooltip('Anywhere in this profile.\n'
                .. 'The file skips all of it.');
        else
            imgui.SetTooltip('Anywhere in this profile.\n'
                .. 'Each one breaks its whole slot.');
        end
    end

    if open then
        -- Bounded: a height of zero would swallow the set list under it.
        -- Split: a collapsed list never swaps again, an ordinary slot just fails to equip.
        local stuck, quiet = {}, {};
        for _, b in ipairs(blocked) do
            if b.stuck then
                stuck[#stuck + 1] = b;
            else
                quiet[#quiet + 1] = b;
            end
        end

        -- Tall enough for what is in it, up to a ceiling.
        local rows = #blocked;
        if (#stuck > 0) then
            rows = rows + 1;
        end
        if (#quiet > 0) and (not installed) then
            rows = rows + 1;
        end
        imgui.BeginChild('##unownedlist',
            { 0, imgui.GetFrameHeightWithSpacing() * math.min(rows, UNOWNED_ROWS) }, 0);

        if (#stuck > 0) then
            imgui.TextColored(theme.col.danger, 'The slot stops swapping.');
            for _, b in ipairs(stuck) do
                DrawUnownedRow(b);
            end
        end
        if (#quiet > 0) then
            if (#stuck > 0) then
                imgui.Spacing();
            end
            -- No heading once the file skips these: a list of what you have not got yet, not a
            -- caution.
            if (not installed) then
                imgui.TextColored(theme.col.textDim, 'The slot keeps what you are wearing.');
            end
            for _, b in ipairs(quiet) do
                DrawUnownedRow(b);
            end
        end
        if installed and (#blocked == 0) then
            imgui.TextDisabled('Nothing. Your lists skip what you do not own.');
        end

        imgui.EndChild();
    end
end

M.HasFallbackList = HasFallbackList;

M.DrawSlotCell = DrawSlotCell;
M.DrawDetailPanel = DrawDetailPanel;
M.DrawSetHeader = DrawSetHeader;
M.FitLabel = FitLabel;
M.DrawGroup = DrawGroup;
M.DrawUnownedPanel = DrawUnownedPanel;
M.DrawFilterOffer = DrawFilterOffer;
M.DrawFilterConfirm = DrawFilterConfirm;

return M;
