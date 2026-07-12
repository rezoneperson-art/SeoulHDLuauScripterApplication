-- Discord Username: rezoneperson | Roblox Username: Solifyre
-- Connected Discord-GitHub
--[[
	PROJECT TITLE: Seoul HD Luau Scripter Application
	DESCRIPTION: So I programmed a grappling hook
	PURPOSE: Player hover their mouse on a wall and press Q to grappling hook directly to that position
]]

-- ============================================================================
-- DEPENDENCIES & SETUP
-- ============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- The RemoteEvent that the client uses to tell the server "I want to fire/release the grapple." 
local GrappleRemote = ReplicatedStorage:FindFirstChild("GrappleEvent")
if not GrappleRemote then
	warn("GrappleHookSystem: Could not find 'GrappleEvent' RemoteEvent in ReplicatedStorage. The grapple hook will not function until it is created.")
	return
end

--==[ CONSTANTS ]==--
-- Tuning values for the grapple hook. Grouped here so they're easy to tweak
local MAX_HOOK_DISTANCE = 300 -- Max raycast range in studs; beyond this the hook misses
local ROPE_THICKNESS = 0.15   -- How thick the visual rope part appears
local PULL_SPEED = 120        -- Target velocity when reeling the player in (studs/s)
local ARRIVAL_DISTANCE = 5    -- Once the player is this close to the anchor, auto-release

--==[ HELPER FUNCTIONS ]==--

-- Small utility that wraps Instance.new("Part") and lets us set properties via a
-- table argument instead of writing them one by one. Every physical part the
-- grapple system creates (anchor, rope visual) goes through here, so we get
-- consistent surface defaults and less boilerplate.
local function createPart(properties)
	local part = Instance.new("Part")
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(properties) do
		part[key] = value
	end
	return part
end

-- Creates an Attachment on the given part. An optional offset can be supplied
-- to position it away from the part's origin. We use attachments because
-- constraints (and our manual rope positioning) need a point in space to
-- anchor themselves to.
local function createAttachment(parentPart, offset)
	local attachment = Instance.new("Attachment")
	attachment.Parent = parentPart
	if offset then
		attachment.Position = offset
	end
	return attachment
end

-- Walks a table of RBXScriptConnections, disconnecting each one, then clears
-- the table. Called during teardown to make sure no lingering event handlers
-- stay alive after a Hook is destroyed — otherwise we'd leak connections every
-- time a player respawned or left.
local function cleanupTable(tbl)
	for key, conn in pairs(tbl) do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
		tbl[key] = nil
	end
end

-- Wrapper around :Destroy() that checks whether the instance still has a
-- Parent first. During cleanup it's possible that something was already
-- removed (e.g., the character's parts got cleaned up by the engine), so
-- guarding each call prevents "attempt to index nil" errors.
local function safeDestroy(instance)
	if instance and instance.Parent then
		instance:Destroy()
	end
end

-- ============================================================================
-- MODULE/CLASS DEFINITIONS (if using metatables)
-- ============================================================================

--==[ HOOK CLASS ]==--
-- Each player gets their own Hook instance that manages the full lifecycle of
-- a grapple: firing, attaching, swinging/pulling, releasing, and cleanup.
-- Using a metatable-based class keeps per-player state isolated and makes it
-- easy to support multiple players grappling at the same time without their
-- ropes or physics interfering with each other.

local Hook = {}
Hook.__index = Hook

-- Constructor. We pass in the player and their character so the Hook can hold
-- direct references to the Humanoid and HumanoidRootPart — these are used
-- throughout the swing/pull logic and checked frequently for validity since
-- they can disappear if the character dies or is removed mid-swing.
-- State machine starts at "Idle" meaning no grapple is active.
function Hook.new(player, character)
	local self = setmetatable({}, Hook)

	-- Core references
	self.player = player
	self.character = character
	self.humanoid = character:FindFirstChildOfClass("Humanoid")
	self.hrp = character:FindFirstChild("HumanoidRootPart")

	-- Simple state machine with three states:
	--   Idle    → no grapple active, ready to fire
	--   Aiming  → raycast sent, waiting to see if it hit something
	--   Swinging → rope attached, player is being pulled toward anchor
	self.state = "Idle"

	-- References to the physical objects we create during :Attach(). We store
	-- them as fields so :Release() and :Destroy() can clean everything up.
	self.anchorPart = nil       -- Invisible anchored part placed at the raycast hit point
	self.ropeConstraint = nil   -- Kept nil; we drive movement manually (see :Attach for why)
	self.ropeVisual = nil       -- Thin visible part stretched between anchor and HRP each frame
	self.charAttachment = nil   -- Attachment on the character's HumanoidRootPart
	self.anchorAttachment = nil -- Attachment on the anchor part
	self.heartbeatConn = nil    -- Heartbeat connection driving the per-frame pull + rope visual
	self.diedConn = nil         -- Humanoid.Died connection for auto-cleanup

	-- General-purpose table for any event connections we want cleaned up on destroy.
	self.connections = {}

	-- If the character dies while grappling we want to tear down immediately so
	-- we don't leave orphaned parts in the Workspace or keep running Heartbeat
	-- against a character that no longer exists.
	if self.humanoid then
		self.diedConn = self.humanoid.Died:Connect(function()
			self:Destroy()
		end)
	end

	return self
end

-- Hook:Fire(direction)
-- Entry point for firing the grapple. The client sends a world-space direction
-- vector (derived from their camera look direction) and we do the raycast on
-- the server so it can't be spoofed. If the ray connects, we hand off to
-- :Attach() which sets up the rope and starts the pull loop. If it misses we
-- quietly reset to Idle so the player can try again.
function Hook:Fire(direction)
	-- Only allow firing from Idle — prevents double-firing or re-firing mid-swing.
	if self.state ~= "Idle" then
		return
	end

	-- If the HumanoidRootPart is gone (character being torn down) there's nothing
	-- to raycast from, so bail out.
	if not self.hrp or not self.hrp.Parent then
		return
	end

	-- Mark Aiming so :Attach() knows we came from a valid Fire call.
	self.state = "Aiming"

	-- Set up raycast parameters. We exclude the character's own parts from the
	-- ray — otherwise the ray would immediately hit the player's torso/limbs and
	-- never reach the environment behind them.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {self.character}
	rayParams.IgnoreWater = true

	-- Normalize so the direction is a unit vector — this lets us multiply by
	-- MAX HOOK DISTANCE to get the exact ray length we want.
	local normalizedDirection = direction.Unit

	-- Cast from the HRP outward. The result (if any) contains the .Position where
	-- the ray hit and the .Instance it hit — both are needed by :Attach().
	local rayResult = Workspace:Raycast(self.hrp.Position, normalizedDirection * MAX_HOOK_DISTANCE, rayParams)

	if rayResult and rayResult.Instance then
		self:Attach(rayResult.Position, rayResult.Instance)
	else
		-- Missed — nothing to hook onto. Reset so the player can fire again.
		self.state = "Idle"
	end
end

-- Hook:Attach(hitPosition, hitPart)
-- Called after a successful raycast. Sets up the physical grapple: an invisible
-- anchor part at the hit point, a visible rope stretched between the anchor and
-- the player, and a Heartbeat loop that drags the player toward the anchor.
--
-- We intentionally do NOT use a RopeConstraint here. In earlier iterations the
-- constraint solver ran after our manual velocity changes each frame and applied
-- corrective forces that cancelled out the pull — the player would jitter in
-- place instead of being reeled in. By skipping the constraint entirely and
-- driving movement through AssemblyLinearVelocity we get full, predictable
-- control over how the player moves toward the anchor.
function Hook:Attach(hitPosition, hitPart)
	-- Guard: must have come from :Fire() (state == "Aiming").
	if self.state ~= "Aiming" then
		return
	end

	-- Double-check the HRP is still valid — the character could have died between
	-- the raycast and this call in edge cases.
	if not self.hrp or not self.hrp.Parent then
		self.state = "Idle"
		return
	end

	self.state = "Swinging"

	-- Measure how far the player is from the hit point. This is used as the
	-- initial length of the visual rope and gives us a baseline for the pull.
	local charPos = self.hrp.Position
	local ropeLength = (hitPosition - charPos).Magnitude

	-- Spawn an invisible anchored part at the exact raycast hit position. This
	-- acts as the fixed anchor that the rope visually connects to. It's tiny,
	-- non-collidable, and has CanQuery disabled so it doesn't interfere with
	-- other raycasts or physics in the world.
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

	-- Attachments on both ends. Even though we're not using a constraint, we
	-- keep these around in case we want to swap in a constraint-based approach
	-- later, and they don't cost anything meaningful.
	self.anchorAttachment = createAttachment(self.anchorPart, Vector3.zero)
	self.charAttachment = createAttachment(self.hrp, Vector3.zero)

	-- Explicitly nil — see the comment at the top of this function for why we
	-- skip the RopeConstraint and do manual velocity control instead.
	self.ropeConstraint = nil

	-- Create the visible rope. This is just a thin part that we re-position and
	-- re-size every Heartbeat frame to stretch between the anchor and the player.
	-- Using Neon material gives it a clean, readable look against most environments.
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

	-- Put the Humanoid into PlatformStand so it stops applying its own movement
	-- forces. While PlatformStand is active the Humanoid essentially lets go of
	-- the character's physics, which means our AssemblyLinearVelocity changes
	-- aren't being fought by the default walk/fall controller. We restore it
	-- back to false in :Release().
	if self.humanoid then
		self.humanoid.PlatformStand = true
	end

	-- This is the core of the grapple. Every Heartbeat frame (roughly 60x/sec)
	-- we do three things while the player is in the Swinging state:
	--   1. Update the visual rope so it stays stretched between the anchor and HRP.
	--   2. Set the character's velocity directly toward the anchor at PULL_SPEED.
	--      We do NOT lerp here — a gradual ramp lets gravity win the first few
	--      frames (since PlatformStand removed the Humanoid's fall resistance),
	--      causing the player to drop before the pull takes over. Setting the
	--      velocity outright each frame completely overrides gravity and sends
	--      the player flying straight toward the hook point immediately.
	--   3. Check if the player has gotten close enough to auto-release the hook.
	self.heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		-- Bail out if the state changed (e.g., Release was called) or the HRP
		-- vanished mid-frame. This prevents errors if cleanup happened between frames.
		if self.state ~= "Swinging" or not self.hrp or not self.hrp.Parent then
			return
		end

		local anchorPos = self.anchorPart.Position
		local charPos2 = self.hrp.Position
		local ropeVec = charPos2 - anchorPos
		local currentDist = ropeVec.Magnitude

		-- Once the player is close enough to the anchor, release the hook.
		-- We give a small residual nudge in the pull direction (30% of PULL_SPEED)
		-- so the player keeps moving toward the surface instead of stopping dead
		-- the instant they hit the release threshold.
		if currentDist <= ARRIVAL_DISTANCE then
			if currentDist > 0.01 then
				local residualDir = (-ropeVec).Unit
				self.hrp.AssemblyLinearVelocity = residualDir * PULL_SPEED * 0.3
			end
			self:Release()
			return
		end

		-- Reposition the visual rope. We place it at the midpoint between the
		-- anchor and the player, point its front face toward the player using
		-- CFrame.lookAt, and set its Z size to the current distance so it
		-- appears to stretch and contract as the player moves.
		if currentDist > 0.01 then
			local midpoint = (anchorPos + charPos2) / 2
			self.ropeVisual.Size = Vector3.new(ROPE_THICKNESS, ROPE_THICKNESS, currentDist)
			self.ropeVisual.CFrame = CFrame.lookAt(midpoint, charPos2)
		end

		-- Pull the player toward the anchor. We set the velocity directly rather
		-- than lerping — when PlatformStand is on the Humanoid no longer resists
		-- gravity, so the character would drop before a gradual lerp could ramp
		-- up enough to counter it. Setting velocity outright each frame means
		-- gravity never gets a chance to pull the player down; the full PULL_SPEED
		-- is applied immediately toward the anchor point, including straight up.
		if currentDist > 0.01 then
			local pullDir = (-ropeVec).Unit
			self.hrp.AssemblyLinearVelocity = pullDir * PULL_SPEED
		end
	end)

	-- Track the Heartbeat connection so :Destroy() can disconnect it later.
	self.connections["heartbeat"] = self.heartbeatConn
end

-- Hook:Release()
-- Detaches the grapple and tears down all the physical objects we created in
-- :Attach(). Called when the player releases the key, when they arrive at the
-- anchor, or as part of :Destroy(). After this, the player regains normal
-- movement control and the state returns to Idle so they can fire again.
function Hook:Release()
	-- Only release if we're actively swinging or mid-aim. This prevents
	-- double-release or releasing from Idle.
	if self.state ~= "Swinging" and self.state ~= "Aiming" then
		return
	end

	self.state = "Idle"

	-- Turn PlatformStand back off so the Humanoid's normal movement controller
	-- takes over again. Without this the player would be stuck unable to walk.
	if self.humanoid and self.humanoid.Parent then
		self.humanoid.PlatformStand = false
	end

	-- Tear down every physical object. safeDestroy checks for nil/missing parent
	-- so this won't error even if something was already cleaned up externally.
	safeDestroy(self.ropeVisual)
	safeDestroy(self.ropeConstraint)
	safeDestroy(self.charAttachment)
	safeDestroy(self.anchorAttachment)
	safeDestroy(self.anchorPart)

	-- Nil out the references so we don't accidentally operate on dead instances
	-- and so the garbage collector can reclaim them.
	self.ropeVisual = nil
	self.ropeConstraint = nil
	self.charAttachment = nil
	self.anchorAttachment = nil
	self.anchorPart = nil

	-- Stop the per-frame update loop.
	if self.heartbeatConn then
		self.heartbeatConn:Disconnect()
		self.heartbeatConn = nil
	end
	self.connections["heartbeat"] = nil
end

-- Hook:Destroy()
-- Full teardown. This is the final cleanup that happens when a character dies
-- or a player leaves the game. It inlines the release logic (rather than calling
-- :Release()) because we want to force cleanup regardless of the current state
-- and avoid the state guard in :Release(). After this runs the Hook instance
-- is dead and should not be used again.
function Hook:Destroy()
	-- If a grapple is active, clean up all the physical objects inline.
	-- We don't call :Release() here because its state guard could skip cleanup
	-- if the state happened to be something unexpected.
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

	-- Disconnect anything still in the connections table.
	cleanupTable(self.connections)

	-- The Died listener is stored separately (not in self.connections) so we
	-- disconnect it explicitly here.
	if self.diedConn then
		self.diedConn:Disconnect()
		self.diedConn = nil
	end

	-- Drop all references so the Hook can be garbage collected. If we left these
	-- pointing at the old character/humanoid we'd have a lingering reference
	-- keeping the old character model in memory.
	self.player = nil
	self.character = nil
	self.humanoid = nil
	self.hrp = nil
end

-- ============================================================================
-- MAIN FUNCTIONALITY
-- ============================================================================

--==[ PLAYER HOOK MANAGEMENT ]==--

-- One Hook per player. We use a dictionary keyed by the Player object so we
-- can look up the active hook in O(1) when a RemoteEvent comes in.
local playerHooks = {}

-- Called whenever a player's character (re)spawns. We tear down the old Hook
-- if one still exists (safety against double-spawn edge cases) then create a
-- fresh one bound to the new character. This ensures the Hook always points at
-- valid, current Humanoid/HRP references.
local function onCharacterAdded(player, character)
	if playerHooks[player] then
		playerHooks[player]:Destroy()
		playerHooks[player] = nil
	end
	playerHooks[player] = Hook.new(player, character)
end

-- Called when a player leaves. Destroys their Hook so we don't leak parts,
-- connections, or references. If we skipped this, the Hook and its Heartbeat
-- loop would keep running against a character that's no longer in the game.
local function onPlayerRemoving(player)
	if playerHooks[player] then
		playerHooks[player]:Destroy()
		playerHooks[player] = nil
	end
end

--==[ REMOTE EVENT HANDLER ]==--

-- This is where the client's intent reaches the server. The client fires the
-- RemoteEvent with two arguments:
--   action    — "Fire" or "Release"
--   direction — a Vector3 world-space aim direction (only meaningful for "Fire")
--
-- All the actual physics, raycasting, and state changes happen server-side.
-- The client only expresses intent; the server validates and executes. This
-- means an exploiter can't fake a grapple to an arbitrary position or bypass
-- the max range — the server does its own raycast and ignores anything invalid.
GrappleRemote.OnServerEvent:Connect(function(player, action, direction)
	local hook = playerHooks[player]
	if not hook then
		return
	end

	if action == "Fire" then
		-- Make sure the direction is actually a Vector3 before using it.
		-- If a client sends garbage data we just ignore it rather than erroring.
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

-- Wire up the PlayerAdded/CharacterAdded events. When a new player joins we
-- listen for their character spawning and create a Hook. We also handle the
-- case where the character already exists (common in Studio play solo where
-- the character loads before the script runs).
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	-- If the character is already spawned (Studio hot-reload scenario), set up
	-- the Hook immediately rather than waiting for the next CharacterAdded.
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end)

-- Clean up when a player leaves the game.
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players that were already connected before this script ran. This can
-- happen when hot-reloading scripts in Studio during a play session — the
-- existing players won't trigger PlayerAdded again, so we need to set up their
-- hooks manually.
for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end
