-- Script to generate obstacle images for PixelHopper
-- Run this in Playdate Simulator to generate the images
-- Then use Playdate's screenshot/export feature to save them

import "CoreLibs/graphics"

local gfx = playdate.graphics

-- Generate saw image
local function generateSaw()
	local sawSize = 24
	local img = gfx.image.new(sawSize, sawSize)
	gfx.pushContext(img)
		local center = sawSize / 2
		local radius = sawSize / 2 - 1
		
		-- Outer blade (silver/grey)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(center, center, radius)
		
		-- Inner circle (darker grey for depth)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(center, center, radius - 3)
		
		-- Red center hub (pattern)
		for i = 0, 3 do
			for j = 0, 3 do
				if (i + j) % 2 == 0 then
					gfx.fillRect(center - 2 + i, center - 2 + j, 1, 1)
				end
			end
		end
		
		-- Draw sharp teeth
		local numTeeth = 16
		for i = 0, numTeeth - 1 do
			local angle = i * (math.pi * 2 / numTeeth)
			local innerRadius = radius - 2
			local outerRadius = radius + 1
			local x1 = center + math.cos(angle) * innerRadius
			local y1 = center + math.sin(angle) * innerRadius
			local x2 = center + math.cos(angle) * outerRadius
			local y2 = center + math.sin(angle) * outerRadius
			gfx.setColor(gfx.kColorBlack)
			gfx.setLineWidth(1)
			gfx.drawLine(x1, y1, x2, y2)
		end
	gfx.popContext()
	return img
end

-- Generate cannon image
local function generateCannon()
	local cannonWidth = 24
	local cannonHeight = 20
	local img = gfx.image.new(cannonWidth, cannonHeight)
	gfx.pushContext(img)
		-- Wooden platform
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(2, cannonHeight - 6, cannonWidth - 4, 4)
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(3, cannonHeight - 5, cannonWidth - 6, 2)
		
		-- Wheels
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(6, cannonHeight - 2, 2)
		gfx.fillCircleAtPoint(cannonWidth - 6, cannonHeight - 2, 2)
		
		-- Blue projectile
		local projX = cannonWidth / 2
		local projY = cannonHeight / 2 - 2
		local projRadius = 6
		
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(projX, projY, projRadius)
		
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(projX - 1, projY - 1, projRadius - 2)
		
		-- Skull icon
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(projX - 2, projY - 1, 1, 1)
		gfx.fillRect(projX + 1, projY - 1, 1, 1)
		gfx.fillRect(projX - 1, projY + 1, 2, 1)
	gfx.popContext()
	return img
end

-- Generate spike ball image
local function generateSpikeBall()
	local ballSize = 18
	local img = gfx.image.new(ballSize, ballSize)
	gfx.pushContext(img)
		local center = ballSize / 2
		local ballRadius = 6
		
		-- Blue ball body
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(center, center, ballRadius)
		
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(center - 1, center - 1, ballRadius - 2)
		
		-- Draw 8 spikes
		local numSpikes = 8
		for i = 0, numSpikes - 1 do
			local angle = i * (math.pi * 2 / numSpikes)
			local spikeLength = 4
			local startRadius = ballRadius
			local endRadius = ballRadius + spikeLength
			
			local x1 = center + math.cos(angle) * startRadius
			local y1 = center + math.sin(angle) * startRadius
			local x2 = center + math.cos(angle) * endRadius
			local y2 = center + math.sin(angle) * endRadius
			
			gfx.setColor(gfx.kColorWhite)
			gfx.setLineWidth(1)
			gfx.drawLine(x1, y1, x2, y2)
			
			gfx.setColor(gfx.kColorBlack)
			local tipX = center + math.cos(angle) * (endRadius - 1)
			local tipY = center + math.sin(angle) * (endRadius - 1)
			gfx.fillRect(tipX - 0.5, tipY - 0.5, 1, 1)
		end
	gfx.popContext()
	return img
end

-- Generate cannon projectile image
local function generateCannonProjectile()
	local projSize = 10
	local img = gfx.image.new(projSize, projSize)
	gfx.pushContext(img)
		local center = projSize / 2
		local radius = projSize / 2 - 1
		
		-- Blue projectile body
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(center, center, radius)
		
		gfx.setColor(gfx.kColorWhite)
		gfx.fillCircleAtPoint(center - 1, center - 1, radius - 2)
		
		-- Skull icon
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRect(center - 2, center - 1, 1, 1)
		gfx.fillRect(center + 1, center - 1, 1, 1)
		gfx.fillRect(center - 1, center + 1, 2, 1)
	gfx.popContext()
	return img
end

-- Main function to display images for export
local currentImage = 1
local images = {
	{name = "saw.png", img = generateSaw()},
	{name = "cannon.png", img = generateCannon()},
	{name = "spikeball.png", img = generateSpikeBall()},
	{name = "cannonball.png", img = generateCannonProjectile()},
}

function playdate.update()
	gfx.clear(gfx.kColorWhite)
	
	if currentImage <= #images then
		local item = images[currentImage]
		gfx.setColor(gfx.kColorBlack)
		gfx.drawText("Image " .. currentImage .. " of " .. #images, 10, 10)
		gfx.drawText("Name: " .. item.name, 10, 30)
		gfx.drawText("Press A to save, B for next", 10, 50)
		
		-- Draw image centered
		local img = item.img
		local w, h = img:getSize()
		img:draw(200 - w/2, 120 - h/2)
	end
	
	-- Navigation
	if playdate.buttonJustPressed(playdate.kButtonA) then
		-- Save image (you'll need to manually export via simulator)
		print("Displaying: " .. images[currentImage].name)
		print("Use Playdate Simulator's export feature to save this image")
	end
	
	if playdate.buttonJustPressed(playdate.kButtonB) or playdate.buttonJustPressed(playdate.kButtonRight) then
		currentImage = (currentImage % #images) + 1
	end
	
	if playdate.buttonJustPressed(playdate.kButtonLeft) then
		currentImage = ((currentImage - 2) % #images) + 1
	end
end

