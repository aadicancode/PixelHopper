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
local gameState = "mainmenu" -- "mainmenu" | "playing" | "dead" | "menu"
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

-- === UI / Menu selection for death screen ===
local menuOptions = { "RESTART", "HIGH SCORE" }
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

	carrotCount = 0
	startTimeMs = playdate.getCurrentTimeMilliseconds()
	lastArrowSpawn = startTimeMs
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
		-- Restart on A or B
		if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
			restartGame()
		end
	elseif gameState == "menu" then
		-- A to go back, B to restart
		if playdate.buttonJustPressed(playdate.kButtonA) then
			gameState = "dead"
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			restartGame()
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
		local instText = "A: Restart  B: Restart"
		local instWidth = font:getTextWidth(instText)
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
