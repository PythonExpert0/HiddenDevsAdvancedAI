-- Services
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- remote event so the GUI reset button can talk to the server
local resetRemote = Instance.new("RemoteEvent")
resetRemote.Name = "ResetNPC"
resetRemote.Parent = ReplicatedStorage

-- Configuration
local CONFIG = {
	DetectionRadius = 40, -- how far the npc can detect a player
	AttackRadius = 5,
	AttackCooldown = 1.5,
	AttackDamage = 15,
	WanderRadius = 20,
	WanderInterval = 4,
	FleeHealthThreshold = 30,
	PatrolPoints = {},
	MoveSpeed = 16, -- humanoid walkspeed
	PathUpdateRate = 0.5, -- how often path recalculates in seconds
}

-- Behavior Tree Node Types
local NodeResult = { -- enum style table for readable return values
	SUCCESS = "SUCCESS",
	FAILURE = "FAILURE",
	RUNNING = "RUNNING",
}

-- NPC Class
local NPC = {} -- uses metatables for OOP
NPC.__index = NPC -- redirect index lookups to the NPC table standard OOP pattern

function NPC.new(model) -- constructor takes the NPC Model from Workspace
	local self = setmetatable({}, NPC) -- create a new table and attach NPC as its metatable

	self.Model = model -- reference to the model
	self.Humanoid = model:FindFirstChildOfClass("Humanoid") -- grab the Humanoid component
	self.Root = model:FindFirstChild("HumanoidRootPart") -- grab the root part for position math
	self.SpawnPosition = self.Root.Position -- remember where the NPC started
	self.Target = nil
	self.LastAttackTime = 0
	self.LastWanderTime = 0
	self.WanderTarget = nil
	self.PatrolIndex = 1
	self.IsAlerted = false

	self.Waypoints = {} -- current computed waypoint list
	self.WaypointIndex = 1 -- which waypoint we are currently walking toward
	self.LastPathTime = 0 -- timestamp of last path compute used to throttle recomputes
	self.PathComputeInProgress = false -- guard prevents two ComputeAsync calls running at once

	-- create the StringValue the GUI reads to show current state
	local sv = Instance.new("StringValue")
	sv.Name = "AIState"
	sv.Value = "Idle"
	sv.Parent = self.Model

	self.StateValue = sv -- keep a reference so Tick can update it directly

	self.Humanoid.WalkSpeed = CONFIG.MoveSpeed -- apply configured speed
	self.Humanoid.AutoRotate = true -- let roblox handle turning so we dont fight the physics solver

	self.Humanoid.HealthChanged:Connect(function(newHealth)
		self:OnHealthChanged(newHealth) -- delegate to method below
	end)

	return self -- return the instance
end

function NPC:GetHealthPercent()
	return self.Humanoid.Health / self.Humanoid.MaxHealth -- returns health as a 0 to 1 fraction
end

function NPC:DistanceTo(position)
	return (self.Root.Position - position).Magnitude -- returns studs between NPC root and a Vector3
end

function NPC:LookAt(position)
	local direction = (position - self.Root.Position) * Vector3.new(1, 0, 1) -- set Y 0 so NPC doesnt tilt up or down
	if direction.Magnitude > 0.01 then -- avoid normalising a zero vector
		self.Root.CFrame = CFrame.new(self.Root.Position, self.Root.Position + direction) -- point face toward target
	end
end

function NPC:OnHealthChanged(newHealth)
	if newHealth <= 0 then
		self:Cleanup() -- destroy path and disconnect when dead
	end
end

function NPC:Cleanup() -- called on death removes connections and path
	self.Waypoints = {}
	self.WaypointIndex = 1
	if self.StateValue then
		self.StateValue.Value = "Dead" -- update GUI to show dead state
	end
	self.Humanoid:UnequipTools() -- drop any held tools
end

function NPC:ComputePath(targetPos) -- calculates a new path toward a position
	if self.PathComputeInProgress then return end -- block reentry so two computes dont run at the same time
	if self.Humanoid.Health <= 0 then return end

	local now = tick()
	if now - self.LastPathTime < CONFIG.PathUpdateRate then return end -- throttle so we dont recompute every tick
	self.LastPathTime = now

	self.PathComputeInProgress = true

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 7,
		AgentMaxSlope = 45,
	})

	local success = pcall(function()
		path:ComputeAsync(self.Root.Position, targetPos) -- compute from current pos to target
	end)

	if success and path.Status == Enum.PathStatus.Success then
		self.Waypoints = path:GetWaypoints() -- store the full waypoint list
		self.WaypointIndex = 2 -- skip index 1 since its the NPCs current position
		self:FollowPath() -- immediately issue the first MoveTo so there is no delay
	else
		self.Waypoints = {}
		self.Humanoid:MoveTo(targetPos) -- fallback to direct move if pathfinding fails
	end

	self.PathComputeInProgress = false
end

function NPC:FollowPath() -- issues MoveTo for the current waypoint in the list
	if #self.Waypoints == 0 then return end
	if self.WaypointIndex > #self.Waypoints then return end

	local waypoint = self.Waypoints[self.WaypointIndex]

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		self.Humanoid.Jump = true -- trigger jump before issuing MoveTo so the jump fires at the right spot
	end

	self.Humanoid:MoveTo(waypoint.Position) -- non blocking move toward the current waypoint
end

function NPC:AdvanceWaypoints() -- checks distance to current waypoint and steps forward if close enough
	if #self.Waypoints == 0 then return end
	if self.WaypointIndex > #self.Waypoints then return end

	local waypoint = self.Waypoints[self.WaypointIndex]
	local horizontalSelf = Vector3.new(self.Root.Position.X, 0, self.Root.Position.Z) -- flatten Y so slopes dont inflate distance
	local horizontalWaypoint = Vector3.new(waypoint.Position.X, 0, waypoint.Position.Z)
	local dist = (horizontalSelf - horizontalWaypoint).Magnitude

	if dist < 4 then -- within 4 studs counts as reached so movement stays fluid
		self.WaypointIndex = self.WaypointIndex + 1
		self:FollowPath() -- immediately issue next MoveTo so there is no pause between waypoints
	end
end

function NPC:MoveToward(targetPos) -- called every tick to keep path fresh and advance waypoints
	self:ComputePath(targetPos) -- throttled internally so safe to call every tick
	self:AdvanceWaypoints() -- check if we passed the current waypoint and step forward
end

function NPC:FindNearestPlayer() -- scans all players and returns the closest one in range
	local nearest = nil
	local nearestDist = CONFIG.DetectionRadius -- only consider players within detection radius

	for _, player in ipairs(Players:GetPlayers()) do -- iterate every connected player
		local char = player.Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart")
			local hum = char:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 then -- only target alive players with a root
				local dist = self:DistanceTo(root.Position) -- measure distance
				if dist < nearestDist then -- checks if closer than current best
					nearestDist = dist
					nearest = player -- update nearest
				end
			end
		end
	end

	return nearest -- returns Player or nil
end

function NPC:HasLineOfSight(targetRoot) -- raycasts from NPC eyes toward the target
	local origin = self.Root.Position + Vector3.new(0, 2, 0) -- offset up slightly for eye height
	local direction = (targetRoot.Position - origin) -- vector pointing at the target

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {self.Model} -- ignore the NPCs own parts
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(origin, direction, rayParams) -- fire the ray

	if result then
		-- if the ray hits the target character LOS is clear
		return result.Instance:IsDescendantOf(targetRoot.Parent)
	end

	return false -- ray hit something else LOS blocked
end

-- Behavior Tree Nodes
-- each function checks a condition or performs an action returning a NodeResult

function NPC:BT_IsDead()
	if self.Humanoid.Health <= 0 then
		return NodeResult.SUCCESS -- success means dead
	end
	return NodeResult.FAILURE
end

function NPC:BT_ShouldFlee()
	if self:GetHealthPercent() < (CONFIG.FleeHealthThreshold / 100) then
		return NodeResult.SUCCESS
	end
	return NodeResult.FAILURE
end

function NPC:BT_FindTarget() -- scan for a nearby player and store as self.Target
	local player = self:FindNearestPlayer()
	if player and player.Character then
		local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
		if targetRoot and self:HasLineOfSight(targetRoot) then -- only target if LOS is clear
			self.Target = player -- store target on the NPC instance
			self.IsAlerted = true -- mark as alerted so patrol doesnt resume immediately
			return NodeResult.SUCCESS
		end
	end
	self.Target = nil -- no valid target found clear it
	return NodeResult.FAILURE
end

function NPC:BT_FleeFromTarget()
	if not self.Target or not self.Target.Character then
		return NodeResult.FAILURE -- no target to flee from
	end

	local targetPos = self.Target.Character.HumanoidRootPart.Position
	local awayDir = (self.Root.Position - targetPos).Unit -- vector pointing away from target
	local fleePos = self.Root.Position + awayDir * 30 -- flee 30 studs in that direction

	self:MoveToward(fleePos) -- smooth path away from target
	return NodeResult.RUNNING -- still fleeing
end

function NPC:BT_ChaseTarget()
	if not self.Target or not self.Target.Character then
		return NodeResult.FAILURE
	end

	local targetRoot = self.Target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return NodeResult.FAILURE end

	local dist = self:DistanceTo(targetRoot.Position)

	if dist <= CONFIG.AttackRadius then -- close enough to attack dont need to chase
		return NodeResult.SUCCESS -- signal to attack node that were in range
	end

	self:MoveToward(targetRoot.Position) -- smooth continuous path toward target
	return NodeResult.RUNNING -- still chasing
end

function NPC:BT_AttackTarget()
	if not self.Target or not self.Target.Character then
		return NodeResult.FAILURE
	end

	local targetRoot = self.Target.Character:FindFirstChild("HumanoidRootPart")
	local targetHum = self.Target.Character:FindFirstChildOfClass("Humanoid")

	if not targetRoot or not targetHum then return NodeResult.FAILURE end

	local dist = self:DistanceTo(targetRoot.Position) -- recheck range every tick

	if dist > CONFIG.AttackRadius then -- target moved out of range
		return NodeResult.FAILURE -- fall back to chase
	end

	local now = tick() -- current timestamp in seconds
	if now - self.LastAttackTime < CONFIG.AttackCooldown then -- cooldown not finished yet
		return NodeResult.RUNNING -- waiting to attack again
	end

	self.LastAttackTime = now -- reset cooldown timer
	targetHum:TakeDamage(CONFIG.AttackDamage) -- apply damage to the targets Humanoid
	self:LookAt(targetRoot.Position) -- snap face toward target on attack

	-- visual punch effect briefly offset the NPC toward the target using CFrame
	local punchOffset = CFrame.new(self.Root.Position, targetRoot.Position) * CFrame.new(0, 0, -1.5)
	self.Root.CFrame = punchOffset -- lunge forward
	task.delay(0.1, function() -- reset after 0.1s
		if self.Root and self.Root.Parent then
			self.Root.CFrame = CFrame.new(self.Root.Position) -- snap back
		end
	end)

	return NodeResult.SUCCESS
end

function NPC:BT_Patrol()
	local points = CONFIG.PatrolPoints
	if #points == 0 then -- no patrol points configured skip to wander
		return NodeResult.FAILURE
	end

	local target = points[self.PatrolIndex] -- get the current patrol waypoint part
	local dist = self:DistanceTo(target.Position)

	if dist < 3 then -- close enough to count as reached
		self.PatrolIndex = (self.PatrolIndex % #points) + 1 -- advance to next point loop at end
		self.Waypoints = {} -- clear stale waypoints so we dont keep walking toward the old point
		self.WaypointIndex = 1
		self.LastPathTime = 0 -- reset throttle so next point gets a fresh path immediately
		return NodeResult.RUNNING
	end

	self:MoveToward(target.Position) -- smooth path toward patrol point
	return NodeResult.RUNNING
end

function NPC:BT_Wander()
	local now = tick()

	if not self.WanderTarget or (now - self.LastWanderTime) > CONFIG.WanderInterval then
		-- pick random polar offset within WanderRadius
		local angle = math.random() * 2 * math.pi -- random angle in radians
		local radius = math.random(5, CONFIG.WanderRadius) -- random distance from spawn
		local offsetX = math.cos(angle) * radius -- X component of offset
		local offsetZ = math.sin(angle) * radius -- Z component of offset
		self.WanderTarget = self.SpawnPosition + Vector3.new(offsetX, 0, offsetZ) -- new wander goal
		self.LastWanderTime = now
		self.Waypoints = {} -- clear old path so the new destination gets a fresh compute
		self.WaypointIndex = 1
		self.LastPathTime = 0 -- force immediate recompute toward the new wander spot
	end

	local dist = self:DistanceTo(self.WanderTarget)
	if dist < 3 then -- reached the wander target
		self.WanderTarget = nil
		self.Waypoints = {}
		self.WaypointIndex = 1
		self.LastPathTime = 0
		return NodeResult.SUCCESS
	end

	self:MoveToward(self.WanderTarget) -- smooth path toward wander point
	return NodeResult.RUNNING
end

function NPC:Tick()
	if self.StateValue then
		if self.Humanoid.Health <= 0 then
			self.StateValue.Value = "Dead"
		elseif self:BT_ShouldFlee() == NodeResult.SUCCESS and self.Target then
			self.StateValue.Value = "Fleeing"
		elseif self.Target then
			local targetRoot = self.Target.Character and self.Target.Character:FindFirstChild("HumanoidRootPart")
			if targetRoot and self:DistanceTo(targetRoot.Position) <= CONFIG.AttackRadius then
				self.StateValue.Value = "Attacking" -- in attack range so show attacking
			else
				self.StateValue.Value = "Chasing" -- has target but not close enough yet
			end -- closes the if targetRoot block
		elseif #CONFIG.PatrolPoints > 0 then
			self.StateValue.Value = "Patrol"
		else
			self.StateValue.Value = "Idle"
		end
	end

	if self:BT_IsDead() == NodeResult.SUCCESS then return end -- dead do nothing

	-- PRIORITY 1 flee if low health and a target exists
	if self:BT_ShouldFlee() == NodeResult.SUCCESS then
		if self:BT_FindTarget() == NodeResult.SUCCESS then -- only flee if theres something to flee from
			self:BT_FleeFromTarget()
			return
		end
	end

	-- PRIORITY 2 attack or chase if a target is found
	if self:BT_FindTarget() == NodeResult.SUCCESS then
		local chaseResult = self:BT_ChaseTarget() -- move toward target
		if chaseResult == NodeResult.SUCCESS then -- in attack range
			self:BT_AttackTarget() -- deal damage
		end
		return -- either chasing or attacking skip lower priority branches
	end

	-- PRIORITY 3 patrol if patrol points exist
	if #CONFIG.PatrolPoints > 0 then
		self:BT_Patrol()
		return
	end

	-- PRIORITY 4 wander as lowest priority fallback
	self:BT_Wander()
end
-- collect patrol points from workspace folder
local patrolFolder = workspace:FindFirstChild("PatrolPoints")
if patrolFolder then
	for _, part in ipairs(patrolFolder:GetChildren()) do -- collect every part in the folder
		if part:IsA("BasePart") then
			table.insert(CONFIG.PatrolPoints, part) -- add to patrol list
		end
	end
end

-- holds the active npc instance so reset can replace it
local npc

local function spawnNPC()
	local template = ServerStorage:FindFirstChild("NPC")
	if not template then
		warn("No NPC template found in ServerStorage")
		return
	end

	-- remove existing npc if one is already in the world
	local existing = workspace:FindFirstChild("NPC")
	if existing then
		existing:Destroy()
	end

	local model = template:Clone() -- clone from ServerStorage so the original stays clean
	model.Name = "NPC"
	model.Parent = workspace

	npc = NPC.new(model) -- create a fresh NPC instance from the new model
end

-- initial spawn
spawnNPC()

-- reset button handler clones a new NPC from ServerStorage
resetRemote.OnServerEvent:Connect(function()
	spawnNPC() -- destroy old and spawn fresh on every reset request
end)

local tickInterval = 0.1 -- seconds between AI ticks so pathfinding isnt hammered every frame
local timeSinceLastTick = 0 -- accumulator

-- Fires every frame
RunService.Heartbeat:Connect(function(deltaTime)
	timeSinceLastTick = timeSinceLastTick + deltaTime -- accumulate elapsed time
	if timeSinceLastTick >= tickInterval then
		timeSinceLastTick = 0 -- reset accumulator
		if npc then
			npc:Tick() -- run 1 AI decision cycle
		end
	end
end)
