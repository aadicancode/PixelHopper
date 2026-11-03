import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"
import "CoreLibs/keyboard"
import "config"
import "online"
import "ui"
import "world"
import "clock"
import "particles"
import "progress"
import "hazards"
import "powerups"
import "rewind"

local gfx = playdate.graphics

-- Clocks (clock.lua): nowMs is real play time, slowmo drives the slow-motion world clock
local nowMs = Clock.now
local slowmo = SlowMo

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
local SCREEN_W, SCREEN_H = World.SCREEN_W, World.SCREEN_H
local GROUND_WIDTH = 400
local GROUND_HEIGHT = 28
local GROUND_TOP = World.GROUND_TOP
local GROUND_CENTER_Y = GROUND_TOP + GROUND_HEIGHT / 2

-- === Physics Constants ===
local GRAVITY = 0.45
local FALL_GRAVITY_MULTIPLIER = 1.6 -- gravity is stronger on the way down
local MAX_FALL_SPEED = 9 -- terminal fall speed (px per frame)
local JUMP_VELOCITY = -5.5
local JUMP_BOOST_FRAMES = 14 -- frames that holding jump adds lift (max jump ~59px)
local COYOTE_FRAMES = 4 -- frames you can still jump after walking off a ledge (~0.13s)
-- Ledge assist: if a jump gets at least 75% of the bunny's 24px body above a platform's top
-- (feet up to 6px below it), the bunny is warped up to stand on the platform once it starts falling
local LEDGE_ASSIST_PX = 6
local MOVE_SPEED = 3
local MOVE_ACCELERATION = 0.5 -- horizontal acceleration (increased for more responsive feel)
local MOVE_DECELERATION = 0.55 -- ground friction / viscosity (increased for less slipperiness)
local MAX_MOVE_SPEED = 3.0 -- max horizontal speed
local LEFT_BOUND, RIGHT_BOUND = World.LEFT_BOUND, World.RIGHT_BOUND

-- === Platform + Carrot Tables ===
local platforms = {}
local carrots = {}
local whiteCarrot = nil -- separate white carrot
local carrotCount = 0
local lastWhiteCarrotTime = 0 -- when last white carrot disappeared
local whiteCarrotSpawnDelay = 0 -- delay before next white carrot spawns

-- Arrows and obstacles live in hazards.lua; particle bursts in particles.lua
local spawnParticles = Particles.spawn

local safeLoad = World.loadImage

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
			-- Hide it with setVisible: setImage(nil) left it with no size, so it couldn't be
			-- collected during the "off" flashes
			carrot:setVisible(visible)
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

-- Where the bunny is, kept up to date each frame so pickups don't spawn right on top of it
local spawnAvoidX, spawnAvoidY = SCREEN_W / 2, GROUND_TOP - 12
local function setSpawnAvoid(x, y)
	spawnAvoidX, spawnAvoidY = x, y
end

-- Find a valid spawn position: not on a platform, below the HUD (pickups are drawn with their
-- bottom at y, and the HUD pills reach y=24), and not right on the bunny
local SPAWN_MIN_Y = 46
local SPAWN_AVOID_BUNNY = 50
local function findValidSpawnPosition()
	local margin = 20
	local maxAttempts = 50
	local x, y
	
	for i = 1, maxAttempts do
		x = math.random(margin, SCREEN_W - margin)
		y = math.random(SPAWN_MIN_Y, GROUND_TOP - margin)
		local dx, dy = x - spawnAvoidX, y - spawnAvoidY
		local nearBunny = dx * dx + dy * dy < SPAWN_AVOID_BUNNY * SPAWN_AVOID_BUNNY
		
		if not isPositionOnPlatform(x, y) and not nearBunny then
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
		carrot.spawnTime = slowmo.now()
	end
end

-- Remove white carrot (called when it times out or is collected)
local function removeWhiteCarrot()
	if whiteCarrot then
		if whiteCarrot.flashTimer then whiteCarrot.flashTimer:remove() end
		if whiteCarrot.bounceTimer then whiteCarrot.bounceTimer:remove() end
		whiteCarrot:remove()
		whiteCarrot = nil
		lastWhiteCarrotTime = slowmo.now()
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
	-- Pebbles in the dirt, in the same style as the menu ground
	UI.drawGroundPebbles({
		{ y = 6, x0 = 8, spacing = 22, count = 18, bigOffset = 0 },
		{ y = 16, x0 = 19, spacing = 28, count = 14, bigOffset = 1 },
	})
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
		-- Brick texture: a highlight along the top and staggered mortar lines
		gfx.setColor(gfx.kColorWhite)
		gfx.drawLine(2, 2, p.w - 3, 2)
		gfx.drawLine(1, 6, p.w - 2, 6)
		for bx = 6, p.w - 4, 12 do gfx.drawLine(bx, 3, bx, 5) end
		for bx = 12, p.w - 4, 12 do gfx.drawLine(bx, 7, bx, p.h - 2) end
	gfx.popContext()
	local plat = gfx.sprite.new(img)
	plat:setCollideRect(0, 0, p.w, p.h)
	plat:moveTo(p.x, p.y + p.h / 2)
	plat:add()
	table.insert(platforms, plat)
end

Hazards.platforms = platforms

math.randomseed(playdate.getSecondsSinceEpoch())
spawnBlackCarrot()
lastWhiteCarrotTime = slowmo.now()
whiteCarrotSpawnDelay = 10000 + math.random(5000) -- initial delay 10-15 seconds

-- === Bunny ===
local bunny = gfx.sprite.new(imgRight)
bunny:setCenter(0.5, 1.0)
bunny:moveTo(SCREEN_W / 2, GROUND_TOP)
bunny:add()

local bw, bh = imgRight:getSize()
bunny:setCollideRect(math.max(0, (bw - 20) / 2), bh - 22, 20, 22) -- centered on the image

-- === State ===
local yVelocity = 0
local xVelocity = 0
local isOnGround = true
-- Drop-through: press Down on a platform to fall through it. The platform you're standing on is
-- remembered, and the one you dropped through is ignored for DROP_THROUGH_MS so you don't re-land.
local DROP_THROUGH_MS = 250
local standingPlatform = nil
local dropPlatform = nil
local dropUntilMs = 0
local function ignoringPlatform(plat)
	return plat == dropPlatform and nowMs() < dropUntilMs
end
local facing = "right"
local jumpPressedTime = 0
local coyoteFrames = 0
local useHopDown = false  -- Track which walking animation to use (hop or hopdown)
local lastWalkAnimationTime = 0  -- Time when we last switched walking animation

-- === Game state management ===
local gameState = "mainmenu" -- "mainmenu" | "playing" | "rewind" | "dying" | "dead" | "leaderboard" | "achievements"
local startTimeMs = nowMs()
local elapsedTime = 0.0

-- Scenery (sun/moon, clouds, birds, hills, flowers) drawn as the sprite system's background, behind every sprite
gfx.sprite.setBackgroundDrawingCallback(function()
	if gameState == "playing" or gameState == "dying" or gameState == "rewind" then
		UI.drawPlayfield(elapsedTime)
	end
end)

-- === This run's results (saved progress lives in progress.lua) ===
local lastScore = 0
local lastTime = 0.0
local lastRunWasBest = false -- set on death, shown as NEW BEST! on the death screen
local carrotCollectionTimes = {} -- recent carrot pickup times, for the speed achievements
local leaderboardScrollOffset = 0
local achievementsScrollOffset = 0

-- === UI / Menu selection for death screen ===
local menuOptions = { "RESTART", "LEADERBOARD", "ACHIEVEMENTS", "MAIN MENU" }
local mainMenuOptions = { "RESTART", "LEADERBOARD", "ACHIEVEMENTS", "CHANGE NAME" }

-- === Leaderboard screen (local and online tabs) ===
local leaderboardTab = "local" -- "local" | "online"

local returnState = "mainmenu" -- where Back goes from the leaderboard / achievements screens
local DEAD_INPUT_DELAY_MS = 450 -- ignore buttons briefly on the game-over screen
local deadSinceMs = 0

local function openLeaderboard()
	returnState = gameState
	gameState = "leaderboard"
	leaderboardTab = "local"
	leaderboardScrollOffset = 0
	OnlineLeaderboard.refresh() -- start loading so the online tab is ready when opened
end

local function openAchievements()
	returnState = gameState
	gameState = "achievements"
	achievementsScrollOffset = 0
end

-- === Player name entry (system keyboard) ===
local function openNameEntry()
	playdate.keyboard.keyboardWillHideCallback = function(confirmed)
		if not confirmed then return end
		local name = string.match(playdate.keyboard.text or "", "^%s*(.-)%s*$")
		if name and #name > 0 then
			Progress.setPlayerName(string.sub(name, 1, 16))
		end
	end
	playdate.keyboard.show(Progress.playerName)
end
local menuSelection = 1

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

-- How far the hurtbox is pulled in from the bunny's 20x22 collide rect (gives a 14x15 hurtbox).
-- Only hazards use this; landing on platforms still uses the full collide rect.
local BUNNY_HURTBOX_INSET_SIDES = 3
local BUNNY_HURTBOX_INSET_TOP = 5
local BUNNY_HURTBOX_INSET_BOTTOM = 2

-- Bunny's hurtbox in screen space: a forgiving box inside its collide rect
local function getBunnyHitRect()
	local bx, by = bunny:getBounds()
	local r = bunny:getCollideRect()
	return playdate.geometry.rect.new(
		bx + r.x + BUNNY_HURTBOX_INSET_SIDES,
		by + r.y + BUNNY_HURTBOX_INSET_TOP,
		r.width - BUNNY_HURTBOX_INSET_SIDES * 2,
		r.height - BUNNY_HURTBOX_INSET_TOP - BUNNY_HURTBOX_INSET_BOTTOM
	)
end

-- === Death sequence ===
-- On death the world freezes while the bunny flips over, pops up and falls off screen
local DEATH_FALL_MAX_MS = 2000
local DEATH_POP_VELOCITY = -6
local imgDeadRight = imgRight:scaledImage(1, -1)
local imgDeadLeft = imgLeft:scaledImage(1, -1)

-- Sprites the menus and HUD draw (ui.lua)
local uiImages = {
	bunny = imgRight,
	bunnyHop = imgHopRight,
	bunnyFall = imgHopDownRight,
	bunnyDead = imgDeadRight,
	carrot = carrotImg,
}
local deathStartMs = 0
local deathVelocity = 0

-- reset everything for restart
local function restartGame()
	UI.newRun() -- new roll for the rare bunny cloud
	Particles.clear()
	Hazards.clear() -- arrows and obstacles; the first obstacle spawns right away
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

	carrotCount = 0
	startTimeMs = nowMs()
	gameState = "playing"
	menuSelection = 1
	yVelocity = 0
	xVelocity = 0
	isOnGround = true
	useHopDown = false
	lastWalkAnimationTime = 0
	coyoteFrames = 0
	bunny:setZIndex(0)
	bunny:moveTo(SCREEN_W / 2, GROUND_TOP)
	setSpawnAvoid(SCREEN_W / 2, GROUND_TOP - 12)
	setStandingSprite()
	spawnBlackCarrot()
	lastWhiteCarrotTime = slowmo.now()
	whiteCarrotSpawnDelay = 10000 + math.random(5000) -- 10-15 seconds
	SlowMo.reset() -- slow motion starts each run with a full meter
	-- Reset achievement tracking
	carrotCollectionTimes = {}
	PowerUps.reset()
	standingPlatform = nil
	dropPlatform = nil
	Rewind.reset()
end

local function die()
	-- Several hazards can hit in the same frame; only the first one counts
	if gameState ~= "playing" then return end

	-- Start the death animation: flip upside down, pop up, fall off the bottom of the screen
	deathStartMs = nowMs()
	deathVelocity = DEATH_POP_VELOCITY
	local bx, by, bwB, bhB = bunny:getBounds()
	spawnParticles(bx + bwB/2, by + bhB/2)
	bunny:setImage(facing == "right" and imgDeadRight or imgDeadLeft)
	bunny:setZIndex(1000) -- fall in front of the ground and platforms

	-- store last run stats (saved now, so quitting mid-animation still records the run)
	lastScore = carrotCount
	lastTime = elapsedTime

	-- Check "Carrot Master" achievement (30 carrots in a single game)
	Progress.checkAchievement("carrot_master", carrotCount, carrotCollectionTimes)

	-- Remember whether this run beat the previous best, before the best is updated
	lastRunWasBest = carrotCount > Progress.highScore

	-- Add score to local leaderboard (always, so player can see their history)
	Progress.addScore(carrotCount, elapsedTime)

	-- Queue the run for the online leaderboard (uploads automatically in the background)
	OnlineLeaderboard.submitScore(Progress.playerName, carrotCount, elapsedTime)

	-- Keep the high score and time in step with the top of the leaderboard
	Progress.syncHighScore()

	gameState = "dying"
	menuSelection = 1
end

-------------------------------------------------------
-- === Crank rewind (rewind.lua): the bunny, carrots and counters as plain data ===
-------------------------------------------------------
local function removeCarrotSprite(c)
	if c.flashTimer then c.flashTimer:remove() end
	if c.bounceTimer then c.bounceTimer:remove() end
	c:remove()
end

Rewind.setup({
	carrotCount = function() return carrotCount end,

	captureGame = function()
		local snap = {}
		snap.bunnyX, snap.bunnyY = bunny:getPosition()
		snap.yVel, snap.xVel, snap.onGround, snap.facing = yVelocity, xVelocity, isOnGround, facing
		snap.standing, snap.coyote, snap.jumpTime = standingPlatform, coyoteFrames, jumpPressedTime
		snap.usedDouble = PowerUps.usedDoubleJump
		snap.carrotCount = carrotCount
		snap.collectTimes = { table.unpack(carrotCollectionTimes) }
		snap.lastWhite, snap.whiteDelay = lastWhiteCarrotTime, whiteCarrotSpawnDelay
		snap.carrots = {}
		for _, c in ipairs(carrots) do
			local x = c:getPosition()
			table.insert(snap.carrots, { x = x, baseY = c.baseY })
		end
		if whiteCarrot then
			local x = whiteCarrot:getPosition()
			snap.white = { x = x, baseY = whiteCarrot.baseY, spawnTime = whiteCarrot.spawnTime }
		end
		return snap
	end,

	restoreGame = function(snap)
		for i = #carrots, 1, -1 do
			removeCarrotSprite(carrots[i])
			carrots[i] = nil
		end
		if whiteCarrot then
			removeCarrotSprite(whiteCarrot)
			whiteCarrot = nil
		end
		for _, c in ipairs(snap.carrots) do
			local sprite = createCarrot(c.x, c.baseY, false)
			if sprite then table.insert(carrots, sprite) end
		end
		if snap.white then
			local sprite = createCarrot(snap.white.x, snap.white.baseY, true)
			if sprite then
				sprite.spawnTime = snap.white.spawnTime
				whiteCarrot = sprite
			end
		end

		bunny:moveTo(snap.bunnyX, snap.bunnyY)
		yVelocity, xVelocity, isOnGround, facing = snap.yVel, snap.xVel, snap.onGround, snap.facing
		standingPlatform, coyoteFrames, jumpPressedTime = snap.standing, snap.coyote, snap.jumpTime
		PowerUps.usedDoubleJump = snap.usedDouble
		carrotCount = snap.carrotCount
		carrotCollectionTimes = { table.unpack(snap.collectTimes) }
		lastWhiteCarrotTime, whiteCarrotSpawnDelay = snap.lastWhite, snap.whiteDelay
		if isOnGround then setStandingSprite() elseif yVelocity < 0 then setHopSprite() else setFallSprite() end
	end,
})

-- A hazard touched the bunny. A shield absorbs the hit (followed by a short blink of
-- invincibility so you can get clear); otherwise it's game over.
local function hitBunny()
	if gameState ~= "playing" then return end
	if PowerUps.absorbHit(bunny) then return end
	local hitX, hitY = bunny:getPosition()
	if Rewind.tryStart(hitX, hitY) then
		gameState = "rewind"
		return
	end
	die()
end

local function updateDying()
	deathVelocity += (deathVelocity >= 0) and GRAVITY * FALL_GRAVITY_MULTIPLIER or GRAVITY
	bunny:moveBy(0, deathVelocity)

	local _, by = bunny:getPosition()
	local _, bunnyHeight = bunny:getSize()
	if by - bunnyHeight > SCREEN_H or nowMs() - deathStartMs >= DEATH_FALL_MAX_MS then
		gameState = "dead"
		deadSinceMs = nowMs()
	end
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

	-- Scenery is animated, so have the sprite system redraw the whole background every frame
	if gameState == "playing" or gameState == "dying" or gameState == "rewind" then
		gfx.sprite.redrawBackground()
	end

	-- Slow motion: hold B while playing, as long as there's focus left (clock.lua)
	SlowMo.update(gameState == "playing", playdate.buttonIsPressed(playdate.kButtonB))

	-- update timer (elapsed time) regardless of paused/dead for display
	if gameState == "playing" then
		elapsedTime = (nowMs() - startTimeMs) / 1000.0
	end

	-- Achievement pop-ups
	Progress.updateNotifications()

	-- Online leaderboard: queued runs upload automatically at any time; the list is only fetched outside gameplay
	OnlineLeaderboard.update(gameState ~= "playing" and gameState ~= "dying")

	-- handle input for menu/state
	if playdate.keyboard.isVisible() then
		-- The name-entry keyboard has input focus
	elseif gameState == "mainmenu" then
		-- Up/Down to navigate menu, A to select, B to restart
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			menuSelection = math.max(1, menuSelection - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			menuSelection = math.min(#mainMenuOptions, menuSelection + 1)
		elseif playdate.buttonJustPressed(playdate.kButtonA) then
			if menuSelection == 1 then
				-- Reset current stats and start game
				carrotCount = 0
				elapsedTime = 0.0
				startTimeMs = nowMs()
				gameState = "playing"
				restartGame()
			elseif menuSelection == 2 then
				openLeaderboard()
			elseif menuSelection == 3 then
				openAchievements()
			elseif menuSelection == 4 then
				openNameEntry()
			end
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			-- Reset current stats and start game
			carrotCount = 0
			elapsedTime = 0.0
			startTimeMs = nowMs()
			gameState = "playing"
			restartGame()
		end
	elseif gameState == "dead" and nowMs() - deadSinceMs < DEAD_INPUT_DELAY_MS then
		-- Just died: ignore buttons for a moment so a jump press can't skip the results
	elseif gameState == "dead" then
		-- Left/Right (or Up/Down) to navigate the row of buttons, A to select, B to restart
		if playdate.buttonJustPressed(playdate.kButtonLeft) or playdate.buttonJustPressed(playdate.kButtonUp) then
			menuSelection = math.max(1, menuSelection - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonRight) or playdate.buttonJustPressed(playdate.kButtonDown) then
			menuSelection = math.min(#menuOptions, menuSelection + 1)
		elseif playdate.buttonJustPressed(playdate.kButtonA) then
			if menuSelection == 1 then
				restartGame()
			elseif menuSelection == 2 then
				openLeaderboard()
			elseif menuSelection == 3 then
				openAchievements()
			elseif menuSelection == 4 then
				gameState = "mainmenu"
				menuSelection = 1
			end
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			restartGame()
		end
	elseif gameState == "leaderboard" then
		-- A or B to go back
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			gameState = returnState
		end
		-- Left/Right to switch between the local and online lists
		if playdate.buttonJustPressed(playdate.kButtonLeft) or playdate.buttonJustPressed(playdate.kButtonRight) then
			leaderboardTab = (leaderboardTab == "local") and "online" or "local"
			leaderboardScrollOffset = 0
			if leaderboardTab == "online" then OnlineLeaderboard.refresh() end
		end
		-- Up/Down to scroll (if needed)
		local shownEntries = (leaderboardTab == "online") and OnlineLeaderboard.entries or Progress.leaderboard
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			leaderboardScrollOffset = math.max(0, leaderboardScrollOffset - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			leaderboardScrollOffset = math.min(math.max(0, #shownEntries - 7), leaderboardScrollOffset + 1)
		end
	elseif gameState == "achievements" then
		-- A or B to go back
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			gameState = returnState
		end
		-- Up/Down to scroll (if needed)
		if playdate.buttonJustPressed(playdate.kButtonUp) then
			achievementsScrollOffset = math.max(0, achievementsScrollOffset - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonDown) then
			achievementsScrollOffset = math.min(math.max(0, #Progress.achievementDefinitions - 3), achievementsScrollOffset + 1)
		end
	elseif gameState == "dying" then
		updateDying()
	elseif gameState == "rewind" then
		local action = Rewind.update()
		if action == "resume" then
			gameState = "playing"
		elseif action == "giveup" then
			gameState = "playing"
			die()
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
		local jumpPressed = playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonUp)
		if jumpPressed and (isOnGround or coyoteFrames > 0) then
			yVelocity = JUMP_VELOCITY -- initial jump velocity
			isOnGround = false
			coyoteFrames = 0 -- grace is used up once you jump
			jumpPressedTime = 0
			setHopSprite()
			if jumpSound then
				jumpSound:play()
			end
		elseif jumpPressed and PowerUps.has("doubleJump") and not PowerUps.usedDoubleJump then
			-- Double jump power-up: one extra jump in mid-air
			PowerUps.usedDoubleJump = true
			yVelocity = JUMP_VELOCITY
			jumpPressedTime = 0
			setHopSprite()
			local fx, fy = bunny:getPosition()
			spawnParticles(fx, fy)
			if jumpSound then
				jumpSound:play()
			end
		end

		-- Down while standing on a platform (not the ground): drop through it
		if playdate.buttonJustPressed(playdate.kButtonDown) and isOnGround and standingPlatform then
			dropPlatform = standingPlatform
			dropUntilMs = nowMs() + DROP_THROUGH_MS
			standingPlatform = nil
			isOnGround = false
			coyoteFrames = 0 -- no jumping back up off the platform you just left
			yVelocity = 1
			setFallSprite()
		end

		-- Hold jump for additional lift
		if (playdate.buttonIsPressed(playdate.kButtonA) or playdate.buttonIsPressed(playdate.kButtonUp)) and not isOnGround and yVelocity < 0 then
			jumpPressedTime += 1
			if jumpPressedTime < JUMP_BOOST_FRAMES then
				yVelocity -= 0.25 -- accelerate upward (increased for higher jump)
			else
				yVelocity += 0.15 -- start decelerating
			end
		end

		-- Gravity + platform collisions
		if not isOnGround then
			local wasRising = yVelocity < 0
			-- Fall faster than you rise, up to a terminal speed
			if yVelocity >= 0 then
				yVelocity = math.min(MAX_FALL_SPEED, yVelocity + GRAVITY * FALL_GRAVITY_MULTIPLIER)
			else
				yVelocity += GRAVITY
			end
			local steps = math.ceil(math.abs(yVelocity))
			local stepSize = yVelocity / steps

			for i = 1, steps do
				bunny:moveBy(0, stepSize)
				local bx, by = bunny:getPosition()
				for _, plat in ipairs(platforms) do
					local px, py = plat:getPosition()
					local pw, ph = plat:getSize()
					local pLeft, pRight, pTop = px - pw/2, px + pw/2, py - ph/2
					if bx > pLeft and bx < pRight and not ignoringPlatform(plat) then
						local hitRect = bunny:getCollideRect()
						local hitH = hitRect.height or 22
						local bunnyBottom = by - (hitH / 2) + 10
						local distanceAbove = pTop - bunnyBottom
						if distanceAbove >= -LEDGE_ASSIST_PX and distanceAbove <= 2 and yVelocity >= 0 then
							yVelocity = 0
							isOnGround = true
							standingPlatform = plat
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
		standingPlatform = nil
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
				if bx > pLeft and bx < pRight and not ignoringPlatform(plat) then
					local distanceAbove = pTop - bunnyBottomHalf
					if distanceAbove >= -LEDGE_ASSIST_PX and distanceAbove <= 6 and yVelocity >= 0 then
						newGroundTop = pTop
						isOnGround = true
						standingPlatform = plat
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

		-- Coyote time: keep a few frames of jump grace after walking off a ledge
		if isOnGround then
			coyoteFrames = COYOTE_FRAMES
			PowerUps.usedDoubleJump = false
		elseif coyoteFrames > 0 then
			coyoteFrames -= 1
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
						slowmo.focus = math.min(1, slowmo.focus + slowmo.REFILL_CARROT * 3)
						-- Track 3 carrot collections for white carrot
						table.insert(carrotCollectionTimes, now)
						table.insert(carrotCollectionTimes, now)
						table.insert(carrotCollectionTimes, now)
						-- Remove white carrot and schedule next one
						removeWhiteCarrot()
					else
						carrotCount += 1
						slowmo.focus = math.min(1, slowmo.focus + slowmo.REFILL_CARROT)
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
					Progress.checkAchievement("speed_collector_5", carrotCount, carrotCollectionTimes)
					Progress.checkAchievement("speed_collector_10", carrotCount, carrotCollectionTimes)
					Progress.checkAchievement("carrot_master", carrotCount, carrotCollectionTimes)
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
				slowmo.focus = math.min(1, slowmo.focus + slowmo.REFILL_CARROT * 3)
				
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
				Progress.checkAchievement("speed_collector_5", carrotCount, carrotCollectionTimes)
				Progress.checkAchievement("speed_collector_10", carrotCount, carrotCollectionTimes)
				Progress.checkAchievement("carrot_master", carrotCount, carrotCollectionTimes)
				
				removeWhiteCarrot()
			end
		end

		-- White carrot timeout check (8 seconds)
		if whiteCarrot and not whiteCarrot.removed then
			local now = slowmo.now()
			if now - whiteCarrot.spawnTime >= 8000 then
				removeWhiteCarrot()
			end
		end

		-- White carrot spawn check (10-15 seconds after last one disappeared)
		if not whiteCarrot then
			local now = slowmo.now()
			if now - lastWhiteCarrotTime >= whiteCarrotSpawnDelay then
				spawnWhiteCarrot()
			end
		end

		PowerUps.update(bunny, findValidSpawnPosition)
		local bunnyX, bunnyY = bunny:getPosition()
		setSpawnAvoid(bunnyX, bunnyY - 12)

		---------------------------------------------------------------------

		-- Arrows and obstacles: spawn, move, and check whether anything hit the bunny (hazards.lua).
		-- Standing on a platform makes you safe from cannonballs.
		Hazards.update(elapsedTime)
		if Hazards.checkHits(getBunnyHitRect(), isOnGround and standingPlatform ~= nil) then
			hitBunny()
		end
		if gameState == "playing" then Rewind.record() end
	end -- end playing-block

	-- Update particles every frame
	Particles.update()

	-- Control bunny visibility based on game state
	local inGame = gameState == "playing" or gameState == "dying" or gameState == "rewind"
	bunny:setVisible(inGame)
	if gameState == "playing" and PowerUps.isInvincible() then
		bunny:setVisible((nowMs() // 80) % 2 == 0) -- blink after the shield takes a hit
	end

	-- Update sprites & timers. While rewinding and moving, the world judders like a VHS tape.
	local judder = Rewind.isMoving()
	if judder then gfx.setDrawOffset(math.random(-2, 2), 0) end
	gfx.sprite.update()
	if judder then gfx.setDrawOffset(0, 0) end
	playdate.timer.updateTimers()

	-- Shield power-up: a ring of dots circling the bunny
	if gameState == "playing" and PowerUps.has("shield") then
		local bx, by, bw, bh = bunny:getBounds()
		local cx, cy = bx + bw / 2, by + bh / 2
		local spin = nowMs() / 400
		gfx.setColor(gfx.kColorBlack)
		for i = 0, 9 do
			local a = spin + i / 10 * math.pi * 2
			gfx.fillCircleAtPoint(cx + math.cos(a) * 17, cy + math.sin(a) * 17, 1.5)
		end
	end

	-- Wrecking-ball chains and the warning outlines of new obstacles (during play, rewind and death)
	if inGame then
		Hazards.drawOverlays()
	end

	-- HUD, menus, leaderboard, achievements and toasts (see ui.lua)
	UI.draw({
		gameState = gameState,
		menuSelection = menuSelection,
		mainMenuOptions = mainMenuOptions,
		playerName = (Progress.playerName ~= "") and Progress.playerName or "Player",
		highScore = Progress.highScore,
		highTime = Progress.highTime,
		lastScore = lastScore,
		lastTime = lastTime,
		newBest = lastRunWasBest,
		elapsedTime = elapsedTime,
		carrotCount = carrotCount,
		leaderboard = Progress.leaderboard,
		leaderboardTab = leaderboardTab,
		scrollOffset = (gameState == "achievements") and achievementsScrollOffset or leaderboardScrollOffset,
		online = OnlineLeaderboard,
		achievementDefinitions = Progress.achievementDefinitions,
		achievements = Progress.achievements,
		power = (gameState == "playing") and PowerUps.hudInfo() or nil,
		slowFocus = slowmo.focus,
		rewind = Rewind.uiState(),
		rewindPlayAge = (gameState == "playing") and (playdate.getCurrentTimeMilliseconds() - Rewind.resumedMs) or nil,
		rewindCharges = (gameState == "playing" or gameState == "rewind") and Rewind.charges() or nil,
		slowActive = slowmo.active,
		notification = Progress.activeNotification,
		notificationAge = Progress.activeNotification and (nowMs() - Progress.activeNotification.startTime) or 0,
		formatTime = formatTime,
		images = uiImages,
	})
end
