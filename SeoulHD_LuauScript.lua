-- Discord Username: rezoneperson | Roblox Username: Solifyre
-- Connected Discord-GitHub
-- Game link - https://www.roblox.com/games/84145306858209/Seoul-HD-Luau-Scripter-Application-Grappling-Hook
--[[
	PROJECT TITLE: Seoul HD Luau Scripter Application
	DESCRIPTION: So I programmed a grappling hook
	PURPOSE: Player hover their mouse on a wall and press Q to use their grappling hook
]]

-- ============================================================================
-- THE FOUR LOCALS ARE THE DEPENDENCIES AND SETUP
-- ============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Client fires this when they want to shoot or let go of the hook
local GrappleRemote = ReplicatedStorage:FindFirstChild("GrappleEvent")
if not GrappleRemote then
	warn("GrappleHookSystem: Could not find 'GrappleEvent' RemoteEvent in ReplicatedStorage. The grapple hook will not function until it is created.")
	return
end

--==[ CONSTANTS ]==--
-- keeping these up top so they're easy to find and tweak while playtesting
local MAX_HOOK_DISTANCE = 300 -- studs, ray just stops here if nothing was hit
local ROPE_THICKNESS = 0.15
local PULL_SPEED = 120 -- studs/sec while reeling someone in
local ARRIVAL_DISTANCE = 5 -- close enough to the anchor, let go automatically

--==[ HELPER FUNCTIONS ]==--

-- Just saves me from typing part.Property = value a dozen times for every
-- part the hook spawns. Pass in a table of properties and it builds the part.
local function createPart(properties)
	local part = Instance.new("Part")
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(properties) do
		part[key] = value
	end
	return part
end

-- makes an Attachment on a part, optionally offset from origin. Used on both
-- ends of the rope so I have a consistent point to work from if I ever swap
-- this over to a real constraint later
local function createAttachment(parentPart, offset)
	local attachment = Instance.new("Attachment")
	attachment.Parent = parentPart
	if offset then
		attachment.Position = offset
	end
	return attachment
end

-- loops through a table of connections and disconnects them all, then wipes
-- the table. mainly here so I don't forget to clean something up when a
-- player respawns or leaves and end up with dead connections piling up
local function cleanupTable(tbl)
	for key, conn in pairs(tbl) do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
		tbl[key] = nil
	end
end

-- :Destroy() but it checks the instance still has a Parent first. Saves me
-- from "attempt to index nil" errors when something's already been removed
-- by the engine before my cleanup code gets to it
local function safeDestroy(instance)
	if instance and instance.Parent then
		instance:Destroy()
	end
end

-- ============================================================================
-- MODULE/CLASS DEFINITIONS (if using metatables)
-- ============================================================================

--==[ HOOK CLASS ]==--
-- every player gets their own Hook so the state, ropes and physics don't
-- bleed into each other when more than one person is grappling at once

local Hook = {}
Hook.__index = Hook

-- takes the player and character so I can grab Humanoid/HumanoidRootPart up
-- front, since I need both constantly throughout the swing logic. state
-- starts at Idle, meaning nothing is currently hooked
function Hook.new(player, character)
	local self = setmetatable({}, Hook)

	self.player = player
	self.character = character
	self.humanoid = character:FindFirstChildOfClass("Humanoid")
	self.hrp = character:FindFirstChild("HumanoidRootPart")

	-- three states basically:
	--   Idle     nothing happening, ready to fire
	--   Aiming   raycast went out, waiting to know if it hit anything
	--   Swinging hooked in, currently being pulled toward the anchor
	self.state = "Idle"

	-- stuff created in :Attach(), stored here so Release/Destroy can clean it up
	self.anchorPart = nil       -- invisible part sitting at the raycast hit point
	self.ropeConstraint = nil   -- not actually used, see the note in :Attach
	self.ropeVisual = nil       -- the rope you actually see, resized every frame
	self.charAttachment = nil
	self.anchorAttachment = nil
	self.heartbeatConn = nil    -- the loop that does the pulling + rope visuals
	self.diedConn = nil

	self.connections = {}

	-- if they die mid-swing I want everything torn down right away instead of
	-- leaving parts sitting in the workspace or a heartbeat loop running on a
	-- character that doesn't exist anymore
	if self.humanoid then
		self.diedConn = self.humanoid.Died:Connect(function()
			self:Destroy()
		end)
	end

	return self
end

-- Hook:Fire(direction)
-- called when the player presses Q. direction comes from the client's camera
-- look vector, but the raycast itself happens here on the server so it can't
-- be spoofed. connects to :Attach() if it hits something, otherwise just
-- resets back to Idle so they can try again
function Hook:Fire(direction)
	-- only fire from Idle, otherwise people could spam Q and re-fire mid swing
	if self.state ~= "Idle" then
		return
	end

	-- nothing to raycast from if the character's being torn down
	if not self.hrp or not self.hrp.Parent then
		return
	end

	self.state = "Aiming"

	-- exclude the character itself so the ray doesn't just hit their own
	-- torso a foot in front of the camera
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {self.character}
	rayParams.IgnoreWater = true

	local normalizedDirection = direction.Unit

	local rayResult = Workspace:Raycast(self.hrp.Position, normalizedDirection * MAX_HOOK_DISTANCE, rayParams)

	if rayResult and rayResult.Instance then
		self:Attach(rayResult.Position, rayResult.Instance)
	else
		-- missed, nothing to hook onto
		self.state = "Idle"
	end
end

-- Hook:Attach(hitPosition, hitPart)
-- runs after a successful raycast. builds the anchor, the visible rope, and
-- starts the heartbeat loop that actually drags the player in.
--
-- note: I'm not using a RopeConstraint for this. tried it early on and the
-- physics solver kept fighting my velocity changes every frame, so instead
-- of reeling in smoothly the player would just jitter in place. setting
-- AssemblyLinearVelocity directly every frame skips that problem entirely
function Hook:Attach(hitPosition, hitPart)
	-- should only ever get here from :Fire()
	if self.state ~= "Aiming" then
		return
	end

	-- character could've died in the gap between the raycast firing and this
	-- running, so double check
	if not self.hrp or not self.hrp.Parent then
		self.state = "Idle"
		return
	end

	self.state = "Swinging"

	local charPos = self.hrp.Position
	local ropeLength = (hitPosition - charPos).Magnitude

	-- tiny invisible part at the hit point, this is what the rope stretches
	-- toward. CanQuery is off so it doesn't mess with other raycasts
	self.anchorPart = createPart({
		Name = "GrappleAnchor_" .. self.player.Name,
		Size = Vector3.new(0.5, 0.5, 0.5),
		Transparency = 1,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		Parent = Workspace,
	})
	self.anchorPart.CFrame = CFrame.new(hitPosition)

	-- attachments on both ends, not doing anything with them right now but
	-- they're cheap and might be useful if I switch to a constraint later
	self.anchorAttachment = createAttachment(self.anchorPart, Vector3.zero)
	self.charAttachment = createAttachment(self.hrp, Vector3.zero)

	self.ropeConstraint = nil

	-- the actual visible rope, just a thin part I reposition and resize
	-- every heartbeat so it looks like it's stretching between anchor and player
	self.ropeVisual = createPart({
		Name = "GrappleRope_" .. self.player.Name,
		Size = Vector3.new(ROPE_THICKNESS, ROPE_THICKNESS, ropeLength),
		Color = Color3.fromRGB(80, 50, 30),
		Material = Enum.Material.Neon,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		Parent = Workspace,
	})

	-- PlatformStand basically tells the humanoid to stop fighting me for
	-- control of the character's physics. without it the default walk/fall
	-- controller cancels out my velocity changes. turned back off in :Release()
	if self.humanoid then
		self.humanoid.PlatformStand = true
	end

	-- the actual grapple loop, runs every heartbeat while Swinging:
	--   1. update the rope so it stays stretched between anchor and player
	--   2. set velocity straight toward the anchor at PULL_SPEED (not lerped,
	--      because with PlatformStand on there's nothing resisting gravity
	--      anymore, so a gradual ramp would just let the player fall for a
	--      few frames before the pull caught up)
	--   3. check distance to anchor and auto release once close enough
	self.heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		-- state could've changed or the hrp could be gone by the time this runs
		if self.state ~= "Swinging" or not self.hrp or not self.hrp.Parent then
			return
		end

		local anchorPos = self.anchorPart.Position
		local charPos2 = self.hrp.Position
		local ropeVec = charPos2 - anchorPos
		local currentDist = ropeVec.Magnitude

		-- close enough, let go. gives a small nudge in the pull direction so
		-- they don't just stop dead the instant they cross the threshold
		if currentDist <= ARRIVAL_DISTANCE then
			if currentDist > 0.01 then
				local residualDir = (-ropeVec).Unit
				self.hrp.AssemblyLinearVelocity = residualDir * PULL_SPEED * 0.3
			end
			self:Release()
			return
		end

		-- rope sits at the midpoint between anchor and player, pointed at the
		-- player, and stretched/shrunk to match the current distance
		if currentDist > 0.01 then
			local midpoint = (anchorPos + charPos2) / 2
			self.ropeVisual.Size = Vector3.new(ROPE_THICKNESS, ROPE_THICKNESS, currentDist)
			self.ropeVisual.CFrame = CFrame.lookAt(midpoint, charPos2)
		end

		-- pull toward the anchor. setting velocity directly instead of lerping
		-- so gravity never gets a window to win, full speed applies immediately
		if currentDist > 0.01 then
			local pullDir = (-ropeVec).Unit
			self.hrp.AssemblyLinearVelocity = pullDir * PULL_SPEED
		end
	end)

	self.connections["heartbeat"] = self.heartbeatConn
end

-- Hook:Release()
-- lets go of the grapple and cleans up everything :Attach() made. happens
-- when the player releases the key, they reach the anchor, or as part of a
-- full :Destroy(). player gets normal movement back and can fire again after
function Hook:Release()
	-- only makes sense from Swinging or Aiming, stops double releases
	if self.state ~= "Swinging" and self.state ~= "Aiming" then
		return
	end

	self.state = "Idle"

	-- hand movement back to the humanoid's normal controller, otherwise
	-- they'd be stuck unable to walk
	if self.humanoid and self.humanoid.Parent then
		self.humanoid.PlatformStand = false
	end

	-- safeDestroy handles anything that's already gone, so this won't error
	-- even if something got cleaned up elsewhere first
	safeDestroy(self.ropeVisual)
	safeDestroy(self.ropeConstraint)
	safeDestroy(self.charAttachment)
	safeDestroy(self.anchorAttachment)
	safeDestroy(self.anchorPart)

	self.ropeVisual = nil
	self.ropeConstraint = nil
	self.charAttachment = nil
	self.anchorAttachment = nil
	self.anchorPart = nil

	if self.heartbeatConn then
		self.heartbeatConn:Disconnect()
		self.heartbeatConn = nil
	end
	self.connections["heartbeat"] = nil
end

-- Hook:Destroy()
-- the real teardown, runs when a character dies or a player leaves. this
-- doesn't just call :Release() because Release has a state guard that could
-- skip cleanup if state ends up somewhere unexpected, this version forces it
-- regardless. once this runs the Hook shouldn't be touched again
function Hook:Destroy()
	if self.state == "Swinging" or self.state == "Aiming" then
		self.state = "Idle"
		if self.humanoid and self.humanoid.Parent then
			self.humanoid.PlatformStand = false
		end
		safeDestroy(self.ropeVisual)
		safeDestroy(self.ropeConstraint)
		safeDestroy(self.charAttachment)
		safeDestroy(self.anchorAttachment)
		safeDestroy(self.anchorPart)
		self.ropeVisual = nil
		self.ropeConstraint = nil
		self.charAttachment = nil
		self.anchorAttachment = nil
		self.anchorPart = nil
		if self.heartbeatConn then
			self.heartbeatConn:Disconnect()
			self.heartbeatConn = nil
		end
	end

	cleanupTable(self.connections)

	-- diedConn lives outside self.connections so it needs its own disconnect
	if self.diedConn then
		self.diedConn:Disconnect()
		self.diedConn = nil
	end

	-- drop references so the old character/humanoid can actually get garbage
	-- collected instead of being held onto by this Hook forever
	self.player = nil
	self.character = nil
	self.humanoid = nil
	self.hrp = nil
end

-- ============================================================================
-- MAIN FUNCTIONALITY
-- ============================================================================

--==[ PLAYER HOOK MANAGEMENT ]==--

-- one Hook per player, keyed by the Player object so lookups on RemoteEvent
-- calls are instant
local playerHooks = {}

-- runs whenever a character (re)spawns. destroys the old hook first just in
-- case one's still hanging around, then makes a fresh one pointing at the
-- new character so it's never holding stale Humanoid/HRP references
local function onCharacterAdded(player, character)
	if playerHooks[player] then
		playerHooks[player]:Destroy()
		playerHooks[player] = nil
	end
	playerHooks[player] = Hook.new(player, character)
end

-- player left, destroy their hook so nothing keeps running against a
-- character that's no longer in the game
local function onPlayerRemoving(player)
	if playerHooks[player] then
		playerHooks[player]:Destroy()
		playerHooks[player] = nil
	end
end

--==[ REMOTE EVENT HANDLER ]==--

-- client sends two things here: action ("Fire" or "Release") and direction
-- (only matters for Fire). all the raycasting and physics happen server side,
-- client is just expressing intent, so there's no way to spoof a hook to some
-- arbitrary spot or skip the max range check
GrappleRemote.OnServerEvent:Connect(function(player, action, direction)
	local hook = playerHooks[player]
	if not hook then
		return
	end

	if action == "Fire" then
		-- ignore garbage data instead of erroring if it's not actually a Vector3
		if typeof(direction) == "Vector3" then
			hook:Fire(direction)
		end
	elseif action == "Release" then
		hook:Release()
	end
end)

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

-- hook up PlayerAdded/CharacterAdded so every new player gets a Hook when
-- they spawn. also covers the case where the character already exists,
-- which happens a lot in studio when playtesting solo
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end)

Players.PlayerRemoving:Connect(onPlayerRemoving)

-- covers players who were already in the game before this script ran, which
-- happens with hot reloading in studio since they won't fire PlayerAdded again
for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end
