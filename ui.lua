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
* Every window, panel and dialog. The only module that draws.
*
* Holds the editing model and the undo stack. Nothing here parses or serializes; that
* belongs to profile and writer, which stay free of Ashita so they can be tested.
--]]

local imgui = require('imgui');
local compat = require('compat');
local chat = require('chat');
local prof = require('profile');
local writer = require('writer');
local rules = require('rules');
local items = require('items');
local picker = require('picker');
local theme = require('theme');

local M = {};

--[[
* Sizes that repeat, named once. The value is unchanged in every case; naming it
* only stops the same number being retyped and drifting apart later.
--]]
local BUTTON_W = 100;      -- the standard width of a dialog button
local NAME_FIELD_W = 240;  -- the name box in the create, rename and duplicate dialogs
local NAME_MAX = 48;       -- longest name those boxes accept
local FILTER_MAX = 64;     -- the filter box and the file rename box
local CHOICE_W = 140;      -- a button whose label is a choice rather than a verb
local CHOICE_WIDE_W = 160; -- the same, where the label runs longer
local CONFIRM_W = 120;     -- Save and Cancel on the save summary

-- The main window's size the first time it opens, and after a reset.
local WINDOW_DEFAULT_W = 1040;
local WINDOW_DEFAULT_H = 640;

-- The compare view lays two sets out side by side at these fixed columns.
local COMPARE_COL_L = 80;
local COMPARE_COL_R = 270;


local us = require('uistate');
local S = us.S;

local Status, ChatMsg = us.Status, us.ChatMsg;
local HasUnsaved, SelectedSet = us.HasUnsaved, us.SelectedSet;
local CaptureBaseline = us.CaptureBaseline;
local RegisterSet, RebuildLookup, NameInUse, CreateSet =
    us.RegisterSet, us.RebuildLookup, us.NameInUse, us.CreateSet;
local DeepCopySlots, PushUndo, DoUndo, DoRedo = us.DeepCopySlots, us.PushUndo, us.DoUndo, us.DoRedo;
local EntryLabel, ApplyRename = us.EntryLabel, us.ApplyRename;
local ProfileEvaluatesLevels = us.ProfileEvaluatesLevels;
local FinishSave, StartSave, ContinueSaveAfterWarn =
    us.FinishSave, us.StartSave, us.ContinueSaveAfterWarn;
local EffectiveBaseSlots = us.EffectiveBaseSlots;

M.AutoOpen = us.AutoOpen;
M.Toggle = us.Toggle;
M.IsOpen = us.IsOpen;
M.RefreshDiscovery = us.RefreshDiscovery;
M.OpenProfile = us.OpenProfile;
M.RequestOpen = us.RequestOpen;
M.MissingFrameworkFiles = us.MissingFrameworkFiles;
M.EvaluatesLevels = us.EvaluatesLevels;
M.FitsSlot = us.FitsSlot;

local GridLayout = {
    { 'Main', 'Sub', 'Range', 'Ammo' },
    { 'Head', 'Neck', 'Ear1', 'Ear2' },
    { 'Body', 'Hands', 'Ring1', 'Ring2' },
    { 'Back', 'Waist', 'Legs', 'Feet' },
};

-- All three columns are shares of the row, so everything grows together and the two
-- draggable dividers make the split the reader's choice. The minimums are deliberately
-- small: the point is being able to tuck the window in a corner and pull it back out.
local SETLIST_MIN = 90;
--[[
* Wide enough for the gear grid, which is what this column holds.
*
* Four cells of 76 (a 64 icon plus 6 padding each side), three gaps of 8, and
* the child's own padding and border. At 260 the column could be narrower than
* its own contents, so the right hand column of slots was simply cut off, which
* is exactly what the default split produced on a fresh install.
--]]
local SETVIEW_MIN = (4 * 76) + (3 * 8) + 22;
local PICKER_MIN = 120;
local SPLITTER_W = 6;

-- The profile name is the widest thing in the header and the one people read
-- first, so it gets the room. Everything else on that row is a fixed button.
local PROFILE_COMBO_W = 260;

-- How far past the last tab the status sits.
local STATUS_GAP = 14;
-- The space around the gear grid inside its column, on every side.
local BLOCK_MARGIN = 8;

-- ImGui puts 8 between items across and 4 down, and the theme changes neither.
-- The two are not interchangeable: using the vertical one to split a row left the
-- buttons 4 wider than the space they had.
local ITEM_SPACING_X = 8;

local WINDOW_MIN_W = 520;
local WINDOW_MIN_H = 280;

--[[
* Deliberately empty. Do not add a SetNextWindowPos pre-call here: this binding ignores
* the pivot form for modals, and the two-argument form fights the in-window correction
* below, each frame yanking the modal to a different spot and smearing the text.
* EnforcePopupCenter is the one positioning authority.
--]]
local function CenterNextPopup()
end

-- Called inside every open modal: measures where it actually ended up and drags it to
-- the center of the addon window when it landed somewhere else.
local function EnforcePopupCenter(tag)
    if (S.winCenter == nil) then
        return;
    end
    local px, py = imgui.GetWindowPos();
    local pw, ph = imgui.GetWindowSize();
    local wantX = S.winCenter.x - (pw / 2);
    local wantY = S.winCenter.y - (ph / 2);
    local off = (math.abs(px - wantX) > 40) or (math.abs(py - wantY) > 40);
    if off then
        imgui.SetWindowPos({ wantX, wantY }, ImGuiCond_Always);
    end
end

local sidebar = require('sidebar');
local FuzzyMatch = sidebar.FuzzyMatch;
local DrawSetRow = sidebar.DrawSetRow;
M.GroupForSidebar = sidebar.GroupForSidebar;
local grid = require('grid');
local DrawSetHeader = grid.DrawSetHeader;
local DrawGroup = grid.DrawGroup;
local DrawSlotCell = grid.DrawSlotCell;
local DrawDetailPanel = grid.DrawDetailPanel;
local DrawUnownedPanel = grid.DrawUnownedPanel;
local DrawFilterOffer = grid.DrawFilterOffer;
local DrawFilterConfirm = grid.DrawFilterConfirm;
M.BagOptionsFor = grid.BagOptionsFor;
M.ClickOpensList = grid.ClickOpensList;
M.HasFallbackList = grid.HasFallbackList;
M.CountDetailFields = grid.CountDetailFields;
M.FollowSwap = grid.FollowSwap;
M.SlotHasAugments = grid.SlotHasAugments;

--[[
* Turns the two split fractions into three pixel widths. Three columns each with a
* minimum have to add up to exactly the row, and a naive clamp on each in turn
* overflows the last, so each is clamped against what the others still need.
--]]
M.ColumnWidths = function(usable, a, b)
    local floor = SETLIST_MIN + SETVIEW_MIN + PICKER_MIN;
    if (usable < floor) then
        usable = floor;
    end
    local setList = math.floor(usable * a);
    local maxList = usable - SETVIEW_MIN - PICKER_MIN;
    if (setList > maxList) then setList = maxList; end
    if (setList < SETLIST_MIN) then setList = SETLIST_MIN; end

    local setView = math.floor(usable * (b - a));
    local maxView = usable - setList - PICKER_MIN;
    if (setView > maxView) then setView = maxView; end
    if (setView < SETVIEW_MIN) then setView = SETVIEW_MIN; end

    return setList, setView, usable - setList - setView;
end

-- A draggable divider. The split follows the cursor's absolute position rather than
-- accumulating deltas, so it cannot drift and needs no state between frames.
local function Splitter(id, originX, usable, height, fraction, minFrac, maxFrac)
    imgui.SameLine(0, 0);
    imgui.InvisibleButton(id, { SPLITTER_W, height });
    if imgui.IsItemHovered() or imgui.IsItemActive() then
        imgui.SetMouseCursor(ImGuiMouseCursor_ResizeEW);
    end
    if imgui.IsItemActive() then
        local mx = imgui.GetMousePos();
        local want = (mx - (SPLITTER_W / 2) - originX) / usable;
        if (want < minFrac) then want = minFrac; end
        if (want > maxFrac) then want = maxFrac; end
        fraction = want;
    end
    imgui.SameLine(0, 0);
    return fraction;
end

--[[
* The three columns: the set list, the gear grid, and the picker, with a draggable
* divider between each. Every child is sized in pixels rather than left to fill,
* because a column that collapses to nothing cannot be dragged back open.
--]]
--[[
* The left column: the filter, the grouped list of sets, and the four buttons
* that make and unmake them. Everything it needs it declares itself, so nothing
* here is visible to the other two columns.
--]]
--[[
* The five dialogs behind the buttons under the set list: New, Duplicate, Rename,
* Make Priority and Delete. Each is a flag and a modal, and none of them reads
* anything the list above it declared.
--]]
local function DrawNewSetDialog()
    CenterNextPopup();
    if imgui.BeginPopupModal('New Set##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('New Set');
        imgui.Text('New set name:');
        imgui.SetNextItemWidth(NAME_FIELD_W);
        imgui.InputText('##newname', S.nameBuf, NAME_MAX);
        local name = S.nameBuf[1] or '';
        local ok, why = writer.ValidateName(name);
        if (#name > 0) and (not ok) then
            imgui.TextColored(theme.col.caution, why);
        elseif (#name > 0) and NameInUse(name) then
            ok = false;
            imgui.TextColored(theme.col.caution, 'That name is already in this profile.');
        end
        if imgui.Button('Create', { BUTTON_W, 0 }) and ok and (#name > 0) then
            CreateSet(name);
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

local function DrawDuplicateSetDialog()
    CenterNextPopup();
    if imgui.BeginPopupModal('Duplicate Set##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Duplicate Set');
        imgui.Text('Name for the copy:');
        imgui.SetNextItemWidth(NAME_FIELD_W);
        imgui.InputText('##dupname', S.nameBuf, NAME_MAX);
        local name = S.nameBuf[1] or '';
        local ok, why = writer.ValidateName(name);
        if (#name > 0) and (not ok) then
            imgui.TextColored(theme.col.caution, why);
        elseif (#name > 0) and NameInUse(name) then
            ok = false;
            imgui.TextColored(theme.col.caution, 'That name is already in this profile.');
        end
        if imgui.Button('Create', { BUTTON_W, 0 }) and ok and (#name > 0) then
            local cur = SelectedSet();
            if (cur ~= nil) then
                PushUndo();
                local extras = {};
                for _, ex in ipairs(cur.extraKeys or {}) do
                    table.insert(extras, { key = ex.key, raw = ex.raw, order = ex.order });
                end
                local setModel = {
                    name = name,
                    kind = 'set',
                    slots = DeepCopySlots(cur.slots),
                    baseSet = cur.baseSet,
                    noWrite = cur.noWrite,
                    unknownKeys = {},
                    extraKeys = extras,
                    dirty = true,
                    isNew = true,
                    deleted = false,
                };
                setModel.logicalName, setModel.isPriority = prof.LogicalName(name);
                RegisterSet(setModel);
                S.selected = name;
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

local function DrawRenameSetDialog()
    CenterNextPopup();
    if imgui.BeginPopupModal('Rename Set##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Rename Set');
        imgui.Text('New name for ' .. tostring(S.renameTarget) .. ':');
        imgui.SetNextItemWidth(NAME_FIELD_W);
        imgui.InputText('##renname', S.renameBuf, NAME_MAX);
        local name = S.renameBuf[1] or '';
        local ok, why = writer.ValidateName(name);
        if (#name > 0) and (not ok) then
            imgui.TextColored(theme.col.caution, why);
        elseif (#name > 0) and (string.lower(name) ~= string.lower(S.renameTarget or ''))
            and NameInUse(name) then
            ok = false;
            imgui.TextColored(theme.col.caution, 'That name is already in this profile.');
        end
        -- The count comes from the same locator the save uses, so what is promised here
        -- and what is written later can never disagree.
        local mentions = 0;
        if (S.renameTarget ~= nil) and (S.model ~= nil) then
            local okSites, sites = pcall(rules.FindRenameSites, S.model.textAtLoad, S.renameTarget);
            if okSites and (sites ~= nil) then
                local cur = prof.FindSet(S.model, S.renameTarget);
                for _, site in ipairs(sites) do
                    local own = (cur ~= nil) and (cur.range ~= nil)
                        and (site.s >= cur.range.s) and (site.e <= cur.range.e);
                    if (not own) then
                        mentions = mentions + 1;
                    end
                end
            end
        end
        if (mentions > 0) then
            imgui.TextWrapped(mentions .. ' mention' .. ((mentions == 1) and '' or 's')
                .. ' in this file will be updated to match. Save shows them first.');
        else
            imgui.TextWrapped('Nothing in this file mentions it, so only the set is renamed.');
        end
        if imgui.Button('Rename', { BUTTON_W, 0 }) and ok and (#name > 0) then
            local cur = prof.FindSet(S.model, S.renameTarget);
            if (cur ~= nil) then
                ApplyRename(cur, name);
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

local function DrawMakePriorityDialog()
    if (S.makePriorityTarget ~= nil) then
        imgui.OpenPopup('Make Priority##lsv');
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('Make Priority##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Make Priority');
        local target = prof.FindSet(S.model, S.makePriorityTarget or '');
        local newName = tostring(S.makePriorityTarget) .. '_Priority';
        imgui.Text('Rename ' .. tostring(S.makePriorityTarget) .. ' to ' .. newName .. '?');
        imgui.TextWrapped('In game nothing changes until a slot holds more than one item. The game keeps using it under its old name, so handlers that mention it keep working.');

        -- EvaluateLevels writes its result back under the suffix-stripped name
        -- unconditionally, so a profile holding both spellings has the plain one
        -- silently clobbered in play. Hence the refusal.
        local collision = NameInUse(newName);
        if collision then
            imgui.TextColored(theme.col.danger, 'This profile already has ' .. newName .. '.');
            imgui.TextWrapped('In game, the priority set would silently overwrite this one, so one of them has to be renamed or deleted first.');
        elseif (not ProfileEvaluatesLevels()) then
            imgui.TextColored(theme.col.caution, 'Nothing here runs priority lists yet.');
            imgui.TextWrapped('Lists only work once the profile calls gFunc.EvaluateLevels, or uses BasicLuas. The rename is still safe, it just does nothing until then.');
        end

        if (target == nil) then
            S.makePriorityTarget = nil;
            imgui.CloseCurrentPopup();
        elseif (not collision) then
            if imgui.Button('Make Priority Set', { 170, 0 }) then
                ApplyRename(target, newName);
                S.makePriorityTarget = nil;
                imgui.CloseCurrentPopup();
            end
            imgui.SameLine();
        end
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            S.makePriorityTarget = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

local function DrawDeleteSetDialog()
    CenterNextPopup();
    if imgui.BeginPopupModal('Delete Set##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Delete Set');
        imgui.Text('Delete ' .. tostring(S.deleteTarget) .. '?');
        imgui.TextWrapped('It leaves the file when you press Save. A timestamped backup of the whole file is made first.');
        imgui.Text('Type the set name to confirm:');
        imgui.SetNextItemWidth(NAME_FIELD_W);
        imgui.InputText('##delconfirm', S.deleteBuf, NAME_MAX);
        local confirmed = string.lower(S.deleteBuf[1] or '') == string.lower(S.deleteTarget or '');
        if (not confirmed) then
            imgui.TextDisabled('Delete unlocks when it matches.');
        end
        if imgui.Button('Delete', { BUTTON_W, 0 }) and confirmed then
            local cur = prof.FindSet(S.model, S.deleteTarget);
            if (cur ~= nil) then
                PushUndo();
                if cur.isNew then
                    for i, s in ipairs(S.model.sets) do
                        if (s == cur) then
                            table.remove(S.model.sets, i);
                            break;
                        end
                    end
                    RebuildLookup();
                else
                    CaptureBaseline(cur);
                    cur.deleted = true;
                end
                if (S.selected == S.deleteTarget) then
                    S.selected = nil;
                    for _, s in ipairs(S.model.sets) do
                        if (s.kind == 'set') and (not s.deleted) then
                            S.selected = s.name;
                            break;
                        end
                    end
                end
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

local function DrawSetDialogs()
    DrawNewSetDialog();
    DrawDuplicateSetDialog();
    DrawRenameSetDialog();
    DrawMakePriorityDialog();
    DrawDeleteSetDialog();
end

-- Forward declared: the set list column draws it, and it needs helpers defined
-- further down, so neither can come first.
local DrawRuleFindings;
local DrawHandlerBrowser;

local function DrawSetListColumn(setListW)
    imgui.BeginChild('##setlist', { setListW, 0 }, ImGuiChildFlags_Borders);
    imgui.SetNextItemWidth(-1);
    -- The count rides in the filter's hint: it names the thing being filtered,
    -- so it needs no line of its own and reads as a label rather than a stat.
    local setCount = (S.model ~= nil) and #S.model.sets or 0;
    imgui.InputTextWithHint('##filter',
        'Filter ' .. setCount .. ' Set' .. ((setCount == 1) and '' or 's'),
        S.filter, FILTER_MAX);
    local needle = string.lower(S.filter[1] or '');

    -- A whole profile report, so it belongs in the column that lists the whole
    -- profile rather than under one set's grid. Collapsed unless you open it.
    DrawUnownedPanel();

    --[[
    * The WITH-SPACING height, not a frame plus a gap: each row carries a trailing gap
    * of its own, and reserving one short overflows this child, which ImGui answers
    * with a second scrollbar around the whole column.
    *
    * Two rows, both of buttons. The checks scroll with the sets rather than
    * sitting under them, so nothing is reserved for them here.
    --]]
    local rowHeight = imgui.GetFrameHeightWithSpacing();
    local buttonRows = rowHeight * 2;

    imgui.BeginChild('##setlistinner', { 0, -buttonRows }, 0);
    -- A folder is flattened into the list: its name becomes a section heading like the
    -- name-family headings, and its member sets sit under it as ordinary rows.
    local visible = {};
    local function AddVisible(s, parentPath)
        if s.deleted then
            return;
        end
        if (s.kind == 'group') then
            local path = ((parentPath ~= nil) and (parentPath .. '/') or '') .. s.name;
            for _, c in ipairs(s.children or {}) do
                AddVisible(c, path);
            end
            return;
        end
        if (#needle == 0) or FuzzyMatch(s.name, needle)
            or ((parentPath ~= nil) and FuzzyMatch(parentPath, needle)) then
            table.insert(visible, { s = s, parent = parentPath });
        end
    end
    for _, s in ipairs(S.model.sets) do
        AddVisible(s, nil);
    end
    local famOrder, buckets, singles = M.GroupForSidebar(visible);

    for _, fam in ipairs(famOrder) do
        -- A pinned set with no siblings is a group of one named after itself, so the
        -- heading would only repeat the row under it.
        local rows = buckets[fam];
        if (#rows > 1) or (rows[1].s.name ~= fam) then
            imgui.TextColored(theme.col.textFaint, (string.gsub(fam, '/', ' / ')));
            imgui.Separator();
        end
        for _, e in ipairs(buckets[fam]) do
            DrawSetRow(e.s, e.parent);
        end
        imgui.Spacing();
    end
    if (#singles > 0) then
        if (#famOrder > 0) then
            imgui.TextColored(theme.col.textFaint, 'Other');
            imgui.Separator();
        end
        for _, e in ipairs(singles) do
            DrawSetRow(e.s, e.parent);
        end
    end
    if (#visible == 0) then
        imgui.TextDisabled('No matches.');
    end

    --[[
    * Last thing INSIDE the scrolling list rather than pinned under it, so a profile
    * with a lot of sets hides it until you scroll to the end and a short one shows it
    * straight away. They are read once and then left alone.
    --]]
    imgui.Spacing();
    DrawRuleFindings();

    imgui.EndChild();

    local editableProfile = prof.IsEditable(S.model, nil);
    if editableProfile then
        local availW = imgui.GetContentRegionAvail();
        local btn = (availW - ITEM_SPACING_X) / 2;

        if imgui.Button('New', { btn, 0 }) then
            S.nameBuf[1] = '';
            imgui.OpenPopup('New Set##lsv');
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Start an empty set');
        end
        imgui.SameLine();
        if imgui.Button('Duplicate', { btn, 0 }) then
            local cur = SelectedSet();
            if (cur ~= nil) and (cur.kind == 'set') then
                S.nameBuf[1] = cur.name .. ' 2';
                imgui.OpenPopup('Duplicate Set##lsv');
            end
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Copy it for a variant');
        end
        if imgui.Button('Rename', { btn, 0 }) then
            local cur = SelectedSet();
            if (cur ~= nil) and prof.IsEditable(S.model, cur) then
                S.renameTarget = cur.name;
                S.renameBuf[1] = cur.name;
                imgui.OpenPopup('Rename Set##lsv');
            end
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Rename this set');
        end
        imgui.SameLine();
        if imgui.Button('Delete', { btn, 0 }) then
            local cur = SelectedSet();
            if (cur ~= nil) and (prof.IsEditable(S.model, cur) or cur.isNew) then
                S.deleteTarget = cur.name;
                S.deleteBuf[1] = '';
                imgui.OpenPopup('Delete Set##lsv');
            end
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Removed on the next Save');
        end
    else
        imgui.TextDisabled('Read Only');
    end

    DrawSetDialogs();

    imgui.EndChild();
end

--[[
* The middle column: the selected set drawn as a grid of sixteen slots, with the
* detail panel and the unowned list under it.
--]]
local function DrawSetViewColumn(setViewW)
    imgui.BeginChild('##setview', { setViewW, 0 }, ImGuiChildFlags_Borders);
    local cur = SelectedSet();
    local topLevelSets = 0;
    local anyEntries = 0;
    for _, s in ipairs(S.model.sets) do
        if (not s.deleted) then
            anyEntries = anyEntries + 1;
            if (s.kind == 'set') then
                topLevelSets = topLevelSets + 1;
            end
        end
    end
    if (anyEntries == 0) and prof.IsEditable(S.model, nil) then
        imgui.Dummy({ 0, 40 });
        imgui.Text('This profile has no equipment sets yet.');
        imgui.TextWrapped('A set is equipment LuAshitacast equips together, like Idle or Tp.');
        local pairW = math.max(CHOICE_WIDE_W,
            imgui.CalcTextSize('Create an Idle Set') + imgui.GetFrameHeight());
        if imgui.Button('Create an Idle Set', { pairW, 0 }) then
            if (not NameInUse('Idle')) then
                CreateSet('Idle');
            end
        end
        imgui.SameLine();
        if imgui.Button('New Set', { pairW, 0 }) then
            S.nameBuf[1] = '';
            imgui.OpenPopup('New Set##lsvfirst');
        end
        CenterNextPopup();
        if imgui.BeginPopupModal('New Set##lsvfirst', nil, ImGuiWindowFlags_AlwaysAutoResize) then
            EnforcePopupCenter('New Set');
            imgui.Text('New set name:');
            imgui.SetNextItemWidth(NAME_FIELD_W);
            imgui.InputText('##newnamef', S.nameBuf, NAME_MAX);
            local name = S.nameBuf[1] or '';
            local ok = writer.ValidateName(name);
            if imgui.Button('Create', { BUTTON_W, 0 }) and ok and (#name > 0)
                and (not NameInUse(name)) then
                CreateSet(name);
                imgui.CloseCurrentPopup();
            end
            imgui.SameLine();
            if imgui.Button('Cancel', { BUTTON_W, 0 }) then
                imgui.CloseCurrentPopup();
            end
            imgui.EndPopup();
        end
    elseif (cur == nil) then
        imgui.TextDisabled('Pick a set on the left.');
        if (topLevelSets == 0) then
            imgui.Spacing();
            imgui.TextWrapped('These sets are built by code when the profile loads, so they are read only. New still adds a normal set to the file.');
        end
    elseif (cur.kind == 'group') then
        DrawSetHeader(cur, false);
        imgui.Separator();
        DrawGroup(cur, 0);
    elseif (cur.kind == 'oddity') or (cur.kind == 'textonly') then
        DrawSetHeader(cur, false);
        imgui.Separator();
        if (cur.sourceSlice ~= nil) then
            imgui.TextWrapped('Raw entry text:');
            imgui.BeginChild('##raw', { 0, 0 }, ImGuiChildFlags_Borders);
            imgui.TextUnformatted(cur.sourceSlice);
            imgui.EndChild();
        else
            imgui.TextDisabled('Nothing to show here.');
        end
    else
        local editable = prof.IsEditable(S.model, cur);

        --[[
        * Centered in its column, so the space above the set name matches the space
        * under whatever the last panel is.
        *
        * Half the spare space above and half below is what makes those two equal, and
        * it is also what keeps a scrollbar away: the block can never end past the
        * bottom, so the column never scrolls, so the width never changes, so the
        * wrapped text in the capsule never changes height. That last chain is what
        * made an earlier version drift a pixel a frame.
        *
        * The margin is the floor rather than the value, so a block taller than the
        * column still clears the top edge.
        *
        * The trade, stated plainly: the height is the whole block, so a set with
        * less under it sits a little lower. Centering and staying put cannot both be
        * had, and equal margins is the call.
        --]]
        local availW, availH = imgui.GetContentRegionAvail();
        local padX = math.floor(math.max(0, (availW - grid.GridWidth()) * 0.5));
        local padY = math.floor(math.max(BLOCK_MARGIN,
            (availH - (S.viewBlockH or 0)) * 0.5));
        -- The cursor rather than a Dummy, which would add its own trailing spacing
        -- and leave the bottom gap a few pixels short of the top one.
        imgui.SetCursorPosY(imgui.GetCursorPosY() + padY);
        -- Indent rather than a cursor set per element: it moves every line that
        -- follows, including the ones inside the detail panel and the capsule.
        if (padX > 0) then
            imgui.Indent(padX);
        end
        local blockTop = imgui.GetCursorPosY();

        DrawSetHeader(cur, editable);
        local ghosts = EffectiveBaseSlots(cur);
        --[[
        * A set opens with its first slot already picked, so the panel beside the
        * grid is never an empty box explaining itself. Seeded once per set rather
        * than every frame, or Done could never close the panel.
        --]]
        if editable and (S.seededFor ~= cur.name) then
            S.seededFor = cur.name;
            -- The slot you were on, not the first one. Comparing the same slot
            -- across sets is most of what this window is for, and being thrown
            -- back to Main every time made that a chore.
            grid.OpenSlot(cur, picker.AimedAt() or GridLayout[1][1]);
        end
        for _, row in ipairs(GridLayout) do
            for c, slotName in ipairs(row) do
                if (c > 1) then
                    imgui.SameLine();
                end
                imgui.PushID('slot' .. slotName);
                DrawSlotCell(cur, slotName, editable, ghosts);
                imgui.PopID();
            end
        end

        --[[
        * Directly under the grid and before anything else, so the four actions are
        * always in the same place whatever the panel below is showing. Sized from the
        * grid's own cell, so each lands under one column.
        *
        * A few pixels of air above and below them. Against the grid on one side and
        * the augments bar on the other they read as part of both.
        --]]
        picker.DrawSlotActions(grid.CellSize());
        DrawDetailPanel(cur, editable);
        DrawFilterOffer();
        S.viewBlockH = imgui.GetCursorPosY() - blockTop;
        if (padX > 0) then
            imgui.Unindent(padX);
        end
    end
    imgui.EndChild();
end

local function DrawSetsTab()
    local originX = imgui.GetCursorScreenPos();
    local rowW, rowH = imgui.GetContentRegionAvail();
    local usable = rowW - (SPLITTER_W * 2);
    local setListW, setViewW, pickerW = M.ColumnWidths(usable, S.splitA, S.splitB);
    DrawSetListColumn(setListW);

    S.splitA = Splitter('##splitA', originX, usable, rowH, S.splitA,
        SETLIST_MIN / usable, 1.0 - ((SETVIEW_MIN + PICKER_MIN) / usable));

    DrawSetViewColumn(setViewW);

    S.splitB = Splitter('##splitB', originX, usable, rowH, S.splitB,
        S.splitA + (SETVIEW_MIN / usable), 1.0 - (PICKER_MIN / usable));

    -- The picker lives here rather than in a window of its own: as a window it reopened
    -- per slot and lost any docking, because a changing title is a different window to
    -- ImGui.
    imgui.BeginChild('##pickerpanel', { pickerW, 0 }, ImGuiChildFlags_Borders);
    picker.DrawPanel();
    imgui.EndChild();

    -- Promoted here rather than inside picker, which cannot see the editing state without
    -- a require cycle. The grid picks it up on the next frame, which is soon enough
    -- because a drag lasts until the button comes up.
    if (S.drag == nil) then
        local dragged = picker.TakePendingDrag();
        if (dragged ~= nil) then
            S.drag = { fromPicker = true, name = dragged.name, iconId = dragged.id };
        end
    end

    -- Kept only while the addon is loaded, so the columns stay where you dragged
    -- them for the session and start even again on the next reload.
    if (S.splitA ~= S.splitSaved.a) or (S.splitB ~= S.splitSaved.b) then
        S.splitSaved.a, S.splitSaved.b = S.splitA, S.splitB;
        if (S.config ~= nil) and (S.config.split_a ~= nil) then
            S.config.split_a[1] = S.splitA;
            S.config.split_b[1] = S.splitB;
        end
    end
end

--[[
* The Rules tab's handler source, chopped into clickable segments once and kept.
* Rebuilt only when the analysis changes, since doing this per frame would re-scan
* every handler in the profile on the way to drawing a few lines of text.
--]]
local function BuildRulesCache()
    local cache = {};
    for _, h in ipairs(S.analysis.handlers) do
        local lines = {};
        for line in string.gmatch(h.source .. '\n', '([^\n]*)\n') do
            line = string.gsub(line, '\r$', '');
            line = string.gsub(line, '\t', '    ');
            local segments = {};
            local pos = 1;
            while true do
                local bestS, bestE, bestName = nil, nil, nil;
                local s1, e1, n1 = string.find(line, '%f[%w_]sets%s*%.%s*([%w_]+)', pos);
                if (s1 ~= nil) then
                    bestS, bestE, bestName = s1, e1, n1;
                end
                local s2, e2, n2 = string.find(line,
                        '%f[%w_]sets%s*%[%s*[\'"]([^\'"]+)[\'"]%s*%]', pos);
                if (s2 ~= nil) and ((bestS == nil) or (s2 < bestS)) then
                    bestS, bestE, bestName = s2, e2, n2;
                end
                local s3, e3, n3 = string.find(line, 'EquipSet%s*%(%s*[\'"]([^\'"]+)[\'"]', pos);
                if (s3 ~= nil) and ((bestS == nil) or (s3 < bestS)) then
                    bestS, bestE, bestName = s3, e3, n3;
                end
                if (bestS == nil) then
                    if (pos <= #line) then
                        table.insert(segments, { text = string.sub(line, pos) });
                    end
                    break;
                end
                if (bestS > pos) then
                    table.insert(segments, { text = string.sub(line, pos, bestS - 1) });
                end
                local resolved = rules.ResolveRef(S.model, { name = bestName, kind = 'field' });
                table.insert(segments, {
                    text = string.sub(line, bestS, bestE),
                    ref = bestName,
                    resolved = resolved,
                });
                pos = bestE + 1;
            end
            table.insert(lines, segments);
        end
        cache[h.name] = lines;
    end
    S.rulesCache = cache;
end

local function JumpToSet(name)
    local target = prof.FindSet(S.model, name) or prof.FindSet(S.model, name .. '_Priority');
    if (target ~= nil) then
        S.selected = target.name;
        S.detailSel = nil;
    end
end

-- First of these names that the profile actually has, so the three dropdowns open on
-- something sensible without the addon insisting on a naming convention.
local function GuessSet(names)
    for _, want in ipairs(names) do
        local s = prof.FindSet(S.model, want);
        if (s ~= nil) and (s.kind == 'set') then
            return s.name;
        end
    end
    return nil;
end

-- Every set that could be wired, plus a way to choose none.
local function WirableNames()
    local out = { '(none)' };
    for _, s in ipairs(S.model.sets) do
        if (s.kind == 'set') and (not s.deleted) then
            table.insert(out, s.name);
        end
    end
    return out;
end

--[[
* The dialog behind Set Up All Three. It writes a HandleDefault that wears one set
* resting, one fighting and one otherwise, which is the shape almost every profile
* starts from.
--]]
local function DrawWireSetupPopup()
    if (S.wireSetup == nil) then
        return;
    end
    imgui.OpenPopup('Set Up HandleDefault##lsv');
    CenterNextPopup();
    if imgui.BeginPopupModal('Set Up HandleDefault##lsv', nil,
        ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Set Up HandleDefault');
        imgui.Text('Which set do you want to wear when:');
        imgui.Spacing();

        local names = WirableNames();
        local function Row(label, key)
            imgui.AlignTextToFramePadding();
            imgui.Text(label);
            imgui.SameLine(90);
            imgui.SetNextItemWidth(200);
            if imgui.BeginCombo('##wire' .. key, S.wireSetup[key] or '(none)') then
                for _, n in ipairs(names) do
                    local chosen = (n == '(none)') and (S.wireSetup[key] == nil)
                        or (n == S.wireSetup[key]);
                    if imgui.Selectable(n, chosen) then
                        S.wireSetup[key] = (n ~= '(none)') and n or nil;
                    end
                end

        --[[
        * Rescanning belongs in the list rather than beside it: you find out the
        * list is stale by opening it and not seeing your file, and this is where
        * you already are at that moment.
        --]]
        imgui.Separator();
        if imgui.Selectable('Refresh list##profilerefresh', false) then
            M.RefreshDiscovery();
            if (S.model ~= nil) then
                M.RequestOpen(S.model.path);
            end
        end
                imgui.EndCombo();
            end
        end
        Row('Resting', 'resting');
        Row('Fighting', 'engaged');
        Row('Otherwise', 'idle');

        imgui.Spacing();
        imgui.TextDisabled('This replaces what HandleDefault does now.');
        imgui.Spacing();

        local any = (S.wireSetup.idle ~= nil) or (S.wireSetup.resting ~= nil)
            or (S.wireSetup.engaged ~= nil);
        if imgui.Button('Write It', { 110, 0 }) and any then
            local span = S.wireSetup.span;
            local block = writer.DefaultHandlerBlock(S.wireSetup.idle, S.wireSetup.resting,
                S.wireSetup.engaged, S.model.eol);
            S.wireSetup = nil;
            if (span ~= nil) and (block ~= nil) then
                -- The span runs up to the closing end's own line, so the body has to end
                -- in a line break or that end would land on the last gear line.
                FinishSave(S.model.textAtLoad, { { op = 'replacespan', s = span.s, e = span.e,
                    text = block .. S.model.eol } });
                S.analysis = nil;
                S.rulesCache = nil;
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            S.wireSetup = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

--[[
* Everything the addon can tell about the profile without running it. Sections
* rather than a tab, in the column that already lists the whole profile, so a
* dead set reference is visible without going to look for it.
--]]

--[[
* Reading the framework includes off disk is the one part of this that touches the
* world, so it is separated from the drawing. Which helpers read the current action
* is learned from the includes rather than hardcoded, so it stays true the day
* BasicLuas adds a third. Cached until an edit invalidates it.
*
* Returns false when it could not read them, having already said so on screen.
--]]
local function EnsureAnalysis()
    if (S.analysis ~= nil) then
        return true;
    end

    local helpers = {};
    local okFw, texts = pcall(function()
        local dir = string.match(S.model.path or '', '^(.*[\\/])');
        return us.ReadFrameworkFiles(S.model.textAtLoad, items.LacRoot(), dir);
    end);
    if okFw then
        for _, body in ipairs(texts) do
            for name in pairs(rules.HelpersNeedingAction(body)) do
                helpers[name] = true;
            end
        end
    end

    -- An uncaught error in the render callback unloads the addon outright.
    local ok, analysis = pcall(rules.Analyze, S.model, helpers);
    if (not ok) then
        imgui.TextWrapped('Could not read the rules: ' .. tostring(analysis));
        return false;
    end
    S.analysis = analysis;
    BuildRulesCache();
    return true;
end

--[[
* Every finding reads the same way: what it is in plain text, then where it is in
* dim text beside it. The eye goes down the names and only drops to the line
* numbers when one of them matters.
--]]
local function FindingRow(name, where, dim)
    if dim then
        imgui.TextDisabled(name);
    else
        imgui.Text(name);
    end
    if (where ~= nil) then
        imgui.SameLine();
        imgui.TextDisabled(where);
    end
end

local function FindingHead(color, title, hint)
    imgui.TextColored(color, title);
    imgui.SameLine();
    theme.Hint(hint);
end

--[[
* A fix button leads its row rather than trailing it. On a wide window a trailing
* button ends up far from the name it belongs to, and on a narrow one it is the
* first thing the column clips, which is the half that actually loses the feature.
--]]
local CREATE_SET = 'Create This Set';
local WIRE_SET = 'Use in HandleDefault';

local function FindingGutter(label)
    return imgui.CalcTextSize(label) + theme.SMALL_BUTTON_PAD + theme.ROW_GAP * 4;
end

--[[
* The quietest way a profile can be broken. The sets look right, the addon draws
* them, and in game those slots simply never swap, because only EvaluateLevels
* collapses a ladder and this file never calls it. Our own demo profile sat like
* this with 31 of them and reported nothing at all.
--]]
local function DrawDeadLadders()
    local ladders = S.analysis.deadLadders or {};
    if (#ladders == 0) then
        return;
    end
    FindingHead(theme.col.danger, 'Slots That Equip Nothing',
        'These sets list several pieces in one slot, but this\n'
        .. 'file never calls gFunc.EvaluateLevels, so the game\n'
        .. 'equips nothing at all in those slots.');
    imgui.Indent();
    for _, dl in ipairs(ladders) do
        FindingRow(dl.set, string.format('%d slot%s', dl.ladders,
            (dl.ladders == 1) and '' or 's'));
    end
    imgui.Unindent();
    imgui.Spacing();
end

local function DrawTypos()
    if (#S.analysis.typos == 0) then
        return;
    end
    FindingHead(theme.col.danger, 'Matches No Set',
        'Your code asks for these sets,\nbut this file has none of them.\nNothing swaps. Usually a typo.');
    --[[
    * Whether a row earns a button is decided before any of them draw, so the names
    * still line up under each other when only some rows have one. The label is a
    * constant, so the gutter is a fixed width rather than anything measured off the
    * rows, which is what keeps it from moving as the column resizes.
    --]]
    local editableProfile = prof.IsEditable(S.model, nil);
    local creatable, anyButton = {}, false;
    for i, t in ipairs(S.analysis.typos) do
        creatable[i] = editableProfile and (t.kind ~= 'prefix')
            and (string.find(t.name, '.', 1, true) == nil)
            and writer.ValidateName(t.name) and (not NameInUse(t.name));
        anyButton = anyButton or creatable[i];
    end
    local gutter = anyButton and FindingGutter(CREATE_SET) or 0;

    imgui.Indent();
    for i, t in ipairs(S.analysis.typos) do
        local left = imgui.GetCursorPosX();
        if creatable[i] then
            imgui.PushID('mktypo' .. i);
            if imgui.SmallButton(CREATE_SET) then
                CreateSet(t.name);
                S.analysis = nil;
                S.rulesCache = nil;
            end
            imgui.PopID();
            imgui.SameLine();
        end
        -- Never backwards, so a button wider than the gutter allows for cannot end up
        -- with the name painted over it.
        imgui.SetCursorPosX(math.max(imgui.GetCursorPosX(), left + gutter));
        FindingRow(t.name, string.format('line %d, in %s', t.line, t.handler));
    end
    imgui.Unindent();
    imgui.Separator();
end

--[[
* Listed before the merely suspect findings because it is the only one that is
* already broken: it throws once per frame from the moment the profile loads. It
* cost a real user an evening, with CheckCancels sitting in HandleDefault.
--]]
local function DrawActionless()
    local actionless = S.analysis.actionless or {};
    if (#actionless == 0) then
        return;
    end
    FindingHead(theme.col.danger, 'Errors Every Frame',
        'These read your current action\nfrom a handler that has no action.\nThe game errors every frame.');
    imgui.Indent();
    for _, a in ipairs(actionless) do
        FindingRow(a.what, string.format('line %d, in %s', a.line, a.handler));
    end
    imgui.Unindent();
    theme.WrapText('Move it to HandlePrecast or HandleAbility, or remove it.');
    imgui.Separator();
end

local function DrawBadLevelCalls()
    local bad = S.analysis.badLevelCalls or {};
    if (#bad == 0) then
        return;
    end
    FindingHead(theme.col.danger, 'Priority Lists Never Run',
        'There is no gData.EvaluateLevels,\nso _Priority sets are unused.\nThe tutorial got this wrong.');
    imgui.Indent();
    for _, b in ipairs(bad) do
        FindingRow('gData should be gFunc', string.format('line %d', b.line));
    end
    imgui.Unindent();
    if prof.IsEditable(S.model, nil) and (not HasUnsaved()) then
        imgui.PushID('fixlevelcall');
        if imgui.SmallButton('Fix the Name') then
            FinishSave(S.model.textAtLoad, { { op = 'fixlevelcall' } });
            S.analysis = nil;
            S.rulesCache = nil;
        end
        imgui.PopID();
    elseif HasUnsaved() then
        theme.WrapText('Save your equipment changes first.');
    end
    imgui.Separator();
end

local function DrawUnusedSets()
    if (#S.analysis.dead == 0) then
        return;
    end
    imgui.TextDisabled('Possibly Unused');
    imgui.SameLine();
    theme.Hint('Nothing in this file mentions them.\nAnother file might.');
    if (S.analysis.handsOff ~= nil) then
        theme.WrapText('Probably equipped by ' .. S.analysis.handsOff .. '.');
    end

    --[[
    * body is the span of HandleDefault when it holds nothing but gear lines, empty
    * included. The per set button needs it empty, because a second unconditional
    * line would just override the first. The three state setup does not, since it
    * rewrites the whole body and carries what was already wired into Otherwise.
    --]]
    local body = nil;
    if prof.IsEditable(S.model, nil) and (not HasUnsaved()) then
        local okBody, found = pcall(rules.SimpleHandlerBody,
            S.model.textAtLoad, 'HandleDefault');
        if okBody then
            body = found;
        end
    end
    local wireAt = (body ~= nil) and (not body.branched) and (#body.equips == 0)
        and body.s or nil;

    imgui.Indent();
    for i, deadName in ipairs(S.analysis.dead) do
        if (wireAt ~= nil) then
            imgui.PushID('wire' .. i);
            if imgui.SmallButton(WIRE_SET) then
                FinishSave(S.model.textAtLoad, { { op = 'insertline', at = wireAt,
                    line = '    gFunc.EquipSet(' .. writer.SetRef(deadName) .. ');' } });
                S.analysis = nil;
                S.rulesCache = nil;
            end
            imgui.PopID();
            imgui.SameLine();
        end
        FindingRow(deadName, nil, true);
    end
    imgui.Unindent();
    -- One set can be worn unconditionally; the rest need to say when. This offers the
    -- three state shape the ecosystem already writes, rather than leaving somebody
    -- with one wired set and no way to use the others.
    if (body ~= nil) then
        if imgui.SmallButton('Set Up All Three') then
            -- A set already wired unconditionally is the one worn the rest of the
            -- time, so it opens in Otherwise rather than being thrown away.
            -- What the file already says beats guessing from set names, so the
            -- dialog opens on the branches that are there rather than proposing
            -- new ones over the top of them.
            local was = body.byStatus or {};
            local unconditional = (not body.branched) and body.equips[1] or nil;
            S.wireSetup = {
                idle = body.otherwise or unconditional or GuessSet({ 'Idle' }),
                resting = was.Resting or GuessSet({ 'Resting' }),
                engaged = was.Engaged
                    or GuessSet({ 'Tp_Default', 'Tp', 'Engaged', 'TP_Default' }),
                span = body,
            };
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Wear one set resting,\none fighting, and one otherwise.');
        end
    end
    -- Deliberately silent when HandleDefault holds real logic: every finished
    -- profile does, so a line here fired for everyone.
    imgui.Separator();
end

-- Ordered by whether the finding is already broken rather than merely suspect.
local FindingSections = {
    DrawDeadLadders, DrawTypos, DrawActionless, DrawBadLevelCalls, DrawUnusedSets,
};

function DrawRuleFindings()
    if (S.model == nil) then
        return;
    end
    if (not EnsureAnalysis()) then
        return;
    end

    --[[
    * Collapsed, and the same way the unowned panel is: closed whenever the profile
    * changes, because ImGui keeps header state in memory only and this sits above
    * the set list, which is the column you scroll most.
    *
    * The count is of the four findings that name something wrong. Show Handlers is
    * under here too, so the header draws even at zero.
    --]]
    local faults = #S.analysis.typos + #(S.analysis.actionless or {})
        + #(S.analysis.badLevelCalls or {}) + #(S.analysis.deadLadders or {})
        + #S.analysis.dead;
    local errors = #S.analysis.typos + #(S.analysis.actionless or {})
        + #(S.analysis.badLevelCalls or {}) + #(S.analysis.deadLadders or {});
    --[[
    * Green when there is nothing to do, and a set nothing in this file mentions counts
    * as nothing to do once the profile hands its sets off to another one: that is the
    * Probably equipped by line, and 92% of these findings across the corpus have it.
    *
    * Amber is the middle: unused sets with no such explanation, which is worth a look
    * and is not broken. Red stays for the three that are.
    --]]
    local headColor = theme.col.accent;
    if (errors > 0) then
        headColor = theme.col.danger;
    elseif (#S.analysis.dead > 0) and (S.analysis.handsOff == nil) then
        headColor = theme.col.caution;
    end
    if (S.rulesFor ~= S.model.path) then
        S.rulesFor = S.model.path;
        imgui.SetNextItemOpen(false, ImGuiCond_Always);
    end
    imgui.PushStyleColor(ImGuiCol_Text, headColor);
    local rulesOpen = imgui.CollapsingHeader(
        string.format('Profile Checks (%d)###lsvrules', faults));
    imgui.PopStyleColor();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('What the addon can check in this profile\n'
            .. 'without running it.');
    end
    if (not rulesOpen) then
        return;
    end

    --[[
    * Any of these can write to the file and blank the analysis the next one would
    * read, so the check sits here once rather than at the foot of each block that
    * happens to carry a button today.
    --]]
    for _, DrawSection in ipairs(FindingSections) do
        DrawSection();
        if (S.analysis == nil) then
            return;
        end
    end

    --[[
    * The profile's own code, under the findings that describe it. Nested one
    * level down because it is reference rather than a fault: you open it to
    * read what a handler does, not because something is wrong.
    --]]
    -- Colored apart from the handler names under it, which are headers of the same
    -- shape: in plain text it read as the first of them rather than their title.
    if (S.handlerCodeEpoch ~= S.openEpoch) then
        S.handlerCodeEpoch = S.openEpoch;
        imgui.SetNextItemOpen(false, ImGuiCond_Always);
    end
    imgui.PushStyleColor(ImGuiCol_Text, theme.col.caution);
    local handlersOpen = imgui.CollapsingHeader('Handler Code###lsvhandlers');
    imgui.PopStyleColor();
    if handlersOpen then
        DrawHandlerBrowser();
    end
end


--[[
* The handlers that fire on an action, so a bare EquipSet is the whole correct
* answer in them. HandleDefault is deliberately absent: it runs every frame, so an
* unconditional line means always and a second one silently overrides the first.
--]]
local ActionHandlers = {
    HandleWeaponskill = true, HandlePrecast = true, HandleMidcast = true,
    HandleAbility = true, HandleItem = true, HandlePreshot = true, HandleMidshot = true,
};

-- Offers to wear a set in a handler that is empty, which is what a fresh profile's are.
local function DrawWearHere(name)
    if (not ActionHandlers[name]) or (S.model == nil) then
        return false;
    end
    if (not prof.IsEditable(S.model, nil)) or HasUnsaved() then
        return false;
    end
    local okAt, at = pcall(rules.EmptyHandlerInsertPoint, S.model.textAtLoad, name);
    if (not okAt) or (at == nil) then
        return false;
    end

    -- One control with the label inside it; a caption beside a box did not fit the column.
    local wrote = false;
    imgui.SetNextItemWidth(math.min(180, imgui.GetContentRegionAvail()));
    if imgui.BeginCombo('##wear' .. name, 'Wear a set here') then
        for _, s in ipairs(S.model.sets) do
            if (s.kind == 'set') and (not s.deleted) then
                if imgui.Selectable(s.name .. '##wear' .. name) then
                    FinishSave(S.model.textAtLoad, { { op = 'insertline', at = at,
                        line = '    gFunc.EquipSet(' .. writer.SetRef(s.name) .. ');' } });
                    S.analysis = nil;
                    S.rulesCache = nil;
                    wrote = true;
                end
            end
        end
        imgui.EndCombo();
    end
    return wrote;
end

--[[
* The handler source, with every set it names clickable. Its own window because
* it is the widest thing here and a column cannot hold a line of code.
--]]
function DrawHandlerBrowser()
    if (#S.analysis.handlers == 0) then
        imgui.TextDisabled('No handler functions found.');
    end

    S.handlerEpoch = S.handlerEpoch or {};
    for _, h in ipairs(S.analysis.handlers) do
        if (S.handlerEpoch[h.name] ~= S.openEpoch) then
            S.handlerEpoch[h.name] = S.openEpoch;
            imgui.SetNextItemOpen(false, ImGuiCond_Always);
        end
        if imgui.CollapsingHeader(h.name .. '##rules') then
            -- The write invalidates the analysis this loop is walking, so the frame
            -- ends here and the next one draws from a freshly read file.
            if DrawWearHere(h.name) then
                return;
            end
            local chipNames = {};
            local chipSeen = {};
            for _, r in ipairs(h.refs) do
                if (r.resolved ~= nil) and (r.resolved.name ~= nil)
                    and (not chipSeen[r.resolved.name]) then
                    chipSeen[r.resolved.name] = true;
                    table.insert(chipNames, r.resolved.name);
                end
            end
            if (#chipNames > 0) then
                imgui.TextDisabled('Uses:');
                for _, n in ipairs(chipNames) do
                    imgui.SameLine();
                    if imgui.SmallButton(n .. '##chip' .. h.name) then
                        JumpToSet(n);
                    end
                end
            end
            local lines = S.rulesCache and S.rulesCache[h.name] or nil;
            if (lines ~= nil) then
                -- Boxed on its own darker ground so it reads as the profile's code.
                -- The scrollbar is the point: a code line is wider than this column.
                if (not compat.StaleLibs) then
                    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 4.0);
                    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 6 });
                end
                imgui.PushStyleColor(ImGuiCol_ChildBg, theme.col.codeBg);
                imgui.BeginChild('##src' .. h.name, { 0, 0 },
                    bit.bor(ImGuiChildFlags_Borders, ImGuiChildFlags_AutoResizeY,
                        ImGuiChildFlags_AlwaysUseWindowPadding),
                    ImGuiWindowFlags_HorizontalScrollbar);
                for li, segments in ipairs(lines) do
                    if (#segments == 0) then
                        imgui.Dummy({ 1, imgui.GetTextLineHeight() });
                    else
                        for si, seg in ipairs(segments) do
                            if (si > 1) then
                                imgui.SameLine(0, 0);
                            end
                            if (seg.ref ~= nil) then
                                -- Green against red, because the whole point of
                                -- the line is which names actually reach a set.
                                local color = (seg.resolved ~= nil)
                                    and theme.col.accent or theme.col.danger;
                                imgui.TextColored(color, seg.text);
                                if imgui.IsItemHovered() then
                                    imgui.SetTooltip((seg.resolved ~= nil)
                                        and 'Click to open this set' or 'No set with this name');
                                end
                                if imgui.IsItemClicked(0) and (seg.resolved ~= nil) then
                                    JumpToSet(seg.resolved.name or seg.ref);
                                end
                            else
                                imgui.TextUnformatted(seg.text);
                            end
                        end
                    end
                end
                imgui.EndChild();
                imgui.PopStyleColor();
                if (not compat.StaleLibs) then
                    imgui.PopStyleVar(2);
                end
            end
        end
    end
end

-- True when the open file's name is not one LuAshitacast could ever load as a profile,
-- which is the one thing the filename can say for certain.
--[[
* A standing note about the open file, as opposed to a passing status. It rides in
* the same place, so nothing about the file ever takes a line of its own above the
* tabs. A real status outranks it, since that one is answering something you did.
--]]
local function StandingNote()
    if (S.model == nil) then
        return nil;
    end
    local notices = S.model.notices or {};
    if (#notices > 0) then
        local note = notices[1];
        if (#notices > 1) then
            note = note .. ' (+' .. (#notices - 1) .. ')';
        end
        return note;
    end
    -- Ranked by what stops you doing something. Read only outranks the include
    -- warning, since a file you cannot edit cannot reach anything either.
    if (S.model.kind ~= 'native') and (S.model.kind ~= 'basiclua') then
        return 'Read only.';
    end
    return nil;
end


--[[
* The profile dropdown. Discovery is refreshed lazily on first open rather than at
* load, because listing the folder costs a disk walk nobody has asked for yet.
--]]
local function DrawProfileCombo()
    local label = (S.model ~= nil) and S.model.filename or 'Pick a profile';
    imgui.SetNextItemWidth(PROFILE_COMBO_W);
    --[[
    * Large rather than the default, which shows eight rows. It still shrinks to
    * fit when there are fewer, so a character with two profiles gets two rows.
    *
    * A brighter edge than the rest of the window uses, because this list opens
    * over the set list and the two were near enough in shade to read as one.
    --]]
    imgui.PushStyleColor(ImGuiCol_Border, theme.col.popupEdge);
    if imgui.BeginCombo('##profilecombo', label, ImGuiComboFlags_HeightLarge) then
        if (S.discovery == nil) then
            M.RefreshDiscovery();
        end
        local function Section(title, list)
            if (#list > 0) then
                imgui.TextDisabled(title);
                for _, e in ipairs(list) do
                    if imgui.Selectable(e.label .. '##p' .. e.path,
                        (S.model ~= nil) and (S.model.path == e.path)) then
                        M.RequestOpen(e.path);
                    end
                    if (S.activePath ~= nil) and (e.path == S.activePath) then
                        imgui.SameLine();
                        imgui.TextDisabled('In use');
                    end
                end
            end
        end
        Section('Your Profiles', S.discovery.yours);
        Section('Other Files', S.discovery.others);
        if (#S.discovery.unsupported > 0) then
            imgui.TextDisabled('Not Loadable (Old XML)');
            for _, e in ipairs(S.discovery.unsupported) do
                imgui.TextDisabled('  ' .. e.label);
            end
        end
        imgui.EndCombo();
    end
    imgui.PopStyleColor();
end

--[[
* Asked when opening another profile would throw away edits.
--]]
local function DrawUnsavedModal()
    if (S.pendingOpenPath ~= nil) then
        imgui.OpenPopup('Unsaved Changes##lsv');
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('Unsaved Changes##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Unsaved Changes');
        imgui.Text('This profile has unsaved changes.');
        local saveW = math.max(CHOICE_W,
            imgui.CalcTextSize('Save Them First') + imgui.GetFrameHeight());
        if imgui.Button('Save Them First', { saveW, 0 }) then
            S.afterSaveOpen = S.pendingOpenPath;
            S.pendingOpenPath = nil;
            StartSave();
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Discard Them', { CHOICE_W, 0 }) then
            local target = S.pendingOpenPath;
            S.pendingOpenPath = nil;
            M.OpenProfile(target);
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { BUTTON_W, 0 }) then
            S.pendingOpenPath = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

--[[
* Asked when the file changed on disk under an open profile.
--]]
local function DrawFileChangedModal()
    if (S.conflictNames ~= nil) then
        imgui.OpenPopup('File Changed##lsv');
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('File Changed##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('File Changed');
        imgui.TextWrapped('The file changed on disk since it was opened, and these sets changed in both places:');
        imgui.Text('  ' .. table.concat(S.conflictNames or {}, ', '));
        imgui.TextWrapped('Saving now overwrites the disk version of those sets with yours.');
        local mineW = math.max(CHOICE_W,
            imgui.CalcTextSize('Save Mine Anyway') + imgui.GetFrameHeight());
        local cancelW = math.max(CHOICE_WIDE_W,
            imgui.CalcTextSize('Cancel, Keep Editing') + imgui.GetFrameHeight());
        if imgui.Button('Save Mine Anyway', { mineW, 0 }) then
            S.conflictNames = nil;
            if (S.pendingSave ~= nil) then
                if (#S.pendingSave.warnable > 0) then
                    S.warnItems = S.pendingSave.warnable;
                else
                    local ps = S.pendingSave;
                    S.pendingSave = nil;
                    FinishSave(ps.text, ps.edits);
                end
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel, Keep Editing', { cancelW, 0 }) then
            S.conflictNames = nil;
            S.pendingSave = nil;
            S.afterSaveOpen = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

--[[
* The slot by slot summary of what a save is about to write.
--]]
local function DrawBeforeSavingModal()
    if (S.warnItems ~= nil) then
        imgui.OpenPopup('Before Save##lsv');
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('Before Save##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Before Save');
        imgui.Text('About to write into '
            .. ((S.model ~= nil) and S.model.filename or 'the file') .. ':');
        imgui.Spacing();
        for _, w in ipairs(S.warnItems or {}) do
            imgui.Checkbox(w.name .. '##warn', w.include);
            for _, l in ipairs(w.lines or {}) do
                imgui.TextColored(theme.col.textDim, '    ' .. l);
            end
            for _, r in ipairs(w.reasons or {}) do
                imgui.TextColored(theme.col.caution, '    ' .. r);
            end
        end
        imgui.Spacing();
        imgui.TextWrapped('Unchecked sets are skipped. The rest of the file is untouched, and a backup is made first.');
        if imgui.Button('Save', { CONFIRM_W, 0 }) then
            S.warnItems = nil;
            ContinueSaveAfterWarn();
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel', { CONFIRM_W, 0 }) then
            S.warnItems = nil;
            S.pendingSave = nil;
            S.afterSaveOpen = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

--[[
* The backups this addon has taken of the open profile, newest first.
--]]
local function DrawBackupsModal()
    if S.showBackups and (S.model ~= nil) then
        imgui.OpenPopup('Backups##lsv');
        S.showBackups = false;
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('Backups##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Backups');
        if (S.backupList == nil) and (S.model ~= nil) then
            S.backupList = items.ListBackups(S.model.filename);
        end
        local list = S.backupList or {};
        if (#list == 0) then
            imgui.Text('No backups of '
                .. ((S.model ~= nil) and S.model.filename or '') .. ' yet.');
            imgui.TextDisabled('One is made every time you save.');
        else
            imgui.Text('Backups of ' .. S.model.filename .. ', newest first.');
            imgui.TextDisabled('Restoring backs up the current file.');
            if HasUnsaved() then
                imgui.TextColored(theme.col.caution, 'Restore discards unsaved edits.');
            end
            imgui.Spacing();
            local restored = false;
            for i, b in ipairs(list) do
                if (i <= 12) and (not restored) then
                    imgui.Text(b.stamp);
                    imgui.SameLine();
                    imgui.PushID('bk' .. i);
                    if imgui.SmallButton('Restore') then
                        local content = items.ReadFile(b.path);
                        local current = (S.model ~= nil) and items.ReadFile(S.model.path) or nil;
                        if (content == nil) then
                            Status('Could not read that backup', 'error');
                        else
                            local okB = true;
                            if (current ~= nil) then
                                okB = items.BackupProfile(
                                    { filename = S.model.filename, textAtLoad = current },
                                    S.lacSettings);
                            end
                            if (not okB) then
                                Status('Could not back up, restore stopped', 'error');
                            elseif items.WriteFile(S.model.path, content) then
                                local p = S.model.path;
                                M.OpenProfile(p);
                                S.reloadArmed = true;
                                Status('Restored ' .. b.stamp, 'good');
                                restored = true;
                            else
                                Status('Could not write the restore', 'error');
                            end
                        end
                    end
                    imgui.PopID();
                end
            end
            if restored then
                S.backupList = nil;
                imgui.CloseCurrentPopup();
            elseif (#list > 12) then
                imgui.TextDisabled((#list - 12) .. ' older backups hidden.');
            end
        end
        imgui.Spacing();
        if imgui.Button('Close', { BUTTON_W, 0 }) then
            S.backupList = nil;
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

--[[
* Two sets side by side, with the slots that differ in orange.
--]]
local function DrawCompareModal()
    if S.showCompare and (S.model ~= nil) then
        imgui.OpenPopup('Compare Sets##lsv');
        S.showCompare = false;
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('Compare Sets##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Compare Sets');
        local a = SelectedSet();
        if (a == nil) or (a.slots == nil) then
            imgui.Text('Pick a set first.');
        else
            imgui.AlignTextToFramePadding();
            imgui.Text(a.name);
            imgui.SameLine();
            imgui.TextDisabled('next to');
            imgui.SameLine();
            imgui.SetNextItemWidth(220);
            if imgui.BeginCombo('##cmpwith', S.compareWith or 'Pick a Set') then
                for _, s in ipairs(S.model.sets) do
                    if (not s.deleted) and (s.name ~= a.name) and (s.slots ~= nil) then
                        if imgui.Selectable(s.name .. '##cmp' .. s.name,
                            S.compareWith == s.name) then
                            S.compareWith = s.name;
                        end
                    end
                end
                imgui.EndCombo();
            end
            local b = (S.compareWith ~= nil) and prof.FindSet(S.model, S.compareWith) or nil;
            if (b ~= nil) and (b.slots ~= nil) then
                imgui.Spacing();
                imgui.TextColored(theme.col.textFaint, string.format('%-8s', 'slot'));
                imgui.SameLine();
                imgui.SetCursorPosX(COMPARE_COL_L);
                imgui.TextColored(theme.col.textFaint, a.name);
                imgui.SameLine();
                imgui.SetCursorPosX(COMPARE_COL_R);
                imgui.TextColored(theme.col.textFaint, b.name);
                imgui.Separator();
                local diffs = 0;
                for _, slot in ipairs(prof.SlotNames) do
                    local la = EntryLabel(a.slots[slot]);
                    local lb = EntryLabel(b.slots[slot]);
                    if (la ~= nil) or (lb ~= nil) then
                        local same = (la == lb);
                        if (not same) then
                            diffs = diffs + 1;
                        end
                        local col = same and theme.col.textDim or theme.col.caution;
                        imgui.TextColored(theme.col.textFaint, slot);
                        imgui.SameLine();
                        imgui.SetCursorPosX(COMPARE_COL_L);
                        imgui.TextColored(col, la or '-');
                        imgui.SameLine();
                        imgui.SetCursorPosX(COMPARE_COL_R);
                        imgui.TextColored(col, lb or '-');
                    end
                end
                imgui.Separator();
                if (diffs == 0) then
                    imgui.TextDisabled('No differences in the filled slots.');
                else
                    imgui.TextColored(theme.col.caution, diffs .. ' slot'
                        .. ((diffs == 1) and ' differs' or 's differ')
                        .. ', shown in orange.');
                end
            end
        end
        imgui.Spacing();
        if imgui.Button('Close', { BUTTON_W, 0 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

--[[
* Everything inside the window frame: the toolbar, the tab row and whichever tab
* is showing. Split out because the caller is otherwise nothing but window setup,
* and the two have no locals in common.
--]]
-- The row across the top: which profile, what you can do to it, and what just happened.
local function DrawToolbar()
    DrawProfileCombo();
    imgui.SameLine();
    local dirtyCount = 0;
    if (S.model ~= nil) then
        for _, s in ipairs(S.model.sets) do
            if us.IsChanged(s) then
                dirtyCount = dirtyCount + 1;
            end
        end
    end
    if (dirtyCount == 0) then
        imgui.PushStyleColor(ImGuiCol_Button, theme.col.panelSoft);
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.textFaint);
        imgui.Button('Save');
        imgui.PopStyleColor(2);
    else
        imgui.PushStyleColor(ImGuiCol_Button, theme.col.accentBg);
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.accent);
        if imgui.Button('Save') then
            StartSave();
        end
        imgui.PopStyleColor(2);
    end
    if imgui.IsItemHovered() and (dirtyCount > 0) then
        imgui.SetTooltip('Shows what changes before writing.');
    end
    imgui.SameLine();
    if (#S.undoStack == 0) then
        imgui.PushStyleColor(ImGuiCol_Button, theme.col.panelSoft);
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.textFaint);
        imgui.Button('Undo');
        imgui.PopStyleColor(2);
    else
        if imgui.Button('Undo') then
            DoUndo();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Take back the last edit. ' .. #S.undoStack .. ' step' .. ((#S.undoStack == 1) and '' or 's') .. ' remembered.');
        end
    end

    imgui.SameLine();
    if (#S.redoStack == 0) then
        imgui.PushStyleColor(ImGuiCol_Button, theme.col.panelSoft);
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.textFaint);
        imgui.Button('Redo');
        imgui.PopStyleColor(2);
    else
        if imgui.Button('Redo') then
            DoRedo();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Put back what Undo took. ' .. #S.redoStack .. ' step' .. ((#S.redoStack == 1) and '' or 's') .. ' waiting.');
        end
    end

    imgui.SameLine();
    if imgui.Button('Restore') and (S.model ~= nil) then
        S.backupList = nil;
        S.showBackups = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Put an earlier version of this file back.');
    end
    imgui.SameLine();
    if imgui.Button('Rename') and (S.model ~= nil) then
        S.fileRenameBuf[1] = S.model.stem;
        S.showFileRename = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Rename this profile file.');
    end
    imgui.SameLine();
    local function TryReload()
        --[[
        * Restarting LuAshitacast needs no profile of ours: it is the same command
        * either way. Only the missing-include check needs a file open, so that is
        * what the guard covers rather than the whole button.
        --]]
        if (S.model ~= nil) then
            -- The profile's own folder first, which is where a character-folder
            -- layout keeps its common\ files.
            local profileDir = string.match(S.model.path or '', '^(.*[\\/])');
            local missing = M.MissingFrameworkFiles(S.model.textAtLoad,
                items.LacRoot(), profileDir);
            if (#missing > 0) then
                Status('Missing ' .. missing[1], 'error');
                return;
            end
        end
        items.QueueReload();
        S.reloadArmed = false;
        Status('Reloaded LuAshitacast', 'good');
    end
    if S.reloadArmed then
        imgui.PushStyleColor(ImGuiCol_Button, theme.col.accentBg);
        imgui.PushStyleColor(ImGuiCol_Text, theme.col.accent);
        if imgui.Button('Reload LuAshitacast') then
            TryReload();
        end
        imgui.PopStyleColor(2);
    else
        if imgui.Button('Reload LuAshitacast') then
            TryReload();
        end
    end
    -- Taken before the tooltip, which draws a window of its own and would leave
    -- the measurement pointing at that instead of at the button.
    local _, btnTop = imgui.GetItemRectMin();
    local btnRight, btnBottom = imgui.GetItemRectMax();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Restarts LuAshitacast and reloads\nyour saved profile.');
    end

        --[[
        * The status trails the toolbar now that there is no tab row to sit on. Same
        * rules as before: a passing status outranks a standing note about the file,
        * and nothing draws when there is nothing to say.
        --]]
        local shown, color = S.status, theme.col.textDim;
        if (shown ~= nil) then
            if (S.statusLevel == 'error') then
                color = theme.col.danger;
            elseif (S.statusLevel == 'good') then
                color = theme.col.accent;
            end
        else
            shown = StandingNote();
            color = theme.col.caution;
        end
        if (shown ~= nil) then
            --[[
            * Centered against the button's own rectangle rather than left to ImGui's
            * baseline offset, which lines text up with a frame in general and not with
            * this button in particular.
            *
            * Through the draw list because it owes nothing to layout: a long status
            * cannot widen the window, and nothing here moves the cursor.
            *
            * There is deliberately no SameLine. A SameLine with no item submitted
            * after it leaves the toolbar row open, and the next column then starts on
            * that row instead of below it. The X comes off the button's own rectangle.
            --]]
            local textX = btnRight + STATUS_GAP;
            local textY = btnTop + (((btnBottom - btnTop) - imgui.GetTextLineHeight()) * 0.5);
            imgui.GetWindowDrawList():AddText({ textX, textY },
                imgui.GetColorU32(color), shown);
        end
end

-- Renaming the file on disk, which is a different thing from renaming a set inside it.
local function DrawRenameFileDialog()
    if S.showFileRename and (S.model ~= nil) then
        imgui.OpenPopup('Rename File##lsv');
        S.showFileRename = false;
    end
    CenterNextPopup();
    if imgui.BeginPopupModal('Rename File##lsv', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        EnforcePopupCenter('Rename File');
        imgui.Text('New name for ' .. ((S.model ~= nil) and S.model.filename or '') .. ':');
        imgui.SetNextItemWidth(NAME_FIELD_W);
        imgui.InputText('##filerename', S.fileRenameBuf, FILTER_MAX);
        imgui.SameLine();
        imgui.Text('.lua');
        local stem = S.fileRenameBuf[1] or '';
        local ok, why = items.ValidFileStem(stem);
        local newPath = nil;
        if (S.model ~= nil) then
            newPath = string.gsub(S.model.path, '[^\\/]+$', '') .. stem .. '.lua';
        end
        if (#stem > 0) and (not ok) then
            imgui.TextColored(theme.col.caution, why);
        elseif (S.model ~= nil) and (string.lower(stem) ~= string.lower(S.model.stem))
            and items.FileExists(newPath) then
            ok = false;
            imgui.TextColored(theme.col.caution, 'A file with that name already exists.');
        end
        imgui.TextWrapped('The filename decides what LuAshitacast auto loads: Name_JOB.lua loads for that character and job.');
        if HasUnsaved() then
            ok = false;
            imgui.TextColored(theme.col.caution, 'Save first; renaming reopens the file.');
        end
        if imgui.Button('Rename##file', { BUTTON_W, 0 })
            and ok and (#stem > 0) and (S.model ~= nil)
            and (stem ~= S.model.stem) then
            local done, err = items.RenameFile(S.model.path, newPath);
            if done then
                Status('Renamed to ' .. stem .. '.lua', 'good');
                S.discovery = nil;
                M.OpenProfile(newPath);
            else
                Status(tostring(err), 'error');
            end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Cancel##file', { BUTTON_W, 0 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end
end

-- The three columns, or the ladder of advice shown when there is no profile open.
local function DrawBodyOrFirstRun()
    if (S.model == nil) then
        imgui.Dummy({ 0, 30 });
        -- The first-run ladder, most broken case first: without LuAshitacast the
        -- newlua advice is a command that silently does nothing.
        local anyProfiles = (S.discovery ~= nil)
            and ((#S.discovery.yours > 0) or (#S.discovery.others > 0));
        if (not items.LacInstalled()) then
            imgui.TextWrapped('LuAshitacast is not installed. This addon edits its equipment profiles.');
            imgui.TextWrapped('Install LuAshitacast first, then come back here.');
        elseif (not anyProfiles) then
            imgui.TextWrapped('No equipment profiles yet.');
            imgui.TextWrapped('In the chat, type /lac newlua to make a blank one for your current job, then press Refresh here.');
        else
            imgui.TextWrapped('Pick a LuAshitacast profile above to view and edit its equipment sets.');
            if (S.discovery ~= nil) and (#S.discovery.yours == 0) then
                imgui.TextWrapped('No profile exists for this character yet. In the chat, type /lac newlua to make a blank one, then press Refresh here.');
            end
        end
    else
        --[[
        * No tabs. The findings that used to be behind one sit in the set list column,
        * and the handler source opens as its own window, so there is nothing left to
        * switch between.
        --]]
        DrawSetsTab();
        DrawFilterConfirm();
        DrawWireSetupPopup();
    end
end

local function DrawWindowBody()
    -- Every modal centers on this rect. Cursor position plus content region, NOT
    -- GetWindowPos plus GetWindowSize: the size call returns a junk height in game,
    -- which centered every popup on the window's top edge.
    do
        local cx, cy = imgui.GetCursorScreenPos();
        local aw, ah = imgui.GetContentRegionAvail();
        S.winCenter = { x = cx + (aw / 2), y = cy + (ah / 2) };
    end
    if (compat.StaleLibs) then
        theme.WrapText('Your addons\\libs folder is from an older Ashita. Styling is off until it is updated.', 'caution');
        imgui.Separator();
    end
    DrawToolbar();
    DrawRenameFileDialog();
    DrawBodyOrFirstRun();
end

M.Draw = function(config)
    S.config = config;
    -- Lives for one frame only: a cell sets it when it consumes a drop, so cells drawn
    -- after it in the same frame do not read that release as an ordinary click.
    S.dropHandled = false;
    -- Read once; re-reading every frame would let the saved value overwrite a drag one
    -- frame after it happened.
    if (not S.splitLoaded) and (config ~= nil) and (config.split_a ~= nil) then
        S.splitLoaded = true;
        if (type(config.split_a[1]) == 'number') and (type(config.split_b[1]) == 'number') then
            S.splitA, S.splitB = config.split_a[1], config.split_b[1];
            S.splitSaved.a, S.splitSaved.b = S.splitA, S.splitB;
        end
    end
    items.Debug = (config ~= nil) and (config.debug ~= nil) and config.debug[1] or false;
    picker.SetConfig(config);
    local pushedTheme = theme.Push();

    -- Every modal, each drawn only when its own flag is set.
    DrawUnsavedModal();
    DrawFileChangedModal();
    DrawBeforeSavingModal();
    DrawBackupsModal();
    DrawCompareModal();

    if (not S.open[1]) then
        S.wasOpen = false;
        theme.Pop(pushedTheme);
        return;
    end

    -- Opening the window starts a new epoch, which every collapsible section reads once
    -- and closes itself on. The two that already close on a profile change do it by
    -- forgetting which profile they were for.
    if (not S.wasOpen) then
        S.wasOpen = true;
        S.openEpoch = (S.openEpoch or 0) + 1;
        S.rulesFor = nil;
        S.unownedFor = nil;
    end

    if (S.config ~= nil) and (S.config.window_reset ~= nil) and (not S.config.window_reset[1]) then
        imgui.SetNextWindowSize({ WINDOW_DEFAULT_W, WINDOW_DEFAULT_H });
        S.config.window_reset[1] = true;
    else
        imgui.SetNextWindowSize({ WINDOW_DEFAULT_W, WINDOW_DEFAULT_H }, ImGuiCond_FirstUseEver);
    end

    if (imgui.SetNextWindowSizeConstraints ~= nil) then
        imgui.SetNextWindowSizeConstraints({ WINDOW_MIN_W, WINDOW_MIN_H }, { 99999, 99999 });
    end
    -- Three hashes, so only 'main' is hashed into the window id: with two the id covers
    -- the whole string, and every version bump would silently become a brand new window
    -- with no saved position or dock.
    local title = ('luashitaview v%s###main'):format(addon.version or '');

    if imgui.Begin(title, S.open, 0) then
        DrawWindowBody();
    end
    imgui.End();

    if (S.drag ~= nil) then
        if imgui.IsMouseReleased(0) then
            S.drag = nil;
        else
            local mx, my = imgui.GetMousePos();
            local dl = imgui.GetForegroundDrawList();
            local ptr = (S.drag.iconId ~= nil) and items.GetIconPtr(S.drag.iconId) or nil;
            if (ptr ~= nil) then
                dl:AddImage(ptr, { mx + 8, my + 8 }, { mx + 40, my + 40 });
            else
                dl:AddText({ mx + 10, my + 10 },
                    imgui.GetColorU32({ 1.0, 1.0, 1.0, 1.0 }),
                    S.drag.fromSlot or S.drag.name or '');
            end
        end
    end
    theme.Pop(pushedTheme);
end

M.HandleCommand = function(args)
    if (#args == 1) then
        M.Toggle();
        return true;
    end
    local sub = string.lower(args[2] or '');
    if (sub == 'debug') then
        if (S.config ~= nil) and (S.config.debug ~= nil) then
            S.config.debug[1] = not S.config.debug[1];
            ChatMsg('Debug logging ' .. (S.config.debug[1] and 'on' or 'off') .. '.');
        end
        return true;
    end
    return false;
end

return M;
