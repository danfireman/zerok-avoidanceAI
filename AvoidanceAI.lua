function widget:GetInfo()
	return {
		name         = "AvoidanceAI",
		desc         = "attempt to avoid getting into range of nasty things. Meant to be used with return fire state. Version 0,87",
		author       = "dyth68,esainane",
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
local Gremlin_ID = UnitDefNames.cloakaa.id
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
	[Gremlin_ID] = 140,
}
local decloakRangeGrace = 50
-- Air tends to change height quite slowly, unless they are already very far up
local airDecloakRangeGrace = 7

local moveDist = 50
-- Check to see if the units we're surrounded by are cancelling each other out.
-- If our impulse ends up being less than this, don't move, just do our best.
local minMoveImpulse = 3/5
local minMoveImpulseSq = minMoveImpulse * minMoveImpulse

local SneakyControllerMT
local SneakyController = {
	allyTeamID = GetMyAllyTeamID(),

	new = function(index, unitID, unitDefID)
		-- Echo("SneakyController added:" .. unitID)
		local self = {}
		setmetatable(self, SneakyControllerMT)
		self.unitID = unitID
		self.unitDefID = unitDefID
		self.pos = {GetUnitPosition(unitID)}
		self.height = Spring.GetUnitHeight(unitID)
		self.aiEngaged = false
		return self
	end,

	unset = function(self)
		-- Echo("SneakyController removed:" .. self.unitID)
		GiveOrderToUnit(self.unitID,CMD_STOP, {}, {""},1)
		return nil
	end,

	checkOneEnemyUnitTooClose = function(self, x,y,z, unitID, unitDefID, enemyUnitID)
		if GetUnitAllyTeam(enemyUnitID) == self.allyTeamID then return false end
		local baseY = GetGroundHeight(x, z)
		local enemyX, enemyY, enemyZ = GetUnitPosition(enemyUnitID)
		if enemyY <= -30 then
			-- disregard underwater units
			return false
		end
		local enemyHeightAboveGround = enemyY - baseY
		-- Don't get spooked by bombers or gunships, unless they're eg blastwings or gnats which really do fly that low, or if they are coming in to land nearby
		-- We should be spooked by air if we have a large decloak area, though
		if enemyHeightAboveGround > decloakRanges[unitDefID] + airDecloakRangeGrace + self.height then
			self.db1 = self.db1 or WG.Debouncer:new(Echo, 30)
			if WG.Debug then WG.Debug.Marker(enemyX,enemyY,enemyZ,'Not dodging', enemyHeightAboveGround, 'is beyond our spookpoint of', decloakRanges[unitDefID] + airDecloakRangeGrace, 'note baseY', baseY, 'our y', y, 'our height', Spring.GetUnitHeight(unitID)) end
			return false
		end
		if GetUnitIsDead(enemyUnitID) then return false end
		local dist2Sq = (x - enemyX) * (x - enemyX) + (z - enemyZ) * (z - enemyZ)
		local dist3Sq = dist2Sq + (y - enemyY) * (y - enemyY)
		-- Give a really big impulse if they're getting close
		-- We give ourselves a little wiggle room with nominalRange since we're using 3D distance for urgency.
		-- If we didn't double the grace, urgency would be at 100% of normal impulse at maximum considered range.
		local nominalRange = decloakRanges[unitDefID] + decloakRangeGrace * 2
		local nominalRangeSq = nominalRange * nominalRange
		-- Impulse equivalent to slightly over 100% of normal impulse at maximum range (see above).
		-- Increases up to 300% as they get closer to being right on top of us
		-- Squared distance means that the increase to the increase is linear as they get closer.
		local urgency = (nominalRangeSq*3) / (dist3Sq+dist3Sq + nominalRangeSq)
		local dist = sqrt(dist2Sq)
		local impulseX = (x - enemyX) * urgency / dist
		local impulseZ = (z - enemyZ) * urgency / dist
		if WG.Debug then WG.Debug.Marker(enemyX,enemyY,enemyZ,'This enemy is spooky', dist, 'elmos away, treating with urgency', urgency * 100, '%, adding impulse', impulseX, impulseZ,'given squared nominal range of',nominalRangeSq,', or normal range of',nominalRange,'and squared 3d range of',dist3Sq,'or normal 3d range of',sqrt(dist3Sq)) end

		return true, impulseX, impulseZ
	end,

	isEnemyTooClose = function (self)
		local x,y,z = unpack(self.pos)
		local unitDefID = self.unitDefID
		local units = GetUnitsInCylinder(x, z, decloakRanges[unitDefID] + decloakRangeGrace)
		local unitID = self.unitID
		local impulseXSum, impulseZSum = 0, 0
		local haveImpulse = false
		for i=1, #units do
			local enemyUnitID = units[i]
			local doMove, impulseX, impulseZ = self:checkOneEnemyUnitTooClose(x,y,z, unitID, unitDefID, enemyUnitID)
			if doMove then
				impulseXSum, impulseZSum = impulseXSum + impulseX, impulseZSum + impulseZ
				haveImpulse = true
			end
		end
		if not haveImpulse then return false end
		local distSq = impulseXSum * impulseXSum + impulseZSum * impulseZSum
		-- If we're surrounded, don't do anything.
		if distSq < minMoveImpulseSq then
			if WG.Debug then WG.Debug.Marker(x,y,z, "I'm surrounded", distSq, "<", minMoveImpulseSq, "Giving up on dodging.") end
			return false
		end
		-- Regardless of our the urgency being fed in, always move the same distance away from our current position.
		local dist = sqrt(distSq)
		local awayX = x + impulseXSum * moveDist / dist
		local awayZ = z + impulseZSum * moveDist / dist
		--Echo("Sneaky order given:" .. self.unitID .. "; from " .. x .. "," .. z .. " to " .. awayX .. "," .. awayZ)
		Spring.GiveOrderToUnit(self.unitID,
			CMD.INSERT,
			{0,CMD_ATTACK_MOVE,CMD.OPT_SHIFT, awayX, y, awayZ},
			{"alt"}
		)
		return true
	end,

	handle = function(self)
		if not (GetUnitStates(self.unitID).movestate == 0 and Spring.GetUnitIsCloaked(self.unitID)) then return end
		local cmdQueue = Spring.GetUnitCommands(self.unitID, 2)
		if not (#cmdQueue == 0 or (cmdQueue[1].id == CMD_ATTACK_MOVE)) then return end
		self.pos = {GetUnitPosition(self.unitID)}
		self:isEnemyTooClose()
	end
}
SneakyControllerMT = {__index=SneakyController}

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
