-- Services
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local resetRemote = Instance.new("RemoteEvent")
resetRemote.Name = "ResetNPC"
resetRemote.Parent = ReplicatedStorage

-- Configuration
local CONFIG = {
	DetectionRadius = 40,
	AttackRadius = 5,
	AttackCooldown = 1.5,
	AttackDamage = 15,
	WanderRadius = 20,
	WanderInterval = 4,
	FleeHealthThreshold = 30,
	PatrolPoints = {},
	MoveSpeed = 16,
	PathUpdateRate = 0.5,
}

-- Enum style table
local NodeResult = {
	SUCCESS = "SUCCESS",
	FAILURE = "FAILURE",
	RUNNING = "RUNNING",
}

-- NPC Class
local NPC = {}
NPC.__index = NPC

function NPC.new(model)
	local self = setmetatable({}, NPC)

	self.Model = model
	self.Humanoid = model:FindFirstChildOfClass("Humanoid")
	self.Root = model:FindFirstChild("HumanoidRootPart")
	self.SpawnPosition = self.Root.Position
	self.Target = nil
	self.LastAttackTime = 0
	self.LastWanderTime = 0
	self.WanderTarget = nil
	self.PatrolIndex = 1
	self.IsAlerted = false

	-- Waypoint tracking for the pathfinding system
	-- WaypointIndex starts at 2 because index 1 is always the NPC's current position
	-- LastPathTime and PathComputeInProgress together throttle and guard ComputeAsync
	-- so we never fire two overlapping path requests
	self.Waypoints = {}
	self.WaypointIndex = 1
	self.LastPathTime = 0
	self.PathComputeInProgress = false

	-- StringValue parented to the model so a Billboard GUI in the character can read
	-- the current state without needing a remote event
	local sv = Instance.new("StringValue")
	sv.Name = "AIState"
	sv.Value = "Idle"
	sv.Parent = self.Model
	self.StateValue = sv

	self.Humanoid.WalkSpeed = CONFIG.MoveSpeed
	-- AutoRotate is left on so Roblox's physics solver handles turning;
	-- manually rotating every frame while MoveTo is active causes jitter.
	self.Humanoid.AutoRotate = true

	self.Humanoid.HealthChanged:Connect(function(newHealth)
		self:OnHealthChanged(newHealth)
	end)

	return self
end

function NPC:GetHealthPercent()
	return self.Humanoid.Health / self.Humanoid.MaxHealth
end

function NPC:DistanceTo(position)
	return (self.Root.Position - position).Magnitude
end

-- Flattens the direction to the XZ plane before rotating so the NPC never
-- tilts its body up or down when the target is on a different elevation.
function NPC:LookAt(position)
	local direction = (position - self.Root.Position) * Vector3.new(1, 0, 1)
	if direction.Magnitude > 0.01 then -- guard against normalising a zero vector if target is at same position
		self.Root.CFrame = CFrame.new(self.Root.Position, self.Root.Position + direction)
	end
end

function NPC:OnHealthChanged(newHealth)
	if newHealth <= 0 then
		self:Cleanup()
	end
end

function NPC:Cleanup()
	self.Waypoints = {}
	self.WaypointIndex = 1
	if self.StateValue then
		self.StateValue.Value = "Dead"
	end
	self.Humanoid:UnequipTools()
end

-- Throttled via PathUpdateRate and guarded by PathComputeInProgress to prevent
-- overlapping ComputeAsync calls, which can cause the path to silently fail or
-- return stale results. Falls back to a direct MoveTo if pathfinding fails so
-- the NPC never just stands still.
function NPC:ComputePath(targetPos)
	if self.PathComputeInProgress then return end
	if self.Humanoid.Health <= 0 then return end

	local now = tick()
	if now - self.LastPathTime < CONFIG.PathUpdateRate then return end -- don't recompute until interval has passed
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
		path:ComputeAsync(self.Root.Position, targetPos)
	end)

	if success and path.Status == Enum.PathStatus.Success then
		self.Waypoints = path:GetWaypoints()
		self.WaypointIndex = 2 -- index 1 is the NPC's current position, skip it
		self:FollowPath()
	else
		self.Waypoints = {}
		self.Humanoid:MoveTo(targetPos) -- direct move fallback if pathfinding fails
	end

	self.PathComputeInProgress = false
end

function NPC:FollowPath()
	if #self.Waypoints == 0 then return end
	if self.WaypointIndex > #self.Waypoints then return end

	local waypoint = self.Waypoints[self.WaypointIndex]

	-- Jump must be triggered before issuing MoveTo, otherwise the humanoid
	-- starts walking into the obstacle before the jump animation fires.
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		self.Humanoid.Jump = true
	end

	self.Humanoid:MoveTo(waypoint.Position)
end

-- Uses horizontal-only distance so that sloped terrain or stairs don't inflate
-- the measured distance and cause the NPC to skip waypoints early.
function NPC:AdvanceWaypoints()
	if #self.Waypoints == 0 then return end
	if self.WaypointIndex > #self.Waypoints then return end

	local waypoint = self.Waypoints[self.WaypointIndex]
	local horizontalSelf = Vector3.new(self.Root.Position.X, 0, self.Root.Position.Z) -- strip Y so slope doesn't inflate distance
	local horizontalWaypoint = Vector3.new(waypoint.Position.X, 0, waypoint.Position.Z)

	if (horizontalSelf - horizontalWaypoint).Magnitude < 4 then -- 4 stud threshold keeps movement fluid without overshooting
		self.WaypointIndex = self.WaypointIndex + 1
		self:FollowPath()
	end
end

function NPC:MoveToward(targetPos)
	self:ComputePath(targetPos)
	self:AdvanceWaypoints()
end

function NPC:FindNearestPlayer()
	local nearest = nil
	local nearestDist = CONFIG.DetectionRadius

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart")
			local hum = char:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 then
				local dist = self:DistanceTo(root.Position)
				if dist < nearestDist then
					nearestDist = dist
					nearest = player
				end
			end
		end
	end

	return nearest
end

-- Casts from slightly above the root to simulate eye height. The NPC model is
-- excluded from the filter so its own parts don't immediately block the ray.
function NPC:HasLineOfSight(targetRoot)
	local origin = self.Root.Position + Vector3.new(0, 2, 0) -- offset to eye height so ground geometry doesn't block the ray
	local direction = targetRoot.Position - origin

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {self.Model} -- exclude self or the ray hits the NPC's own parts instantly
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(origin, direction, rayParams)

	if result then
		return result.Instance:IsDescendantOf(targetRoot.Parent) -- true only if the ray landed on the target's character
	end

	return false
end

-- Behavior Tree Nodes
-- SUCCESS FAILURE RUNNING follows standard BT conventions:
-- SUCCESS = condition met or action completed, FAILURE = condition not met,
-- RUNNING = action is ongoing and should be revisited next tick.

function NPC:BT_IsDead()
	if self.Humanoid.Health <= 0 then
		return NodeResult.SUCCESS
	end
	return NodeResult.FAILURE
end

function NPC:BT_ShouldFlee()
	if self:GetHealthPercent() < (CONFIG.FleeHealthThreshold / 100) then
		return NodeResult.SUCCESS
	end
	return NodeResult.FAILURE
end

function NPC:BT_FindTarget()
	local player = self:FindNearestPlayer()
	if player and player.Character then
		local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
		if targetRoot and self:HasLineOfSight(targetRoot) then -- only lock on if LOS is clear, prevents targeting through walls
			self.Target = player
			self.IsAlerted = true
			return NodeResult.SUCCESS
		end
	end
	self.Target = nil -- clear stale target if no valid player was found this tick
	return NodeResult.FAILURE
end

function NPC:BT_FleeFromTarget()
	if not self.Target or not self.Target.Character then
		return NodeResult.FAILURE
	end

	local targetPos = self.Target.Character.HumanoidRootPart.Position
	local awayDir = (self.Root.Position - targetPos).Unit -- unit vector pointing directly away from the threat
	local fleePos = self.Root.Position + awayDir * 30

	self:MoveToward(fleePos)
	return NodeResult.RUNNING
end

function NPC:BT_ChaseTarget()
	if not self.Target or not self.Target.Character then
		return NodeResult.FAILURE
	end

	local targetRoot = self.Target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return NodeResult.FAILURE end

	if self:DistanceTo(targetRoot.Position) <= CONFIG.AttackRadius then
		return NodeResult.SUCCESS -- in range signal attack node to take over
	end

	self:MoveToward(targetRoot.Position)
	return NodeResult.RUNNING
end

function NPC:BT_AttackTarget()
	if not self.Target or not self.Target.Character then
		return NodeResult.FAILURE
	end

	local targetRoot = self.Target.Character:FindFirstChild("HumanoidRootPart")
	local targetHum = self.Target.Character:FindFirstChildOfClass("Humanoid")

	if not targetRoot or not targetHum then return NodeResult.FAILURE end
	if self:DistanceTo(targetRoot.Position) > CONFIG.AttackRadius then return NodeResult.FAILURE end -- target escaped fall back to chase

	local now = tick()
	if now - self.LastAttackTime < CONFIG.AttackCooldown then
		return NodeResult.RUNNING -- cooldown still active hold until ready
	end

	self.LastAttackTime = now
	targetHum:TakeDamage(CONFIG.AttackDamage)
	self:LookAt(targetRoot.Position)

	-- Brief CFrame lunge toward the target to sell the hit visually
	-- Resets after 0.1s the Parent check guards against the NPC being
	-- destroyed during the delay.
	local punchOffset = CFrame.new(self.Root.Position, targetRoot.Position) * CFrame.new(0, 0, -1.5)
	self.Root.CFrame = punchOffset
	task.delay(0.1, function()
		if self.Root and self.Root.Parent then
			self.Root.CFrame = CFrame.new(self.Root.Position)
		end
	end)

	return NodeResult.SUCCESS
end

function NPC:BT_Patrol()
	local points = CONFIG.PatrolPoints
	if #points == 0 then return NodeResult.FAILURE end

	local target = points[self.PatrolIndex]

	if self:DistanceTo(target.Position) < 3 then
		self.PatrolIndex = (self.PatrolIndex % #points) + 1 -- advance and loop back to 1 after the last point
		-- Clear path state so the next point triggers a fresh ComputeAsync
		-- rather than continuing along the old route.
		self.Waypoints = {}
		self.WaypointIndex = 1
		self.LastPathTime = 0
		return NodeResult.RUNNING
	end

	self:MoveToward(target.Position)
	return NodeResult.RUNNING
end

function NPC:BT_Wander()
	local now = tick()

	-- Pick a new random destination when the previous one was reached or the
	-- interval has elapsed. Polar coordinates keep the target within WanderRadius
	-- of the spawn rather than drifting arbitrarily far from it.
	if not self.WanderTarget or (now - self.LastWanderTime) > CONFIG.WanderInterval then
		local angle = math.random() * 2 * math.pi
		local radius = math.random(5, CONFIG.WanderRadius)
		self.WanderTarget = self.SpawnPosition + Vector3.new(
			math.cos(angle) * radius,
			0,
			math.sin(angle) * radius
		)
		self.LastWanderTime = now
		self.Waypoints = {}
		self.WaypointIndex = 1
		self.LastPathTime = 0 -- force immediate recompute toward the new wander destination
	end

	if self:DistanceTo(self.WanderTarget) < 3 then
		self.WanderTarget = nil
		self.Waypoints = {}
		self.WaypointIndex = 1
		self.LastPathTime = 0
		return NodeResult.SUCCESS
	end

	self:MoveToward(self.WanderTarget)
	return NodeResult.RUNNING
end

-- Runs every tickInterval seconds. Evaluates the behavior tree top-down so that
-- higher-priority branches (flee, attack) always override lower ones (patrol, wander).
function NPC:Tick()
	if self.StateValue then
		if self.Humanoid.Health <= 0 then
			self.StateValue.Value = "Dead"
		elseif self:BT_ShouldFlee() == NodeResult.SUCCESS and self.Target then
			self.StateValue.Value = "Fleeing"
		elseif self.Target then
			local targetRoot = self.Target.Character and self.Target.Character:FindFirstChild("HumanoidRootPart")
			if targetRoot and self:DistanceTo(targetRoot.Position) <= CONFIG.AttackRadius then
				self.StateValue.Value = "Attacking"
			else
				self.StateValue.Value = "Chasing"
			end
		elseif #CONFIG.PatrolPoints > 0 then
			self.StateValue.Value = "Patrol"
		else
			self.StateValue.Value = "Idle"
		end
	end

	if self:BT_IsDead() == NodeResult.SUCCESS then return end

	-- PRIORITY 1: flee overrides everything when health is critical
	if self:BT_ShouldFlee() == NodeResult.SUCCESS then
		if self:BT_FindTarget() == NodeResult.SUCCESS then
			self:BT_FleeFromTarget()
			return
		end
	end

	-- PRIORITY 2: chase then attack if a target is in range and visible
	if self:BT_FindTarget() == NodeResult.SUCCESS then
		local chaseResult = self:BT_ChaseTarget()
		if chaseResult == NodeResult.SUCCESS then -- chase returned SUCCESS meaning we're in attack range
			self:BT_AttackTarget()
		end
		return
	end

	-- PRIORITY 3: structured patrol if points are configured
	if #CONFIG.PatrolPoints > 0 then
		self:BT_Patrol()
		return
	end

	-- PRIORITY 4: wander as lowest priority fallback when nothing else applies
	self:BT_Wander()
end

-- Patrol point collection
local patrolFolder = workspace:FindFirstChild("PatrolPoints")
if patrolFolder then
	for _, part in ipairs(patrolFolder:GetChildren()) do
		if part:IsA("BasePart") then
			table.insert(CONFIG.PatrolPoints, part)
		end
	end
end

local npc

local function spawnNPC()
	local template = ServerStorage:FindFirstChild("NPC")
	if not template then
		warn("No NPC template found in ServerStorage")
		return
	end

	local existing = workspace:FindFirstChild("NPC")
	if existing then
		existing:Destroy()
	end

	local model = template:Clone()
	model.Name = "NPC"
	model.Parent = workspace

	npc = NPC.new(model)
end

spawnNPC()

resetRemote.OnServerEvent:Connect(function()
	spawnNPC()
end)

-- Heartbeat accumulator pattern keeps the AI tick rate decoupled from the
-- frame rate 0.1s per tick is frequent enough for responsive decisions
-- without firing pathfinding every frame
local tickInterval = 0.1
local timeSinceLastTick = 0

RunService.Heartbeat:Connect(function(deltaTime)
	timeSinceLastTick = timeSinceLastTick + deltaTime
	if timeSinceLastTick >= tickInterval then
		timeSinceLastTick = 0 -- reset accumulator after each tick fires
		if npc then
			npc:Tick()
		end
	end
end)
