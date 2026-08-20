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
* Reads a LuAshitacast profile without running it.
*
* Profiles are ordinary Lua, so the only way to know what a set contains is to look at
* the file. Sets are found by scanning the source for their byte ranges, which is what
* lets an edit be spliced back in without rewriting anything around it. The file is
* also loaded in a sandbox, so a profile that builds sets in code still yields values
* to look at, but the raw source text is what gets written back.
*
* Pure Lua with no Ashita calls, so it runs under the test suite outside the game.
--]]

local M = {};

--[[
* The bytes this file compares against while scanning. Named because a bare 61 in the
* middle of a bracket test says nothing, and computed from the character itself so a
* name and its value can never drift apart.
--]]
local BYTE_QUOTE  = string.byte("'");
local BYTE_DQUOTE = string.byte('"');
local BYTE_EQUALS = string.byte('=');
local BYTE_RBRACK = string.byte(']');
local BYTE_LBRACE = string.byte('{');
local BYTE_RBRACE = string.byte('}');

M.SlotNames = {
    'Main', 'Sub', 'Range', 'Ammo', 'Head', 'Body', 'Hands', 'Legs',
    'Feet', 'Neck', 'Waist', 'Ear1', 'Ear2', 'Ring1', 'Ring2', 'Back',
};

M.EquipScreenOrder = { 1, 2, 3, 4, 5, 10, 12, 13, 6, 7, 14, 15, 16, 11, 8, 9 };

M.SlotIndex = {};
for i, name in ipairs(M.SlotNames) do
    M.SlotIndex[string.lower(name)] = i;
end

M.Sentinels = { remove = true, displaced = true, ignore = true };

local AnchorLiterals = {
    'local sets = {',
    'local Sets = {',
    'profile.Sets = {',
    'local sets = T{',
    'local Sets = T{',
    'profile.Sets = T{',
};

--[[
* The literals above cover a job profile. A shared include declares its table against
* its own name instead (blsets.sets = T{), so those are matched by shape, and the case
* of the key is not fixed: blsets uses a lowercase sets.
--]]
local AnchorPattern = '()[%a_][%w_]*%.[Ss]ets%s*=%s*T?%s*{';

M.FindAnchor = function(text)
    for _, literal in ipairs(AnchorLiterals) do
        local s = string.find(text, literal, 1, true);
        if (s ~= nil) then
            return { Start = s, BraceIndex = s + #literal - 1, Literal = literal };
        end
    end

    local s, e = string.find(text, AnchorPattern);
    if (s ~= nil) then
        return { Start = s, BraceIndex = e, Literal = string.sub(text, s, e) };
    end

    return nil;
end

--[[
* Every set declared inside the sets table literal, as exact byte ranges into the
* real file. Ranges rather than values, because editing one means splicing those
* bytes back out and leaving every other byte of the profile untouched.
--]]
M.ScanSets = function(wholeFile, startIndex)
    local comma = string.byte(',');
    local semicolon = string.byte(';');
    local openBracket = string.byte('[');
    local closeBracket = string.byte(']');
    local parenthesisOpen = string.byte('{');
    local parenthesisClose = string.byte('}');
    local escapeSlash = string.byte('\\');
    local equalSign = string.byte('=');
    local singleQuote = string.byte('\'');
    local doubleQuote = string.byte('\"');
    local lineBreak = string.byte('\n');
    local underscore = string.byte('_');
    local function isLetter(byte)
        if ((byte >= 65) and (byte <= 90)) then
            return true;
        end
        return ((byte >= 97) and (byte <= 122));
    end
    local function isNumber(byte)
        return ((byte >= 48) and (byte <= 57));
    end

    local parenthesisCount = 1;
    local commentState = 'none';
    local stringState = 'none';
    local entryName = '';
    local entryState = 'none';
    local entryStart = 0;

    local keyIndices = {};
    local i = startIndex;
    local len = #wholeFile;
    while i <= len do
        local byte = wholeFile:byte(i);

        if commentState == 'blockcomment' then
            if string.sub(wholeFile, i, i + 1) == ']]' then
                commentState = 'none';
                i = i + 1;
            end
        elseif commentState == 'comment' then
            if byte == lineBreak then
                commentState = 'none';
            end
        elseif stringState == 'singlequote' then
            if byte == singleQuote then
                stringState = 'none';
            elseif byte == escapeSlash then
                i = i + 1;
            end
        elseif stringState == 'doublequote' then
            if byte == doubleQuote then
                stringState = 'none';
            elseif byte == escapeSlash then
                i = i + 1;
            end
        elseif string.sub(wholeFile, i, i + 3) == '--[[' then
            commentState = 'blockcomment';
            i = i + 3;
        elseif string.sub(wholeFile, i, i + 1) == '--' then
            commentState = 'comment';
            i = i + 1;
        elseif byte == singleQuote then
            stringState = 'singlequote';
        elseif byte == doubleQuote then
            stringState = 'doublequote';
        elseif byte == parenthesisOpen then
            parenthesisCount = parenthesisCount + 1;
        elseif byte == parenthesisClose then
            parenthesisCount = parenthesisCount - 1;
            if (parenthesisCount == 0) then
                if entryState == 'value' then
                    table.insert(keyIndices, { Name = entryName,
                        StartIndex = entryStart, EndIndex = i - 1 });
                end
                return keyIndices, i;
            end
        elseif entryState == 'key' then
            if (not isLetter(byte)) and (not isNumber(byte)) and (byte ~= underscore) then
                entryName = string.sub(wholeFile, entryStart, i - 1);
                if byte == equalSign then
                    entryState = 'value';
                else
                    entryState = 'space';
                end
            end
        elseif entryState == 'bracketkey' then
            if byte == closeBracket then
                entryName = string.sub(wholeFile, entryStart + 1, i - 1);
                local firstByte = string.byte(entryName, 1);
                local lastByte = string.byte(entryName, #entryName);
                if (firstByte == singleQuote) or (firstByte == doubleQuote) then
                    entryName = string.sub(entryName, 2);
                end
                if ((lastByte == singleQuote) or (lastByte == doubleQuote)) then
                    entryName = string.sub(entryName, 1, -2);
                end
                entryState = 'space';
            end
        elseif entryState == 'none' then
            if isLetter(byte) or byte == underscore then
                entryStart = i;
                entryState = 'key';
            elseif byte == openBracket then
                entryStart = i;
                entryState = 'bracketkey';
            end
        elseif entryState == 'space' then
            if (byte == comma) or (byte == semicolon) then
                entryState = 'none';
            elseif byte == equalSign then
                entryState = 'value';
            end
        elseif entryState == 'value' then
            -- A semicolon separates table entries exactly as a comma does, and stray
            -- ones ship inside the stock BasicLuas templates, so both are honored.
            if ((byte == comma) or (byte == semicolon)) and (parenthesisCount == 1) then
                table.insert(keyIndices, { Name = entryName,
                    StartIndex = entryStart, EndIndex = i - 1 });
                entryState = 'none';
            end
        end

        i = i + 1;
    end
    return keyIndices, #wholeFile;
end

--[[
* Statement-declared sets: the miniswap dialect writes sets.Idle = { ... }; as top
* level statements after the table. The scanner works on StripComments output, which
* blanks every comment while keeping the length, so a commented-out set cannot match
* and every index maps straight back onto the real file.
--]]

M.AnchorVarExpr = function(anchor)
    if (anchor == nil) or (anchor.Literal == nil) then
        return nil;
    end
    local expr = string.gsub(anchor.Literal, '^local%s+', '');
    expr = string.gsub(expr, '%s*=%s*T?%s*{$', '');
    if string.match(expr, '^[%a_][%w_%.]*$') then
        return expr;
    end
    return nil;
end

local function IsWordByte(b)
    if (b == nil) then
        return false;
    end
    if (b >= 48) and (b <= 57) then
        return true;
    end
    if (b >= 65) and (b <= 90) then
        return true;
    end
    if (b >= 97) and (b <= 122) then
        return true;
    end
    return (b == 95);
end

--[[
* The index of the brace that closes the one at openIdx, or nil if the file never
* closes it. Quotes are walked past so a brace inside an item name cannot end a set
* early, which is what breaks a naive depth count on real profiles.
--]]
local function MatchBrace(stripped, openIdx)
    local sq = string.byte('\'');
    local dq = string.byte('\"');
    local esc = string.byte('\\');
    local open = string.byte('{');
    local close = string.byte('}');
    local depth = 0;
    local stringState = 'none';
    local i = openIdx;
    local len = #stripped;
    while i <= len do
        local b = stripped:byte(i);
        if (stringState == 'single') then
            if (b == sq) then
                stringState = 'none';
            elseif (b == esc) then
                i = i + 1;
            end
        elseif (stringState == 'double') then
            if (b == dq) then
                stringState = 'none';
            elseif (b == esc) then
                i = i + 1;
            end
        elseif (b == sq) then
            stringState = 'single';
        elseif (b == dq) then
            stringState = 'double';
        elseif (b == open) then
            depth = depth + 1;
        elseif (b == close) then
            depth = depth - 1;
            if (depth == 0) then
                return i;
            end
        end
        i = i + 1;
    end
    return nil;
end

--[[
* Sets written as statements after the table, which is the miniswap dialect:
* sets.Idle = { ... }. The range starts AFTER the sets. head, so the text it points
* at is shaped exactly like an entry inside the literal and everything downstream
* works unchanged. Only the writer knows the difference, through entry.Form.
* 
* Function and block depth is tracked so a set assigned inside a handler body is
* skipped: that one only exists while the game runs, so calling it editable is a lie.
--]]
M.ScanStatementSets = function(text, varExpr, fromIndex)
    local entries = {};
    if (varExpr == nil) then
        return entries;
    end
    local stripped = M.StripComments(text);
    local len = #stripped;
    local sq = string.byte('\'');
    local dq = string.byte('\"');
    local esc = string.byte('\\');
    local space = string.byte(' ');
    local tab = string.byte('\t');
    local function SkipBlank(idx)
        while (idx <= len) and ((stripped:byte(idx) == space) or (stripped:byte(idx) == tab)) do
            idx = idx + 1;
        end
        return idx;
    end

    -- Block openers are tracked so an assignment inside a handler body stays dynamic:
    -- code in a function only runs when the game calls it, so the text is not the truth
    -- about what that set holds. Only depth zero statements are load-time facts.
    local openers = { ['function'] = true, ['if'] = true, ['for'] = true,
        ['while'] = true, ['repeat'] = true };
    local blockDepth = 0;
    local braceDepth = 0;
    local pendingDo = false;
    local stringState = 'none';

    local i = math.max(1, fromIndex or 1);
    while i <= len do
        local b = stripped:byte(i);
        if (stringState == 'single') then
            if (b == sq) then
                stringState = 'none';
            elseif (b == esc) then
                i = i + 1;
            end
            i = i + 1;
        elseif (stringState == 'double') then
            if (b == dq) then
                stringState = 'none';
            elseif (b == esc) then
                i = i + 1;
            end
            i = i + 1;
        elseif (b == sq) then
            stringState = 'single';
            i = i + 1;
        elseif (b == dq) then
            stringState = 'double';
            i = i + 1;
        elseif (b == string.byte('{')) then
            braceDepth = braceDepth + 1;
            i = i + 1;
        elseif (b == string.byte('}')) then
            braceDepth = math.max(0, braceDepth - 1);
            i = i + 1;
        elseif IsWordByte(b) and (not IsWordByte(stripped:byte(i - 1))) then
            local wordEnd = i;
            while (wordEnd <= len) and IsWordByte(stripped:byte(wordEnd)) do
                wordEnd = wordEnd + 1;
            end
            local word = string.sub(stripped, i, wordEnd - 1);
            local matched = nil;

            if (blockDepth == 0) and (braceDepth == 0)
                and (string.sub(stripped, i, i + #varExpr - 1) == varExpr)
                and (not IsWordByte(stripped:byte(i + #varExpr))) then
                local name, keyStart;
                local q = SkipBlank(i + #varExpr);
                if (stripped:byte(q) == string.byte('.')) then
                    local ns = q + 1;
                    local ne = ns;
                    while (ne <= len) and IsWordByte(stripped:byte(ne)) do
                        ne = ne + 1;
                    end
                    if (ne > ns) then
                        name = string.sub(stripped, ns, ne - 1);
                        keyStart = ns;
                        q = ne;
                    end
                elseif (stripped:byte(q) == string.byte('[')) then
                    keyStart = q;
                    local qs = SkipBlank(q + 1);
                    local quote = stripped:byte(qs);
                    if (quote == sq) or (quote == dq) then
                        local qe = qs + 1;
                        while (qe <= len) and (stripped:byte(qe) ~= quote) do
                            if (stripped:byte(qe) == esc) then
                                qe = qe + 1;
                            end
                            qe = qe + 1;
                        end
                        local cb = SkipBlank(qe + 1);
                        if (stripped:byte(cb) == string.byte(']')) then
                            name = string.sub(stripped, qs + 1, qe - 1);
                            q = cb + 1;
                        end
                    end
                end
                if (name ~= nil) then
                    local r = SkipBlank(q);
                    -- A dot or bracket here means a slot mutation like sets.X.Main, which
                    -- is not a set declaration. A == would be a comparison, not a write.
                    if (stripped:byte(r) == string.byte('='))
                        and (stripped:byte(r + 1) ~= string.byte('=')) then
                        local v = SkipBlank(r + 1);
                        if (stripped:byte(v) == string.byte('T')) and (not IsWordByte(stripped:byte(v + 1)) or stripped:byte(v + 1) == string.byte('{')) then
                            local t = SkipBlank(v + 1);
                            if (stripped:byte(t) == string.byte('{')) then
                                v = t;
                            end
                        end
                        if (stripped:byte(v) == string.byte('{')) then
                            local closeIdx = MatchBrace(stripped, v);
                            if (closeIdx ~= nil) then
                                matched = { Name = name, StartIndex = keyStart, EndIndex = closeIdx,
                                    Form = 'statement', StmtStart = i };
                            end
                        end
                    end
                end
            end

            if (matched ~= nil) then
                table.insert(entries, matched);
                i = matched.EndIndex + 1;
            else
                if openers[word] then
                    blockDepth = blockDepth + 1;
                    if (word == 'for') or (word == 'while') then
                        pendingDo = true;
                    end
                elseif (word == 'do') then
                    if pendingDo then
                        pendingDo = false;
                    else
                        blockDepth = blockDepth + 1;
                    end
                elseif (word == 'end') or (word == 'until') then
                    blockDepth = math.max(0, blockDepth - 1);
                end
                i = wordEnd;
            end
        else
            i = i + 1;
        end
    end
    return entries;
end

--[[
* One scan for everything with a text range: the literal's own keys, then any statement
* declarations after it. The writer and the parser both go through here, so they can
* never disagree about what counts as a set.
--]]
M.ScanProfileKeys = function(text)
    local anchor = M.FindAnchor(text);
    if (anchor == nil) then
        return nil, nil, nil;
    end
    local keys, tableEnd = M.ScanSets(text, anchor.BraceIndex + 1);
    local varExpr = M.AnchorVarExpr(anchor);
    if (varExpr ~= nil) then
        local inLiteral = {};
        for _, e in ipairs(keys) do
            inLiteral[e.Name] = true;
        end
        for _, e in ipairs(M.ScanStatementSets(text, varExpr, tableEnd + 1)) do
            -- A statement that reassigns a name the literal already declares is a
            -- runtime overwrite. The literal's text stays authoritative for editing,
            -- so the later statement is skipped rather than fought over.
            if (not inLiteral[e.Name]) then
                table.insert(keys, e);
                inLiteral[e.Name] = true;
            end
        end
    end
    return anchor, keys, tableEnd;
end

--[[
* Whether anything between s and e is a comment rather than code. Read before a set
* is rewritten, because a set that carries one is spliced instead of regenerated.
--]]
M.HasComment = function(text, s, e)
    local singleQuote = string.byte('\'');
    local doubleQuote = string.byte('\"');
    local escapeSlash = string.byte('\\');
    local stringState = 'none';
    local i = s;
    while i <= e do
        local byte = text:byte(i);
        if stringState == 'singlequote' then
            if byte == singleQuote then
                stringState = 'none';
            elseif byte == escapeSlash then
                i = i + 1;
            end
        elseif stringState == 'doublequote' then
            if byte == doubleQuote then
                stringState = 'none';
            elseif byte == escapeSlash then
                i = i + 1;
            end
        elseif byte == singleQuote then
            stringState = 'singlequote';
        elseif byte == doubleQuote then
            stringState = 'doublequote';
        elseif string.sub(text, i, i + 1) == '--' then
            return true;
        end
        i = i + 1;
    end
    return false;
end

--[[
* The text with every comment blanked to spaces, the SAME LENGTH as the original.
* That is the whole point: every index found in the stripped copy points at the same
* byte of the real file, so a scan can ignore comments and still splice accurately.
--]]
M.StripComments = function(text)
    local out = {};
    local singleQuote = string.byte('\'');
    local doubleQuote = string.byte('\"');
    local escapeSlash = string.byte('\\');
    local lineBreak = string.byte('\n');
    local commentState = 'none';
    local stringState = 'none';
    local i = 1;
    local len = #text;
    while i <= len do
        local byte = text:byte(i);
        local emit = string.char(byte);
        if commentState == 'blockcomment' then
            if string.sub(text, i, i + 1) == ']]' then
                commentState = 'none';
                table.insert(out, '  ');
                i = i + 2;
            else
                table.insert(out, byte == lineBreak and '\n' or ' ');
                i = i + 1;
            end
        elseif commentState == 'comment' then
            if byte == lineBreak then
                commentState = 'none';
                table.insert(out, '\n');
            else
                table.insert(out, ' ');
            end
            i = i + 1;
        elseif stringState == 'singlequote' then
            if byte == singleQuote then
                stringState = 'none';
                table.insert(out, emit);
                i = i + 1;
            elseif byte == escapeSlash then
                table.insert(out, string.sub(text, i, i + 1));
                i = i + 2;
            else
                table.insert(out, emit);
                i = i + 1;
            end
        elseif stringState == 'doublequote' then
            if byte == doubleQuote then
                stringState = 'none';
                table.insert(out, emit);
                i = i + 1;
            elseif byte == escapeSlash then
                table.insert(out, string.sub(text, i, i + 1));
                i = i + 2;
            else
                table.insert(out, emit);
                i = i + 1;
            end
        elseif string.sub(text, i, i + 3) == '--[[' then
            commentState = 'blockcomment';
            table.insert(out, '    ');
            i = i + 4;
        elseif string.sub(text, i, i + 1) == '--' then
            commentState = 'comment';
            table.insert(out, '  ');
            i = i + 2;
        elseif byte == singleQuote then
            stringState = 'singlequote';
            table.insert(out, emit);
            i = i + 1;
        elseif byte == doubleQuote then
            stringState = 'doublequote';
            table.insert(out, emit);
            i = i + 1;
        else
            table.insert(out, emit);
            i = i + 1;
        end
    end
    return table.concat(out);
end

--[[
* A private copy of the string library for the sandbox. A profile that assigns to
* string.format would otherwise change it for this addon and everything else in the
* Lua state, since a stranger's file is run to find out what its sets contain.
--]]
local function CopyStringLib()
    local s = {};
    for k, v in pairs(string) do
        s[k] = v;
    end
    if (s.contains == nil) then
        s.contains = function(str, sub)
            return string.find(str, sub, 1, true) ~= nil;
        end
    end
    if (s.trimend == nil) then
        s.trimend = function(str, chars)
            chars = chars or '%s';
            return string.gsub(str, '[' .. chars .. ']*$', '');
        end
    end
    if (s.any == nil) then
        s.any = function(str, ...)
            local lowered = string.lower(str);
            for _, v in ipairs({ ... }) do
                if (string.lower(v) == lowered) then
                    return true;
                end
            end
            return false;
        end
    end
    if (s.fmt == nil) then
        s.fmt = string.format;
    end
    return s;
end

local TMethods = {};
TMethods.append = function(t, v)
    table.insert(t, v);
    return t;
end
TMethods.insert = function(t, ...)
    table.insert(t, ...);
    return t;
end
TMethods.contains = function(t, v)
    for _, x in pairs(t) do
        if (x == v) then
            return true;
        end
    end
    return false;
end
TMethods.hasval = TMethods.contains;
TMethods.hasvalue = TMethods.contains;
TMethods.haskey = function(t, k)
    return t[k] ~= nil;
end
TMethods.each = function(t, fn)
    for k, v in pairs(t) do
        fn(v, k);
    end
    return t;
end
TMethods.ieach = function(t, fn)
    for i, v in ipairs(t) do
        fn(v, i);
    end
    return t;
end
TMethods.sort = function(t, fn)
    table.sort(t, fn);
    return t;
end
TMethods.copy = function(t)
    local c = {};
    for k, v in pairs(t) do
        c[k] = v;
    end
    return c;
end
TMethods.merge = function(t, other)
    for k, v in pairs(other or {}) do
        if (t[k] == nil) then
            t[k] = v;
        end
    end
    return t;
end
TMethods.length = function(t)
    return #t;
end
TMethods.unpack = function(t)
    return unpack(t);
end
TMethods.pack = function(_, ...)
    local packed = { ... };
    packed.n = select('#', ...);
    return packed;
end
TMethods.insert = function(t, a, b)
    if (b == nil) then
        table.insert(t, a);
    else
        table.insert(t, a, b);
    end
    return t;
end
TMethods.append = function(t, v)
    t[#t + 1] = v;
    return t;
end
TMethods.equals = function(t, other)
    if (type(other) ~= 'table') then
        return false;
    end
    for k, v in pairs(t) do
        if (other[k] ~= v) then
            return false;
        end
    end
    for k in pairs(other) do
        if (t[k] == nil) then
            return false;
        end
    end
    return true;
end

local TMeta = { __index = TMethods };

--[[
* Ashita's T{} table with the handful of methods profiles actually call. Without it
* any profile written in the house style throws on its first line and reads as broken.
--]]
local function TStub(t)
    t = t or {};
    if (getmetatable(t) == nil) then
        setmetatable(t, TMeta);
    end
    return t;
end

--[[
* Stands in for a required file that is not on disk. It answers any index and any
* call without throwing, so a profile pulling gear from a framework still loads far
* enough to show its sets, with those slots marked as coming from code.
--]]
local function MakeProxy()
    local p = {};
    setmetatable(p, {
        __index = function()
            return p;
        end,
        -- Two DISTINCT return values: profiles multi-assign from a framework call, as
        -- local profile, sets = gFunc.LoadFile(...)(). A single return leaves the
        -- second variable nil, and the same proxy twice lets profile.Sets = sets make
        -- the table contain itself, which overflows any recursive walk.
        __call = function()
            return MakeProxy(), MakeProxy();
        end,
        -- Profiles concatenate paths at load time, and concatenating a plain table is
        -- a hard error that kills the whole file. The string half survives.
        __concat = function(a, b)
            local left = (type(a) == 'string') and a or '';
            local right = (type(b) == 'string') and b or '';
            return left .. right;
        end,
    });
    return p;
end

--[[
* True when a slot already holds exactly this item and nothing else, so writing it
* again would change nothing. Deliberately false for an entry carrying augments or any
* other descriptor: picking the same name there drops those, which is a real edit.
--]]
M.IsPlainItemNamed = function(slotValue, itemName)
    if (type(slotValue) ~= 'table') or (slotValue.kind ~= 'item') then
        return false;
    end
    if (type(slotValue.item) ~= 'table') or (slotValue.item.name ~= itemName) then
        return false;
    end
    for k in pairs(slotValue.item) do
        if (k ~= 'name') and (k ~= 'sentinel') then
            return false;
        end
    end
    return true;
end

--[[
* Some profiles hand their sets table to a framework before assigning it, as in
* profile.Sets = gcmelee.AppendSets(sets). The sandbox stubs LoadFile, so that returns
* a proxy and the runtime half of a parse comes up empty. The table itself is fine, it
* is just a local on the far side of the chunk boundary: blanking the local keyword
* makes it a global in the sandbox env, readable once the chunk has run. The keyword is
* replaced by the same number of spaces so every byte offset and line number holds, and
* nothing on disk is touched; only the copy handed to loadstring is rewritten.
--]]
M.UnlocalizeAnchor = function(text, anchor)
    if (anchor == nil) or (anchor.Literal == nil) or (anchor.Start == nil) then
        -- No anchor can still mean sets exist: some profiles take both their containers
        -- from one framework call (local profile, sets = ...).
        local s = string.find(text, 'local%s+[%a_][%w_]*%s*,%s*[Ss]ets%s*=');
        if (s ~= nil) and (string.sub(text, s, s + 4) == 'local') then
            local name = string.match(text, 'local%s+[%a_][%w_]*%s*,%s*([Ss]ets)%s*=', s);
            return string.sub(text, 1, s - 1) .. '     ' .. string.sub(text, s + 5), name;
        end
        return text, nil;
    end
    local name = string.match(anchor.Literal, '^local%s+([%a_][%w_]*)%s*=');
    if (name == nil) then
        return text, nil;
    end
    if (string.sub(text, anchor.Start, anchor.Start + 4) ~= 'local') then
        return text, nil;
    end
    return string.sub(text, 1, anchor.Start - 1) .. '     '
        .. string.sub(text, anchor.Start + 5), name;
end

M.RuntimeSets = function(result, env, localName)
    if (type(result) == 'table') then
        if (type(result.Sets) == 'table') and (not M.IsProxy(result.Sets)) then
            return result.Sets;
        end
        if (type(result.sets) == 'table') and (not M.IsProxy(result.sets)) then
            return result.sets;
        end
    end
    -- rawget, because the env answers any unknown global with a proxy.
    if (type(env) == 'table') and (localName ~= nil) then
        local declared = rawget(env, localName);
        if (type(declared) == 'table') and (not M.IsProxy(declared)) then
            return declared;
        end
        -- A proxy that has been written into is a real sets container: written keys sit
        -- in the table itself, so pairs sees them. An empty proxy stays rejected, since
        -- every read on it fabricates another proxy and nothing in it is real.
        if (type(declared) == 'table') and M.IsProxy(declared) and (next(declared) ~= nil) then
            return declared;
        end
    end
    return nil;
end

--[[
* The one way to run a profile and get its sets back. The reader and the save validator
* both go through here, so they can never disagree about what counts as a sets table.
--]]
M.SandboxProfile = function(text, chunkName, anchor)
    if (anchor == nil) then
        anchor = M.FindAnchor(text);
    end
    local prepared, localName = M.UnlocalizeAnchor(text, anchor);
    local result, err, env = M.Sandbox(prepared, chunkName);
    return M.RuntimeSets(result, env, localName), result, err;
end

M.IsProxy = function(v)
    if (type(v) ~= 'table') then
        return false;
    end
    local mt = getmetatable(v);
    return (mt ~= nil) and (type(mt.__call) == 'function') and (type(mt.__index) == 'function');
end

M.MakeSandboxEnv = function()
    -- Ashita builds LuaJIT with Lua 5.2 compatibility, so profiles may call
    -- table.unpack and table.pack, which stock LuaJIT lacks. The sandbox fills both in,
    -- since it exists to answer what a file does in the game.
    local tableCompat = {};
    for k, v in pairs(table) do
        tableCompat[k] = v;
    end
    tableCompat.unpack = tableCompat.unpack or unpack;
    tableCompat.pack = tableCompat.pack or function(...)
        local packed = { ... };
        packed.n = select('#', ...);
        return packed;
    end;
    -- Ashita's common.lua extends the table library, and profiles use the sugar
    -- mid-set: Hands = table.merge(gear.X, { Priority = 14 }).
    tableCompat.merge = tableCompat.merge or function(dst, src)
        local out = {};
        for k, v in pairs(dst or {}) do
            out[k] = v;
        end
        for k, v in pairs(src or {}) do
            out[k] = v;
        end
        return out;
    end;
    tableCompat.copy = tableCompat.copy or function(t)
        local out = {};
        for k, v in pairs(t or {}) do
            out[k] = v;
        end
        return out;
    end;
    local base = {
        string = CopyStringLib(),
        table = tableCompat,
        math = math,
        os = {
            time = os.time,
            date = os.date,
            clock = os.clock,
            getenv = function() return nil; end,
        },
        tostring = tostring,
        tonumber = tonumber,
        type = type,
        pairs = pairs,
        ipairs = ipairs,
        next = next,
        select = select,
        unpack = unpack,
        rawget = rawget,
        rawset = rawset,
        rawequal = rawequal,
        setmetatable = setmetatable,
        getmetatable = getmetatable,
        pcall = pcall,
        xpcall = xpcall,
        error = error,
        assert = assert,
        print = function() end,
        T = TStub,
        require = function() return MakeProxy(); end,
        loadstring = function() return nil, 'blocked'; end,
        load = function() return nil, 'blocked'; end,
        loadfile = function() return nil, 'blocked'; end,
        dofile = function() return nil; end,
        coroutine = {
            create = coroutine.create,
            resume = coroutine.resume,
            yield = coroutine.yield,
            status = coroutine.status,
            wrap = coroutine.wrap,
            sleep = function() end,
            sleepf = function() end,
        },
    };
    -- require raises rather than returning nil when a module is missing, so this cannot
    -- be an or-chain. Profiles that never touch bit still load if it is absent.
    local okbit, bitlib = pcall(require, 'bit');
    if okbit then
        base.bit = bitlib;
    end
    -- An unknown global answers with a proxy rather than nil. Under nil, profiles that
    -- reference framework globals crash before building a single set; under a proxy
    -- they run, plain string slots read normally, and reference-fed slots classify as
    -- code. Writes still land in env first, so a file defining its own globals never
    -- sees a proxy for them.
    local env = setmetatable({}, {
        __index = function(_, k)
            local v = base[k];
            if (v ~= nil) then
                return v;
            end
            return MakeProxy();
        end,
    });
    env.gFunc = MakeProxy();
    env.gData = MakeProxy();
    env.gState = MakeProxy();
    env.gSettings = MakeProxy();
    env.gEquip = MakeProxy();
    env.gIntegration = MakeProxy();
    env.gFileTools = MakeProxy();
    env.gSetDisplay = MakeProxy();
    env.gConfigGUI = MakeProxy();
    env.AshitaCore = MakeProxy();
    env.ashita = MakeProxy();
    env.chat = MakeProxy();
    env.struct = MakeProxy();
    env._G = env;
    return env;
end

M.Sandbox = function(text, chunkName)
    local chunk, err = loadstring(text, '@' .. (chunkName or 'profile'));
    if (chunk == nil) then
        return nil, err;
    end
    local env = M.MakeSandboxEnv();
    setfenv(chunk, env);
    -- A broken profile opens as an error message instead of taking the addon with it.
    local ok, result = pcall(chunk);
    if (not ok) then
        return nil, tostring(result);
    end
    return result, nil, env;
end

M.ParseCharSettings = function(text)
    if (text == nil) then
        return nil;
    end
    local result = M.Sandbox(text, 'lacsettings');
    if (type(result) ~= 'table') then
        return nil;
    end
    local out = {};
    if (type(result.AddSetBackups) == 'boolean') then
        out.AddSetBackups = result.AddSetBackups;
    end
    if (type(result.AddSetEquipScreenOrder) == 'boolean') then
        out.AddSetEquipScreenOrder = result.AddSetEquipScreenOrder;
    end
    if (type(result.DefaultProfile) == 'string') and (#result.DefaultProfile > 0) then
        out.DefaultProfile = result.DefaultProfile;
    end
    if (type(result.EquipBags) == 'table') then
        local bags = {};
        for _, v in pairs(result.EquipBags) do
            if (type(v) == 'number') then
                table.insert(bags, v);
            end
        end
        out.EquipBags = bags;
    end
    return out;
end

M.SliceHasTopLevelKey = function(slice, keyName)
    local stripped = M.StripComments(slice);
    local depth = 0;
    local i = 1;
    local len = #stripped;
    while i <= len do
        local c = stripped:byte(i);
        if (c == BYTE_QUOTE) or (c == BYTE_DQUOTE) then
            local quote = c;
            i = i + 1;
            while (i <= len) do
                local b = stripped:byte(i);
                if (b == 92) then
                    i = i + 2;
                elseif (b == quote) then
                    break;
                else
                    i = i + 1;
                end
            end
        elseif (c == BYTE_LBRACE) then
            depth = depth + 1;
        elseif (c == BYTE_RBRACE) then
            depth = depth - 1;
        elseif (depth == 0) and stripped:match('^[%a_]', i) then
            local word = stripped:match('^[%w_]+', i);
            local prev = (i > 1) and stripped:sub(i - 1, i - 1) or '';
            if (word == keyName) and (not prev:match('[%w_%.]')) then
                if stripped:match('^%s*=', i + #word) then
                    return true;
                end
            end
            i = i + #word - 1;
        end
        i = i + 1;
    end
    return false;
end

--[[
* The raw source text of every slot in a set, keyed by slot name. This is what makes
* a slot filled by code survive a save: the writer emits these bytes back verbatim
* rather than whatever the sandbox happened to evaluate them to.
--]]
M.ExtractSlotSources = function(slice)
    local stripped = M.StripComments(slice);
    local len = #stripped;

    local function SkipString(pos)
        local q = stripped:byte(pos);
        pos = pos + 1;
        while pos <= len do
            local b = stripped:byte(pos);
            if (b == 92) then
                pos = pos + 2;
            elseif (b == q) then
                return pos + 1;
            else
                pos = pos + 1;
            end
        end
        return pos;
    end

    local brace = nil;
    local i = 1;
    while i <= len do
        local b = stripped:byte(i);
        if (b == BYTE_QUOTE) or (b == BYTE_DQUOTE) then
            i = SkipString(i);
        elseif (b == BYTE_LBRACE) then
            brace = i;
            break;
        else
            i = i + 1;
        end
    end
    if (brace == nil) then
        return {};
    end

    local function ScanValue(pos)
        local braces, parens, brackets = 0, 0, 0;
        local lastNonWs = pos - 1;
        while pos <= len do
            local b = stripped:byte(pos);
            local c = string.char(b);
            if (b == BYTE_QUOTE) or (b == BYTE_DQUOTE) then
                pos = SkipString(pos);
                lastNonWs = pos - 1;
            elseif (c == '{') then
                braces = braces + 1;
                lastNonWs = pos;
                pos = pos + 1;
            elseif (c == '}') then
                if (braces == 0) then
                    break;
                end
                braces = braces - 1;
                lastNonWs = pos;
                pos = pos + 1;
            elseif (c == '(') then
                parens = parens + 1;
                lastNonWs = pos;
                pos = pos + 1;
            elseif (c == ')') then
                parens = parens - 1;
                lastNonWs = pos;
                pos = pos + 1;
            elseif (c == '[') then
                brackets = brackets + 1;
                lastNonWs = pos;
                pos = pos + 1;
            elseif (c == ']') then
                brackets = brackets - 1;
                lastNonWs = pos;
                pos = pos + 1;
            elseif ((c == ',') or (c == ';')) and (braces == 0)
                and (parens == 0) and (brackets == 0) then
                break;
            else
                if (not string.match(c, '%s')) then
                    lastNonWs = pos;
                end
                pos = pos + 1;
            end
        end
        return lastNonWs, pos;
    end

    local sources = {};
    local order = 0;
    i = brace + 1;
    local depth = 1;
    local expectKey = true;
    while (i <= len) and (depth > 0) do
        local b = stripped:byte(i);
        local c = string.char(b);
        if string.match(c, '%s') then
            i = i + 1;
        elseif (c == '}') then
            depth = depth - 1;
            i = i + 1;
        elseif (c == '{') then
            depth = depth + 1;
            expectKey = false;
            i = i + 1;
        elseif (depth > 1) then
            if (b == BYTE_QUOTE) or (b == BYTE_DQUOTE) then
                i = SkipString(i);
            else
                i = i + 1;
            end
        elseif (c == ',') or (c == ';') then
            expectKey = true;
            i = i + 1;
        elseif expectKey then
            local key = nil;
            local afterKey = nil;
            local word = string.match(stripped, '^([%a_][%w_]*)', i);
            if (word ~= nil) then
                local wsEnd = string.find(stripped, '%S', i + #word);
                if (wsEnd ~= nil) and (stripped:byte(wsEnd) == BYTE_EQUALS)
                    and (stripped:byte(wsEnd + 1) ~= BYTE_EQUALS) then
                    key = word;
                    afterKey = wsEnd + 1;
                end
            elseif (c == '[') then
                local qPos = string.find(stripped, '%S', i + 1);
                if (qPos ~= nil) and ((stripped:byte(qPos) == BYTE_QUOTE) or (stripped:byte(qPos) == BYTE_DQUOTE)) then
                    local strEnd = SkipString(qPos);
                    local inner = string.sub(stripped, qPos + 1, strEnd - 2);
                    local closePos = string.find(stripped, '%S', strEnd);
                    if (closePos ~= nil) and (stripped:byte(closePos) == BYTE_RBRACK) then
                        local eqPos2 = string.find(stripped, '%S', closePos + 1);
                        if (eqPos2 ~= nil) and (stripped:byte(eqPos2) == BYTE_EQUALS)
                            and (stripped:byte(eqPos2 + 1) ~= BYTE_EQUALS) then
                            key = inner;
                            afterKey = eqPos2 + 1;
                        end
                    end
                end
            end
            if (key ~= nil) then
                local valueStart = string.find(stripped, '%S', afterKey);
                if (valueStart == nil) then
                    break;
                end
                local valueEnd, term = ScanValue(valueStart);
                if (valueEnd >= valueStart) then
                    order = order + 1;
                    -- keyStart and valueEnd are what ExtractComments pins a comment to.
                    -- StripComments is length preserving, so they index the slice too.
                    sources[string.lower(key)] = {
                        key = key,
                        raw = string.sub(slice, valueStart, valueEnd),
                        order = order,
                        keyStart = i,
                        valueEnd = valueEnd,
                    };
                end
                i = term;
                expectKey = false;
            else
                local _, term = ScanValue(i);
                i = term;
                expectKey = false;
            end
        else
            if (b == BYTE_QUOTE) or (b == BYTE_DQUOTE) then
                i = SkipString(i);
            else
                i = i + 1;
            end
        end
    end
    return sources;
end

--[[
* Every comment inside a set, pinned to something that survives a rewrite.
*
* A save rebuilds the set slot by slot in screen order, so a comment cannot be
* kept by remembering which line it sat on: that line may not exist afterwards.
* Each one is therefore anchored to a slot name, or to the set's own opening
* line, and re-emitted with whatever it is anchored to.
*
* Measured over the 343 readable corpus profiles: 8,000 comments in 1,971 sets,
* of which about 96% anchor to a slot or the set header. The rest have nothing
* near them and are returned with no anchor, for the writer to park at the end.
*
* Returns a list in file order: { text, anchor, place }. anchor is a lowercase
* slot name, or SET_ANCHOR, or nil. place is 'trailing' or 'own'.
--]]
M.SET_ANCHOR = '@set';

M.ExtractComments = function(slice)
    local bare = M.StripComments(slice);
    local sources = M.ExtractSlotSources(slice);

    local spans = {};
    for lower, src in pairs(sources) do
        if (src.keyStart ~= nil) and (src.valueEnd ~= nil) then
            spans[#spans + 1] = { lower = lower, keyStart = src.keyStart, valueEnd = src.valueEnd };
        end
    end
    table.sort(spans, function(a, b) return a.keyStart < b.keyStart; end);

    local out = {};
    local seenTrailing = {};

    -- Lines are walked by character position. Splitting on a newline pattern
    -- desynced the stripped copy from the original on every CRLF file, which
    -- reported plain code as comments.
    local starts = { 1 };
    for at in slice:gmatch('()\n') do
        starts[#starts + 1] = at + 1;
    end

    for li = 1, #starts do
        local lineStart = starts[li];
        local lineEnd = (starts[li + 1] or (#slice + 2)) - 2;
        local s = nil;
        for at = lineStart, lineEnd do
            if (slice:sub(at, at) ~= bare:sub(at, at)) then
                s = at;
                break;
            end
        end
        if (s ~= nil) then
            local body = slice:sub(s, lineEnd):gsub('%s+$', '');
            local before = slice:sub(lineStart, s - 1);
            if (body ~= '') then
                if (before:match('^%s*$') == nil) then
                    -- Something is in front of it, so it belongs to whatever ended last.
                    local owner = nil;
                    for _, sp in ipairs(spans) do
                        if (sp.valueEnd < s) and (sp.valueEnd >= lineStart) then
                            owner = sp.lower;
                        end
                    end
                    if (owner ~= nil) and (not seenTrailing[owner]) then
                        seenTrailing[owner] = true;
                        out[#out + 1] = { text = body, anchor = owner, place = 'trailing' };
                    elseif (owner ~= nil) then
                        -- A slot whose value spans lines can carry several. Only one
                        -- can trail the rebuilt single line, so the rest go above it.
                        out[#out + 1] = { text = body, anchor = owner, place = 'own' };
                    else
                        out[#out + 1] = { text = body, anchor = M.SET_ANCHOR, place = 'trailing' };
                    end
                else
                    -- On its own line. A commented out slot goes back beside the slot
                    -- it names, which is the kept alternative pattern and a quarter of
                    -- every comment in the corpus. Otherwise it belongs to whatever
                    -- comes next.
                    local named = body:match("^%-%-+%s*%[?%s*['\"]?([%a_][%w_]*)['\"]?%s*%]?%s*=");
                    local anchor = nil;
                    if (named ~= nil) and (M.SlotIndex[string.lower(named)] ~= nil) then
                        anchor = string.lower(named);
                    else
                        for _, sp in ipairs(spans) do
                            if (sp.keyStart > lineEnd) then
                                anchor = sp.lower;
                                break;
                            end
                        end
                    end
                    out[#out + 1] = { text = body, anchor = anchor, place = 'own' };
                end
            end
        end
    end
    return out;
end

M.LogicalName = function(name)
    if (#name > 9) and (string.sub(name, -9) == '_Priority') then
        return string.sub(name, 1, -10), true;
    end
    return name, false;
end

local function ClassifyItemEntry(v, flags)
    if (type(v) == 'string') then
        local entry = { name = v };
        if M.Sentinels[string.lower(v)] then
            entry.sentinel = string.lower(v);
        end
        return entry;
    end
    if (type(v) == 'table') then
        local entry = {};
        for k, val in pairs(v) do
            if (k == 'Name') and (type(val) == 'string') then
                entry.name = val;
            elseif (k == 'Augment') and (type(val) == 'string' or type(val) == 'table') then
                entry.augment = val;
            elseif (k == 'AugPath') then
                entry.augPath = val;
            elseif (k == 'AugRank') then
                entry.augRank = val;
            elseif (k == 'AugTrial') then
                entry.augTrial = val;
            elseif (k == 'Bag') then
                entry.bag = val;
            elseif (k == 'Priority') and (type(val) == 'number') then
                entry.priority = val;
            elseif (k == 'Level') and (type(val) == 'number') then
                entry.level = val;
            elseif (k == 'Quantity') and (type(val) == 'number') then
                entry.quantity = val;
            else
                flags.unknown = flags.unknown or {};
                table.insert(flags.unknown, tostring(k));
            end
        end
        if (entry.name ~= nil) and M.Sentinels[string.lower(entry.name)] then
            entry.sentinel = string.lower(entry.name);
        end
        return entry;
    end
    flags.unknown = flags.unknown or {};
    table.insert(flags.unknown, type(v));
    return nil;
end

M.ClassifySlot = function(v)
    local flags = {};
    if (type(v) == 'string') then
        local entry = ClassifyItemEntry(v, flags);
        return { kind = 'item', item = entry }, flags;
    end
    if (type(v) == 'table') and (not M.IsProxy(v)) then
        if (next(v) == nil) then
            return { kind = 'chain', entries = {} }, flags;
        end
        if (rawget(v, 1) ~= nil) then
            local entries = {};
            for _, e in ipairs(v) do
                if M.IsProxy(e) then
                    return { kind = 'opaque' }, flags;
                end
                local entry = ClassifyItemEntry(e, flags);
                if (entry == nil) or ((entry.name == nil) and (entry.sentinel == nil)) then
                    return { kind = 'opaque' }, flags;
                end
                table.insert(entries, entry);
            end
            return { kind = 'chain', entries = entries }, flags;
        end
        local entry = ClassifyItemEntry(v, flags);
        if (entry ~= nil) and (entry.name ~= nil) then
            return { kind = 'item', item = entry }, flags;
        end
    end
    return { kind = 'opaque' }, flags;
end

--[[
* One set turned into the shape the interface draws: sixteen slots, each classified
* as an item, a list, code, or empty, plus the extra keys and comments that have to
* come back out unchanged on save.
--]]
local function BuildSetModel(name, value, scanEntry, text, depth, path)
    local setModel = {
        name = name,
        kind = 'set',
        nestedPath = path,
        slots = {},
        unknownKeys = {},
        extraKeys = {},
        children = nil,
        baseSet = nil,
        noWrite = nil,
        dirty = false,
        deleted = false,
        isNew = false,
        hasOpaque = false,
        opaqueLost = false,
    };
    setModel.logicalName, setModel.isPriority = M.LogicalName(name);
    if (scanEntry ~= nil) then
        setModel.range = { s = scanEntry.StartIndex, e = scanEntry.EndIndex };
        setModel.keyForm = (text:byte(scanEntry.StartIndex) == string.byte('['))
            and 'bracket' or 'bare';
        setModel.hasComments = M.HasComment(text, scanEntry.StartIndex, scanEntry.EndIndex);
        local slice = string.sub(text, scanEntry.StartIndex, scanEntry.EndIndex);
        setModel.sourceSlice = slice;
        setModel.hasTabs = string.find(slice, '\t', 1, true) ~= nil;
        if setModel.hasComments then
            setModel.comments = M.ExtractComments(slice);
        end
    end

    if (type(value) ~= 'table') then
        setModel.kind = 'oddity';
        return setModel;
    end
    if M.IsProxy(value) then
        setModel.kind = 'oddity';
        return setModel;
    end

    local slotSources = nil;
    if (setModel.sourceSlice ~= nil) then
        slotSources = M.ExtractSlotSources(setModel.sourceSlice);
    end

    local slotCount = 0;
    local tableChildren = {};
    for k, v in pairs(value) do
        if (type(k) == 'string') then
            local slotIdx = M.SlotIndex[string.lower(k)];
            local src = (slotSources ~= nil) and slotSources[string.lower(k)] or nil;
            if (slotIdx ~= nil) then
                local sv, flags = M.ClassifySlot(v);
                if (sv.kind == 'opaque') then
                    setModel.hasOpaque = true;
                    if (src ~= nil) then
                        sv.raw = src.raw;
                    else
                        setModel.opaqueLost = true;
                    end
                else
                    if (src ~= nil) then
                        local firstByte = string.byte(src.raw);
                        if (firstByte ~= 39) and (firstByte ~= 34) and (firstByte ~= 123) then
                            sv.raw = src.raw;
                            sv.locked = true;
                            setModel.hasOpaque = true;
                        end
                    end
                    if (flags.unknown ~= nil) then
                        for _, u in ipairs(flags.unknown) do
                            table.insert(setModel.unknownKeys, k .. '.' .. u);
                        end
                    end
                end
                setModel.slots[M.SlotNames[slotIdx]] = sv;
                slotCount = slotCount + 1;
            elseif (k == 'BaseSet') and (type(v) == 'string') then
                setModel.baseSet = v;
            elseif (k == 'NoWrite') then
                setModel.noWrite = (v == true);
            elseif (src ~= nil) then
                table.insert(setModel.extraKeys,
                    { key = src.key, raw = src.raw, order = src.order });
                if (type(v) == 'table') and (not M.IsProxy(v)) then
                    table.insert(tableChildren, { key = k, value = v, preserved = true });
                end
            elseif (type(v) == 'table') and (not M.IsProxy(v)) then
                table.insert(tableChildren, { key = k, value = v });
            else
                table.insert(setModel.unknownKeys, tostring(k));
            end
        elseif (type(k) == 'number') then
            table.insert(setModel.unknownKeys, 'array entry ' .. tostring(k));
        end
    end
    --[[
    * A slot can be written in the file and still be absent from the table this loop
    * walks, because the loop walks the RESULT of running the file: an expression that
    * evaluates to nil never creates a runtime key, and a save would then rewrite the
    * set without that line. Anything the text declares is carried through as code, so
    * the writer puts it back verbatim.
    --]]
    if (slotSources ~= nil) then
        for lowerKey, src in pairs(slotSources) do
            local slotIdx = M.SlotIndex[lowerKey];
            if (slotIdx ~= nil) and (setModel.slots[M.SlotNames[slotIdx]] == nil) then
                setModel.slots[M.SlotNames[slotIdx]] = { kind = 'opaque', raw = src.raw };
                setModel.hasOpaque = true;
                slotCount = slotCount + 1;
            end
        end
    end

    table.sort(setModel.extraKeys, function(a, b) return a.order < b.order; end);

    if (slotCount == 0) and (#tableChildren > 0) and (setModel.baseSet == nil) then
        setModel.kind = 'group';
        setModel.children = {};
        for _, child in ipairs(tableChildren) do
            local childPath = (path ~= nil) and (path .. '.' .. child.key)
                or (name .. '.' .. child.key);
            local childModel = BuildSetModel(child.key, child.value, nil,
                text, depth + 1, childPath);
            table.insert(setModel.children, childModel);
        end
        table.sort(setModel.children, function(a, b) return a.name < b.name; end);
    else
        for _, child in ipairs(tableChildren) do
            if (not child.preserved) then
                table.insert(setModel.unknownKeys, child.key);
            end
        end
    end

    return setModel;
end

--[[
* The whole profile: find the sets table, run the file in a sandbox to see what its
* sets contain, then match those values back to byte ranges in the text so they can
* be edited. Both halves are needed. The sandbox knows the values, only the scan
* knows where they live.
--]]
M.Parse = function(text, path)
    local model = {
        path = path,
        filename = path and string.match(path, '[^\\/]+$') or 'unknown',
        textAtLoad = text,
        kind = 'unsupported',
        sets = {},
        setsByLower = {},
        notices = {},
        anchor = nil,
        scanKeys = nil,
        tableEnd = nil,
        handlersPresent = {},
        profileTable = nil,
    };
    model.stem = string.gsub(model.filename, '%.lua$', '');
    model.eol = (string.find(text, '\r\n', 1, true) ~= nil) and '\r\n' or '\n';

    if string.match(string.lower(model.filename), '%.xml$') then
        model.kind = 'xml';
        table.insert(model.notices, 'Ashitacast v3 XML files are not supported. LuAshitacast profiles only.');
        return model;
    end

    local anchor, scanKeys, tableEnd = M.ScanProfileKeys(text);
    if (anchor ~= nil) then
        model.anchor = anchor;
        model.scanKeys = scanKeys;
        model.tableEnd = tableEnd;
    end

    local runtime, result, err = M.SandboxProfile(text, model.filename, anchor);
    local setsTable = nil;
    if (runtime ~= nil) then
        setsTable = runtime;
        model.profileTable = result;
        for _, h in ipairs({
            'OnLoad', 'OnUnload', 'HandleCommand', 'HandleDefault', 'HandleAbility',
            'HandleItem', 'HandlePrecast', 'HandleMidcast', 'HandlePreshot',
            'HandleMidshot', 'HandleWeaponskill',
        }) do
            if (type(result[h]) == 'function') then
                model.handlersPresent[h] = true;
            end
        end
    end

    if (anchor ~= nil) and (setsTable ~= nil) then
        if string.find(text, 'blinclude', 1, true) or string.find(text, 'BasicLuas', 1, true) then
            model.kind = 'basiclua';
        else
            model.kind = 'native';
        end
    elseif (anchor ~= nil) and (setsTable == nil) then
        model.kind = 'textonly';
        table.insert(model.notices, 'This file could not be run safely. Showing set names read only.');
        if (err ~= nil) then
            table.insert(model.notices, 'Load error: ' .. tostring(err));
        end
    elseif (anchor == nil) and (setsTable ~= nil) then
        model.kind = 'readonly';
        table.insert(model.notices, 'No standard sets table found. Sets are read only.');
    else
        model.kind = 'unsupported';
        table.insert(model.notices, 'This does not look like a LuAshitacast profile.');
        if (err ~= nil) then
            table.insert(model.notices, 'Load error: ' .. tostring(err));
        end
        return model;
    end

    local seen = {};
    if (scanKeys ~= nil) then
        for _, entry in ipairs(scanKeys) do
            local value = (setsTable ~= nil) and setsTable[entry.Name] or nil;
            local setModel;
            if (value ~= nil) then
                setModel = BuildSetModel(entry.Name, value, entry, text, 0, nil);
            else
                setModel = BuildSetModel(entry.Name, nil, entry, text, 0, nil);
                if (setsTable ~= nil) then
                    setModel.kind = 'oddity';
                end
                if (model.kind == 'textonly') then
                    setModel.kind = 'textonly';
                end
            end
            table.insert(model.sets, setModel);
            seen[entry.Name] = true;
        end
    end

    if (setsTable ~= nil) then
        local dynamicNames = {};
        for k, v in pairs(setsTable) do
            if (type(k) == 'string') and (not seen[k]) then
                table.insert(dynamicNames, k);
            end
        end
        table.sort(dynamicNames);
        for _, k in ipairs(dynamicNames) do
            local setModel = BuildSetModel(k, setsTable[k], nil, text, 0, nil);
            setModel.kind = (setModel.kind == 'group') and 'group' or 'dynamic';
            setModel.range = nil;
            table.insert(model.sets, setModel);
        end
    end

    for i, s in ipairs(model.sets) do
        if (model.setsByLower[string.lower(s.name)] == nil) then
            model.setsByLower[string.lower(s.name)] = i;
        end
    end

    for _, s in ipairs(model.sets) do
        if s.isPriority then
            local twinIdx = model.setsByLower[string.lower(s.logicalName)];
            if (twinIdx ~= nil) then
                s.pairedWith = model.sets[twinIdx].name;
                model.sets[twinIdx].pairedWith = s.name;
            end
        end
    end

    for _, d in ipairs(model.sets) do
        if (d.kind == 'dynamic') then
            for _, s in ipairs(model.sets) do
                if (s.range ~= nil) then
                    local slice = string.sub(text, s.range.s, s.range.e);
                    if M.SliceHasTopLevelKey(slice, d.name) then
                        s.fusedWith = s.fusedWith or {};
                        table.insert(s.fusedWith, d.name);
                        d.fusedInto = s.name;
                        table.insert(model.notices, 'Sets ' .. s.name .. ' and ' .. d.name
                            .. ' share one file block, likely from a stray semicolon. Both stay locked until fixed by hand.');
                    end
                end
            end
        end
    end

    return model;
end

M.FindSet = function(model, name)
    local idx = model.setsByLower[string.lower(name)];
    if (idx == nil) then
        return nil;
    end
    return model.sets[idx], idx;
end

M.IsEditable = function(model, setModel)
    if (model.kind ~= 'native') and (model.kind ~= 'basiclua') then
        return false;
    end
    if (model.anchor == nil) then
        return false;
    end
    if (setModel == nil) then
        return true;
    end
    if (setModel.isNew == true) then
        return true;
    end
    if (setModel.fusedWith ~= nil) or (setModel.fusedInto ~= nil) then
        return false;
    end
    if (setModel.opaqueLost == true) then
        return false;
    end
    return (setModel.kind == 'set') and (setModel.range ~= nil);
end

return M;
