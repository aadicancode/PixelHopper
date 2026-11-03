-- Shared screen and ground measurements, used by main.lua and the gameplay modules.

World = {
	SCREEN_W = 400,
	SCREEN_H = 240,
	GROUND_TOP = 216, -- y of the ground's top edge
	LEFT_BOUND = 8, -- how far left and right the bunny can go
	RIGHT_BOUND = 392,
}

-- Load an image, or return nil if it's missing
function World.loadImage(path)
	local ok, img = pcall(playdate.graphics.image.new, path)
	if ok and img then return img end
	return nil
end
