-- GMMT UI + Hub (client)
-- Install: addons/<your_addon>/lua/autorun/client/gmmt_ui.lua
--
--  * Dark grey / white look with small animations for every GMMT window
--    (Face Tracking, Finger Tracking, Kinect Recorder, Kinect Converter ...).
--    Windows are restyled automatically when they open - the tool files need no changes.
--  * Clean Half-Life 2 UI sounds for clicks and for switching things on / off.
--  * The GMMT Hub: version, Discord link, logo and a list of all tools.
--    Open it with the console command  gmmt_hub  (also  !gmmt  in chat).
--    A chat message tells you the command when you join.
--
-- EDIT THESE THREE LINES:
if SERVER then AddCSLuaFile() return end

GMMT = GMMT or {}
GMMT.Version = "0.1.92"
GMMT.Discord = "https://discord.gg/tDWfFDHgSU"   -- <- put your real invite link here
GMMT.Command = "gmmt_hub"
GMMT.UI = GMMT.UI or {}
local UI = GMMT.UI

-- Fallback logo file (only used if the embedded gmmt_logo_data.lua is missing).
local LOGO_PATH = "gmmt/logo.png"

local cvSounds  = CreateClientConVar("gmmt_ui_sounds", "1", true, false, "Play GMMT interface sounds")
local cvVolume  = CreateClientConVar("gmmt_ui_volume", "0.6", true, false, "Volume of the GMMT interface sounds (0-1)")
local cvAnim    = CreateClientConVar("gmmt_ui_anim", "1", true, false, "Animate GMMT windows")
local cvWelcome = CreateClientConVar("gmmt_welcome", "1", true, false, "Show the GMMT Hub hint in chat when joining")

-- ---------------------------------------------------------------------------
-- Look
-- ---------------------------------------------------------------------------
local C = {
    window  = Color(34, 35, 39),
    header  = Color(26, 27, 30),
    panel   = Color(44, 45, 50),
    control = Color(60, 61, 67),
    hover   = Color(80, 82, 90),
    down    = Color(48, 49, 55),
    text    = Color(255, 255, 255),
    muted   = Color(168, 170, 178),
    accent  = Color(96, 165, 250),
    good    = Color(96, 205, 128),
    line    = Color(70, 72, 80),
}
UI.Colors = C

surface.CreateFont("GMMT.Title",  { font = "Roboto", size = 26, weight = 700, extended = true })
surface.CreateFont("GMMT.Header", { font = "Roboto", size = 16, weight = 600, extended = true })
surface.CreateFont("GMMT.Text",   { font = "Roboto", size = 15, weight = 400, extended = true })
surface.CreateFont("GMMT.Small",  { font = "Roboto", size = 13, weight = 400, extended = true })
surface.CreateFont("GMMT.Logo",   { font = "Roboto", size = 34, weight = 800, extended = true })

-- ---------------------------------------------------------------------------
-- Sounds (all stock Half-Life 2 files; swap them here if you like)
-- { file, pitch }
-- ---------------------------------------------------------------------------
UI.Sounds = {
    click = { "ui/buttonclickrelease.wav", 100 },
    on    = { "ui/buttonclickrelease.wav", 125 },
    off   = { "ui/buttonclickrelease.wav", 80 },
    open  = { "ui/buttonrollover.wav", 100 },
}

function UI.Play(name)
    if not cvSounds:GetBool() then return end
    local s = UI.Sounds[name]
    if not s then return end
    local ply = LocalPlayer()
    if IsValid(ply) then
        ply:EmitSound(s[1], 0, s[2], math.Clamp(cvVolume:GetFloat(), 0, 1))
    else
        surface.PlaySound(s[1])
    end
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function approach(self, key, target, speed)
    if not cvAnim:GetBool() then self[key] = target return target end
    local v = self[key] or target
    v = v + (target - v) * math.min(1, FrameTime() * speed)
    self[key] = v
    return v
end

local function mix(a, b, t)
    return Color(Lerp(t, a.r, b.r), Lerp(t, a.g, b.g), Lerp(t, a.b, b.b), Lerp(t, a.a, b.a))
end

-- Every panel's table already contains the class's own Paint, so "has a Paint" says nothing.
-- A Paint counts as the tool file's own only when it differs from the class default.
local function defaultPaint(class)
    local guard = 0
    while class and guard < 12 do
        local ctl = vgui.GetControlTable(class)
        if not ctl then return nil end
        if ctl.Paint then return ctl.Paint end
        class = ctl.Base
        guard = guard + 1
    end
    return nil
end

local function ownPaint(p)
    local t = p:GetTable()
    if not t or t.Paint == nil then return false end
    local class = t.ClassName or t.WidgetType
    return t.Paint ~= defaultPaint(class)
end

local function safe(fn, ...)
    if not isfunction(fn) then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- A Derma skin that only changes text colours (shapes are painted per control below).
local skinOk = false
pcall(function()
    local base = derma.GetDefaultSkin and derma.GetDefaultSkin()
    if not base then return end
    local skin = table.Copy(base)
    local col = skin.Colours
    if col then
        if col.Label then
            col.Label.Default, col.Label.Bright, col.Label.Dark, col.Label.Highlight = C.text, C.text, C.muted, C.accent
        end
        if col.Button then
            col.Button.Normal, col.Button.Hover, col.Button.Down, col.Button.Disabled = C.text, C.text, C.text, C.muted
        end
        if col.Window then col.Window.TitleActive, col.Window.TitleInactive = C.text, C.muted end
    end
    derma.DefineSkin("GMMT", "GMMT dark", skin)
    skinOk = true
end)

-- ---------------------------------------------------------------------------
-- Per-control styling
-- ---------------------------------------------------------------------------
local S = {}

local function styleVBar(p)
    if not isfunction(p.GetVBar) then return end
    local vb = p:GetVBar()
    if not IsValid(vb) or vb.GMMTBar then return end
    vb.GMMTBar = true
    if vb.SetHideButtons then vb:SetHideButtons(true) end
    vb:SetWide(8)
    vb.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, C.header) end
    if IsValid(vb.btnGrip) then
        vb.btnGrip.Paint = function(self, w, h)
            local hv = approach(self, "_gh", (self:IsHovered() or self.Depressed) and 1 or 0, 14)
            draw.RoundedBox(4, 0, 0, w, h, mix(C.control, C.accent, hv))
        end
    end
end

S.DFrame = function(f)
    if skinOk then f:SetSkin("GMMT") end
    if not ownPaint(f) then
        f.Paint = function(_, w, h)
            draw.RoundedBox(8, 0, 0, w, h, C.window)
            draw.RoundedBoxEx(8, 0, 0, w, 24, C.header, true, true, false, false)
            surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 150)
            surface.DrawRect(0, 24, w, 1)
        end
    end
    if IsValid(f.lblTitle) then
        f.lblTitle:SetTextColor(C.text)
        f.lblTitle:SetFont("GMMT.Header")
    end
    for _, name in ipairs({ "btnClose", "btnMaxim", "btnMinim" }) do
        local b = f[name]
        if IsValid(b) then
            local glyph = (name == "btnClose" and "x") or (name == "btnMaxim" and "o") or "-"
            b.Paint = function(self, w, h)
                local hv = approach(self, "_gh", self:IsHovered() and 1 or 0, 16)
                draw.RoundedBox(4, 2, 2, w - 4, h - 6, mix(Color(0, 0, 0, 0), name == "btnClose" and Color(200, 70, 70) or C.hover, hv))
                draw.SimpleText(glyph, "GMMT.Header", w / 2, h / 2 - 2, C.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            b:SetText("")
        end
    end
    if cvAnim:GetBool() then
        f:SetAlpha(0)
        f:AlphaTo(255, 0.16, 0)
    end
end

S.DButton = function(b)
    b:SetTextColor(C.text)
    b.DoClickInternal = function() UI.Play("click") end
    if not ownPaint(b) then
        b.Paint = function(self, w, h)
            local enabled = self:IsEnabled()
            local hv = approach(self, "_gh", (enabled and self:IsHovered()) and 1 or 0, 14)
            local col = mix(C.control, C.hover, hv)
            if enabled and self:IsDown() then col = C.down end
            if not enabled then col = C.panel end
            draw.RoundedBox(5, 0, 0, w, h, col)
            self:SetTextColor(enabled and C.text or C.muted)
        end
    end
end

S.DTab = function(t)
    t:SetTextColor(C.text)
    t.DoClickInternal = function() UI.Play("click") end
    t.Paint = function(self, w, h)
        local active = self.IsActive and self:IsActive()
        local hv = approach(self, "_gh", (active or self:IsHovered()) and 1 or 0, 14)
        draw.RoundedBoxEx(5, 0, 0, w, h, mix(C.header, C.panel, hv), true, true, false, false)
        if active then
            surface.SetDrawColor(C.accent)
            surface.DrawRect(0, h - 2, w, 2)
        end
    end
end

S.DPropertySheet = function(s)
    if ownPaint(s) then return end
    s.Paint = function(self, w, h)
        local top = (IsValid(self.tabScroller) and self.tabScroller:GetTall() or 20) - 1
        draw.RoundedBox(5, 0, top, w, h - top, C.panel)
    end
end

S.DCheckBoxLabel = function(c)
    c:SetTextColor(C.text)
    local b = c.Button
    if not IsValid(b) or b.GMMTBox then return end
    b.GMMTBox = true
    local orig = b.Toggle
    if isfunction(orig) then
        b.Toggle = function(self, ...)
            orig(self, ...)
            UI.Play(self:GetChecked() and "on" or "off")
        end
    end
    b.Paint = function(self, w, h)
        local on = self:GetChecked() and 1 or 0
        local p = approach(self, "_gc", on, 18)
        local hv = approach(self, "_gh", self:IsHovered() and 1 or 0, 14)
        draw.RoundedBox(4, 0, 0, w, h, mix(C.control, C.hover, hv))
        if p > 0.02 then
            local pad = (1 - p) * (w / 2 - 1) + 3
            draw.RoundedBox(3, pad, pad, w - pad * 2, h - pad * 2, C.accent)
        end
    end
end

S.DTextEntry = function(t)
    t:SetTextColor(C.text)
    if t.SetCursorColor then t:SetCursorColor(C.text) end
    if t.SetHighlightColor then t:SetHighlightColor(C.accent) end
    if ownPaint(t) then return end
    t.Paint = function(self, w, h)
        local focus = approach(self, "_gf", self:HasFocus() and 1 or 0, 14)
        draw.RoundedBox(4, 0, 0, w, h, mix(C.control, C.accent, focus))
        draw.RoundedBox(3, 1, 1, w - 2, h - 2, C.header)
        self:DrawTextEntryText(C.text, C.accent, C.text)
    end
end

local function styleMenu(menu)
    if not IsValid(menu) then return end
    menu.Paint = function(_, w, h)
        draw.RoundedBox(5, 0, 0, w, h, C.line)
        draw.RoundedBox(5, 1, 1, w - 2, h - 2, C.window)
    end
    local canvas = menu.GetCanvas and menu:GetCanvas()
    for _, opt in ipairs(canvas and canvas:GetChildren() or menu:GetChildren()) do
        if IsValid(opt) and opt.SetTextColor then
            opt:SetTextColor(C.text)
            opt.DoClickInternal = function() UI.Play("click") end
            opt.Paint = function(self, w, h)
                local hv = approach(self, "_gh", self:IsHovered() and 1 or 0, 16)
                draw.RoundedBox(3, 2, 1, w - 4, h - 2, mix(Color(0, 0, 0, 0), C.hover, hv))
            end
        end
    end
end
UI.StyleMenu = styleMenu

S.DComboBox = function(c)
    c:SetTextColor(C.text)
    if not ownPaint(c) then
        c.Paint = function(self, w, h)
            local hv = approach(self, "_gh", (self:IsHovered() or self:IsMenuOpen()) and 1 or 0, 14)
            draw.RoundedBox(4, 0, 0, w, h, mix(C.control, C.hover, hv))
        end
    end
    if IsValid(c.DropButton) then
        c.DropButton.Paint = function(_, w, h)
            draw.NoTexture()
            surface.SetDrawColor(C.text)
            local cx, cy = w / 2, h / 2
            surface.DrawPoly({ { x = cx - 4, y = cy - 2 }, { x = cx + 4, y = cy - 2 }, { x = cx, y = cy + 3 } })
        end
    end
    local open = c.OpenMenu
    if isfunction(open) then
        c.OpenMenu = function(self, ...)
            UI.Play("click")
            open(self, ...)
            styleMenu(self.Menu)
        end
    end
end

S.DSlider = function(s)
    if ownPaint(s) then return end
    s.Paint = function(self, w, h)
        local fx = approach(self, "_sx", self:GetSlideX(), 22)
        draw.RoundedBox(2, 0, h / 2 - 2, w, 4, C.control)
        draw.RoundedBox(2, 0, h / 2 - 2, math.max(4, w * fx), 4, C.accent)
    end
    local k = s.Knob
    if IsValid(k) then
        k.Paint = function(self, w, h)
            local hv = approach(self, "_gh", (self:IsHovered() or self.Depressed) and 1 or 0, 14)
            draw.RoundedBox(h / 2, 0, 0, w, h, mix(C.text, C.accent, hv))
        end
    end
end

S.DCollapsibleCategory = function(c)
    if not ownPaint(c) then
        c.Paint = function(_, w, h) draw.RoundedBox(6, 0, 0, w, h, C.panel) end
    end
end

-- Plain containers: the default Derma look is white/light grey, so give them the dark panel colour.
S.DPanel = function(p)
    if ownPaint(p) then return end
    p.Paint = function(self, w, h)
        if self.GetPaintBackground and not self:GetPaintBackground() then return end
        draw.RoundedBox(5, 0, 0, w, h, self.m_bgColor or C.panel)
    end
end

S.DPanelList = function(p)
    if ownPaint(p) then return end
    p.Paint = function(self, w, h)
        if self.m_bBackground == false then return end
        draw.RoundedBox(5, 0, 0, w, h, C.panel)
    end
end

S.DNumberWang = S.DTextEntry

S.DListView = function(lv)
    if ownPaint(lv) then return end
    lv.Paint = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, C.header) end
end

S.DListView_Column = function(c)
    c:SetTextColor(C.text)
    c.Paint = function(self, w, h)
        draw.RoundedBoxEx(4, 0, 0, w, h, C.control, true, true, false, false)
    end
end

S.DListView_Line = function(l)
    l.Paint = function(self, w, h)
        local sel = self.IsLineSelected and self:IsLineSelected() or false
        local hv = approach(self, "_gh", (sel or self:IsHovered()) and 1 or 0, 16)
        local base = (self:GetID() or 0) % 2 == 0 and C.header or C.window
        draw.RoundedBox(0, 0, 0, w, h, sel and C.accent or mix(base, C.hover, hv * 0.6))
        for _, col in ipairs(self.Columns or {}) do
            if IsValid(col) and col.SetTextColor then col:SetTextColor(sel and Color(10, 16, 26) or C.text) end
        end
    end
end

S.DTree = function(t)
    if ownPaint(t) then return end
    t.Paint = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, C.header) end
end

S.DTree_Node = function(n)
    if IsValid(n.Label) then n.Label:SetTextColor(C.text) end
end


local function classOf(p)
    return p.ClassName or p.WidgetType
end

local function applyTo(p)
    if not IsValid(p) then return end
    local tbl = p:GetTable()
    if not tbl or tbl.GMMTDone then return end
    tbl.GMMTDone = true
    local fn = S[classOf(p) or ""]
    if fn then pcall(fn, p) end
    pcall(styleVBar, p)
    local old = tbl.OnChildAdded
    p.OnChildAdded = function(self, child)
        if old then old(self, child) end
        timer.Simple(0, function() if IsValid(child) then applyTo(child) end end)
    end
    for _, c in ipairs(p:GetChildren()) do applyTo(c) end
end

-- Restyle a window and everything inside it (now and later).
function UI.Style(root)
    if not IsValid(root) then return end
    timer.Simple(0, function() applyTo(root) end)
end

-- Windows from the tool files are found by title and restyled when they open.
local TOOL_WORDS = { "gmmt", "kinect", "face", "finger", "hologram", "skeleton", "converter", "recorder", "tracking" }
timer.Create("GMMTUIScan", 0.4, 0, function()
    local world = vgui.GetWorldPanel()
    if not IsValid(world) then return end
    for _, p in ipairs(world:GetChildren()) do
        if IsValid(p) and classOf(p) == "DFrame" and not p:GetTable().GMMTDone and IsValid(p.lblTitle) then
            local title = string.lower(p.lblTitle:GetText() or "")
            for _, w in ipairs(TOOL_WORDS) do
                if string.find(title, w, 1, true) then
                    UI.Style(p)
                    break
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Animation addons (SMH today; others can be added with GMMT.RegisterAddon)
-- ---------------------------------------------------------------------------
GMMT.Addons = GMMT.Addons or {}
GMMT.AddonOrder = GMMT.AddonOrder or {}
local cvAddon = CreateClientConVar("gmmt_addon", "smh", true, false, "Animation addon the GMMT Hub opens")
local cvSMHPlugin = CreateClientConVar("gmmt_smh_plugin", "1", true, false, "Use the GMMT plugin inside SMH (tool strip, menu key)")

-- def = { id, name, isInstalled=fn, pluginInstalled=fn, open=fn, close=fn, isOpen=fn, missingHint="..." }
function GMMT.RegisterAddon(def)
    if not def or not def.id then return end
    if not GMMT.Addons[def.id] then GMMT.AddonOrder[#GMMT.AddonOrder + 1] = def.id end
    GMMT.Addons[def.id] = def
end

GMMT.RegisterAddon({
    id = "smh",
    name = "Stop Motion Helper (SMH)",
    isInstalled = function() return SMH ~= nil and SMH.UI ~= nil and isfunction(SMH.UI.Open) end,
    -- the GMMT plugin for SMH is smh_tools_hub.lua (adds the tool strip and registers the tools)
    pluginInstalled = function() return SMHToolsHub ~= nil end,
    pluginCvar = "gmmt_smh_plugin",
    open = function() SMH.UI.Open() end,
    close = function() SMH.UI.Close() end,
    isOpen = function() return SMH.UI.IsOpen() == true end,
    missingHint = "SMH was not found. Subscribe to Stop Motion Helper on the Workshop and rejoin.",
    pluginHint = "The GMMT plugin for SMH is missing. Install smh_tools_hub.lua.",
})

local function addonState(def)
    local installed = safe(def.isInstalled) and true or false
    local plugin = installed and (safe(def.pluginInstalled) and true or false) or false
    return installed, plugin
end

local function selectedAddon()
    local id = cvAddon:GetString()
    if GMMT.Addons[id] then return GMMT.Addons[id] end
    return GMMT.Addons[GMMT.AddonOrder[1] or ""]
end

-- ---------------------------------------------------------------------------
-- The Hub
-- ---------------------------------------------------------------------------
local hub
local logoMat

local function getLogo()
    if logoMat ~= nil then return logoMat or nil end
    logoMat = false
    -- 1) logo embedded in Lua: gmmt_logo_data.lua sets GMMT.LogoBase64 (travels with the Lua files, no extra download)
    if isstring(GMMT.LogoBase64) and GMMT.LogoBase64 ~= "" then
        local raw = util.Base64Decode(GMMT.LogoBase64)
        if raw and #raw > 0 then
            file.Write("gmmt_logo.png", raw)
            local m = Material("data/gmmt_logo.png", "smooth")
            if m and not m:IsError() then logoMat = m return m end
        end
    end
    -- 2) a normal material file shipped with the addon
    if file.Exists("materials/" .. LOGO_PATH, "GAME") then
        local m = Material(LOGO_PATH, "smooth")
        if m and not m:IsError() then logoMat = m end
    end
    return logoMat or nil
end

local function drawLogo(x, y, size)
    local m = getLogo()
    if m then
        surface.SetDrawColor(255, 255, 255, 255)
        surface.SetMaterial(m)
        surface.DrawTexturedRect(x, y, size, size)
    else
        -- placeholder until a real logo exists
        draw.RoundedBox(14, x, y, size, size, C.accent)
        draw.RoundedBox(12, x + 3, y + 3, size - 6, size - 6, C.header)
        draw.SimpleText("G", "GMMT.Logo", x + size / 2, y + size / 2 - 1, C.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

local function hubButton(parent, text, x, y, w, h, onClick)
    local b = vgui.Create("DButton", parent)
    b:SetText(text) b:SetFont("GMMT.Text")
    b:SetPos(x, y) b:SetSize(w, h)
    b.DoClick = onClick
    return b
end

local function toolRows(scroll)
    local SH = SMHToolsHub
    if SH and not cvSMHPlugin:GetBool() then
        local l = vgui.Create("DLabel", scroll)
        l:Dock(TOP) l:SetTall(46) l:SetWrap(true) l:SetFont("GMMT.Text") l:SetTextColor(C.muted)
        l:SetText("The GMMT plugin for SMH is turned off. Tick the box above to use the tools.")
        return
    end
    if not (SH and SH.order and #SH.order > 0) then
        local l = vgui.Create("DLabel", scroll)
        l:Dock(TOP) l:SetTall(46) l:SetWrap(true) l:SetFont("GMMT.Text") l:SetTextColor(C.muted)
        l:SetText("No tools are registered yet. Install smh_tools_hub.lua and the tool files, then reopen the Hub.")
        return
    end
    for _, id in ipairs(SH.order) do
        local t = SH.tools[id]
        if t then
            local row = vgui.Create("DPanel", scroll)
            row:Dock(TOP) row:SetTall(42) row:DockMargin(0, 0, 8, 6)
            row.Paint = function(self, w, h)
                draw.RoundedBox(6, 0, 0, w, h, C.panel)
                draw.SimpleText(t.name or id, "GMMT.Header", 14, h / 2, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local active = safe(t.isActive)
                local st = safe(t.status)
                local text = active and ("Running" .. ((st and st ~= "") and (" - " .. tostring(st)) or "")) or (safe(t.isOpen) and "Open" or "")
                if text ~= "" then
                    draw.SimpleText(text, "GMMT.Small", w - 110, h / 2, active and C.good or C.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
                end
            end
            local b = vgui.Create("DButton", row)
            b:Dock(RIGHT) b:SetWide(86) b:DockMargin(0, 6, 8, 6) b:SetFont("GMMT.Text")
            b.Think = function(self) self:SetText(safe(t.isOpen) and "Close" or "Open") end
            b.DoClick = function()
                if safe(t.isOpen) then safe(t.close) UI.Play("off") else safe(t.open) UI.Play("on") end
            end
        end
    end
end

function UI.OpenHub()
    if IsValid(hub) then
        hub:Remove()
        UI.Play("off")
        return
    end
    UI.Play("open")
    local W, H = 580, 560
    hub = vgui.Create("DFrame")
    hub:SetSize(W, H) hub:Center()
    hub:SetTitle("") hub:ShowCloseButton(false) hub:SetDraggable(true)
    hub:MakePopup()
    hub.Paint = function(_, w, h)
        draw.RoundedBox(10, 0, 0, w, h, C.window)
        draw.RoundedBoxEx(10, 0, 0, w, 100, C.header, true, true, false, false)
        surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 170)
        surface.DrawRect(0, 100, w, 1)
        drawLogo(22, 18, 64)
        draw.SimpleText("GMMT Hub", "GMMT.Title", 104, 24, C.text)
        draw.SimpleText("Garry's Mod Motion Tracker", "GMMT.Text", 106, 56, C.muted)
        draw.SimpleText("Version " .. GMMT.Version, "GMMT.Small", 106, 76, C.accent)
        draw.SimpleText("Animation addon", "GMMT.Header", 22, 114, C.text)
        draw.SimpleText("Tools", "GMMT.Header", 22, 242, C.text)
    end

    local close = vgui.Create("DButton", hub)
    close:SetText("") close:SetSize(28, 28) close:SetPos(W - 38, 10)
    close.DoClickInternal = function() UI.Play("off") end
    close.DoClick = function() hub:Remove() end
    close.Paint = function(self, w, h)
        local hv = approach(self, "_gh", self:IsHovered() and 1 or 0, 16)
        draw.RoundedBox(6, 0, 0, w, h, mix(Color(0, 0, 0, 0), Color(200, 70, 70), hv))
        draw.SimpleText("x", "GMMT.Header", w / 2, h / 2 - 1, C.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    local d = hubButton(hub, "Join the Discord", W - 178, 56, 150, 30, function()
        if GMMT.Discord and GMMT.Discord ~= "" then gui.OpenURL(GMMT.Discord) end
    end)
    d.Paint = function(self, w, h)
        local hv = approach(self, "_gh", self:IsHovered() and 1 or 0, 14)
        draw.RoundedBox(6, 0, 0, w, h, mix(C.accent, Color(130, 190, 255), hv))
        self:SetTextColor(Color(14, 20, 30))
    end

    -- ---- animation addon picker ----
    local card = vgui.Create("DPanel", hub)
    card:SetPos(22, 138) card:SetSize(W - 44, 94)
    card.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, C.panel)
        local def = selectedAddon()
        if not def then
            draw.SimpleText("No animation addons registered.", "GMMT.Text", 14, h / 2, C.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            return
        end
        local installed, plugin = addonState(def)
        local pcv = def.pluginCvar and GetConVar(def.pluginCvar)
        local line1, col1
        if not installed then
            line1, col1 = def.missingHint or "Not installed.", Color(235, 110, 110)
        elseif not plugin then
            line1, col1 = def.pluginHint or "GMMT plugin missing.", Color(240, 190, 90)
        elseif pcv and not pcv:GetBool() then
            line1, col1 = "Installed - GMMT plugin turned off", C.muted
        else
            line1, col1 = "Installed - GMMT plugin active", C.good
        end
        draw.SimpleText(line1, "GMMT.Small", 14, h - 8, col1, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
    end
    local combo = vgui.Create("DComboBox", card)
    combo:SetPos(12, 10) combo:SetSize(260, 26) combo:SetFont("GMMT.Text")
    for _, id in ipairs(GMMT.AddonOrder) do
        local def = GMMT.Addons[id]
        local installed = addonState(def)
        combo:AddChoice(def.name .. (installed and "" or "  (not found)"), id, id == (selectedAddon() or {}).id)
    end
    combo.OnSelect = function(_, _, _, id) cvAddon:SetString(id) end
    local openBtn = vgui.Create("DButton", card)
    openBtn:SetPos(284, 10) openBtn:SetSize(card:GetWide() - 284 - 12, 26) openBtn:SetFont("GMMT.Text")
    openBtn.Think = function(self)
        local def = selectedAddon()
        local installed = def and addonState(def)
        self:SetEnabled(installed and true or false)
        local isOpen = installed and safe(def.isOpen)
        self:SetText(not def and "Open" or (isOpen and ("Close " .. (def.shortName or def.name:match("%((.-)%)") or def.name)) or ("Open " .. (def.shortName or def.name:match("%((.-)%)") or def.name))))
    end
    local plug = vgui.Create("DCheckBoxLabel", card)
    plug:SetPos(14, 44) plug:SetText("Use the GMMT plugin inside SMH (tool strip, menu key)")
    plug:SetConVar("gmmt_smh_plugin") plug:SizeToContents()
    openBtn.DoClick = function()
        local def = selectedAddon()
        if not def then return end
        local installed = addonState(def)
        if not installed then UI.Play("off") return end
        if safe(def.isOpen) then
            safe(def.close)
            UI.Play("off")
        else
            safe(def.open)
            UI.Play("on")
            if IsValid(hub) then hub:Remove() end   -- get out of the way of the timeline
        end
    end

    local scroll = vgui.Create("DScrollPanel", hub)
    scroll:SetPos(22, 266) scroll:SetSize(W - 44, 166)
    toolRows(scroll)

    local foot = vgui.Create("DPanel", hub)
    foot:SetPos(22, 440) foot:SetSize(W - 44, H - 440 - 14)
    foot.Paint = function(_, w, h)
        draw.RoundedBox(6, 0, 0, w, h, C.panel)
        draw.SimpleText(GMMT.Discord ~= "" and "Discord: " .. GMMT.Discord or "", "GMMT.Small", w - 12, h - 8, C.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    end
    local function check(text, cvar, x, y)
        local c = vgui.Create("DCheckBoxLabel", foot)
        c:SetPos(x, y) c:SetText(text) c:SetConVar(cvar) c:SizeToContents()
        return c
    end
    check("Interface sounds", "gmmt_ui_sounds", 14, 12)
    check("Animations", "gmmt_ui_anim", 14, 36)
    check("Chat hint on join", "gmmt_welcome", 14, 60)
    local vol = vgui.Create("DNumSlider", foot)
    vol:SetPos(190, 8) vol:SetSize(W - 44 - 204, 24)
    vol:SetText("Volume") vol:SetMin(0) vol:SetMax(1) vol:SetDecimals(2) vol:SetConVar("gmmt_ui_volume")
    local cmd = vgui.Create("DLabel", foot)
    cmd:SetPos(190, 40) cmd:SetFont("GMMT.Small") cmd:SetTextColor(C.muted)
    cmd:SetText("Open this window: console command  " .. GMMT.Command .. "  or chat  !gmmt")
    cmd:SizeToContents()

    UI.Style(hub)   -- also gives it the same fade-in as every other window
end

concommand.Add(GMMT.Command, function() UI.OpenHub() end)

hook.Add("OnPlayerChat", "GMMTHubChat", function(ply, text)
    if ply == LocalPlayer() and string.lower(string.Trim(text or "")) == "!gmmt" then
        UI.OpenHub()
        return true
    end
end)

hook.Add("InitPostEntity", "GMMTWelcome", function()
    timer.Simple(5, function()
        if not cvWelcome:GetBool() then return end
        chat.AddText(C.accent, "[GMMT] ", color_white, "Version " .. GMMT.Version .. ". Open the GMMT Hub with ",
            Color(255, 224, 130), GMMT.Command, color_white, " in the console, or type ", Color(255, 224, 130), "!gmmt", color_white, " in chat.")
    end)
end)

print("[GMMT] UI loaded - open the hub with: " .. GMMT.Command)
