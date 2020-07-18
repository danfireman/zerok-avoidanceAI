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
local ScytheStack = {}
local GetUnitMaxRange = Spring.GetUnitMaxRange
local GetUnitPosition = Spring.GetUnitPosition
local GetMyAllyTeamID = Spring.GetMyAllyTeamID
local GiveOrderToUnit = Spring.GiveOrderToUnit
local GetGroundHeight = Spring.GetGroundHeight
local GetUnitsInSphere = Spring.GetUnitsInSphere
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GetUnitAllyTeam = Spring.GetUnitAllyTeam
local GetUnitNearestEnemy = Spring.GetUnitNearestEnemy
local GetUnitIsDead = Spring.GetUnitIsDead
local GetMyTeamID = Spring.GetMyTeamID
local GetUnitDefID = Spring.GetUnitDefID
local GetTeamUnits = Spring.GetTeamUnits
local GetUnitArmored = Spring.GetUnitArmored
local GetUnitStates = Spring.GetUnitStates
local ENEMY_DETECT_BUFFER  = 40
local Echo = Spring.Echo
local Phantom_NAME = "cloaksnipe"
local Scythe_NAME = "cloakheavyraid"
local Widow_NAME = "spiderantiheavy"
local Razor_NAME = "turretaalaser"
local Halbert_NAME = "hoverassault"
local Gauss_NAME = "turretgauss"
local Faraday_NAME = "turretemp"
local GetSpecState = Spring.GetSpectatingState
local CMD_UNIT_SET_TARGET = 34923
local CMD_UNIT_CANCEL_TARGET = 34924
local CMD_STOP = CMD.STOP
local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = 16 -- I should figure out where to get this
local sqrt = math.sqrt




local ScytheController = {
    unitID,
    pos,
    allyTeamID = GetMyAllyTeamID(),
    range,
    forceTarget,


    new = function(self, unitID)
        Echo("ScytheController added:" .. unitID)
        self = deepcopy(self)
        self.unitID = unitID
        self.range = GetUnitMaxRange(self.unitID)
        self.pos = {GetUnitPosition(self.unitID)}
        return self
    end,

    unset = function(self)
        Echo("ScytheController removed:" .. self.unitID)
        GiveOrderToUnit(self.unitID,CMD_STOP, {}, {""},1)
        return nil
    end,

    setForceTarget = function(self, param)
        self.forceTarget = param[1]
    end,


    isEnemyTooClose = function (self)
        local units = GetUnitsInCylinder(self.pos[1], self.pos[3], 75 + 50)
        for i=1, #units do
            if not (GetUnitAllyTeam(units[i]) == self.allyTeamID) then
                local DefID = GetUnitDefID(units[i])
                if not(DefID == nil)then
                    local enemyPosition = {GetUnitPosition(units[i])}
                    if(enemyPosition[2]>-30)then
                        if (GetUnitIsDead(units[i]) == false) then
                            local enemyX, _, enemyY = GetUnitPosition(units[i]);
                            local dist = sqrt((self.pos[1] - enemyX) * (self.pos[1] - enemyX) + (self.pos[3] - enemyY) * (self.pos[3] - enemyY));
                            enemyX = self.pos[1] + (self.pos[1] - enemyX) * 50 / dist;
                            enemyY = self.pos[3] + (self.pos[3] - enemyY) * 50 / dist;
                            Echo("Scythe order give:" .. self.unitID .. "; from " .. self.pos[1] .. "," .. self.pos[3] .. " to " .. enemyX .. "," .. enemyY);
                            Spring.GiveOrderToUnit(self.unitID,
                                CMD.INSERT,
                                {0,CMD_ATTACK_MOVE,CMD.OPT_SHIFT, enemyX, self.pos[2], enemyY},
                                {"alt"}
                            );
                            return true
                        end
                    end
                end
            end
        end
        return false
    end,

    handle=function(self)
        local cmdQueue = Spring.GetUnitCommands(self.unitID, 2);
        local unitStateAppropriate = GetUnitStates(self.unitID).movestate == 0 and Spring.GetUnitIsCloaked(self.unitID);
        if ((#cmdQueue == 0 or (#cmdQueue > 0 and cmdQueue[1].id == CMD_ATTACK_MOVE)) and unitStateAppropriate) then
            self.pos = {GetUnitPosition(self.unitID)}
            self:isEnemyTooClose()
        end
    end
}

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
    if (UnitDefs[unitDefID].name == Scythe_NAME and cmdID == CMD_ATTACK  and #cmdParams == 1) then
        if (ScytheStack[unitID])then
            ScytheStack[unitID]:setForceTarget(cmdParams)
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
        if (UnitDefs[unitDefID].name==Scythe_NAME or UnitDefs[unitDefID].name==Widow_NAME)
        and (unitTeam==GetMyTeamID()) then
            ScytheStack[unitID] = ScytheController:new(unitID);
        end
end

function widget:UnitDestroyed(unitID)
    if not (ScytheStack[unitID]==nil) then
        ScytheStack[unitID]=ScytheStack[unitID]:unset();
    end
end

function widget:GameFrame(n)
    if (n%UPDATE_FRAME==0) then
        for _,Scythe in pairs(ScytheStack) do
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
    local units = GetTeamUnits(Spring.GetMyTeamID())
    for i=1, #units do
        local DefID = GetUnitDefID(units[i])
        if (UnitDefs[DefID].name==Scythe_NAME or UnitDefs[DefID].name==Widow_NAME)  then
            if  (ScytheStack[units[i]]==nil) then
                ScytheStack[units[i]]=ScytheController:new(units[i])
            end
        end
    end
end


function widget:PlayerChanged (playerID)
    DisableForSpec()
end
