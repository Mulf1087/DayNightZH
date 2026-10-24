"""Draw the original day/night app icon and its macOS iconset."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "Assets"
ICONSET = ASSETS / "DayNight.iconset"
ICONSET.mkdir(parents=True, exist_ok=True)

size = 2048
image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
pixels = image.load()
for y in range(size):
    t = y / (size - 1)
    color = (int(24 + 11 * t), int(39 + 15 * t), int(75 + 23 * t), 255)
    for x in range(size):
        pixels[x, y] = color

mask = Image.new("L", (size, size), 0)
draw = ImageDraw.Draw(mask)
draw.rounded_rectangle((96, 96, 1952, 1952), radius=430, fill=255)
image.putalpha(mask)

# The sun sits behind a clean crescent; two shapes remain legible at menu sizes.
glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
g.ellipse((320, 350, 1320, 1350), fill=(255, 174, 81, 85))
glow = glow.filter(ImageFilter.GaussianBlur(170))
image = Image.alpha_composite(image, glow)
draw = ImageDraw.Draw(image)
draw.ellipse((410, 510, 1210, 1310), fill=(255, 190, 98, 255))
draw.ellipse((740, 430, 1470, 1160), fill=(34, 52, 94, 255))
draw.ellipse((860, 350, 1510, 1000), fill=(244, 244, 226, 255))
draw.ellipse((1020, 210, 1630, 820), fill=(34, 52, 94, 255))
draw.ellipse((560, 390, 615, 445), fill=(255, 228, 176, 255))
draw.ellipse((1500, 1140, 1550, 1190), fill=(255, 220, 159, 255))

# Re-apply the rounded-square mask after the soft glow.
image.putalpha(Image.composite(image.getchannel("A"), Image.new("L", (size, size), 0), mask))
preview = image.resize((1024, 1024), Image.Resampling.LANCZOS)
preview.save(ASSETS / "DayNight-1024.png")

for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = "@2x" if scale == 2 else ""
        preview.resize((base * scale, base * scale), Image.Resampling.LANCZOS).save(
            ICONSET / f"icon_{base}x{base}{suffix}.png"
        )
