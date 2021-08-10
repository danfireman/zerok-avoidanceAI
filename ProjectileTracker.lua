function widget:GetInfo()
   return {
      name         = "Projectile Tracker",
      desc         = "Tracks projectiles and tries to have Impalers fire back",
      author       = "dyth68",
      date         = "2020",
      license      = "PD", -- should be compatible with Spring
      layer        = 11,
      enabled      = true
   }
end


local UPDATE_FRAME=15
local ImpalerStack = {}
local ImpalersToStop = {}
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
local Impaler_NAME = "vehheavyarty"
local GetSpecState = Spring.GetSpectatingState
local CMD_UNIT_SET_TARGET = 34923
local CMD_UNIT_CANCEL_TARGET = 34924
local CMD_STOP = CMD.STOP
local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = 16 -- I should figure out where to get this
local BARREL_HEIGHT = 20 -- Likely height of barrel on unit
local TIME_TO_ERECT = 80
local EPSILON_TIME = 2
local MAX_TIME_TO_STOW = 290
local TIME_AFK_TO_START_STOW = 155
local sqrt = math.sqrt

local BARREL_POSITIONS = {tankheavyarty_plasma = {20, 0}, tankarty_core_artillery = {20, 0},  veharty_mine = {40, 17},  cloakarty_hammer_weapon = {37, 20},  staticarty_plasma = {25, 0}}

local trackedProjectiles = {}

-- I don't know how to import functions, so...
local function DistSq(x1,z1,x2,z2)
        return (x1 - x2)*(x1 - x2) + (z1 - z2)*(z1 - z2)
end

local ImpalerController = {
	unitID,
	pos,
	allyTeamID = GetMyAllyTeamID(),
	range,
	lastAttackCmdTime,
	lastRealAttackTime,
	lastUserActionTime,
	oldestTimeWithNoOrders,
	lastCommandPos,
	lastErectTime,
	
	
	new = function(self, unitID)
		Echo("ImpalerController added:" .. unitID)
		self = deepcopy(self)
		self.unitID = unitID
		self.lastAttackCmdTime = -1
		self.lastErectTime = -1
		self.lastRealAttackTime = -1
		self.lastCommandPos = {-1, -1, -1}
		self.range = GetUnitMaxRange(self.unitID)
		self.pos = {GetUnitPosition(self.unitID)}
		ImpalersToStop[self.unitID] = false
		return self
	end,

	unset = function(self)
		Echo("ImpalerController removed:" .. self.unitID)
		GiveOrderToUnit(self.unitID,CMD_STOP, {}, {""},1)
		return nil
	end,
	
	inRightState = function(self)
		local cmdQueue = Spring.GetUnitCommands(self.unitID, 2)
		local unitStateAppropriate = (GetUnitStates(self.unitID).firestate == 1) and (GetUnitStates(self.unitID).movestate == 0)
		return #cmdQueue == 0 and unitStateAppropriate
	end,
	
	giveFakeFireOrder = function(self)
    self.pos = {GetUnitPosition(self.unitID)}
    self.lastAttackCmdTime = Spring.GetGameFrame()
    self.lastCommandPos = {self.pos[1], self.pos[2], self.pos[3] + 30}
    Spring.GiveOrderToUnit(self.unitID, CMD.INSERT, {-1,CMD.ATTACK, CMD.OPT_SHIFT, self.pos[1], self.pos[2], self.pos[3] + 30}, {"alt"})
    ImpalersToStop[self.unitID] = true
	end,
	
	
	keepTubesHot = function(self)
    local cmdQueue = Spring.GetUnitCommands(self.unitID, 2)
    if #cmdQueue == 0 and not self.oldestTimeWithNoOrders then
      self.oldestTimeWithNoOrders = Spring.GetGameFrame()
    end
    if not self.oldestTimeWithNoOrders then
      return
    end
    
    if self.oldestTimeWithNoOrders + MAX_TIME_TO_STOW > Spring.GetGameFrame() then
      return
    end
    
    if self.lastRealAttackTime + TIME_TO_ERECT > Spring.GetGameFrame() then
      Echo("not keeping tubes hot because a real attack has been given")
      return
    end

    local timeTilReload = Spring.GetUnitWeaponState(self.unitID, 1, "reloadTime") + Spring.GetUnitWeaponState(self.unitID, 1, "reloadState") - Spring.GetGameFrame()
    
    if timeTilReload > 0 then
      if timeTilReload < TIME_TO_ERECT and Spring.GetGameFrame() - self.lastAttackCmdTime > TIME_TO_ERECT then
        Echo("Reload ending, time to get ready " .. tostring(Spring.GetGameFrame()))
        self:giveFakeFireOrder()
        self.lastErectTime = Spring.GetGameFrame() + TIME_TO_ERECT
      end
      return
    end
    
    if self.oldestTimeWithNoOrders + MAX_TIME_TO_STOW + EPSILON_TIME > Spring.GetGameFrame() and Spring.GetGameFrame() - self.lastAttackCmdTime > TIME_TO_ERECT then
      Echo("initial elevation after player stopped messing about " .. tostring(Spring.GetGameFrame()))
      self:giveFakeFireOrder()
      self.lastErectTime = Spring.GetGameFrame() + TIME_TO_ERECT
      return
    end
    
    if self.lastErectTime + TIME_AFK_TO_START_STOW + EPSILON_TIME < Spring.GetGameFrame() and Spring.GetGameFrame() - self.lastAttackCmdTime > TIME_TO_ERECT then
      Echo("giving keep-alive order " .. tostring(Spring.GetGameFrame()))
      self:giveFakeFireOrder()
      self.lastErectTime = Spring.GetGameFrame()
      return
    end
	end,
	
	handle=function(self, enemyPos)
		if self:inRightState() then
			self.pos = {GetUnitPosition(self.unitID)}
			Echo("Impaler active!")
			local canFire = Spring.GetUnitWeaponState(self.unitID, 1, "reloadTime") + Spring.GetUnitWeaponState(self.unitID, 1, "reloadState") < Spring.GetGameFrame()
			if (DistSq(self.pos[1], self.pos[3], enemyPos[1], enemyPos[3]) < self.range * self.range) and canFire then
        self.lastCommandPos = {enemyPos[1], enemyPos[2], enemyPos[3]}
        self.lastAttackCmdTime = Spring.GetGameFrame()
        self.lastRealAttackTime = Spring.GetGameFrame()
        Spring.GiveOrderToUnit(self.unitID, CMD.INSERT, {-1,CMD.ATTACK, CMD.OPT_SHIFT,enemyPos[1], enemyPos[2], enemyPos[3]}, {"alt"})
        ImpalersToStop[self.unitID] = true
        return true
			end
		end
		return false
	end
}

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
  for impalerId,Impaler in pairs(ImpalerStack) do 
    if unitID == impalerId then
      local commandPos = {cmdParams[#cmdParams - 2], cmdParams[#cmdParams - 1], cmdParams[#cmdParams]}
      Echo("Checking for user action")
      local cmdQueue = Spring.GetUnitCommands(unitID, 2)
      if cmdID == CMD.STOP or (#cmdQueue < 2 and Impaler.lastCommandPos[1] == commandPos[1] and Impaler.lastCommandPos[3] == commandPos[3]) then
        if not Impaler.oldestTimeWithNoOrders then
          Impaler.oldestTimeWithNoOrders = Spring.GetGameFrame()
        end
      else
        Impaler.oldestTimeWithNoOrders = nil
        Impaler.lastUserActionTime = Spring.GetGameFrame()
        Echo("User action!")
        Echo(Impaler.lastUserActionTime)
      end
    end
  end
end

function tryToImpale(enemyPos) 
  for _,Impaler in pairs(ImpalerStack) do 
    local handled = Impaler:handle(enemyPos)
    if handled then
      return
    end
  end
end

function keepImpalersHot()
  for _,Impaler in pairs(ImpalerStack) do 
    Impaler:keepTubesHot()
  end
end

function printThing(theKey, theTable, indent)
	if (type(theTable) == "table") then
		Echo(indent .. theKey .. ":")
		for a, b in pairs(theTable) do
			printThing(tostring(a), b, indent .. "  ")
		end
	else
		Echo(indent .. theKey .. ": " .. tostring(theTable))
	end
end

local markers = {}
function addMarker(x,y,z)
	Spring.MarkerAddPoint(x,y,z, "", true)
	markers[tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)] = {time=Spring.GetGameFrame(), x=x, y=y, z=z}
end

function removeOldProjectiles()
	toremove = {}
  for k, data in pairs(markers) do
		if data["time"] + 30*15 < Spring.GetGameFrame() then
			Spring.MarkerErasePosition(data["x"],data["y"],data["z"])
			toremove[k] = data
		end
  end
  for k, data in pairs(toremove) do
		markers[k] = nil
  end
end

function widget:GameFrame(n)
  for impalerId, exists in pairs(ImpalersToStop) do
    Spring.GiveOrderToUnit(impalerId,CMD.STOP, {}, {""},1)
  end
  ImpalersToStop = {}
  keepImpalersHot()
	if (n%UPDATE_FRAME==0) then
		removeOldProjectiles()
    local projectiles = Spring.GetVisibleProjectiles()
		if (#projectiles > 0) then
      for bulletNum=1,#projectiles do
        local bulletId = projectiles[bulletNum]
				if not (Spring.GetProjectileTeamID(bulletId) == Spring.GetLocalTeamID()) then
					if not trackedProjectiles[bulletId] then
						local pos = {Spring.GetProjectilePosition(bulletId)}
						if #pos == 0 then
							--Echo(Spring.GetProjectileVelocity(bulletId))
							--Echo("no pos!")
						else
							local bulletName = Spring.GetProjectileName(bulletId)
							if BARREL_POSITIONS[bulletName] then
								local currentPos = pos
								local velocity = {Spring.GetProjectileVelocity(bulletId)}
								local currentV = velocity
								for i=1,3 do
									--Echo(currentPos)
									local gHeight = Spring.GetGroundHeight(currentPos[1], currentPos[3]) + BARREL_POSITIONS[bulletName][1]
									local heightDiff = currentPos[2] - gHeight
									local gravity = Spring.GetProjectileGravity(bulletId)
									-- initvelocity*t + gravity *t*t / 2 = heightDiff
									-- velocity = initvelocity + gravity*t
									-- initvelocity =  velocity - gravity*t
									-- gravity *t*t / 2 - velocity*t + heightDiff = 0
									-- t = (velocity +- sqrt(velocity * velocity - 2 * heightDiff * gravity)) /gravity
									local time = (currentV[2] - sqrt(currentV[2] * currentV[2] - 2 * heightDiff * gravity)) /gravity
									if time == time then
										currentPos = {currentPos[1] - currentV[1]*time, gHeight, currentPos[3] - currentV[3]*time}
										currentV = {currentV[1], currentV[2] - time * gravity, currentV[3]}
									end
								end
								local vMag = sqrt(velocity[1]*velocity[1] + velocity[3]*velocity[3])
								local normalV = {0 - velocity[3] * BARREL_POSITIONS[bulletName][2]/vMag, 0, velocity[1] * BARREL_POSITIONS[bulletName][2]/vMag}
								local enemyPos = {currentPos[1] + normalV[1], currentPos[2], currentPos[3] + normalV[3]}
					--Echo(bulletId)
					--Echo(Spring.GetProjectileName(bulletId))
					--Echo(Spring.GetProjectileTimeToLive (bulletId))
								tryToImpale(enemyPos)
								if not Spring.IsPosInLos(currentPos[1], currentPos[2], currentPos[3], Spring.GetMyAllyTeamID()) then
									addMarker(enemyPos[1], enemyPos[2], enemyPos[3])
								end
								trackedProjectiles[bulletId] = true
							end
						end
					end
				end
      end
    end
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
		if (UnitDefs[unitDefID].name==Impaler_NAME)
		and (unitTeam==GetMyTeamID()) then
			ImpalerStack[unitID] = ImpalerController:new(unitID);
		end
end

function widget:UnitDestroyed(unitID) 
	if not (ImpalerStack[unitID]==nil) then
		ImpalerStack[unitID]=ImpalerStack[unitID]:unset();
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
		DefID = GetUnitDefID(units[i])
		if (UnitDefs[DefID].name==Impaler_NAME or UnitDefs[DefID].name==Widow_NAME)  then
			if  (ImpalerStack[units[i]]==nil) then
				ImpalerStack[units[i]]=ImpalerController:new(units[i])
			end
		end
	end
end


function widget:PlayerChanged (playerID)
	DisableForSpec()
end
