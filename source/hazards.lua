-- Everything that can hit the bunny: arrows falling from the top, and the obstacles (saws, wrecking
-- balls, cannons and their cannonballs, spike balls). Creating, spawning and moving them, their
-- hitboxes, their warning outlines, and saving/restoring them for rewind.
--
-- Hazards run on the slow-motion world clock (SlowMo.now) and scale their per-frame movement by
-- SlowMo.scale, so slow motion slows them down.

local gfx <const> = playdate.graphics
local SCREEN_W <const>, SCREEN_H <const> = World.SCREEN_W, World.SCREEN_H
local GROUND_TOP <const> = World.GROUND_TOP
local LEFT_BOUND <const>, RIGHT_BOUND <const> = World.LEFT_BOUND, World.RIGHT_BOUND

Hazards = {
	arrows = {},
	saws = {},
	wreckingBalls = {},
	cannons = {},
	spikeBalls = {},
	projectiles = {}, -- cannonballs
	platforms = {}, -- set by main.lua; wrecking balls hang from them

	lastArrowSpawn = 0,
	lastObstacleSpawn = 0, -- 0 means "spawn the first obstacle right away"
	obstacleSpawnInterval = 0,

	-- Hitbox sizes (squares around the center, a bit smaller than the art)
	SAW_HITBOX = 24 * 0.8,
	WRECKING_BALL_HITBOX = 20 * 0.8,
	SPIKE_BALL_HITBOX = 18 * 0.8,

	CANNON_BARREL_HEIGHT = 16, -- barrel center above the base of the 24px cannon image
	WRECKING_BALL_CHAIN_LENGTH = 50,
}
local H = Hazards
local arrows, saws, wreckingBalls = H.arrows, H.saws, H.wreckingBalls
local cannons, spikeBalls, projectiles = H.cannons, H.spikeBalls, H.projectiles

-- Speeds (per frame at normal speed)
local SAW_SPEED = 2.0
local SAW_ROTATION_SPEED = 5.0 -- degrees per frame
local WRECKING_BALL_ROTATION_SPEED = 0.05 -- radians per frame
local SPIKE_BALL_VERTICAL_SPEED = 2.0
local SPIKE_BALL_DIAGONAL_SPEED = 2.5
local SPIKE_BALL_ROTATION_SPEED = 4.0 -- degrees per frame
local CANNON_PROJECTILE_SPEED = 3.0
local CANNON_FIRE_INTERVAL = 2000 -- milliseconds between shots (world clock)
local FLASH_MS = 2000 -- obstacles flash this long before they become dangerous

-------------------------------------------------------
-- Images, loaded once (with placeholders if a file is missing)
-------------------------------------------------------
local function placeholder(w, h, draw)
	local img = gfx.image.new(w, h)
	gfx.pushContext(img)
		draw()
	gfx.popContext()
	return img
end

local arrowImg = World.loadImage("images/arrow.png") or placeholder(12, 12, function()
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 5, 12, 2)
	gfx.fillRect(8, 2, 4, 8)
end)

local sawImg = World.loadImage("images/saw.png") or placeholder(24, 24, function()
	gfx.setColor(gfx.kColorBlack)
	gfx.fillCircleAtPoint(12, 12, 12)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillCircleAtPoint(12, 12, 10)
	gfx.setColor(gfx.kColorBlack)
	for i = 0, 7 do
		local a = i * math.pi / 4
		gfx.drawLine(12 + math.cos(a) * 10, 12 + math.sin(a) * 10, 12 + math.cos(a) * 12, 12 + math.sin(a) * 12)
	end
end)

local wreckingBallImg = placeholder(20, 20, function()
	gfx.setColor(gfx.kColorBlack)
	gfx.fillCircleAtPoint(10, 10, 10)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillCircleAtPoint(10, 10, 8)
end)

local cannonImgRight = World.loadImage("images/cannon.png") or placeholder(24, 16, function()
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 0, 24, 16)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(2, 2, 20, 12)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(16, 6, 8, 4)
end)
local cannonImgLeft = cannonImgRight:scaledImage(-1, 1)

local spikeBallImg = World.loadImage("images/spikeball.png") or placeholder(18, 18, function()
	gfx.setColor(gfx.kColorBlack)
	gfx.fillCircleAtPoint(9, 9, 9)
	gfx.setColor(gfx.kColorWhite)
	for i = 0, 7 do
		local a = i * math.pi / 4
		gfx.drawLine(9 + math.cos(a) * 7, 9 + math.sin(a) * 7, 9 + math.cos(a) * 11, 9 + math.sin(a) * 11)
	end
end)

local cannonballImg = World.loadImage("images/cannonball.png") or placeholder(12, 12, function()
	gfx.setColor(gfx.kColorBlack)
	gfx.fillCircleAtPoint(6, 6, 6)
end)

-------------------------------------------------------
-- Arrows
-------------------------------------------------------
-- Create an arrow at x that slides in from above the screen, then falls at vy
function H.spawnArrowAt(x, vy)
	local a = {}
	a.sprite = gfx.sprite.new(arrowImg)
	a.sprite:setCenter(0.5, 0)
	local _, arrowHeight = arrowImg:getSize()
	a.startY = -arrowHeight
	a.targetY = 4 -- where the tip becomes visible
	a.sprite:moveTo(x, a.startY)
	a.sprite:add()
	a.vx = 0
	a.vy = vy or 2.5
	a.startTime = SlowMo.now()
	a.slideDuration = 1000 -- the slide in takes 1 second
	a.isSlidingIn = true
	table.insert(arrows, a)
	return a
end

-- Arrow difficulty over a run (runSeconds = time since the run started):
--   more arrows allowed on screen at once: 0s: 1   40s: 2   80s: 3   120s+: 4
--   falling a little faster: 2.5 -> 3.5 over the first 2 minutes
--   coming more often: 2.2s between arrows at the start, down to 0.9s after about 2 minutes
function H.arrowsAllowed(runSeconds)
	return math.min(4, 1 + runSeconds // 40)
end

function H.arrowFallSpeed(runSeconds)
	return 2.5 + math.min(1, runSeconds / 120)
end

function H.arrowSpawnInterval(runSeconds)
	return math.max(900, 2200 - runSeconds * 11)
end

-- Spawn an arrow at a random x, if fewer than the allowed number are on screen. It won't start
-- right next to another arrow, so two never fall as one.
function H.spawnRandomArrow(runSeconds)
	if #arrows >= H.arrowsAllowed(runSeconds) then return end
	local margin = 12
	for _ = 1, 10 do
		local x = math.random(margin, SCREEN_W - margin)
		local clear = true
		for _, a in ipairs(arrows) do
			local ax = a.sprite:getPosition()
			if math.abs(ax - x) < 40 then clear = false break end
		end
		if clear then
			H.spawnArrowAt(x, H.arrowFallSpeed(runSeconds))
			return
		end
	end
end

local function updateArrows()
	local now = SlowMo.now()
	for i = #arrows, 1, -1 do
		local a = arrows[i]
		if a and a.sprite then
			local ax, ay = a.sprite:getPosition()
			if a.isSlidingIn then
				-- First: slide in from the top over slideDuration
				local elapsed = now - a.startTime
				if elapsed >= a.slideDuration then
					a.sprite:moveTo(ax, a.targetY)
					a.isSlidingIn = false
				else
					local progress = elapsed / a.slideDuration
					a.sprite:moveTo(ax, a.startY + (a.targetY - a.startY) * progress)
				end
				ax, ay = a.sprite:getPosition()
			else
				-- Then: fall
				a.sprite:moveBy(a.vx * SlowMo.scale, a.vy * SlowMo.scale)
				ax, ay = a.sprite:getPosition()
			end

			-- Remove when it reaches the ground or goes off screen
			if ay >= 210 or ay > SCREEN_H + 20 then
				a.sprite:remove()
				table.remove(arrows, i)
			end
		else
			table.remove(arrows, i)
		end
	end
end

-------------------------------------------------------
-- Warning flash: new obstacles flash for FLASH_MS before they can hurt
-------------------------------------------------------
local function startFlashingEffect(obstacle, sprite)
	obstacle.isFlashing = true
	obstacle.flashStartTime = SlowMo.now()
	obstacle.flashDuration = FLASH_MS
	obstacle.flashVisible = true
	obstacle.flashTimer = playdate.timer.new(200, function()
		if obstacle and not obstacle.removed then
			obstacle.flashVisible = not obstacle.flashVisible
			if sprite then sprite:setVisible(obstacle.flashVisible) end
		end
	end)
	obstacle.flashTimer.repeats = true
end

local function updateFlashingEffect(obstacle, sprite)
	if obstacle.isFlashing and SlowMo.now() - obstacle.flashStartTime >= obstacle.flashDuration then
		obstacle.isFlashing = false
		if obstacle.flashTimer then
			obstacle.flashTimer:remove()
			obstacle.flashTimer = nil
		end
		if sprite then sprite:setVisible(true) end
	end
end

-------------------------------------------------------
-- Creating obstacles
-------------------------------------------------------
function H.createSaw(x, y)
	local sprite = gfx.sprite.new(sawImg)
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:setZIndex(-1) -- behind the ground, so the buried half is hidden
	sprite:add()

	local direction = (math.random() > 0.5) and 1 or -1
	local saw = {
		sprite = sprite,
		size = sawImg:getSize(), -- unrotated width, for the flashing outline
		state = "ground", -- "ground", "wallUp", "wallDown"
		x = x,
		y = y,
		direction = direction, -- horizontal direction: 1 = right, -1 = left
		wallSide = nil, -- which wall it's on: "left" or "right"
		rotation = 0, -- degrees
		spin = direction, -- spin direction; flips when the saw turns around at the ceiling
		isFlashing = false,
		removed = false
	}
	startFlashingEffect(saw, sprite)
	return saw
end

function H.createWreckingBall(anchorX, anchorY)
	local sprite = gfx.sprite.new(wreckingBallImg)
	sprite:setCenter(0.5, 0.5)
	local angle = math.random() * math.pi * 2
	sprite:moveTo(anchorX + math.cos(angle) * H.WRECKING_BALL_CHAIN_LENGTH, anchorY + math.sin(angle) * H.WRECKING_BALL_CHAIN_LENGTH)
	sprite:add()

	local ball = {
		sprite = sprite,
		anchorX = anchorX,
		anchorY = anchorY,
		angle = angle,
		isFlashing = false,
		removed = false
	}
	startFlashingEffect(ball, sprite)
	return ball
end

function H.createCannon(x, y, facing)
	local sprite = gfx.sprite.new(facing == "left" and cannonImgLeft or cannonImgRight)
	sprite:setCenter(0.5, 1.0) -- bottom-aligned, so y is its base
	sprite:moveTo(x, y)
	sprite:add()

	local cannon = {
		sprite = sprite,
		x = x,
		y = y,
		facing = facing, -- "left" or "right"
		lastFireTime = SlowMo.now(),
		isFlashing = false,
		removed = false
	}
	startFlashingEffect(cannon, sprite)
	return cannon
end

-- type: "vertical" (bounces up and down), "diagonal1" or "diagonal2" (bounce off the edges)
function H.createSpikeBall(type, x, y)
	local sprite = gfx.sprite.new(spikeBallImg)
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:add()

	local spikeBall = {
		sprite = sprite,
		size = spikeBallImg:getSize(), -- unrotated width, for the flashing outline
		type = type,
		x = x,
		y = y,
		vx = 0,
		vy = 0,
		rotation = 0,
		isFlashing = false,
		removed = false
	}
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

-- direction: 1 for right, -1 for left
function H.createCannonProjectile(x, y, direction)
	local sprite = gfx.sprite.new(cannonballImg)
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:add()

	return {
		sprite = sprite,
		x = x,
		y = y,
		vx = direction * CANNON_PROJECTILE_SPEED,
		vy = 0,
		removed = false
	}
end

-------------------------------------------------------
-- Moving obstacles
-------------------------------------------------------
-- The saw's center runs along the ground line and the screen edges, so it's always half buried in
-- the ground or half off the side of the screen (and only a quarter shows in the corners). It climbs
-- a wall until its top touches the ceiling, then reverses back down; it never runs along the ceiling.
local function updateSaw(saw)
	if saw.removed or not saw.sprite then return end
	updateFlashingEffect(saw, saw.sprite)

	saw.rotation = (saw.rotation + SAW_ROTATION_SPEED * saw.spin * SlowMo.scale) % 360
	saw.sprite:setRotation(saw.rotation)

	if saw.isFlashing then return end
	local sawRadius = saw.size / 2
	if saw.state == "ground" then
		saw.y = GROUND_TOP
		saw.x += saw.direction * SAW_SPEED * SlowMo.scale
		if saw.x <= 0 then
			saw.x = 0
			saw.wallSide = "left"
			saw.state = "wallUp"
		elseif saw.x >= SCREEN_W then
			saw.x = SCREEN_W
			saw.wallSide = "right"
			saw.state = "wallUp"
		end
	elseif saw.state == "wallUp" then
		saw.y -= SAW_SPEED * SlowMo.scale
		if saw.y <= sawRadius then
			-- top of the saw reached the ceiling: turn around
			saw.y = sawRadius
			saw.state = "wallDown"
			saw.spin = -saw.spin
		end
	elseif saw.state == "wallDown" then
		saw.y += SAW_SPEED * SlowMo.scale
		if saw.y >= GROUND_TOP then
			-- back at the corner: roll out across the ground, away from this wall
			saw.y = GROUND_TOP
			saw.state = "ground"
			saw.direction = (saw.wallSide == "left") and 1 or -1
		end
	end
	saw.sprite:moveTo(saw.x, saw.y)
end

local function updateWreckingBall(ball)
	if ball.removed or not ball.sprite then return end
	updateFlashingEffect(ball, ball.sprite)
	if ball.isFlashing then return end
	ball.angle += WRECKING_BALL_ROTATION_SPEED * SlowMo.scale
	ball.sprite:moveTo(ball.anchorX + math.cos(ball.angle) * H.WRECKING_BALL_CHAIN_LENGTH,
		ball.anchorY + math.sin(ball.angle) * H.WRECKING_BALL_CHAIN_LENGTH)
end

local function updateCannon(cannon)
	if cannon.removed or not cannon.sprite then return end
	updateFlashingEffect(cannon, cannon.sprite)
	if cannon.isFlashing then return end
	local now = SlowMo.now()
	if now - cannon.lastFireTime >= CANNON_FIRE_INTERVAL then
		cannon.lastFireTime = now
		local direction = (cannon.facing == "right") and 1 or -1
		local barrelX = cannon.x + direction * 16 -- just past the barrel's mouth
		local barrelY = cannon.y - H.CANNON_BARREL_HEIGHT
		table.insert(projectiles, H.createCannonProjectile(barrelX, barrelY, direction))
	end
end

local function updateSpikeBall(spikeBall)
	if spikeBall.removed or not spikeBall.sprite then return end
	updateFlashingEffect(spikeBall, spikeBall.sprite)

	spikeBall.rotation = (spikeBall.rotation + SPIKE_BALL_ROTATION_SPEED * SlowMo.scale) % 360
	spikeBall.sprite:setRotation(spikeBall.rotation)

	if spikeBall.isFlashing then return end
	if spikeBall.type == "vertical" then
		-- Up and down, bouncing at the top and bottom
		spikeBall.y += spikeBall.vy * SlowMo.scale
		spikeBall.sprite:moveTo(spikeBall.x, spikeBall.y)
		if spikeBall.y <= 20 then
			spikeBall.y = 20
			spikeBall.vy = SPIKE_BALL_VERTICAL_SPEED
		elseif spikeBall.y >= GROUND_TOP - 9 then
			spikeBall.y = GROUND_TOP - 9
			spikeBall.vy = -SPIKE_BALL_VERTICAL_SPEED
		end
	else
		-- Diagonally, bouncing off the screen edges
		spikeBall.x += spikeBall.vx * SlowMo.scale
		spikeBall.y += spikeBall.vy * SlowMo.scale
		spikeBall.sprite:moveTo(spikeBall.x, spikeBall.y)
		if spikeBall.x <= LEFT_BOUND + 9 then
			spikeBall.x = LEFT_BOUND + 9
			spikeBall.vx = -spikeBall.vx
		elseif spikeBall.x >= RIGHT_BOUND - 9 then
			spikeBall.x = RIGHT_BOUND - 9
			spikeBall.vx = -spikeBall.vx
		end
		if spikeBall.y <= 20 then
			spikeBall.y = 20
			spikeBall.vy = -spikeBall.vy
		elseif spikeBall.y >= GROUND_TOP - 9 then
			spikeBall.y = GROUND_TOP - 9
			spikeBall.vy = -spikeBall.vy
		end
	end
end

local function updateCannonProjectile(projectile)
	if projectile.removed or not projectile.sprite then return end
	projectile.x += projectile.vx * SlowMo.scale
	projectile.sprite:moveTo(projectile.x, projectile.y)
	if projectile.x < -20 or projectile.x > SCREEN_W + 20 then
		projectile.sprite:remove()
		projectile.removed = true
	end
end

-- Update every item in a list, dropping removed ones
local function updateList(list, update)
	for i = #list, 1, -1 do
		local o = list[i]
		if o and not o.removed then update(o) end
		if not o or o.removed then table.remove(list, i) end
	end
end

-------------------------------------------------------
-- Spawning obstacles
-------------------------------------------------------
-- Cannon positions (6 total: left and right on three levels). y is the cannon's base; the barrel
-- is CANNON_BARREL_HEIGHT above it. Standing on a platform is safe from cannonballs, so:
--   ground level: shots at y=205 hit a bunny on the ground, and have to be jumped over
--   low level:    shots at y=160 cross the lowest platforms at body height (tops at 170): they
--                 catch you jumping up to or dropping off those platforms
--   middle level: shots at y=110, the same for the middle platforms (tops at 120)
local CANNON_POSITIONS = {
	{ x = LEFT_BOUND, y = 205 + H.CANNON_BARREL_HEIGHT, facing = "right" },
	{ x = RIGHT_BOUND, y = 205 + H.CANNON_BARREL_HEIGHT, facing = "left" },
	{ x = LEFT_BOUND, y = 160 + H.CANNON_BARREL_HEIGHT, facing = "right" },
	{ x = RIGHT_BOUND, y = 160 + H.CANNON_BARREL_HEIGHT, facing = "left" },
	{ x = LEFT_BOUND, y = 110 + H.CANNON_BARREL_HEIGHT, facing = "right" },
	{ x = RIGHT_BOUND, y = 110 + H.CANNON_BARREL_HEIGHT, facing = "left" },
}

local SPIKE_BALL_TYPES = {
	{ type = "vertical", x = SCREEN_W / 2, y = 120 },
	{ type = "diagonal1", x = SCREEN_W / 2, y = 120 },
	{ type = "diagonal2", x = SCREEN_W / 2, y = 120 },
}

-- Saws spawn half buried in the ground at a random position (max 3)
function H.spawnSaw()
	if #saws >= 3 then return end
	table.insert(saws, H.createSaw(math.random(LEFT_BOUND + 16, RIGHT_BOUND - 16), GROUND_TOP))
end

-- Wrecking balls hang from platforms, one per platform (max 3)
function H.spawnWreckingBall()
	if #wreckingBalls >= 3 then return end
	local available = {}
	for _, plat in ipairs(H.platforms) do
		local used = false
		for _, ball in ipairs(wreckingBalls) do
			if not ball.removed and ball.platform == plat then used = true break end
		end
		if not used then table.insert(available, plat) end
	end
	if #available == 0 then return end
	local plat = available[math.random(1, #available)]
	local px, py = plat:getPosition()
	local ball = H.createWreckingBall(px, py - 5)
	ball.platform = plat
	table.insert(wreckingBalls, ball)
end

-- Cannons take one of the free CANNON_POSITIONS (max 6)
function H.spawnCannon()
	if #cannons >= 6 then return end
	local available = {}
	for _, pos in ipairs(CANNON_POSITIONS) do
		local used = false
		for _, cannon in ipairs(cannons) do
			if cannon.sprite and not cannon.removed and math.abs(cannon.x - pos.x) < 5 and math.abs(cannon.y - pos.y) < 5 then
				used = true
				break
			end
		end
		if not used then table.insert(available, pos) end
	end
	if #available == 0 then return end
	local pos = available[math.random(1, #available)]
	table.insert(cannons, H.createCannon(pos.x, pos.y, pos.facing))
end

-- Spike balls start in the middle of the screen (max 3)
function H.spawnSpikeBall()
	if #spikeBalls >= 3 then return end
	local t = SPIKE_BALL_TYPES[math.random(1, #SPIKE_BALL_TYPES)]
	table.insert(spikeBalls, H.createSpikeBall(t.type, t.x, t.y))
end

-- Spawn one obstacle of a random type that isn't at its limit
local function spawnRandomObstacle()
	local types = {}
	if #saws < 3 then table.insert(types, H.spawnSaw) end
	if #wreckingBalls < 3 then table.insert(types, H.spawnWreckingBall) end
	if #cannons < 6 then table.insert(types, H.spawnCannon) end
	if #spikeBalls < 3 then table.insert(types, H.spawnSpikeBall) end
	if #types > 0 then types[math.random(1, #types)]() end
end

-------------------------------------------------------
-- Each frame while playing
-------------------------------------------------------
-- Spawn and move everything. runSeconds is the time since the run started (for difficulty).
function H.update(runSeconds)
	local now = SlowMo.now()

	-- Arrows
	if now - H.lastArrowSpawn >= H.arrowSpawnInterval(runSeconds) then
		H.lastArrowSpawn = now
		H.spawnRandomArrow(runSeconds)
	end
	updateArrows()

	-- Obstacles: the first one comes right away, then one every 13-17 seconds
	if H.lastObstacleSpawn == 0 or now - H.lastObstacleSpawn >= H.obstacleSpawnInterval then
		H.lastObstacleSpawn = now
		H.obstacleSpawnInterval = 13000 + math.random(4000)
		spawnRandomObstacle()
	end

	updateList(saws, updateSaw)
	updateList(wreckingBalls, updateWreckingBall)
	updateList(cannons, updateCannon)
	updateList(spikeBalls, updateSpikeBall)
	updateList(projectiles, updateCannonProjectile)
end

-------------------------------------------------------
-- Hitboxes
-------------------------------------------------------
-- Fixed-size square around a sprite's center; unlike getBounds, it doesn't grow when the sprite rotates
function H.centeredRect(sprite, size)
	local x, y = sprite:getPosition()
	return playdate.geometry.rect.new(x - size / 2, y - size / 2, size, size)
end

local function arrowHitRect(a)
	return playdate.geometry.rect.new(a.sprite:getBounds())
end

-- Cannonballs are round: hit only when the circle of the art touches the rect, not its square corners
local CANNONBALL_RADIUS <const> = cannonballImg:getSize() / 2

local function projectileHits(projectile, rect)
	local cx, cy = projectile.sprite:getPosition()
	local nearestX = math.max(rect.x, math.min(cx, rect.x + rect.width))
	local nearestY = math.max(rect.y, math.min(cy, rect.y + rect.height))
	local dx, dy = cx - nearestX, cy - nearestY
	return dx * dx + dy * dy < CANNONBALL_RADIUS * CANNONBALL_RADIUS
end

-- Does anything dangerous overlap the bunny's hurtbox? Arrows only hurt once they're falling, and
-- obstacles not while they're still flashing. cannonSafe: the bunny is standing on a platform, where
-- cannonballs can't hit it.
function H.checkHits(bunnyRect, cannonSafe)
	for _, a in ipairs(arrows) do
		if a.sprite and not a.isSlidingIn and bunnyRect:intersects(arrowHitRect(a)) then return true end
	end
	for _, o in ipairs(saws) do
		if o.sprite and not o.isFlashing and bunnyRect:intersects(H.centeredRect(o.sprite, H.SAW_HITBOX)) then return true end
	end
	for _, o in ipairs(wreckingBalls) do
		if o.sprite and not o.isFlashing and bunnyRect:intersects(H.centeredRect(o.sprite, H.WRECKING_BALL_HITBOX)) then return true end
	end
	for _, o in ipairs(spikeBalls) do
		if o.sprite and not o.isFlashing and bunnyRect:intersects(H.centeredRect(o.sprite, H.SPIKE_BALL_HITBOX)) then return true end
	end
	if not cannonSafe then
		for _, o in ipairs(projectiles) do
			if o.sprite and not o.removed and projectileHits(o, bunnyRect) then return true end
		end
	end
	return false
end

-------------------------------------------------------
-- Drawing on top of the sprites: wrecking-ball chains and the warning outlines of new obstacles
-------------------------------------------------------
function H.drawOverlays()
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(1)
	for _, ball in ipairs(wreckingBalls) do
		if ball.sprite and not ball.removed then
			local bx, by = ball.sprite:getPosition()
			gfx.drawLine(ball.anchorX, ball.anchorY, bx, by)
		end
	end

	gfx.setLineWidth(2)
	for _, saw in ipairs(saws) do
		if saw.sprite and saw.isFlashing then gfx.drawRect(H.centeredRect(saw.sprite, saw.size)) end
	end
	for _, ball in ipairs(wreckingBalls) do
		if ball.sprite and ball.isFlashing then gfx.drawRect(ball.sprite:getBounds()) end
	end
	for _, cannon in ipairs(cannons) do
		if cannon.sprite and cannon.isFlashing then gfx.drawRect(cannon.sprite:getBounds()) end
	end
	for _, spikeBall in ipairs(spikeBalls) do
		if spikeBall.sprite and spikeBall.isFlashing then gfx.drawRect(H.centeredRect(spikeBall.sprite, spikeBall.size)) end
	end
	gfx.setLineWidth(1)
end

-------------------------------------------------------
-- New run: remove everything, and have the first obstacle spawn right away
-------------------------------------------------------
local function removeObstacle(o)
	if o.flashTimer then o.flashTimer:remove() end
	if o.sprite then o.sprite:remove() end
end

function H.clear()
	for i = #arrows, 1, -1 do
		if arrows[i].sprite then arrows[i].sprite:remove() end
		arrows[i] = nil
	end
	for _, list in ipairs({ saws, wreckingBalls, cannons, spikeBalls, projectiles }) do
		for i = #list, 1, -1 do
			removeObstacle(list[i])
			list[i] = nil
		end
	end
	H.lastArrowSpawn = SlowMo.now()
	H.lastObstacleSpawn = 0
	H.obstacleSpawnInterval = 0
end

-------------------------------------------------------
-- Rewind: save and restore every hazard as plain data
-------------------------------------------------------
function H.capture()
	local snap = {
		lastArrowSpawn = H.lastArrowSpawn,
		lastObstacleSpawn = H.lastObstacleSpawn,
		obstacleSpawnInterval = H.obstacleSpawnInterval,
		arrows = {}, saws = {}, balls = {}, cannons = {}, spikes = {}, shots = {},
	}
	for _, a in ipairs(arrows) do
		if a.sprite then
			local x, y = a.sprite:getPosition()
			table.insert(snap.arrows, { x = x, y = y, vx = a.vx, vy = a.vy, startTime = a.startTime, sliding = a.isSlidingIn })
		end
	end
	for _, o in ipairs(saws) do
		if not o.removed then
			table.insert(snap.saws, { x = o.x, y = o.y, state = o.state, dir = o.direction, wall = o.wallSide,
				rot = o.rotation, spin = o.spin, flashing = o.isFlashing, flashStart = o.flashStartTime })
		end
	end
	for _, o in ipairs(wreckingBalls) do
		if not o.removed then
			table.insert(snap.balls, { ax = o.anchorX, ay = o.anchorY, angle = o.angle, platform = o.platform,
				flashing = o.isFlashing, flashStart = o.flashStartTime })
		end
	end
	for _, o in ipairs(cannons) do
		if not o.removed then
			table.insert(snap.cannons, { x = o.x, y = o.y, facing = o.facing, lastFire = o.lastFireTime,
				flashing = o.isFlashing, flashStart = o.flashStartTime })
		end
	end
	for _, o in ipairs(spikeBalls) do
		if not o.removed then
			table.insert(snap.spikes, { type = o.type, x = o.x, y = o.y, vx = o.vx, vy = o.vy, rot = o.rotation,
				flashing = o.isFlashing, flashStart = o.flashStartTime })
		end
	end
	for _, o in ipairs(projectiles) do
		if not o.removed and o.sprite then
			table.insert(snap.shots, { x = o.x, y = o.y, vx = o.vx })
		end
	end
	return snap
end

-- Match a recreated obstacle's warning flash to the snapshot
local function restoreFlash(o, flashing, flashStart)
	o.isFlashing = flashing
	o.flashStartTime = flashStart
	if not flashing then
		if o.flashTimer then o.flashTimer:remove(); o.flashTimer = nil end
		o.sprite:setVisible(true)
	end
end

-- Rebuild every hazard exactly as it was in a snapshot
function H.restore(snap)
	local spawnTimers = { snap.lastArrowSpawn, snap.lastObstacleSpawn, snap.obstacleSpawnInterval }
	H.clear()
	H.lastArrowSpawn, H.lastObstacleSpawn, H.obstacleSpawnInterval = spawnTimers[1], spawnTimers[2], spawnTimers[3]

	for _, d in ipairs(snap.arrows) do
		local a = H.spawnArrowAt(d.x, d.vy)
		a.vx, a.startTime, a.isSlidingIn = d.vx, d.startTime, d.sliding
		a.sprite:moveTo(d.x, d.y)
	end
	for _, d in ipairs(snap.saws) do
		local o = H.createSaw(d.x, d.y)
		o.state, o.direction, o.wallSide, o.rotation, o.spin = d.state, d.dir, d.wall, d.rot, d.spin
		o.sprite:setRotation(d.rot)
		restoreFlash(o, d.flashing, d.flashStart)
		table.insert(saws, o)
	end
	for _, d in ipairs(snap.balls) do
		local o = H.createWreckingBall(d.ax, d.ay)
		o.angle, o.platform = d.angle, d.platform
		o.sprite:moveTo(d.ax + math.cos(d.angle) * H.WRECKING_BALL_CHAIN_LENGTH, d.ay + math.sin(d.angle) * H.WRECKING_BALL_CHAIN_LENGTH)
		restoreFlash(o, d.flashing, d.flashStart)
		table.insert(wreckingBalls, o)
	end
	for _, d in ipairs(snap.cannons) do
		local o = H.createCannon(d.x, d.y, d.facing)
		o.lastFireTime = d.lastFire
		restoreFlash(o, d.flashing, d.flashStart)
		table.insert(cannons, o)
	end
	for _, d in ipairs(snap.spikes) do
		local o = H.createSpikeBall(d.type, d.x, d.y)
		o.vx, o.vy, o.rotation = d.vx, d.vy, d.rot
		o.sprite:setRotation(d.rot)
		restoreFlash(o, d.flashing, d.flashStart)
		table.insert(spikeBalls, o)
	end
	for _, d in ipairs(snap.shots) do
		local o = H.createCannonProjectile(d.x, d.y, (d.vx >= 0) and 1 or -1)
		o.vx = d.vx
		table.insert(projectiles, o)
	end
end
