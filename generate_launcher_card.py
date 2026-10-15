#!/usr/bin/env python3
"""
Generate launcher card for PixelHopper game.
Creates a 400x240 PNG image for the Playdate launcher.
"""

from PIL import Image, ImageDraw, ImageFont
import os

def create_launcher_card():
    """Create launcher card image for PixelHopper"""
    # Create 400x240 image (Playdate screen size)
    # '1' = 1-bit mode (black/white only for Playdate)
    img = Image.new('1', (400, 240), 1)  # 1 = white background
    draw = ImageDraw.Draw(img)
    
    # Draw border around the whole card
    draw.rectangle([5, 5, 395, 235], outline=0, width=3)

    # White background - the background is already white (1 = white in 1-bit mode)

    # Load bunny sprite and place it on white background (inverted colors)
    bunny_path = os.path.join('source', 'images', 'bunny.png')
    if os.path.exists(bunny_path):
        bunny = Image.open(bunny_path)
        # Handle transparency if present
        if bunny.mode == 'RGBA':
            # Create white background and composite
            bunny_bg = Image.new('L', bunny.size, 255)
            alpha = bunny.split()[3]
            bunny_gray = bunny.convert('L')
            bunny_bg.paste(bunny_gray, mask=alpha)
            bunny = bunny_bg
        elif bunny.mode != 'L':
            bunny = bunny.convert('L')
        
        # Scale bunny to fit nicely on card
        max_width = 200
        max_height = 120
        scale = min(max_width / bunny.width, max_height / bunny.height)
        new_size = (max(1, int(bunny.width * scale)), max(1, int(bunny.height * scale)))
        bunny = bunny.resize(new_size, Image.LANCZOS)
        
        # Convert to 1-bit - white bunny on white background with black outline
        # First, create the bunny shape as white
        bunny_1bit = bunny.point(lambda x: 1 if x >= 128 else 0, mode='1')
        
        # Create outline by dilating the bunny shape
        # We'll create a slightly larger version for the outline
        from PIL import ImageFilter, ImageOps
        
        # Create a mask of the bunny (invert so bunny is black for dilation)
        bunny_mask = bunny_1bit.point(lambda x: 0 if x == 1 else 1, mode='1')
        
        # Dilate the mask to create outline (make it bigger)
        # Use a simple method: create a larger image and paste the bunny multiple times offset
        outline_size = (new_size[0] + 4, new_size[1] + 4)
        bunny_outline = Image.new('1', outline_size, 1)  # white background
        
        # Paste bunny mask multiple times with offsets to create outline effect
        offsets = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
        center_x, center_y = outline_size[0] // 2, outline_size[1] // 2
        bunny_center_x, bunny_center_y = new_size[0] // 2, new_size[1] // 2
        
        for ox, oy in offsets:
            paste_x = center_x - bunny_center_x + ox
            paste_y = center_y - bunny_center_y + oy
            bunny_outline.paste(bunny_mask, (paste_x, paste_y))
        
        # Now paste the white bunny on top
        paste_x = center_x - bunny_center_x
        paste_y = center_y - bunny_center_y
        bunny_outline.paste(bunny_1bit, (paste_x, paste_y))
        
        # Center bunny horizontally, place in upper portion
        bunny_x = (400 - outline_size[0]) // 2
        bunny_y = 38  # Slightly higher to account for outline
        
        # Paste the bunny with outline (black outline, white bunny on white background)
        img.paste(bunny_outline, (bunny_x, bunny_y))
    else:
        # fallback: draw simple silhouette
        draw.ellipse([150, 50, 250, 150], fill=0)
    
    # Draw "PixelHopper" text (centered, large)
    try:
        font_paths = [
            "C:/Windows/Fonts/arial.ttf",
            "C:/Windows/Fonts/calibri.ttf",
            "arial.ttf",
        ]
        font_large = None
        for path in font_paths:
            try:
                font_large = ImageFont.truetype(path, 36)
                break
            except:
                continue
        if font_large is None:
            font_large = ImageFont.load_default()
    except:
        font_large = ImageFont.load_default()
    
    # Title text
    title_text = "PixelHopper"
    if hasattr(draw, 'textbbox'):
        bbox = draw.textbbox((0, 0), title_text, font=font_large)
        title_width = bbox[2] - bbox[0]
    else:
        title_width = len(title_text) * 22
    
    title_x = (400 - title_width) // 2
    title_y = 160
    
    # Draw title (black text on white background)
    draw.text((title_x, title_y), title_text, fill=0, font=font_large)
    
    return img

def create_icon():
    """Create 32x32 icon for Playdate launcher list"""
    # Create 32x32 image (1-bit mode)
    img = Image.new('1', (32, 32), 1)  # 1 = white background
    
    # Load bunny sprite
    bunny_path = os.path.join('source', 'images', 'bunny.png')
    if os.path.exists(bunny_path):
        bunny = Image.open(bunny_path)
        
        # Handle transparency if present
        if bunny.mode == 'RGBA':
            bunny_bg = Image.new('L', bunny.size, 255)
            alpha = bunny.split()[3]
            bunny_gray = bunny.convert('L')
            bunny_bg.paste(bunny_gray, mask=alpha)
            bunny = bunny_bg
        elif bunny.mode != 'L':
            bunny = bunny.convert('L')
        
        # Scale bunny to fit in 32x32 (with some padding)
        max_size = 28  # Leave 2px padding on each side
        scale = min(max_size / bunny.width, max_size / bunny.height)
        new_size = (max(1, int(bunny.width * scale)), max(1, int(bunny.height * scale)))
        bunny = bunny.resize(new_size, Image.LANCZOS)
        
        # Convert to 1-bit - black bunny on white background
        bunny_1bit = bunny.point(lambda x: 0 if x >= 128 else 1, mode='1')
        
        # Center the bunny in the 32x32 icon
        bunny_x = (32 - new_size[0]) // 2
        bunny_y = (32 - new_size[1]) // 2
        
        # Paste the bunny
        img.paste(bunny_1bit, (bunny_x, bunny_y))
    
    return img

def main():
    # Create the launcher card
    card = create_launcher_card()
    
    # Save to source directory (pdc will copy it to .pdx)
    card_path = 'source/card.png'
    card.save(card_path)
    print(f"Launcher card created: {card_path}")
    print("Size: 400x240 pixels (Playdate screen size)")
    print("Format: 1-bit PNG (black and white)")
    
    # Create the icon
    icon = create_icon()
    icon_path = 'source/icon.png'
    icon.save(icon_path)
    print(f"\nIcon created: {icon_path}")
    print("Size: 32x32 pixels")
    print("Format: 1-bit PNG (black and white)")
    print("\nNote: Run 'pdc source PixelHopper.pdx' to include them in the build")

if __name__ == '__main__':
    main()

