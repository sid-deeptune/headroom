"""Generates the Headroom app icon.

Concept: three quota bars rising toward a hard ceiling, with the gap between them
left empty — the headroom itself is the subject. The tallest bar is amber, matching
the app's urgency language (neutral -> amber -> red).

Run: python3 Icons/make-icon.py   (then Icons/make-icns.sh to package)
"""

from PIL import Image, ImageDraw

S = 1024
BG_TOP, BG_BOTTOM = (44, 49, 58), (23, 26, 31)
INK = (255, 255, 255)
AMBER = (255, 159, 10)

# Squircle occupies 824x824 of the 1024 canvas — the macOS Big Sur icon grid.
MARGIN, RADIUS = 100, 180

image = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Vertical gradient, clipped to the squircle.
gradient = Image.new("RGBA", (1, S))
for y in range(S):
    t = y / (S - 1)
    gradient.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)) + (255,))
gradient = gradient.resize((S, S))

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [MARGIN, MARGIN, S - MARGIN, S - MARGIN], radius=RADIUS, fill=255
)
image.paste(gradient, (0, 0), mask)

draw = ImageDraw.Draw(image)

# The ceiling.
CEILING_TOP, CEILING_H = 320, 46
LEFT, RIGHT = 250, 774
draw.rounded_rectangle(
    [LEFT, CEILING_TOP, RIGHT, CEILING_TOP + CEILING_H], radius=CEILING_H // 2, fill=INK
)

# Three bars, none of them touching it.
BAR_W, GAP, BOTTOM = 130, 67, 792
tops = [600, 516, 430]
colors = [INK, INK, AMBER]
for index, (top, color) in enumerate(zip(tops, colors)):
    x = LEFT + index * (BAR_W + GAP)
    draw.rounded_rectangle([x, top, x + BAR_W, BOTTOM], radius=22, fill=color)

image.save("Icons/AppIcon.png")
print("wrote Icons/AppIcon.png")
