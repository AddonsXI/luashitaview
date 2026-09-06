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

-- ui, grid and sidebar share the one S table exported here.

local chat = require('chat');
local prof = require('profile');
local writer = require('writer');
local rules = require('rules');
local items = require('items');
local picker = require('picker');

local M = {};

local UNDO_DEPTH = 100;


-- Fractions of the usable row rather than pixels.
local DEFAULT_SPLIT_A = 0.26;
-- 0.57 cut the grid's last column off at the default window size.
local DEFAULT_SPLIT_B = 0.62;

-- Exported so the config default is this same number.
M.DefaultSplits = function()
    return DEFAULT_SPLIT_A, DEFAULT_SPLIT_B;
end

local S = {
    splitA = DEFAULT_SPLIT_A,
    splitB = DEFAULT_SPLIT_B,
    splitSaved = { a = DEFAULT_SPLIT_A, b = DEFAULT_SPLIT_B },
    open = { false },
    config = nil,
    discovery = nil,
    lacSettings = nil,

    -- The profile luashitacast itself is using right now, marked in the dropdown.
    activePath = nil,

    model = nil,
    analysis = nil,
    rulesCache = nil,
    -- An epoch, not a flag: a section nested under a closed parent may not draw for a long
    -- time, so a flag cleared at frame end would miss it.
    openEpoch = 0,
    wasOpen = false,
    handlerEpoch = {},
    handlerCodeEpoch = nil,
    selected = nil,
    filter = { '' },
    -- Back to the gear sets every time the window opens; ImGui otherwise remembers the
    -- last tab in its own ini, and one trip to Rules would stick for every session.
    reloadArmed = false,
    status = nil,
    statusLevel = 'info',
    nameBuf = { '' },
    renameBuf = { '' },
    renameTarget = nil,
    fileRenameBuf = { '' },
    showFileRename = false,
    deleteTarget = nil,
    deleteBuf = { '' },
    warnItems = nil,
    conflictNames = nil,
    pendingOpenPath = nil,
    detailSel = nil,
    augBuf = { '' },
    augPathBuf = { '' },
    augRankBuf = { '' },
    augTrialBuf = { '' },
    priorityBuf = { '' },
    quantityBuf = { '' },
    bagIndex = 1,
    bagLabels = nil,
    bagValues = nil,
    detailTarget = nil,
    drag = nil,
    baselines = {},
    baselineSlots = {},
    undoStack = {},
    redoStack = {},
    showBackups = false,
    backupList = nil,
    compareWith = nil,
    showCompare = false,
    afterSaveOpen = nil,
};

local function Status(text, level)
    S.status = text;
    S.statusLevel = level or 'info';
end

local function ChatMsg(text)
    print(chat.header('luashitaview'):append(chat.message(text)));
end

local function Dbg(text)
    if (S.config ~= nil) and (S.config.debug ~= nil) and S.config.debug[1] then
        print('[luashitaview] ' .. text);
    end
end

M.AutoOpen = function()
    if (S.model ~= nil) then
        return;
    end
    local auto = items.ActiveProfilePath(S.lacSettings);
    if (auto ~= nil) then
        M.OpenProfile(auto);
        return;
    end
    local last = (S.config ~= nil) and (S.config.last_profile ~= nil) and S.config.last_profile[1] or '';
    if (#last > 0) and items.FileExists(last) then
        M.OpenProfile(last);
    end
end

M.Toggle = function()
    S.open[1] = not S.open[1];
    if S.open[1] then
        if (S.discovery == nil) then
            M.RefreshDiscovery();
        end
        M.AutoOpen();
    end
end

M.IsOpen = function()
    return S.open[1];
end

M.RefreshDiscovery = function()
    S.discovery = items.DiscoverProfiles();
    S.lacSettings = items.LoadLacSettings();
    S.activePath = items.ActiveProfilePath(S.lacSettings);
end

-- Forward declared: HasUnsaved asks it, and it needs DeepEquals, which is defined
-- further down.
local IsChanged;

local function HasUnsaved()
    if (S.model == nil) then
        return false;
    end
    for _, s in ipairs(S.model.sets) do
        if IsChanged(s) then
            return true;
        end
    end
    return false;
end

local PushUndo;
local CaptureBaselineSlots;

local function ClearEditState()
    S.selected = nil;
    S.seededFor = nil;
    S.selectedIn = nil;
    S.detailSel = nil;
    S.detailEntry = nil;
    S.makePriorityTarget = nil;
    S.detailTarget = nil;
    S.analysis = nil;
    S.rulesCache = nil;
    -- Every set's slots are deep copied when a profile opens, so the save summary can
    -- diff against how things were rather than the model's state at save time.
    S.baselines = {};
    S.baselineSlots = {};
    S.undoStack = {};
    S.redoStack = {};
    S.drag = nil;
    S.compareWith = nil;
    S.showCompare = false;
end

M.OpenProfile = function(path)
    local text = items.ReadFile(path);
    if (text == nil) then
        Status('Could not read ' .. path, 'error');
        return;
    end
    -- A malformed file surfaces as a message rather than an exception.
    local ok, model = pcall(prof.Parse, text, path);
    if (not ok) then
        Status('Could not parse ' .. path, 'error');
        return;
    end
    S.model = model;
    picker.SetProfileJob(items.JobFromProfileName(model.stem));
    ClearEditState();
    CaptureBaselineSlots(model);
    for _, s in ipairs(model.sets) do
        if (s.kind == 'set') then
            S.selected = s.name;
            break;
        end
    end
    if (S.selected == nil) then
        for _, s in ipairs(model.sets) do
            if (s.kind == 'group') then
                for _, c in ipairs(s.children or {}) do
                    if (c.kind == 'set') then
                        S.selected = c.name;
                        S.selectedIn = s.name;
                        break;
                    end
                end
            end
            if (S.selected ~= nil) then
                break;
            end
        end
    end
    -- The set count is a fact about the file, drawn by ui beside the name; writing it here
    -- overwrote the save result.
    S.status = nil;
    local scanned, dynamic = 0, 0;
    for _, s in ipairs(model.sets) do
        if (s.range ~= nil) then
            scanned = scanned + 1;
        elseif (s.kind == 'dynamic') then
            dynamic = dynamic + 1;
        end
    end
    Dbg(string.format('Opened %s: kind=%s, %d sets (%d in file, %d runtime), eol=%s, %d notices',
        model.filename, model.kind, #model.sets, scanned, dynamic,
        (model.eol == '\r\n') and 'CRLF' or 'LF', #model.notices));
    if (S.config ~= nil) and (S.config.last_profile ~= nil) then
        S.config.last_profile[1] = path;
    end
end

M.RequestOpen = function(path)
    if HasUnsaved() then
        S.pendingOpenPath = path;
    else
        M.OpenProfile(path);
    end
end

local function SelectedSet()
    if (S.model == nil) or (S.selected == nil) then
        return nil;
    end
    -- A set inside a folder is addressed by the sidebar's folder path, walked segment by
    -- segment because folders nest.
    if (S.selectedIn ~= nil) then
        local node = nil;
        for seg in string.gmatch(S.selectedIn, '[^/]+') do
            if (node == nil) then
                node = prof.FindSet(S.model, seg);
            else
                local found = nil;
                for _, c in ipairs(node.children or {}) do
                    if (c.name == seg) then
                        found = c;
                        break;
                    end
                end
                node = found;
            end
            if (node == nil) then
                break;
            end
        end
        for _, c in ipairs((node and node.children) or {}) do
            if (c.name == S.selected) then
                return c;
            end
        end
    end
    return prof.FindSet(S.model, S.selected);
end

local function CaptureBaseline(setModel)
    if (setModel.range ~= nil) and (S.baselines[setModel.name] == nil) then
        S.baselines[setModel.name] = string.sub(S.model.textAtLoad, setModel.range.s, setModel.range.e);
    end
end

local function MarkDirty(setModel)
    CaptureBaseline(setModel);
    setModel.dirty = true;
end

local function RegisterSet(setModel)
    table.insert(S.model.sets, setModel);
    if (S.model.setsByLower[string.lower(setModel.name)] == nil) then
        S.model.setsByLower[string.lower(setModel.name)] = #S.model.sets;
    end
end

local function RebuildLookup()
    S.model.setsByLower = {};
    for i, s in ipairs(S.model.sets) do
        if (S.model.setsByLower[string.lower(s.name)] == nil) then
            S.model.setsByLower[string.lower(s.name)] = i;
        end
    end
end

local function NameInUse(name)
    return S.model.setsByLower[string.lower(name)] ~= nil;
end

local function CreateSet(name)
    PushUndo();
    local setModel = {
        name = name,
        kind = 'set',
        slots = {},
        unknownKeys = {},
        dirty = true,
        isNew = true,
        deleted = false,
    };
    setModel.logicalName, setModel.isPriority = prof.LogicalName(name);
    RegisterSet(setModel);
    S.baselineSlots[name] = {};
    S.selected = name;
    Status('Created ' .. name .. ', press Save', 'info');
end

local function DeepCopySlots(slots)
    local out = {};
    for k, v in pairs(slots) do
        if (v.kind == 'item') then
            local item = {};
            for ik, iv in pairs(v.item) do
                if (type(iv) == 'table') then
                    local arr = {};
                    for _, a in ipairs(iv) do
                        table.insert(arr, a);
                    end
                    item[ik] = arr;
                else
                    item[ik] = iv;
                end
            end
            out[k] = { kind = 'item', item = item, raw = v.raw, locked = v.locked };
        elseif (v.kind == 'chain') then
            local entries = {};
            for _, e in ipairs(v.entries) do
                local item = {};
                for ik, iv in pairs(e) do
                    if (type(iv) == 'table') then
                        local arr = {};
                        for _, a in ipairs(iv) do
                            table.insert(arr, a);
                        end
                        item[ik] = arr;
                    else
                        item[ik] = iv;
                    end
                end
                table.insert(entries, item);
            end
            out[k] = { kind = 'chain', entries = entries, raw = v.raw, locked = v.locked };
        elseif (v.kind == 'opaque') then
            out[k] = { kind = 'opaque', raw = v.raw };
        end
    end
    return out;
end

local function DeepCopy(v)
    if (type(v) ~= 'table') then
        return v;
    end
    local out = {};
    for k, val in pairs(v) do
        out[k] = DeepCopy(val);
    end
    return out;
end

-- Must be called BEFORE the mutation: most sites change the model first and mark it afterwards.
PushUndo = function()
    if (S.model == nil) then
        return;
    end
    -- A snapshot is a deep copy of every set, so the ceiling is about memory.
    table.insert(S.undoStack, { sets = DeepCopy(S.model.sets), selected = S.selected });
    while (#S.undoStack > UNDO_DEPTH) do
        table.remove(S.undoStack, 1);
    end
    -- A fresh edit makes the forward history meaningless: redoing into it would bring
    -- back gear from a branch that was abandoned the moment this edit happened.
    S.redoStack = {};
end

local function Snapshot()
    return { sets = DeepCopy(S.model.sets), selected = S.selected };
end

local function Restore(snap)
    S.model.sets = snap.sets;
    RebuildLookup();
    S.detailSel = nil;
    S.detailTarget = nil;
    S.analysis = nil;
    S.rulesCache = nil;
    S.drag = nil;
    if (snap.selected ~= nil) and (prof.FindSet(S.model, snap.selected) ~= nil) then
        S.selected = snap.selected;
    elseif (S.selected ~= nil) and (prof.FindSet(S.model, S.selected) == nil) then
        S.selected = nil;
    end
end

local function DoUndo()
    if (S.model == nil) or (#S.undoStack == 0) then
        return;
    end
    table.insert(S.redoStack, Snapshot());
    Restore(table.remove(S.undoStack));
    Status('Undone', 'info');
end

local function DoRedo()
    if (S.model == nil) or (#S.redoStack == 0) then
        return;
    end
    table.insert(S.undoStack, Snapshot());
    Restore(table.remove(S.redoStack));
    Status('Redone', 'info');
end

CaptureBaselineSlots = function(model)
    for _, s in ipairs(model.sets) do
        if (s.kind == 'set') and (S.baselineSlots[s.name] == nil) then
            S.baselineSlots[s.name] = DeepCopySlots(s.slots);
        end
    end
end

local function FirstEntry(slotValue)
    if (slotValue == nil) then
        return nil;
    end
    if (slotValue.kind == 'item') then
        return slotValue.item;
    end
    if (slotValue.kind == 'chain') and (#slotValue.entries > 0) then
        return slotValue.entries[1];
    end
    return nil;
end

local function EntryLabel(v)
    if (v == nil) then
        return nil;
    end
    if (v.kind == 'opaque') then
        return '{ code }';
    end
    if (v.kind == 'chain') and (#v.entries == 0) then
        return 'empty list';
    end
    local e = FirstEntry(v);
    local label = (e and e.name) or '?';
    if (label == '') then
        label = "''";
    end
    if (v.kind == 'chain') and (#v.entries > 1) then
        label = label .. ' (+' .. (#v.entries - 1) .. ' more)';
    end
    return label;
end

local function DeepEquals(a, b)
    if (a == b) then
        return true;
    end
    if (type(a) ~= 'table') or (type(b) ~= 'table') then
        return false;
    end
    for k, v in pairs(a) do
        if (not DeepEquals(v, b[k])) then
            return false;
        end
    end
    for k in pairs(b) do
        if (a[k] == nil) then
            return false;
        end
    end
    return true;
end

-- Asked rather than remembered: a flag only ever went true, and undo could not restore it once
-- the clean snapshot fell off the stack. dirty still means touched, which decides whether the
-- original text is kept for the diff.
IsChanged = function(s)
    if (s == nil) then
        return false;
    end
    if s.isNew or s.deleted then
        return true;
    end
    if (not s.dirty) then
        return false;
    end
    if (s.renamedFrom ~= nil) and (s.renamedFrom ~= s.name) then
        return true;
    end
    local base = S.baselineSlots[s.renamedFrom or s.name];
    if (base == nil) then
        return true;
    end
    for _, slot in ipairs(prof.SlotNames) do
        local old, new = base[slot], (s.slots or {})[slot];
        if ((old == nil) ~= (new == nil)) then
            return true;
        end
        if (old ~= nil) and (not DeepEquals(old, new)) then
            return true;
        end
    end
    return false;
end

local function DiffLines(s)
    local base = S.baselineSlots[s.renamedFrom or s.name] or {};
    local lines = {};
    if s.isNew then
        base = {};
    end
    for _, slot in ipairs(prof.SlotNames) do
        local old = base[slot];
        local new = s.slots[slot];
        if (old == nil) and (new ~= nil) then
            table.insert(lines, slot .. ': add ' .. tostring(EntryLabel(new)));
        elseif (old ~= nil) and (new == nil) then
            table.insert(lines, slot .. ': clear (was ' .. tostring(EntryLabel(old)) .. ')');
        elseif (old ~= nil) and (new ~= nil) and (not DeepEquals(old, new)) then
            local ol = tostring(EntryLabel(old));
            local nl = tostring(EntryLabel(new));
            if (ol == nl) then
                table.insert(lines, slot .. ': ' .. nl .. ' (details changed)');
            else
                table.insert(lines, slot .. ': ' .. ol .. '  >  ' .. nl);
            end
        end
    end
    if (s.renamedFrom ~= nil) and (s.renamedFrom ~= s.name) then
        table.insert(lines, 1, 'renamed from ' .. s.renamedFrom);
    end
    if (#lines == 0) then
        table.insert(lines, 'rewritten in standard style; equipment unchanged');
    end
    return lines;
end

-- renamedFrom keeps the FIRST name the file knows, so a save still finds the original
-- line whatever the set has been called in between.
local function ApplyRename(cur, name)
    PushUndo();
    S.baselineSlots[name] = S.baselineSlots[cur.name];
    cur.renamedFrom = cur.renamedFrom or cur.name;
    cur.name = name;
    cur.logicalName, cur.isPriority = prof.LogicalName(name);
    MarkDirty(cur);
    RebuildLookup();
    S.selected = name;
    S.analysis = nil;
    S.rulesCache = nil;
end

-- A missing framework file takes LuAshitacast down: LoadFile returns nil, the profile indexes
-- it at file scope, and Ashita unloads the addon. The sandbox proxies every load, so only the
-- real disk knows.
-- The profile's own folder is checked first: LoadFile tries the character folder before the
-- root, and a character-folder layout keeps common\ in there.
-- Same two bases as MissingFrameworkFiles, for the same reason.
M.ReadFrameworkFiles = function(text, lacRoot, profileDir)
    local out = {};
    local bases = {};
    if (type(profileDir) == 'string') and (#profileDir > 0) then
        table.insert(bases, profileDir);
    end
    table.insert(bases, lacRoot);

    for path in string.gmatch(text or '', 'gFunc%s*%.%s*LoadFile%s*%(%s*[\'"]([^\'"]+)[\'"]') do
        local rel = string.gsub(path, '/', '\\');
        if (string.lower(string.sub(rel, -4)) ~= '.lua') then
            rel = rel .. '.lua';
        end
        for _, base in ipairs(bases) do
            local f = io.open(base .. rel, 'rb');
            if (f ~= nil) then
                table.insert(out, f:read('*a'));
                f:close();
                break;
            end
        end
    end
    return out;
end

M.MissingFrameworkFiles = function(text, lacRoot, profileDir)
    local missing = {};
    local bases = {};
    if (type(profileDir) == 'string') and (#profileDir > 0) then
        table.insert(bases, profileDir);
    end
    table.insert(bases, lacRoot);

    for path in string.gmatch(text or '', 'gFunc%s*%.%s*LoadFile%s*%(%s*[\'"]([^\'"]+)[\'"]') do
        local rel = string.gsub(path, '/', '\\');
        if (string.lower(string.sub(rel, -4)) ~= '.lua') then
            rel = rel .. '.lua';
        end
        local found = false;
        for _, base in ipairs(bases) do
            local f = io.open(base .. rel, 'rb');
            if (f ~= nil) then
                f:close();
                found = true;
                break;
            end
        end
        if (not found) then
            table.insert(missing, path);
        end
    end
    return missing;
end

-- LuAshitacast only walks _Priority sets when the profile calls gFunc.EvaluateLevels, or
-- reaches it through BasicLuas' CheckLevelSync. gData has no EvaluateLevels, so a plain
-- substring test would wrongly report the lists as live.
M.EvaluatesLevels = function(text)
    return rules.CallsEvaluateLevels(text or '');
end

local function ProfileEvaluatesLevels()
    return M.EvaluatesLevels((S.model ~= nil) and S.model.textAtLoad or '');
end

-- The set's own declaration is excluded: the writer rewrites that head itself, so it would be
-- renamed twice.
local function RenameSitesFor(s)
    local old = s.renamedFrom;
    if (old == nil) or (old == s.name) or s.isNew or s.deleted then
        return nil;
    end
    local ok, found = pcall(rules.FindRenameSites, S.model.textAtLoad, old);
    if (not ok) or (found == nil) then
        return nil;
    end
    local out = {};
    for _, site in ipairs(found) do
        local ownDecl = (s.range ~= nil) and (site.s >= s.range.s) and (site.e <= s.range.e);
        if (not ownDecl) then
            table.insert(out, site);
        end
    end
    if (#out == 0) then
        return nil;
    end
    return out;
end

local function BuildEdits()
    local edits = {};
    local warnable = {};

    -- References first: these spans are measured against the file as loaded, and replacing a
    -- set changes its length.
    for _, s in ipairs(S.model.sets) do
        local sites = RenameSitesFor(s);
        if (sites ~= nil) then
            -- name carries the same key the warnable entry uses, so unticking the box in
            -- the save summary actually skips this edit rather than silently doing it.
            table.insert(edits, { op = 'renamerefs', sites = sites, name = 'refs:' .. s.name,
                oldName = s.renamedFrom, newName = s.name });
            table.insert(warnable, { name = s.name, key = 'refs:' .. s.name, reasons = {},
                lines = { #sites .. ' mention' .. ((#sites == 1) and '' or 's') ..
                    ' of ' .. s.renamedFrom .. ' updated to ' .. s.name }, include = { true } });
        end
    end
    for _, s in ipairs(S.model.sets) do
        if s.deleted and (not s.isNew) then
            table.insert(edits, { op = 'delete', name = s.renamedFrom or s.name });
            table.insert(warnable, { name = s.name, key = s.renamedFrom or s.name, reasons = {},
                lines = { 'the whole set was removed' }, include = { true } });
        elseif s.isNew and (not s.deleted) then
            table.insert(edits, { op = 'append', name = s.name, set = s });
            table.insert(warnable, { name = s.name, key = s.name, reasons = {},
                lines = DiffLines(s), include = { true } });
        elseif IsChanged(s) and (not s.deleted) then
            table.insert(edits, { op = 'replace', name = s.renamedFrom or s.name, set = s });
            local reasons = {};
            if (s.unknownKeys ~= nil) and (#s.unknownKeys > 0) then
                table.insert(reasons, 'unrecognized entries removed: ' .. table.concat(s.unknownKeys, ', '));
            end
            if s.hasTabs then
                table.insert(reasons, 'tab indentation changed to standard style');
            end
            table.insert(warnable, { name = s.name, key = s.name, reasons = reasons,
                lines = DiffLines(s), include = { true } });
        end
    end
    return edits, warnable;
end

local function FinishSave(baseText, edits)
    local opts = {
        screenOrder = (S.lacSettings == nil) or (S.lacSettings.AddSetEquipScreenOrder ~= false),
        eol = S.model.eol,
    };
    local newText, err = writer.ApplyEdits(baseText, edits, opts);
    if (newText == nil) then
        Status('Nothing written: ' .. tostring(err), 'error');
        Dbg('ApplyEdits refused: ' .. tostring(err));
        return;
    end
    Dbg(string.format('Save: %d edits, %d bytes in, %d bytes out', #edits, #baseText, #newText));
    local okBackup, backupPathOrErr = items.BackupProfile({ filename = S.model.filename, textAtLoad = baseText }, S.lacSettings);
    if (not okBackup) then
        Status('Nothing written: ' .. tostring(backupPathOrErr), 'error');
        return;
    end
    if (not items.WriteFile(S.model.path, newText)) then
        Status('Could not write ' .. S.model.filename, 'error');
        return;
    end
    local savedCount = #edits;
    local keepSelected = S.selected;
    local path = S.model.path;
    M.OpenProfile(path);
    if (keepSelected ~= nil) and (prof.FindSet(S.model, keepSelected) ~= nil) then
        S.selected = keepSelected;
    end
    S.reloadArmed = true;
    Status('Saved ' .. S.model.filename, 'good');
    local msg = 'Saved ' .. savedCount .. ' change' .. ((savedCount == 1) and '' or 's')
        .. ' to ' .. S.model.filename .. '.';
    if (type(backupPathOrErr) == 'string') then
        msg = msg .. ' Backup made first.';
    end
    ChatMsg(msg);
    if (S.config ~= nil) and S.config.auto_reload_after_save[1] then
        items.QueueReload();
        S.reloadArmed = false;
    end
    if (S.afterSaveOpen ~= nil) then
        local target = S.afterSaveOpen;
        S.afterSaveOpen = nil;
        M.OpenProfile(target);
    end
end

local function StartSave()
    if (S.model == nil) then
        return;
    end
    local edits, warnable = BuildEdits();
    if (#edits == 0) then
        Status('Nothing to save', 'info');
        return;
    end
    local fresh = items.ReadFile(S.model.path);
    if (fresh == nil) then
        Status('Could not re-read the file', 'error');
        return;
    end
    if (fresh ~= S.model.textAtLoad) then
        local freshAnchor = prof.FindAnchor(fresh);
        local conflicts = {};
        if (freshAnchor ~= nil) then
            local freshKeys = prof.ScanSets(fresh, freshAnchor.BraceIndex + 1);
            local freshMap = {};
            for _, k in ipairs(freshKeys) do
                freshMap[k.Name] = string.sub(fresh, k.StartIndex, k.EndIndex);
            end
            for _, edit in ipairs(edits) do
                if (edit.op ~= 'append') then
                    local base = S.baselines[edit.name];
                    local now = freshMap[edit.name];
                    if (now == nil) or ((base ~= nil) and (now ~= base)) then
                        table.insert(conflicts, edit.name);
                    end
                end
            end
        end
        if (#conflicts > 0) then
            S.conflictNames = conflicts;
            S.pendingSave = { text = fresh, edits = edits, warnable = warnable };
            return;
        end
    end
    if (#warnable > 0) then
        S.warnItems = warnable;
        S.pendingSave = { text = fresh, edits = edits, warnable = warnable };
        return;
    end
    FinishSave(fresh, edits);
end

local function ContinueSaveAfterWarn()
    if (S.pendingSave == nil) then
        return;
    end
    local included = {};
    local skipped = {};
    for _, w in ipairs(S.pendingSave.warnable) do
        if (not w.include[1]) then
            skipped[w.key or w.name] = true;
        end
    end
    for _, edit in ipairs(S.pendingSave.edits) do
        local key = (edit.set ~= nil) and edit.set.name or edit.name;
        if (not skipped[key]) and (not ((edit.op == 'delete') and skipped[edit.name])) then
            table.insert(included, edit);
        end
    end
    local text = S.pendingSave.text;
    S.pendingSave = nil;
    if (#included == 0) then
        Status('Nothing written', 'info');
        return;
    end
    FinishSave(text, included);
end

local function ResolveEntryId(entry)
    if (entry == nil) or (entry.name == nil) or entry.sentinel then
        return nil;
    end
    return items.ResolveItemId(entry.name);
end

-- Whether an entry can live in a slot. Sentinels and anything unresolvable pass, since
-- refusing what cannot be checked would block edits on names the database lacks.
M.FitsSlot = function(entry, slotName)
    if (entry == nil) or entry.sentinel then
        return true;
    end
    local id = ResolveEntryId(entry);
    local info = (id ~= nil) and items.GetItemInfo(id) or nil;
    if (info == nil) or (info.slots == nil) then
        return true;
    end
    local idx = prof.SlotIndex[string.lower(slotName)];
    if (idx == nil) then
        return true;
    end
    local mask = bit.lshift(1, idx - 1);
    if (slotName == 'Ear1') or (slotName == 'Ear2') then
        mask = 0x1800;
    elseif (slotName == 'Ring1') or (slotName == 'Ring2') then
        mask = 0x6000;
    end
    return bit.band(info.slots, mask) ~= 0;
end

-- Deliberately ignores what you own, because the game does.
local function WinningEntry(slotValue, level)
    if (slotValue == nil) then
        return nil, nil;
    end
    if (slotValue.kind == 'item') then
        return slotValue.item, 1;
    end
    if (slotValue.kind ~= 'chain') then
        return nil, nil;
    end
    for i, entry in ipairs(slotValue.entries) do
        if (entry.sentinel) then
            return entry, i;
        end
        local id = ResolveEntryId(entry);
        local info = (id ~= nil) and items.GetItemInfo(id) or nil;
        local need = (info ~= nil) and (info.level or 0) or 0;
        if (level == nil) or (need <= level) then
            return entry, i;
        end
    end
    return nil, nil;
end

local function EffectiveBaseSlots(setModel)
    local ghosts = {};
    local seen = {};
    local current = setModel;
    for _ = 1, 8 do
        if (current == nil) or (current.baseSet == nil) then
            break;
        end
        local baseName = string.match(current.baseSet, '^[^%.]+');
        if seen[string.lower(baseName)] then
            break;
        end
        seen[string.lower(baseName)] = true;
        local base = prof.FindSet(S.model, baseName);
        if (base == nil) then
            break;
        end
        for slot, v in pairs(base.slots or {}) do
            if (setModel.slots[slot] == nil) and (ghosts[slot] == nil) then
                ghosts[slot] = { value = v, from = base.name };
            end
        end
        current = base;
    end
    return ghosts;
end

M.S = S;
M.Status = Status;
M.ChatMsg = ChatMsg;
M.Dbg = Dbg;
M.HasUnsaved = HasUnsaved;
M.IsChanged = function(s) return IsChanged(s); end;
M.SelectedSet = SelectedSet;
M.CaptureBaseline = CaptureBaseline;
M.MarkDirty = MarkDirty;
M.RegisterSet = RegisterSet;
M.RebuildLookup = RebuildLookup;
M.NameInUse = NameInUse;
M.CreateSet = CreateSet;
M.DeepCopySlots = DeepCopySlots;
M.PushUndo = PushUndo;
M.DoUndo = DoUndo;
M.DoRedo = DoRedo;
M.FirstEntry = FirstEntry;
M.EntryLabel = EntryLabel;
M.ApplyRename = ApplyRename;
M.ProfileEvaluatesLevels = ProfileEvaluatesLevels;
M.FinishSave = FinishSave;
M.StartSave = StartSave;
M.ContinueSaveAfterWarn = ContinueSaveAfterWarn;
M.ResolveEntryId = ResolveEntryId;
M.WinningEntry = WinningEntry;
M.EffectiveBaseSlots = EffectiveBaseSlots;

return M;
