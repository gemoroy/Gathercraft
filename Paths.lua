local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Paths (v0.1.22, part W): where you can ride, learned from where you ride.
--   Collected only - nothing uses it yet, nothing is sent, nothing leaves
--   this computer. Later a route can go around a cliff instead of through it.
--
--   A zone is cut into squares of 25 yards. Whenever you cross from one
--   square into a neighbour, that crossing ("path piece", an edge from ->
--   to) is counted with
--     - how often,
--     - its cost: the way you made inside the square you left (time x your
--       speed) divided by the straight line between the two squares'
--       centres. 1 = straight through; more = a detour, a slope you fought,
--       a wall you ran along. Speed x time makes walking, riding and every
--       level the same,
--     - how often you fell on it (in the air for a second or more - a jump
--       is shorter; such a piece may only go downwards),
--     - how often you swam on it,
--     - the day you last used it (the day only, never a time).
--   No trace is kept: not the order of the squares, no times, no names.
--
--   The client tells no height (UnitPosition gives 0; Sven's probe of
--   12.11.2026), so there is none here.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local TILE = 25           -- yards: the side of a square (W1)
local TICK = 0.5          -- seconds between two looks (W5: never more than two a second)
local GRID = 1024         -- squares per row in a key (a zone up to 25,600 yards wide)
local COUNT_MAX = 255     -- counts stop here (8 bits)
local COST_MAX = 1023     -- cost in hundredths stops here (10 bits: 10.23)
local MIN_WAY = 0.5       -- a crossing counts when you made at least this share of the straight line yourself
local FALL_SECONDS = 1.0  -- in the air this long without a break: a fall (a jump takes about 0.8 s)
local GAP_MAX = 2         -- seconds between two looks: longer was a hitch or a loading screen
local DAY0 = 20454        -- the day 2026-01-01, counted from 1970: days are kept from here (14 bits)

local floor, min, max = math.floor, math.min, math.max
local SQRT2 = math.sqrt(2)

-- the eight neighbours: (dy + 1) * 3 + (dx + 1), 4 is the square itself
local function Dir(dx, dy) return (dy + 1) * 3 + (dx + 1) end

---------------------------------------------------------------------------
-- The saved data: ns.db.paths = {
--     off = true            only when turned off (on by default)
--     total = n             path pieces in all zones
--     zones = { [mapID] = { n = pieces, e = { [key] = value } } }
-- }
--   key   = (ty * GRID + tx) * 9 + direction    the square you left and where to
--   value = (((swims * 256 + falls) * 1024 + cost) * 256 + count) * 16384 + day
--           (what is mostly 0 sits on top: the number stays short in the file)
---------------------------------------------------------------------------
local function DB()
    local db = ns.db
    if not db then return end
    local p = db.paths
    if type(p) ~= "table" then
        p = {}
        db.paths = p
    end
    if type(p.zones) ~= "table" then p.zones, p.total = {}, 0 end
    if type(p.total) ~= "number" then p.total = 0 end
    return p
end

local function Pack(count, cost, falls, swims, day)
    return (((swims * 256 + falls) * 1024 + cost) * 256 + count) * 16384 + day
end

local function Unpack(v)
    local day = v % 16384
    v = (v - day) / 16384
    local count = v % 256
    v = (v - count) / 256
    local cost = v % 1024
    v = (v - cost) / 1024
    local falls = v % 256
    return count, cost, falls, (v - falls) / 256, day
end

local function Today()
    return max(0, min(16383, floor(time() / 86400) - DAY0))
end

-- One crossing: from square (tx, ty) of the zone into its neighbour (dx, dy)
local function Record(p, mapID, tx, ty, dx, dy, cost, fell, swam)
    local z = p.zones[mapID]
    if not z then
        z = { n = 0, e = {} }
        p.zones[mapID] = z
    end
    local key = (ty * GRID + tx) * 9 + Dir(dx, dy)
    local hundredths = max(100, min(COST_MAX, floor(cost * 100 + 0.5)))
    local v = z.e[key]
    if v then
        local count, mean, falls, swims = Unpack(v)
        if count < COUNT_MAX then
            count = count + 1
            if fell then falls = falls + 1 end
            if swam then swims = swims + 1 end
        end
        -- (at the top of the count the mean follows new crossings slowly, and the shares stay)
        mean = floor(mean + (hundredths - mean) / count + 0.5)
        z.e[key] = Pack(count, max(100, min(COST_MAX, mean)), falls, swims, Today())
        return
    end
    z.e[key] = Pack(1, hundredths, fell and 1 or 0, swam and 1 or 0, Today())
    z.n = z.n + 1
    p.total = p.total + 1
end

---------------------------------------------------------------------------
-- Looking: twice a second, a fixed handful of calls each time (W5)
---------------------------------------------------------------------------
local here = {} -- the square you are in: map, tx, ty, way (yards made in it), air, fell, swam, at

local function Forget()
    here.map = nil
end

local function ZoneSize(mapID)
    if not (HBD and HBD.GetZoneSize) then return end
    local w, h = HBD:GetZoneSize(mapID)
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then return w, h end
end

-- Not on your own feet or not in the open world: nothing is learned (W3)
local function Elsewhere()
    if IsInInstance and IsInInstance() then return true end
    if UnitOnTaxi and UnitOnTaxi("player") then return true end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return true end
    if UnitInVehicle and UnitInVehicle("player") then return true end
    if IsFlying and IsFlying() then return true end
    return false
end

local function Look()
    local p = DB()
    if not p or p.off then return end
    local now = GetTime()
    local last = here.at
    local dt = last and (now - last) or 0
    here.at = now
    if not last then here.map = nil end -- (the first look: a start, nothing to measure yet)
    if (last and (dt <= 0 or dt > GAP_MAX)) or Elsewhere() then return Forget() end
    local speed = GetUnitSpeed and GetUnitSpeed("player")
    local falling = IsFalling and IsFalling()
    local swimming = IsSwimming and IsSwimming()
    if ns.AnySecret("paths", speed, falling, swimming) or type(speed) ~= "number" then return Forget() end
    local mapID, x, y = ns.GetPlayerPos()
    if not mapID or not x or not y then return Forget() end
    local w, h = ZoneSize(mapID)
    if not w then return Forget() end
    local tx, ty = floor(x * w / TILE), floor(y * h / TILE)
    if tx < 0 or ty < 0 or tx >= GRID or ty >= GRID then return Forget() end

    if here.map ~= mapID then
        -- a new start (login, another zone, after anything that was skipped)
        here.map, here.tx, here.ty, here.way, here.air, here.fell, here.swam = mapID, tx, ty, 0, 0, false, false
        return
    end
    if speed > 0 then here.way = here.way + speed * dt end
    if falling == true then
        here.air = here.air + dt
        if here.air >= FALL_SECONDS then here.fell = true end
    else
        here.air = 0
    end
    if swimming == true then here.swam = true end

    local dx, dy = tx - here.tx, ty - here.ty
    if dx == 0 and dy == 0 then return end
    if dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1 then
        local line = TILE * ((dx ~= 0 and dy ~= 0) and SQRT2 or 1)
        -- carried across (a boat, a lift, a knock-back) is no way of yours
        if here.way >= line * MIN_WAY then
            Record(p, mapID, here.tx, here.ty, dx, dy, here.way / line, here.fell, here.swam)
        end
    end
    -- (further than a neighbour in one look: a teleport or a hitch - no piece, a new start here)
    here.tx, here.ty, here.way, here.fell, here.swam = tx, ty, 0, here.air >= FALL_SECONDS, false
end

---------------------------------------------------------------------------
-- On and off
---------------------------------------------------------------------------
local ticker

local function Enabled()
    local p = DB()
    return p ~= nil and not p.off
end

local function StartStop()
    if Enabled() then
        if not ticker then
            Forget()
            here.at = nil -- (the time it was off is no hitch)
            ticker = C_Timer.NewTicker(TICK, Look)
        end
    elseif ticker then
        ticker:Cancel()
        ticker = nil
        Forget()
    end
end

local function SetEnabled(on)
    local p = DB()
    if not p then return end
    p.off = (not on) or nil
    StartStop()
end

local function Count()
    local p = DB()
    local zones = 0
    if p then for _ in pairs(p.zones) do zones = zones + 1 end end
    return p and p.total or 0, zones
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local p = DB()
        if not p then return end
        StartStop()
    else
        -- a loading screen: whatever square you were in, the next look starts anew
        Forget()
    end
end)

ns.PathsLook = Look
ns.PathsEnabled = Enabled
ns.PathsSetEnabled = SetEnabled
ns.PathsCount = Count
-- What is known about the crossing from square (tx, ty) into its neighbour
-- (dx, dy): count, cost (1 = straight), falls, swims, days since 2026-01-01
ns.PathsPiece = function(mapID, tx, ty, dx, dy)
    local p = DB()
    local z = p and p.zones[mapID]
    local v = z and z.e[(ty * GRID + tx) * 9 + Dir(dx, dy)]
    if not v then return end
    local count, cost, falls, swims, day = Unpack(v)
    return count, cost / 100, falls, swims, day
end
-- The square of a place in a zone (map coordinates 0-1), nil where the zone has no size
ns.PathsSquare = function(mapID, x, y)
    local w, h = ZoneSize(mapID)
    if not w then return end
    return floor(x * w / TILE), floor(y * h / TILE)
end
