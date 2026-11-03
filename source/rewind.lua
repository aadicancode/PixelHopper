-- Crank rewind. When a hit would end the run, time freezes. Crank backwards (or press Left/Right)
-- to scrub back up to 3 seconds, then press A to resume from that moment, or B to give up.
-- To make it a skill rather than a free retry: you must go back at least MIN_BACK steps, there's a
-- decision timer, and charges are limited (1 per run plus 1 per CARROTS_PER_CHARGE carrots).
--
-- A snapshot is recorded every other playing frame. Hazards save and restore themselves
-- (Hazards.capture / Hazards.restore); main.lua provides the rest through Rewind.setup():
--   captureGame()     -> the bunny, carrots and counters as plain data
--   restoreGame(snap) -> put them back
--   carrotCount()     -> carrots collected this run (earns charges)

Rewind = {
	HISTORY = 45, -- snapshots kept, one every 2 frames: 3 seconds
	STEPS_PER_SECOND = 15,
	MIN_BACK = 5, -- must go at least this far back (1/3 s) to resume
	DEGREES_PER_STEP = 10, -- crank degrees per snapshot
	DECIDE_MS = 6000, -- time to pick a moment before the hit counts
	CARROTS_PER_CHARGE = 15,
	MAX_CHARGES = 3,
	FLASH_FRAMES = 4, -- inverted "tape stop" flash when the hit freezes time

	active = false, -- rewinding right now
	history = {},
	frame = 0,
	used = 0,
	index = 0, -- how many snapshots back from the hit we're showing
	crankAccum = 0,
	startedMs = 0,
	hitX = 0,
	hitY = 0,
	introFrames = 0,
	autoSteps = 0, -- steps still to rewind automatically right after the hit
	movedMs = -10000, -- when the scrub position last changed (drives the VHS effects)
	moveDir = -1, -- -1 rewinding, 1 scrubbing forward
	resumedMs = -10000, -- when play resumed (drives the "play" flash)
	hooks = nil,
}
local R = Rewind

function R.setup(hooks)
	R.hooks = hooks
end

-- New run
function R.reset()
	R.history = {}
	R.frame = 0
	R.used = 0
	R.active = false
end

function R.charges()
	local earned = 1 + R.hooks.carrotCount() // R.CARROTS_PER_CHARGE
	return math.max(0, math.min(R.MAX_CHARGES, earned) - R.used)
end

local function capture()
	return {
		game = R.hooks.captureGame(),
		hazards = Hazards.capture(),
		worldMs = SlowMo.worldMs,
		focus = SlowMo.focus,
	}
end

local function restore(snap)
	Hazards.restore(snap.hazards)
	R.hooks.restoreGame(snap.game)
	SlowMo.worldMs, SlowMo.focus = snap.worldMs, snap.focus
end

-- Record a snapshot every other playing frame, keeping the last HISTORY of them
function R.record()
	R.frame += 1
	if R.frame % 2 ~= 0 then return end
	table.insert(R.history, capture())
	if #R.history > R.HISTORY + 1 then table.remove(R.history, 1) end
end

-- A hit would end the run: freeze time and start rewinding, if a rewind is available.
-- (hitX, hitY) is where the bunny was hit. Returns true if rewinding started.
function R.tryStart(hitX, hitY)
	if R.charges() <= 0 or #R.history < R.MIN_BACK + 1 then return false end
	table.insert(R.history, capture()) -- the moment of the hit
	R.active = true
	R.index = 0
	R.crankAccum = 0
	R.hitX, R.hitY = hitX, hitY
	R.startedMs = playdate.getCurrentTimeMilliseconds()
	R.introFrames = R.FLASH_FRAMES
	R.autoSteps = R.MIN_BACK -- everything visibly runs backwards to the earliest allowed moment
	playdate.display.setInverted(true)
	playdate.getCrankChange() -- ignore any turning done before now
	Clock.beginPause() -- real-time timers (run clock, power-ups) don't run while deciding
	return true
end

local function finish()
	R.active = false
	playdate.display.setInverted(false)
	Clock.endPause()
end

-- Each frame while rewinding. Returns "resume" when the player picks a moment, "giveup" when they
-- give up (or run out of time; the world is back at the moment of the hit), or nil to keep going.
function R.update()
	local n = #R.history

	-- The hit: a brief inverted flash with everything frozen
	if R.introFrames > 0 then
		R.introFrames -= 1
		if R.introFrames == 0 then playdate.display.setInverted(false) end
		playdate.getCrankChange()
		return nil
	end

	-- Then everything runs backwards on its own to the earliest moment you're allowed to resume
	if R.autoSteps > 0 then
		R.autoSteps -= 1
		playdate.getCrankChange()
		local index = math.min(n - 1, R.index + 1)
		if index ~= R.index then
			R.index = index
			R.movedMs, R.moveDir = playdate.getCurrentTimeMilliseconds(), -1
			restore(R.history[n - index])
		end
		return nil
	end

	-- Scrub: counter-clockwise goes back in time, clockwise forward
	if not playdate.isCrankDocked() then
		R.crankAccum += playdate.getCrankChange()
	end
	local index = R.index
	while R.crankAccum <= -R.DEGREES_PER_STEP do
		index += 1
		R.crankAccum += R.DEGREES_PER_STEP
	end
	while R.crankAccum >= R.DEGREES_PER_STEP do
		index -= 1
		R.crankAccum -= R.DEGREES_PER_STEP
	end
	if playdate.buttonJustPressed(playdate.kButtonLeft) then index += 1 end
	if playdate.buttonJustPressed(playdate.kButtonRight) then index -= 1 end
	index = math.max(0, math.min(n - 1, index))
	if index ~= R.index then
		R.movedMs = playdate.getCurrentTimeMilliseconds()
		R.moveDir = (index > R.index) and -1 or 1
		R.index = index
		restore(R.history[n - index])
	end

	local elapsed = playdate.getCurrentTimeMilliseconds() - R.startedMs
	if playdate.buttonJustPressed(playdate.kButtonA) and R.index >= R.MIN_BACK then
		-- Resume from here; the future we rewound past is forgotten
		for i = n, n - R.index + 1, -1 do R.history[i] = nil end
		R.used += 1
		R.resumedMs = playdate.getCurrentTimeMilliseconds()
		finish()
		SlowMo.lastRealMs = Clock.now()
		SlowMo.scale = SlowMo.SCALE -- ease back in from slow motion
		return "resume"
	elseif playdate.buttonJustPressed(playdate.kButtonB) or elapsed >= R.DECIDE_MS then
		restore(R.history[#R.history]) -- back to the moment of the hit
		finish()
		return "giveup"
	end
	return nil
end

-- Is the tape moving right now? (the world judders while it is)
function R.isMoving()
	return R.active and playdate.getCurrentTimeMilliseconds() - R.movedMs < 220
end

-- What the rewind overlay needs to draw, or nil when not rewinding
function R.uiState()
	if not R.active then return nil end
	local n = #R.history
	-- Ghosts of the bunny where it was a moment "later": the path being undone
	local trail = {}
	for k = 1, 4 do
		local snap = R.history[n - R.index + k * 2]
		if snap then table.insert(trail, { x = snap.game.bunnyX, y = snap.game.bunnyY }) end
	end
	local now = playdate.getCurrentTimeMilliseconds()
	return {
		moving = now - R.movedMs < 220,
		moveDir = R.moveDir,
		trail = trail,
		intro = R.introFrames > 0,
		index = R.index,
		maxBack = n - 1,
		minBack = R.MIN_BACK,
		stepsPerSecond = R.STEPS_PER_SECOND,
		remainingMs = math.max(0, R.DECIDE_MS - (now - R.startedMs)),
		decideMs = R.DECIDE_MS,
		charges = R.charges(),
		hitX = R.hitX,
		hitY = R.hitY,
	}
end
