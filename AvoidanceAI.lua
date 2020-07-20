function widget:GetInfo()
    return {
        name         = "AvoidanceAI",
        desc         = "attempt to avoid getting into range of nasty things. Meant to be used with return fire state. Version 0,87",
        author       = "dyth68",
        date         = "2020",
        license      = "PD", -- should be compatible with Spring
        layer        = 11,
        enabled      = true
    }
end


local UPDATE_FRAME=4
local SneakyStack = {}
local GetGroundHeight = Spring.GetGroundHeight
local GetUnitMaxRange = Spring.GetUnitMaxRange
local GetUnitPosition = Spring.GetUnitPosition
local GetMyAllyTeamID = Spring.GetMyAllyTeamID
local GiveOrderToUnit = Spring.GiveOrderToUnit
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GetUnitAllyTeam = Spring.GetUnitAllyTeam
local GetUnitIsDead = Spring.GetUnitIsDead
local GetMyTeamID = Spring.GetMyTeamID
local GetUnitDefID = Spring.GetUnitDefID
local GetTeamUnits = Spring.GetTeamUnits
local GetUnitStates = Spring.GetUnitStates
local Echo = Spring.Echo
local Scythe_ID = UnitDefNames.cloakheavyraid.id
local Widow_ID = UnitDefNames.spiderantiheavy.id
local GetSpecState = Spring.GetSpectatingState
local CMD_UNIT_SET_TARGET = 34923
local CMD_UNIT_CANCEL_TARGET = 34924
local CMD_STOP = CMD.STOP
local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = 16 -- I should figure out where to get this
local sqrt = math.sqrt

local decloakRanges = {
    [Scythe_ID] = 75,
    [Widow_ID] = 60,
}
local decloakRangeGrace = 50


local SneakyController = {
    unitID,
    pos,
    allyTeamID = GetMyAllyTeamID(),
    unitDefID,


    new = function(self, unitID, unitDefID)
        Echo("SneakyController added:" .. unitID)
        self = deepcopy(self)
        self.unitID = unitID
        self.unitDefID = unitDefID
        self.pos = {GetUnitPosition(self.unitID)}
        return self
    end,

    unset = function(self)
        Echo("SneakyController removed:" .. self.unitID)
        GiveOrderToUnit(self.unitID,CMD_STOP, {}, {""},1)
        return nil
    end,

    isEnemyTooClose = function (self)
        local x,y,z = unpack(self.pos)
        local unitDefID = self.unitDefID
        local units = GetUnitsInCylinder(x, z, decloakRanges[unitDefID] + decloakRangeGrace)
        for i=1, #units do
            if not (GetUnitAllyTeam(units[i]) == self.allyTeamID) then
                local DefID = GetUnitDefID(units[i])
                if not(DefID == nil)then
                    local enemyPosition = {GetUnitPosition(units[i])}
                    local baseY = GetGroundHeight(x, z)
                    -- Don't get spooked by bombers or gunships, unless they're eg blastwings or gnats which really do fly that low, or if they are coming in to land nearby
                    if(enemyPosition[2]>-30 and enemyPosition[2] - baseY < 85)then
                        if (GetUnitIsDead(units[i]) == false) then
                            local enemyX, _, enemyZ = GetUnitPosition(units[i])
                            local dist = sqrt((x - enemyX) * (x - enemyX) + (z - enemyZ) * (z - enemyZ))
                            local awayX = x + (x - enemyX) * 50 / dist
                            local awayZ = z + (z - enemyZ) * 50 / dist
                            Echo("Scythe order given:" .. self.unitID .. "; from " .. x .. "," .. z .. " to " .. awayX .. "," .. awayZ)
                            Spring.GiveOrderToUnit(self.unitID,
                                CMD.INSERT,
                                {0,CMD_ATTACK_MOVE,CMD.OPT_SHIFT, awayX, y, awayZ},
                                {"alt"}
                            )
                            return true
                        end
                    end
                end
            end
        end
        return false
    end,

    handle = function(self)
        if not (GetUnitStates(self.unitID).movestate == 0 and Spring.GetUnitIsCloaked(self.unitID)) then return end
        local cmdQueue = Spring.GetUnitCommands(self.unitID, 2)
        if not (#cmdQueue == 0 or (#cmdQueue > 0 and cmdQueue[1].id == CMD_ATTACK_MOVE)) then return end
        self.pos = {GetUnitPosition(self.unitID)}
        self:isEnemyTooClose()
    end
}

function widget:UnitFinished(unitID, unitDefID, unitTeam)
        if decloakRanges[unitDefID] and unitTeam==GetMyTeamID() then
            SneakyStack[unitID] = SneakyController:new(unitID, unitDefID)
        end
end

function widget:UnitDestroyed(unitID)
    if not (SneakyStack[unitID]==nil) then
        SneakyStack[unitID]=SneakyStack[unitID]:unset()
    end
end

function widget:GameFrame(n)
    if (n%UPDATE_FRAME==0) then
        for _,Scythe in pairs(SneakyStack) do
            Scythe:handle()
        end
    end
end

function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- The rest of the code is there to disable the widget for spectators
local function DisableForSpec()
    if GetSpecState() then
        widgetHandler:RemoveWidget()
    end
end

function widget:Initialize()
    DisableForSpec()
    local units = GetTeamUnits(GetMyTeamID())
    for i=1, #units do
        local unitDefID = GetUnitDefID(units[i])
        if (decloakRanges[unitDefID])  then
            if  (SneakyStack[units[i]]==nil) then
                SneakyStack[units[i]]=SneakyController:new(units[i], unitDefID)
            end
        end
    end
end

function widget:PlayerChanged (playerID)
    DisableForSpec()
end
