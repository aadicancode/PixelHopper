-- Rare power-ups. A bubble shows up now and then: at most one every 30-45s, and never while a power
-- is active. It pops if it isn't collected within LIFETIME_MS (flashing near the end).
--   shield:      blocks one hit, then a short blink of invincibility; wears off after SHIELD_MS
--   double jump: one extra jump in mid-air, for DOUBLE_JUMP_MS
-- Power-ups run on real time (Clock.now), not the slow-motion world clock.

local gfx <const> = playdate.graphics

PowerUps = {
	GAP_MIN_MS = 30000,
	GAP_MAX_MS = 45000,
	LIFETIME_MS = 8000,
	FLASH_MS = 2000,
	SHIELD_MS = 15000,
	DOUBLE_JUMP_MS = 10000,
	HIT_INVINCIBLE_MS = 1200,
	KINDS = { "shield", "doubleJump" },

	bubble = nil, -- the bubble on the field: { sprite, kind, spawnMs, x, baseY }
	active = nil, -- the power you have: { kind, untilMs }
	nextMs = 0, -- when the next bubble may appear
	invincibleUntilMs = 0,
	usedDoubleJump = false, -- the mid-air jump is spent until the next landing
}
local P = PowerUps
P.DURATION = { shield = P.SHIELD_MS, doubleJump = P.DOUBLE_JUMP_MS }

-------------------------------------------------------
-- Bubble icons (24x24): a clean white bubble with a bold outline and a small shine, with a
-- hand-drawn pixel-art icon inside ('#' = black, '.' = white, ' ' = leave as is)
-------------------------------------------------------
local SIZE = 24
local ICONS = {
	shield = {
		"##########",
		"#........#",
		"#.######.#",
		"#.##..##.#",
		"#.#....#.#",
		"#.##..##.#",
		"#.######.#",
		".#.####.#.",
		".#.####.#.",
		"..#.##.#..",
		"...#..#...",
		"....##....",
	},
	doubleJump = { -- two stacked up-chevrons: "jump up twice"
		".....##.....",
		"....####....",
		"...######...",
		"..###..###..",
		".###....###.",
		"###......###",
		".....##.....",
		"....####....",
		"...######...",
		"..###..###..",
		".###....###.",
		"###......###",
	},
}

local function drawPixelMap(map, x, y)
	for row, line in ipairs(map) do
		for col = 1, #line do
			local ch = string.sub(line, col, col)
			if ch == "#" then
				gfx.setColor(gfx.kColorBlack)
				gfx.drawPixel(x + col - 1, y + row - 1)
			elseif ch == "." then
				gfx.setColor(gfx.kColorWhite)
				gfx.drawPixel(x + col - 1, y + row - 1)
			end
		end
	end
end

local function makeImage(kind)
	local c = SIZE / 2
	local img = gfx.image.new(SIZE, SIZE, gfx.kColorClear)
	gfx.pushContext(img)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(c, c, 11)
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(2)
		gfx.drawCircleAtPoint(c, c, 10)
		gfx.setLineWidth(1)
		gfx.drawArc(c, c, 7, 295, 340) -- shine
		local icon = ICONS[kind]
		drawPixelMap(icon, math.floor(c - #icon[1] / 2), math.floor(c - #icon / 2) + ((#icon < 12) and 1 or 0))
	gfx.popContext()
	return img
end

P.images = { shield = makeImage("shield"), doubleJump = makeImage("doubleJump") }

-------------------------------------------------------
local function gap()
	return math.random(P.GAP_MIN_MS, P.GAP_MAX_MS)
end

local function removeBubble()
	if P.bubble then
		P.bubble.sprite:remove()
		P.bubble = nil
	end
end

-- New run: no bubble, no power, and the first bubble comes after a full gap
function P.reset()
	removeBubble()
	P.active = nil
	P.invincibleUntilMs = 0
	P.usedDoubleJump = false
	P.nextMs = Clock.now() + gap()
end

local function spawnBubble(findSpawnPosition)
	local kind = P.KINDS[math.random(1, #P.KINDS)]
	-- Somewhere clear of platforms, and below the HUD so it's never hidden behind it
	local x, y = findSpawnPosition()
	for _ = 1, 20 do
		if y >= 50 then break end
		x, y = findSpawnPosition()
	end
	y = math.max(y, 50)
	local sprite = gfx.sprite.new(P.images[kind])
	sprite:setCenter(0.5, 0.5)
	sprite:moveTo(x, y)
	sprite:add()
	P.bubble = { sprite = sprite, kind = kind, spawnMs = Clock.now(), x = x, baseY = y }
end

-- Do you have this power right now?
function P.has(kind)
	return P.active ~= nil and P.active.kind == kind and Clock.now() < P.active.untilMs
end

function P.isInvincible()
	return Clock.now() < P.invincibleUntilMs
end

-- Spawning, bobbing, expiring and collecting. Call every frame while playing.
-- findSpawnPosition() returns a free (x, y) for the bubble.
function P.update(bunny, findSpawnPosition)
	local now = Clock.now()
	if P.active and now >= P.active.untilMs then P.active = nil end
	if not P.bubble and not P.active and now >= P.nextMs then spawnBubble(findSpawnPosition) end
	local b = P.bubble
	if not b then return end

	local age = now - b.spawnMs
	if age >= P.LIFETIME_MS then
		-- Not collected in time: pop
		Particles.spawn(b.x, b.baseY)
		removeBubble()
		P.nextMs = now + gap()
		return
	end

	b.sprite:moveTo(b.x, b.baseY + math.sin(now / 300) * 3)
	b.sprite:setVisible(age < P.LIFETIME_MS - P.FLASH_MS or (now // 150) % 2 == 0)

	local bunnyRect = playdate.geometry.rect.new(bunny:getBounds())
	if bunnyRect:intersects(playdate.geometry.rect.new(b.sprite:getBounds())) then
		P.active = { kind = b.kind, untilMs = now + P.DURATION[b.kind] }
		P.usedDoubleJump = false
		Particles.spawn(b.x, b.baseY)
		removeBubble()
		P.nextMs = now + gap() -- (another can't appear until this one wears off anyway)
	end
end

-- A hazard touched the bunny. Returns true if the hit doesn't count: the bunny is still blinking
-- from an earlier blocked hit, or a shield takes it (and is used up).
function P.absorbHit(bunny)
	local now = Clock.now()
	if now < P.invincibleUntilMs then return true end
	if P.has("shield") then
		P.active = nil
		P.invincibleUntilMs = now + P.HIT_INVINCIBLE_MS
		local bx, by, bw, bh = bunny:getBounds()
		Particles.spawn(bx + bw / 2, by + bh / 2)
		return true
	end
	return false
end

-- What the HUD shows for the active power: its icon and how much time is left
function P.hudInfo()
	if not P.active then return nil end
	return {
		image = P.images[P.active.kind],
		remainingMs = P.active.untilMs - Clock.now(),
		durationMs = P.DURATION[P.active.kind],
	}
end
