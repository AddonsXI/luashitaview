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

-- Every enum is nil guarded: the headless suite loads this without an imgui to read them from.

local imgui = require('imgui');
local compat = require('compat');

local M = {};

-- Whatever opens one of these gaps must submit an item after it, or ImGui asserts in a red box.
-- Lives here because uistate requires picker, so picker cannot require uistate.
M.ROW_GAP = 2;

-- What a SmallButton adds to its label, measured against the real control.
M.SMALL_BUTTON_PAD = 14;

M.col = {
    bg          = { 0.07, 0.07, 0.09, 0.96 },
    panel       = { 0.10, 0.10, 0.13, 1.00 },
    panelSoft   = { 0.13, 0.13, 0.16, 1.00 },
    popupEdge   = { 0.42, 0.42, 0.50, 1.00 },
    border      = { 0.22, 0.22, 0.27, 1.00 },
    text        = { 0.88, 0.88, 0.90, 1.00 },
    textDim     = { 0.58, 0.58, 0.64, 1.00 },
    textFaint   = { 0.40, 0.40, 0.46, 1.00 },
    -- Green is the accent for everything highlighted; red only for things actually wrong.
    accent      = { 0.42, 0.80, 0.48, 1.00 },
    accentDim   = { 0.28, 0.56, 0.33, 1.00 },
    accentBg    = { 0.14, 0.31, 0.18, 1.00 },
    -- Behind selected text in a box you type in, so it has to stay translucent.
    accentSel   = { 0.42, 0.80, 0.48, 0.35 },
    code        = { 0.50, 0.80, 1.00, 1.00 },
    codeBg      = { 0.13, 0.20, 0.28, 1.00 },
    caution     = { 1.00, 0.72, 0.32, 1.00 },
    cautionBg   = { 0.28, 0.20, 0.10, 1.00 },
    danger      = { 1.00, 0.45, 0.42, 1.00 },
    dangerBg    = { 0.30, 0.12, 0.11, 1.00 },
    keyword     = { 0.85, 0.85, 0.45, 1.00 },
    neutralBg   = { 0.18, 0.18, 0.22, 1.00 },
    neutralHi   = { 0.24, 0.24, 0.29, 1.00 },
    neutralOn   = { 0.30, 0.30, 0.36, 1.00 },
    cellBg      = { 0.13, 0.13, 0.17, 1.00 },
    cellHover   = { 0.22, 0.19, 0.19, 1.00 },
    cellBorder  = { 0.30, 0.30, 0.36, 1.00 },
    ghost       = { 1.00, 1.00, 1.00, 0.35 },
};

local StyleColors = {
    { 'ImGuiCol_WindowBg', 'bg' },
    { 'ImGuiCol_ChildBg', 'panel' },
    { 'ImGuiCol_PopupBg', 'panel' },
    { 'ImGuiCol_Border', 'border' },
    { 'ImGuiCol_Text', 'text' },
    { 'ImGuiCol_TextDisabled', 'textDim' },
    { 'ImGuiCol_FrameBg', 'panelSoft' },
    { 'ImGuiCol_FrameBgHovered', 'neutralBg' },
    { 'ImGuiCol_FrameBgActive', 'neutralBg' },
    { 'ImGuiCol_TitleBg', 'panel' },
    { 'ImGuiCol_TitleBgActive', 'panel' },
    { 'ImGuiCol_TitleBgCollapsed', 'panel' },
    { 'ImGuiCol_Button', 'neutralBg' },
    { 'ImGuiCol_ButtonHovered', 'neutralHi' },
    { 'ImGuiCol_ButtonActive', 'neutralOn' },
    { 'ImGuiCol_Header', 'neutralBg' },
    { 'ImGuiCol_HeaderHovered', 'neutralHi' },
    { 'ImGuiCol_HeaderActive', 'neutralOn' },
    { 'ImGuiCol_Tab', 'panel' },
    { 'ImGuiCol_TabHovered', 'neutralHi' },
    -- TabActive resolves to nil here, and Push is nil guarded, so the old spelling silently did
    -- nothing.
    { 'ImGuiCol_TabSelected', 'neutralOn' },
    { 'ImGuiCol_CheckMark', 'accent' },
    -- Left unset it keeps ImGui's own red.
    { 'ImGuiCol_ResizeGrip', 'accentDim' },
    { 'ImGuiCol_ResizeGripHovered', 'accent' },
    { 'ImGuiCol_ResizeGripActive', 'accent' },
    { 'ImGuiCol_Separator', 'border' },
    { 'ImGuiCol_ScrollbarBg', 'panel' },
    { 'ImGuiCol_ScrollbarGrab', 'neutralBg' },
    { 'ImGuiCol_ScrollbarGrabHovered', 'neutralHi' },
    { 'ImGuiCol_ScrollbarGrabActive', 'neutralOn' },
    { 'ImGuiCol_SliderGrab', 'accent' },
    -- Same as the resize grip: unset, it keeps ImGui's red.
    { 'ImGuiCol_TextSelectedBg', 'accentSel' },
};

local StyleVars = {
    { 'ImGuiStyleVar_FrameRounding', 3.0 },
    { 'ImGuiStyleVar_ChildRounding', 4.0 },
    { 'ImGuiStyleVar_PopupRounding', 4.0 },
    { 'ImGuiStyleVar_PopupBorderSize', 1.0 },
    { 'ImGuiStyleVar_GrabRounding', 3.0 },
    { 'ImGuiStyleVar_WindowRounding', 5.0 },
    -- Zero removes the rule under the tab row without touching ImGuiCol_TabSelected.
    { 'ImGuiStyleVar_TabBarBorderSize', 0.0 },
};

M.Push = function()
    -- On a stale libs file the style enums are misnumbered, so pushing any of them styles the
    -- wrong setting.
    if (compat.StaleLibs) then
        return { colors = 0, vars = 0 };
    end
    local colors = 0;
    for _, entry in ipairs(StyleColors) do
        local enum = _G[entry[1]];
        if (enum ~= nil) then
            imgui.PushStyleColor(enum, M.col[entry[2]]);
            colors = colors + 1;
        end
    end
    local vars = 0;
    for _, entry in ipairs(StyleVars) do
        local enum = _G[entry[1]];
        if (enum ~= nil) then
            imgui.PushStyleVar(enum, entry[2]);
            vars = vars + 1;
        end
    end
    return { colors = colors, vars = vars };
end

M.Pop = function(pushed)
    if (pushed == nil) then
        return;
    end
    if (pushed.vars > 0) then
        imgui.PopStyleVar(pushed.vars);
    end
    if (pushed.colors > 0) then
        imgui.PopStyleColor(pushed.colors);
    end
end

M.Badge = function(label, fg, bg, tooltip)
    imgui.PushStyleColor(ImGuiCol_Button, M.col[bg] or M.col.neutralBg);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, M.col[bg] or M.col.neutralBg);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, M.col[bg] or M.col.neutralBg);
    imgui.PushStyleColor(ImGuiCol_Text, M.col[fg] or M.col.text);
    imgui.SmallButton(label);
    imgui.PopStyleColor(4);
    if (tooltip ~= nil) and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip);
    end
end

-- ImGui's TextDisabled has no wrapping form.
M.WrapText = function(text, colorKey)
    local c = M.col[colorKey or 'textDim'];
    imgui.PushStyleColor(ImGuiCol_Text, c);
    imgui.TextWrapped(text);
    imgui.PopStyleColor();
end

M.Hint = function(text)
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(text);
    end
end

return M;
