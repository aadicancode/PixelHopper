-- Online leaderboard backed by Supabase (https://supabase.com).
-- Settings come from config.lua (SUPABASE_HOST, SUPABASE_KEY). If they're blank, online features stay off.
--
-- Every finished run is queued in the datastore and uploaded automatically in the background, whether
-- or not the player opens the leaderboard. Runs played offline are sent once a connection works.
-- Each run carries a unique id so a retried upload can never create a duplicate on the server.
-- Only one request is in flight at a time. Progress is logged to the console with an [online] prefix.

OnlineLeaderboard = {}
local M = OnlineLeaderboard

local PENDING_KEY = "pendingOnlineScores"
local TOP_PATH = "/rest/v1/scores?select=player_name,score,time_seconds&order=score.desc,time_seconds.asc&limit=20"
local SUBMIT_PATH = "/rest/v1/rpc/submit_score"
local REQUEST_TIMEOUT_MS = 30000 -- Wi-Fi can take 10+ seconds just to wake up
local RETRY_DELAY_MS = 10000 -- wait this long before retrying an upload that failed

M.entries = {} -- last fetched top scores: { playerName, score, time, rank }
M.status = "idle" -- "idle" | "loading" | "ready" | "error"
M.message = nil -- error text when status is "error"

local current = nil -- the request in flight, if any
local fetchWanted = false
local retryUploadAtMs = 0
local accessRequested = false

local function log(text)
	print("[online] " .. text)
end

local function newRunId()
	return string.format("%d-%d-%d", playdate.getSecondsSinceEpoch(),
		playdate.getCurrentTimeMilliseconds(), math.random(1, 999999999))
end

local pending = playdate.datastore.read(PENDING_KEY)
if type(pending) ~= "table" then pending = {} end

local function savePending()
	playdate.datastore.write(pending, PENDING_KEY)
end

-- Runs queued by older builds have no id yet
for _, entry in ipairs(pending) do
	if not entry.runId then entry.runId = newRunId() end
end
savePending()

function M.isConfigured()
	return type(SUPABASE_HOST) == "string" and SUPABASE_HOST ~= ""
		and type(SUPABASE_KEY) == "string" and SUPABASE_KEY ~= ""
end

function M.pendingCount()
	return #pending
end

local function requestHeaders()
	local headers = {
		apikey = SUPABASE_KEY,
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
	-- Legacy anon keys are JWTs and also go in Authorization; new sb_publishable_ keys must not
	if not string.find(SUPABASE_KEY, "^sb_") then
		headers.Authorization = "Bearer " .. SUPABASE_KEY
	end
	return headers
end

local function headerValue(headers, name)
	if not headers then return nil end
	name = string.lower(name)
	for key, value in pairs(headers) do
		if string.lower(key) == name then return value end
	end
	return nil
end

-- Starts an HTTPS request. onDone(ok, status, body, err) is called exactly once.
local function startRequest(method, path, body, onDone)
	-- Must run inside playdate.update(): the first call can show the system's network permission prompt
	local conn = playdate.network.http.new(SUPABASE_HOST, 443, true, "Online leaderboard")
	if not conn then
		onDone(false, nil, nil, "Network access not allowed")
		return
	end
	conn:setConnectTimeout(20)

	local req = { body = "", startMs = playdate.getCurrentTimeMilliseconds(), finished = false }
	current = req

	local function drain()
		local n = conn:getBytesAvailable()
		if n and n > 0 then
			local data = conn:read(n)
			if data then req.body = req.body .. data end
		end
	end

	function req.finish(err)
		if req.finished then return end
		req.finished = true
		drain()
		local status = conn:getResponseStatus()
		conn:close()
		current = nil
		local ok = err == nil and status ~= nil and status >= 200 and status < 300
		if not ok and not err then
			err = status and ("Server error " .. status) or "No response"
		end
		onDone(ok, status, req.body, err)
	end

	-- A response with no body (e.g. 204, or Content-Length: 0) is complete as soon as its headers arrive
	conn:setHeadersReadCallback(function()
		local status = conn:getResponseStatus()
		local length = headerValue(conn:getResponseHeaders(), "Content-Length")
		if status == 204 or length == "0" then req.finish(nil) end
	end)
	conn:setRequestCallback(function()
		drain()
		local got, total = conn:getProgress()
		if total and total > 0 and got >= total then req.finish(nil) end
	end)
	conn:setRequestCompleteCallback(function()
		local err = conn:getError()
		if err == "Connection closed" then err = nil end
		req.finish(err)
	end)
	conn:setConnectionClosedCallback(function()
		req.finish(nil)
	end)

	local queued, err
	if method == "GET" then
		queued, err = conn:get(path, requestHeaders())
	else
		queued, err = conn:post(path, requestHeaders(), body)
	end
	if not queued then
		req.finish(err or "Request failed")
	end
end

local function startFetch()
	fetchWanted = false
	M.status = "loading"
	M.message = nil
	log("fetching top scores")
	startRequest("GET", TOP_PATH, nil, function(ok, status, body, err)
		if not ok then
			log("fetch failed: " .. tostring(err))
			M.status = "error"
			M.message = err
			return
		end
		local decoded, rows = pcall(json.decode, body)
		if not decoded or type(rows) ~= "table" then
			log("fetch returned unreadable data")
			M.status = "error"
			M.message = "Couldn't read scores"
			return
		end
		local entries = {}
		for i, row in ipairs(rows) do
			table.insert(entries, {
				rank = i,
				playerName = row.player_name or "Player",
				score = tonumber(row.score) or 0,
				time = tonumber(row.time_seconds) or 0,
			})
		end
		M.entries = entries
		M.status = "ready"
		log("fetched " .. #entries .. " scores")
	end)
end

local function startUpload()
	local entry = pending[1]
	log(string.format("uploading run %s (%d carrots, %.2fs)", entry.runId, entry.score, entry.time))
	local body = json.encode({
		p_run_id = entry.runId,
		p_name = entry.name,
		p_score = entry.score,
		p_time = entry.time,
	})
	startRequest("POST", SUBMIT_PATH, body, function(ok, status, _, err)
		if ok or (status and status >= 400 and status < 500) then
			-- Sent, or rejected by the server's checks (retrying would fail again): drop it either way
			log(ok and "upload done" or ("upload rejected: " .. tostring(err)))
			table.remove(pending, 1)
			savePending()
			if ok and M.status ~= "idle" then fetchWanted = true end -- show the new score
		else
			log("upload failed, retrying in " .. (RETRY_DELAY_MS // 1000) .. "s: " .. tostring(err))
			retryUploadAtMs = playdate.getCurrentTimeMilliseconds() + RETRY_DELAY_MS
		end
	end)
end

-- Queue a finished run for upload (it goes out automatically on the next update() calls)
function M.submitScore(name, score, time)
	if not M.isConfigured() or score <= 0 then return end
	table.insert(pending, {
		runId = newRunId(),
		name = string.sub(name or "Player", 1, 16),
		score = score,
		time = math.floor(time * 100 + 0.5) / 100,
	})
	savePending()
	retryUploadAtMs = 0 -- a new run is worth trying right away
end

-- Ask for the latest top scores (shown once they arrive)
function M.refresh()
	if not M.isConfigured() then return end
	fetchWanted = true
	retryUploadAtMs = 0 -- the player is looking, so try pending uploads right away too
end

-- Drive network work. Call every frame from playdate.update().
-- Uploads run whenever there's something queued; fetching the list only happens when allowFetch is true.
function M.update(allowFetch)
	if not M.isConfigured() then return end

	-- Ask for network permission once, up front, so the system prompt never interrupts a run
	if not accessRequested then
		accessRequested = true
		playdate.network.http.requestAccess(SUPABASE_HOST, 443, true, "Online leaderboard")
	end

	local now = playdate.getCurrentTimeMilliseconds()

	if current then
		if now - current.startMs > REQUEST_TIMEOUT_MS then
			current.finish("Timed out")
		end
		return
	end

	-- Upload first, so a fresh fetch includes the player's own scores
	if #pending > 0 and now >= retryUploadAtMs then
		startUpload()
	elseif fetchWanted and allowFetch then
		startFetch()
	end
end
