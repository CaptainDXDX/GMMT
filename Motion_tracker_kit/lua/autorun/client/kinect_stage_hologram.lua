-- Kinect Stage Hologram (client)
-- Install: addons/<your_addon>/lua/autorun/client/kinect_stage_hologram.lua
--
-- While a Kinect controller is running (the stock "Control With Motion Sensor"
-- or the converted one) this draws a green hologram of the ragdoll in a
-- T-pose where the ragdoll will be placed, so you can see where to stand /
-- where to put the Kinect stage prop.
--
-- The hologram follows your real position in front of the sensor and turns
-- with your shoulders, using the same maths the controllers use to place the
-- ragdoll. When the sensor cannot see you it sits at the stage prop instead.
--
-- Console: kinect_hologram 0 turns it off.  kinect_hologram_alpha 0..1.
if SERVER then AddCSLuaFile() return end

local showCvar = CreateClientConVar("kinect_hologram", "1", true, false, "Show the tracking hologram while a Kinect controller is active")
local alphaCvar = CreateClientConVar("kinect_hologram_alpha", "0.35", true, false, "Hologram brightness 0..1")
local wireCvar = CreateClientConVar("kinect_hologram_wire", "1", true, false, "Draw the wireframe outline on the hologram")
local solidCvar = CreateClientConVar("kinect_hologram_solid", "1", true, false, "Draw the filled green tint on the hologram")

local solidMat = Material("models/debug/debugwhite")
local wireMat = Material("models/wireframe")

local PELVIS_NAMES = { "ValveBiped.Bip01_Pelvis", "bip_pelvis", "Bip01_Pelvis", "pelvis", "hips" }
local POSE_SEQUENCES = { "reference", "ref", "ragdoll", "idle_all_01" }

local holo = {} -- stage entity -> { ent = clientside model, model = path, pelvis = local pelvis offset }

local function removeHolo(stage)
    local h = holo[stage]
    if h and IsValid(h.ent) then h.ent:Remove() end
    holo[stage] = nil
end

local function makeHolo(stage, target)
    local mdl = target:GetModel()
    if not mdl or mdl == "" then return nil end
    local cs = ClientsideModel(mdl, RENDERGROUP_TRANSLUCENT)
    if not IsValid(cs) then return nil end
    cs:SetNoDraw(true)
    for _, name in ipairs(POSE_SEQUENCES) do
        local seq = cs:LookupSequence(name)
        if seq and seq > 0 then cs:ResetSequence(seq) break end
    end
    cs:SetCycle(0)
    cs:SetPlaybackRate(0)

    -- where the pelvis sits relative to the model origin (at yaw 0)
    cs:SetPos(vector_origin)
    cs:SetAngles(angle_zero)
    cs:SetupBones()
    local pelvisBone = 0
    for _, n in ipairs(PELVIS_NAMES) do
        local b = cs:LookupBone(n)
        if b and b >= 0 then pelvisBone = b break end
    end
    local bp = cs:GetBonePosition(pelvisBone)
    if not bp or bp == vector_origin then bp = Vector(0, 0, 40) end
    local h = { ent = cs, model = mdl, pelvis = bp }
    holo[stage] = h
    return h
end

-- Returns world position and yaw where the ragdoll will be, from the live sensor.
local function trackedPlacement(stage)
    local ply = LocalPlayer()
    local scale = stage:GetScale()
    local rot = stage:GetAngles()
    rot:RotateAroundAxis(rot:Up(), -90) -- same rotation the controllers apply

    if not motionsensor or not SENSORBONE or not ply.MotionSensorPos then
        return stage:GetPos(), stage:GetAngles().y, false
    end
    local function joint(i)
        local v = ply:MotionSensorPos(i)
        if not v then return nil end
        v = Vector(v)
        v:Rotate(rot)
        return v
    end
    local hipRaw = ply:MotionSensorPos(SENSORBONE.HIP)
    if not hipRaw or (math.abs(hipRaw.x) <= 0.05 and math.abs(hipRaw.y) <= 0.05) then
        return stage:GetPos(), stage:GetAngles().y, false -- sensor does not see a body
    end
    local hip = joint(SENSORBONE.HIP)
    local r, l = joint(SENSORBONE.SHOULDER_RIGHT), joint(SENSORBONE.SHOULDER_LEFT)
    local pos = stage:GetPos() + hip * scale
    local yaw = stage:GetAngles().y
    if r and l then
        local across = r - l
        across.z = 0
        if across:LengthSqr() > 1e-6 then
            local fwd = Vector(0, 0, 1):Cross(across) -- body "forward": up x (right shoulder - left shoulder)
            yaw = math.deg(math.atan2(fwd.y, fwd.x))
        end
    end
    return pos, yaw, true
end

hook.Add("PostDrawTranslucentRenderables", "KinectStageHologram", function(depth, sky)
    if depth or sky then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    if not showCvar:GetBool() then
        for stage in pairs(holo) do removeHolo(stage) end
        return
    end

    local seen = {}
    for _, stage in ipairs(ents.FindByClass("ragdoll_motion")) do
        local target = stage:GetTarget()
        if IsValid(target) and stage:GetController() == ply then
            seen[stage] = true
            local h = holo[stage]
            if h and (not IsValid(h.ent) or h.model ~= target:GetModel()) then removeHolo(stage) h = nil end
            h = h or makeHolo(stage, target)
            if h then
                local pos, yaw, tracked = trackedPlacement(stage)
                local ang = Angle(0, yaw, 0)
                local off = Vector(h.pelvis)
                off:Rotate(ang)
                h.ent:SetPos(pos - off)
                h.ent:SetAngles(ang)
                h.ent:SetupBones()

                local a = math.Clamp(alphaCvar:GetFloat(), 0, 1)
                if not tracked then a = a * (0.55 + 0.25 * math.sin(CurTime() * 3)) end -- pulse when the sensor sees nobody
                render.SetColorModulation(0.25, 1, 0.45)
                if solidCvar:GetBool() then
                    render.MaterialOverride(solidMat)
                    render.SetBlend(a * 0.35)
                    h.ent:DrawModel()
                end
                if wireCvar:GetBool() then
                    render.MaterialOverride(wireMat)
                    render.SetBlend(math.min(1, a * 1.8))
                    h.ent:DrawModel()
                end
                render.MaterialOverride(nil)
                render.SetBlend(1)
                render.SetColorModulation(1, 1, 1)
            end
        end
    end
    for stage in pairs(holo) do
        if not seen[stage] or not IsValid(stage) then removeHolo(stage) end
    end
end)

-- Options: Q menu -> Utilities -> Kinect -> Tracking Hologram
hook.Add("PopulateToolMenu", "KinectStageHologramMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Kinect", "kinect_hologram_opts", "Tracking Hologram", "", "", function(panel)
        panel:ClearControls()
        panel:CheckBox("Show the tracking hologram", "kinect_hologram")
        panel:CheckBox("Wireframe outline", "kinect_hologram_wire")
        panel:CheckBox("Filled green tint", "kinect_hologram_solid")
        panel:NumSlider("Brightness", "kinect_hologram_alpha", 0, 1, 2)
        panel:Help("Untick 'Wireframe outline' to hide the wireframe but keep the tint, or untick the first box to hide everything.")
    end)
end)

-- Right-click the Kinect stage prop -> Toggle Tracking Hologram
properties.Add("kinect_hologram_toggle", {
    MenuLabel = "Toggle Tracking Hologram",
    Order = 2000,
    MenuIcon = "icon16/eye.png",
    Filter = function(self, ent, ply) return IsValid(ent) and ent:GetClass() == "ragdoll_motion" end,
    Action = function(self, ent)
        RunConsoleCommand("kinect_hologram", showCvar:GetBool() and "0" or "1")
    end,
})
