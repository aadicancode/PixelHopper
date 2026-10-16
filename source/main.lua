import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"

local gfx = playdate.graphics

-- === Game clock (excludes time spent paused in the system menu or locked) ===
local pausedTotalMs = 0
local pauseStartMs = nil

local function nowMs()
	return playdate.getCurrentTimeMilliseconds() - pausedTotalMs
end

local function beginPause()
	if not pauseStartMs then
		pauseStartMs = playdate.getCurrentTimeMilliseconds()
	end
end

local function endPause()
	if pauseStartMs then
		pausedTotalMs += playdate.getCurrentTimeMilliseconds() - pauseStartMs
		pauseStartMs = nil
	end
end

function playdate.gameWillPause() beginPause() end
function playdate.gameWillResume() endPause() end
function playdate.deviceWillLock() beginPause() end
function playdate.deviceDidUnlock() endPause() end

-- === Sound Effects ===
local jumpSound = nil

-- Load sound effects (gracefully handle missing files)
local function loadSounds()
	-- Try to load jump sound
	local jumpSample = playdate.sound.sample.new("sounds/jump")
	if jumpSample then
		jumpSound = playdate.sound.sampleplayer.new(jumpSample)
	end
end

-- Initialize sounds
loadSounds()

-- === Screen and Ground Settings ===
local SCREEN_W, SCREEN_H = 400, 240
local GROUND_WIDTH = 400
local GROUND_HEIGHT = 28
local GROUND_CENTER_Y = 230
local GROUND_TOP = GROUND_CENTER_Y - 14

-- === Physics Constants ===
local GRAVITY = 0.45
local JUMP_VELOCITY = -5.5
local MOVE_SPEED = 3
local MOVE_ACCELERATION = 0.5 -- horizontal acceleration (increased for more responsive feel)
local MOVE_DECELERATION = 0.55 -- ground friction / viscosity (increased for less slipperiness)
local MAX_MOVE_SPEED = 3.0 -- max horizontal speed
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
			local offset = math.sin(nowMs() / 400 + phase) * 2
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

-- Spawn a white carrot (temporary, disappears after 8 seconds)
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
		carrot.spawnTime = nowMs()
	end
end

-- Remove white carrot (called when it times out or is collected)
local function removeWhiteCarrot()
	if whiteCarrot then
		if whiteCarrot.flashTimer then whiteCarrot.flashTimer:remove() end
		if whiteCarrot.bounceTimer then whiteCarrot.bounceTimer:remove() end
		whiteCarrot:remove()
		whiteCarrot = nil
		lastWhiteCarrotTime = nowMs()
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
lastWhiteCarrotTime = nowMs()
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
local xVelocity = 0
local isOnGround = true
local facing = "right"
local jumpPressedTime = 0
local useHopDown = false  -- Track which walking animation to use (hop or hopdown)
local lastWalkAnimationTime = 0  -- Time when we last switched walking animation

-- === Game state management ===
local gameState = "mainmenu" -- "mainmenu" | "playing" | "dead" | "leaderboard" | "achievements"
local startTimeMs = nowMs()
local elapsedTime = 0.0

-- === Enemy spawn control ===
local lastArrowSpawn = nowMs()
local arrowSpawnInterval = 1500 -- ms (every 1.5s at start)

-- Difficulty progression (simple): spawn faster over time
local function getSpawnInterval()
	-- cap min interval
	local t = (nowMs() - startTimeMs) / 1000
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

-- === Player Name ===
local playerName = "Player"

local function loadPlayerName()
	local data = playdate.datastore.read("playerName")
	if data and type(data) == "string" and #data > 0 then
		playerName = data
	end
end

loadPlayerName()

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
	playdate.datastore.write("highScore", highScore)
end

local function loadHighTime()
	local data = playdate.datastore.read("highTime")
	if data and type(data) == "number" then
		highTime = data
	end
end

local function saveHighTime()
	playdate.datastore.write("highTime", highTime)
end

loadHighScore()
loadHighTime()

-- === Achievements System ===
local achievements = {} -- Table of {id, name, description, unlocked, unlockTime}
local carrotCollectionTimes = {} -- Track timestamps for speed achievements

-- Achievement definitions
local achievementDefinitions = {
	{
		id = "speed_collector_5",
		name = "Speed Collector",
		description = "Collect 5 carrots in under 5 seconds"
	},
	{
		id = "speed_collector_10",
		name = "Fast Collector",
		description = "Collect 10 carrots in under 10 seconds"
	},
	{
		id = "carrot_master",
		name = "Carrot Master",
		description = "Collect 30 carrots in a single game"
	}
}

-- Initialize achievements from definitions
local function initializeAchievements()
	for _, def in ipairs(achievementDefinitions) do
		if not achievements[def.id] then
			achievements[def.id] = {
				id = def.id,
				name = def.name,
				description = def.description,
				unlocked = false,
				unlockTime = 0
			}
		end
	end
end

-- Load achievements from datastore
local function loadAchievements()
	local data = playdate.datastore.read("achievements")
	if data and type(data) == "table" then
		achievements = data
		-- Ensure all defined achievements exist
		initializeAchievements()
	else
		initializeAchievements()
	end
end

-- Save achievements to datastore
local function saveAchievements()
	playdate.datastore.write("achievements", achievements)
end

-- Notification system
local activeNotification = nil
local notificationQueue = {}

local function showNotification(achievement)
	-- Add to queue if there's already a notification showing
	if activeNotification then
		table.insert(notificationQueue, achievement)
	else
		activeNotification = {
			achievement = achievement,
			startTime = nowMs(),
			duration = 3000 -- 3 seconds
		}
	end
end

local function updateNotifications()
	if activeNotification then
		local now = nowMs()
		if now - activeNotification.startTime >= activeNotification.duration then
			activeNotification = nil
			-- Show next notification in queue if any
			if #notificationQueue > 0 then
				activeNotification = {
					achievement = table.remove(notificationQueue, 1),
					startTime = now,
					duration = 3000
				}
			end
		end
	end
end

-- Check and unlock achievement
local function checkAchievement(id)
	local achievement = achievements[id]
	if not achievement then return end
	if achievement.unlocked then return end
	
	local unlocked = false
	
	-- Check achievement conditions
	if id == "speed_collector_5" then
		if #carrotCollectionTimes >= 5 then
			local lastIndex = #carrotCollectionTimes
			local firstIndex = lastIndex - 4
			if firstIndex >= 1 and lastIndex >= 5 then
				local timeSpan = (carrotCollectionTimes[lastIndex] - carrotCollectionTimes[firstIndex]) / 1000.0
				if timeSpan < 5.0 then
					unlocked = true
				end
			end
		end
	elseif id == "speed_collector_10" then
		if #carrotCollectionTimes >= 10 then
			local lastIndex = #carrotCollectionTimes
			local firstIndex = lastIndex - 9
			if firstIndex >= 1 and lastIndex >= 10 then
				local timeSpan = (carrotCollectionTimes[lastIndex] - carrotCollectionTimes[firstIndex]) / 1000.0
				if timeSpan < 10.0 then
					unlocked = true
				end
			end
		end
	elseif id == "carrot_master" then
		if carrotCount >= 30 then
			unlocked = true
		end
	end
	
	if unlocked then
		achievement.unlocked = true
		achievement.unlockTime = nowMs()
		saveAchievements()
		showNotification(achievement)
	end
end

-- Initialize achievements on startup
loadAchievements()

-- === Local Leaderboard (persisted using Playdate datastore) ===
local leaderboard = {} -- Array of {score, time, playerName, rank, date}
local leaderboardScrollOffset = 0
local achievementsScrollOffset = 0
local maxLeaderboardEntries = 10

-- Save local leaderboard to datastore
local function saveLocalLeaderboard()
	playdate.datastore.write("localLeaderboard", leaderboard)
end

-- Load local leaderboard from datastore
local function loadLocalLeaderboard()
	local data = playdate.datastore.read("localLeaderboard")
	if data and type(data) == "table" then
		leaderboard = data
		-- Clean up invalid entries
		local validEntries = {}
		for i, entry in ipairs(leaderboard) do
			-- Check if score is valid (must be a number, not a string with "/")
			local score = entry.score
			if type(score) == "number" and score >= 0 then
				-- Valid numeric score
				entry.rank = #validEntries + 1
				entry.playerName = entry.playerName or "Player"
				entry.score = score
				entry.time = entry.time or 0
				entry.date = entry.date or 0
				table.insert(validEntries, entry)
			elseif type(score) == "string" then
				-- Try to convert string to number, skip if it contains "/"
				if not string.find(score, "/") then
					local numScore = tonumber(score)
					if numScore and numScore >= 0 then
						entry.rank = #validEntries + 1
						entry.playerName = entry.playerName or "Player"
						entry.score = numScore
						entry.time = entry.time or 0
						entry.date = entry.date or 0
						table.insert(validEntries, entry)
					end
				end
				-- Skip entries with "/" in score (like "1/10")
			end
		end
		leaderboard = validEntries
		
		-- Re-sort after cleanup
		table.sort(leaderboard, function(a, b)
			if a.score ~= b.score then
				return a.score > b.score
			else
				return a.time < b.time
			end
		end)
		
		-- Update ranks after sorting
		for i = 1, #leaderboard do
			leaderboard[i].rank = i
		end
		
		-- Save cleaned leaderboard
		if #validEntries ~= #data then
			saveLocalLeaderboard()
		end
	else
		leaderboard = {}
	end
end

-- Add a score to the local leaderboard
local function addScoreToLocalLeaderboard(score, time)
	-- Create new entry
	local entry = {
		score = score,
		time = time,
		playerName = playerName,
		date = playdate.getSecondsSinceEpoch()
	}
	
	-- Insert into leaderboard (sorted by score, descending)
	table.insert(leaderboard, entry)
	
	-- Sort by score (descending), then by time (ascending for same score)
	table.sort(leaderboard, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		else
			return a.time < b.time
		end
	end)
	
	-- Keep only top entries
	while #leaderboard > maxLeaderboardEntries do
		table.remove(leaderboard)
	end
	
	-- Update ranks
	for i = 1, #leaderboard do
		leaderboard[i].rank = i
	end
	
	-- Save to disk
	saveLocalLeaderboard()
end

-- Initialize: Load local leaderboard on startup
loadLocalLeaderboard()

-- Sync highScore and highTime with leaderboard (in case leaderboard has better scores)
local function syncHighScoreFromLeaderboard()
	if #leaderboard > 0 then
		local topEntry = leaderboard[1]
		if topEntry and topEntry.score then
			-- Update if leaderboard has a higher score, or if highScore is 0
			if topEntry.score > highScore or highScore == 0 then
				highScore = topEntry.score
				highTime = topEntry.time or 0
				saveHighScore()
				saveHighTime()
			end
		end
	end
end

-- Sync on startup
syncHighScoreFromLeaderboard()

-- === UI / Menu selection for death screen ===
local menuOptions = { "RESTART", "LEADERBOARD", "ACHIEVEMENTS" }
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
	a.startTime = nowMs() -- track when arrow was created
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
	obstacle.flashStartTime = nowMs()
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
		local now = nowMs()
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
		size = img:getSize(), -- unrotated width, for the flashing outline
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
	sprite:setCenter(0.5, 1.0)  -- Center horizontally, bottom vertically (so it sits on platform)
	sprite:moveTo(x, y)
	sprite:add()
	
	local cannon = {
		sprite = sprite,
		x = x,
		y = y,
		facing = facing,
		lastFireTime = nowMs(),
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
		size = img:getSize(), -- unrotated width, for the flashing outline
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
	-- Set collision rectangle (slightly smaller than visual for better feel)
	local collisionSize = projSize * 0.8
	sprite:setCollideRect(-collisionSize/2, -collisionSize/2, collisionSize, collisionSize)
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
		local now = nowMs()
		if now - cannon.lastFireTime >= CANNON_FIRE_INTERVAL then
			cannon.lastFireTime = now
			local direction = (cannon.facing == "right") and 1 or -1
			-- Calculate barrel position: cannon is 24 wide, barrel extends 8 pixels from edge
			-- Cannon center is at (cannon.x, cannon.y - 8) since it's bottom-aligned
			local barrelX = cannon.x + (direction * 16)  -- 12 (half width) + 4 (half barrel) = 16
			local barrelY = cannon.y - 8  -- Middle of cannon (cannon is 16 tall, bottom-aligned)
			local projectile = createCannonProjectile(barrelX, barrelY, direction)
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
-- Cannons positioned higher so projectiles pass above platforms
local CANNON_POSITIONS = {
	{ x = LEFT_BOUND, y = 140, facing = "right" },  -- Ground left (raised from 160)
	{ x = RIGHT_BOUND, y = 140, facing = "left" },  -- Ground right (raised from 160)
	{ x = LEFT_BOUND, y = 90, facing = "right" },   -- Middle left (raised from 110)
	{ x = RIGHT_BOUND, y = 90, facing = "left" },   -- Middle right (raised from 110)
	{ x = LEFT_BOUND, y = 40, facing = "right" },   -- Top left (raised from 60)
	{ x = RIGHT_BOUND, y = 40, facing = "left" },   -- Top right (raised from 60)
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
	
	-- Only use platforms that don't already have a wrecking ball
	local availablePlatforms = {}
	for _, plat in ipairs(platforms) do
		local used = false
		for _, ball in ipairs(wreckingBalls) do
			if ball and not ball.removed and ball.platform == plat then
				used = true
				break
			end
		end
		if not used then
			table.insert(availablePlatforms, plat)
		end
	end

	if #availablePlatforms == 0 then return end

	local plat = availablePlatforms[math.random(1, #availablePlatforms)]
	local px, py = plat:getPosition()
	local ball = createWreckingBall(px, py - 5)
	if ball then
		ball.platform = plat
		table.insert(wreckingBalls, ball)
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
	local now = nowMs()
	
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

-- Bunny's hitbox in screen space (its collide rect, not the whole image)
local function getBunnyHitRect()
	local bx, by = bunny:getBounds()
	local r = bunny:getCollideRect()
	return playdate.geometry.rect.new(bx + r.x, by + r.y, r.width, r.height)
end

-- Fixed-size square around a sprite's center; unlike getBounds, it doesn't grow when the sprite rotates
local function centeredRect(sprite, size)
	local x, y = sprite:getPosition()
	return playdate.geometry.rect.new(x - size / 2, y - size / 2, size, size)
end

local SAW_HITBOX = 24 * 0.8
local WRECKING_BALL_HITBOX = 20 * 0.8
local SPIKE_BALL_HITBOX = 18 * 0.8

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
	startTimeMs = nowMs()
	lastArrowSpawn = startTimeMs
	lastObstacleSpawn = 0 -- Reset to trigger immediate spawn
	obstacleSpawnInterval = 0 -- Will be set on first spawn
	gameState = "playing"
	menuSelection = 1
	yVelocity = 0
	xVelocity = 0
	isOnGround = true
	useHopDown = false
	lastWalkAnimationTime = 0
	bunny:moveTo(SCREEN_W / 2, GROUND_TOP)
	setStandingSprite()
	spawnBlackCarrot()
	lastWhiteCarrotTime = nowMs()
	whiteCarrotSpawnDelay = 10000 + math.random(5000) -- 10-15 seconds
	-- Reset achievement tracking
	carrotCollectionTimes = {}
end

local function die()
	-- Several hazards can hit in the same frame; only the first one counts
	if gameState ~= "playing" then return end

	-- particle burst at bunny
	local bx, by, bwB, bhB = bunny:getBounds()
	spawnParticles(bx + bwB/2, by + bhB/2)

	-- store last run stats
	lastScore = carrotCount
	lastTime = elapsedTime

	-- Check "Carrot Master" achievement (30 carrots in a single game)
	checkAchievement("carrot_master")

	-- Add score to local leaderboard (always, so player can see their history)
	addScoreToLocalLeaderboard(carrotCount, elapsedTime)

	-- Sync high score and high time with leaderboard (leaderboard is now sorted)
	-- This ensures highScore/highTime always match the top leaderboard entry
	syncHighScoreFromLeaderboard()

	gameState = "dead"
	menuSelection = 1
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
		elapsedTime = (nowMs() - startTimeMs) / 1000.0
	end

	-- Update notifications
	updateNotifications()

	-- handle input for menu/state
	if gameState == "mainmenu" then
		-- Up/Down to navigate menu, A to select, B to restart
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			menuSelection = math.max(1, menuSelection - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			menuSelection = math.min(#menuOptions, menuSelection + 1)
		elseif playdate.buttonJustPressed(playdate.kButtonA) then
			if menuSelection == 1 then
				-- Reset current stats and start game
				carrotCount = 0
				elapsedTime = 0.0
				startTimeMs = nowMs()
				gameState = "playing"
				restartGame()
			elseif menuSelection == 2 then
				-- View leaderboard
				gameState = "leaderboard"
			elseif menuSelection == 3 then
				-- View achievements
				gameState = "achievements"
			end
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			-- Reset current stats and start game
			carrotCount = 0
			elapsedTime = 0.0
			startTimeMs = nowMs()
			gameState = "playing"
			restartGame()
		end
	elseif gameState == "dead" then
		-- Up/Down to navigate menu, A to select, B to restart
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			menuSelection = math.max(1, menuSelection - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			menuSelection = math.min(#menuOptions, menuSelection + 1)
		elseif playdate.buttonJustPressed(playdate.kButtonA) then
			if menuSelection == 1 then
				restartGame()
			elseif menuSelection == 2 then
				-- View leaderboard (local leaderboard is always available)
				gameState = "leaderboard"
			elseif menuSelection == 3 then
				-- View achievements
				gameState = "achievements"
			end
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			restartGame()
		end
	elseif gameState == "leaderboard" then
		-- A or B to go back
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			if lastScore > 0 or lastTime > 0 then
				gameState = "dead"
			else
				gameState = "mainmenu"
			end
		end
		-- Up/Down to scroll (if needed)
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			leaderboardScrollOffset = math.max(0, leaderboardScrollOffset - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			leaderboardScrollOffset = math.min(math.max(0, #leaderboard - 7), leaderboardScrollOffset + 1)
		end
	elseif gameState == "achievements" then
		-- A or B to go back
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			if lastScore > 0 or lastTime > 0 then
				gameState = "dead"
			else
				gameState = "mainmenu"
			end
		end
		-- Up/Down to scroll (if needed)
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			achievementsScrollOffset = math.max(0, achievementsScrollOffset - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			achievementsScrollOffset = math.min(math.max(0, #achievementDefinitions - 7), achievementsScrollOffset + 1)
		end
	else -- playing
		-- movement with acceleration/deceleration
		local moved = false
		local bx, by = bunny:getPosition()

		if playdate.buttonIsPressed(playdate.kButtonLeft) then
			facing = "left"
			-- if moving right, quickly reverse direction (no sliding)
			if xVelocity > 0 then
				xVelocity = -MOVE_ACCELERATION * 1.5 -- quick reverse, start moving left
			else
				xVelocity = math.max(-MAX_MOVE_SPEED, xVelocity - MOVE_ACCELERATION)
			end
			moved = true
		elseif playdate.buttonIsPressed(playdate.kButtonRight) then
			facing = "right"
			-- if moving left, quickly reverse direction (no sliding)
			if xVelocity < 0 then
				xVelocity = MOVE_ACCELERATION * 1.5 -- quick reverse, start moving right
			else
				xVelocity = math.min(MAX_MOVE_SPEED, xVelocity + MOVE_ACCELERATION)
			end
			moved = true
		else
			-- very fast stop (almost instant, but smoother)
			if math.abs(xVelocity) > 0.1 then
				xVelocity = xVelocity * 0.3 -- quick deceleration
			else
				xVelocity = 0 -- stop when very slow
			end
		end

		-- apply horizontal velocity
		if math.abs(xVelocity) > 0.01 then
			bunny:moveBy(xVelocity, 0)
			if math.abs(xVelocity) > 0.1 then
				moved = true
			end
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

		-- Jump with acceleration
		if (playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonUp)) and isOnGround then
			yVelocity = JUMP_VELOCITY -- initial jump velocity
			isOnGround = false
			jumpPressedTime = 0
			setHopSprite()
			if jumpSound then
				jumpSound:play()
			end
		end

		-- Hold jump for additional lift
		if (playdate.buttonIsPressed(playdate.kButtonA) or playdate.buttonIsPressed(playdate.kButtonUp)) and not isOnGround and yVelocity < 0 then
			jumpPressedTime += 1
			if jumpPressedTime < 12 then
				yVelocity -= 0.25 -- accelerate upward (increased for higher jump)
			else
				yVelocity += 0.15 -- start decelerating
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
			local currentTime = nowMs()
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

					local now = nowMs()
					if c.isWhite then
						carrotCount += 3
						-- Track 3 carrot collections for white carrot
						table.insert(carrotCollectionTimes, now)
						table.insert(carrotCollectionTimes, now)
						table.insert(carrotCollectionTimes, now)
						-- Remove white carrot and schedule next one
						removeWhiteCarrot()
					else
						carrotCount += 1
						-- Track carrot collection timestamp
						table.insert(carrotCollectionTimes, now)
						-- Remove black carrot and spawn new one
						if c.flashTimer then c.flashTimer:remove() end
						if c.bounceTimer then c.bounceTimer:remove() end
						c:remove()
						table.remove(carrots, i)
						spawnBlackCarrot()
					end
					
					-- Keep only last 10 timestamps for efficiency
					while #carrotCollectionTimes > 10 do
						table.remove(carrotCollectionTimes, 1)
					end
					
					-- Check speed achievements
					checkAchievement("speed_collector_5")
					checkAchievement("speed_collector_10")
					checkAchievement("carrot_master")
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
				
				-- Track 3 carrot collections for white carrot
				local now = nowMs()
				table.insert(carrotCollectionTimes, now)
				table.insert(carrotCollectionTimes, now)
				table.insert(carrotCollectionTimes, now)
				
				-- Keep only last 10 timestamps for efficiency
				while #carrotCollectionTimes > 10 do
					table.remove(carrotCollectionTimes, 1)
				end
				
				-- Check speed achievements
				checkAchievement("speed_collector_5")
				checkAchievement("speed_collector_10")
				checkAchievement("carrot_master")
				
				removeWhiteCarrot()
			end
		end

		-- White carrot timeout check (8 seconds)
		if whiteCarrot and not whiteCarrot.removed then
			local now = nowMs()
			if now - whiteCarrot.spawnTime >= 8000 then
				removeWhiteCarrot()
			end
		end

		-- White carrot spawn check (10-15 seconds after last one disappeared)
		if not whiteCarrot then
			local now = nowMs()
			if now - lastWhiteCarrotTime >= whiteCarrotSpawnDelay then
				spawnWhiteCarrot()
			end
		end

		---------------------------------------------------------------------

		-- spawn arrows over time
		local now = nowMs()
		if now - lastArrowSpawn >= getSpawnInterval() then
			lastArrowSpawn = now
			spawnRandomArrow()
		end

		-- update arrows
		for i = #arrows, 1, -1 do
			local a = arrows[i]
			if a and a.sprite then
				local now = nowMs()
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
					local axB, ayB, awB, ahB = a.sprite:getBounds()
					local bunnyRect = getBunnyHitRect()
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
			lastObstacleSpawn = nowMs()
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
		local bunnyRect = getBunnyHitRect()

		-- Check collision with saws
		for i = #saws, 1, -1 do
			local saw = saws[i]
			if saw and saw.sprite and not saw.isFlashing then
				if bunnyRect:intersects(centeredRect(saw.sprite, SAW_HITBOX)) then
					die()
					break
				end
			end
		end

		-- Check collision with wrecking balls
		for i = #wreckingBalls, 1, -1 do
			local ball = wreckingBalls[i]
			if ball and ball.sprite and not ball.isFlashing then
				if bunnyRect:intersects(centeredRect(ball.sprite, WRECKING_BALL_HITBOX)) then
					die()
					break
				end
			end
		end

		-- Check collision with spike balls
		for i = #spikeBalls, 1, -1 do
			local spikeBall = spikeBalls[i]
			if spikeBall and spikeBall.sprite and not spikeBall.isFlashing then
				if bunnyRect:intersects(centeredRect(spikeBall.sprite, SPIKE_BALL_HITBOX)) then
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
					-- Use projectile's collision rect
					local projCollideRect = projectile.sprite:getCollideRect()
					local projBoundsX, projBoundsY = projectile.sprite:getBounds()
					local projRect = playdate.geometry.rect.new(
						projBoundsX + projCollideRect.x,
						projBoundsY + projCollideRect.y,
						projCollideRect.width,
						projCollideRect.height
					)
					
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

	-- Control bunny visibility based on game state
	if gameState == "playing" then
		bunny:setVisible(true)
	else
		bunny:setVisible(false)
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
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawRect(centeredRect(saw.sprite, saw.size))
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
				gfx.setColor(gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawRect(centeredRect(spikeBall.sprite, spikeBall.size))
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
	
	-- draw death/menu overlays
	local font = gfx.getFont()
	
	if gameState == "mainmenu" then
		-- Draw background (same as death screen)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Simple text display (same as death screen)
		gfx.setColor(gfx.kColorBlack)
		local yPos = 10
		local statsLineHeight = 22  -- Reduced spacing for stats
		
		-- Player Name (ensure we have the latest value)
		local displayPlayerName = playerName or "Player"
		if not displayPlayerName or displayPlayerName == "" then
			displayPlayerName = "Player"
		end
		local playerNameText = "PLAYER: " .. displayPlayerName
		local playerNameWidth = font:getTextWidth(playerNameText)
		gfx.drawText(playerNameText, SCREEN_W / 2 - playerNameWidth / 2, yPos)
		
		-- High Score
		yPos = yPos + statsLineHeight + 5
		local highScoreText = "HIGH SCORE: " .. tostring(highScore)
		local highScoreWidth = font:getTextWidth(highScoreText)
		gfx.drawText(highScoreText, SCREEN_W / 2 - highScoreWidth / 2, yPos)
		
		-- High Timer
		yPos = yPos + statsLineHeight
		local highTimerText = "HIGH TIMER: " .. formatTime(highTime)
		local highTimerWidth = font:getTextWidth(highTimerText)
		gfx.drawText(highTimerText, SCREEN_W / 2 - highTimerWidth / 2, yPos)
		
		-- Current Score
		yPos = yPos + statsLineHeight
		local currentScoreText = "CURRENT SCORE: " .. tostring(lastScore)
		local currentScoreWidth = font:getTextWidth(currentScoreText)
		gfx.drawText(currentScoreText, SCREEN_W / 2 - currentScoreWidth / 2, yPos)
		
		-- Current Timer
		yPos = yPos + statsLineHeight
		local currentTimerText = "CURRENT TIMER: " .. formatTime(lastTime)
		local currentTimerWidth = font:getTextWidth(currentTimerText)
		gfx.drawText(currentTimerText, SCREEN_W / 2 - currentTimerWidth / 2, yPos)
		
		-- Menu options (with more spacing)
		yPos = yPos + statsLineHeight + 5
		local menuY = yPos
		local menuLineHeight = 22  -- Spacing between menu items
		
		-- RESTART option
		local restartText = "RESTART"
		local restartWidth = font:getTextWidth(restartText)
		if menuSelection == 1 then
			-- Draw selection line on the left side
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - restartWidth / 2 - 8, menuY, 3, 16)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(restartText, SCREEN_W / 2 - restartWidth / 2, menuY)
		
		-- LEADERBOARD option
		menuY = menuY + menuLineHeight
		local leaderboardText = "LEADERBOARD"
		local leaderboardWidth = font:getTextWidth(leaderboardText)
		if menuSelection == 2 then
			-- Draw selection line on the left side
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - leaderboardWidth / 2 - 8, menuY, 3, 16)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(leaderboardText, SCREEN_W / 2 - leaderboardWidth / 2, menuY)
		
		-- ACHIEVEMENTS option
		menuY = menuY + menuLineHeight
		local achievementsText = "ACHIEVEMENTS"
		local achievementsWidth = font:getTextWidth(achievementsText)
		if menuSelection == 3 then
			-- Draw selection line on the left side
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - achievementsWidth / 2 - 8, menuY, 3, 16)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(achievementsText, SCREEN_W / 2 - achievementsWidth / 2, menuY)
		
		-- Instructions (moved to very bottom with more space)
		local instText = "A: Select  B: Start"
		local instWidth = font:getTextWidth(instText)
		gfx.drawText(instText, SCREEN_W / 2 - instWidth / 2, SCREEN_H - 20)
		
	elseif gameState == "dead" then
		-- Draw background (same as main menu)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Simple text display (same as main menu)
		gfx.setColor(gfx.kColorBlack)
		local yPos = 30
		local statsLineHeight = 22  -- Reduced spacing for stats
		
		-- High Score
		local highScoreText = "HIGH SCORE: " .. tostring(highScore)
		local highScoreWidth = font:getTextWidth(highScoreText)
		gfx.drawText(highScoreText, SCREEN_W / 2 - highScoreWidth / 2, yPos)
		
		-- High Timer
		yPos = yPos + statsLineHeight
		local highTimerText = "HIGH TIMER: " .. formatTime(highTime)
		local highTimerWidth = font:getTextWidth(highTimerText)
		gfx.drawText(highTimerText, SCREEN_W / 2 - highTimerWidth / 2, yPos)
		
		-- Current Score
		yPos = yPos + statsLineHeight
		local currentScoreText = "CURRENT SCORE: " .. tostring(lastScore)
		local currentScoreWidth = font:getTextWidth(currentScoreText)
		gfx.drawText(currentScoreText, SCREEN_W / 2 - currentScoreWidth / 2, yPos)
		
		-- Current Timer
		yPos = yPos + statsLineHeight
		local currentTimerText = "CURRENT TIMER: " .. formatTime(lastTime)
		local currentTimerWidth = font:getTextWidth(currentTimerText)
		gfx.drawText(currentTimerText, SCREEN_W / 2 - currentTimerWidth / 2, yPos)
		
		-- Menu options (with more spacing)
		yPos = yPos + statsLineHeight + 5
		local menuY = yPos
		local menuLineHeight = 22  -- Spacing between menu items
		
		-- RESTART option
		local restartText = "RESTART"
		local restartWidth = font:getTextWidth(restartText)
		if menuSelection == 1 then
			-- Draw selection line on the left side
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - restartWidth / 2 - 8, menuY, 3, 16)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(restartText, SCREEN_W / 2 - restartWidth / 2, menuY)
		
		-- LEADERBOARD option
		menuY = menuY + menuLineHeight
		local leaderboardText = "LEADERBOARD"
		local leaderboardWidth = font:getTextWidth(leaderboardText)
		if menuSelection == 2 then
			-- Draw selection line on the left side
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - leaderboardWidth / 2 - 8, menuY, 3, 16)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(leaderboardText, SCREEN_W / 2 - leaderboardWidth / 2, menuY)
		
		-- ACHIEVEMENTS option
		menuY = menuY + menuLineHeight
		local achievementsText = "ACHIEVEMENTS"
		local achievementsWidth = font:getTextWidth(achievementsText)
		if menuSelection == 3 then
			-- Draw selection line on the left side
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRect(SCREEN_W / 2 - achievementsWidth / 2 - 8, menuY, 3, 16)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(achievementsText, SCREEN_W / 2 - achievementsWidth / 2, menuY)
		
		-- Instructions (moved to very bottom with more space)
		local instText = "A: Select  B: Restart"
		local instWidth = font:getTextWidth(instText)
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText(instText, SCREEN_W / 2 - instWidth / 2, SCREEN_H - 20)
		
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
		
		if #leaderboard == 0 then
			gfx.setColor(gfx.kColorBlack)
			local noDataText = "No scores yet"
			local noDataWidth = font:getTextWidth(noDataText)
			gfx.drawText(noDataText, SCREEN_W / 2 - noDataWidth / 2, startY + 50)
		else
			-- Draw header with better spacing
			gfx.setColor(gfx.kColorBlack)
			local rankX = 20
			local nameX = 60
			local scoreX = 150
			local timeX = 230
			
			gfx.drawText("RANK", rankX, startY)
			gfx.drawText("NAME", nameX, startY)
			gfx.drawText("SCORE", scoreX, startY)
			gfx.drawText("TIME", timeX, startY)
			
			-- Draw entries
			local visibleStart = leaderboardScrollOffset + 1
			local visibleEnd = math.min(visibleStart + maxVisible - 1, #leaderboard)
			
			for i = visibleStart, visibleEnd do
				local entry = leaderboard[i]
				if entry then
					local y = startY + (i - visibleStart + 1) * lineHeight
					
					-- Rank
					local rankText = tostring(entry.rank or i)
					gfx.drawText(rankText, rankX, y)
					
					-- Player name (truncate if too long to fit column width)
					local nameText = entry.playerName or "Player"
					local maxNameWidth = scoreX - nameX - 10  -- Leave 10px gap before score
					if font:getTextWidth(nameText) > maxNameWidth then
						-- Truncate name to fit
						for j = #nameText, 1, -1 do
							local testText = string.sub(nameText, 1, j) .. "..."
							if font:getTextWidth(testText) <= maxNameWidth then
								nameText = testText
								break
							end
						end
					end
					gfx.drawText(nameText, nameX, y)
					
					-- Score (ensure it's a number, not a string)
					local score = entry.score or 0
					if type(score) ~= "number" then
						score = tonumber(score) or 0
					end
					local scoreText = tostring(score)
					local maxScoreWidth = timeX - scoreX - 10  -- Leave 10px gap before time
					if font:getTextWidth(scoreText) > maxScoreWidth then
						-- Truncate score to fit
						for j = #scoreText, 1, -1 do
							local testText = string.sub(scoreText, 1, j)
							if font:getTextWidth(testText) <= maxScoreWidth then
								scoreText = testText
								break
							end
						end
					end
					gfx.drawText(scoreText, scoreX, y)
					
					-- Time
					local timeText = formatTime(entry.time or 0)
					gfx.drawText(timeText, timeX, y)
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
		
	elseif gameState == "achievements" then
		-- Achievements screen
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		
		-- Title
		gfx.setColor(gfx.kColorBlack)
		local titleText = "ACHIEVEMENTS"
		local titleWidth = font:getTextWidth(titleText)
		gfx.drawText(titleText, SCREEN_W / 2 - titleWidth / 2, 10)
		
		-- Draw achievements list
		local startY = 40
		local lineHeight = 42  -- Increased spacing even more to prevent overlap
		local maxVisible = 5   -- Reduced visible items to fit better
		
		if #achievementDefinitions == 0 then
			gfx.setColor(gfx.kColorBlack)
			local noDataText = "No achievements"
			local noDataWidth = font:getTextWidth(noDataText)
			gfx.drawText(noDataText, SCREEN_W / 2 - noDataWidth / 2, startY + 50)
		else
			-- Draw entries
			local visibleStart = achievementsScrollOffset + 1
			local visibleEnd = math.min(visibleStart + maxVisible - 1, #achievementDefinitions)
			
			for i = visibleStart, visibleEnd do
				local def = achievementDefinitions[i]
				local achievement = achievements[def.id]
				if achievement then
					local y = startY + (i - visibleStart) * lineHeight
					
					-- Achievement status indicator (locked/unlocked)
					local statusX = 20
					if achievement.unlocked then
						-- Draw checkmark or unlocked indicator
						gfx.setColor(gfx.kColorBlack)
						gfx.fillRect(statusX, y + 4, 12, 12)
						-- White checkmark drawn with lines (drawText ignores setColor, and the font may lack ✓)
						gfx.setColor(gfx.kColorWhite)
						gfx.setLineWidth(2)
						gfx.drawLine(statusX + 2, y + 10, statusX + 5, y + 13)
						gfx.drawLine(statusX + 5, y + 13, statusX + 10, y + 6)
					else
						-- Draw locked indicator
						gfx.setColor(gfx.kColorBlack)
						gfx.drawRect(statusX, y + 4, 12, 12)
						gfx.setColor(gfx.kColorBlack)
						gfx.drawText("?", statusX + 4, y + 2)
					end
					
					-- Achievement name (always show, with proper spacing)
					gfx.setColor(gfx.kColorBlack)
					local nameText = achievement.name
					if not achievement.unlocked then
						nameText = "???"
					end
					-- Draw name on first line
					gfx.drawText(nameText, statusX + 18, y + 2)
					
					-- Achievement description (only if unlocked, with proper spacing)
					if achievement.unlocked then
						gfx.setColor(gfx.kColorBlack)
						local descText = achievement.description
						-- Truncate if too long
						local maxWidth = SCREEN_W - statusX - 18 - 20
						if font:getTextWidth(descText) > maxWidth then
							-- Find the longest substring that fits
							for i = #descText, 1, -1 do
								local testText = string.sub(descText, 1, i) .. "..."
								if font:getTextWidth(testText) <= maxWidth then
									descText = testText
									break
								end
							end
						end
						-- Draw description on second line with more spacing (20 pixels down from name)
						gfx.drawText(descText, statusX + 18, y + 20)
					else
						-- For locked achievements, show hint text
						gfx.setColor(gfx.kColorBlack)
						local hintText = "Locked"
						gfx.drawText(hintText, statusX + 18, y + 20)
					end
				end
			end
			
			-- Scroll indicator
			if #achievementDefinitions > maxVisible then
				gfx.setColor(gfx.kColorBlack)
				local scrollText = string.format("%d/%d", achievementsScrollOffset + 1, #achievementDefinitions)
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

	-- Achievement notification (drawn last so it shows on every screen)
	if activeNotification then
		local notif = activeNotification.achievement
		local notifY = 30
		local padding = 8
		local textWidth = font:getTextWidth(notif.name)
		local descWidth = font:getTextWidth(notif.description)
		local boxWidth = math.max(textWidth, descWidth) + padding * 2
		local boxHeight = 40
		local boxX = (SCREEN_W - boxWidth) / 2

		-- Draw notification background
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(boxX, notifY, boxWidth, boxHeight)
		gfx.setColor(gfx.kColorWhite)
		gfx.setLineWidth(2)
		gfx.drawRect(boxX, notifY, boxWidth, boxHeight)

		-- Draw achievement text in white (drawText uses the image draw mode, not setColor)
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		gfx.drawText(notif.name, boxX + padding, notifY + 6)
		gfx.drawText(notif.description, boxX + padding, notifY + 22)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end
end
