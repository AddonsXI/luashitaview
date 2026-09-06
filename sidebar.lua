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
local theme = require('theme');
local us = require('uistate');

local S = us.S;

local M = {};

local function FuzzyMatch(name, needle)
    local ln = string.lower(name);
    if (string.find(ln, needle, 1, true) ~= nil) then
        return true;
    end
    local pos = 1;
    for i = 1, #needle do
        local c = string.sub(needle, i, i);
        if (c ~= ' ') then
            pos = string.find(ln, c, pos, true);
            if (pos == nil) then
                return false;
            end
            pos = pos + 1;
        end
    end
    return true;
end

local function SetFamily(name)
    return string.match(name, '^([^_]+)_') or '';
end

-- Section headings are alphabetical; inside a section the file's own order is kept, and a
-- family's base set leads its section.
-- Families that lead the list when the profile has one, in this order.
local PINNED = { 'idle', 'weapon' };

local function PinRank(fam)
    local key = string.lower(fam);
    for i, name in ipairs(PINNED) do
        if (key == name) then
            return i;
        end
    end
    return #PINNED + 1;
end

M.GroupForSidebar = function(visible)
    local famCounts = {};
    for _, e in ipairs(visible) do
        if (e.parent == nil) then
            local fam = SetFamily(e.s.name);
            if (fam ~= '') then
                famCounts[fam] = (famCounts[fam] or 0) + 1;
            end
        end
    end
    -- A set named exactly like a family is that family's base set and leads its section.
    for _, e in ipairs(visible) do
        if (e.parent == nil) and (SetFamily(e.s.name) == '') and (famCounts[e.s.name] ~= nil) then
            famCounts[e.s.name] = famCounts[e.s.name] + 1;
        end
    end

    local singles = {};
    local famOrder = {};
    local buckets = {};
    for _, e in ipairs(visible) do
        -- A folder member always sits under its folder's heading, even alone; the
        -- two-member rule only applies to families inferred from name prefixes.
        local fam = (e.parent ~= nil) and e.parent or SetFamily(e.s.name);
        local isBase = false;
        if (e.parent == nil) and (fam == '') and (famCounts[e.s.name] ~= nil) then
            fam = e.s.name;
            isBase = true;
        end
        if (e.parent == nil) and ((fam == '') or (famCounts[fam] < 2)) then
            table.insert(singles, e);
        else
            if (buckets[fam] == nil) then
                buckets[fam] = {};
                table.insert(famOrder, fam);
            end
            if isBase then
                table.insert(buckets[fam], 1, e);
            else
                table.insert(buckets[fam], e);
            end
        end
    end
    -- Only when the profile has it: a missing name pins nothing.
    for _, name in ipairs(PINNED) do
        for i, e in ipairs(singles) do
            if (string.lower(e.s.name) == name) then
                table.remove(singles, i);
                buckets[e.s.name] = { e };
                table.insert(famOrder, e.s.name);
                break;
            end
        end
    end
    table.sort(famOrder, function(a, b)
        local ra, rb = PinRank(a), PinRank(b);
        if (ra ~= rb) then
            return ra < rb;
        end
        return string.lower(a) < string.lower(b);
    end);
    return famOrder, buckets, singles;
end

local function CountSlots(s)
    local n = 0;
    for _, v in pairs(s.slots or {}) do
        -- An empty list occupies the slot key without putting anything in it.
        if (v.kind ~= 'chain') or (#v.entries > 0) then
            n = n + 1;
        end
    end
    return n;
end

-- How far the first mark sits past the name, and how far apart they run.
local MARK_GAP = 8;
local MARK_SPACING = 5;

local function DrawSetRow(s, parentPath)
    local locked = (s.kind ~= 'set') or (s.fusedWith ~= nil) or (s.range == nil and not s.isNew);
    if locked then
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.textDim);
    end
    local rowId = s.name .. '##set_' .. (parentPath or '') .. '/' .. s.name;
    local isSelected = (S.selected == s.name) and (S.selectedIn == parentPath);
    if isSelected then
        imgui.PushStyleColor(ImGuiCol_Header, theme.col.accentBg);
    end
    if imgui.Selectable(rowId, isSelected) then
        S.selected = s.name;
        S.selectedIn = parentPath;
        S.detailSel = nil;
        S.detailTarget = nil;
    end
    if isSelected then
        imgui.PopStyleColor();
    end
    if locked then
        imgui.PopStyleColor();
    end
    local hovered = imgui.IsItemHovered();
    local minX, minY = imgui.GetItemRectMin();
    local _, maxY = imgui.GetItemRectMax();
    local dl = imgui.GetWindowDrawList();
    -- P for a _Priority set, B for a BaseSet, { for a slot filled by code.
    local nameW, textH = imgui.CalcTextSize(s.name);
    local x = minX + nameW + MARK_GAP;
    local y = minY + (((maxY - minY) - textH) * 0.5);
    local function Mark(glyph, colorKey)
        dl:AddText({ x, y }, imgui.GetColorU32(theme.col[colorKey]), glyph);
        x = x + imgui.CalcTextSize(glyph) + MARK_SPACING;
    end
    if us.IsChanged(s) then
        Mark('*', 'accent');
    end
    if s.isPriority then
        Mark('P', 'accentDim');
    end
    if (s.hasOpaque == true) then
        Mark('{', 'code');
    end
    if (s.baseSet ~= nil) then
        Mark('B', 'textFaint');
    end
    if hovered then
        imgui.BeginTooltip();
        imgui.Text(s.name);
        if (s.kind == 'set') then
            imgui.TextDisabled(CountSlots(s) .. ' of 16 slots filled');
        end
        if us.IsChanged(s) then
            imgui.TextColored(theme.col.accent, 'Unsaved changes');
        end
        if s.isPriority then
            imgui.TextDisabled('Holds options. Used as ' .. tostring(s.logicalName));
        end
        if (s.baseSet ~= nil) then
            imgui.TextDisabled('Inherits from ' .. s.baseSet);
        end
        if s.hasOpaque then
            imgui.TextColored(theme.col.code, 'Some slots come from profile code');
        end
        if locked then
            imgui.TextDisabled('View only');
        end
        imgui.EndTooltip();
    end
end

M.FuzzyMatch = FuzzyMatch;
M.DrawSetRow = DrawSetRow;

return M;
