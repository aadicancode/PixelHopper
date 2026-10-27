-- All menu, overlay and HUD drawing. main.lua builds a state snapshot each frame and calls UI.draw(state).
-- Everything here is 1-bit: black, white, and dither patterns for greys.

local gfx <const> = playdate.graphics

UI = {}

local W <const>, H <const> = 400, 240
local GROUND_Y <const> = 196 -- top of the decorative ground strip on menu screens

local function loadFont(path)
	return gfx.font.new(path) or gfx.getSystemFont()
end

local fonts = {
	title = loadFont("fonts/Nontendo-Bold-2x"), -- big pixel headings and numbers
	label = loadFont("fonts/Nontendo-Bold"), -- small pixel labels, menu items, hints
	body = loadFont("fonts/Roobert-11-Medium"), -- names and descriptions
	bold = loadFont("fonts/Roobert-11-Bold"),
}

local function now()
	return playdate.getCurrentTimeMilliseconds()
end

-------------------------------------------------------
-- Easing
-------------------------------------------------------
local function clamp01(t) return math.max(0, math.min(1, t)) end

local function easeOutBack(t)
	t = clamp01(t)
	local c1, c3 = 1.70158, 2.70158
	return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

local function easeOutCubic(t)
	t = clamp01(t)
	return 1 - (1 - t) ^ 3
end

-------------------------------------------------------
-- Text
-------------------------------------------------------
local function textWidth(font, text)
	return font:getTextWidth(text)
end

-- Draws text in black, or white when `white` is true
local function text(font, str, x, y, white)
	if white then gfx.setImageDrawMode(gfx.kDrawModeFillWhite) end
	font:drawText(str, x, y)
	if white then gfx.setImageDrawMode(gfx.kDrawModeCopy) end
end

local function textCentered(font, str, cx, y, white)
	text(font, str, math.floor(cx - textWidth(font, str) / 2), y, white)
end

local function textRight(font, str, rx, y, white)
	text(font, str, rx - textWidth(font, str), y, white)
end

-- Cuts text down with "..." until it fits maxWidth
local function fitText(font, str, maxWidth)
	if textWidth(font, str) <= maxWidth then return str end
	for i = #str, 1, -1 do
		local candidate = string.sub(str, 1, i) .. "..."
		if textWidth(font, candidate) <= maxWidth then return candidate end
	end
	return "..."
end

-- Per-letter images for wavy titles (cached)
local letterCache = {}
local function letterImage(font, ch)
	local key = tostring(font) .. ch
	local img = letterCache[key]
	if not img then
		local w = math.max(1, textWidth(font, ch))
		img = gfx.image.new(w, font:getHeight())
		gfx.pushContext(img)
			font:drawText(ch, 0, 0)
		gfx.popContext()
		letterCache[key] = img
	end
	return img
end

-- Title whose letters bob in a wave, with a dithered drop shadow
local function waveTitle(str, cx, y, amplitude)
	local font = fonts.title
	local tracking = font:getTracking()
	local total = textWidth(font, str)
	local x = math.floor(cx - total / 2)
	local t = now()
	for i = 1, #str do
		local ch = string.sub(str, i, i)
		local w = textWidth(font, ch)
		if ch ~= " " then
			local dy = math.floor(math.sin(t / 220 + i * 0.55) * amplitude + 0.5)
			local img = letterImage(font, ch)
			img:drawFaded(x + 3, y + dy + 3, 0.45, gfx.image.kDitherTypeBayer4x4)
			img:draw(x, y + dy)
		end
		x += w + tracking
	end
end

-------------------------------------------------------
-- Shapes
-------------------------------------------------------
-- alpha is how dark the grey is (0 = white, 1 = black). setDitherPattern takes the inverse.
local function dither(alpha)
	gfx.setColor(gfx.kColorBlack)
	gfx.setDitherPattern(1 - alpha, gfx.image.kDitherTypeBayer4x4)
end

-- White panel with a 2px border and a dithered drop shadow
local function panel(x, y, w, h, r)
	r = r or 6
	dither(0.5)
	gfx.fillRoundRect(x + 4, y + 4, w, h, r)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRoundRect(x, y, w, h, r)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(2)
	gfx.drawRoundRect(x, y, w, h, r)
	gfx.setLineWidth(1)
end

-- Small round button glyph like (A), drawn white-on-black or black-on-white
local function buttonGlyph(letter, x, y, white)
	gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
	gfx.fillCircleAtPoint(x + 7, y + 7, 7)
	textCentered(fonts.label, letter, x + 7, y + 1, not white)
end

-- A row of hints like (A) SELECT  (B) BACK. Items: { {glyph, label}, ... }. Returns total width.
local function hintsWidth(items)
	local total = 0
	for i, item in ipairs(items) do
		total += 16 + 4 + textWidth(fonts.label, item[2])
		if i < #items then total += 14 end
	end
	return total
end

local function hints(items, cx, y, white)
	local x = math.floor(cx - hintsWidth(items) / 2)
	for i, item in ipairs(items) do
		local glyph = item[1]
		if glyph == "A" or glyph == "B" then
			buttonGlyph(glyph, x, y, white)
		else
			-- D-pad hint: a little left/right or up/down arrow pair
			gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
			if glyph == "LR" then
				gfx.fillTriangle(x, y + 7, x + 6, y + 2, x + 6, y + 12)
				gfx.fillTriangle(x + 16, y + 7, x + 10, y + 2, x + 10, y + 12)
			else
				gfx.fillTriangle(x + 8, y, x + 3, y + 6, x + 13, y + 6)
				gfx.fillTriangle(x + 8, y + 14, x + 3, y + 8, x + 13, y + 8)
			end
		end
		x += 20
		text(fonts.label, item[2], x, y + 1, white)
		x += textWidth(fonts.label, item[2]) + 14
	end
end

local function trophy(x, y, white)
	gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
	gfx.fillRoundRect(x + 3, y, 12, 10, 4) -- cup
	gfx.fillRect(x + 3, y, 12, 4)
	gfx.setLineWidth(2)
	gfx.drawRoundRect(x, y + 1, 6, 6, 3) -- handles
	gfx.drawRoundRect(x + 12, y + 1, 6, 6, 3)
	gfx.setLineWidth(1)
	gfx.fillRect(x + 8, y + 10, 2, 3) -- stem
	gfx.fillRect(x + 5, y + 13, 8, 3) -- base
end

local function padlock(x, y)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(2)
	gfx.drawRoundRect(x + 3, y, 10, 10, 5) -- shackle
	gfx.setLineWidth(1)
	gfx.fillRoundRect(x, y + 6, 16, 11, 2) -- body
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(x + 7, y + 9, 2, 5) -- keyhole
end

-- Spinning loading indicator
local function spinner(cx, cy)
	local step = (now() // 90) % 8
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local px = cx + math.cos(a) * 9
		local py = cy + math.sin(a) * 9
		gfx.setColor(gfx.kColorBlack)
		if (i - step) % 8 < 3 then
			gfx.fillCircleAtPoint(px, py, 2.5)
		else
			gfx.drawCircleAtPoint(px, py, 2)
		end
	end
end

-------------------------------------------------------
-- Menu backdrop: drifting clouds and a ground strip
-------------------------------------------------------
local clouds = {
	{ x = 30, y = 26, s = 1.0, speed = 0.010 },
	{ x = 300, y = 52, s = 0.8, speed = 0.016 },
	{ x = 180, y = 170, s = 0.7, speed = 0.007 },
}

local function cloud(x, y, s, alpha)
	dither(alpha or 0.2)
	gfx.fillCircleAtPoint(x, y, 9 * s)
	gfx.fillCircleAtPoint(x + 12 * s, y - 5 * s, 12 * s)
	gfx.fillCircleAtPoint(x + 26 * s, y, 9 * s)
	gfx.fillRoundRect(x, y - 2 * s, 26 * s, 11 * s, 5 * s)
end

local function backdrop()
	local t = now()
	for _, c in ipairs(clouds) do
		local x = (c.x + t * c.speed) % (W + 80) - 40
		cloud(x, c.y, c.s)
	end
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, GROUND_Y, W, H - GROUND_Y)
	-- grass tufts along the top edge
	for x = 4, W, 22 do
		gfx.fillTriangle(x, GROUND_Y, x + 3, GROUND_Y - 4, x + 6, GROUND_Y)
		gfx.fillTriangle(x + 7, GROUND_Y, x + 9, GROUND_Y - 3, x + 11, GROUND_Y)
	end
end

-- Bunny hopping across the ground strip, with a few carrots planted along the way
local function hoppingBunny(images)
	local t = now()
	for _, cx in ipairs({ 70, 205, 330 }) do
		if images.carrot then images.carrot:draw(cx - 8, GROUND_Y - 16) end
	end
	local span = W + 60
	local x = (t * 0.06) % span - 30
	local phase = (t % 520) / 520
	local hop = math.sin(phase * math.pi) * 8
	local img = (phase < 0.5) and images.bunnyHop or images.bunnyFall
	if hop < 2 then img = images.bunny end
	if img then img:draw(math.floor(x - 10), math.floor(GROUND_Y - 24 - hop)) end
end

-------------------------------------------------------
-- Vertical pill menu (main menu)
-------------------------------------------------------
local function verticalMenu(options, selected, cx, y, rowH, images)
	local t = now()
	for i, label in ipairs(options) do
		local rowY = y + (i - 1) * rowH
		local w = textWidth(fonts.label, label)
		if i == selected then
			local pillW = math.max(150, w + 40)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRoundRect(cx - pillW / 2, rowY, pillW, rowH - 4, (rowH - 4) / 2)
			textCentered(fonts.label, label, cx, rowY + 5, true)
			-- carrot pointer that nudges left and right
			local nudge = math.floor(math.sin(t / 140) * 3 + 0.5)
			if images.carrot then
				images.carrot:draw(cx - pillW / 2 - 22 + nudge, rowY + (rowH - 4) / 2 - 8)
			end
		else
			textCentered(fonts.label, label, cx, rowY + 5)
		end
	end
end

-- Horizontal pill menu (death screen)
local function horizontalMenu(options, selected, cx, y)
	local gap = 10
	local widths, total = {}, 0
	for i, label in ipairs(options) do
		widths[i] = textWidth(fonts.label, label) + 26
		total += widths[i] + (i > 1 and gap or 0)
	end
	local x = math.floor(cx - total / 2)
	for i, label in ipairs(options) do
		local w = widths[i]
		if i == selected then
			dither(0.5)
			gfx.fillRoundRect(x + 3, y + 3, w, 22, 11)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRoundRect(x, y, w, 22, 11)
			textCentered(fonts.label, label, x + w / 2, y + 6, true)
		else
			gfx.setColor(gfx.kColorWhite)
			gfx.fillRoundRect(x, y, w, 22, 11)
			gfx.setColor(gfx.kColorBlack)
			gfx.setLineWidth(2)
			gfx.drawRoundRect(x, y, w, 22, 11)
			gfx.setLineWidth(1)
			textCentered(fonts.label, label, x + w / 2, y + 6)
		end
		x += w + gap
	end
end

-------------------------------------------------------
-- Screen state tracking (for entrance animations)
-------------------------------------------------------
local lastState = nil
local stateEnteredMs = 0

local function sinceEntered()
	return now() - stateEnteredMs
end

-------------------------------------------------------
-- Main menu
-------------------------------------------------------
local function drawMainMenu(s)
	backdrop()
	waveTitle("PIXEL HOPPER", W / 2, 12, 3)

	-- Player chip: name and personal best
	local name = fitText(fonts.bold, s.playerName, 120)
	local best = "BEST " .. s.highScore .. "  " .. s.formatTime(s.highTime)
	local chipW = textWidth(fonts.bold, name) + textWidth(fonts.label, best) + 34
	local chipX = math.floor(W / 2 - chipW / 2)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(1)
	gfx.drawRoundRect(chipX, 46, chipW, 20, 10)
	text(fonts.bold, name, chipX + 10, 48)
	local dotX = chipX + 10 + textWidth(fonts.bold, name) + 7
	gfx.fillCircleAtPoint(dotX, 56, 2)
	text(fonts.label, best, dotX + 7, 50)

	verticalMenu(s.mainMenuOptions, s.menuSelection, W / 2, 74, 24, s.images)
	hoppingBunny(s.images)
	hints({ { "A", "SELECT" }, { "B", "PLAY" } }, W / 2, 214, true)
end

-------------------------------------------------------
-- Death screen
-------------------------------------------------------
local function statCard(x, y, w, label, value, sub, icon)
	panel(x, y, w, 70)
	local labelW = textWidth(fonts.label, label) + (icon and 20 or 0)
	local lx = math.floor(x + w / 2 - labelW / 2)
	if icon then
		icon:draw(lx, y + 6)
		lx += 20
	end
	text(fonts.label, label, lx, y + 8)
	textCentered(fonts.title, value, x + w / 2, y + 24)
	textCentered(fonts.label, sub, x + w / 2, y + 52)
end

local function drawDeathScreen(s)
	backdrop()
	local enter = sinceEntered()

	-- Title drops in with a bounce
	local titleY = math.floor(-34 + 46 * easeOutBack(enter / 550))
	waveTitle("GAME OVER", W / 2, titleY, 2)

	-- Stats count up
	local countT = easeOutCubic((enter - 250) / 700)
	local shownScore = math.floor(s.lastScore * countT + 0.5)
	local shownTime = s.lastTime * countT

	local cardY = 56
	statCard(44, cardY, 148, "CARROTS", tostring(shownScore), "BEST " .. s.highScore, s.images.carrot)
	statCard(208, cardY, 148, "TIME", s.formatTime(shownTime), "BEST " .. s.formatTime(s.highTime), nil)

	-- NEW BEST badge, stamped over the top edge of the cards once the count finishes
	if s.newBest and enter > 950 then
		local pop = easeOutBack((enter - 950) / 300)
		local bw, bh = 104, 20
		local bx = W / 2 - bw / 2
		local by = cardY - 10 + (1 - pop) * -14
		if (now() // 350) % 2 == 0 or enter < 1600 then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRoundRect(bx, by, bw, bh, 10)
			gfx.setColor(gfx.kColorWhite)
			gfx.setLineWidth(2)
			gfx.drawRoundRect(bx + 2, by + 2, bw - 4, bh - 4, 8)
			gfx.setLineWidth(1)
			textCentered(fonts.label, "NEW BEST!", W / 2, by + 5, true)
		end
	end

	horizontalMenu({ "RETRY", "SCORES", "AWARDS", "MENU" }, s.menuSelection, W / 2, 148)
	hints({ { "LR", "MOVE" }, { "A", "SELECT" }, { "B", "RETRY" } }, W / 2 - 30, 214, true)
end

-------------------------------------------------------
-- Header and footer bands (leaderboard, achievements)
-------------------------------------------------------
local BAND_H <const> = 30
local FOOTER_Y <const> = 214

local function headerBand(title, rightText)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 0, W, BAND_H)
	dither(0.5)
	gfx.fillRect(0, BAND_H, W, 3)
	if title then text(fonts.title, title, 12, 2, true) end
	if rightText then textRight(fonts.label, rightText, W - 12, 9, true) end
end

local function footerBand(items, status)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, FOOTER_Y, W, H - FOOTER_Y)
	hints(items, status and 140 or W / 2, FOOTER_Y + 6, true)
	if status then textRight(fonts.label, status, W - 10, FOOTER_Y + 7, true) end
end

-------------------------------------------------------
-- Leaderboard
-------------------------------------------------------
local ROW_H <const> = 22
local ROWS_VISIBLE <const> = 7

-- White label text as an image, so it can be drawn faded (grey) on the black header
local greyLabelCache = {}
local function greyLabelImage(label)
	local img = greyLabelCache[label]
	if not img then
		img = gfx.image.new(textWidth(fonts.label, label), fonts.label:getHeight(), gfx.kColorClear)
		gfx.pushContext(img)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			fonts.label:drawText(label, 0, 0)
		gfx.popContext()
		greyLabelCache[label] = img
	end
	return img
end

-- Tiny white spinner for the black header
local function miniSpinner(cx, cy)
	local step = (now() // 90) % 6
	gfx.setColor(gfx.kColorWhite)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local px, py = cx + math.cos(a) * 4, cy + math.sin(a) * 4
		if (i - step) % 6 < 2 then
			gfx.fillCircleAtPoint(px, py, 1.5)
		else
			gfx.drawPixel(px, py)
		end
	end
end

-- Tips shown while something is loading. The first one each session is always the bunny cloud.
local LOADING_TIPS = {
	"Keep one eye on the sky. Once in a blue moon, a bunny-shaped cloud drifts by...",
	"White carrots are worth 3, but they don't stick around for long!",
	"Hold A to jump higher, or tap it for a quick hop.",
	"Ran off a ledge? You can still jump for a split second after.",
	"Hazards flash before they turn dangerous. That's your cue to move!",
	"Saws ride up the walls and turn back at the ceiling. Mind the corners!",
}
local currentTip = nil
local tipsShown = 0

local function pickTip()
	tipsShown += 1
	if tipsShown == 1 then return LOADING_TIPS[1] end
	return LOADING_TIPS[math.random(1, #LOADING_TIPS)]
end

-- A "TIP" card: rounded panel with a small label and centered text
local function tipCard(tip, y)
	local x, w, h = 32, W - 64, 82
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(1)
	gfx.drawRoundRect(x, y, w, h, 8)
	local labelW = textWidth(fonts.label, "TIP") + 16
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(W / 2 - labelW / 2, y - 7, labelW, 14)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRoundRect(W / 2 - labelW / 2, y - 7, labelW, 14, 7)
	textCentered(fonts.label, "TIP", W / 2, y - 6, true)
	gfx.drawTextInRect(tip, x + 10, y + 12, w - 20, h - 14, nil, nil, kTextAlignment.center, fonts.body)
end

local function drawLeaderboard(s)
	local isOnline = s.leaderboardTab == "online"
	local online = s.online
	local onlineBusy = online.isConfigured() and (online.pendingCount() > 0 or online.status == "loading")

	-- Header with tab pills
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 0, W, BAND_H)
	dither(0.5)
	gfx.fillRect(0, BAND_H, W, 3)
	text(fonts.title, "SCORES", 12, 2, true)
	-- The outlined pill marks the other tab (the one Left/Right switches to)
	local tabs = { { "LOCAL", isOnline }, { "ONLINE", not isOnline } }
	local tx = 196
	local nudge = math.floor(math.sin(now() / 160) * 2 + 0.5)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillTriangle(tx - 11 - nudge, 15, tx - 6 - nudge, 10, tx - 6 - nudge, 20)
	for _, tab in ipairs(tabs) do
		local label, active = tab[1], tab[2]
		local w = textWidth(fonts.label, label) + 22
		if active then
			-- Outlined pill with white text
			gfx.setColor(gfx.kColorWhite)
			gfx.setLineWidth(2)
			gfx.drawRoundRect(tx, 5, w, 20, 10)
			gfx.setLineWidth(1)
			textCentered(fonts.label, label, tx + w / 2, 10, true)
		else
			-- No pill, greyed-out text
			local img = greyLabelImage(label)
			local imgW = img:getSize()
			img:drawFaded(math.floor(tx + w / 2 - imgW / 2), 10, 0.5, gfx.image.kDitherTypeBayer2x2)
		end
		tx += w + 6
		-- Online scores downloading or a run uploading: small spinner right beside the ONLINE tab
		if label == "ONLINE" and onlineBusy then
			miniSpinner(tx + 3, 15)
			tx += 14
		end
	end
	gfx.setColor(gfx.kColorWhite)
	gfx.fillTriangle(tx + 5 + nudge, 15, tx + nudge, 10, tx + nudge, 20)

	local entries = isOnline and online.entries or s.leaderboard
	local listTop = 40

	-- Empty, loading and error states
	local message, showSpinner = nil, false
	if isOnline then
		if not online.isConfigured() then
			message = "Online scores aren't set up"
		elseif online.status == "error" and #entries == 0 then
			message = "Couldn't connect\n" .. (online.message or "")
		elseif online.status ~= "ready" and #entries == 0 then
			message, showSpinner = "Loading scores", true
		elseif #entries == 0 then
			message = "No online scores yet.\nBe the first!"
		end
	elseif #entries == 0 then
		message = "No scores yet.\nGo hop some carrots!"
	end

	-- Pick a new tip each time loading starts, and keep it until loading finishes
	if showSpinner then
		currentTip = currentTip or pickTip()
	else
		currentTip = nil
	end

	if message then
		local cy = showSpinner and 70 or 120
		if showSpinner then
			spinner(W / 2, cy - 18)
		elseif s.images.carrot then
			s.images.carrot:draw(W / 2 - 8, cy - 28)
		end
		gfx.drawTextInRect(message, 40, cy, W - 80, 50, nil, nil, kTextAlignment.center, fonts.bold)
		if showSpinner then tipCard(currentTip, 116) end
	else
		-- Column labels
		text(fonts.label, "#", 18, listTop)
		text(fonts.label, "PLAYER", 50, listTop)
		textRight(fonts.label, "CARROTS", 300, listTop)
		textRight(fonts.label, "TIME", 386, listTop)

		local first = s.scrollOffset + 1
		local last = math.min(first + ROWS_VISIBLE - 1, #entries)
		for i = first, last do
			local e = entries[i]
			local y = listTop + 16 + (i - first) * ROW_H
			local mine = e.playerName == s.playerName
			local rank = e.rank or i

			if mine then
				gfx.setColor(gfx.kColorBlack)
				gfx.fillRoundRect(6, y, W - 16, ROW_H - 2, 5)
			elseif i < last then
				-- dotted divider under each row
				gfx.setColor(gfx.kColorBlack)
				for dx = 12, W - 16, 4 do gfx.drawPixel(dx, y + ROW_H - 1) end
			end

			-- Rank: medals for the top three
			if rank <= 3 then
				gfx.setColor(mine and gfx.kColorWhite or gfx.kColorBlack)
				gfx.fillCircleAtPoint(22, y + 10, 8)
				textCentered(fonts.label, tostring(rank), 22, y + 4, not mine)
			else
				textCentered(fonts.label, tostring(rank), 22, y + 4, mine)
			end

			text(fonts.bold, fitText(fonts.bold, e.playerName or "Player", 150), 50, y + 2, mine)
			textRight(fonts.label, tostring(e.score or 0), 300, y + 4, mine)
			textRight(fonts.label, s.formatTime(e.time or 0), 386, y + 4, mine)
		end

		-- Scrollbar
		if #entries > ROWS_VISIBLE then
			local trackY, trackH = listTop + 16, ROWS_VISIBLE * ROW_H - 2
			local thumbH = math.max(12, trackH * ROWS_VISIBLE / #entries)
			local maxOffset = #entries - ROWS_VISIBLE
			local thumbY = trackY + (trackH - thumbH) * (s.scrollOffset / maxOffset)
			dither(0.25)
			gfx.fillRect(W - 6, trackY, 3, trackH)
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRoundRect(W - 7, thumbY, 5, thumbH, 2)
		end
	end

	footerBand({ { "LR", "TAB" }, { "UD", "SCROLL" }, { "B", "BACK" } })
end

-------------------------------------------------------
-- Achievements
-------------------------------------------------------
local CARD_H <const> = 50
local CARD_GAP <const> = 6
local CARDS_VISIBLE <const> = 3

local function drawAchievements(s)
	local unlockedCount = 0
	for _, def in ipairs(s.achievementDefinitions) do
		local a = s.achievements[def.id]
		if a and a.unlocked then unlockedCount += 1 end
	end
	headerBand("AWARDS", unlockedCount .. " / " .. #s.achievementDefinitions .. " UNLOCKED")

	local enter = sinceEntered()
	local first = s.scrollOffset + 1
	local last = math.min(first + CARDS_VISIBLE - 1, #s.achievementDefinitions)
	for i = first, last do
		local def = s.achievementDefinitions[i]
		local a = s.achievements[def.id] or {}
		local slot = i - first
		-- Cards slide in from the right, one after another
		local slide = easeOutCubic((enter - slot * 90) / 350)
		local x = math.floor(16 + (1 - slide) * W)
		local y = 44 + slot * (CARD_H + CARD_GAP)
		local w = W - 40

		panel(x, y, w, CARD_H)

		-- Icon tile
		if a.unlocked then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRoundRect(x + 8, y + 7, 36, 36, 6)
			trophy(x + 17, y + 16, true)
		else
			dither(0.25)
			gfx.fillRoundRect(x + 8, y + 7, 36, 36, 6)
			gfx.setColor(gfx.kColorBlack)
			gfx.drawRoundRect(x + 8, y + 7, 36, 36, 6)
			padlock(x + 18, y + 15)
		end

		text(fonts.bold, def.name, x + 54, y + 7)
		text(fonts.label, fitText(fonts.label, def.description, w - 64), x + 54, y + 29)

		-- Status tag
		local tag = a.unlocked and "UNLOCKED" or "LOCKED"
		local tagW = textWidth(fonts.label, tag) + 14
		local tagX = x + w - tagW - 10
		if a.unlocked then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillRoundRect(tagX, y + 7, tagW, 16, 8)
			textCentered(fonts.label, tag, tagX + tagW / 2, y + 10, true)
		else
			gfx.setColor(gfx.kColorBlack)
			gfx.drawRoundRect(tagX, y + 7, tagW, 16, 8)
			textCentered(fonts.label, tag, tagX + tagW / 2, y + 10)
		end
	end

	footerBand({ { "UD", "SCROLL" }, { "B", "BACK" } })
end

-------------------------------------------------------
-- In-game HUD
-------------------------------------------------------
local hudCarrots = 0
local carrotPopMs = -10000
local carrotPopAmount = 0

local function hudPill(x, y, w, inverted)
	gfx.setColor(inverted and gfx.kColorBlack or gfx.kColorWhite)
	gfx.fillRoundRect(x, y, w, 20, 10)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(2)
	gfx.drawRoundRect(x, y, w, 20, 10)
	gfx.setLineWidth(1)
end

local function drawHUD(s)
	-- Detect pickups for the pop effect
	if s.carrotCount > hudCarrots then
		carrotPopAmount = s.carrotCount - hudCarrots
		carrotPopMs = now()
	end
	hudCarrots = s.carrotCount

	-- Timer pill (fixed width so it doesn't jitter)
	local timeW = textWidth(fonts.label, "00:00:00") + 18
	hudPill(4, 4, timeW, false)
	text(fonts.label, s.formatTime(s.elapsedTime), 14, 9)

	-- Carrot pill: flashes inverted briefly on pickup, with a floating "+N"
	local popAge = now() - carrotPopMs
	local popping = popAge < 180
	local countText = tostring(s.carrotCount)
	local pillW = textWidth(fonts.label, countText) + 38
	local px = W - pillW - 4
	hudPill(px, 4, pillW, popping)
	if s.images.carrot then
		local bob = popping and -2 or 0
		s.images.carrot:draw(px + 6, 6 + bob)
	end
	text(fonts.label, countText, px + 26, 9, popping)

	-- "+1" / "+3" pops up just below the carrot counter and floats up toward it
	if popAge < 700 then
		local rise = easeOutCubic(popAge / 700) * 6
		local number = tostring(carrotPopAmount)
		-- The pixel font has no "+", so the plus sign is drawn by hand
		local plusW, gap = 6, 2
		local totalW = plusW + gap + textWidth(fonts.label, number)
		local x = math.floor(px + pillW / 2 - totalW / 2)
		local y = math.floor(32 - rise)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(x, y + 4, 6, 2)
		gfx.fillRect(x + 2, y + 2, 2, 6)
		text(fonts.label, number, x + plusW + gap, y)
	end

	-- Active power-up: its icon and a countdown bar under the timer (flashes in the last 2s)
	local p = s.power
	if p and p.remainingMs > 0 then
		local lastSeconds = p.remainingMs < 2000
		if not lastSeconds or (now() // 150) % 2 == 0 then
			-- Taller pill so the 24px bubble icon fits
			gfx.setColor(gfx.kColorWhite)
			gfx.fillRoundRect(4, 27, 80, 28, 14)
			gfx.setColor(gfx.kColorBlack)
			gfx.setLineWidth(2)
			gfx.drawRoundRect(4, 27, 80, 28, 14)
			gfx.setLineWidth(1)
			p.image:draw(6, 29)
			local barX, barY, barW, barH = 34, 38, 42, 6
			gfx.setColor(gfx.kColorBlack)
			gfx.drawRect(barX, barY, barW, barH)
			gfx.fillRect(barX + 1, barY + 1, math.floor((barW - 2) * p.remainingMs / p.durationMs), barH - 2)
		end
	end
end

-------------------------------------------------------
-- Achievement toast
-------------------------------------------------------
local function drawToast(s)
	local n = s.notification
	if not n then return end
	local age = s.notificationAge
	local remaining = n.duration - age
	local inT = easeOutBack(age / 300)
	local outT = easeOutCubic((300 - remaining) / 300)
	local h = 40
	local y = math.floor(-h - 4 + (h + 34) * inT - (h + 34) * clamp01(outT))

	local name = n.achievement.name
	local w = math.max(textWidth(fonts.bold, name), textWidth(fonts.label, "ACHIEVEMENT UNLOCKED")) + 64
	local x = math.floor(W / 2 - w / 2)

	dither(0.5)
	gfx.fillRoundRect(x + 3, y + 3, w, h, 8)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRoundRect(x, y, w, h, 8)
	gfx.setColor(gfx.kColorWhite)
	gfx.setLineWidth(1)
	gfx.drawRoundRect(x + 3, y + 3, w - 6, h - 6, 6)
	trophy(x + 14, y + 12, true)
	text(fonts.label, "ACHIEVEMENT UNLOCKED", x + 44, y + 7, true)
	text(fonts.bold, name, x + 44, y + 19, true)
end

-------------------------------------------------------
-- Gameplay backdrop: sun/moon, drifting clouds, birds, a hot-air balloon, distant mountains,
-- rolling hills with tree silhouettes, flowers and grass.
-- Everything far back is soft grey with no outlines, so hazards (bold black) stay easy to read.
-------------------------------------------------------
local FIELD_GROUND_Y <const> = 216 -- matches GROUND_TOP in main.lua

local fieldClouds = {
	{ x = 20, y = 46, s = 1.2, speed = 0.0060 },
	{ x = 150, y = 100, s = 0.8, speed = 0.0035 },
	{ x = 260, y = 30, s = 1.0, speed = 0.0075 },
	{ x = 330, y = 140, s = 0.7, speed = 0.0028 },
	{ x = 90, y = 160, s = 0.6, speed = 0.0045 },
}

local fieldBirds = {
	{ y = 58, speed = 0.022, offset = 0, size = 4 },
	{ y = 66, speed = 0.022, offset = 18, size = 3 },
}

-- Day/night cycle: the sun crosses the sky from east (right) to west (left) and sets behind the
-- hills, then the moon makes the same trip with stars out, then the sun again. Driven by the run's
-- elapsed time, so every run starts at sunrise and pausing doesn't move the sky.
local SUN_SECONDS <const> = 30
local MOON_SECONDS <const> = 30
local HORIZON_Y <const> = 206 -- the sun/moon sit this low at rise and set (hidden behind the hills)
local ARC_HEIGHT <const> = 166 -- how high they climb (peak at y = 40)

local stars = {
	{ 40, 30 }, { 92, 58 }, { 128, 22 }, { 176, 48 }, { 214, 18 }, { 250, 64 },
	{ 290, 34 }, { 336, 72 }, { 362, 40 }, { 62, 96 }, { 156, 88 }, { 306, 102 },
}

-- Hot-air balloon (daytime): drifts very slowly across the sky
local BALLOON_SPEED <const> = 0.004 -- px per ms
local BALLOON_Y <const> = 78

-- More slow drifters, all soft grey with no outlines
local SMALL_BALLOON_SPEED <const> = 0.0025 -- a smaller, farther balloon drifting the other way
local SMALL_BALLOON_Y <const> = 42
local BLIMP_SPEED <const> = 0.003
local BLIMP_Y <const> = 104
local UFO_EVERY <const> = 20000 -- at night, a little UFO wobbles across once every this many ms
local UFO_CROSSING_MS <const> = 9000

-- Super rare bunny-shaped cloud: each minute of a run has this chance of one drifting across
UI.BUNNY_CLOUD_CHANCE = 0.05
local runSeed = 0
function UI.newRun()
	runSeed = math.random(1, 100000)
end

-- Shooting star (night): one streak every SHOOTING_STAR_EVERY ms, lasting SHOOTING_STAR_MS
local SHOOTING_STAR_EVERY <const> = 7000
local SHOOTING_STAR_MS <const> = 600

-- Static layers are drawn once into images
local sunImage = nil
local moonImage = nil
local mountainImage = nil -- distant mountains (drawn behind the clouds)
local landImage = nil -- hills with tree silhouettes, flowers, grass tufts

local function buildFieldImages()
	-- Sun with short rays
	sunImage = gfx.image.new(50, 50, gfx.kColorClear)
	gfx.pushContext(sunImage)
		dither(0.35)
		gfx.fillCircleAtPoint(25, 25, 13)
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(1)
		gfx.drawCircleAtPoint(25, 25, 13)
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			gfx.drawLine(25 + math.cos(a) * 17, 25 + math.sin(a) * 17, 25 + math.cos(a) * 22, 25 + math.sin(a) * 22)
		end
	gfx.popContext()

	-- Crescent moon: white disc, shaded dark side, a couple of craters
	moonImage = gfx.image.new(30, 30, gfx.kColorClear)
	gfx.pushContext(moonImage)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(15, 15, 11)
		gfx.setColor(gfx.kColorBlack)
		for py = 3, 27 do
			for px = 3, 27 do
				local inMoon = (px - 15) ^ 2 + (py - 15) ^ 2 <= 11 ^ 2
				local inShadow = (px - 22) ^ 2 + (py - 12) ^ 2 <= 10 ^ 2
				if inMoon and inShadow and (px + py) % 2 == 0 then gfx.drawPixel(px, py) end
			end
		end
		gfx.drawCircleAtPoint(15, 15, 11)
		gfx.drawCircleAtPoint(10, 17, 2)
		gfx.drawCircleAtPoint(13, 22, 1)
	gfx.popContext()

	-- Distant mountains: a soft grey silhouette with white snowy tips, no outlines
	mountainImage = gfx.image.new(W, H, gfx.kColorClear)
	gfx.pushContext(mountainImage)
		local peaks = {
			{ -10, 180 }, { 40, 152 }, { 76, 170 }, { 120, 140 }, { 164, 166 }, { 206, 150 },
			{ 246, 172 }, { 292, 136 }, { 338, 162 }, { 374, 148 }, { 410, 176 },
		}
		local poly = {}
		for _, pt in ipairs(peaks) do
			table.insert(poly, pt[1]); table.insert(poly, pt[2])
		end
		table.insert(poly, 410); table.insert(poly, FIELD_GROUND_Y)
		table.insert(poly, -10); table.insert(poly, FIELD_GROUND_Y)
		dither(0.06)
		gfx.fillPolygon(table.unpack(poly))
		-- snowy tips: the top 8px of each peak left white
		gfx.setColor(gfx.kColorWhite)
		for i = 2, #peaks - 1 do
			local px, py = peaks[i][1], peaks[i][2]
			local prev, nxt = peaks[i - 1], peaks[i + 1]
			if py < prev[2] and py < nxt[2] then
				local tl = 8 / (prev[2] - py)
				local tr = 8 / (nxt[2] - py)
				gfx.fillTriangle(px, py,
					px + (prev[1] - px) * tl, py + 8,
					px + (nxt[1] - px) * tr, py + 8)
			end
		end
	gfx.popContext()

	landImage = gfx.image.new(W, H, gfx.kColorClear)
	gfx.pushContext(landImage)
		-- Far hills (lighter), then near hills (a little darker)
		local layers = {
			{ base = 178, a1 = 10, f1 = 70, a2 = 5, f2 = 31, phase = 0.0, alpha = 0.08 },
			{ base = 196, a1 = 8, f1 = 45, a2 = 4, f2 = 19, phase = 2.0, alpha = 0.17 },
		}
		local function hillTop(l, x)
			return math.floor(l.base - math.sin(x / l.f1 + l.phase) * l.a1 - math.sin(x / l.f2 + l.phase * 2) * l.a2)
		end
		for _, l in ipairs(layers) do
			dither(l.alpha)
			for x = 0, W - 1, 2 do
				local top = hillTop(l, x)
				gfx.fillRect(x, top, 2, FIELD_GROUND_Y - top)
			end
		end

		-- Tree silhouettes, a shade darker than the hill they stand on (no outlines)
		dither(0.14)
		for _, tx in ipairs({ 16, 30, 98, 184, 230, 244, 320, 354, 388 }) do
			local base = hillTop(layers[1], tx) + 2
			local hgt = 9 + (tx % 3) * 2
			gfx.fillTriangle(tx, base - hgt, tx - 4, base - hgt / 2, tx + 4, base - hgt / 2)
			gfx.fillTriangle(tx, base - hgt * 0.7, tx - 5, base, tx + 5, base)
		end
		dither(0.28)
		for _, tree in ipairs({ { 54, 6 }, { 148, 8 }, { 270, 7 }, { 364, 5 } }) do
			local tx, r = tree[1], tree[2]
			local base = hillTop(layers[2], tx) + 3
			gfx.fillRect(tx - 1, base - r - 3, 2, r + 3) -- trunk
			gfx.fillCircleAtPoint(tx, base - r * 2 - 1, r)
		end

		-- Grass tufts along the ground
		gfx.setColor(gfx.kColorBlack)
		for x = 3, W, 17 do
			gfx.fillTriangle(x, FIELD_GROUND_Y, x + 2, FIELD_GROUND_Y - 4, x + 4, FIELD_GROUND_Y)
			gfx.fillTriangle(x + 4, FIELD_GROUND_Y, x + 6, FIELD_GROUND_Y - 3, x + 8, FIELD_GROUND_Y)
		end

		-- A few little flowers
		for _, fx in ipairs({ 36, 118, 171, 247, 302, 371 }) do
			local stem = (fx % 3 == 0) and 7 or 5
			gfx.setColor(gfx.kColorBlack)
			gfx.drawLine(fx, FIELD_GROUND_Y - 1, fx, FIELD_GROUND_Y - stem)
			gfx.setColor(gfx.kColorWhite)
			gfx.fillCircleAtPoint(fx, FIELD_GROUND_Y - stem - 2, 2)
			gfx.setColor(gfx.kColorBlack)
			gfx.drawCircleAtPoint(fx, FIELD_GROUND_Y - stem - 2, 2)
			gfx.drawPixel(fx, FIELD_GROUND_Y - stem - 2)
		end
	gfx.popContext()
	gfx.setColor(gfx.kColorBlack)
end

-- Small soft-grey hot-air balloon, no outline
local function balloon(x, y)
	dither(0.18)
	gfx.fillCircleAtPoint(x, y, 7)
	gfx.fillTriangle(x - 6, y + 3, x + 6, y + 3, x, y + 10)
	dither(0.4)
	gfx.fillRect(x - 2, y + 12, 4, 3) -- basket
	gfx.drawLine(x - 2, y + 9, x - 2, y + 12)
	gfx.drawLine(x + 1, y + 9, x + 1, y + 12)
end

-- Smaller, paler balloon with a white stripe, further away
local function smallBalloon(x, y)
	dither(0.12)
	gfx.fillCircleAtPoint(x, y, 4)
	gfx.fillTriangle(x - 3, y + 2, x + 3, y + 2, x, y + 6)
	gfx.setColor(gfx.kColorWhite)
	gfx.drawLine(x - 4, y, x + 4, y)
	dither(0.3)
	gfx.fillRect(x - 1, y + 7, 2, 2)
end

-- Little blimp: a soft grey body with tail fins and a gondola underneath
local function blimp(x, y)
	dither(0.16)
	gfx.fillEllipseInRect(x - 18, y - 7, 36, 14)
	gfx.fillTriangle(x + 14, y - 1, x + 23, y - 8, x + 23, y + 6)
	dither(0.3)
	gfx.fillRect(x - 5, y + 8, 10, 4)
end

-- Little UFO: a saucer with a dome
local function ufo(x, y)
	dither(0.15)
	gfx.fillCircleAtPoint(x, y - 3, 6)
	dither(0.3)
	gfx.fillEllipseInRect(x - 13, y - 1, 26, 7)
end

-- Bunny-shaped cloud: round head, cheeks and two tall ears, same soft grey as the clouds
local function bunnyCloud(x, y)
	dither(0.15)
	gfx.fillEllipseInRect(x - 9, y - 32, 7, 22) -- ears
	gfx.fillEllipseInRect(x + 2, y - 30, 7, 20)
	gfx.fillCircleAtPoint(x, y, 11) -- head
	gfx.fillCircleAtPoint(x - 9, y + 4, 7) -- cheeks
	gfx.fillCircleAtPoint(x + 9, y + 4, 7)
	gfx.setColor(gfx.kColorWhite) -- eyes
	gfx.fillCircleAtPoint(x - 4, y - 2, 1.5)
	gfx.fillCircleAtPoint(x + 4, y - 2, 1.5)
end

-- Deterministic 0..1 roll for a given minute of the current run
local function rareRoll(n)
	local v = math.sin(n * 12.9898 + runSeed * 78.233) * 43758.5453
	return v - math.floor(v)
end

-- A faint streak across the upper sky, now and then at night
local function shootingStar(t)
	local cycleT = t % SHOOTING_STAR_EVERY
	if cycleT > SHOOTING_STAR_MS then return end
	local n = t // SHOOTING_STAR_EVERY
	local startX = 60 + (n * 97) % 260
	local startY = 14 + (n * 31) % 40
	local p = cycleT / SHOOTING_STAR_MS
	local headX, headY = startX + p * 70, startY + p * 26
	dither(0.45)
	gfx.drawLine(headX - 14, headY - 5, headX, headY)
end

local function bird(x, y, size, flapUp)
	gfx.setColor(gfx.kColorBlack)
	local wingY = flapUp and (y - size) or (y + 1)
	gfx.drawLine(x - size, wingY, x, y)
	gfx.drawLine(x, y, x + size, wingY)
end

-- Position along the east-to-west arc for progress p (0 = rising in the east, 1 = setting in the west)
local function arcPosition(p)
	local x = (W + 26) - p * (W + 52)
	local y = HORIZON_Y - math.sin(p * math.pi) * ARC_HEIGHT
	return math.floor(x), math.floor(y)
end

local function drawStars(nightProgress, t)
	-- Stars fade in after moonrise and out before sunrise, a few at a time
	local strength = math.sin(nightProgress * math.pi)
	gfx.setColor(gfx.kColorBlack)
	for i, star in ipairs(stars) do
		if strength > 0.1 + (i / #stars) * 0.5 then
			local x, y = star[1], star[2]
			if ((t // 450) + i) % 4 == 0 then
				gfx.drawPixel(x, y) -- twinkle
			else
				gfx.drawLine(x - 2, y, x + 2, y)
				gfx.drawLine(x, y - 2, x, y + 2)
			end
		end
	end
end

-- Draw behind the sprites (the sprite system's background). gameSeconds is the run's elapsed time.
function UI.drawPlayfield(gameSeconds)
	if not sunImage then buildFieldImages() end
	local t = now()

	-- Sun by day, moon (and stars) by night
	local cycle = (gameSeconds or 0) % (SUN_SECONDS + MOON_SECONDS)
	if cycle < SUN_SECONDS then
		local x, y = arcPosition(cycle / SUN_SECONDS)
		sunImage:draw(x - 25, y - 25)
	else
		local p = (cycle - SUN_SECONDS) / MOON_SECONDS
		drawStars(p, t)
		if math.sin(p * math.pi) > 0.3 then shootingStar(t) end
		local x, y = arcPosition(p)
		moonImage:draw(x - 15, y - 15)
	end

	mountainImage:draw(0, 0)

	for _, c in ipairs(fieldClouds) do
		local x = (c.x + t * c.speed) % (W + 90) - 50
		cloud(x, c.y, c.s, 0.15)
	end

	-- The rare bunny cloud drifts across once during a lucky minute of the run
	local minute = (gameSeconds or 0) // 60
	if rareRoll(minute) < UI.BUNNY_CLOUD_CHANCE then
		local p = ((gameSeconds or 0) % 60) / 60
		bunnyCloud(math.floor(-40 + p * (W + 80)), 48)
	end

	if cycle < SUN_SECONDS then
		local bx = (t * BALLOON_SPEED) % (W + 60) - 30
		balloon(math.floor(bx), math.floor(BALLOON_Y + math.sin(t / 1500) * 3))
		local sx = W + 20 - (t * SMALL_BALLOON_SPEED) % (W + 40)
		smallBalloon(math.floor(sx), math.floor(SMALL_BALLOON_Y + math.sin(t / 1800 + 1) * 2))
		local px = (t * BLIMP_SPEED + 230) % (W + 80) - 40
		blimp(math.floor(px), math.floor(BLIMP_Y + math.sin(t / 2200) * 2))
	else
		local ut = t % UFO_EVERY
		if ut < UFO_CROSSING_MS then
			local p = ut / UFO_CROSSING_MS
			ufo(math.floor(W + 20 - p * (W + 40)), math.floor(50 + math.sin(t / 250) * 3))
		end
	end

	for _, b in ipairs(fieldBirds) do
		local x = (t * b.speed + b.offset) % (W + 160) - 40
		local flap = ((t // 220) + b.offset) % 2 == 0
		bird(x, b.y + math.sin(t / 400 + b.offset) * 2, b.size, flap)
	end

	landImage:draw(0, 0)
	gfx.setColor(gfx.kColorBlack)
end

-------------------------------------------------------
-- Entry point
-------------------------------------------------------
function UI.draw(s)
	if s.gameState ~= lastState then
		lastState = s.gameState
		stateEnteredMs = now()
	end

	gfx.setColor(gfx.kColorBlack)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)

	if s.gameState == "playing" or s.gameState == "dying" then
		drawHUD(s)
	else
		-- Menu screens draw over the frozen game scene
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(0, 0, W, H)
		if s.gameState == "mainmenu" then
			drawMainMenu(s)
		elseif s.gameState == "dead" then
			drawDeathScreen(s)
		elseif s.gameState == "leaderboard" then
			drawLeaderboard(s)
		elseif s.gameState == "achievements" then
			drawAchievements(s)
		end
	end

	drawToast(s)
	gfx.setColor(gfx.kColorBlack)
end
