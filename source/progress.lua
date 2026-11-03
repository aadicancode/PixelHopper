-- Things that are saved between runs: the player's name, high score and time, achievements (with
-- their pop-up notifications), and the local leaderboard. Everything is kept in the Playdate datastore.

Progress = {
	playerName = "Player",
	highScore = 0,
	highTime = 0.0, -- time from the same run as the high score
	leaderboard = {}, -- array of { score, time, playerName, rank, date }
	MAX_LEADERBOARD_ENTRIES = 10,
	achievements = {}, -- by id: { id, name, description, unlocked, unlockTime }
	achievementDefinitions = {
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
	},
	activeNotification = nil, -- the achievement pop-up showing now: { achievement, startTime, duration }
}

-------------------------------------------------------
-- Player name
-------------------------------------------------------
local function loadPlayerName()
	local data = playdate.datastore.read("playerName")
	if data and type(data) == "string" and #data > 0 then
		Progress.playerName = data
	end
end

function Progress.savePlayerName()
	playdate.datastore.write(Progress.playerName, "playerName")
end

function Progress.setPlayerName(name)
	Progress.playerName = name
	Progress.savePlayerName()
end

-------------------------------------------------------
-- High score
-------------------------------------------------------
local function loadHighScore()
	local data = playdate.datastore.read("highScore")
	if data and type(data) == "number" then
		Progress.highScore = data
	end
end

local function saveHighScore()
	playdate.datastore.write(Progress.highScore, "highScore")
end

local function loadHighTime()
	local data = playdate.datastore.read("highTime")
	if data and type(data) == "number" then
		Progress.highTime = data
	end
end

local function saveHighTime()
	playdate.datastore.write(Progress.highTime, "highTime")
end

-------------------------------------------------------
-- Achievements
-------------------------------------------------------
-- Make sure every defined achievement has an entry
local function initializeAchievements()
	for _, def in ipairs(Progress.achievementDefinitions) do
		if not Progress.achievements[def.id] then
			Progress.achievements[def.id] = {
				id = def.id,
				name = def.name,
				description = def.description,
				unlocked = false,
				unlockTime = 0
			}
		end
	end
end

local function loadAchievements()
	local data = playdate.datastore.read("achievements")
	if data and type(data) == "table" then
		Progress.achievements = data
	end
	initializeAchievements()
end

local function saveAchievements()
	playdate.datastore.write(Progress.achievements, "achievements")
end

-- Pop-up notifications for newly unlocked achievements, shown one at a time
local notificationQueue = {}

local function showNotification(achievement)
	if Progress.activeNotification then
		table.insert(notificationQueue, achievement)
	else
		Progress.activeNotification = {
			achievement = achievement,
			startTime = Clock.now(),
			duration = 3000 -- 3 seconds
		}
	end
end

-- Call once per frame: retire the current pop-up when its time is up and show the next one
function Progress.updateNotifications()
	local n = Progress.activeNotification
	if not n then return end
	local now = Clock.now()
	if now - n.startTime >= n.duration then
		Progress.activeNotification = nil
		if #notificationQueue > 0 then
			Progress.activeNotification = {
				achievement = table.remove(notificationQueue, 1),
				startTime = now,
				duration = 3000
			}
		end
	end
end

-- How many of the last `count` carrot pickups happened within `seconds`
local function collectedWithin(collectionTimes, count, seconds)
	local last = #collectionTimes
	local first = last - (count - 1)
	if first < 1 then return false end
	return (collectionTimes[last] - collectionTimes[first]) / 1000.0 < seconds
end

-- Unlock an achievement if its condition is met. carrotCount is this run's carrots so far;
-- collectionTimes holds the times of the recent carrot pickups.
function Progress.checkAchievement(id, carrotCount, collectionTimes)
	local achievement = Progress.achievements[id]
	if not achievement or achievement.unlocked then return end

	local unlocked = false
	if id == "speed_collector_5" then
		unlocked = collectedWithin(collectionTimes, 5, 5.0)
	elseif id == "speed_collector_10" then
		unlocked = collectedWithin(collectionTimes, 10, 10.0)
	elseif id == "carrot_master" then
		unlocked = carrotCount >= 30
	end

	if unlocked then
		achievement.unlocked = true
		achievement.unlockTime = Clock.now()
		saveAchievements()
		showNotification(achievement)
	end
end

-------------------------------------------------------
-- Local leaderboard
-------------------------------------------------------
local function sortLeaderboard()
	-- Highest score first; for the same score, the shorter time ranks higher
	table.sort(Progress.leaderboard, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		else
			return a.time < b.time
		end
	end)
	for i = 1, #Progress.leaderboard do
		Progress.leaderboard[i].rank = i
	end
end

local function saveLocalLeaderboard()
	playdate.datastore.write(Progress.leaderboard, "localLeaderboard")
end

local function loadLocalLeaderboard()
	local data = playdate.datastore.read("localLeaderboard")
	if not (data and type(data) == "table") then
		Progress.leaderboard = {}
		return
	end

	-- Keep only valid entries (older versions saved some scores as strings like "1/10")
	local validEntries = {}
	for _, entry in ipairs(data) do
		local score = entry.score
		if type(score) == "string" and not string.find(score, "/") then
			score = tonumber(score)
		end
		if type(score) == "number" and score >= 0 then
			entry.playerName = entry.playerName or "Player"
			entry.score = score
			entry.time = entry.time or 0
			entry.date = entry.date or 0
			table.insert(validEntries, entry)
		end
	end
	Progress.leaderboard = validEntries
	sortLeaderboard()

	if #validEntries ~= #data then
		saveLocalLeaderboard()
	end
end

-- Add a finished run to the local leaderboard (keeps the top MAX_LEADERBOARD_ENTRIES)
function Progress.addScore(score, time)
	table.insert(Progress.leaderboard, {
		score = score,
		time = time,
		playerName = Progress.playerName,
		date = playdate.getSecondsSinceEpoch()
	})
	sortLeaderboard()
	while #Progress.leaderboard > Progress.MAX_LEADERBOARD_ENTRIES do
		table.remove(Progress.leaderboard)
	end
	for i = 1, #Progress.leaderboard do
		Progress.leaderboard[i].rank = i
	end
	saveLocalLeaderboard()
end

-- Keep the high score and its time in step with the top of the leaderboard
function Progress.syncHighScore()
	local top = Progress.leaderboard[1]
	if top and top.score then
		if top.score > Progress.highScore or Progress.highScore == 0 then
			Progress.highScore = top.score
			Progress.highTime = top.time or 0
			saveHighScore()
			saveHighTime()
		end
	end
end

-------------------------------------------------------
-- Load everything at startup
-------------------------------------------------------
loadPlayerName()
loadHighScore()
loadHighTime()
loadAchievements()
loadLocalLeaderboard()
Progress.syncHighScore()
