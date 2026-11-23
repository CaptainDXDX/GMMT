-- GMMT skeleton export (client)
-- Install: addons/<your_addon>/lua/autorun/client/gmmt_skeleton_export.lua
--
-- While the GMMT "Skeleton" tab is open, this writes the Kinect's 20 joints to
-- garrysmod/data/gmmt_kinect_skeleton.txt a few times a second so GMMT can draw them.
-- It only runs while GMMT keeps garrysmod/data/gmmt_skeleton_request.txt fresh,
-- so it costs nothing the rest of the time.
if SERVER then return end

local REQUEST = "gmmt_skeleton_request.txt"
local OUTPUT = "gmmt_kinect_skeleton.txt"
local RATE = 1 / 15

local wanted, nextCheck, nextWrite = false, 0, 0

hook.Add("Think", "GMMTSkeletonExport", function()
    local now = RealTime()
    if now >= nextCheck then
        nextCheck = now + 0.5
        wanted = false
        if file.Exists(REQUEST, "DATA") then
            local stamp = tonumber(file.Read(REQUEST, "DATA") or "") or 0
            -- GMMT rewrites the stamp every second; ignore a stale file left by a crash
            wanted = math.abs(os.time() - stamp) < 6
        end
    end
    if not wanted or now < nextWrite then return end
    nextWrite = now + RATE

    local ply = LocalPlayer()
    if not IsValid(ply) or not ply.MotionSensorPos then return end
    local joints, seen = {}, 0
    for i = 0, 19 do
        local v = ply:MotionSensorPos(i)
        if v and (math.abs(v.x) > 0.05 or math.abs(v.y) > 0.05) then seen = seen + 1 end
        joints[#joints + 1] = v and { math.Round(v.x, 4), math.Round(v.y, 4), math.Round(v.z, 4) } or { 0, 0, 0 }
    end
    file.Write(OUTPUT, util.TableToJSON({ t = os.time(), tracking = seen > 14, joints = joints }))
end)
