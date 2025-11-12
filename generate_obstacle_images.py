#!/usr/bin/env python3
"""
Generate obstacle images for PixelHopper game.
Creates PNG files: saw.png, cannon.png, spikeball.png, cannonball.png
"""

from PIL import Image, ImageDraw
import math
import os

def create_saw_image():
    """Create saw blade image: silver/grey with red center and sharp teeth"""
    size = 24
    img = Image.new('RGB', (size, size), 'white')
    draw = ImageDraw.Draw(img)
    center = size // 2
    radius = size // 2 - 1
    
    # Outer blade (silver/grey)
    draw.ellipse([center - radius, center - radius, center + radius, center + radius], 
                 fill='#C0C0C0', outline='#808080')
    
    # Inner circle (darker grey)
    inner_radius = radius - 3
    draw.ellipse([center - inner_radius, center - inner_radius, 
                  center + inner_radius, center + inner_radius], 
                 fill='#808080', outline='#606060')
    
    # Red center hub
    hub_size = 4
    draw.ellipse([center - hub_size//2, center - hub_size//2,
                  center + hub_size//2, center + hub_size//2],
                 fill='#FF0000', outline='#CC0000')
    
    # Draw sharp teeth (16 teeth)
    num_teeth = 16
    for i in range(num_teeth):
        angle = i * (2 * math.pi / num_teeth)
        inner_rad = radius - 2
        outer_rad = radius + 1
        
        x1 = center + math.cos(angle) * inner_rad
        y1 = center + math.sin(angle) * inner_rad
        x2 = center + math.cos(angle) * outer_rad
        y2 = center + math.sin(angle) * outer_rad
        
        draw.line([x1, y1, x2, y2], fill='#000000', width=2)
    
    return img

def create_cannon_image():
    """Create cannon image: blue projectile on wooden platform with wheels"""
    width, height = 24, 20
    img = Image.new('RGB', (width, height), 'white')
    draw = ImageDraw.Draw(img)
    
    # Wooden platform (brown)
    platform_y = height - 6
    draw.rectangle([2, platform_y, width - 2, height - 2], 
                   fill='#8B4513', outline='#654321')
    # Platform highlight
    draw.rectangle([3, platform_y + 1, width - 3, platform_y + 3],
                   fill='#A0522D')
    
    # Wheels (dark circles)
    draw.ellipse([4, height - 4, 8, height], fill='#000000')
    draw.ellipse([width - 8, height - 4, width - 4, height], fill='#000000')
    
    # Blue projectile/cannonball
    proj_x = width // 2
    proj_y = height // 2 - 2
    proj_radius = 6
    
    draw.ellipse([proj_x - proj_radius, proj_y - proj_radius,
                  proj_x + proj_radius, proj_y + proj_radius],
                 fill='#0066CC', outline='#004499')
    
    # Highlight on projectile
    draw.ellipse([proj_x - proj_radius + 1, proj_y - proj_radius + 1,
                  proj_x + proj_radius - 2, proj_y + proj_radius - 2],
                 fill='#0088FF')
    
    # White skull icon
    # Eyes
    draw.rectangle([proj_x - 2, proj_y - 1, proj_x - 1, proj_y], fill='white')
    draw.rectangle([proj_x + 1, proj_y - 1, proj_x + 2, proj_y], fill='white')
    # Mouth
    draw.rectangle([proj_x - 1, proj_y + 1, proj_x + 1, proj_y + 2], fill='white')
    
    return img

def create_spikeball_image():
    """Create spike ball image: blue ball with 8 white spikes with dark tips"""
    size = 18
    img = Image.new('RGB', (size, size), 'white')
    draw = ImageDraw.Draw(img)
    center = size // 2
    ball_radius = 6
    
    # Blue ball body
    draw.ellipse([center - ball_radius, center - ball_radius,
                  center + ball_radius, center + ball_radius],
                 fill='#0066CC', outline='#004499')
    
    # Lighter blue highlight
    draw.ellipse([center - ball_radius + 1, center - ball_radius + 1,
                  center + ball_radius - 2, center + ball_radius - 2],
                 fill='#0088FF')
    
    # Draw 8 spikes evenly spaced
    num_spikes = 8
    for i in range(num_spikes):
        angle = i * (2 * math.pi / num_spikes)
        spike_length = 4
        start_radius = ball_radius
        end_radius = ball_radius + spike_length
        
        x1 = center + math.cos(angle) * start_radius
        y1 = center + math.sin(angle) * start_radius
        x2 = center + math.cos(angle) * end_radius
        y2 = center + math.sin(angle) * end_radius
        
        # Draw spike (white with dark tip)
        draw.line([x1, y1, x2, y2], fill='white', width=2)
        # Dark tip
        tip_x = int(center + math.cos(angle) * (end_radius - 1))
        tip_y = int(center + math.sin(angle) * (end_radius - 1))
        draw.ellipse([tip_x - 1, tip_y - 1, tip_x + 1, tip_y + 1], fill='#000000')
    
    return img

def create_cannonball_image():
    """Create cannon projectile image: blue projectile with white skull icon"""
    size = 10
    img = Image.new('RGB', (size, size), 'white')
    draw = ImageDraw.Draw(img)
    center = size // 2
    radius = size // 2 - 1
    
    # Blue projectile body
    draw.ellipse([center - radius, center - radius,
                  center + radius, center + radius],
                 fill='#0066CC', outline='#004499')
    
    # Highlight
    draw.ellipse([center - radius + 1, center - radius + 1,
                  center + radius - 2, center + radius - 2],
                 fill='#0088FF')
    
    # White skull icon
    # Eyes
    draw.rectangle([center - 2, center - 1, center - 1, center], fill='white')
    draw.rectangle([center + 1, center - 1, center + 2, center], fill='white')
    # Mouth
    draw.rectangle([center - 1, center + 1, center + 1, center + 2], fill='white')
    
    return img

def main():
    # Create images directory if it doesn't exist
    os.makedirs('source/images', exist_ok=True)
    
    # Generate and save images
    images = [
        ('saw.png', create_saw_image()),
        ('cannon.png', create_cannon_image()),
        ('spikeball.png', create_spikeball_image()),
        ('cannonball.png', create_cannonball_image()),
    ]
    
    for filename, img in images:
        filepath = os.path.join('source/images', filename)
        img.save(filepath)
        print(f"Created: {filepath}")
    
    print("\nAll obstacle images created successfully!")
    print("The images are in: source/images/")

if __name__ == '__main__':
    main()



