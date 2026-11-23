-- SMH Tools Hub (client)
-- Install: addons/<your_addon>/lua/autorun/client/smh_tools_hub.lua
--
-- * A small button strip sits above the SMH timeline: one button per tool
--   (Face Tracking, Face Recorder, Kinect Recorder ...), plus
--   "Hide timeline" / "Close SMH".
-- * Tool windows are no longer opened automatically; open them from the strip.
-- * Anything that is running (tracking, recording, countdown) is listed in the
--   top-left of the screen at all times, even with SMH closed.
-- * The SMH menu key becomes a toggle: press once to open, press again to close
--   (no need to hold it).  Console: smh_hub_sticky 0 gives the old hold behaviour.
if SERVER then AddCSLuaFile() return end

SMHToolsHub = SMHToolsHub or {}
local Hub = SMHToolsHub
Hub.tools = Hub.tools or {}
Hub.order = Hub.order or {}

local STRIP_H = 28
local BAR_H = 90 -- height of the SMH timeline bar
local stickyCvar = CreateClientConVar("smh_hub_sticky", "1", true, false, "SMH menu key toggles instead of hold")

-- tool = { id, name, open=fn, close=fn, isOpen=fn, isActive=fn, status=fn }
function Hub.Register(tool)
    if not tool or not tool.id then return end
    if not Hub.tools[tool.id] then Hub.order[#Hub.order + 1] = tool.id end
    Hub.tools[tool.id] = tool
    Hub.dirty = true
end

-- Height used by the strip + bar, so tool windows can place themselves above it.
function Hub.ReservedHeight()
    return BAR_H + STRIP_H + 10
end

local function smhOpen()
    return SMH ~= nil and SMH.UI ~= nil and isfunction(SMH.UI.IsOpen) and SMH.UI.IsOpen() == true
end

local clicker
local function findClicker()
    if IsValid(clicker) then return clicker end
    local world = vgui.GetWorldPanel()
    if not IsValid(world) then return nil end
    for _, p in ipairs(world:GetChildren()) do
        if IsValid(p) and p:GetName() == "SMHWorldClicker" and IsValid(p.MainMenu) then
            clicker = p
            return p
        end
    end
    return nil
end

local timelineHidden = false
local function setTimelineHidden(hide)
    local c = findClicker()
    if not c then
        -- cannot find the bar: fall back to closing SMH completely
        if hide and smhOpen() then SMH.UI.Close() end
        timelineHidden = false
        return
    end
    timelineHidden = hide and true or false
    c.MainMenu:SetVisible(not timelineHidden)
end

local strip
local function safe(fn, ...)
    if not isfunction(fn) then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function styleButton(b, activeFn)
    b:SetTextColor(color_white)
    b.Paint = function(self, w, h)
        local on = activeFn and activeFn()
        local col = on and Color(40, 130, 60, 235) or (self:IsHovered() and Color(70, 70, 80, 235) or Color(45, 45, 55, 225))
        draw.RoundedBox(4, 0, 0, w, h, col)
    end
end

local function buildStrip()
    if IsValid(strip) then strip:Remove() end
    strip = vgui.Create("DPanel")
    strip:SetTall(STRIP_H)
    strip.Paint = function() end
    strip:SetVisible(false)
    local x = 0
    local function add(text, w, doClick, activeFn, textFn)
        local b = vgui.Create("DButton", strip)
        b:SetText(text)
        b:SetPos(x, 0)
        b:SetSize(w, STRIP_H)
        b.DoClick = doClick
        styleButton(b, activeFn)
        if textFn then
            local old = b.Think
            b.Think = function(self) self:SetText(textFn()) end
        end
        x = x + w + 4
        return b
    end
    for _, id in ipairs(Hub.order) do
        local t = Hub.tools[id]
        add(t.name, 150, function()
            if safe(t.isOpen) then safe(t.close) else safe(t.open) end
        end, function() return safe(t.isActive) or safe(t.isOpen) end,
        function()
            return (safe(t.isActive) and "● " or "") .. t.name
        end)
    end
    add("Hide timeline", 110, function() setTimelineHidden(not timelineHidden) end, nil,
        function() return timelineHidden and "Show timeline" or "Hide timeline" end)
    add("Close SMH", 90, function() if smhOpen() then SMH.UI.Close() end end)
    strip:SetWide(x - 4)
    strip:MakePopup()
    strip:SetKeyboardInputEnabled(false)
    strip:SetVisible(false)
    Hub.dirty = false
end

hook.Add("Think", "SMHToolsHubStrip", function()
    if Hub.dirty or (#Hub.order > 0 and not IsValid(strip)) then buildStrip() end
    if not IsValid(strip) then return end
    local open = smhOpen()
    if open ~= strip:IsVisible() then
        strip:SetVisible(open)
        if not open then
            -- always bring the timeline back for next time
            if timelineHidden then setTimelineHidden(false) end
        end
    end
    if open then
        local barH = timelineHidden and 0 or BAR_H
        strip:SetPos((ScrW() - strip:GetWide()) / 2, ScrH() - barH - STRIP_H - 2)
        strip:MoveToFront()
    end
end)

-- Persistent "something is running" list.
surface.CreateFont("SMHHubStatus", { font = "Arial", size = 18, weight = 700 })
hook.Add("HUDPaint", "SMHToolsHubStatus", function()
    local y = 110
    for _, id in ipairs(Hub.order) do
        local t = Hub.tools[id]
        if t and safe(t.isActive) then
            local text = "● " .. t.name
            local st = safe(t.status)
            if st and st ~= "" then text = text .. ": " .. tostring(st) end
            draw.SimpleTextOutlined(text, "SMHHubStatus", 20, y, Color(255, 90, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
            y = y + 22
        end
    end
end)

-- Sticky menu key: press once to open, press again to close.
local function installSticky()
    if not stickyCvar:GetBool() then return end
    if not (SMH and SMH.UI and SMH.UI.Open) then return end
    concommand.Add("+smh_menu", function()
        if not stickyCvar:GetBool() then SMH.UI.Open() return end
        if SMH.UI.IsOpen() then SMH.UI.Close() else SMH.UI.Open() end
    end)
    concommand.Add("-smh_menu", function()
        if not stickyCvar:GetBool() then SMH.UI.Close() end
    end)
end
hook.Add("InitPostEntity", "SMHToolsHubSticky", function()
    timer.Simple(1, installSticky)
    timer.Simple(5, installSticky) -- in case SMH loaded late
end)
if SMH and SMH.UI then timer.Simple(1, installSticky) end
cvars.AddChangeCallback("smh_hub_sticky", function()
    concommand.Add("+smh_menu", function() SMH.UI.Open() end)
    concommand.Add("-smh_menu", function() SMH.UI.Close() end)
    installSticky()
end, "SMHToolsHubStickyChange")

print("[SMH Tools Hub] loaded")
