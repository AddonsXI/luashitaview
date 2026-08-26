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
* Turns edited sets back into LuAshitacast source text.
*
* Deliberately a superset of what LuAshitacast writes: it keeps array slots, BaseSet,
* NoWrite, Priority, Level and Quantity, which LAC silently drops, and it escapes
* augment strings, which LAC does not. Everything it emits, LAC loads happily.
*
* Pure Lua with no Ashita calls, so it runs under the test suite outside the game.
--]]

local prof = require('profile');

local M = {};

M.ValidateName = function(name)
    if (type(name) ~= 'string') or (#name == 0) then
        return false, 'A set needs a name.';
    end
    if (string.gsub(name, '[^%w%s_]+', '') ~= name) then
        return false, 'Set names can use letters, numbers, spaces, and underscores.';
    end
    if string.match(name, '^[_%d]') then
        return false, 'Set names cannot start with _ or a number.';
    end
    return true;
end

local function EscapeQuotes(s)
    return string.gsub(s, '\'', '\\\'');
end

local function SerializeItemInline(entry)
    local out = '{ Name = \'' .. EscapeQuotes(entry.name or '') .. '\'';
    if (entry.augment ~= nil) then
        if (type(entry.augment) == 'string') then
            out = out .. ', Augment = \'' .. EscapeQuotes(entry.augment) .. '\'';
        elseif (type(entry.augment) == 'table') then
            local augIndex = 1;
            out = out .. ', Augment = { ';
            for _, checkAugment in ipairs(entry.augment) do
                if (augIndex ~= 1) then
                    out = out .. ', ';
                end
                out = out .. '[' .. augIndex .. '] = \'' .. EscapeQuotes(checkAugment) .. '\'';
                augIndex = augIndex + 1;
            end
            out = out .. ' }';
        end
    end
    if (entry.augPath ~= nil) then
        out = out .. ', AugPath=\'' .. EscapeQuotes(tostring(entry.augPath)) .. '\'';
    end
    if (entry.augRank ~= nil) then
        out = out .. ', AugRank=' .. tostring(entry.augRank);
    end
    if (entry.augTrial ~= nil) then
        out = out .. ', AugTrial=' .. tostring(entry.augTrial);
    end
    if (entry.bag ~= nil) then
        if (type(entry.bag) == 'number') then
            out = out .. ', Bag=' .. tostring(entry.bag);
        else
            out = out .. ', Bag=\'' .. EscapeQuotes(tostring(entry.bag)) .. '\'';
        end
    end
    if (entry.priority ~= nil) then
        out = out .. ', Priority=' .. tostring(entry.priority);
    end
    if (entry.level ~= nil) then
        out = out .. ', Level=' .. tostring(entry.level);
    end
    if (entry.quantity ~= nil) then
        out = out .. ', Quantity=' .. tostring(entry.quantity);
    end
    return out .. ' }';
end

local function SerializeEntryValue(entry)
    local plain = (entry.augment == nil) and (entry.augPath == nil) and (entry.augRank == nil)
        and (entry.augTrial == nil) and (entry.bag == nil) and (entry.priority == nil)
        and (entry.level == nil) and (entry.quantity == nil);
    if plain then
        return '\'' .. EscapeQuotes(entry.name or '') .. '\'';
    end
    return SerializeItemInline(entry);
end

M.SerializeSet = function(setModel, opts)
    opts = opts or {};
    local screenOrder = (opts.screenOrder ~= false);
    local eol = opts.eol or '\n';
    local pieces = {};

    --[[
    * Comments come back in through their anchor rather than their old position,
    * because the set is rebuilt in screen order and the line a comment sat on
    * may not exist afterwards. Anything with no anchor is parked at the end:
    * moved, which is enormously better than deleted.
    --]]
    local byAnchor = {};
    local trailingFor = {};
    local pending = 0;
    for _, c in ipairs(setModel.comments or {}) do
        pending = pending + 1;
        if (c.anchor ~= nil) and (c.place == 'trailing') and (trailingFor[c.anchor] == nil) then
            trailingFor[c.anchor] = c;
        else
            byAnchor[c.anchor or false] = byAnchor[c.anchor or false] or {};
            table.insert(byAnchor[c.anchor or false], c);
        end
    end
    local function Emit(c)
        c.done = true;
        pending = pending - 1;
        table.insert(pieces, '        ' .. c.text .. eol);
    end
    local function Above(anchor)
        for _, c in ipairs(byAnchor[anchor] or {}) do
            if (not c.done) then Emit(c); end
        end
    end
    local function Trailing(anchor)
        local c = trailingFor[anchor];
        if (c == nil) or c.done then
            return '';
        end
        c.done = true;
        pending = pending - 1;
        return '  ' .. c.text;
    end

    table.insert(pieces, M.SetKey(setModel.name) .. ' = {'
        .. Trailing(prof.SET_ANCHOR) .. eol);
    Above(prof.SET_ANCHOR);
    if (setModel.baseSet ~= nil) then
        table.insert(pieces, '        BaseSet = \'' .. EscapeQuotes(setModel.baseSet) .. '\',' .. eol);
    end
    if (setModel.noWrite == true) then
        table.insert(pieces, '        NoWrite = true,' .. eol);
    end
    for i = 1, 16, 1 do
        local index = i;
        if screenOrder then
            index = prof.EquipScreenOrder[i];
        end
        local slot = prof.SlotNames[index];
        local key = string.lower(slot);
        local v = setModel.slots[slot];
        Above(key);
        local wrote = false;
        if (v ~= nil) then
            local outString = '        ' .. slot .. ' = ';
            local tail = ',' .. Trailing(key) .. eol;
            if (v.locked == true) and (v.raw ~= nil) then
                outString = outString .. v.raw .. tail;
                table.insert(pieces, outString);
                wrote = true;
            elseif (v.kind == 'item') and (v.item ~= nil) then
                outString = outString .. SerializeEntryValue(v.item) .. tail;
                table.insert(pieces, outString);
                wrote = true;
            elseif (v.kind == 'chain') and (v.entries ~= nil) then
                local parts = {};
                for _, entry in ipairs(v.entries) do
                    table.insert(parts, SerializeEntryValue(entry));
                end
                -- An empty list is written back rather than dropped. The slot key is the
                -- author's, and omitting it would silently delete a line they wrote.
                if (#parts == 0) then
                    outString = outString .. '{ }' .. tail;
                else
                    outString = outString .. '{ ' .. table.concat(parts, ', ') .. ' }' .. tail;
                end
                table.insert(pieces, outString);
                wrote = true;
            elseif (v.kind == 'opaque') and (v.raw ~= nil) then
                outString = outString .. v.raw .. tail;
                table.insert(pieces, outString);
                wrote = true;
            end
        end
        -- The slot it trailed is gone, so it becomes a line of its own rather
        -- than trailing nothing.
        if (not wrote) and (trailingFor[key] ~= nil) and (not trailingFor[key].done) then
            Emit(trailingFor[key]);
        end
    end
    for _, ex in ipairs(setModel.extraKeys or {}) do
        if (ex.raw ~= nil) then
            local keyText = ex.key;
            local exKey = string.lower(ex.key);
            if (string.match(keyText, '^[%a_][%w_]*$') == nil) then
                keyText = '[\'' .. EscapeQuotes(keyText) .. '\']';
            end
            Above(exKey);
            table.insert(pieces, '        ' .. keyText .. ' = ' .. ex.raw .. ','
                .. Trailing(exKey) .. eol);
        end
    end
    --[[
    * Everything still unplaced, in file order. Comments with no anchor land
    * here, and so does anything anchored to a key neither loop above emits:
    * BaseSet, NoWrite, and the pseudo slots Rings and Ears, which are real
    * keys in a profile and are not one of the sixteen. 119 sets lost a comment
    * to exactly that gap before this existed, so the catch-all is the rule
    * rather than the special case.
    --]]
    if (pending > 0) then
        for _, c in ipairs(setModel.comments or {}) do
            if (not c.done) then Emit(c); end
        end
    end
    table.insert(pieces, '    }');
    return table.concat(pieces);
end

local function Rescan(text)
    local anchor, keys, tableEnd = prof.ScanProfileKeys(text);
    if (anchor == nil) then
        return nil, nil, nil, 'Could not find the sets table.';
    end
    return anchor, keys, tableEnd;
end

local function FindKey(keys, name)
    for _, entry in ipairs(keys) do
        if (entry.Name == name) then
            return entry;
        end
    end
    return nil;
end

local function DetectEol(text)
    return (string.find(text, '\r\n', 1, true) ~= nil) and '\r\n' or '\n';
end

M.ReplaceSet = function(text, name, body)
    local anchor, keys, tableEnd, err = Rescan(text);
    if (anchor == nil) then
        return nil, err;
    end
    local entry = FindKey(keys, name);
    if (entry == nil) then
        return nil, 'Set not found: ' .. name;
    end
    local startIndex = entry.StartIndex;
    if (entry.Form == 'statement') and (text:byte(entry.StartIndex) ~= string.byte('[')) then
        --[[
        * A dot-declared statement reads sets.Name = { ... }, and the range starts at the
        * Name, so a bracket-key body would splice into sets.['Name'], which is not Lua.
        * Matched on the body's own shape, not the old name, since a rename carries a new
        * name. A name that cannot be a dot key (a space, a leading digit) widens the
        * splice to the statement head and rewrites it in bracket form.
        --]]
        local key, rest = string.match(body, '^%[\'(.-)\'%]%s*=%s*(.*)$');
        if (key ~= nil) then
            if string.match(key, '^[%a_][%w_]*$') then
                body = key .. ' = ' .. rest;
            elseif (entry.StmtStart ~= nil) then
                local head = string.sub(text, entry.StmtStart, entry.StartIndex - 2);
                body = head .. '[\'' .. key .. '\'] = ' .. rest;
                startIndex = entry.StmtStart;
            end
        end
    end
    local suffix = string.sub(text, entry.EndIndex + 1);
    if (entry.Form == nil) and string.match(suffix, '^[ \t]*}') then
        body = body .. DetectEol(text);
    end
    return string.sub(text, 1, startIndex - 1) .. body .. suffix;
end

M.AppendSet = function(text, body)
    local anchor, keys, tableEnd, err = Rescan(text);
    if (anchor == nil) then
        return nil, err;
    end
    local eol = DetectEol(text);
    -- Only entries inside the literal are candidates to append after. A statement set
    -- lives past the closing brace, and appending after one would write the new set
    -- outside the table, which compiles as garbage.
    local last = nil;
    for _, e in ipairs(keys) do
        if (e.Form == nil) then
            last = e;
        end
    end
    if (last == nil) then
        return string.sub(text, 1, anchor.BraceIndex) .. eol .. '    ' .. body .. ',' .. eol .. string.sub(text, tableEnd);
    end
    return string.sub(text, 1, last.EndIndex) .. ',' .. eol .. '    ' .. body .. string.sub(text, last.EndIndex + 1);
end

M.DeleteSet = function(text, name)
    local anchor, keys, tableEnd, err = Rescan(text);
    if (anchor == nil) then
        return nil, err;
    end
    local entry = FindKey(keys, name);
    if (entry == nil) then
        return nil, 'Set not found: ' .. name;
    end
    -- Deleting a statement set removes the whole statement: cutting only the key and
    -- table would leave the dangling head 'sets.' behind.
    local s = entry.StmtStart or entry.StartIndex;
    local e = entry.EndIndex;
    local lineStart = s;
    while (lineStart > 1) do
        local b = text:byte(lineStart - 1);
        if (b == string.byte(' ')) or (b == string.byte('\t')) then
            lineStart = lineStart - 1;
        else
            break;
        end
    end
    local atLineStart = (lineStart == 1) or (text:byte(lineStart - 1) == string.byte('\n'));
    if atLineStart then
        s = lineStart;
    end
    local len = #text;
    local i = e + 1;
    while (i <= len) and ((text:byte(i) == string.byte(' ')) or (text:byte(i) == string.byte('\t'))) do
        i = i + 1;
    end
    local separator = (entry.Form == 'statement') and string.byte(';') or string.byte(',');
    if (i <= len) and (text:byte(i) == separator) then
        i = i + 1;
        local j = i;
        while (j <= len) and ((text:byte(j) == string.byte(' ')) or (text:byte(j) == string.byte('\t'))) do
            j = j + 1;
        end
        if (j <= len) and (text:byte(j) == string.byte('\r')) then
            j = j + 1;
        end
        if (j <= len) and (text:byte(j) == string.byte('\n')) and atLineStart then
            i = j + 1;
        end
        e = i - 1;
    end
    return string.sub(text, 1, s - 1) .. string.sub(text, e + 1);
end

M.ValidateResult = function(text, expectedNames)
    local chunk, err = loadstring(text, '@validate');
    if (chunk == nil) then
        return false, 'Edited file would not compile: ' .. tostring(err);
    end
    local anchor, keys, tableEnd, scanErr = Rescan(text);
    if (anchor == nil) then
        return false, scanErr;
    end
    local found = {};
    for _, entry in ipairs(keys) do
        found[entry.Name] = true;
    end
    for _, name in ipairs(expectedNames or {}) do
        if (not found[name]) then
            return false, 'After the edit, the set could not be found: ' .. name;
        end
    end
    --[[
    * Both halves are checked on purpose. The reader can find the sets through the
    * file's own local, so finding them does not prove the file still returns anything
    * LuAshitacast can load; the returned value is checked separately.
    --]]
    local runtime, result = prof.SandboxProfile(text, 'validate', anchor);
    if (type(result) ~= 'table') then
        return false, 'Edited file no longer returns a profile.';
    end
    if (runtime == nil) then
        return false, 'Edited file no longer returns a profile with sets.';
    end
    for _, name in ipairs(expectedNames or {}) do
        if (runtime[name] == nil) then
            return false, 'Edited file lost the set: ' .. name;
        end
    end
    return true;
end

M.ApplyEdits = function(text, edits, opts)
    local merged = { screenOrder = (opts or {}).screenOrder, eol = (opts or {}).eol or DetectEol(text) };
    opts = merged;
    local expectPresent = {};
    for _, edit in ipairs(edits) do
        local newText, err;
        if (edit.op == 'replace') then
            local body = edit.body or M.SerializeSet(edit.set, opts);
            newText, err = M.ReplaceSet(text, edit.name, body);
            table.insert(expectPresent, (edit.set and edit.set.name) or edit.name);
        elseif (edit.op == 'append') then
            local body = edit.body or M.SerializeSet(edit.set, opts);
            newText, err = M.AppendSet(text, body);
            table.insert(expectPresent, (edit.set and edit.set.name) or edit.name);
        elseif (edit.op == 'delete') then
            newText, err = M.DeleteSet(text, edit.name);
        elseif (edit.op == 'fixlevelcall') then
            newText, err = M.FixLevelCalls(text);
        elseif (edit.op == 'renamerefs') then
            newText, err = M.RenameRefs(text, edit.sites, edit.oldName, edit.newName);
        elseif (edit.op == 'insertline') then
            newText, err = M.InsertLine(text, edit.at, edit.line, opts.eol);
        elseif (edit.op == 'replacespan') then
            newText, err = M.ReplaceSpan(text, edit.s, edit.e, edit.text);
        elseif (edit.op == 'installownedfilter') then
            newText, err = M.InstallOwnedFilter(text, edit.blockAt, edit.callAt,
                edit.kind, opts.eol, edit.indent);
        elseif (edit.op == 'removeownedfilter') then
            newText, err = M.RemoveOwnedFilter(text);
        else
            return nil, 'Unknown edit: ' .. tostring(edit.op);
        end
        if (newText == nil) then
            return nil, err;
        end
        text = newText;
    end
    local ok, err = M.ValidateResult(text, expectPresent);
    if (not ok) then
        return nil, err;
    end
    return text;
end

--[[
* Repoint gData.EvaluateLevels at gFunc, which is the only namespace that has it.
* Both names are five characters, so every byte offset in the file survives untouched
* and the match is located in the comment-stripped copy so prose is never rewritten.
--]]
M.FixLevelCalls = function(text)
    local stripped = prof.StripComments(text);
    local out = text;
    local count = 0;
    local init = 1;
    while true do
        local fs = string.find(stripped, 'gData%s*%.%s*EvaluateLevels', init);
        if (fs == nil) then
            break;
        end
        if (string.sub(out, fs, fs + 4) == 'gData') then
            out = string.sub(out, 1, fs - 1) .. 'gFunc' .. string.sub(out, fs + 5);
            count = count + 1;
        end
        init = fs + 1;
    end
    if (count == 0) then
        return nil, 'Nothing to fix: gData.EvaluateLevels not found.';
    end
    return out, count;
end

--[[
* Not repair code, and nothing in the addon calls it. It exists for the test suite, which
* compares our scanner against LuAshitacast's own parser: LAC splits a set table on
* commas only, so the stray semicolons that ship inside BasicLuas templates have to be
* normalized before the two can be compared at identical indices.
*
* The scanner itself treats a depth-1 semicolon as a comma, so real files need no repair.
--]]
--[[
* Rewrites the spans rules.FindRenameSites located, back to front so that every index
* stays valid as the text shortens or grows underneath them.
*
* It refuses rather than guessing: if a span does not still hold the old name, the file
* has moved under us and nothing is written.
--]]
M.RenameRefs = function(text, sites, oldName, newName)
    if (sites == nil) or (#sites == 0) then
        return text, 0;
    end
    local ordered = {};
    for _, site in ipairs(sites) do
        table.insert(ordered, site);
    end
    table.sort(ordered, function(a, b) return a.s > b.s; end);

    local out = text;
    for _, site in ipairs(ordered) do
        if (string.sub(out, site.s, site.e) ~= oldName) then
            return nil, 'File changed while renaming; nothing was written.';
        end
        out = string.sub(out, 1, site.s - 1) .. newName .. string.sub(out, site.e + 1);
    end
    return out, #ordered;
end

--[[
* Puts one line into the file at an index the caller located, which is rule five: the
* writer never searches, it only splices where it was told.
--]]
M.InsertLine = function(text, at, line, eol)
    if (type(at) ~= 'number') or (at < 1) or (at > #text + 1) then
        return nil, 'Insert point moved; nothing was written.';
    end
    return string.sub(text, 1, at - 1) .. line .. (eol or '\n') .. string.sub(text, at);
end

--[[
* The body of a HandleDefault that wears a different set resting, fighting and otherwise.
*
* This is not an invention: 215 profiles in the corpus test player.Status against
* 'Engaged' and 177 against 'Resting', so it is the shape the ecosystem already writes.
* Anything left unchosen is simply left out, so picking one set produces one line.
--]]
local Reserved = {
    ['and'] = true, ['break'] = true, ['do'] = true, ['else'] = true, ['elseif'] = true,
    ['end'] = true, ['false'] = true, ['for'] = true, ['function'] = true, ['goto'] = true,
    ['if'] = true, ['in'] = true, ['local'] = true, ['nil'] = true, ['not'] = true,
    ['or'] = true, ['repeat'] = true, ['return'] = true, ['then'] = true, ['true'] = true,
    ['until'] = true, ['while'] = true,
};

--[[
* Dot form where the name is an identifier, bracket form otherwise. A set really
* can be called 'EP Set', and sets.EP Set does not compile.
--]]
local function PlainName(name)
    return (name:match('^[%a_][%w_]*$') ~= nil) and (not Reserved[name]);
end

M.SetRef = function(name)
    name = tostring(name or '');
    if PlainName(name) then
        return 'sets.' .. name;
    end
    return 'sets[' .. string.format('%q', name) .. ']';
end

--[[
* A set's own key when we create one: bare where the name is a plain identifier,
* bracket form otherwise, so a set we write looks like the ones people write.
--]]
M.SetKey = function(name)
    name = tostring(name or '');
    if PlainName(name) then
        return name;
    end
    return '[\'' .. EscapeQuotes(name) .. '\']';
end

M.DefaultHandlerBlock = function(idle, resting, engaged, eol)
    eol = eol or '\n';
    local branches = {};
    if (resting ~= nil) then
        table.insert(branches, { "if (player.Status == 'Resting') then", resting });
    end
    if (engaged ~= nil) then
        local word = (#branches == 0) and 'if' or 'elseif';
        table.insert(branches, { word .. " (player.Status == 'Engaged') then", engaged });
    end

    local out = {};
    if (#branches == 0) then
        if (idle == nil) then
            return nil, 'Nothing selected.';
        end
        table.insert(out, '    gFunc.EquipSet(' .. M.SetRef(idle) .. ');');
        return table.concat(out, eol);
    end

    table.insert(out, '    local player = gData.GetPlayer();');
    for _, b in ipairs(branches) do
        table.insert(out, '    ' .. b[1]);
        table.insert(out, '        gFunc.EquipSet(' .. M.SetRef(b[2]) .. ');');
    end
    if (idle ~= nil) then
        table.insert(out, '    else');
        table.insert(out, '        gFunc.EquipSet(' .. M.SetRef(idle) .. ');');
    end
    table.insert(out, '    end');
    return table.concat(out, eol);
end

--[[
* Swaps one located span for new text. Rule five again: the caller found it, the writer
* only splices. An empty span, where s is one past e, is an insert.
--]]
M.ReplaceSpan = function(text, s, e, replacement)
    if (type(s) ~= 'number') or (type(e) ~= 'number') or (s < 1) or (e > #text) or (s > e + 1) then
        return nil, 'That part of the file moved; nothing was written.';
    end
    return string.sub(text, 1, s - 1) .. replacement .. string.sub(text, e + 1);
end

--[[ ---------------------------------------------------------------------
    THE OWNED GEAR FILTER

    LuAshitacast picks the first entry in a _Priority list whose level you meet
    and never looks in your bags, so a piece you have not bought yet wins its
    slot, finds nothing to equip, and that slot quietly stops swapping. Thorny
    closed the feature request telling people to solve it in their own profile,
    so writing it in is the sanctioned route rather than a workaround.

    Every addon runs in its own Lua state, so luashitaview cannot reach LAC's
    gFunc or its sets table from outside. The fix has to live in the file.

    The source is Bitcoin_PUP.lua lines 528 to 652, in live use and measured at
    0.0011 ms per frame, with every name prefixed lsv so nothing
    can collide with the profile's own. It reads profile.Sets rather than a
    local named sets, because that local's name differs per dialect while
    profile.Sets is how LAC itself finds them.

    This block SHIPS INTO A STRANGER'S FILE, which is the one place the no
    comments rule does not apply: they have to be able to read what appeared
    in their profile. Density follows the PUP original.
--------------------------------------------------------------------- ]]--

M.FILTER_OPEN  = '-- >>> luashitaview owned-gear filter >>>';
M.FILTER_CLOSE = '-- <<< luashitaview owned-gear filter <<<';
M.FILTER_CALL  = 'lsvRefreshOwnedGear();';

-- Level delimited: the block itself contains a --]] comment, which would
-- close a plain long string early.
local FILTER_BODY = [==[
--[[
* Makes every _Priority list fall back only to gear you actually own.
*
* LuAshitacast picks the first entry whose level you meet and never checks your
* bags, so a piece you have not bought yet wins its slot, finds nothing to
* equip, and that slot stops swapping until you buy it.
*
* This rechecks a few seconds after your bags change, so buying something is
* picked up on its own. If any part of it fails it turns itself off and the
* profile behaves exactly as it would without it.
--]]
local lsvPristine = nil;
local lsvBagCounter = -1;
local lsvLastRun = 0;

-- Remembers the lists exactly as you typed them, so filtering always runs from
-- your original text rather than from an already filtered copy.
local function lsvRemember()
    lsvPristine = {};
    for setName, setBody in pairs(profile.Sets or {}) do
        if (type(setName) == 'string') and (#setName > 9)
            and (string.sub(setName, -9) == '_Priority') and (type(setBody) == 'table') then
            local slots = {};
            for slotName, entries in pairs(setBody) do
                if (type(entries) == 'table') and (entries[1] ~= nil) then
                    local copy = {};
                    for i, entry in ipairs(entries) do
                        copy[i] = entry;
                    end
                    slots[slotName] = copy;
                end
            end
            lsvPristine[setName] = slots;
        end
    end
end

-- Every item name sitting in a bag you can equip out of.
local function lsvOwned()
    local owned = {};
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    local resources = AshitaCore:GetResourceManager();
    local bags = gSettings and gSettings.EquipBags;
    if (type(bags) ~= 'table') then
        bags = { 0, 8, 10, 11, 12, 13, 14, 15, 16 };
    end
    for _, bag in ipairs(bags) do
        local count = inventory:GetContainerCountMax(bag);
        if (type(count) == 'number') then
            for slotIndex = 0, count do
                local item = inventory:GetContainerItem(bag, slotIndex);
                if (item ~= nil) and (item.Id ~= 0) and (item.Id ~= 65535) and (item.Count > 0) then
                    local resource = resources:GetItemById(item.Id);
                    if (resource ~= nil) then
                        owned[string.lower(resource.Name[1])] = true;
                    end
                end
            end
        end
    end
    return owned;
end

-- Rewrites the live lists down to the gear you have.
local function lsvApply()
    if (lsvPristine == nil) then
        lsvRemember();
    end
    local owned = lsvOwned();

    -- An empty scan means the inventory is not loaded yet. Do nothing rather
    -- than empty every list.
    if (next(owned) == nil) then
        return false;
    end

    for setName, slots in pairs(lsvPristine) do
        local live = (profile.Sets or {})[setName];
        if (type(live) == 'table') then
            for slotName, entries in pairs(slots) do
                local kept = {};
                for _, entry in ipairs(entries) do
                    local itemName = entry;
                    if (type(entry) == 'table') then
                        itemName = entry.Name;
                    end
                    if (type(itemName) == 'string') and (owned[string.lower(itemName)] == true) then
                        kept[#kept + 1] = entry;
                    end
                end
                if (#kept > 0) then
                    live[slotName] = kept;
                else
                    -- You own nothing in this list, so leave the slot alone
                    -- rather than swapping to something you cannot wear.
                    live[slotName] = nil;
                end
            end
        end
    end
@TAIL@
    return true;
end

-- Runs once at the start, then a few seconds after anything in your bags moves.
local function lsvRefreshOwnedGear()
    local ok, counter = pcall(function()
        return AshitaCore:GetMemoryManager():GetInventory():GetContainerUpdateCounter();
    end);
    if (not ok) or (type(counter) ~= 'number') or (counter == lsvBagCounter) then
        return;
    end
    local now = os.time();
    if (now - lsvLastRun < 3) then
        return;
    end
    local applied, changed = pcall(lsvApply);
    if applied and (changed == true) then
        lsvBagCounter = counter;
    end
    lsvLastRun = now;
end]==];

--[[
* The tail is the one dialect difference, and both halves are read out of the
* frameworks rather than guessed. BasicLuas keeps a global CurrentLevel
* (blinclude.lua:55) and rebuilds when it does not match the synced level
* (blinclude.lua:573), so zeroing it forces the rebuild. A native profile has
* nobody to do that for it and calls EvaluateLevels itself; func.lua:325 shows
* it mutates the table in place and returns nothing.
--]]
local FILTER_TAILS = {
    basiclua = '    -- Make BasicLuas rebuild the finished sets from the filtered lists.\n'
        .. '    CurrentLevel = 0;',
    native = '    -- Rebuild the finished sets from the filtered lists.\n'
        .. '    gFunc.EvaluateLevels(profile.Sets, gData.GetPlayer().MainJobSync);',
};

--[[
* True when the profile already drops unowned gear out of its own _Priority lists.
* Thorny tells people to solve this in their own profile, so hand written copies
* exist, and ours cannot see them: the names are whatever that author chose.
*
* Installing a second one is worse than installing none. Both snapshot the original
* lists on their first run, so whichever runs second snapshots an already filtered
* copy as its original. Gear bought later comes back through one filter and is
* wiped again by the other, which is the exact case both exist to handle.
*
* The signal is reading the bags AND testing set names for _Priority at run time.
* Across 656 corpus profiles that matches 5, every one of them a file that really
* does this, and none of the 651 written by anyone else.
--]]
M.AlreadyFiltersOwnership = function(text)
    if (type(text) ~= 'string') then
        return false;
    end
    local scan = prof.StripComments(text);
    if (not string.find(scan, 'GetInventory', 1, true)) then
        return false;
    end
    return (string.find(scan, "'_Priority'", 1, true) ~= nil)
        or (string.find(scan, '"_Priority"', 1, true) ~= nil);
end

--[[
* Whether the file skips equipment you do not own, by any route: the block this addon
* writes, or one somebody wrote themselves.
*
* This is the question the grid and the unowned panel want. OwnedFilterPresent is the
* narrower one and means only that OUR block is in there, which is what Turn Off needs
* since that is all we can take back out.
--]]
M.SkipsUnowned = function(text)
    return M.OwnedFilterPresent(text) or M.AlreadyFiltersOwnership(text);
end

M.OwnedFilterPresent = function(text)
    if (type(text) ~= 'string') then
        return false;
    end
    return string.find(text, M.FILTER_OPEN, 1, true) ~= nil;
end

M.BuildOwnedFilterBlock = function(kind, eol)
    local tail = FILTER_TAILS[kind];
    if (tail == nil) then
        return nil, 'This profile type is not supported by the filter: ' .. tostring(kind);
    end
    local body = string.gsub(FILTER_BODY, '@TAIL@', (string.gsub(tail, '%%', '%%%%')));
    local block = M.FILTER_OPEN .. '\n' .. body .. '\n' .. M.FILTER_CLOSE;
    if (eol ~= nil) and (eol ~= '\n') then
        block = string.gsub(block, '\n', eol);
    end
    return block;
end

--[[
* Two inserts in one edit. The later index goes first, because inserting at the
* earlier one shifts every index after it.
--]]
M.InstallOwnedFilter = function(text, blockAt, callAt, kind, eol, indent)
    if M.OwnedFilterPresent(text) then
        return nil, 'This profile already has the filter.';
    end
    if (type(blockAt) ~= 'number') or (type(callAt) ~= 'number')
        or (blockAt < 1) or (callAt < 1) or (blockAt > #text + 1) or (callAt > #text + 1) then
        return nil, 'Insert points moved; nothing was written.';
    end
    if (blockAt >= callAt) then
        return nil, 'The filter must be declared before the handler that calls it.';
    end
    local block, err = M.BuildOwnedFilterBlock(kind, eol);
    if (block == nil) then
        return nil, err;
    end
    eol = eol or '\n';
    local out = M.InsertLine(text, callAt, (indent or '    ') .. M.FILTER_CALL, eol);
    if (out == nil) then
        return nil, 'Handler moved; nothing was written.';
    end
    out = M.InsertLine(out, blockAt, eol .. block, eol);
    if (out == nil) then
        return nil, 'Sets table moved; nothing was written.';
    end
    return out;
end

--[[
* Removal is by exact text rather than by remembered offsets, because the file
* may have been edited since. Both pieces must be found or nothing is touched.
--]]
M.RemoveOwnedFilter = function(text)
    local openAt = string.find(text, M.FILTER_OPEN, 1, true);
    local closeAt = string.find(text, M.FILTER_CLOSE, 1, true);
    if (openAt == nil) or (closeAt == nil) or (closeAt < openAt) then
        return nil, 'Filter not found in this file; nothing was written.';
    end
    local callAt = string.find(text, M.FILTER_CALL, 1, true);
    if (callAt == nil) then
        return nil, 'Filter block is here, but its call is gone. '
            .. 'Nothing was written, so you can remove it by hand.';
    end

    -- Whole lines, including the line break each one sits on, so no blank line
    -- is left where the filter used to be.
    local function LineSpan(at, tailLen)
        local s = (string.sub(text, 1, at - 1):match('.*()\n') or 0) + 1;
        local e = string.find(text, '\n', at + tailLen, true) or #text;
        return s, e;
    end

    local blockStart = LineSpan(openAt, #M.FILTER_OPEN);
    local _, blockEnd = LineSpan(closeAt, #M.FILTER_CLOSE);
    local callStart, callEnd = LineSpan(callAt, #M.FILTER_CALL);
    if (callStart > blockStart) and (callStart < blockEnd) then
        return nil, 'The call is inside the block. Nothing was written.';
    end

    -- Back to front, so the first cut cannot move the second.
    local first = { s = blockStart, e = blockEnd };
    local second = { s = callStart, e = callEnd };
    if (second.s < first.s) then
        first, second = second, first;
    end
    local out = string.sub(text, 1, second.s - 1) .. string.sub(text, second.e + 1);
    out = string.sub(out, 1, first.s - 1) .. string.sub(out, first.e + 1);

    -- The block is preceded by one blank line put there on install.
    local before = string.sub(out, 1, first.s - 1);
    local trimmed = string.gsub(before, '(\r?\n)%s*\r?\n$', '%1');
    return trimmed .. string.sub(out, first.s);
end

M.FixStraySemicolons = function(text)
    local anchor = prof.FindAnchor(text);
    if (anchor == nil) then
        return text, 0;
    end
    local _, tableEnd = prof.ScanSets(text, anchor.BraceIndex + 1);
    local singleQuote = string.byte('\'');
    local doubleQuote = string.byte('\"');
    local escapeSlash = string.byte('\\');
    local lineBreak = string.byte('\n');
    local i = anchor.BraceIndex + 1;
    local depth = 1;
    local stringState = 'none';
    local commentState = 'none';
    local prevNonWs = '{';
    local repl = {};
    while (i <= tableEnd) and (depth > 0) do
        local b = text:byte(i);
        local c = string.char(b);
        if commentState == 'block' then
            if text:sub(i, i + 1) == ']]' then
                commentState = 'none';
                i = i + 1;
            end
        elseif commentState == 'line' then
            if (b == lineBreak) then
                commentState = 'none';
            end
        elseif stringState == 'single' then
            if (b == singleQuote) then
                stringState = 'none';
            elseif (b == escapeSlash) then
                i = i + 1;
            end
        elseif stringState == 'double' then
            if (b == doubleQuote) then
                stringState = 'none';
            elseif (b == escapeSlash) then
                i = i + 1;
            end
        elseif text:sub(i, i + 3) == '--[[' then
            commentState = 'block';
            i = i + 3;
        elseif text:sub(i, i + 1) == '--' then
            commentState = 'line';
            i = i + 1;
        elseif (b == singleQuote) then
            stringState = 'single';
            prevNonWs = c;
        elseif (b == doubleQuote) then
            stringState = 'double';
            prevNonWs = c;
        elseif (c == '{') then
            depth = depth + 1;
            prevNonWs = c;
        elseif (c == '}') then
            depth = depth - 1;
            prevNonWs = c;
        elseif (c == ';') and (depth == 1) then
            local with = ((prevNonWs == ',') or (prevNonWs == '{')) and ' ' or ',';
            table.insert(repl, { index = i, with = with });
            prevNonWs = ',';
        elseif (not string.match(c, '%s')) then
            prevNonWs = c;
        end
        i = i + 1;
    end
    if (#repl == 0) then
        return text, 0;
    end
    local parts = {};
    local last = 1;
    for _, r in ipairs(repl) do
        table.insert(parts, string.sub(text, last, r.index - 1));
        table.insert(parts, r.with);
        last = r.index + 1;
    end
    table.insert(parts, string.sub(text, last));
    return table.concat(parts), #repl;
end

return M;
