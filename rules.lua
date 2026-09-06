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


local prof = require('profile');

local M = {};

M.HandlerNames = {
    'OnLoad', 'OnUnload', 'HandleCommand', 'HandleDefault', 'HandleAbility',
    'HandleItem', 'HandlePrecast', 'HandleMidcast', 'HandlePreshot',
    'HandleMidshot', 'HandleWeaponskill',
};

local OpenKeywords = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true };
local CloseKeywords = { ['end'] = true, ['until'] = true };
local SkipDo = { ['while'] = true, ['for'] = true };

local function FindBodyEnd(stripped, funcKeywordEnd)
    local depth = 1;
    local i = funcKeywordEnd + 1;
    local len = #stripped;
    local pendingSkipDo = false;
    while i <= len do
        local c = stripped:byte(i);
        if (c == string.byte('\'')) or (c == string.byte('\"')) then
            local quote = c;
            i = i + 1;
            while i <= len do
                local b = stripped:byte(i);
                if (b == string.byte('\\')) then
                    i = i + 2;
                elseif (b == quote) then
                    break;
                else
                    i = i + 1;
                end
            end
        elseif stripped:sub(i, i + 1) == '[[' then
            local closeAt = stripped:find(']]', i + 2, true);
            i = (closeAt ~= nil) and (closeAt + 1) or len;
        elseif stripped:match('^[%a_]', i) then
            local word = stripped:match('^[%w_]+', i);
            local before = (i > 1) and stripped:sub(i - 1, i - 1) or '';
            local isName = before:match('[%w_%.]') ~= nil;
            if (not isName) then
                if (word == 'do') and pendingSkipDo then
                    pendingSkipDo = false;
                elseif SkipDo[word] then
                    pendingSkipDo = true;
                elseif OpenKeywords[word] then
                    depth = depth + 1;
                elseif CloseKeywords[word] then
                    depth = depth - 1;
                    if (depth == 0) then
                        return i + #word - 1;
                    end
                end
            end
            i = i + #word - 1;
        end
        i = i + 1;
    end
    return nil;
end

M.ExtractHandlers = function(text, stripped)
    stripped = stripped or prof.StripComments(text);
    local handlers = {};
    for _, name in ipairs(M.HandlerNames) do
        local pattern = 'profile%s*%.%s*' .. name .. '%s*=%s*function';
        local s, e = stripped:find(pattern);
        if (s ~= nil) then
            local bodyEnd = FindBodyEnd(stripped, e);
            if (bodyEnd ~= nil) then
                local line = 1;
                for _ in string.gmatch(stripped:sub(1, s), '\n') do
                    line = line + 1;
                end
                handlers[name] = {
                    name = name,
                    startIndex = s,
                    endIndex = bodyEnd,
                    startLine = line,
                    source = text:sub(s, bodyEnd),
                    strippedSource = stripped:sub(s, bodyEnd),
                };
            end
        end
    end
    return handlers;
end

local RefCallNames = { 'EquipSet', 'InterimEquipSet', 'ForceEquipSet', 'LockSet' };

local function IsPrefixConcat(stripped, quoteEnd)
    local rest = stripped:sub(quoteEnd + 1);
    return rest:match('^%s*%.%.') ~= nil;
end

local function AddRef(refs, name, kind, index)
    table.insert(refs, { name = name, kind = kind, index = index });
end

-- The frontier pattern treats a dot as a word boundary, so blsets.sets.Holy_Water would
-- otherwise read as a local name.
local function IsQualified(text, index)
    local before = (index > 1) and string.sub(text, index - 1, index - 1) or '';
    return (before == '.') or (before == ':');
end

-- Byte spans covering the name alone, found in the comment-stripped copy, which is length
-- preserving. A concatenated reference like EquipSet('Tp_' .. mode) is skipped.
-- Empty handlers only: writing into one that already has logic changes what wins.
-- Two shapes count as simple: nothing but equip lines, or one Status branch. Anything else
-- returns nil.
M.SimpleHandlerBody = function(text, handlerName)
    local stripped = prof.StripComments(text);
    local h = M.ExtractHandlers(text, stripped)[handlerName];
    if (h == nil) then
        return nil;
    end
    local inner = h.strippedSource:match('^profile%s*%.%s*[%w_]+%s*=%s*function%s*%b()%s*(.-)%s*end%s*$');
    if (inner == nil) then
        return nil;
    end

    -- byStatus and otherwise carry which set belongs to which branch.
    local equips, byStatus = {}, {};
    local otherwise, branched, sawLocal, inChain, sawElse, closed = nil, false, false, false, false, false;
    local status = nil;

    local function Condition(cond)
        local var, want = cond:match('^%(?%s*([%w_]+)%s*%.%s*Status%s*==%s*[\'"]([%w_]+)[\'"]%s*%)?$');
        return var, want;
    end

    for line in string.gmatch(inner, '[^\n]+') do
        local body = line:match('^%s*(.-)%s*$');
        if (#body > 0) then
            local name = body:match('^gFunc%s*%.%s*EquipSet%s*%(%s*sets%s*%.%s*([%w_]+)%s*%)%s*;?$')
                or body:match('^gFunc%s*%.%s*EquipSet%s*%(%s*[\'"]([%w_]+)[\'"]%s*%)%s*;?$');
            if (name ~= nil) then
                -- An equip after the chain has closed is unconditional and would
                -- override every branch above it, so it is not a shape to offer on.
                if closed then
                    return nil;
                end
                table.insert(equips, name);
                if (not inChain) then
                    if branched then
                        return nil;
                    end
                elseif (status ~= nil) then
                    byStatus[status] = name;
                elseif sawElse then
                    otherwise = name;
                end
            elseif body:match('^local%s+[%w_]+%s*=%s*gData%s*%.%s*GetPlayer%s*%(%s*%)%s*;?$') then
                if sawLocal or inChain or (#equips > 0) then
                    return nil;
                end
                sawLocal = true;
            elseif body:match('^if%s') or body:match('^if%(') then
                local cond = body:match('^if%s*(.-)%s*then$');
                local _, want = Condition(cond or '');
                if (want == nil) or inChain or branched or (#equips > 0) then
                    return nil;
                end
                inChain, branched, status = true, true, want;
            elseif body:match('^elseif%s') or body:match('^elseif%(') then
                local cond = body:match('^elseif%s*(.-)%s*then$');
                local _, want = Condition(cond or '');
                if (want == nil) or (not inChain) or sawElse then
                    return nil;
                end
                status = want;
            elseif (body == 'else') then
                if (not inChain) or sawElse then
                    return nil;
                end
                sawElse, status = true, nil;
            elseif (body == 'end') then
                if (not inChain) then
                    return nil;
                end
                inChain, closed, status = false, true, nil;
            else
                return nil;
            end
        end
    end

    if inChain then
        return nil;
    end

    -- The span runs from the start of the first body line to the end of the last, so a
    -- replacement lands exactly where the body was and the closing end is untouched.
    local at = h.endIndex - 2;
    while (at > 1) and (text:sub(at - 1, at - 1) ~= '\n') do
        at = at - 1;
    end
    local bodyStart = h.startIndex;
    local _, headEnd = stripped:find('^profile%s*%.%s*[%w_]+%s*=%s*function%s*%b()', h.startIndex);
    if (headEnd == nil) then
        return nil;
    end
    bodyStart = headEnd + 1;
    while (bodyStart <= #text) and (text:sub(bodyStart, bodyStart) ~= '\n') do
        bodyStart = bodyStart + 1;
    end
    bodyStart = bodyStart + 1;

    return { s = bodyStart, e = at - 1, equips = equips, byStatus = byStatus,
        otherwise = otherwise, branched = branched };
end

M.EmptyHandlerInsertPoint = function(text, handlerName)
    local stripped = prof.StripComments(text);
    local h = M.ExtractHandlers(text, stripped)[handlerName];
    if (h == nil) then
        return nil;
    end
    local inner = h.strippedSource:match('^profile%s*%.%s*[%w_]+%s*=%s*function%s*%b()%s*(.-)%s*end%s*$');
    if (inner == nil) or (inner:match('^%s*$') == nil) then
        return nil;
    end
    -- Back up from the closing end to the start of its line, so the new line lands above
    -- it at the body's own indentation rather than jammed onto the end.
    local at = h.endIndex - 2;
    while (at > 1) and (text:sub(at - 1, at - 1) ~= '\n') do
        at = at - 1;
    end
    return at;
end

M.FindRenameSites = function(text, oldName)
    local stripped = prof.StripComments(text);
    local sites = {};
    local seen = {};
    local function Add(s, e)
        if (not seen[s]) then
            seen[s] = true;
            table.insert(sites, { s = s, e = e });
        end
    end

    -- sets.Name
    for at, name, after in string.gmatch(stripped, '()%f[%w_]sets%s*%.%s*([%w_]+)()') do
        if (name == oldName) and (not IsQualified(stripped, at)) then
            Add(after - #name, after - 1);
        end
    end

    -- sets['Name']
    for at, q, nameAt, name in string.gmatch(stripped, '()%f[%w_]sets%s*%[%s*([\'"])()([^\'"]+)%2') do
        if (name == oldName) and (not IsQualified(stripped, at)) then
            Add(nameAt, nameAt + #name - 1);
        end
    end

    -- BaseSet = 'Name' is a reference too. Only an exact whole value is renamed, never a dotted
    -- path.
    for at, q, nameAt, name in string.gmatch(stripped, '()%f[%w_]BaseSet%s*=%s*([\'"])()([^\'"]+)%2') do
        if (name == oldName) then
            Add(nameAt, nameAt + #name - 1);
        end
    end

    -- EquipSet('Name') and its siblings
    for _, call in ipairs(RefCallNames) do
        local pattern = '()%f[%w_]' .. call .. '%s*%(%s*([\'"])()([^\'"]*)%2()';
        for _, q, nameAt, name, qEnd in string.gmatch(stripped, pattern) do
            if (name == oldName) and (not IsPrefixConcat(stripped, qEnd - 1)) then
                Add(nameAt, nameAt + #name - 1);
            end
        end
    end

    table.sort(sites, function(a, b) return a.s < b.s; end);
    return sites;
end

M.ExtractRefs = function(strippedSlice)
    local refs = {};
    for s, name in string.gmatch(strippedSlice, '()%f[%w_]sets%s*%.%s*([%w_]+)') do
        if (not IsQualified(strippedSlice, s)) then
            AddRef(refs, name, 'field', s);
        end
    end
    for s, q, name in string.gmatch(strippedSlice, '()%f[%w_]sets%s*%[%s*([\'"])([^\'"]+)%2%s*%]') do
        if (not IsQualified(strippedSlice, s)) then
            AddRef(refs, name, 'field', s);
        end
    end
    for _, call in ipairs(RefCallNames) do
        local pattern = '()%f[%w_]' .. call .. '%s*%(%s*([\'"])([^\'"]*)%2()';
        for s, q, name, qEnd in string.gmatch(strippedSlice, pattern) do
            if (#name > 0) then
                if IsPrefixConcat(strippedSlice, qEnd - 1) then
                    AddRef(refs, name, 'prefix', s);
                else
                    AddRef(refs, name, 'string', s);
                end
            end
        end
    end
    return refs;
end

local function ResolveDotPath(model, name)
    local parts = {};
    for part in string.gmatch(name, '[^%.]+') do
        table.insert(parts, part);
    end
    if (#parts < 2) then
        return nil;
    end
    local current = prof.FindSet(model, parts[1]);
    if (current == nil) then
        return nil;
    end
    local resolvedPath = current.name;
    for i = 2, #parts do
        if (current.children == nil) then
            return nil;
        end
        local found = nil;
        for _, child in ipairs(current.children) do
            if (string.lower(child.name) == string.lower(parts[i])) then
                found = child;
                break;
            end
        end
        if (found == nil) then
            return nil;
        end
        current = found;
        resolvedPath = resolvedPath .. '.' .. current.name;
    end
    return resolvedPath;
end

M.ResolveRef = function(model, ref)
    if (ref.kind == 'prefix') then
        local matches = {};
        local lowered = string.lower(ref.name);
        for _, s in ipairs(model.sets) do
            if (string.sub(string.lower(s.name), 1, #lowered) == lowered) then
                table.insert(matches, s.name);
            end
        end
        if (#matches > 0) then
            return { kind = 'prefix', matches = matches };
        end
        return nil;
    end
    local direct = prof.FindSet(model, ref.name);
    if (direct ~= nil) then
        return { kind = 'set', name = direct.name };
    end
    local twin = prof.FindSet(model, ref.name .. '_Priority');
    if (twin ~= nil) then
        return { kind = 'set', name = twin.name };
    end
    if string.find(ref.name, '.', 1, true) then
        local path = ResolveDotPath(model, ref.name);
        if (path ~= nil) then
            return { kind = 'path', name = path };
        end
    end
    return nil;
end

local function CollectCycleNames(stripped)
    local names = {};
    for cyc, listStart in string.gmatch(stripped, 'CreateCycle%s*%(%s*[\'"]([%w_]+)[\'"]%s*,%s*{()') do
        local depth = 1;
        local i = listStart;
        local len = #stripped;
        local segment = nil;
        while (i <= len) and (depth > 0) do
            local c = stripped:sub(i, i);
            if (c == '{') then
                depth = depth + 1;
            elseif (c == '}') then
                depth = depth - 1;
            end
            i = i + 1;
        end
        segment = stripped:sub(listStart, i - 2);
        for value in string.gmatch(segment, '[\'"]([^\'"]+)[\'"]') do
            table.insert(names, cyc .. '_' .. value);
        end
    end
    return names;
end

-- Only a gFunc call counts; that is the one LuAshitacast exposes.
M.CallsEvaluateLevels = function(stripped)
    return (string.find(stripped, 'gFunc%s*%.%s*EvaluateLevels') ~= nil)
        or (string.find(stripped, 'CheckLevelSync', 1, true) ~= nil);
end

-- gData has no EvaluateLevels, so the call errors and no _Priority set is ever flattened.
-- Returns a display string naming what probably equips these sets, or nil when the profile is
-- self contained.
-- The line break after the function header.
-- gData.GetAction is nil unless an action is in progress, so a read from one of these throws
-- once per frame.
M.ActionlessHandlers = {
    OnLoad = true, OnUnload = true, HandleCommand = true, HandleDefault = true,
};

-- Parsed from the include rather than listed, so a third helper is picked up on its own.
M.HelpersNeedingAction = function(includeText)
    local out = {};
    if (type(includeText) ~= 'string') then
        return out;
    end
    local src = prof.StripComments(includeText);
    local names, starts = {}, {};
    for at, name in src:gmatch('()function%s+[%w_]+%s*%.%s*([%w_]+)') do
        names[#names + 1] = name;
        starts[#starts + 1] = at;
    end
    for i, name in ipairs(names) do
        local body = src:sub(starts[i], (starts[i + 1] or (#src + 1)) - 1);
        if (body:find('GetAction%s*%(') ~= nil) then
            out[name] = true;
        end
    end
    return out;
end

-- Returns { handler, what, line }; what is the call as written.
M.FindActionlessReads = function(text, stripped, helpers)
    stripped = stripped or prof.StripComments(text);
    helpers = helpers or {};
    local found = {};
    local handlers = M.ExtractHandlers(text, stripped);

    for name in pairs(M.ActionlessHandlers) do
        local h = handlers[name];
        if (h ~= nil) then
            local body = stripped:sub(h.startIndex, h.endIndex);
            local function Note(at, what)
                local line = h.startLine;
                for _ in body:sub(1, at):gmatch('\n') do
                    line = line + 1;
                end
                table.insert(found, { handler = name, what = what, line = line });
            end
            for at, call in body:gmatch('()gData%s*%.%s*(GetAction)%s*%(') do
                Note(at, 'gData.' .. call .. '()');
            end
            for at, holder, call in body:gmatch('()([%w_]+)%s*%.%s*([%w_]+)%s*%(') do
                if helpers[call] then
                    Note(at, holder .. '.' .. call .. '()');
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.line < b.line; end);
    return found;
end

M.HandlerBodyStart = function(text, handlerName)
    local handlers = M.ExtractHandlers(text);
    local h = handlers[handlerName];
    if (h == nil) then
        return nil;
    end
    local at = string.find(text, '\n', h.startIndex, true);
    if (at == nil) or (at > h.endIndex) then
        return nil;
    end
    return at + 1;
end

M.HandsSetsOff = function(stripped)
    local seen, names = {}, {};
    for name in stripped:gmatch('gFunc%s*%.%s*LoadFile%s*%(%s*[\'"]([^\'"]+)[\'"]') do
        -- A literal ending in a separator is a folder with the filename concatenated on, so it
        -- has no leaf.
        local leaf = name:match('([^/\\]+)$');
        if (leaf ~= nil) and (not seen[leaf]) then
            seen[leaf] = true;
            names[#names + 1] = leaf;
        end
    end
    if (#names > 0) then
        if (#names > 3) then
            local extra = #names - 3;
            return table.concat({ names[1], names[2], names[3] }, ', ')
                .. ' and ' .. extra .. ' more';
        end
        return table.concat(names, ', ');
    end
    -- Rag's and the other shared-set frameworks take the whole table instead.
    local holder = stripped:match('([%w_]+)%s*%.%s*AppendSets%s*%(');
    if (holder ~= nil) then
        return holder;
    end
    if (stripped:find('gFunc%s*%.%s*LoadFile') ~= nil) then
        return 'another file';
    end
    return nil;
end

M.FindBadLevelCalls = function(stripped)
    local out = {};
    local init = 1;
    while true do
        local fs, fe = string.find(stripped, 'gData%s*%.%s*EvaluateLevels', init);
        if (fs == nil) then
            break;
        end
        local line = 1;
        for _ in string.gmatch(string.sub(stripped, 1, fs), '\n') do
            line = line + 1;
        end
        table.insert(out, { line = line, first = fs, last = fe });
        init = fe + 1;
    end
    return out;
end

-- A ladder is only collapsed by gFunc.EvaluateLevels. Without it EquipSet hands the whole list
-- to Equip, which returns early because a list has no Name, so the slot equips nothing. Native
-- only: BasicLuas rebuilds through CurrentLevel.
M.FindDeadLadders = function(model, text)
    local out = {};
    if (model == nil) or (model.kind ~= 'native') or M.CallsEvaluateLevels(text or '') then
        return out;
    end
    for _, s in ipairs(model.sets or {}) do
        if (not s.deleted) and s.isPriority and (s.slots ~= nil) then
            local ladders = 0;
            for _, slot in ipairs(prof.SlotNames) do
                local v = s.slots[slot];
                if (v ~= nil) and (v.kind == 'chain') and (#(v.entries or {}) > 1) then
                    ladders = ladders + 1;
                end
            end
            if (ladders > 0) then
                out[#out + 1] = { set = s.name, ladders = ladders };
            end
        end
    end
    return out;
end

-- helpers is the set from HelpersNeedingAction, loaded by the caller because
-- this module deliberately touches no disk and no Ashita call.
M.Analyze = function(model, helpers)
    local text = model.textAtLoad;
    local stripped = prof.StripComments(text);
    local handlers = M.ExtractHandlers(text, stripped);

    local referenced = {};
    local function MarkName(name)
        local s = prof.FindSet(model, name);
        if (s ~= nil) then
            referenced[string.lower(s.name)] = true;
            local twinName = s.isPriority and s.logicalName or (s.name .. '_Priority');
            local twin = prof.FindSet(model, twinName);
            if (twin ~= nil) then
                referenced[string.lower(twin.name)] = true;
            end
        end
    end

    local analysis = { handlers = {}, typos = {}, dead = {}, refIndex = {},
        handsOff = M.HandsSetsOff(stripped),
        actionless = M.FindActionlessReads(text, stripped, helpers),
        badLevelCalls = M.FindBadLevelCalls(stripped),
        deadLadders = M.FindDeadLadders(model, text) };

    local orderedHandlers = {};
    for _, name in ipairs(M.HandlerNames) do
        if (handlers[name] ~= nil) then
            table.insert(orderedHandlers, handlers[name]);
        end
    end

    local fileScope = stripped;
    for _, h in ipairs(orderedHandlers) do
        fileScope = fileScope:sub(1, h.startIndex - 1)
            .. string.rep(' ', h.endIndex - h.startIndex + 1)
            .. fileScope:sub(h.endIndex + 1);
    end

    for _, h in ipairs(orderedHandlers) do
        local entry = { name = h.name, source = h.source, startLine = h.startLine, refs = {} };
        local refs = M.ExtractRefs(h.strippedSource);
        local seenInHandler = {};
        for _, ref in ipairs(refs) do
            local resolved = M.ResolveRef(model, ref);
            local line = h.startLine;
            for _ in string.gmatch(h.strippedSource:sub(1, ref.index), '\n') do
                line = line + 1;
            end
            local display = { name = ref.name, kind = ref.kind, line = line, resolved = resolved };
            table.insert(entry.refs, display);
            if (resolved ~= nil) then
                if (resolved.kind == 'prefix') then
                    for _, m in ipairs(resolved.matches) do
                        MarkName(m);
                    end
                elseif (resolved.name ~= nil) then
                    MarkName(string.match(resolved.name, '^[^%.]+'));
                end
                if (resolved.kind ~= 'prefix') and (not seenInHandler[string.lower(ref.name)]) then
                    seenInHandler[string.lower(ref.name)] = true;
                end
            else
                table.insert(analysis.typos, {
                    handler = h.name, name = ref.name, kind = ref.kind, line = line,
                });
            end
        end
        table.insert(analysis.handlers, entry);
    end

    local scopeRefs = M.ExtractRefs(fileScope);
    for _, ref in ipairs(scopeRefs) do
        local resolved = M.ResolveRef(model, ref);
        if (resolved ~= nil) then
            if (resolved.kind == 'prefix') then
                for _, m in ipairs(resolved.matches) do
                    MarkName(m);
                end
            elseif (resolved.name ~= nil) then
                MarkName(string.match(resolved.name, '^[^%.]+'));
            end
        end
    end

    for _, name in ipairs(CollectCycleNames(stripped)) do
        MarkName(name);
    end

    for _, s in ipairs(model.sets) do
        if (s.baseSet ~= nil) then
            MarkName(string.match(s.baseSet, '^[^%.]+'));
        end
    end

    for _, s in ipairs(model.sets) do
        local pattern1 = '[\'"]' .. s.name:gsub('%W', '%%%1') .. '[\'"]';
        local init = 1;
        while true do
            local fs = string.find(stripped, pattern1, init);
            if (fs == nil) then
                break;
            end
            local before = (fs > 1) and stripped:sub(fs - 1, fs - 1) or '';
            if (before ~= '[') then
                MarkName(s.name);
                break;
            end
            init = fs + 1;
        end
    end

    for _, s in ipairs(model.sets) do
        if (s.kind == 'set') and (not referenced[string.lower(s.name)]) then
            table.insert(analysis.dead, s.name);
        end
    end

    return analysis;
end

return M;
