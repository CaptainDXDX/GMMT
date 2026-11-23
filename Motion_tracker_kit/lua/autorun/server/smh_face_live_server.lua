-- SMH Face Tracking: live multiplayer bridge (server)
-- Install as lua/autorun/server/smh_face_live_server.lua   (keep your existing smh_face_keyframe_server.lua)
--
-- The face tracker sets flex weights on the client, which only YOU see. This file receives
-- those weights (about 20 times a second) and applies them on the server, so Garry's Mod
-- sends the face to every player.
--
-- Server setting  smh_face_live_mode  (admins change it from the face window, or in the
-- server console / as an admin with  smh_face_live_mode_set <0|1|2>):
--   0 = off
--   1 = admins only (default)
--   2 = everyone
-- When on, a player may drive their own player model, and entities they own; admins may drive
-- anything. In single player everything is allowed.
--
-- Also handles head rotation for PLAYER MODELS: the server turns the head bone with bone
-- manipulation, which Garry's Mod networks to every player.
if not SERVER then return end

local NET = "SMHFaceTracking_LiveFlex"
util.AddNetworkString(NET)

local PLAYER_HEAD_NET = "SMHFaceTracking_PlayerHead"
util.AddNetworkString(PLAYER_HEAD_NET)

local modeCvar = CreateConVar("smh_face_live_mode", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "Live face tracking shared with the server: 0 = off, 1 = admins only, 2 = everyone")

-- Admins change the mode (the face window's dropdown calls this).
concommand.Add("smh_face_live_mode_set", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local n = math.Clamp(math.floor(tonumber(args[1]) or 1), 0, 2)
    RunConsoleCommand("smh_face_live_mode", tostring(n))
    local text = "[SMH Face] Server face sharing set to " .. ({ [0] = "OFF", "ADMINS ONLY", "EVERYONE" })[n]
    print(text)
    if IsValid(ply) then ply:ChatPrint(text) end
end)

local TIMEOUT = 1.5            -- stop applying (and relax the face) if updates stop this long
local MAX_PER_SECOND = 40      -- per player, protects the server from spam
local live = {}                -- entity -> { ply = player, last = CurTime(), eye = bool }
local rate = {}                -- player -> { window start, count }

local function finite(v) return v == v and math.abs(v) < 1e6 end

local function canControl(ply, ent)
    if not IsValid(ply) or not IsValid(ent) then return false end
    local mode = modeCvar:GetInt()
    if mode <= 0 then return false end
    if game.SinglePlayer() then return true end
    if ply:IsAdmin() then return true end
    if mode < 2 then return false end            -- admins only
    if ent == ply then return true end
    if ent.CPPIGetOwner then
        local owner = ent:CPPIGetOwner()
        if owner == ply then return true end
    end
    if ent:GetOwner() == ply then return true end
    if ent.GetCreator and ent:GetCreator() == ply then return true end
    return false
end

local RELAY_NET = "SMHFaceTracking_PlayerRelay"
util.AddNetworkString(RELAY_NET)
-- Tell every OTHER player about this player's tracked eyes/head (the sender applies their own locally).
local function relay(ply, kind, a, b)
    net.Start(RELAY_NET)
    net.WriteEntity(ply)
    net.WriteUInt(kind, 2)       -- 0 = stop eye, 1 = eye, 2 = head, 3 = stop head
    if kind == 1 then
        net.WriteVector(a)
    elseif kind == 2 then
        net.WriteUInt(a, 10)
        net.WriteAngle(b)
    end
    net.SendOmit(ply)
end

local function relax(ent, st)
    if not IsValid(ent) then return end
    for i = 0, ent:GetFlexNum() - 1 do ent:SetFlexWeight(i, 0) end
    if st and st.eye and ent.SetEyeTarget then ent:SetEyeTarget(vector_origin) end
end

net.Receive(NET, function(_, ply)
    local ent = net.ReadEntity()
    local active = net.ReadBool()
    if not IsValid(ply) or not IsValid(ent) then return end
    if not canControl(ply, ent) then return end

    local now = CurTime()
    local r = rate[ply]
    if not r or now - r[1] >= 1 then r = { now, 0 } rate[ply] = r end
    r[2] = r[2] + 1
    if r[2] > MAX_PER_SECOND then return end

    if not active then
        local st = live[ent]
        if st and st.ply == ply then
            relax(ent, st)
            live[ent] = nil
        end
        if ent:IsPlayer() then relay(ply, 0) end
        return
    end

    local count = net.ReadUInt(10)
    local weights = {}
    for i = 0, count - 1 do weights[i] = net.ReadFloat() end
    local eye = nil
    if net.ReadBool() then
        local v = net.ReadVector()
        if finite(v.x) and finite(v.y) and finite(v.z) then eye = v end
    end

    local st = live[ent]
    if st and st.ply ~= ply and IsValid(st.ply) and now - st.last < TIMEOUT then return end -- someone else is driving it
    st = st or {}
    st.ply, st.last, st.eye = ply, now, eye ~= nil
    live[ent] = st

    local n = math.min(count, ent:GetFlexNum())
    for i = 0, n - 1 do
        local w = weights[i]
        if finite(w) then
            local lo, hi = -3, 3
            if ent.GetFlexBounds then
                local a, b = ent:GetFlexBounds(i)
                if a and b then lo, hi = math.min(a, b), math.max(a, b) end
            end
            ent:SetFlexWeight(i, math.Clamp(w, lo, hi))
        end
    end
    if ent:IsPlayer() then
        -- A player's eyes are overwritten by the engine every frame, so other clients apply
        -- them right before drawing instead (see the face file's PrePlayerDraw hook).
        relay(ply, eye and 1 or 0, eye)
    elseif eye and ent.SetEyeTarget then
        ent:SetEyeTarget(eye)
    end
end)

-- If the tracking player stops sending (tracker closed, disconnected), relax the face.
timer.Create("SMHFaceLiveTimeout", 0.5, 0, function()
    local now = CurTime()
    for ent, st in pairs(live) do
        if not IsValid(ent) then
            live[ent] = nil
        elseif not IsValid(st.ply) or now - st.last > TIMEOUT then
            relax(ent, st)
            live[ent] = nil
        end
    end
end)

hook.Add("PlayerDisconnected", "SMHFaceLiveCleanup", function(ply) rate[ply] = nil end)

-- ===========================================================================
-- Player model head rotation: validated here, then relayed to every other player, who turn
-- the head bone right before drawing (a server-side bone change was being overwritten).
-- ===========================================================================
net.Receive(PLAYER_HEAD_NET, function(_, ply)
    if not IsValid(ply) then return end
    local active = net.ReadBool()
    if not active then
        relay(ply, 3)
        return
    end
    local bone = net.ReadUInt(10)
    local ang = net.ReadAngle()
    if not canControl(ply, ply) then return end
    if bone >= ply:GetBoneCount() then return end
    local name = string.lower(ply:GetBoneName(bone) or "")
    if not string.find(name, "head", 1, true) then return end -- only ever turn a head bone
    if not (finite(ang.p) and finite(ang.y) and finite(ang.r)) then return end
    local now = CurTime()
    local r = rate[ply]
    if r and r[2] > MAX_PER_SECOND * 2 then return end
    relay(ply, 2, bone, Angle(math.Clamp(math.NormalizeAngle(ang.p), -60, 60),
        math.Clamp(math.NormalizeAngle(ang.y), -60, 60), math.Clamp(math.NormalizeAngle(ang.r), -60, 60)))
end)
