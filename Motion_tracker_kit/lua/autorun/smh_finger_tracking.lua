-- SMH Finger Tracking
-- Install: addons/<your_addon>/lua/autorun/smh_finger_tracking.lua
-- Needs finger_tracker.py running (writes garrysmod/data/smh_finger_tracking.txt).
-- Moves the finger bones of the SMH-selected model with "bone manipulation",
-- so to RECORD fingers just tick "Nonphysical Bones" on a timeline in SMH and
-- record as usual (with the Kinect recorder or normal SMH keyframes).

local NET_NAME = "SMHFingerTracking_Pose"
local NET_INFO = "SMHFingerTracking_Info"
local FINGERS = { "thumb", "index", "middle", "ring", "pinky" }

-- Bone names per rig. {hand letter} is R or L.
local RIGS = {
    {
        name = "ValveBiped",
        hand = function(letter) return "ValveBiped.Bip01_" .. letter .. "_Hand" end,
        bones = function(letter)
            local p = "ValveBiped.Bip01_" .. letter .. "_Finger"
            return {
                thumb  = { p .. "0", p .. "01", p .. "02" },
                index  = { p .. "1", p .. "11", p .. "12" },
                middle = { p .. "2", p .. "21", p .. "22" },
                ring   = { p .. "3", p .. "31", p .. "32" },
                pinky  = { p .. "4", p .. "41", p .. "42" },
            }
        end,
    },
    {
        name = "TF2",
        hand = function(letter) return "bip_hand_" .. letter end,
        bones = function(letter)
            local t = {}
            for _, f in ipairs(FINGERS) do
                t[f] = { "bip_" .. f .. "_0_" .. letter, "bip_" .. f .. "_1_" .. letter, "bip_" .. f .. "_2_" .. letter }
            end
            return t
        end,
    },
}

-- ===========================================================================
-- SERVER: applies the angles
-- ===========================================================================
if SERVER then
    AddCSLuaFile()
    util.AddNetworkString(NET_NAME)
    util.AddNetworkString(NET_INFO)

    local cache = {} -- entity -> { right = {finger={bone,..}, hand=bone}, left = ... }

    local function resolve(ent)
        local c = cache[ent]
        if c then return c end
        for _, rig in ipairs(RIGS) do
            local found = { rig = rig.name, right = {}, left = {}, count = 0 }
            for _, side in ipairs({ { "right", "R" }, { "left", "L" } }) do
                local names = rig.bones(side[2])
                for finger, list in pairs(names) do
                    found[side[1]][finger] = {}
                    for j, bname in ipairs(list) do
                        local b = ent:LookupBone(bname)
                        if b and b >= 0 then
                            found[side[1]][finger][j] = b
                            found.count = found.count + 1
                        end
                    end
                end
                local hb = ent:LookupBone(rig.hand(side[2]))
                if hb and hb >= 0 then
                    found[side[1]].hand = hb
                    -- the hand's own physics body (exact match only)
                    local pb = ent:TranslateBoneToPhysBone(hb)
                    if pb and pb >= 0 and ent:TranslatePhysBoneToBone(pb) == hb then
                        found[side[1]].handPhys = pb
                    end
                end
            end
            if found.count > 0 then
                cache[ent] = found
                return found
            end
        end
        return nil
    end

    local AXIS = { [0] = "p", [1] = "y", [2] = "r" }
    local function makeAngle(axis, deg)
        local a = Angle(0, 0, 0)
        a[AXIS[axis] or "y"] = deg
        return a
    end

    -- Every finger bone eases toward its target each tick.
    local live = {} -- entity -> { bones = {[bone]={cur,target}}, hands = {[side]={...}}, active, rest }

    local function setTarget(st, bone, ang)
        local b = st.bones[bone]
        if not b then
            b = { cur = Angle(0, 0, 0), target = Angle(ang) }
            st.bones[bone] = b
        else
            b.target = Angle(ang)
        end
    end

    local function angNear(a, b)
        return math.abs(math.AngleDifference(a.p, b.p)) < 0.05
            and math.abs(math.AngleDifference(a.y, b.y)) < 0.05
            and math.abs(math.AngleDifference(a.r, b.r)) < 0.05
    end

    local function setHandTarget(ent, st, info, side, ang)
        local pb = info[side].handPhys
        local phys = pb and ent:GetPhysicsObjectNum(pb)
        if phys and IsValid(phys) then
            local h = st.hands[side]
            if not h or h.phys ~= phys then
                h = { phys = phys, moveable = phys:IsMoveable(), base = phys:GetAngles(), cur = Angle(0, 0, 0) }
                st.hands[side] = h
            end
            h.target = Angle(ang)
        elseif info[side].hand then
            setTarget(st, info[side].hand, ang) -- no physics body: bone manipulation instead
        end
    end

    net.Receive(NET_NAME, function(_, ply)
        local ent = net.ReadEntity()
        local active = net.ReadBool()
        if not IsValid(ent) then return end
        local info = resolve(ent)
        if not info then
            if not ent.SMHFingerWarned then
                ent.SMHFingerWarned = true
                print("[SMH Fingers] No known finger bones on " .. tostring(ent:GetModel()) .. " (supported: ValveBiped, TF2).")
            end
            return
        end
        local st = live[ent]
        if not st then
            st = { bones = {}, hands = {} }
            live[ent] = st
            if active and IsValid(ply) then
                local lines = { "Rig: " .. info.rig }
                for _, side in ipairs({ "right", "left" }) do
                    local i = info[side]
                    local txt
                    if not i.hand then txt = "NO hand bone found (hand rotation impossible)"
                    elseif i.handPhys then txt = "hand turns via physics body " .. i.handPhys
                    else txt = "hand bone has NO physics body of its own - rotation falls back to bone manipulation, which ragdolls ignore" end
                    lines[#lines + 1] = side .. ": " .. txt
                end
                net.Start(NET_INFO)
                net.WriteString(table.concat(lines, "\n"))
                net.Send(ply)
            end
        end
        st.active = active
        local axis, thumbAxis = net.ReadUInt(2), net.ReadUInt(2)
        for _, side in ipairs({ "right", "left" }) do
            local has = net.ReadBool()
            for _, finger in ipairs(FINGERS) do
                for j = 1, 3 do
                    local deg = has and net.ReadFloat() or 0
                    local bone = info[side][finger] and info[side][finger][j]
                    if bone then
                        if not active then deg = 0 end
                        setTarget(st, bone, makeAngle(finger == "thumb" and thumbAxis or axis, deg))
                    end
                end
            end
            local hasRot = net.ReadBool()
            local ang = hasRot and net.ReadAngle() or Angle(0, 0, 0)
            if hasRot or not active then
                setHandTarget(ent, st, info, side, active and ang or Angle(0, 0, 0))
            end
        end
    end)

    hook.Add("Think", "SMHFingerEase", function()
        local k = math.Clamp(FrameTime() * 25, 0, 1)
        for ent, st in pairs(live) do
            if not IsValid(ent) then
                live[ent] = nil
            else
                local settled = true
                for bone, b in pairs(st.bones) do
                    b.cur = LerpAngle(k, b.cur, b.target)
                    ent:ManipulateBoneAngles(bone, b.cur)
                    if math.abs(b.cur.p - b.target.p) + math.abs(b.cur.y - b.target.y) + math.abs(b.cur.r - b.target.r) > 0.05 then
                        settled = false
                    end
                end
                for side, h in pairs(st.hands) do
                    if not IsValid(h.phys) then
                        st.hands[side] = nil
                    else
                        local cur = h.phys:GetAngles()
                        if h.lastSet and not angNear(cur, h.lastSet) then
                            h.base = cur -- the animation moved the hand: new base pose
                        end
                        h.cur = LerpAngle(k, h.cur, h.target or h.cur)
                        local _, newAng = LocalToWorld(vector_origin, h.cur, h.phys:GetPos(), h.base)
                        h.phys:EnableMotion(false)
                        h.phys:SetAngles(newAng)
                        h.phys:Wake()
                        h.lastSet = h.phys:GetAngles()
                        local t = h.target or h.cur
                        if math.abs(h.cur.p - t.p) + math.abs(h.cur.y - t.y) + math.abs(h.cur.r - t.r) > 0.05 then
                            settled = false
                        elseif st.active == false then
                            h.phys:SetAngles(h.base)
                            h.phys:EnableMotion(h.moveable)
                            h.phys:Wake()
                            st.hands[side] = nil
                        end
                    end
                end
                if st.active == false and settled and next(st.hands) == nil then live[ent] = nil end
            end
        end
    end)

    hook.Add("EntityRemoved", "SMHFingerCache", function(e) cache[e] = nil live[e] = nil end)
    return
end

-- ===========================================================================
-- CLIENT
-- ===========================================================================
local DATA_FILE = "smh_finger_tracking.txt"
local STALE_SECONDS = 2
local SEND_INTERVAL = 1 / 30

local cv = {
    scale   = CreateClientConVar("smh_finger_scale", "1", true, false),
    smooth  = CreateClientConVar("smh_finger_smooth", "0.5", true, false),
    axis    = CreateClientConVar("smh_finger_axis", "1", true, false),       -- 0 pitch,1 yaw,2 roll
    thumbAx = CreateClientConVar("smh_finger_thumb_axis", "1", true, false),
    flipL   = CreateClientConVar("smh_finger_flip_left", "0", true, false),
    flipR   = CreateClientConVar("smh_finger_flip_right", "0", true, false),
    flipT   = CreateClientConVar("smh_finger_flip_thumb", "0", true, false),
    swap    = CreateClientConVar("smh_finger_swap_hands", "0", true, false),
    compensate = CreateClientConVar("smh_finger_flatten", "1", true, false),
    extraFlat  = CreateClientConVar("smh_finger_extra_flat", "0", true, false),
    -- hand rotation
    rotOn   = CreateClientConVar("smh_hand_rot_enabled", "1", true, false),
    rotScale = CreateClientConVar("smh_hand_rot_scale", "1", true, false),
    twistAx = CreateClientConVar("smh_hand_twist_axis", "2", true, false),   -- roll
    flexAx  = CreateClientConVar("smh_hand_flex_axis", "0", true, false),    -- pitch
    sideAx  = CreateClientConVar("smh_hand_side_axis", "1", true, false),    -- yaw
    twistFlip = CreateClientConVar("smh_hand_twist_flip", "0", true, false),
    flexFlip  = CreateClientConVar("smh_hand_flex_flip", "0", true, false),
    sideFlip  = CreateClientConVar("smh_hand_side_flip", "0", true, false),
}

local rotCur = { right = nil, left = nil }   -- smoothed {roll,pitch,yaw}
local rotNeutral = { right = { 0, 0, 0 }, left = { 0, 0, 0 } }
local lastRaw = { right = nil, left = nil }  -- latest raw {roll,pitch,yaw}
local rotTest = nil                          -- test sweep: { channel, ... }

-- Turns tracked palm angles into a bone angle using the axis mapping.
local function rotToAngle(side, r)
    if not r then return nil end
    local nz = rotNeutral[side]
    local sc = cv.rotScale:GetFloat()
    local vals = {
        twist = (r[1] - nz[1]) * (cv.twistFlip:GetBool() and -1 or 1),
        flex  = (r[2] - nz[2]) * (cv.flexFlip:GetBool() and -1 or 1),
        side  = (r[3] - nz[3]) * (cv.sideFlip:GetBool() and -1 or 1),
    }
    local a = Angle(0, 0, 0)
    local key = { [0] = "p", [1] = "y", [2] = "r" }
    a[key[cv.twistAx:GetInt() % 3]] = a[key[cv.twistAx:GetInt() % 3]] + vals.twist * sc
    a[key[cv.flexAx:GetInt() % 3]]  = a[key[cv.flexAx:GetInt() % 3]] + vals.flex * sc
    a[key[cv.sideAx:GetInt() % 3]]  = a[key[cv.sideAx:GetInt() % 3]] + vals.side * sc
    a.p = math.Clamp(a.p, -90, 90) a.y = math.Clamp(a.y, -90, 90) a.r = math.Clamp(a.r, -120, 120)
    return a
end


-- ---- default finger curl of the model (measured on the client, where the
-- displayed pose is known).  Used to flatten curled default hands.
local restCur = nil
local restText = "Default curl: not measured yet"
local measureAt = nil
local serverInfo = ""

local function dev(a, b)
    local la, lb = a:Length(), b:Length()
    if la < 0.001 or lb < 0.001 then return 0 end
    return math.deg(math.acos(math.Clamp(a:Dot(b) / (la * lb), -1, 1)))
end

local function measureRest(ent)
    ent:SetupBones()
    local rig
    for _, r in ipairs(RIGS) do
        local probe = r.bones("R").index[1]
        local b = ent:LookupBone(probe)
        if b and b >= 0 then rig = r break end
    end
    if not rig then return nil, "Default curl: no known finger bones" end
    local out = { right = {}, left = {} }
    local anyPos = false
    for _, side in ipairs({ { "right", "R" }, { "left", "L" } }) do
        local names = rig.bones(side[2])
        local handB = ent:LookupBone(rig.hand(side[2]))
        local handPos = handB and handB >= 0 and (ent:GetBonePosition(handB)) or nil
        for _, f in ipairs(FINGERS) do
            local P = {}
            for j, n in ipairs(names[f]) do
                local b = ent:LookupBone(n)
                if b and b >= 0 then
                    local p = ent:GetBonePosition(b)
                    if p and p ~= vector_origin then P[j] = p anyPos = true end
                end
            end
            local r = { 0, 0, 0 }
            if P[1] and P[2] and P[3] then
                if f ~= "thumb" and handPos then r[1] = dev(P[1] - handPos, P[2] - P[1]) end
                r[2] = dev(P[2] - P[1], P[3] - P[2])
                r[3] = 0.67 * r[2]
                for j = 1, 3 do r[j] = math.min(r[j], 100) end
            end
            out[side[1]][f] = r
        end
    end
    if not anyPos then return nil, "Default curl: could not read bone positions" end
    local i = out.right.index
    return out, string.format("Default curl measured (right index): %.0f / %.0f / %.0f degrees", i[1], i[2], i[3])
end

net.Receive(NET_INFO, function() serverInfo = net.ReadString() end)

local autoApplyPreset -- defined with the preset code below
local enabled = false
local status = "Off"
local cur = { right = nil, left = nil } -- smoothed degrees: cur[side][finger][j]
local lastSend = 0
local testUntil = 0
local handTestUntil = nil
local frame

local function targetEntity()
    if not (SMH and SMH.State) then return nil end
    local e = SMH.State.Entity
    if IsValid(e) then return e end
    if istable(e) then
        for k in pairs(e) do if IsValid(k) then return k end end
    end
    return nil
end

local function blank()
    local t = {}
    for _, f in ipairs(FINGERS) do t[f] = { 0, 0, 0 } end
    return t
end

local function send(active, ent)
    net.Start(NET_NAME)
    net.WriteEntity(ent)
    net.WriteBool(active)
    net.WriteUInt(cv.axis:GetInt() % 3, 2)
    net.WriteUInt(cv.thumbAx:GetInt() % 3, 2)
    for _, side in ipairs({ "right", "left" }) do
        local d = cur[side]
        net.WriteBool(d ~= nil)
        if d then
            local flipSide = cv[side == "right" and "flipR" or "flipL"]:GetBool() and -1 or 1
            for _, f in ipairs(FINGERS) do
                local sign = flipSide * ((f == "thumb" and cv.flipT:GetBool()) and -1 or 1)
                for j = 1, 3 do
                    local deg = d[f][j] * cv.scale:GetFloat() * sign
                    if cv.compensate:GetBool() and restCur and restCur[side] and restCur[side][f] then
                        local r = restCur[side][f][j] or 0
                        if f ~= "thumb" then r = r + cv.extraFlat:GetFloat() end
                        deg = deg - sign * r -- cancel the model's own default curl
                    end
                    net.WriteFloat(deg)
                end
            end
        end
        local ang = (cv.rotOn:GetBool() and (rotTest or rotCur[side])) and (rotTest and rotTest[side] or rotToAngle(side, rotCur[side])) or nil
        net.WriteBool(ang ~= nil)
        if ang then net.WriteAngle(ang) end
    end
    net.SendToServer()
end

local function stepToward(side, target, alpha)
    local c = cur[side]
    if not target then cur[side] = nil return end
    if not c then
        c = blank()
        cur[side] = c
    end
    for _, f in ipairs(FINGERS) do
        local t = target[f] or { 0, 0, 0 }
        for j = 1, 3 do c[f][j] = Lerp(alpha, c[f][j], t[j] or 0) end
    end
end

local function stop()
    local ent = targetEntity()
    enabled = false
    status = "Off"
    if IsValid(ent) then send(false, ent) end
    cur = { right = nil, left = nil }
    rotCur = { right = nil, left = nil }
end

local function start()
    if not targetEntity() then
        status = "Select a model in SMH first."
        return
    end
    autoApplyPreset(targetEntity())
    enabled = true
    restCur = nil
    restText = "Default curl: measuring..."
    measureAt = CurTime() + 0.6 -- let any earlier pose settle first
    status = "Waiting for finger_tracker.py..."
end

hook.Add("Think", "SMHFingerTrackingThink", function()
    if not enabled then return end
    local now = CurTime()
    if now - lastSend < SEND_INTERVAL then return end
    lastSend = now

    local ent = targetEntity()
    if not IsValid(ent) then status = "No SMH model selected." return end

    if measureAt then
        if now < measureAt then status = "Measuring the model's default pose..." return end
        measureAt = nil
        restCur, restText = measureRest(ent)
    end

    local targets = { right = nil, left = nil }
    if now < testUntil then
        -- test sweep: all fingers curl and open so you can check axis/direction
        local k = (math.sin((testUntil - now) * 3) * 0.5 + 0.5) * 70
        local t = {}
        for _, f in ipairs(FINGERS) do t[f] = { k, k, k } end
        targets.right, targets.left = t, t
        status = "Test sweep"
    else
        local raw = file.Read(DATA_FILE, "DATA")
        local data = raw and raw ~= "" and util.JSONToTable(raw) or nil
        if not data or not data.hands then
            status = "No data. Is finger_tracker.py running?"
        elseif math.abs(os.time() - (data.t or 0)) > STALE_SECONDS then
            status = "Tracker not updating."
        else
            local l, r = data.hands.left, data.hands.right
            if cv.swap:GetBool() then l, r = r, l end
            targets.left, targets.right = l, r
            status = (l or r) and ("Tracking: " .. ((r and "right ") or "") .. ((l and "left") or "")) or "No hands visible."
        end
    end

    local alpha = 1 - math.Clamp(cv.smooth:GetFloat(), 0, 0.95)
    stepToward("right", targets.right, alpha)
    stepToward("left", targets.left, alpha)

    -- hand rotation (already filtered in the tracker; light easing here)
    for _, side in ipairs({ "right", "left" }) do
        local src = targets[side] and targets[side].rot
        if src then
            local raw = { src.roll or 0, src.pitch or 0, src.yaw or 0 }
            lastRaw[side] = raw
            local c = rotCur[side]
            if not c then c = { raw[1], raw[2], raw[3] } rotCur[side] = c end
            for i = 1, 3 do
                -- take the short way round at +-180
                local d = raw[i] - c[i]
                if d > 180 then d = d - 360 elseif d < -180 then d = d + 360 end
                c[i] = c[i] + d * alpha
            end
        else
            rotCur[side] = nil
        end
    end

    -- hand test: twist, then flex, then side-to-side, 40 degrees each
    if handTestUntil and now < handTestUntil then
        local phase = math.floor((handTestUntil - now) / 1.4)
        local k = math.sin((handTestUntil - now) * 4.5) * 40
        local a = Angle(0, 0, 0)
        local axisCv = ({ cv.sideAx, cv.flexAx, cv.twistAx })[phase + 1] or cv.twistAx
        local key = { [0] = "p", [1] = "y", [2] = "r" }
        a[key[axisCv:GetInt() % 3]] = k
        rotTest = { right = a, left = a }
        status = "Hand test: " .. (({ "side-to-side", "flex", "twist" })[phase + 1] or "twist")
    else
        rotTest = nil
    end
    send(true, ent)
end)

-- ---- rig presets -----------------------------------------------------------
-- A preset stores every finger / hand setting (axes, flips, strengths, flatten).
-- Files: garrysmod/data/smh_finger_presets/<name>.txt
-- A model can be linked to a preset; it is applied automatically on Start.
local PRESET_DIR = "smh_finger_presets"
local MODEL_MAP_FILE = PRESET_DIR .. "/_models.txt"
local PRESET_KEYS = { "scale", "smooth", "axis", "thumbAx", "flipL", "flipR", "flipT", "swap",
    "compensate", "extraFlat", "rotOn", "rotScale", "twistAx", "flexAx", "sideAx",
    "twistFlip", "flexFlip", "sideFlip" }
local presetRefreshers = {}   -- filled by the window's controls
local currentPreset = nil     -- name of the last applied/saved preset
local presetCombo

local function cleanName(n)
    n = string.Trim(tostring(n or ""))
    n = string.gsub(n, "[^%w_%- ]", "")
    return string.sub(n, 1, 40)
end

local function presetPath(name) return PRESET_DIR .. "/" .. name .. ".txt" end

local function listPresets()
    file.CreateDir(PRESET_DIR)
    local files = file.Find(PRESET_DIR .. "/*.txt", "DATA")
    local out = {}
    for _, f in ipairs(files or {}) do
        local n = string.StripExtension(f)
        if string.sub(n, 1, 1) ~= "_" then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

local function readModelMap()
    local raw = file.Read(MODEL_MAP_FILE, "DATA")
    return (raw and util.JSONToTable(raw)) or {}
end

local function writeModelMap(map)
    file.CreateDir(PRESET_DIR)
    file.Write(MODEL_MAP_FILE, util.TableToJSON(map, true))
end

local function savePreset(name)
    name = cleanName(name)
    if name == "" then return false end
    local data = {}
    for _, k in ipairs(PRESET_KEYS) do data[k] = cv[k]:GetString() end
    file.CreateDir(PRESET_DIR)
    file.Write(presetPath(name), util.TableToJSON(data, true))
    currentPreset = name
    return true
end

local function applyPreset(name)
    local raw = file.Read(presetPath(name), "DATA")
    local data = raw and util.JSONToTable(raw)
    if not data then return false end
    for _, k in ipairs(PRESET_KEYS) do
        if data[k] ~= nil then cv[k]:SetString(tostring(data[k])) end
    end
    currentPreset = name
    for _, fn in ipairs(presetRefreshers) do pcall(fn) end
    return true
end

local function deletePreset(name)
    file.Delete(presetPath(name))
    local map = readModelMap()
    for m, p in pairs(map) do if p == name then map[m] = nil end end
    writeModelMap(map)
    if currentPreset == name then currentPreset = nil end
end

local function refreshPresetCombo()
    if not IsValid(presetCombo) then return end
    presetCombo:Clear()
    local list = listPresets()
    for _, n in ipairs(list) do presetCombo:AddChoice(n) end
    presetCombo:SetValue(currentPreset or "(no preset)")
end

-- Applies the preset linked to this model, if there is one.
autoApplyPreset = function(ent)
    if not IsValid(ent) then return end
    local p = readModelMap()[ent:GetModel() or ""]
    if p and applyPreset(p) then
        status = "Applied preset '" .. p .. "' for this model."
        refreshPresetCombo()
    end
end

local function openWindow()
    if IsValid(frame) then frame:SetVisible(true) frame:MakePopup() return end
    presetRefreshers = {}
    frame = vgui.Create("DFrame")
    frame:SetTitle("SMH Finger Tracking")
    frame:SetSize(340, 720)
    frame:SetPos(20, 120)
    frame:SetDeleteOnClose(false)
    frame:MakePopup()

    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:Dock(FILL)

    local function label(text, tall, wrap)
        local l = vgui.Create("DLabel", scroll)
        l:Dock(TOP) l:SetTall(tall or 20) l:SetWrap(wrap or false)
        l:DockMargin(0, 2, 0, 2)
        l:SetText(text)
        return l
    end

    local st = label("", 40, true)
    st.Think = function(self) self:SetText("Status: " .. status) end
    label("1. Run finger_tracker.py   2. Select the model in SMH   3. Start.\nTo record: tick 'Nonphysical Bones' on a timeline in SMH.", 48, true)

    local btn = vgui.Create("DButton", scroll)
    btn:Dock(TOP) btn:SetTall(30) btn:DockMargin(0, 4, 0, 4)
    btn.Think = function(self) self:SetText(enabled and "Stop finger tracking" or "Start finger tracking") end
    btn.DoClick = function() if enabled then stop() else start() end end

    local test = vgui.Create("DButton", scroll)
    test:Dock(TOP) test:SetTall(26) test:DockMargin(0, 0, 0, 6)
    test:SetText("Test sweep (curls all fingers for 4 s)")
    test.DoClick = function()
        if not enabled then start() end
        testUntil = CurTime() + 4
    end

    -- ---- rig presets ----
    label("RIG PRESETS", 20)
    local modelLabel = label("", 34, true)
    modelLabel.Think = function(self)
        local e = targetEntity()
        local m = IsValid(e) and e:GetModel() or "(no model selected)"
        local linked = IsValid(e) and readModelMap()[e:GetModel() or ""]
        self:SetText("Model: " .. m .. "\nLinked preset: " .. (linked or "none"))
    end
    presetCombo = vgui.Create("DComboBox", scroll)
    presetCombo:Dock(TOP) presetCombo:SetTall(24) presetCombo:DockMargin(0, 2, 0, 2)
    presetCombo.OnSelect = function(_, _, name) applyPreset(name) end
    refreshPresetCombo()

    local function btnRow(buttons)
        local row = vgui.Create("DPanel", scroll)
        row:Dock(TOP) row:SetTall(26) row:DockMargin(0, 2, 0, 2) row.Paint = function() end
        for i, b in ipairs(buttons) do
            local x = vgui.Create("DButton", row)
            x:Dock(LEFT) x:SetWide(150) x:DockMargin(0, 0, 4, 0)
            x:SetText(b[1]) x.DoClick = b[2]
        end
    end
    btnRow({
        { "Save (overwrite)", function()
            if currentPreset and savePreset(currentPreset) then status = "Saved preset '" .. currentPreset .. "'."
            else status = "Pick a preset first, or use Save as new." end
            refreshPresetCombo()
        end },
        { "Save as new...", function()
            Derma_StringRequest("New rig preset", "Name (for example: HL2 citizen, TF2 spy):", "", function(text)
                if savePreset(text) then status = "Saved preset '" .. cleanName(text) .. "'." end
                refreshPresetCombo()
            end)
        end },
    })
    btnRow({
        { "Use for this model", function()
            local e = targetEntity()
            if not IsValid(e) or not currentPreset then status = "Select a model and a preset first." return end
            local map = readModelMap()
            map[e:GetModel()] = currentPreset
            writeModelMap(map)
            status = "This model will now use '" .. currentPreset .. "' automatically."
        end },
        { "Forget link / Delete preset", function()
            local e = targetEntity()
            local map = readModelMap()
            if IsValid(e) and map[e:GetModel()] then
                map[e:GetModel()] = nil
                writeModelMap(map)
                status = "Link removed for this model."
            elseif currentPreset then
                local n = currentPreset
                deletePreset(n)
                status = "Deleted preset '" .. n .. "'."
                refreshPresetCombo()
            end
        end },
    })
    label("Tip: set up one model (axes, flips, flatten), Save as new, then 'Use for this model'. Next time that model loads it is applied on Start. Rigs that share a skeleton can share a preset.", 52, true)

    local function slider(text, cvar, min, max, dec)
        local s = vgui.Create("DNumSlider", scroll)
        s:Dock(TOP) s:SetTall(24) s:SetText(text)
        s:SetMin(min) s:SetMax(max) s:SetDecimals(dec)
        s:SetValue(cvar:GetFloat())
        s.OnValueChanged = function(_, v) cvar:SetFloat(v) end
        presetRefreshers[#presetRefreshers + 1] = function() if IsValid(s) then s:SetValue(cvar:GetFloat()) end end
        return s
    end
    slider("Curl strength", cv.scale, 0.2, 1.5, 2)
    slider("Smoothing", cv.smooth, 0, 0.9, 2)

    local function combo(text, cvar)
        local row = vgui.Create("DPanel", scroll)
        row:Dock(TOP) row:SetTall(24) row:DockMargin(0, 2, 0, 2) row.Paint = function() end
        local l = vgui.Create("DLabel", row) l:Dock(LEFT) l:SetWide(150) l:SetText(text)
        local c = vgui.Create("DComboBox", row) c:Dock(FILL)
        c:AddChoice("Pitch", 0) c:AddChoice("Yaw", 1) c:AddChoice("Roll", 2)
        c:ChooseOptionID((cvar:GetInt() % 3) + 1)
        c.OnSelect = function(_, _, _, data) cvar:SetInt(data) end
        presetRefreshers[#presetRefreshers + 1] = function() if IsValid(c) then c:ChooseOptionID((cvar:GetInt() % 3) + 1) end end
    end
    combo("Finger curl axis", cv.axis)
    combo("Thumb curl axis", cv.thumbAx)
    label("If fingers rotate sideways or the wrong way, use Test sweep and change the axis / flip boxes until they curl.", 40, true)

    local function check(text, cvar)
        local c = vgui.Create("DCheckBoxLabel", scroll)
        c:Dock(TOP) c:DockMargin(0, 2, 0, 2) c:SetText(text)
        c:SetValue(cvar:GetBool() and 1 or 0)
        c.OnChange = function(_, v) cvar:SetBool(v) end
        presetRefreshers[#presetRefreshers + 1] = function() if IsValid(c) then c:SetValue(cvar:GetBool() and 1 or 0) end end
    end
    check("Flip right-hand curl direction", cv.flipR)
    check("Flip left-hand curl direction", cv.flipL)
    check("Flip thumb direction", cv.flipT)
    check("Flatten the model's default finger curl", cv.compensate)
    slider("Extra flatten (degrees)", cv.extraFlat, 0, 60, 0)
    local restLabel = label("", 34, true)
    restLabel.Think = function(self) self:SetText(restText) end
    local infoLabel = label("", 70, true)
    infoLabel.Think = function(self) self:SetText(serverInfo ~= "" and serverInfo or "(model info appears here after Start)") end
    label("Many models (HL2 5-finger, TF2) start with curled fingers. Flatten measures that at Start and cancels it so an open hand is flat. If fingers still look too curled when your hand is open, raise Extra flatten.", 64, true)
    check("Swap left / right hands", cv.swap)

    -- ---- hand rotation ----
    label("HAND ROTATION (wrist)", 22)
    check("Track hand rotation", cv.rotOn)
    slider("Rotation strength", cv.rotScale, 0.2, 1.5, 2)
    combo("Twist (roll) drives bone axis", cv.twistAx)
    combo("Flex (up/down) drives bone axis", cv.flexAx)
    combo("Side-to-side drives bone axis", cv.sideAx)
    check("Flip twist", cv.twistFlip)
    check("Flip flex", cv.flexFlip)
    check("Flip side-to-side", cv.sideFlip)

    local calib = vgui.Create("DButton", scroll)
    calib:Dock(TOP) calib:SetTall(26) calib:DockMargin(0, 4, 0, 2)
    calib:SetText("Calibrate hands (palm toward camera, fingers up)")
    calib.DoClick = function()
        for _, side in ipairs({ "right", "left" }) do
            if lastRaw[side] then rotNeutral[side] = { lastRaw[side][1], lastRaw[side][2], lastRaw[side][3] } end
        end
        status = "Hands calibrated."
    end
    local calReset = vgui.Create("DButton", scroll)
    calReset:Dock(TOP) calReset:SetTall(24) calReset:DockMargin(0, 0, 0, 2)
    calReset:SetText("Reset calibration")
    calReset.DoClick = function() rotNeutral = { right = { 0, 0, 0 }, left = { 0, 0, 0 } } end

    local hTest = vgui.Create("DButton", scroll)
    hTest:Dock(TOP) hTest:SetTall(26) hTest:DockMargin(0, 0, 0, 6)
    hTest:SetText("Test hand rotation (twist, flex, side - 4 s)")
    hTest.DoClick = function()
        if not enabled then start() end
        handTestUntil = CurTime() + 4.2
    end
    label("Hold each hand with the palm toward the camera and fingers up, press Calibrate, then move. Use the test to see which bone axis each movement drives and flip it if it goes the wrong way. The arm is not tracked: forearm twist from the Kinect adds on top.", 80, true)
end

concommand.Add("smh_finger_menu", openWindow)

local function register()
    if not (SMHToolsHub and SMHToolsHub.Register) then return false end
    SMHToolsHub.Register({
        id = "finger_tracking",
        name = "Finger Tracking",
        open = openWindow,
        close = function() if IsValid(frame) then frame:Close() end end,
        isOpen = function() return IsValid(frame) and frame:IsVisible() end,
        isActive = function() return enabled end,
        status = function() return status end,
    })
    return true
end
if not register() then
    hook.Add("InitPostEntity", "SMHFingerRegisterHub", register)
    timer.Simple(2, register)
end
