-- Game clocks.
--   Clock.now()  milliseconds of play, not counting time paused in the system menu, while the device
--                is locked, or while the game pauses itself (deciding a rewind).
--   SlowMo       slow motion (hold B) and the "world clock" hazards run on, which advances slower
--                while slow motion is on. The bunny, the run timer and power-ups stay on Clock.now().

Clock = {}

local pausedTotalMs = 0
local pauseStartMs = nil

function Clock.now()
	return playdate.getCurrentTimeMilliseconds() - pausedTotalMs
end

function Clock.beginPause()
	if not pauseStartMs then
		pauseStartMs = playdate.getCurrentTimeMilliseconds()
	end
end

function Clock.endPause()
	if pauseStartMs then
		pausedTotalMs += playdate.getCurrentTimeMilliseconds() - pauseStartMs
		pauseStartMs = nil
	end
end

function playdate.gameWillPause() Clock.beginPause() end
function playdate.gameWillResume() Clock.endPause() end
function playdate.deviceWillLock() Clock.beginPause() end
function playdate.deviceDidUnlock() Clock.endPause() end

-------------------------------------------------------
-- Slow motion
-------------------------------------------------------
SlowMo = {
	SCALE = 0.35, -- world speed while slowed
	FULL_MS = 3000, -- a full focus meter lasts this long
	REFILL_CARROT = 0.15, -- focus gained per carrot (white carrots give 3x)
	worldMs = 0, -- the world clock
	lastRealMs = 0,
	scale = 1, -- current world speed (eases toward SCALE or 1)
	focus = 1, -- meter, 0..1
	active = false,
}

-- The world clock: use for anything hazards do over time (spawns, firing, flashing, falling)
function SlowMo.now()
	return SlowMo.worldMs
end

-- Once per frame. playing: a run is in progress. wantsSlow: the player is holding B.
-- Slow motion runs while there's focus left; the world clock advances by real time times the
-- current world speed.
function SlowMo.update(playing, wantsSlow)
	local realNow = Clock.now()
	local dt = math.max(0, math.min(100, realNow - SlowMo.lastRealMs))
	SlowMo.lastRealMs = realNow
	SlowMo.active = playing and wantsSlow and SlowMo.focus > 0
	if SlowMo.active then
		SlowMo.focus = math.max(0, SlowMo.focus - dt / SlowMo.FULL_MS)
	end
	local target = (playing and SlowMo.active) and SlowMo.SCALE or 1
	SlowMo.scale += (target - SlowMo.scale) * 0.3 -- ease in and out
	if playing then
		SlowMo.worldMs += dt * SlowMo.scale
	end
end

-- Each run starts with a full meter at normal speed
function SlowMo.reset()
	SlowMo.focus = 1
	SlowMo.scale = 1
	SlowMo.active = false
end

-- Carrots refill focus (pass 3 for a white carrot)
function SlowMo.refill(carrots)
	SlowMo.focus = math.min(1, SlowMo.focus + SlowMo.REFILL_CARROT * carrots)
end
