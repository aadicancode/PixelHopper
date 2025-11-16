import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

local gfx = playdate.graphics

-- === Screen and Ground Settings ===
local SCREEN_W, SCREEN_H = 400, 240
local GROUND_WIDTH = 400
local GROUND_HEIGHT = 28
local GROUND_CENTER_Y = 230
local GROUND_TOP = GROUND_CENTER_Y - 14

-- === Physics Constants ===
local GRAVITY = 0.45
local JUMP_VELOCITY = -5.8
local MOVE_SPEED = 3
local LEFT_BOUND = 8
local RIGHT_BOUND = SCREEN_W - 8

-- === Platform + Carrot Tables ===
local platforms = {}
local carrots = {}
local whiteCarrot = nil -- separate white carrot
local carrotCount = 0
local lastWhiteCarrotTime = 0 -- when last white carrot disappeared
local whiteCarrotSpawnDelay = 0 -- delay before next white carrot spawns

-- === Enemy (arrows) table ===
local arrows = {}

-- === Obstacle tables ===
local saws = {}
local wreckingBalls = {}
local cannons = {}
local spikeBalls = {}
local cannonProjectiles = {}

-- === Obstacle spawn control ===
local lastObstacleSpawn = 0
local obstacleSpawnInterval = 0 -- will be set to random 13-17 seconds

-- === Particle system (from earlier) ===
local Particle = {}
Particle.__index = Particle

function Particle.new(x, y)
	local self = setmetatable({}, Particle)
	self.size = math.random(2, 3)
	self.life = 22 -- frames before disappearing
	self.vx = math.random(-2, 2)
	self.vy = math.random(-3, -1)

	local img = gfx.image.new(self.size, self.size)
	gfx.pushContext(img)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 0, self.size, self.size)
	gfx.popContext()

	self.sprite = gfx.sprite.new(img)
	self.sprite:setCenter(0.5, 0.5)
	self.sprite:moveTo(x, y)
	self.sprite:add()

	return self
end

function Particle:update()
	self.life -= 1
	self.sprite:moveBy(self.vx, self.vy)
	self.vy += 0.15 -- gravity

	if self.life <= 0 then
		self.sprite:remove()
		return true
	end
	return false
end

local activeParticles = {}

local function spawnParticles(x, y)
	for i = 1, 7 do
		table.insert(activeParticles, Particle.new(x, y))
	end
end

-------------------------------------------------------
-- === Safe image loader ===
-------------------------------------------------------
local function safeLoad(path)
	local ok, img = pcall(gfx.image.new, path)
	if ok and img then return img end
	return nil
end

-- === Bunny Images ===
local imgRight = safeLoad("images/bunny.png")
local imgHopRight = safeLoad("images/bunnyhop.png")
local imgHopDownRight = safeLoad("images/bunnyhopdown.png")

if not imgRight then
	local p = gfx.image.new(32, 32)
	gfx.pushContext(p)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 0, 32, 32)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawText("?", 10, 6)
	gfx.popContext()
	imgRight = p
end
if not imgHopRight then imgHopRight = imgRight end
if not imgHopDownRight then imgHopDownRight = imgHopRight end

local imgLeft = imgRight:scaledImage(-1, 1)
local imgHopLeft = imgHopRight:scaledImage(-1, 1)
local imgHopDownLeft = imgHopDownRight:scaledImage(-1, 1)

-- === Carrot Images ===
local carrotImg = safeLoad("images/carrot.png")
local whiteCarrotImg = safeLoad("images/whitecarrot.png")

-- === Arrow enemy image ===
local arrowImg = safeLoad("images/arrow.png")
if not arrowImg then
	-- placeholder arrow if image missing
	local p = gfx.image.new(12, 12)
	gfx.pushContext(p)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 5, 12, 2)
		gfx.fillRect(8, 2, 4, 8)
	gfx.popContext()
	arrowImg = p
end

-------------------------------------------------------
-- === Carrot System (safe + flashing + bounce) ===
-------------------------------------------------------
local function createCarrot(x, y, isWhite)
	local img = isWhite and whiteCarrotImg or carrotImg
	if not img then return nil end
	
	local carrot = gfx.sprite.new(img)
	carrot:setCenter(0.5, 1)
	carrot:moveTo(x, y)
	carrot.baseY = y
	carrot.isWhite = isWhite
	carrot:add()

	-- ✨ Flashing white carrot effect
	if isWhite then
		local visible = true
		carrot.flashTimer = playdate.timer.new(200, function()
			if not carrot or carrot.removed then return end
			visible = not visible
			if visible then carrot:setImage(whiteCarrotImg)
			else carrot:setImage(nil) end
		end)
		carrot.flashTimer.repeats = true
	end

	-- ✨ Bouncing motion (for all carrots)
	local phase = math.random() * math.pi * 2
	carrot.bounceTimer = playdate.timer.new(30, function()
		if carrot and not carrot.removed then
			local offset = math.sin(playdate.getCurrentTimeMilliseconds() / 400 + phase) * 2
			carrot:moveTo(x, carrot.baseY + offset)
		end
	end)
	carrot.bounceTimer.repeats = true

	return carrot
end

-- Check if a position overlaps with any platform
local function isPositionOnPlatform(x, y)
	-- Check each platform
	for _, plat in ipairs(platforms) do
		local px, py = plat:getPosition()
		local pw, ph = plat:getSize()
		local pLeft = px - pw/2
		local pRight = px + pw/2
		local pTop = py - ph/2
		local pBottom = py + ph/2
		
		-- Check if point is within platform bounds (with small margin for carrot size)
		local carrotMargin = 10
		if x >= pLeft - carrotMargin and x <= pRight + carrotMargin and
		   y >= pTop - carrotMargin and y <= pBottom + carrotMargin then
			return true
		end
	end
	
	-- Also check ground
	if y >= GROUND_TOP - 10 then
		return true
	end
	
	return false
end

-- Find a valid spawn position (not on platforms)
local function findValidSpawnPosition()
	local margin = 20
	local maxAttempts = 50
	local x, y
	
	for i = 1, maxAttempts do
		x = math.random(margin, SCREEN_W - margin)
		y = math.random(margin, GROUND_TOP - margin)
		
		if not isPositionOnPlatform(x, y) then
			return x, y
		end
	end
	
	-- If we couldn't find a valid position after many attempts, return a default
	return SCREEN_W / 2, 50
end

-- Spawn a black carrot (always present)
local function spawnBlackCarrot()
	-- Remove existing black carrots
	for i = #carrots, 1, -1 do
		local c = carrots[i]
		if c and not c.isWhite then
			if c.flashTimer then c.flashTimer:remove() end
			if c.bounceTimer then c.bounceTimer:remove() end
			c:remove()
			table.remove(carrots, i)
		end
	end

	-- Find a valid spawn position (not on platforms)
	local x, y = findValidSpawnPosition()
	local carrot = createCarrot(x, y, false)
	if carrot then
		table.insert(carrots, carrot)
	end
end

-- Spawn a white carrot (temporary, disappears after 5 seconds)
local function spawnWhiteCarrot()
	-- Remove existing white carrot
	if whiteCarrot then
		if whiteCarrot.flashTimer then whiteCarrot.flashTimer:remove() end
		if whiteCarrot.bounceTimer then whiteCarrot.bounceTimer:remove() end
		whiteCarrot:remove()
		whiteCarrot = nil
	end

	-- Find a valid spawn position (not on platforms)
	local x, y = findValidSpawnPosition()
	local carrot = createCarrot(x, y, true)
	if carrot then
		whiteCarrot = carrot
		carrot.spawnTime = playdate.getCurrentTimeMilliseconds()
	end
end

-- Remove white carrot (called when it times out or is collected)
local function removeWhiteCarrot()
	if whiteCarrot then
		if whiteCarrot.flashTimer then whiteCarrot.flashTimer:remove() end
		if whiteCarrot.bounceTimer then whiteCarrot.bounceTimer:remove() end
		whiteCarrot:remove()
		whiteCarrot = nil
		lastWhiteCarrotTime = playdate.getCurrentTimeMilliseconds()
		whiteCarrotSpawnDelay = 10000 + math.random(5000) -- 10-15 seconds
	end
end

-------------------------------------------------------
-- === Ground Sprite ===
-------------------------------------------------------
local groundImage = gfx.image.new(GROUND_WIDTH, GROUND_HEIGHT)
gfx.pushContext(groundImage)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 0, GROUND_WIDTH, GROUND_HEIGHT)
gfx.popContext()
local ground = gfx.sprite.new(groundImage)
ground:setCollideRect(0, 0, GROUND_WIDTH, GROUND_HEIGHT)
ground:moveTo(SCREEN_W / 2, GROUND_CENTER_Y)
ground:add()

-- === Platforms ===
local platformData = {
	{ x = 75, y = 170, w = 30, h = 10 },
	{ x = 200, y = 170, w = 60, h = 10 },
	{ x = 325, y = 170, w = 30, h = 10 },
	{ x = 120, y = 120, w = 60, h = 10 },
	{ x = 280, y = 120, w = 60, h = 10 },
	{ x = 200, y = 70,  w = 60, h = 10 },
	{ x = 75, y = 70,  w = 30, h = 10 },
	{ x = 325, y = 70,  w = 30, h = 10 },
}

for _, p in ipairs(platformData) do
	local img = gfx.image.new(p.w, p.h)
	gfx.pushContext(img)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 0, p.w, p.h)
	gfx.popContext()
	local plat = gfx.sprite.new(img)
	plat:setCollideRect(0, 0, p.w, p.h)
	plat:moveTo(p.x, p.y + p.h / 2)
	plat:add()
	table.insert(platforms, plat)
end

math.randomseed(playdate.getSecondsSinceEpoch())
spawnBlackCarrot()
lastWhiteCarrotTime = playdate.getCurrentTimeMilliseconds()
whiteCarrotSpawnDelay = 10000 + math.random(5000) -- initial delay 10-15 seconds

-- === Bunny ===
local bunny = gfx.sprite.new(imgRight)
bunny:setCenter(0.5, 1.0)
bunny:moveTo(SCREEN_W / 2, GROUND_TOP)
bunny:add()

local bw, bh = imgRight:getSize()
bunny:setCollideRect(6, bh - 22, 20, 22)

-- === State ===
local yVelocity = 0
local isOnGround = true
local facing = "right"
local showDebug = true
local jumpPressedTime = 0
local useHopDown = false  -- Track which walking animation to use (hop or hopdown)
local lastWalkAnimationTime = 0  -- Time when we last switched walking animation

-- === Game state management ===
local gameState = "mainmenu" -- "mainmenu" | "playing" | "dead" | "menu" | "leaderboard"
local startTimeMs = playdate.getCurrentTimeMilliseconds()
local elapsedTime = 0.0

-- === Enemy spawn control ===
local lastArrowSpawn = playdate.getCurrentTimeMilliseconds()
local arrowSpawnInterval = 1500 -- ms (every 1.5s at start)

-- Difficulty progression (simple): spawn faster over time
local function getSpawnInterval()
	-- cap min interval
	local t = (playdate.getCurrentTimeMilliseconds() - startTimeMs) / 1000
	local speedup = math.max(0, math.min(1000, math.floor(t * 40))) -- reduce interval slowly
	return math.max(500, arrowSpawnInterval - speedup) -- min 500ms
end

-- === Obstacle Speed Variables (configurable) ===
local SAW_SPEED = 2.0
local SAW_ROTATION_SPEED = 5.0 -- degrees per frame
local WRECKING_BALL_ROTATION_SPEED = 0.05 -- radians per frame
local WRECKING_BALL_CHAIN_LENGTH = 50
local SPIKE_BALL_VERTICAL_SPEED = 2.0
local SPIKE_BALL_DIAGONAL_SPEED = 2.5
local SPIKE_BALL_ROTATION_SPEED = 4.0 -- degrees per frame
local CANNON_PROJECTILE_SPEED = 3.0
local CANNON_FIRE_INTERVAL = 2000 -- milliseconds between shots

-- === High score storage (using Playdate datastore) ===
local highScore = 0
local highTime = 0.0  -- Time from the same run as high score
local lastScore = 0
local lastTime = 0.0

local function loadHighScore()
	local data = playdate.datastore.read("highScore")
	if data and type(data) == "number" then
		highScore = data
	end
end

local function saveHighScore()
	playdate.datastore.write(highScore, "highScore")
end

local function loadHighTime()
	local data = playdate.datastore.read("highTime")
	if data and type(data) == "number" then
		highTime = data
	end
end

local function saveHighTime()
	playdate.datastore.write(highTime, "highTime")
end

loadHighScore()
loadHighTime()

-- === Multiplayer Leaderboard (using Playdate Scoreboard API) ===
-- Note: To use leaderboards, you need to:
-- 1. Set up scoreboards in the Playdate Developer Portal for your game
-- 2. Ensure your game has a valid bundle ID configured
-- 3. The board ID (SCORE_BOARD_ID) should match the board ID created in the portal
-- 4. Leaderboards will only work when the game is published/connected to Playdate servers
local LEADERBOARD_ENABLED = true -- Set to false to disable leaderboard features

local leaderboard = {} -- Array of {score, time, playerName, rank}
local leaderboardLoading = false
local leaderboardError = nil
local leaderboardScrollOffset = 0
local maxLeaderboardEntries = 10

-- Board IDs - these should match the board IDs configured in your pdxinfo
local SCORE_BOARD_ID = "pixelhopper_scores" -- Main score leaderboard
local TIME_BOARD_ID = "pixelhopper_times" -- Time leaderboard (optional)

-- Send score to Playdate leaderboard
local function submitScoreToLeaderboard(score, time)
	if not LEADERBOARD_ENABLED then return end
	
	-- Submit score to the main scoreboard
	playdate.scoreboards.addScore(SCORE_BOARD_ID, score, function(error)
		if error then
			-- Handle error silently or log it
		else
			-- Success - refresh leaderboard
			fetchLeaderboard()
		end
	end)
end

-- Fetch leaderboard from Playdate servers
local function fetchLeaderboard()
	if not LEADERBOARD_ENABLED then return end
	
	leaderboardLoading = true
	leaderboardError = nil
	
	-- Get top scores from the scoreboard
	playdate.scoreboards.getScores(SCORE_BOARD_ID, maxLeaderboardEntries, function(scores, error)
		leaderboardLoading = false
		if error then
			leaderboardError = "Failed to load"
			leaderboard = {}
		elseif scores then
			-- Convert Playdate scoreboard format to our format
			leaderboard = {}
			for i, scoreEntry in ipairs(scores) do
				table.insert(leaderboard, {
					rank = i,
					playerName = scoreEntry.playerName or "Player",
					score = scoreEntry.value or 0,
					time = 0 -- Time not stored in scoreboard, would need separate board
				})
			end
			leaderboardError = nil
		else
			leaderboard = {}
			leaderboardError = nil
		end
	end)
end

-- === UI / Menu selection for death screen ===
local menuOptions = { "RESTART", "LEADERBOARD" }
local menuSelection = 1

-- === Utility: spawn an arrow at x, with vy ===
local function spawnArrowAt(x, vy)
	local a = {}
	a.img = arrowImg
	a.sprite = gfx.sprite.new(a.img)
	a.sprite:setCenter(0.5, 0)
	-- Start above screen, will slide down
	local arrowWidth, arrowHeight = arrowImg:getSize()
	a.startY = -arrowHeight
	a.targetY = 4 -- position where tip becomes visible
	a.sprite:moveTo(x, a.startY)
	a.sprite:add()
	a.vx = 0
	a.vy = vy or 2.5 -- same fall speed for all
	a.startTime = playdate.getCurrentTimeMilliseconds() -- track when arrow was created
	a.slideDuration = 1000 -- slide animation takes 1 second
	a.isSlidingIn = true -- flag to track if arrow is sliding in from top
	table.insert(arrows, a)
end

-- spawn a single arrow at a random position
local function spawnRandomArrow()
	-- Only spawn if there are no arrows currently
	if #arrows == 0 then
		local margin = 12
		local x = math.random(margin, SCREEN_W - margin)
		spawnArrowAt(x, 2.5)
	end
end

-------------------------------------------------------
-- === Obstacle Flashing Effect System ===
-------------------------------------------------------
local function startFlashingEffect(obstacle, sprite)
	obstacle.isFlashing = true
	obstacle.flashStartTime = playdate.getCurrentTimeMilliseconds()
	obstacle.flashDuration = 2000 -- 2 seconds
	obstacle.flashVisible = true
	
	-- Create timer to toggle visibility
	obstacle.flashTimer = playdate.timer.new(200, function()
		if obstacle and not obstacle.removed then
			obstacle.flashVisible = not obstacle.flashVisible
			if sprite then
				if obstacle.flashVisible then
					sprite:setVisible(true)
				else
					sprite:setVisible(false)
				end
			end
		end
	end)
	obstacle.flashTimer.repeats = true
end

local function updateFlashingEffect(obstacle, sprite)
	if obstacle.isFlashing then
		local now = playdate.getCurrentTimeMilliseconds()
		if now - obstacle.flashStartTime >= obstacle.flashDuration then
			-- Flash complete, make obstacle active
			obstacle.isFlashing = false
			if obstacle.flashTimer then
				obstacle.flashTimer:remove()
				obstacle.flashTimer = nil
			end
			if sprite then
				sprite:setVisible(true)
			end
		end
	end
end

-------------------------------------------------------
-- === Obstacle Creation Functions ===
-------------------------------------------------------

-- Create a saw obstacle
local function createSaw(x, y)
	local sawSize = 24
	local img = safeLoad("images/saw.png")
	if not img then
		-- Placeholder: create a simple saw image
		img = gfx.image.new(sawSize, sawSize)
		gfx.pushContext(img)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(sawSize/2, sawSize/2, sawSize/2)
			gfx.setColor(gfx.kColorWhite)
			gfx.fillCircleAtPoint(sawSize/2, sawSize/2, sawSize/2 - 2)
			-- Draw teeth
			for i = 0, 7 do
				local angle = i * math.pi / 4
				local x1 = sawSize/2 + math.cos(angle) * (sawSize/2 - 2)
				local y1 = sawSize/2 + math.sin(angle) * (sawSize/2 - 2)
				local x2 = sawSize/2 + math.cos(angle) * (sawSize/2)
				local y2 = sawSize/2 + math.sin(angle) * (sawSize/2)
				gfx.setColor(gfx.kColorBlack)
				gfx.drawLine(x1, y1, x2, y2)
			end
		gfx.popContext()
	end
	
	local sprite = gfx.sprite.new(img)
	sprite:setCenter(0.5, 0.5)
	-- Set collision rectangle to match actual saw size (24x24)
	-- Center the collision rect around the sprite center
	local collisionSize = sawSize * 0.8 -- Slightly smaller than visual for better feel
	sprite:setCollideRect(-collisionSize/2, -collisionSize/2, collisionSize, collisionSize)
	sprite:moveTo(x, y)
	sprite:add()
	
	-- Set initial direction (random left or right on ground)
	local direction = (math.random() > 0.5) and 1 or -1
	
	local saw = {
		sprite = sprite,
		state = "ground", -- "ground", "wallUp", "top", "wallDown"
		x = x,
		y = y,
		direction = direction, -- horizontal direction: 1 = right, -1 = left
		wallSide = nil, -- which wall was hit: "left" or "right"
		rotation = 0, -- rotation angle in degrees
		isFlashing = false,
		removed = false
	}
	
	startFlashingEffect(saw, sprite)
	return saw
end

-- Create a wrecking ball
local function createWreckingBall(anchorX, anchorY)
	local ballSize = 20
	-- Always create placeholder (no image loading for wrecking balls)
	local img = gfx.image.new(ballSize, ballSize)
	gfx.pushContext(img)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(ballSize/2, ballSize/2, ballSize/2)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(ballSize/2, ballSize/2, ballSize/2 - 2)
	gfx.popContext()
	
	local sprite = gfx.sprite.new(img)
	sprite:setCenter(0.5, 0.5)
	
	-- Set initial angle first, then position ball at that angle
	local initialAngle = math.random() * math.pi * 2
	local initialX = anchorX + math.cos(initialAngle) * WRECKING_BALL_CHAIN_LENGTH
	local initialY = anchorY + math.sin(initialAngle) * WRECKING_BALL_CHAIN_LENGTH
	sprite:moveTo(initialX, initialY)
	sprite:add()
	
	local ball = {
		sprite = sprite,
		anchorX = anchorX,
		anchorY = anchorY,
		angle = initialAngle,
		isFlashing = false,
		removed = false
	}
	
	startFlashingEffect(ball, sprite)
	return ball
end

-- Create a cannon
local function createCannon(x, y, facing)
	-- facing: "left" or "right"
	local cannonWidth = 24
	local cannonHeight = 16
	local img = safeLoad("images/cannon.png")
	if not img then
		-- Placeholder: create a simple cannon image
		img = gfx.image.new(cannonWidth, cannonHeight)
		gfx.pushContext(img)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(0, 0, cannonWidth, cannonHeight)
			gfx.setColor(gfx.kColorWhite)
			gfx.fillRect(2, 2, cannonWidth - 4, cannonHeight - 4)
			-- Cannon barrel
			if facing == "right" then
				gfx.setColor(gfx.kColorBlack)
				gfx.fillRect(cannonWidth - 8, cannonHeight/2 - 2, 8, 4)
			else
				gfx.setColor(gfx.kColorBlack)
				gfx.fillRect(0, cannonHeight/2 - 2, 8, 4)
			end
		gfx.popContext()
		if facing == "left" then
			img = img:scaledImage(-1, 1)
		end
	else
		-- Flip the loaded image if facing left
		if facing == "left" then
			img = img:scaledImage(-1, 1)
		end
	end
	
	local sprite = gfx.sprite.new(img)
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:add()
	
	local cannon = {
		sprite = sprite,
		x = x,
		y = y,
		facing = facing,
		lastFireTime = playdate.getCurrentTimeMilliseconds(),
		isFlashing = false,
		removed = false
	}
	
	startFlashingEffect(cannon, sprite)
	return cannon
end

-- Create a spike ball
local function createSpikeBall(type, x, y)
	-- type: "vertical", "diagonal1", "diagonal2"
	local ballSize = 18
	local img = safeLoad("images/spikeball.png")
	if not img then
		-- Placeholder: create a simple spiky ball image
		img = gfx.image.new(ballSize, ballSize)
		gfx.pushContext(img)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(ballSize/2, ballSize/2, ballSize/2)
			-- Draw spikes
			for i = 0, 7 do
				local angle = i * math.pi / 4
				local x1 = ballSize/2 + math.cos(angle) * (ballSize/2 - 2)
				local y1 = ballSize/2 + math.sin(angle) * (ballSize/2 - 2)
				local x2 = ballSize/2 + math.cos(angle) * (ballSize/2 + 2)
				local y2 = ballSize/2 + math.sin(angle) * (ballSize/2 + 2)
				gfx.setColor(gfx.kColorWhite)
				gfx.drawLine(x1, y1, x2, y2)
			end
		gfx.popContext()
	end
	
	local sprite = gfx.sprite.new(img)
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:add()
	
	local spikeBall = {
		sprite = sprite,
		type = type,
		x = x,
		y = y,
		vx = 0,
		vy = 0,
		startX = x,
		startY = y,
		rotation = 0, -- rotation angle in degrees
		isFlashing = false,
		removed = false
	}
	
	-- Set initial velocity based on type
	if type == "vertical" then
		spikeBall.vy = SPIKE_BALL_VERTICAL_SPEED
	elseif type == "diagonal1" then
		spikeBall.vx = SPIKE_BALL_DIAGONAL_SPEED
		spikeBall.vy = -SPIKE_BALL_DIAGONAL_SPEED
	elseif type == "diagonal2" then
		spikeBall.vx = -SPIKE_BALL_DIAGONAL_SPEED
		spikeBall.vy = -SPIKE_BALL_DIAGONAL_SPEED
	end
	
	startFlashingEffect(spikeBall, sprite)
	return spikeBall
end

-- Create a cannon projectile
local function createCannonProjectile(x, y, direction)
	-- direction: 1 for right, -1 for left
	local projSize = 8
	local img = safeLoad("images/cannonball.png")
	if not img then
		-- Placeholder: create a simple projectile image
		img = gfx.image.new(projSize, projSize)
		gfx.pushContext(img)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(projSize/2, projSize/2, projSize/2)
		gfx.popContext()
	end
	
	local sprite = gfx.sprite.new(img)
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:add()
	
	local projectile = {
		sprite = sprite,
		x = x,
		y = y,
		vx = direction * CANNON_PROJECTILE_SPEED,
		vy = 0,
		removed = false
	}
	
	return projectile
end

-------------------------------------------------------
-- === Obstacle Update Functions ===
-------------------------------------------------------

-- Update saw movement
local function updateSaw(saw)
	if saw.removed or not saw.sprite then return end
	
	updateFlashingEffect(saw, saw.sprite)
	
	-- Always rotate the saw
	saw.rotation = (saw.rotation + SAW_ROTATION_SPEED) % 360
	saw.sprite:setRotation(saw.rotation)
	
	-- Only move if not flashing
	if not saw.isFlashing then
		local sawRadius = 12 -- Half of saw size (24/2)
		
		if saw.state == "ground" then
			-- Move horizontally on ground
			saw.y = GROUND_TOP - sawRadius -- Lock y position to ground
			saw.x += saw.direction * SAW_SPEED
			saw.sprite:moveTo(saw.x, saw.y)
			
			-- Check if hit a wall, then go up
			if saw.x <= LEFT_BOUND + sawRadius then
				saw.x = LEFT_BOUND + sawRadius
				saw.wallSide = "left"
				saw.state = "wallUp"
			elseif saw.x >= RIGHT_BOUND - sawRadius then
				saw.x = RIGHT_BOUND - sawRadius
				saw.wallSide = "right"
				saw.state = "wallUp"
			end
		elseif saw.state == "wallUp" then
			-- Move vertically upward along the wall
			saw.y -= SAW_SPEED
			saw.sprite:moveTo(saw.x, saw.y)
			
			-- Check if hit the top, then move horizontally
			if saw.y <= 20 + sawRadius then
				saw.y = 20 + sawRadius
				saw.state = "top"
				-- Move in opposite direction from ground movement
				saw.direction = -saw.direction
			end
		elseif saw.state == "top" then
			-- Move horizontally along the top
			saw.y = 20 + sawRadius -- Lock y position to top
			saw.x += saw.direction * SAW_SPEED
			saw.sprite:moveTo(saw.x, saw.y)
			
			-- Check if hit a wall, then go down
			if saw.x <= LEFT_BOUND + sawRadius then
				saw.x = LEFT_BOUND + sawRadius
				saw.wallSide = "left"
				saw.state = "wallDown"
			elseif saw.x >= RIGHT_BOUND - sawRadius then
				saw.x = RIGHT_BOUND - sawRadius
				saw.wallSide = "right"
				saw.state = "wallDown"
			end
		elseif saw.state == "wallDown" then
			-- Move vertically downward along the wall
			saw.y += SAW_SPEED
			saw.sprite:moveTo(saw.x, saw.y)
			
			-- Check if hit the ground, then move horizontally
			if saw.y >= GROUND_TOP - sawRadius then
				saw.y = GROUND_TOP - sawRadius
				saw.state = "ground"
				-- Move in opposite direction from top movement
				saw.direction = -saw.direction
			end
		end
	end
end

-- Update wrecking ball rotation
local function updateWreckingBall(ball)
	if ball.removed or not ball.sprite then return end
	
	updateFlashingEffect(ball, ball.sprite)
	
	-- Only rotate if not flashing
	if not ball.isFlashing then
		ball.angle += WRECKING_BALL_ROTATION_SPEED
		local x = ball.anchorX + math.cos(ball.angle) * WRECKING_BALL_CHAIN_LENGTH
		local y = ball.anchorY + math.sin(ball.angle) * WRECKING_BALL_CHAIN_LENGTH
		ball.sprite:moveTo(x, y)
	end
end

-- Update cannon (fire projectiles)
local function updateCannon(cannon)
	if cannon.removed or not cannon.sprite then return end
	
	updateFlashingEffect(cannon, cannon.sprite)
	
	-- Only fire if not flashing
	if not cannon.isFlashing then
		local now = playdate.getCurrentTimeMilliseconds()
		if now - cannon.lastFireTime >= CANNON_FIRE_INTERVAL then
			cannon.lastFireTime = now
			local direction = (cannon.facing == "right") and 1 or -1
			local projectile = createCannonProjectile(cannon.x, cannon.y, direction)
			table.insert(cannonProjectiles, projectile)
		end
	end
end

-- Update spike ball movement
local function updateSpikeBall(spikeBall)
	if spikeBall.removed or not spikeBall.sprite then return end
	
	updateFlashingEffect(spikeBall, spikeBall.sprite)
	
	-- Always rotate the spikeball
	spikeBall.rotation = (spikeBall.rotation + SPIKE_BALL_ROTATION_SPEED) % 360
	spikeBall.sprite:setRotation(spikeBall.rotation)
	
	-- Only move if not flashing
	if not spikeBall.isFlashing then
		if spikeBall.type == "vertical" then
			-- Move vertically, bounce at top/bottom
			spikeBall.y += spikeBall.vy
			spikeBall.sprite:moveTo(spikeBall.x, spikeBall.y)
			
			if spikeBall.y <= 20 then
				spikeBall.y = 20
				spikeBall.vy = SPIKE_BALL_VERTICAL_SPEED
			elseif spikeBall.y >= GROUND_TOP - 9 then
				spikeBall.y = GROUND_TOP - 9
				spikeBall.vy = -SPIKE_BALL_VERTICAL_SPEED
			end
		else
			-- Move diagonally, bounce off screen edges
			spikeBall.x += spikeBall.vx
			spikeBall.y += spikeBall.vy
			spikeBall.sprite:moveTo(spikeBall.x, spikeBall.y)
			
			-- Bounce off horizontal edges
			if spikeBall.x <= LEFT_BOUND + 9 then
				spikeBall.x = LEFT_BOUND + 9
				spikeBall.vx = -spikeBall.vx
			elseif spikeBall.x >= RIGHT_BOUND - 9 then
				spikeBall.x = RIGHT_BOUND - 9
				spikeBall.vx = -spikeBall.vx
			end
			
			-- Bounce off vertical edges
			if spikeBall.y <= 20 then
				spikeBall.y = 20
				spikeBall.vy = -spikeBall.vy
			elseif spikeBall.y >= GROUND_TOP - 9 then
				spikeBall.y = GROUND_TOP - 9
				spikeBall.vy = -spikeBall.vy
			end
		end
	end
end

-- Update cannon projectiles
local function updateCannonProjectile(projectile)
	if projectile.removed or not projectile.sprite then return end
	
	projectile.x += projectile.vx
	projectile.sprite:moveTo(projectile.x, projectile.y)
	
	-- Remove if off screen
	if projectile.x < -20 or projectile.x > SCREEN_W + 20 then
		projectile.sprite:remove()
		projectile.removed = true
	end
end

-------------------------------------------------------
-- === Obstacle Spawn System ===
-------------------------------------------------------

-- Define cannon positions (6 total: 2 per level, left and right)
local CANNON_POSITIONS = {
	{ x = LEFT_BOUND, y = 160, facing = "right" },  -- Ground left
	{ x = RIGHT_BOUND, y = 160, facing = "left" },  -- Ground right
	{ x = LEFT_BOUND, y = 110, facing = "right" },  -- Middle left
	{ x = RIGHT_BOUND, y = 110, facing = "left" },  -- Middle right
	{ x = LEFT_BOUND, y = 60, facing = "right" },   -- Top left
	{ x = RIGHT_BOUND, y = 60, facing = "left" },   -- Top right
}

-- Define spike ball types
local SPIKE_BALL_TYPES = {
	{ type = "vertical", x = SCREEN_W / 2, y = 120 },
	{ type = "diagonal1", x = SCREEN_W / 2, y = 120 },
	{ type = "diagonal2", x = SCREEN_W / 2, y = 120 },
}

-- Spawn a saw
local function spawnSaw()
	if #saws >= 3 then return end -- Max 3 saws
	
	-- Always spawn on ground at random position
	local sawRadius = 12 -- Half of saw size (24/2)
	local x = math.random(LEFT_BOUND + sawRadius, RIGHT_BOUND - sawRadius)
	local y = GROUND_TOP - sawRadius
	
	local saw = createSaw(x, y)
	if saw then
		table.insert(saws, saw)
	end
end

-- Spawn a wrecking ball
local function spawnWreckingBall()
	if #wreckingBalls >= 3 then return end -- Max 3 wrecking balls
	
	-- Find a platform to attach to (simplified - check if platform is actually occupied)
	local availablePlatforms = {}
	for _, plat in ipairs(platforms) do
		local px, py = plat:getPosition()
		-- Check if this platform is already used by an active wrecking ball
		local used = false
		for _, ball in ipairs(wreckingBalls) do
			if ball and ball.sprite and not ball.removed then
				if math.abs(ball.anchorX - px) < 5 and math.abs(ball.anchorY - py) < 5 then
					used = true
					break
				end
			end
		end
		if not used then
			table.insert(availablePlatforms, { x = px, y = py - 5 })
		end
	end
	
	-- If no specific platforms available, pick a random one anyway (shouldn't happen, but safety)
	if #availablePlatforms > 0 then
		local platform = availablePlatforms[math.random(1, #availablePlatforms)]
		local ball = createWreckingBall(platform.x, platform.y)
		if ball then
			table.insert(wreckingBalls, ball)
		end
	elseif #platforms > 0 then
		-- Fallback: use any random platform
		local plat = platforms[math.random(1, #platforms)]
		local px, py = plat:getPosition()
		local ball = createWreckingBall(px, py - 5)
		if ball then
			table.insert(wreckingBalls, ball)
		end
	end
end

-- Spawn a cannon
local function spawnCannon()
	if #cannons >= 6 then return end -- Max 6 cannons
	
	-- Find available cannon position (simplified - just check if position is already occupied)
	local availablePositions = {}
	for i, pos in ipairs(CANNON_POSITIONS) do
		local used = false
		for _, cannon in ipairs(cannons) do
			if cannon and cannon.sprite and not cannon.removed then
				if math.abs(cannon.x - pos.x) < 5 and math.abs(cannon.y - pos.y) < 5 then
					used = true
					break
				end
			end
		end
		if not used then
			table.insert(availablePositions, pos)
		end
	end
	
	-- If no specific positions available, just pick a random one from all positions
	-- This ensures we can always spawn if under the limit
	if #availablePositions > 0 then
		local pos = availablePositions[math.random(1, #availablePositions)]
		local cannon = createCannon(pos.x, pos.y, pos.facing)
		if cannon then
			table.insert(cannons, cannon)
		end
	else
		-- Fallback: pick any random position if all are "used" (shouldn't happen, but safety check)
		local pos = CANNON_POSITIONS[math.random(1, #CANNON_POSITIONS)]
		local cannon = createCannon(pos.x, pos.y, pos.facing)
		if cannon then
			table.insert(cannons, cannon)
		end
	end
end

-- Spawn a spike ball
local function spawnSpikeBall()
	if #spikeBalls >= 3 then return end -- Max 3 spike balls
	
	-- Allow multiple spike balls of the same type - just pick a random type
	local spikeType = SPIKE_BALL_TYPES[math.random(1, #SPIKE_BALL_TYPES)]
	local ball = createSpikeBall(spikeType.type, spikeType.x, spikeType.y)
	if ball then
		table.insert(spikeBalls, ball)
	end
end

-- Unified obstacle spawn system
local function trySpawnObstacle()
	local now = playdate.getCurrentTimeMilliseconds()
	
	-- Check if it's time to spawn
	if now - lastObstacleSpawn >= obstacleSpawnInterval then
		lastObstacleSpawn = now
		obstacleSpawnInterval = 13000 + math.random(4000) -- 13-17 seconds
		
		-- Build list of available obstacle types
		local availableTypes = {}
		if #saws < 3 then table.insert(availableTypes, "saw") end
		if #wreckingBalls < 3 then table.insert(availableTypes, "wreckingBall") end
		if #cannons < 6 then table.insert(availableTypes, "cannon") end
		if #spikeBalls < 3 then table.insert(availableTypes, "spikeBall") end
		
		if #availableTypes > 0 then
			local obstacleType = availableTypes[math.random(1, #availableTypes)]
			if obstacleType == "saw" then
				spawnSaw()
			elseif obstacleType == "wreckingBall" then
				spawnWreckingBall()
			elseif obstacleType == "cannon" then
				spawnCannon()
			elseif obstacleType == "spikeBall" then
				spawnSpikeBall()
			end
		end
	end
end

-- convenience sprite-setters (defined before use)
local function setStandingSprite()
	if facing == "right" then bunny:setImage(imgRight)
	else bunny:setImage(imgLeft) end
end

local function setHopSprite()
	if facing == "right" then bunny:setImage(imgHopRight)
	else bunny:setImage(imgHopLeft) end
end

local function setFallSprite()
	if facing == "right" then bunny:setImage(imgHopDownRight)
	else bunny:setImage(imgHopDownLeft) end
end

-- reset everything for restart
local function restartGame()
	-- remove arrows
	for i = #arrows, 1, -1 do
		local a = arrows[i]
		if a and a.sprite then a.sprite:remove() end
		table.remove(arrows, i)
	end
	-- remove particles
	for i = #activeParticles, 1, -1 do
		local p = activeParticles[i]
		if p and p.sprite then p.sprite:remove() end
		table.remove(activeParticles, i)
	end
	-- remove carrots
	for i = #carrots, 1, -1 do
		local c = carrots[i]
		if c then
			if c.flashTimer then c.flashTimer:remove() end
			if c.bounceTimer then c.bounceTimer:remove() end
			c:remove()
		end
		table.remove(carrots, i)
	end
	-- remove white carrot
	removeWhiteCarrot()

	-- remove obstacles
	-- remove saws
	for i = #saws, 1, -1 do
		local saw = saws[i]
		if saw then
			if saw.flashTimer then saw.flashTimer:remove() end
			if saw.sprite then saw.sprite:remove() end
		end
		table.remove(saws, i)
	end
	-- remove wrecking balls
	for i = #wreckingBalls, 1, -1 do
		local ball = wreckingBalls[i]
		if ball then
			if ball.flashTimer then ball.flashTimer:remove() end
			if ball.sprite then ball.sprite:remove() end
		end
		table.remove(wreckingBalls, i)
	end
	-- remove cannons
	for i = #cannons, 1, -1 do
		local cannon = cannons[i]
		if cannon then
			if cannon.flashTimer then cannon.flashTimer:remove() end
			if cannon.sprite then cannon.sprite:remove() end
		end
		table.remove(cannons, i)
	end
	-- remove spike balls
	for i = #spikeBalls, 1, -1 do
		local spikeBall = spikeBalls[i]
		if spikeBall then
			if spikeBall.flashTimer then spikeBall.flashTimer:remove() end
			if spikeBall.sprite then spikeBall.sprite:remove() end
		end
		table.remove(spikeBalls, i)
	end
	-- remove cannon projectiles
	for i = #cannonProjectiles, 1, -1 do
		local projectile = cannonProjectiles[i]
		if projectile and projectile.sprite then
			projectile.sprite:remove()
		end
		table.remove(cannonProjectiles, i)
	end

	carrotCount = 0
	startTimeMs = playdate.getCurrentTimeMilliseconds()
	lastArrowSpawn = startTimeMs
	lastObstacleSpawn = 0 -- Reset to trigger immediate spawn
	obstacleSpawnInterval = 0 -- Will be set on first spawn
	gameState = "playing"
	menuSelection = 1
	yVelocity = 0
	isOnGround = true
	useHopDown = false
	lastWalkAnimationTime = 0
	bunny:moveTo(SCREEN_W / 2, GROUND_TOP)
	setStandingSprite()
	spawnBlackCarrot()
	lastWhiteCarrotTime = playdate.getCurrentTimeMilliseconds()
	whiteCarrotSpawnDelay = 10000 + math.random(5000) -- 10-15 seconds
end

local function die()
	-- particle burst at bunny
	local bx, by, bwB, bhB = bunny:getBounds()
	spawnParticles(bx + bwB/2, by + bhB/2)

	-- store last run stats
	lastScore = carrotCount
	lastTime = elapsedTime

	-- update high score and high time together (from same run)
	if carrotCount > highScore then
		highScore = carrotCount
		highTime = elapsedTime  -- Save time from the same run as high score
		saveHighScore()
		saveHighTime()
	end

	-- Submit score to multiplayer leaderboard
	submitScoreToLeaderboard(carrotCount, elapsedTime)

	gameState = "dead"
end

-- Format time as MM:SS:CS
local function formatTime(seconds)
	local minutes = math.floor(seconds / 60)
	local secs = math.floor(seconds % 60)
	local centiseconds = math.floor((seconds % 1) * 100)
	return string.format("%d:%02d:%02d", minutes, secs, centiseconds)
end

-- === Main Loop ===
function playdate.update()
	gfx.clear(gfx.kColorWhite)

	-- update timer (elapsed time) regardless of paused/dead for display
	if gameState == "playing" then
		elapsedTime = (playdate.getCurrentTimeMilliseconds() - startTimeMs) / 1000.0
	end

	-- handle input for menu/state
	if gameState == "mainmenu" then
		-- A or B button starts the game
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			-- Reset current stats and start game
			carrotCount = 0
			elapsedTime = 0.0
			startTimeMs = playdate.getCurrentTimeMilliseconds()
			gameState = "playing"
			restartGame()
		end
	elseif gameState == "dead" then
		-- Up/Down to navigate menu, A to select, B to restart
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			menuSelection = math.max(1, menuSelection - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			menuSelection = math.min(2, menuSelection + 1)
		elseif playdate.buttonJustPressed(playdate.kButtonA) then
			if menuSelection == 1 then
				restartGame()
			elseif menuSelection == 2 then
				-- View leaderboard
				if LEADERBOARD_ENABLED then
					fetchLeaderboard()
					gameState = "leaderboard"
				else
					gameState = "menu"
				end
			end
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			restartGame()
		end
	elseif gameState == "menu" then
		-- A to go back, B to restart
		if playdate.buttonJustPressed(playdate.kButtonA) then
			gameState = "dead"
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			restartGame()
		end
	elseif gameState == "leaderboard" then
		-- A or B to go back to death screen
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			gameState = "dead"
		end
		-- Up/Down to scroll (if needed)
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			leaderboardScrollOffset = math.max(0, leaderboardScrollOffset - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			leaderboardScrollOffset = math.min(math.max(0, #leaderboard - 7), leaderboardScrollOffset + 1)
		end
	else -- playing
		-- debug toggle
		if playdate.buttonJustPressed(playdate.kButtonB) then
			showDebug = not showDebug
		end

		-- movement
		local moved = false
		local bx, by = bunny:getPosition()

		if playdate.buttonIsPressed(playdate.kButtonLeft) then
			facing = "left"
			bunny:moveBy(-MOVE_SPEED, 0)
			moved = true
		elseif playdate.buttonIsPressed(playdate.kButtonRight) then
			facing = "right"
			bunny:moveBy(MOVE_SPEED, 0)
			moved = true
		end

		-- allow mid-air sprite change
		if not isOnGround and moved then
			if yVelocity < 0 then setHopSprite()
			else setFallSprite() end
		end

		-- clamp to screen
		bx, by = bunny:getPosition()
		if bx < LEFT_BOUND then bunny:moveTo(LEFT_BOUND, by)
		elseif bx > RIGHT_BOUND then bunny:moveTo(RIGHT_BOUND, by) end

		-- Jump
		if (playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonUp)) and isOnGround then
			yVelocity = JUMP_VELOCITY
			isOnGround = false
			jumpPressedTime = 0
			setHopSprite()
		end

		-- Hold jump
		if (playdate.buttonIsPressed(playdate.kButtonA) or playdate.buttonIsPressed(playdate.kButtonUp)) and not isOnGround and yVelocity < 0 then
			jumpPressedTime += 1
			if jumpPressedTime < 10 then
				yVelocity -= 0.25
			end
		end

		-- Gravity + platform collisions
		if not isOnGround then
			local wasRising = yVelocity < 0
			yVelocity += GRAVITY
			local steps = math.ceil(math.abs(yVelocity))
			local stepSize = yVelocity / steps

			for i = 1, steps do
				bunny:moveBy(0, stepSize)
				local bx, by = bunny:getPosition()
				for _, plat in ipairs(platforms) do
					local px, py = plat:getPosition()
					local pw, ph = plat:getSize()
					local pLeft, pRight, pTop = px - pw/2, px + pw/2, py - ph/2
					if bx > pLeft and bx < pRight then
						local hitRect = bunny:getCollideRect()
						local hitH = hitRect.height or 22
						local bunnyBottom = by - (hitH / 2) + 10
						local distanceAbove = pTop - bunnyBottom
						if distanceAbove >= -2 and distanceAbove <= 2 and yVelocity >= 0 then
							yVelocity = 0
							isOnGround = true
							local offset = (hitH / 2) - 10
							bunny:moveTo(bx, pTop + offset)
							-- Don't set standing sprite here if moving - let walking animation handle it
							if not moved then
								setStandingSprite()
							end
							break
						end
					end
				end
				if isOnGround then break end
			end

			if (wasRising and yVelocity >= 0) then setFallSprite() end
		end

		-- Ground/platform snap & collisions
		isOnGround = false
		bx, by = bunny:getPosition()
		local bunnyBottom = by
		local hitRect = bunny:getCollideRect()
		local hitH = hitRect.height or 22
		local bunnyBottomHalf = bunnyBottom - (hitH / 2) + 10
		local newGroundTop = nil

		local groundTopY = GROUND_TOP
		if bunnyBottomHalf >= groundTopY and yVelocity >= 0 then
			newGroundTop = groundTopY
			isOnGround = true
		end

		for _, plat in ipairs(platforms) do
			local px, py = plat:getPosition()
			local pw, ph = plat:getSize()
			if px and py and pw and ph then
				local pLeft, pRight, pTop = px - pw/2, px + pw/2, py - ph/2
				if bx > pLeft and bx < pRight then
					local distanceAbove = pTop - bunnyBottomHalf
					if distanceAbove >= -2 and distanceAbove <= 6 and yVelocity >= 0 then
						newGroundTop = pTop
						isOnGround = true
						yVelocity = 0
						break
					end
				end
			end
		end

		if isOnGround and newGroundTop then
			local hitRect = bunny:getCollideRect()
			local hitH = hitRect.height or 22
			local offset = (hitH / 2) - 10
			bunny:moveTo(bx, newGroundTop + offset)
			-- Don't set standing sprite here if moving - let walking animation handle it
			if not moved then
				setStandingSprite()
			end
		end

		-- Switch between hop and hopdown when moving on ground (after ground collision check)
		if moved and isOnGround then
			local currentTime = playdate.getCurrentTimeMilliseconds()
			-- Initialize walking animation if just started moving
			if lastWalkAnimationTime == 0 then
				useHopDown = false
				setHopSprite()
				lastWalkAnimationTime = currentTime
			end
			-- Switch every 0.1 seconds (100 milliseconds)
			if currentTime - lastWalkAnimationTime >= 100 then
				useHopDown = not useHopDown
				lastWalkAnimationTime = currentTime
				if useHopDown then setFallSprite()
				else setHopSprite() end
			end
		elseif not moved and isOnGround then
			-- Use standing bunny when not moving
			useHopDown = false
			lastWalkAnimationTime = 0
			setStandingSprite()
		end

		---------------------------------------------------------------------
		-- Carrot collection
		---------------------------------------------------------------------
		for i = #carrots, 1, -1 do
			local c = carrots[i]
			if c then
				local bx, by, bwC, bhC = bunny:getBounds()
				local cx, cy, cw, ch = c:getBounds()
				local bunnyRect = playdate.geometry.rect.new(bx, by, bwC, bhC)
				local carrotRect = playdate.geometry.rect.new(cx, cy, cw, ch)

				if bunnyRect:intersects(carrotRect) then
					-- particles
					spawnParticles(cx + cw/2, cy + ch/2)

					if c.isWhite then
						carrotCount += 3
						-- Remove white carrot and schedule next one
						removeWhiteCarrot()
					else
						carrotCount += 1
						-- Remove black carrot and spawn new one
						if c.flashTimer then c.flashTimer:remove() end
						if c.bounceTimer then c.bounceTimer:remove() end
						c:remove()
						table.remove(carrots, i)
						spawnBlackCarrot()
					end
				end
			end
		end
		---------------------------------------------------------------------

		-- White carrot collision check
		if whiteCarrot and not whiteCarrot.removed then
			local bx, by, bwC, bhC = bunny:getBounds()
			local cx, cy, cw, ch = whiteCarrot:getBounds()
			local bunnyRect = playdate.geometry.rect.new(bx, by, bwC, bhC)
			local carrotRect = playdate.geometry.rect.new(cx, cy, cw, ch)

			if bunnyRect:intersects(carrotRect) then
				-- particles
				spawnParticles(cx + cw/2, cy + ch/2)
				carrotCount += 3
				removeWhiteCarrot()
			end
		end

		-- White carrot timeout check (8 seconds)
		if whiteCarrot and not whiteCarrot.removed then
			local now = playdate.getCurrentTimeMilliseconds()
			if now - whiteCarrot.spawnTime >= 8000 then
				removeWhiteCarrot()
			end
		end

		-- White carrot spawn check (10-15 seconds after last one disappeared)
		if not whiteCarrot then
			local now = playdate.getCurrentTimeMilliseconds()
			if now - lastWhiteCarrotTime >= whiteCarrotSpawnDelay then
				spawnWhiteCarrot()
			end
		end

		---------------------------------------------------------------------

		-- spawn arrows over time
		local now = playdate.getCurrentTimeMilliseconds()
		if now - lastArrowSpawn >= getSpawnInterval() then
			lastArrowSpawn = now
			spawnRandomArrow()
		end

		-- update arrows
		for i = #arrows, 1, -1 do
			local a = arrows[i]
			if a and a.sprite then
				local now = playdate.getCurrentTimeMilliseconds()
				local ax, ay = a.sprite:getPosition()
				
				-- First phase: slide in from top (takes 1 second)
				if a.isSlidingIn then
					local elapsed = now - a.startTime
					if elapsed >= a.slideDuration then
						-- Slide complete, start falling immediately
						a.sprite:moveTo(ax, a.targetY) -- snap to exact position
						a.isSlidingIn = false
					else
						-- Interpolate position over 1 second
						local progress = elapsed / a.slideDuration
						local currentY = a.startY + (a.targetY - a.startY) * progress
						a.sprite:moveTo(ax, currentY)
						ax, ay = a.sprite:getPosition()
					end
				-- Second phase: falling
				else
					a.sprite:moveBy(a.vx, a.vy)
					ax, ay = a.sprite:getPosition()
				end
				
				-- remove when arrow hits the ground (y=210) or goes offscreen
				if ay >= 210 then
					-- Arrow hit the ground, remove it
					a.sprite:remove()
					table.remove(arrows, i)
				elseif ay > SCREEN_H + 20 then
					-- Arrow went offscreen, remove it
					a.sprite:remove()
					table.remove(arrows, i)
				elseif not a.isSlidingIn then
					-- Only check collision if arrow is falling (not sliding in)
					-- check collision with bunny
					local bx, by, bwB, bhB = bunny:getBounds()
					local axB, ayB, awB, ahB = a.sprite:getBounds()
					local bunnyRect = playdate.geometry.rect.new(bx, by, bwB, bhB)
					local arrowRect = playdate.geometry.rect.new(axB, ayB, awB, ahB)
					if bunnyRect:intersects(arrowRect) then
						-- collide: die
						-- remove arrow
						if a.sprite then a.sprite:remove() end
						table.remove(arrows, i)
						die()
						break
					end
				end
			else
				table.remove(arrows, i)
			end
		end

		---------------------------------------------------------------------
		-- Obstacle spawn system
		---------------------------------------------------------------------
		if lastObstacleSpawn == 0 then
			-- Initialize spawn timer and spawn immediately on first frame
			lastObstacleSpawn = playdate.getCurrentTimeMilliseconds()
			obstacleSpawnInterval = 13000 + math.random(4000) -- 13-17 seconds
			-- Spawn first obstacle immediately
			local availableTypes = {}
			if #saws < 3 then table.insert(availableTypes, "saw") end
			if #wreckingBalls < 3 then table.insert(availableTypes, "wreckingBall") end
			if #cannons < 6 then table.insert(availableTypes, "cannon") end
			if #spikeBalls < 3 then table.insert(availableTypes, "spikeBall") end
			
			if #availableTypes > 0 then
				local obstacleType = availableTypes[math.random(1, #availableTypes)]
				if obstacleType == "saw" then
					spawnSaw()
				elseif obstacleType == "wreckingBall" then
					spawnWreckingBall()
				elseif obstacleType == "cannon" then
					spawnCannon()
				elseif obstacleType == "spikeBall" then
					spawnSpikeBall()
				end
			end
		end
		trySpawnObstacle()

		---------------------------------------------------------------------
		-- Update obstacles
		---------------------------------------------------------------------
		-- Update saws
		for i = #saws, 1, -1 do
			local saw = saws[i]
			if saw and not saw.removed then
				updateSaw(saw)
			else
				table.remove(saws, i)
			end
		end

		-- Update wrecking balls
		for i = #wreckingBalls, 1, -1 do
			local ball = wreckingBalls[i]
			if ball and not ball.removed then
				updateWreckingBall(ball)
			else
				table.remove(wreckingBalls, i)
			end
		end

		-- Update cannons
		for i = #cannons, 1, -1 do
			local cannon = cannons[i]
			if cannon and not cannon.removed then
				updateCannon(cannon)
			else
				table.remove(cannons, i)
			end
		end

		-- Update spike balls
		for i = #spikeBalls, 1, -1 do
			local spikeBall = spikeBalls[i]
			if spikeBall and not spikeBall.removed then
				updateSpikeBall(spikeBall)
			else
				table.remove(spikeBalls, i)
			end
		end

		-- Update cannon projectiles
		for i = #cannonProjectiles, 1, -1 do
			local projectile = cannonProjectiles[i]
			if projectile and not projectile.removed then
				updateCannonProjectile(projectile)
				if projectile.removed then
					table.remove(cannonProjectiles, i)
				end
			else
				table.remove(cannonProjectiles, i)
			end
		end

		---------------------------------------------------------------------
		-- Obstacle collision detection
		---------------------------------------------------------------------
		local bx, by, bwB, bhB = bunny:getBounds()
		local bunnyRect = playdate.geometry.rect.new(bx, by, bwB, bhB)

		-- Check collision with saws
		for i = #saws, 1, -1 do
			local saw = saws[i]
			if saw and saw.sprite and not saw.isFlashing then
				-- Use collision rectangle instead of full bounds for more accurate hitbox
				local sx, sy = saw.sprite:getPosition()
				local sawRadius = 12 * 0.8 -- Match the collision rect size (80% of visual)
				local sawRect = playdate.geometry.rect.new(
					sx - sawRadius, 
					sy - sawRadius, 
					sawRadius * 2, 
					sawRadius * 2
				)
				if bunnyRect:intersects(sawRect) then
					die()
					break
				end
			end
		end

		-- Check collision with wrecking balls
		for i = #wreckingBalls, 1, -1 do
			local ball = wreckingBalls[i]
			if ball and ball.sprite and not ball.isFlashing then
				local wx, wy, ww, wh = ball.sprite:getBounds()
				local ballRect = playdate.geometry.rect.new(wx, wy, ww, wh)
				if bunnyRect:intersects(ballRect) then
					die()
					break
				end
			end
		end

		-- Check collision with spike balls
		for i = #spikeBalls, 1, -1 do
			local spikeBall = spikeBalls[i]
			if spikeBall and spikeBall.sprite and not spikeBall.isFlashing then
				local spx, spy, spw, sph = spikeBall.sprite:getBounds()
				local spikeRect = playdate.geometry.rect.new(spx, spy, spw, sph)
				if bunnyRect:intersects(spikeRect) then
					die()
					break
				end
			end
		end

		-- Check collision with cannon projectiles
		-- Helper function to check if bunny is on a platform (not just ground)
		local function isBunnyOnPlatform()
			if not isOnGround then return false end
			local bx, by = bunny:getPosition()
			local hitRect = bunny:getCollideRect()
			local hitH = hitRect.height or 22
			local bunnyBottomHalf = by - (hitH / 2) + 10
			
			-- Check if bunny is on a platform (not the ground)
			for _, plat in ipairs(platforms) do
				local px, py = plat:getPosition()
				local pw, ph = plat:getSize()
				if px and py and pw and ph then
					local pLeft, pRight, pTop = px - pw/2, px + pw/2, py - ph/2
					if bx > pLeft and bx < pRight then
						local distanceAbove = pTop - bunnyBottomHalf
						if distanceAbove >= -2 and distanceAbove <= 6 then
							return true -- Bunny is on this platform
						end
					end
				end
			end
			return false -- Bunny is on ground, not a platform
		end
		
		for i = #cannonProjectiles, 1, -1 do
			local projectile = cannonProjectiles[i]
			if projectile and projectile.sprite then
				-- Skip collision if bunny is standing on a platform
				if not isBunnyOnPlatform() then
					local px, py, pw, ph = projectile.sprite:getBounds()
					local projRect = playdate.geometry.rect.new(px, py, pw, ph)
					if bunnyRect:intersects(projRect) then
						projectile.sprite:remove()
						table.remove(cannonProjectiles, i)
						die()
						break
					end
				end
			end
		end
	end -- end playing-block

	-- Update particles every frame
	for i = #activeParticles, 1, -1 do
		if activeParticles[i]:update() then
			table.remove(activeParticles, i)
		end
	end

	-- Update sprites & timers
	gfx.sprite.update()
	playdate.timer.updateTimers()

	-- Draw obstacle chains and outlines (only during gameplay)
	if gameState == "playing" then
		-- Draw chains for wrecking balls
		for _, ball in ipairs(wreckingBalls) do
			if ball and ball.sprite and not ball.removed then
				local bx, by = ball.sprite:getPosition()
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(1)
				gfx.drawLine(ball.anchorX, ball.anchorY, bx, by)
			end
		end

		-- Draw outlines for flashing obstacles
		for _, saw in ipairs(saws) do
			if saw and saw.sprite and saw.isFlashing then
				local sx, sy, sw, sh = saw.sprite:getBounds()
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawRect(sx, sy, sw, sh)
			end
		end

		for _, ball in ipairs(wreckingBalls) do
			if ball and ball.sprite and ball.isFlashing then
				local wx, wy, ww, wh = ball.sprite:getBounds()
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawRect(wx, wy, ww, wh)
			end
		end

		for _, cannon in ipairs(cannons) do
			if cannon and cannon.sprite and cannon.isFlashing then
				local cx, cy, cw, ch = cannon.sprite:getBounds()
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawRect(cx, cy, cw, ch)
			end
		end

		for _, spikeBall in ipairs(spikeBalls) do
			if spikeBall and spikeBall.sprite and spikeBall.isFlashing then
				local spx, spy, spw, sph = spikeBall.sprite:getBounds()
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawRect(spx, spy, spw, sph)
			end
		end
	end

	-- draw timer and carrot count (only during gameplay)
	if gameState == "playing" then
		gfx.setColor(gfx.kColorBlack)
		-- Timer at top-left
		gfx.drawText(formatTime(elapsedTime), 8, 8)
		-- Carrot count at top-right
		gfx.drawText("Carrots: " .. carrotCount, SCREEN_W - 100, 8)
	end
	
	-- Draw simple carrot icon (8x8) - white carrot on dark background
	local function drawCarrotIcon(x, y)
		gfx.setColor(gfx.kColorWhite)
		-- Carrot body (orange-ish - using white for visibility)
		gfx.fillRect(x + 2, y + 3, 4, 4)
		-- Carrot top (green stem)
		gfx.fillRect(x + 3, y, 2, 3)
		gfx.fillRect(x + 2, y + 1, 1, 1)
		gfx.fillRect(x + 5, y + 1, 1, 1)
	end
	
	-- Draw simple clock icon (8x8) - white clock on dark background
	local function drawClockIcon(x, y)
		gfx.setColor(gfx.kColorWhite)
		-- Clock face (square approximation of circle)
		gfx.drawRect(x + 1, y + 1, 6, 6)
		-- Clock hands (pointing to 12 o'clock)
		gfx.fillRect(x + 3, y + 2, 2, 2) -- hour hand at 12
		-- Center dot
		gfx.fillRect(x + 3, y + 3, 2, 2)
	end
	
	-- Draw info panel (Poor Bunny style)
	local function drawInfoPanel(x, y, w, h, isBest, score, timeStr)
		-- Panel background
		if isBest then
			-- Dark reddish-purple fill for best panel
			-- Using a pattern to simulate dark purple/red (Playdate is 1-bit, so we use dithering pattern)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(x, y, w, h)
			-- Add some pattern for purple/red effect (using alternating pattern)
			for i = 0, w - 1, 2 do
				for j = 0, h - 1, 2 do
					if (i + j) % 4 == 0 then
						gfx.setColor(gfx.kColorWhite)
						gfx.fillRect(x + i, y + j, 1, 1)
					end
				end
			end
			-- Golden border (thick white border to simulate gold)
			gfx.setColor(gfx.kColorWhite)
			gfx.setLineWidth(3)
			gfx.drawRect(x, y, w, h)
			-- Add inner highlight for gold effect
			gfx.setLineWidth(1)
			gfx.setColor(gfx.kColorWhite)
			gfx.drawRect(x + 2, y + 2, w - 4, h - 4)
		else
			-- Dark grey fill for current panel
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(x, y, w, h)
			-- Add pattern for grey effect
			for i = 0, w - 1, 3 do
				for j = 0, h - 1, 3 do
					if (i + j) % 6 == 0 then
						gfx.setColor(gfx.kColorWhite)
						gfx.fillRect(x + i, y + j, 1, 1)
					end
				end
			end
			-- Grey border (thin white border)
			gfx.setColor(gfx.kColorWhite)
			gfx.setLineWidth(1)
			gfx.drawRect(x, y, w, h)
		end
		gfx.setLineWidth(1)
		gfx.setColor(gfx.kColorBlack)
		
		-- Carrot icon and score (top row)
		drawCarrotIcon(x + 8, y + 6)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawText(tostring(score), x + 20, y + 6)
		
		-- Clock icon and time (bottom row)
		drawClockIcon(x + 8, y + 20)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawText(timeStr, x + 20, y + 20)
	end
	
	-- Draw restart button
	local function drawRestartButton(x, y, size)
		-- Button background (light blue)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(x, y, size, size)
		-- Outer white border
		gfx.setColor(gfx.kColorWhite)
		gfx.setLineWidth(2)
		gfx.drawRect(x, y, size, size)
		-- Inner dark border
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(1)
		gfx.drawRect(x + 2, y + 2, size - 4, size - 4)
		-- Restart arrow (curved arrow pointing counter-clockwise)
		gfx.setColor(gfx.kColorBlack)
		local centerX, centerY = x + size/2, y + size/2
		-- Draw curved arrow
		gfx.setLineWidth(2)
		-- Arrow arc
		for i = 0, 8 do
			local angle = i * math.pi / 4
			local px = centerX + math.cos(angle) * 4
			local py = centerY + math.sin(angle) * 4
			if i == 0 then
				gfx.fillRect(px - 1, py - 1, 2, 2)
			else
				gfx.fillRect(px, py, 1, 1)
			end
		end
		gfx.setLineWidth(1)
	end
	
	-- draw death/menu overlays
	local font = gfx.getFont()
	
	if gameState == "mainmenu" then
		-- Draw background
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Simple text display
		gfx.setColor(gfx.kColorBlack)
		local yPos = 60
		local lineHeight = 30
		
		-- High Score
		local highScoreText = "HIGH SCORE: " .. tostring(highScore)
		local highScoreWidth = font:getTextWidth(highScoreText)
		gfx.drawText(highScoreText, SCREEN_W / 2 - highScoreWidth / 2, yPos)
		
		-- High Timer
		yPos = yPos + lineHeight
		local highTimerText = "HIGH TIMER: " .. formatTime(highTime)
		local highTimerWidth = font:getTextWidth(highTimerText)
		gfx.drawText(highTimerText, SCREEN_W / 2 - highTimerWidth / 2, yPos)
		
		-- Current Score
		yPos = yPos + lineHeight
		local currentScoreText = "CURRENT SCORE: " .. tostring(lastScore)
		local currentScoreWidth = font:getTextWidth(currentScoreText)
		gfx.drawText(currentScoreText, SCREEN_W / 2 - currentScoreWidth / 2, yPos)
		
		-- Current Timer
		yPos = yPos + lineHeight
		local currentTimerText = "CURRENT TIMER: " .. formatTime(lastTime)
		local currentTimerWidth = font:getTextWidth(currentTimerText)
		gfx.drawText(currentTimerText, SCREEN_W / 2 - currentTimerWidth / 2, yPos)
		
		-- Instructions
		yPos = SCREEN_H - 30
		local instText = "A: Start  B: Start"
		local instWidth = font:getTextWidth(instText)
		gfx.drawText(instText, SCREEN_W / 2 - instWidth / 2, yPos)
		
	elseif gameState == "dead" then
		-- Draw background (same as main menu)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Simple text display (same as main menu)
		gfx.setColor(gfx.kColorBlack)
		local yPos = 40
		local lineHeight = 25
		
		-- High Score
		local highScoreText = "HIGH SCORE: " .. tostring(highScore)
		local highScoreWidth = font:getTextWidth(highScoreText)
		gfx.drawText(highScoreText, SCREEN_W / 2 - highScoreWidth / 2, yPos)
		
		-- High Timer
		yPos = yPos + lineHeight
		local highTimerText = "HIGH TIMER: " .. formatTime(highTime)
		local highTimerWidth = font:getTextWidth(highTimerText)
		gfx.drawText(highTimerText, SCREEN_W / 2 - highTimerWidth / 2, yPos)
		
		-- Current Score
		yPos = yPos + lineHeight
		local currentScoreText = "CURRENT SCORE: " .. tostring(lastScore)
		local currentScoreWidth = font:getTextWidth(currentScoreText)
		gfx.drawText(currentScoreText, SCREEN_W / 2 - currentScoreWidth / 2, yPos)
		
		-- Current Timer
		yPos = yPos + lineHeight
		local currentTimerText = "CURRENT TIMER: " .. formatTime(lastTime)
		local currentTimerWidth = font:getTextWidth(currentTimerText)
		gfx.drawText(currentTimerText, SCREEN_W / 2 - currentTimerWidth / 2, yPos)
		
		-- Menu options
		yPos = yPos + lineHeight + 10
		local menuY = yPos
		
		-- RESTART option
		local restartText = "RESTART"
		local restartWidth = font:getTextWidth(restartText)
		if menuSelection == 1 then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - restartWidth / 2 - 5, menuY - 2, restartWidth + 10, 20)
			gfx.setColor(gfx.kColorWhite)
		else
			gfx.setColor(gfx.kColorBlack)
		end
		gfx.drawText(restartText, SCREEN_W / 2 - restartWidth / 2, menuY)
		
		-- LEADERBOARD option
		menuY = menuY + lineHeight
		local leaderboardText = LEADERBOARD_ENABLED and "LEADERBOARD" or "HIGH SCORE"
		local leaderboardWidth = font:getTextWidth(leaderboardText)
		if menuSelection == 2 then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - leaderboardWidth / 2 - 5, menuY - 2, leaderboardWidth + 10, 20)
			gfx.setColor(gfx.kColorWhite)
		else
			gfx.setColor(gfx.kColorBlack)
		end
		gfx.drawText(leaderboardText, SCREEN_W / 2 - leaderboardWidth / 2, menuY)
		
		-- Instructions
		yPos = SCREEN_H - 30
		local instText = "A: Select  B: Restart"
		local instWidth = font:getTextWidth(instText)
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(instText, SCREEN_W / 2 - instWidth / 2, yPos)
		
	elseif gameState == "menu" then
		-- High score screen - same style as death screen
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Best score panel
		drawInfoPanel(20, 40, 200, 30, true, highScore, formatTime(highTime))
		
		-- Current score panel
		drawInfoPanel(20, 80, 200, 30, false, carrotCount, formatTime(elapsedTime))
		
		-- Restart button
		local buttonSize = 32
		local buttonX = SCREEN_W / 2 - buttonSize / 2
		local buttonY = SCREEN_H - buttonSize - 20
		drawRestartButton(buttonX, buttonY, buttonSize)
		
		-- Instructions
		gfx.setColor(gfx.kColorWhite)
		local instText = "A: Back  B: Restart"
		local instWidth = font:getTextWidth(instText)
		gfx.drawText(instText, SCREEN_W / 2 - instWidth / 2, buttonY - 20)
		
	elseif gameState == "leaderboard" then
		-- Leaderboard screen
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Title
		gfx.setColor(gfx.kColorBlack)
		local titleText = "LEADERBOARD"
		local titleWidth = font:getTextWidth(titleText)
		gfx.drawText(titleText, SCREEN_W / 2 - titleWidth / 2, 10)
		
		-- Draw leaderboard entries
		local startY = 40
		local lineHeight = 22
		local maxVisible = 7
		
		if leaderboardLoading then
			gfx.setColor(gfx.kColorBlack)
			local loadingText = "Loading..."
			local loadingWidth = font:getTextWidth(loadingText)
			gfx.drawText(loadingText, SCREEN_W / 2 - loadingWidth / 2, startY + 50)
		elseif leaderboardError then
			gfx.setColor(gfx.kColorBlack)
			local errorText = leaderboardError
			local errorWidth = font:getTextWidth(errorText)
			gfx.drawText(errorText, SCREEN_W / 2 - errorWidth / 2, startY + 50)
		elseif #leaderboard == 0 then
			gfx.setColor(gfx.kColorBlack)
			local noDataText = "No scores yet"
			local noDataWidth = font:getTextWidth(noDataText)
			gfx.drawText(noDataText, SCREEN_W / 2 - noDataWidth / 2, startY + 50)
		else
			-- Draw header
			gfx.setColor(gfx.kColorBlack)
			gfx.drawText("RANK", 20, startY)
			gfx.drawText("NAME", 80, startY)
			gfx.drawText("SCORE", 200, startY)
			gfx.drawText("TIME", 280, startY)
			
			-- Draw entries
			local visibleStart = leaderboardScrollOffset + 1
			local visibleEnd = math.min(visibleStart + maxVisible - 1, #leaderboard)
			
			for i = visibleStart, visibleEnd do
				local entry = leaderboard[i]
				if entry then
					local y = startY + (i - visibleStart + 1) * lineHeight
					
					-- Rank
					local rankText = tostring(entry.rank or i)
					gfx.drawText(rankText, 20, y)
					
					-- Player name (truncate if too long)
					local nameText = entry.playerName or "Player"
					if #nameText > 12 then
						nameText = string.sub(nameText, 1, 12) .. "..."
					end
					gfx.drawText(nameText, 80, y)
					
					-- Score
					local scoreText = tostring(entry.score or 0)
					gfx.drawText(scoreText, 200, y)
					
					-- Time
					local timeText = formatTime(entry.time or 0)
					gfx.drawText(timeText, 280, y)
				end
			end
			
			-- Scroll indicator
			if #leaderboard > maxVisible then
				gfx.setColor(gfx.kColorBlack)
				local scrollText = string.format("%d/%d", leaderboardScrollOffset + 1, #leaderboard)
				local scrollWidth = font:getTextWidth(scrollText)
				gfx.drawText(scrollText, SCREEN_W / 2 - scrollWidth / 2, SCREEN_H - 40)
			end
		end
		
		-- Instructions
		gfx.setColor(gfx.kColorBlack)
		local instText = "A/B: Back"
		local instWidth = font:getTextWidth(instText)
		gfx.drawText(instText, SCREEN_W / 2 - instWidth / 2, SCREEN_H - 20)
	end

	-- debug overlay
	if showDebug and gameState == "playing" then
		gfx.setColor(gfx.kColorBlack)
		local dbx, dby = bunny:getPosition()
		gfx.drawText(string.format("x: %.1f y: %.1f", dbx, dby), 8, 32)
		gfx.drawText(string.format("yVel: %.2f", yVelocity), 8, 48)
		gfx.drawText("isOnGround: " .. tostring(isOnGround), 8, 64)
		gfx.drawText("Facing: " .. facing, 8, 80)
	end
end
