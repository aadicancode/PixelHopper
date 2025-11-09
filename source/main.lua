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
local carrotCount = 0

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
local function spawnSingleCarrot()
	-- Remove existing carrots safely
	for i = #carrots, 1, -1 do
		local c = carrots[i]
		if c then
			if c.flashTimer then c.flashTimer:remove() end
			if c.bounceTimer then c.bounceTimer:remove() end
			c:remove()
		end
		table.remove(carrots, i)
	end

	-- Pick a random platform
	if #platforms > 0 then
		local p = platforms[math.random(1, #platforms)]
		local px, py = p:getPosition()

		-- 1 in 8 chance for a white carrot
		local isWhite = (math.random(8) == 1)
		local img = isWhite and whiteCarrotImg or carrotImg
		if img then
			local carrot = gfx.sprite.new(img)
			carrot:setCenter(0.5, 1)
			carrot:moveTo(px, py - 12)
			carrot.baseY = py - 12
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
					carrot:moveTo(px, carrot.baseY + offset)
				end
			end)
			carrot.bounceTimer.repeats = true

			table.insert(carrots, carrot)
		end
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
spawnSingleCarrot()

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

-- === Game state management ===
local gameState = "playing" -- "playing" | "dead" | "menu"
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

local function loadHighScore()
	local data = playdate.datastore.read("highScore")
	if data and type(data) == "number" then
		highScore = data
	end
end

local function saveHighScore()
	playdate.datastore.write(highScore, "highScore")
end

loadHighScore()

-- === UI / Menu selection for death screen ===
local menuOptions = { "RESTART", "HIGH SCORE" }
local menuSelection = 1

-- === Utility: spawn an arrow at x, with vy ===
local function spawnArrowAt(x, vy)
	local a = {}
	a.img = arrowImg
	a.sprite = gfx.sprite.new(a.img)
	a.sprite:setCenter(0.5, 0)
	a.sprite:moveTo(x, -8)
	a.sprite:add()
	a.vx = 0
	a.vy = vy or (2 + math.random() * 2.0) -- random fall speed
	table.insert(arrows, a)
end

-- spawn a random top arrow
local function spawnRandomArrow()
	local margin = 12
	local x = math.random(margin, SCREEN_W - margin)
	spawnArrowAt(x, 2 + math.random() * 2.5)
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

	carrotCount = 0
	startTimeMs = playdate.getCurrentTimeMilliseconds()
	lastArrowSpawn = startTimeMs
	gameState = "playing"
	menuSelection = 1
	yVelocity = 0
	isOnGround = true
	bunny:moveTo(SCREEN_W / 2, GROUND_TOP)
	setStandingSprite()
	spawnSingleCarrot()
end

local function die()
	-- particle burst at bunny
	local bx, by, bwB, bhB = bunny:getBounds()
	spawnParticles(bx + bwB/2, by + bhB/2)

	-- update high score if needed (use carrotCount)
	if carrotCount > highScore then
		highScore = carrotCount
		saveHighScore()
	end

	gameState = "dead"
end

-- === Main Loop ===
function playdate.update()
	gfx.clear(gfx.kColorWhite)

	-- update timer (elapsed time) regardless of paused/dead for display
	if gameState == "playing" then
		elapsedTime = (playdate.getCurrentTimeMilliseconds() - startTimeMs) / 1000.0
	end

	-- top-left timer display (T1 format)
	gfx.setColor(gfx.kColorBlack)
	gfx.drawText(string.format("Time: %.1fs", elapsedTime), 8, 8)

	-- handle input for menu/state
	if gameState == "dead" then
		-- when dead, only menu left/right and select are active
		if playdate.buttonJustPressed(playdate.kButtonLeft) then
			menuSelection = math.max(1, menuSelection - 1)
		elseif playdate.buttonJustPressed(playdate.kButtonRight) then
			menuSelection = math.min(#menuOptions, menuSelection + 1)
		elseif playdate.buttonJustPressed(playdate.kButtonA) then
			if menuOptions[menuSelection] == "RESTART" then
				restartGame()
			elseif menuOptions[menuSelection] == "HIGH SCORE" then
				-- toggle to menu state that shows high score until A pressed
				gameState = "menu"
			end
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			-- also allow B to restart quickly
			restartGame()
		end
	elseif gameState == "menu" then
		-- in high score display state, press A to go back to dead screen (or restart)
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
							setStandingSprite()
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

					if c:getImage() == whiteCarrotImg then
						carrotCount += 3
					else
						carrotCount += 1
					end
					if c.flashTimer then c.flashTimer:remove() end
					if c.bounceTimer then c.bounceTimer:remove() end
					c:remove()
					table.remove(carrots, i)
					spawnSingleCarrot()
				end
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
				-- move
				a.sprite:moveBy(a.vx, a.vy)
				-- rotate slightly to look like falling: (optional)
				-- remove when offscreen
				local ax, ay = a.sprite:getPosition()
				if ay > SCREEN_H + 20 then
					a.sprite:remove()
					table.remove(arrows, i)
				else
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

	-- draw carrot count top-right
	gfx.setColor(gfx.kColorBlack)
	gfx.drawText("Carrots: " .. carrotCount, SCREEN_W - 100, 8)

	-- draw death/menu overlays
	if gameState == "dead" then
		-- Dark overlay
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 28, SCREEN_W, SCREEN_H - 28)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawText("YOU DIED", SCREEN_W / 2 - 40, 60)

		-- draw menu options
		local px = SCREEN_W / 2 - 80
		local py = 120
		for i, opt in ipairs(menuOptions) do
			local w = 120; local h = 28
			local x = px + (i-1) * (w + 20)
			-- highlight selection
			if i == menuSelection then
				gfx.setColor(gfx.kColorWhite)
				gfx.fillRect(x, py, w, h)
				gfx.setColor(gfx.kColorBlack)
				gfx.drawText(opt, x + 10, py + 6)
			else
				gfx.setColor(gfx.kColorWhite)
				gfx.drawRect(x, py, w, h)
				gfx.setColor(gfx.kColorWhite)
				-- draw text on transparent background
				gfx.setImageDrawMode(gfx.kDrawModeNXOR) -- ensures visible on dark overlay
				gfx.drawText(opt, x + 10, py + 6)
				gfx.setImageDrawMode(gfx.kDrawModeCopy)
				gfx.setColor(gfx.kColorWhite)
			end
		end

		-- instruction
		gfx.setColor(gfx.kColorWhite)
		gfx.drawText("Use ← → and A to select, B to restart", 30, 170)

		-- show high score small
		gfx.drawText("High: " .. tostring(highScore), SCREEN_W / 2 - 20, 200)
	elseif gameState == "menu" then
		-- show high score screen
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 28, SCREEN_W, SCREEN_H - 28)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawText("HIGH SCORE", SCREEN_W / 2 - 45, 60)
		gfx.drawText(tostring(highScore), SCREEN_W / 2 - 10, 110)
		gfx.drawText("Press A to go back, B to restart", 20, 170)
	end

	-- debug overlay
	if showDebug and gameState ~= "dead" and gameState ~= "menu" then
		gfx.setColor(gfx.kColorBlack)
		local dbx, dby = bunny:getPosition()
		gfx.drawText(string.format("x: %.1f y: %.1f", dbx, dby), 8, 32)
		gfx.drawText(string.format("yVel: %.2f", yVelocity), 8, 48)
		gfx.drawText("isOnGround: " .. tostring(isOnGround), 8, 64)
		gfx.drawText("Facing: " .. facing, 8, 80)
	end
end
