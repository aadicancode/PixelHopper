-- Little bursts of black squares: carrot pickups, power-ups popping, hits.

Particles = {}

local gfx <const> = playdate.graphics

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

local active = {}

-- A burst of 7 particles at (x, y)
function Particles.spawn(x, y)
	for _ = 1, 7 do
		table.insert(active, Particle.new(x, y))
	end
end

-- Move every particle; call once per frame
function Particles.update()
	for i = #active, 1, -1 do
		if active[i]:update() then
			table.remove(active, i)
		end
	end
end

-- Remove all particles (new run)
function Particles.clear()
	for i = #active, 1, -1 do
		local p = active[i]
		if p and p.sprite then p.sprite:remove() end
		table.remove(active, i)
	end
end
