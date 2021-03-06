dofile "$SURVIVAL_DATA/Scripts/game/survival_constants.lua"
dofile "$SURVIVAL_DATA/Scripts/game/survival_units.lua"
dofile "$CHALLENGE_DATA/Scripts/challenge/world_util.lua"

-- Server side
UnitManager = class( nil )

local PlayerDensityMaxIndex = 120
local PlayerDensityTickInterval = 4800 -- Save player position once every other minute

local CropAttackCellScanCooldownTime = 0.5 * 40
local CellScanCooldown = 15 * 40
local MinimumCropValueForRaid = 1000
local HighValueCrop = 3

local RaidWaveCooldown = DaysInTicks( 4.5 / 24 )
local RaidFinishedCooldown = DaysInTicks( 4.5 / 24 )

-- Sum of values determine raid level, values >= than HighValueCrop can summon tapebots and farmbots
local Crops = {
	[tostring(hvs_growing_banana)] = 2, [tostring(hvs_mature_banana)] = 2,
	[tostring(hvs_growing_blueberry)] = 2, [tostring(hvs_mature_blueberry)] = 2,
	[tostring(hvs_growing_orange)] = 2, [tostring(hvs_mature_orange)] = 2,
	[tostring(hvs_growing_pineapple)] = 3, [tostring(hvs_mature_pineapple)] = 3,
	[tostring(hvs_growing_carrot)] = 1, [tostring(hvs_mature_carrot)] = 1,
	[tostring(hvs_growing_redbeet)] = 1, [tostring(hvs_mature_redbeet)] = 1,
	[tostring(hvs_growing_tomato)] = 1, [tostring(hvs_mature_tomato)] = 1,
	[tostring(hvs_growing_broccoli)] = 3, [tostring(hvs_mature_broccoli)] = 3,
	[tostring(hvs_growing_potato)] = 1.5, [tostring(hvs_mature_potato)] = 1.5,
	[tostring(hvs_growing_cotton)] = 1.5, [tostring(hvs_mature_cotton)] = 1.5
}

local Raiders = {
	-- Raid level 1
	{
		{ [unit_totebot_green] = 3 },
		{ [unit_totebot_green] = 4 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 1 },
	},
	-- Raid level 2
	{
		{ [unit_totebot_green] = 4, [unit_haybot] = 1 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 2 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 3 },
	},
	-- Raid level 3
	{
		{ [unit_totebot_green] = 4, [unit_haybot] = 2 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 3 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 5 },
	},
	-- Raid level 4
	{
		{ [unit_totebot_green] = 4, [unit_haybot] = 3 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 5 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 7 },
	},
	-- Raid level 5
	{
		{ [unit_totebot_green] = 4, [unit_haybot] = 4 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 6 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 8 },
	},
	-- Raid level 6
	{
		{ [unit_totebot_green] = 4, [unit_haybot] = 6 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 8 },
		{ [unit_totebot_green] = 4, [unit_haybot] = 10 },
	},
	-- Raid level 7
	{
		{ [unit_totebot_green] = 3, [unit_haybot] = 6, [unit_tapebot] = 1 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 8, [unit_tapebot] = 1 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 10, [unit_tapebot] = 2 },
	},
	-- Raid level 8
	{
		{ [unit_totebot_green] = 3, [unit_haybot] = 6, [unit_tapebot] = 2 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 8, [unit_tapebot] = 2 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 10, [unit_tapebot] = 3 },
	},
	-- Raid level 9
	{
		{ [unit_totebot_green] = 3, [unit_haybot] = 6, [unit_tapebot] = 3 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 8, [unit_tapebot] = 3 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 10, [unit_tapebot] = 4, [unit_farmbot] = 1 },
	},
	-- Raid level 10
	{
		{ [unit_totebot_green] = 3, [unit_haybot] = 6, [unit_tapebot] = 4, [unit_farmbot] = 1 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 6, [unit_tapebot] = 4, [unit_farmbot] = 1 },
		{ [unit_totebot_green] = 3, [unit_haybot] = 6, [unit_tapebot] = 5, [unit_farmbot] = 3 },
	}
}

function UnitManager.sv_onCreate( self, overworld )
	self.sv = {}
	self.saved = sm.storage.load( STORAGE_CHANNEL_UNIT_MANAGER )

	if self.saved then
		print( "Loaded unit groups:" )
		print( self.saved )
	else
		self.saved = {}
		self.saved.unitGroups = {}
		self.saved.dailyUnitGroupId = 1
		self.saved.nextUnitGroupId = 2

		self.saved.deathMarkers = {}
		self.saved.deathMarkerNextIndex = 1

		self.saved.visitedCells = {}
		self:sv_save()
	end

	self.overworld = overworld

	self.playerDensityNextIndex = 1
	self.playerDensityPositions = {}
	self.playerDensityTicks = 0

	self.deathMarkerMaxIndex = 100
	self.dangerousInteractables = {}

	self.tempUnitRequests = {}

	self.sv.cropAttackCells = {}
	self.sv.cropAttackCellScanCooldown = Timer()
	self.sv.cropAttackCellScanCooldown:start( CropAttackCellScanCooldownTime )

	self.newPlayers = {}
end

function UnitManager.cl_onCreate( self, overworld )
	self.cl = {}
	self.cl.attacks = {}
end

function UnitManager.sv_initNewDay( self )
	self.saved.visitedCells = {}
	self:sv_generateDailyGroupId()
end

-- Game environment
function UnitManager.sv_onFixedUpdate( self )
	-- Grab player positions for later density calculations
	self.playerDensityTicks = self.playerDensityTicks + 1
	if self.playerDensityTicks >= PlayerDensityTickInterval then
		self.playerDensityTicks = 0
		local players = sm.player.getAllPlayers()
		for _, player in pairs( players ) do
			if player.character and player.character:getWorld() == self.overworld then
				self.playerDensityPositions[self.playerDensityNextIndex] = player.character.worldPosition
				self.playerDensityNextIndex = ( self.playerDensityNextIndex % ( PlayerDensityMaxIndex ) ) + 1
			end
		end
	end

	-- Spawn requested temporary units
	local remainingTempUnitRequests = {}
	for _, tempRequest in ipairs( self.tempUnitRequests ) do
		if tempRequest.requestTick < sm.game.getCurrentTick() then
			sm.event.sendToWorld( self.overworld, "sv_e_spawnTempUnitsOnCell", { x = tempRequest.x, y = tempRequest.y } )
		else
			remainingTempUnitRequests[#remainingTempUnitRequests+1] = tempRequest
		end
	end
	self.tempUnitRequests = remainingTempUnitRequests

	-- Spawn crop raiders
	for _, cropAttackCell in pairs( self.sv.cropAttackCells ) do
		-- Time to raid
		if cropAttackCell.loaded and cropAttackCell.saved.attackTick and sm.game.getCurrentTick() >= cropAttackCell.saved.attackTick then
			cropAttackCell.saved.attackTick = nil

			-- Spawn some raiders
			assert( Raiders[cropAttackCell.saved.level] and #Raiders[cropAttackCell.saved.level] > 0 )
			print( "Spawning raiders. Level:", cropAttackCell.saved.level, " wave:", cropAttackCell.saved.wave )
			sm.event.sendToWorld( self.overworld, "sv_e_spawnRaiders", { attackPos = cropAttackCell.saved.attackPos, raiders = Raiders[cropAttackCell.saved.level][cropAttackCell.saved.wave], wave = cropAttackCell.saved.wave } )

			if cropAttackCell.saved.wave >= #Raiders[cropAttackCell.saved.level] then
				print( "LAST RAID WAVE" )
				cropAttackCell.saved.attackPos = nil
				cropAttackCell.saved.level = nil
				cropAttackCell.saved.wave = nil	
				cropAttackCell.saved.reevaluationTick = sm.game.getCurrentTick() + RaidFinishedCooldown
			else
				cropAttackCell.saved.reevaluationTick = sm.game.getCurrentTick() + RaidWaveCooldown
			end

			sm.storage.save( { STORAGE_CHANNEL_CROP_ATTACK_CELLS, CellKey( cropAttackCell.x, cropAttackCell.y ) }, cropAttackCell.saved )
		end
	end
end

function UnitManager.sv_onPlayerJoined( self, player )
	print( "UnitManager: Player", player.id, "joined" )
	--Inform player of incoming raids
	self.newPlayers[#self.newPlayers + 1] = player
end

function UnitManager.sv_save( self )
	sm.storage.save( STORAGE_CHANNEL_UNIT_MANAGER, self.saved )
end

function UnitManager.sv_getPlayerDensity( self, position )
	if #self.playerDensityPositions > 0 then
		local rr = 128 * 128 --magic number based on two cells size as search radius

		-- Predict density for point
		local sum = 0
		for _, savedPosition in pairs( self.playerDensityPositions ) do
			local dd = ( position - savedPosition ):length2()
			if dd < rr then
				sum = sum + 1
			end
		end
		return sum / PlayerDensityMaxIndex
	end
	return 0
end

function UnitManager.sv_requestTempUnitsOnCell( self, x, y )
	local cellKey = CellKey( x, y )
	if not self.saved.visitedCells[cellKey] then
		self.saved.visitedCells[cellKey] = true
		self.tempUnitRequests[#self.tempUnitRequests+1] = { x = x, y = y, requestTick = sm.game.getCurrentTick() }
	end
end

function UnitManager.sv_getRandomUnits( self, amount, position )

	-- Can use the position to check for nearby deathMarkers and/or dangers and determine what bots to send

	-- Build chance table
	local unitWeights =
	{
		{ uuid = unit_haybot, chance = 0.8 },
		{ uuid = unit_totebot_green, chance = 0.2 },
		--{ uuid = unit_totebot_red, chance = 0.075 },
		--{ uuid = unit_totebot_blue, chance = 0.075 },
		--{ uuid = unit_totebot_yellow, chance = 0.075 },
		--{ uuid = unit_farmbot, chance = 0.05 },
	}

	local unitBin = {}
	for i = 1, #unitWeights do
		if i > 1 then
			unitBin[i] = unitBin[i-1] + unitWeights[i].chance
		else
			unitBin[i] = unitWeights[i].chance
		end
	end

	-- Select random units
	local selectedUnits = {}
	for i = 1, amount do
		local nextUnit = unit_haybot
		local num = math.random() * unitBin[#unitBin]
		print( "num:", num )
		for i = 1, #unitBin do
			if num <= unitBin[i] then
				nextUnit = unitWeights[i].uuid
				break
			end
		end
		selectedUnits[#selectedUnits+1] = nextUnit
	end

	return selectedUnits

end

function UnitManager.sv_onInteractableCreated( self, interactable )
	if( interactable.shape and ( interactable.shape.shapeUuid == obj_powertools_sawblade or interactable.shape.shapeUuid == obj_powertools_drill ) ) then
		addToArrayIfNotExists( self.dangerousInteractables, interactable )
	end
end

function UnitManager.sv_onInteractableDestroyed( self, interactable )
	removeFromArray( self.dangerousInteractables, function( value ) return value == interactable end )
end

function UnitManager.sv_addDeathMarker( self, position, reason )
	local deathMarker = { position = position, timeStamp = sm.game.getCurrentTick(), reason = reason  }
	self.saved.deathMarkers[self.saved.deathMarkerNextIndex] = deathMarker
	self.saved.deathMarkerNextIndex = ( self.saved.deathMarkerNextIndex % ( self.deathMarkerMaxIndex ) ) + 1
	self:sv_save()
end

function UnitManager.sv_getClosestDangers( self, position )

	local closestInteractable = nil
	local closestInteractableDistance = nil
	local validInteractables = {}
	for _, interactable in ipairs( self.dangerousInteractables ) do
		if sm.exists( interactable ) and interactable.shape then
			validInteractables[#validInteractables+1] = interactable
			if closestInteractableDistance then
				local distance = ( interactable.shape.worldPosition - position ):length2()
				if distance < closestInteractableDistance then
					closestInteractable = interactable
					closestInteractableDistance = distance
				end
			else
				closestInteractable = interactable
				closestInteractableDistance = ( interactable.shape.worldPosition - position ):length2()
			end
		end
	end
	self.dangerousInteractables = validInteractables

	local closestMarker = nil
	local closestMarkerDistance = nil
	for _, deathMarker in ipairs( self.saved.deathMarkers ) do
		if closestMarkerDistance then
			local distance = ( deathMarker.position - position ):length2()
			if distance < closestMarkerDistance then
				closestMarker = deathMarker
				closestMarkerDistance = distance
			end
		else
			closestMarker = deathMarker
			closestMarkerDistance = ( deathMarker.position - position ):length2()
		end
	end

	local closestShape = nil
	if closestInteractable then
		closestShape = closestInteractable.shape
	end
	return closestShape, closestMarker

end

-- Unit Groups --
function UnitManager.sv_generateNextGroupId( self )
	local nextGroupId = self.saved.nextUnitGroupId
	self.saved.nextUnitGroupId = self.saved.nextUnitGroupId + 1
	self:sv_save()
	return nextGroupId
end

function UnitManager.sv_generateDailyGroupId( self )
	self.saved.dailyUnitGroupId = self.saved.nextUnitGroupId
	self.saved.nextUnitGroupId = self.saved.nextUnitGroupId + 1
	self:sv_save()
	return self.saved.dailyUnitGroupId
end

function UnitManager.sv_getDailyGroupId( self )
	return self.saved.dailyUnitGroupId
end

function UnitManager.sv_addUnitToGroup( self, unit, groupId )
	if not self.saved.unitGroups[groupId] then
		self.saved.unitGroups[groupId] = {}
	end
	self.saved.unitGroups[groupId][#self.saved.unitGroups[groupId]+1] = unit
	self:sv_save()
end

function UnitManager.sv_getUnitGroup( self, groupId )
	if self.saved.unitGroups[groupId] then
		return self.saved.unitGroups[groupId]
	end
	return {}
end

-- World --

function UnitManager.sv_onWorldCellLoaded( self, worldSelf, x, y )
	if worldSelf.world == self.overworld then
		local key = CellKey( x, y )
		local cropAttackCell = { x = x, y = y, loaded = true, saved = {} }
		--assert( self.sv.cropAttackCells[key] == nil )
		self.sv.cropAttackCells[key] = cropAttackCell
		sm.storage.save( { STORAGE_CHANNEL_CROP_ATTACK_CELLS, key }, cropAttackCell.saved )
	end
end

function UnitManager.sv_onWorldCellReloaded( self, worldSelf, x, y )
	if worldSelf.world == self.overworld then
		local key = CellKey( x, y )
		local cropAttackCell = self.sv.cropAttackCells[key]
		if cropAttackCell then
			cropAttackCell.loaded = true
		else
			cropAttackCell = { x = x, y = y, loaded = true }
			self.sv.cropAttackCells[key] = cropAttackCell
		end
		cropAttackCell.saved = sm.storage.load( { STORAGE_CHANNEL_CROP_ATTACK_CELLS, key } )
		if cropAttackCell.saved == nil then
			cropAttackCell.saved = {}
		end
	end
end

function UnitManager.sv_onWorldCellUnloaded( self, worldSelf, x, y )
	if worldSelf.world == self.overworld then
		local key = CellKey( x, y )
		local cropAttackCell = self.sv.cropAttackCells[key]
		--assert( cropAttackCell ~= nil )
		if cropAttackCell ~= nil then
			cropAttackCell.loaded = false
		end
	end
end

function UnitManager.sv_onWorldFixedUpdate( self, worldSelf )
	--Inform player of incoming raids
	for _,player in ipairs( self.newPlayers ) do
		print( "Informing player", player.id, "about incoming raids." )
		for _, cropAttackCell in pairs( self.sv.cropAttackCells ) do
			if cropAttackCell.saved.attackTick then
				print( "Sending info about raid at ("..cropAttackCell.x..","..cropAttackCell.y..") to player", player.id )
				worldSelf.network:sendToClient( player, "cl_n_unitMsg", { fn = "cl_n_detected", tick = cropAttackCell.saved.attackTick, pos = cropAttackCell.saved.attackPos } )
			end
		end
	end
	self.newPlayers = {}


	if worldSelf.world == self.overworld and not self.disableRaids then
		self.sv.cropAttackCellScanCooldown:tick()
		if self.sv.cropAttackCellScanCooldown:done() then
			local evaluatedCells = {}

			-- Check for cells to scan
			local tick = sm.game.getCurrentTick()
			for _,cropAttackCell in pairs( self.sv.cropAttackCells ) do
				if cropAttackCell.loaded and not cropAttackCell.saved.attackTick
					and ( not cropAttackCell.saved.reevaluationTick or tick >= cropAttackCell.saved.reevaluationTick )
					and ( not cropAttackCell.scanTick or tick >= cropAttackCell.scanTick ) then

					cropAttackCell.saved.reevaluationTick = nil
					evaluatedCells[#evaluatedCells + 1] = cropAttackCell
				end
			end

			-- Scan a random cell for crops
			if #evaluatedCells > 0 then
				local cropAttackCell = evaluatedCells[math.random( #evaluatedCells )]
				cropAttackCell.scanTick = tick + CellScanCooldown

				--print( "UnitManager - scanning cell", cropAttackCell.x, cropAttackCell.y, "for crops" )

				local harvestables = sm.cell.getHarvestables( cropAttackCell.x, cropAttackCell.y, 0 ) --Find tiny harvestables in cell
				local cropCount = 0
				local cropValue = 0
				local avgPos = sm.vec3.zero()
				local highLevelCount = 0

				for _,harvestable in ipairs( harvestables ) do
					local crop = Crops[tostring(harvestable:getUuid())]
					if crop then
						cropCount = cropCount + 1
						cropValue = cropValue + crop
						avgPos = avgPos + harvestable:getPosition()
						if crop >= HighValueCrop then
							highLevelCount = highLevelCount + 1
						end
					end
				end
				
				if cropCount > 0 then
					avgPos = avgPos / cropCount
					--print( "Crop count:", cropCount, "(harvestables:"..#harvestables..")" )
					-- Calculate raid level based on what is growing

					--local playerDensity = g_unitManager:sv_getPlayerDensity( avgPos )
					--print( "player density:", playerDensity )
					print( "crop value:", cropValue )
					print( "avg crop value:", cropValue / cropCount )
					print( "high level crops:", highLevelCount )

					local level

					if highLevelCount >= 50 and cropValue >= 300 then
						level = 10
					elseif highLevelCount >= 20 and cropValue >= 150 then
						level = 9
					elseif highLevelCount >= 10 and cropValue >= 110 then
						level = 8
					elseif highLevelCount >= 5 and cropValue >= 80 then
						level = 7
					elseif cropValue >= 60 then
						level = 6
					elseif cropValue >= 50 then
						level = 5
					elseif cropValue >= 40 then
						level = 4
					elseif cropValue >= 30 then
						level = 3
					elseif cropValue >= 20 then
						level = 2
					else
						level = 1
					end


					local delay = getTicksUntilDayCycleFraction( 0 )

					if cropAttackCell.saved.wave then
						self:sv_beginRaidCountdown( worldSelf, avgPos, level, cropAttackCell.saved.wave + 1, delay )
					elseif cropValue >= MinimumCropValueForRaid then
						print( "FARMING DETECTED" )
						-- Crops detected in new cell
						-- Wait some time then check again
						cropAttackCell.saved.reevaluationTick = 40 * 30
						cropAttackCell.saved.wave = 0
					end
				else
					if cropAttackCell.saved.wave then
						print( "RAIDERS WON ABORT RAID" )
						cropAttackCell.saved.attackPos = nil
						cropAttackCell.saved.level = nil
						cropAttackCell.saved.wave = nil
						sm.storage.save( { STORAGE_CHANNEL_CROP_ATTACK_CELLS, CellKey( cropAttackCell.x, cropAttackCell.y ) }, cropAttackCell.saved )
					end
				end
			end

			self.sv.cropAttackCellScanCooldown:start( CropAttackCellScanCooldownTime )
		end
	end
end

function UnitManager.sv_beginRaidCountdown( self, worldSelf, position, level, wave, delay )

	local x = math.floor( position.x / 64 )
	local y = math.floor( position.y / 64 )
	local key = CellKey( x, y )
	local cropAttackCell = self.sv.cropAttackCells[key]
	assert( cropAttackCell ~= nil )

	print( "UNAUTHORIZED FARMING DETECTED! Level:", level, "wave:", wave )

	cropAttackCell.saved.attackTick = sm.game.getCurrentTick() + delay
	cropAttackCell.saved.attackPos = position
	cropAttackCell.saved.level = level
	cropAttackCell.saved.wave = wave

	sm.storage.save( { STORAGE_CHANNEL_CROP_ATTACK_CELLS, CellKey( cropAttackCell.x, cropAttackCell.y ) }, cropAttackCell.saved )

	worldSelf.network:sendToClients( "cl_n_unitMsg", {
		fn = "cl_n_detected",
		tick = cropAttackCell.saved.attackTick,
		pos = cropAttackCell.saved.attackPos,
		level = cropAttackCell.saved.level,
		wave = cropAttackCell.saved.wave,
	} )
end

function UnitManager.sv_cancelRaidCountdown( self, worldSelf )
	for _,cropAttackCell in pairs( self.sv.cropAttackCells ) do
		cropAttackCell.saved.attackTick = nil
		cropAttackCell.saved.attackPos = nil
		cropAttackCell.saved.level = nil
		cropAttackCell.saved.wave = nil
		cropAttackCell.saved.reevaluationTick = nil
		worldSelf.network:sendToClients( "cl_n_unitMsg", { fn = "cl_n_cancel" } )
	end
end

function UnitManager.cl_onWorldUpdate( self, worldSelf, deltaTime )
	removeFromArray( self.cl.attacks, function( attack )
		local timeLeft = ( attack.tick - sm.game.getServerTick() ) / 40
		attack.gui:setText( "Text", "#ff0000"..formatCountdown( timeLeft ) )
		if timeLeft < 0 then
			attack.gui:destroy()
			return true
		end
		return false
	end )
end

function UnitManager.cl_n_detected( self, msg )
	--if msg.wave == 1 then
		sm.gui.displayAlertText( "UNAUTHORIZED FARMING DETECTED!", 10 )
	--end

	local gui = sm.gui.createNameTagGui()
	gui:setWorldPosition( msg.pos + sm.vec3.new( 0, 0, 0.5 ) )
	gui:setRequireLineOfSight( false )
	gui:open()
	gui:setMaxRenderDistance( 500 )
	gui:setText( "Text", "#ff0000"..formatCountdown( ( msg.tick - sm.game.getServerTick() ) / 40 ) )

	self.cl.attacks[#self.cl.attacks + 1] = { gui = gui, tick = msg.tick }
end

-- function UnitManager.cl_n_waveMsg( self, msg )
-- 	sm.gui.displayAlertText( "[WAVE "..msg.wave.."]", 5 )
-- end

function UnitManager.cl_n_cancel( self, msg )
	for _,attack in ipairs( self.cl.attacks ) do
		attack.gui:destroy()
	end
	self.cl.attacks = {}
end
