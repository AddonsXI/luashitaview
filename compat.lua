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

local bit = require('bit');
-- The ImGui globals only exist after libs\imgui.lua has run in this state, so it
-- has to be pulled in before the staleness test reads them.
require('imgui');

local M = {};

--[[
* A pre-2025 addons\libs\imgui.lua on a current Ashita misnumbers the style enums.
* DisabledAlpha is the tell: every current libs file has it, no stale one does.
* When stale, styling is skipped (see theme.Push) and the names below, absent from
* the old file, are filled with the current engine's values.
--]]
M.StaleLibs = (ImGuiStyleVar_DisabledAlpha == nil) and (AshitaCore ~= nil);

if (M.StaleLibs) then
    ImGuiChildFlags_Borders = ImGuiChildFlags_Borders or bit.lshift(1, 0);
    ImGuiChildFlags_AlwaysUseWindowPadding = ImGuiChildFlags_AlwaysUseWindowPadding or bit.lshift(1, 1);
    ImGuiChildFlags_AutoResizeY = ImGuiChildFlags_AutoResizeY or bit.lshift(1, 5);
    ImGuiCol_TabSelected = ImGuiCol_TabSelected or 36;
    ImGuiStyleVar_TabBarBorderSize = ImGuiStyleVar_TabBarBorderSize or 28;
end

return M;
