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
* Entry point. Owns the addon lifecycle and hands everything else to ui.
--]]

addon.name      = 'luashitaview';
addon.author    = 'AddonsXI';
addon.version   = '1.2.0';
addon.link      = 'https://github.com/AddonsXI';
addon.desc      = 'View and edit LuAshitacast equipment sets in game, without touching a Lua file.';

require('common');
local chat = require('chat');
local items = require('items');
local ui = require('ui');
local uistate = require('uistate');

--[[
* Held in memory for the life of the addon and never written to disk. Everything
* here is a working preference rather than a setting: it survives closing and
* reopening the window, and a reload puts it all back the way it starts.
--]]
local config = T{
    auto_reload_after_save = T{ false },
    last_profile = T{ '' },
    debug = T{ false },
    window_reset = T{ false },

    picker_sort = T{ 2 },
    picker_favorites = T{},

    -- Container ids Your bags should skip. Empty means search them all.
    picker_bags = T{},

    -- 1 the level box is a ceiling, 2 a floor.
    picker_levelmode = T{ 1 },

    -- Whether the Recent Picks list is expanded.
    picker_recent_open = T{ true },

    -- Divider positions, as fractions of the row rather than pixels.
    -- From uistate, so there is one source of truth for the column layout.
    split_a = T{ (uistate.DefaultSplits()) },
    split_b = T{ (select(2, uistate.DefaultSplits())) },
};

ashita.events.register('load', 'load_cb', function ()
end);

ashita.events.register('unload', 'unload_cb', function ()
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end
    local cmd = string.lower(args[1]);
    if (cmd ~= '/sets') and (cmd ~= '/luashitaview') and (cmd ~= '/lua') and (cmd ~= '/gear') then
        return;
    end
    e.blocked = true;

    if (not ui.HandleCommand(args)) then
        print(chat.header(addon.name):append(chat.message('/sets toggles the window. /sets debug logs it.')));
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    items.PumpIcons(8);
    items.PumpDbSweep();
    if items.GetInterfaceHidden() then
        return;
    end
    if (AshitaCore:GetFontManager():GetVisible() == false)
        or (AshitaCore:GetGuiManager():GetVisible() == false)
        or (AshitaCore:GetPrimitiveManager():GetVisible() == false) then
        return;
    end
    ui.Draw(config);
end);
