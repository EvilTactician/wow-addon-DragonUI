#!/usr/bin/env python3
"""Bake the Classic skin's sheets from the 3.3.5 client's stock interface textures.

Each sheet keeps the size and rects of the Forever sheet it stands in for, so the same atlas entries
and texcoords draw it: DragonUI/utils/skins.lua only swaps the path. The output is committed, so this
needs running only when the art changes:

    python3 tools/build_classic_skin.py --stock DIR
    python3 tools/build_classic_skin.py --check

DIR is the client's Interface tree extracted from its locale MPQs, with lower-cased names
(DIR/paperdollinfoframe/ui-character-general-topleft.blp). Needs Pillow 11+ (DXT encoding).

Stock art is 1x and the frame sheet 2x, so one stock pixel is two sheet pixels. The mappings below
line the stock rails up with the seat measured in utils/nineslice.lua (addon.WindowSeat): rails end
4.5 in from the left and bottom and 5.5 from the right, and the title stone runs 2 to 20 below the top.
"""
import argparse
import io
import math
import re
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter, ImageOps

from recolour_grounds import dxt1_level, recolour, write_like

ROOT = Path(__file__).resolve().parent.parent / "DragonUI" / "Textures"
OUT = ROOT / "Skins" / "Classic"

# Grounds: the stone under the stock title bar for windows, the black rock of its body for insets.
ROCK_MEAN, MARBLE_MEAN = (47, 46, 44), (15, 15, 15)


def load(path):
    """BLP encoding 3 (raw BGRA) is not one Pillow reads."""
    path = Path(path)
    if path.suffix == ".blp":
        data = path.read_bytes()
        if data[:4] == b"BLP2" and data[8] == 3:
            w, h = struct.unpack("<II", data[12:20])
            off = struct.unpack("<I", data[20:24])[0]
            size = struct.unpack("<I", data[84:88])[0]
            return Image.frombuffer("RGBA", (w, h), data[off:off + size], "raw", "BGRA", 0, 1).copy()
    return Image.open(path).convert("RGBA")


def save_tga(im, path):
    """Bottom-left origin, 32-bit, RLE: the header the client already reads in chrome-frame.tga."""
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, "TGA", compression="tga_rle", orientation=-1)


def silver(im):
    """Forever's bronze as stock's grey metal; the strong yellows and reds of icons and checks stay."""
    hsv = im.convert("RGB").convert("HSV").load()
    px = im.load()
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            r, g, b, a = px[x, y]
            hue, sat, _ = hsv[x, y]
            yellow = 26 <= hue <= 50 and sat >= 170
            red = (hue <= 10 or hue >= 245) and sat >= 150
            if a and not yellow and not red:
                grey = (r * 299 + g * 587 + b * 114) // 1000
                px[x, y] = (grey, grey, grey, a)
    return im


# Sheets whose shapes stay and only lose the bronze: (source under Textures, output name).
SILVER_SHEETS = (
    ("ForeverUI/chrome-dialog.tga", "chrome-dialog.tga"),
    ("ForeverUI/chrome-options.tga", "chrome-options.tga"),
    ("ForeverUI/controls-basic.tga", "controls-basic.tga"),
    ("ForeverUI/controls-dropdown.tga", "controls-dropdown.tga"),
    ("UI/dropdownbutton.tga", "dropdownbutton.tga"),
    ("CharacterPanel/scrollbararrows.tga", "scrollbararrows.tga"),
    ("CharacterPanel/scrollbarthumb.tga", "scrollbarthumb.tga"),
)


def build_silver():
    for source, name in SILVER_SHEETS:
        save_tga(silver(load(ROOT / source)), OUT / name)


def bilinear(px, size, x, y):
    x0, y0 = int(x), int(y)
    fx, fy = x - x0, y - y0
    if not (0 <= x0 < size[0] - 1 and 0 <= y0 < size[1] - 1):
        return (0, 0, 0, 0)
    a, b, c, d = px[x0, y0], px[x0 + 1, y0], px[x0, y0 + 1], px[x0 + 1, y0 + 1]
    return tuple(round((a[i] * (1 - fx) + b[i] * fx) * (1 - fy) + (c[i] * (1 - fx) + d[i] * fx) * fy) for i in range(4))


class StockRing:
    """A stock ring as radial bands: one clean arc, folded around the circle so badges and joints drop out."""

    def __init__(self, art, cx, cy, inner, outer, arc):
        self.px, self.size = art.load(), art.size
        self.cx, self.cy, self.inner, self.outer = cx, cy, inner, outer
        self.arc = arc

    def sample(self, t, angle):
        start, end = self.arc
        span = end - start
        folded = angle % (2 * span)
        folded = folded if folded <= span else 2 * span - folded
        a = math.radians(start + folded)
        r = self.inner + t * (self.outer - self.inner)
        return bilinear(self.px, self.size, self.cx + r * math.cos(a), self.cy + r * math.sin(a))


def paint_ring(im, ring, cx, cy, inner, outer):
    """Draws `ring` over `im`'s annulus; what lies inside the hole or outside the ring stays."""
    px = im.load()
    pad = 2
    for y in range(max(0, int(cy - outer - pad)), min(im.size[1], int(cy + outer + pad) + 1)):
        for x in range(max(0, int(cx - outer - pad)), min(im.size[0], int(cx + outer + pad) + 1)):
            r = math.hypot(x - cx, y - cy)
            if inner - pad <= r <= outer + pad:
                t = (r - inner) / (outer - inner)
                if 0 <= t <= 1:
                    px[x, y] = ring.sample(t, math.degrees(math.atan2(y - cy, x - cx)))
                else:
                    px[x, y] = (0, 0, 0, 0) if t > 1 else (px[x, y][0] // 3, px[x, y][1] // 3, px[x, y][2] // 3, px[x, y][3])
    return im


def bronze(pixel, hsv):
    hue, sat, _ = hsv
    return pixel[3] > 120 and 6 <= hue <= 42 and sat >= 70


def find_ring(im, region=None):
    """Centre and radii of the bronze ring in `im`, from its left and top: a player's wedge hangs lower right."""
    hsv, px = im.convert("RGB").convert("HSV").load(), im.load()
    left, top, right, bottom = region or (0, 0, im.size[0], im.size[1])
    points = [(x, y) for y in range(top, bottom) for x in range(left, right) if bronze(px[x, y], hsv[x, y])]
    min_x, min_y = min(p[0] for p in points), min(p[1] for p in points)
    # Widest extent on the row and column through the first guess gives the true centre.
    rows = {}
    for x, y in points:
        rows.setdefault(y, []).append(x)
    first = rows[min_y]
    cx = (min(first) + max(first)) / 2
    outer = cx - min_x + 0.5
    cy = min_y + outer - 0.5
    along = sorted(x for x, y in points if abs(y - cy) < 1 and x < cx)
    inner = cx - max(along) - 0.5
    return cx, cy, inner, outer


def grey_all(im, shade=1.0):
    px = im.load()
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            r, g, b, a = px[x, y]
            if a:
                v = min(255, round((r * 299 + g * 587 + b * 114) / 1000 * shade))
                px[x, y] = (v, v, v, a)
    return im


# Forever's frame cells: every ring on them becomes the stock one, everything else goes grey.
UF_SHEETS = ("Player-BACKGROUND.tga", "Player-BORDER.tga", "Player-Fat-BACKGROUND.tga", "Player-Fat-BORDER.tga",
             "Target-BACKGROUND.tga", "Target-BORDER.tga", "Target-Fat-BACKGROUND.tga", "Target-Fat-BORDER.tga",
             "Party-BACKGROUND.blp", "Party-BORDER.blp", "TargetofTarget-BACKGROUND.blp", "TargetofTarget-BORDER.blp",
             "Level.blp")


def build_unit_frames(stock):
    source = load(stock / "targetingframe/ui-targetingframe.blp")
    # The stock target ring, measured: its top-right quarter is free of the bars and the level badge.
    ring = StockRing(source, 182.5, 44.5, 26.5, 34.5, (-85, -10))
    for name in UF_SHEETS:
        im = load(ROOT / "UnitFrames" / "Forever" / name)
        region = (0, 0, 80, 80) if name == "Level.blp" else None
        cx, cy, inner, outer = find_ring(im, region)
        grey_all(im)
        paint_ring(im, ring, cx, cy, inner, outer)
        save_tga(im, OUT / "UnitFrames" / (Path(name).stem + ".tga"))
    badge = load(ROOT / "UnitFrames" / "pvpforever.blp")
    save_tga(silver(badge), OUT / "UnitFrames" / "pvpforever.tga")


SQUARE_LINE_SHADE = 0.65


def build_minimap(stock):
    source = load(stock / "minimap/ui-minimap-border.blp")
    ring = StockRing(source, 167.5, 104.5, 62.5, 72.0, (120, 240))
    im = load(ROOT / "Minimap" / "forever_circle.tga")
    cx, cy, inner, outer = find_ring(im)
    grey_all(im)
    save_tga(paint_ring(im, ring, cx, cy, inner, outer), OUT / "Minimap" / "forever_circle.tga")
    # DragonUI's ring is a thin line with gold pips: the stock ring replaces all of it, from the line's
    # inner edge outwards, measured on a diagonal where no pip lies.
    im = load(ROOT / "Minimap" / "uiminimapborder.tga")
    cx, cy = im.size[0] / 2 - 0.5, im.size[1] / 2 - 0.5
    px = im.load()
    along = [r for r in range(int(cx)) if px[round(cx + r * 0.7071), round(cy + r * 0.7071)][3] > 120]
    inner = min(along)
    blank = Image.new("RGBA", im.size, (0, 0, 0, 0))
    # Its mask keeps the pips, so the ring has to reach past them or the map shows outside it.
    outer = cx - 1
    save_tga(paint_ring(blank, ring, cx, cy, inner, outer), OUT / "Minimap" / "uiminimapborder.tga")
    for name in ("forever_pointer.tga", "forever_square_frame.tga", "forever_square_frame_rounded.tga",
                 "forever_square_pointer.tga"):
        save_tga(grey_all(load(ROOT / "Minimap" / name)), OUT / "Minimap" / name)
    # A white line on Forever's dark pips reads far brighter than any stock metal.
    save_tga(grey_all(load(ROOT / "Minimap" / "uiminimapsquareborder.tga"), SQUARE_LINE_SHADE),
             OUT / "Minimap" / "uiminimapsquareborder.tga")


def build_castbar(stock):
    border = load(stock / "castingbar/ui-castingbar-border.blp")
    art = border.crop(border.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
    sheet = load(ROOT / "Castbar" / "uicastingbar2x.tga")
    w, h = sheet.size
    # castbar.lua's border and text border rects.
    for left, right, top, bottom in ((0.412109375, 0.828125, 0.001953125, 0.060546875),):
        box = (round(left * w), round(top * h), round(right * w), round(bottom * h))
        sheet.paste((0, 0, 0, 0), box)
        paste_scaled(sheet, art, box)
    box = (round(0.001953125 * w), round(0.00390625 * h), round(0.412109375 * w), round(0.11328125 * h))
    sheet.paste(grey_all(sheet.crop(box)), box[:2])
    box = (round(0.000976562 * w), round(0.796875 * h), round(0.0859375 * w), round(0.970703 * h))
    sheet.paste(grey_all(sheet.crop(box)), box[:2])
    save_tga(sheet, OUT / "Castbar" / "uicastingbar2x.tga")


def atlas_rects(stems):
    """Rows of utils/atlas.lua's sheet(...) tables: {name: (file, across, down, left, right, top, bottom)}."""
    source = (ROOT.parent / "utils" / "atlas.lua").read_text(encoding="utf-8")
    rows, current = {}, None
    for line in source.splitlines():
        head = re.match(r"\s*sheet\((\w+), (\d+), (\d+), \{", line)
        if head:
            current = head.groups()
            continue
        row = re.match(r'\s*\{ "([^"]+)", [\d.]+, [\d.]+, (\d+), (\d+), (\d+), (\d+)', line)
        if row and current and any(stem in row.group(1) for stem in stems):
            rows[row.group(1)] = (current[0], int(row.group(2)), int(row.group(3)), int(row.group(4)), int(row.group(5)))
    return rows


def build_action_bars(stock):
    lion = load(stock / "mainmenubar/ui-mainmenubar-endcap-human.blp")
    lion = lion.crop(lion.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
    rows = atlas_rects(("-gryphon", "-wyvern"))
    sheets = {"uiactionbar2x_": "uiactionbar2x_.blp", "uiactionbar2x_new": "uiactionbar2x_new.blp",
              "uiactionbar2x_flying": "uiactionbar2x_flying.blp", "uiactionbar2x_forever": "uiactionbar2x_forever.blp"}
    for key, file in sheets.items():
        sheet = silver(load(ROOT / "ActionBars" / file))
        for name, (owner, left, right, top, bottom) in rows.items():
            if owner != key:
                continue
            art = lion if "left" in name else lion.transpose(Image.FLIP_LEFT_RIGHT)
            sheet.paste((0, 0, 0, 0), (left, top, right, bottom))
            scale = min((right - left) / art.size[0], (bottom - top) / art.size[1])
            fit = art.resize((round(art.size[0] * scale), round(art.size[1] * scale)), Image.LANCZOS)
            sheet.paste(fit, ((left + right - fit.size[0]) // 2, bottom - fit.size[1]))
        save_tga(sheet, OUT / "ActionBars" / (Path(file).stem + ".tga"))

    slot = load(stock / "buttons/ui-quickslot2.blp")
    slot = slot.crop(slot.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
    frame = load(ROOT / "ActionBars" / "uiactionbariconframe.tga")
    box = frame.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    out = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    paste_scaled(out, slot, box)
    save_tga(out, OUT / "ActionBars" / "uiactionbariconframe.tga")


def build_xp():
    for name in ("Background.tga", "Background_r.tga", "Overlay.tga", "Overlay_r.tga"):
        save_tga(grey_all(load(ROOT / "XP" / name)), OUT / "XP" / name)
    sheet = load(ROOT / "XP" / "uiexperiencebar.blp")
    strip = (0, 0, sheet.size[0], 16)
    sheet.paste(grey_all(sheet.crop(strip)), strip[:2])
    save_tga(sheet, OUT / "XP" / "uiexperiencebar.tga")


# Micro menu cells with a stock button.
MICRO_BUTTONS = {"Achievements": "achievement", "GameMenu": "mainmenu", "Groupfinder": "lfg", "GuildCommunities": "socials",
                 "Questlog": "quest", "SpecTalents": "talents", "SpellbookAbilities": "spellbook", "Professions": "abilities",
                 "Challenges": "world"}
# The rest have no stock icon, so theirs stands on the blank stock button: otherwise they float beside framed ones.
MICRO_ON_BLANK = ("Shop", "Collections")
MICRO_ICON_FILL = 0.62  # of the button's width, what the stock icons take
MICRO_GROUND_CELLS = {"up": (0.0654297, 0.12793, 0.330078, 0.490234), "down": (0.0654297, 0.12793, 0.494141, 0.654297)}


def opaque_box(im):
    return im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()


def blank_micro_button(stock, state):
    """The stock Character button, the only one without an icon: it has no disabled state of its own."""
    art = load(stock / f"buttons/ui-microbuttoncharacter-{'down' if state == 'down' else 'up'}.blp")
    art = art.crop(opaque_box(art))
    return grey_all(art, 0.6) if state == "disabled" else art


def icon_on_blank(stock, state, icon, size):
    """`icon` centred on the blank button, both scaled to a cell of `size`."""
    cell = blank_micro_button(stock, state).resize(size, Image.LANCZOS)
    icon = icon.crop(opaque_box(icon))
    scale = size[0] * MICRO_ICON_FILL / icon.size[0]
    fit = icon.resize((round(icon.size[0] * scale), round(icon.size[1] * scale)), Image.LANCZOS)
    cell.alpha_composite(fit, ((size[0] - fit.size[0]) // 2, (size[1] - fit.size[1]) // 2))
    return cell


def build_micro(stock):
    source = (ROOT.parent / "modules" / "micromenu.lua").read_text(encoding="utf-8")
    forever = load(ROOT / "Micromenu" / "uimicromenu2x.blp")
    sheet = forever.copy()
    w, h = sheet.size
    states = {"Up": "up", "Mouseover": "up", "Down": "down", "Disabled": "disabled"}
    pattern = r'\["UI-HUD-MicroMenu-(\w+)-(Up|Down|Mouseover|Disabled)"\] = \{([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\}'
    for name, state, left, right, top, bottom in re.findall(pattern, source):
        box = (round(float(left) * w), round(float(top) * h), round(float(right) * w), round(float(bottom) * h))
        if name in MICRO_ON_BLANK:
            art = icon_on_blank(stock, states[state], forever.crop(box), (box[2] - box[0], box[3] - box[1]))
            sheet.paste((0, 0, 0, 0), box)
            sheet.paste(art, box[:2])
            continue
        stem = MICRO_BUTTONS.get(name)
        art_path = stem and stock / f"buttons/ui-microbutton-{stem}-{states[state]}.blp"
        if not art_path or not art_path.exists():
            continue
        art = load(art_path)
        art = art.crop(art.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
        sheet.paste((0, 0, 0, 0), box)
        paste_scaled(sheet, art, box)
    # The cells micromenu.lua lays behind the portrait and the PvP crest.
    for state, (left, right, top, bottom) in MICRO_GROUND_CELLS.items():
        box = (round(left * w), round(top * h), round(right * w), round(bottom * h))
        sheet.paste((0, 0, 0, 0), box)
        paste_scaled(sheet, blank_micro_button(stock, state), box)
    save_tga(sheet, OUT / "Micromenu" / "uimicromenu2x.tga")

    # micromenu.lua's Professions row: up, down, mouseover, disabled.
    hammers = load(ROOT / "Professions" / "MicroButton.tga")
    for column, state in enumerate(("up", "down", "up", "disabled")):
        box = (column * 64, 0, (column + 1) * 64, 82)
        art = icon_on_blank(stock, state, hammers.crop(box), (64, 82))
        hammers.paste((0, 0, 0, 0), box)
        hammers.paste(art, box[:2])
    save_tga(hammers, OUT / "Micromenu" / "MicroButton.tga")

    # SetupPVPButton's two faction cells.
    pvp = load(ROOT / "Micromenu" / "micropvp.blp")
    for column in range(2):
        box = (column * 118, 0, (column + 1) * 118, 151)
        art = icon_on_blank(stock, "up", pvp.crop(box), (118, 151))
        pvp.paste((0, 0, 0, 0), box)
        pvp.paste(art, box[:2])
    save_tga(pvp, OUT / "Micromenu" / "micropvp.tga")


def mapped(stock, box, sx, ox, sy, oy):
    """The sheet rect `box` sampled from `stock` by stock = (sheet - offset) / scale."""
    left, top, right, bottom = box
    out = Image.new("RGBA", (right - left, bottom - top), (0, 0, 0, 0))
    sw, sh = stock.size
    src, dst = stock.load(), out.load()
    for y in range(top, bottom):
        sample_y = (y - top - oy) // sy
        if not 0 <= sample_y < sh:
            continue
        for x in range(left, right):
            sample_x = (x - left - ox) // sx
            if 0 <= sample_x < sw:
                dst[x - left, y - top] = src[sample_x, sample_y]
    return out


def keep(im, test):
    """Clears pixels whose (x, y) fails `test`."""
    px = im.load()
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            if not test(x, y):
                px[x, y] = (0, 0, 0, 0)
    return im


# Rows and columns of the title bar in ui-character-general-topleft: its lower rail, the first
# column the ring's shadow has left, and the 128 columns that tile (they run into the top right piece).
BAND_RAIL, BAND_CLEAN, BAND_TILE = 33, 80, 128
BLEED = 3
# The top right piece mirrored: this many columns put its outer rail on the left rail's. CORNER_END is the sheet
# column, clear of the close box's far side, where that corner gives way to the band.
MIRROR_SHIFT, CORNER_END = 23, 46


def bleed_sideways(sheet, box):
    left, top, right, bottom = box
    for x, source in [(left - i, left) for i in range(1, BLEED + 1)] + [(right - 1 + i, right - 1) for i in range(1, BLEED + 1)]:
        sheet.paste(sheet.crop((source, top, source + 1, bottom)), (x, top))


def bleed_upright(sheet, box):
    left, top, right, bottom = box
    for y, source in [(top - i, top) for i in range(1, BLEED + 1)] + [(bottom - 1 + i, bottom - 1) for i in range(1, BLEED + 1)]:
        sheet.paste(sheet.crop((left, source, right, source + 1)), (left, y))


def build_frame(stock):
    tl = load(stock / "paperdollinfoframe/ui-character-general-topleft.blp")
    tr = load(stock / "paperdollinfoframe/ui-character-general-topright.blp")
    bl = load(stock / "paperdollinfoframe/ui-character-general-bottomleft.blp")
    br = load(stock / "paperdollinfoframe/ui-character-general-bottomright.blp")
    forever = load(ROOT / "ForeverUI" / "chrome-frame.tga")
    sheet = Image.new("RGBA", forever.size, (0, 0, 0, 0))

    # Sheet y = 2 * stock y + 6 in the band pieces: the stock title stone (15..33) lands on 36..72.
    band_y, band_end = 6, 38
    # Left rail: stock 12..17 lands on 26..37. Right rail: stock 87..92 lands on 175..186.
    left_x, right_x = 2, 1
    edge = bl.getchannel("A").crop((100, 0, 101, 256))
    last = edge.point(lambda v: 255 if v > 8 else 0).getbbox()[3] - 1
    # Bottom rail: the last six solid stock rows, inner edge on 55 in a corner's 80-tall rect. Its shadow hangs below.
    rail_top = edge.point(lambda v: 255 if v > 200 else 0).getbbox()[3] - 6
    corner_y = 55 - 2 * rail_top

    def band(x, y):
        return (y - band_y) // 2 <= band_end

    def left_rail(x, y):
        return 12 <= (x - left_x) // 2 <= 17

    def right_rail(x, y):
        return 87 <= (x - right_x) // 2 <= 92

    def bottom_rail(y, oy):
        return rail_top <= (y - oy) // 2 <= last

    # What shows under the title's lower rail fades out, as Forever's shadow does, instead of ending on stock's stone.
    def fade_under_band(im, oy, spared=lambda x, y: False):
        px = im.load()
        for y in range(im.size[1]):
            row = (y - oy) // 2
            if BAND_RAIL < row <= band_end:
                strength = 1 - (row - BAND_RAIL) / (band_end - BAND_RAIL + 1)
                for x in range(im.size[0]):
                    if not spared(x, y):
                        r, g, b, a = px[x, y]
                        px[x, y] = (r, g, b, round(a * strength))
        return im

    # The stock bar's own run, clear of the shadow the portrait ring throws on it. The tile's end fades
    # into what precedes its start, so it repeats without a seam, and the corner ends where the tile starts.
    clean = BAND_CLEAN
    run = tl.crop((0, 0, tl.width, tl.height))
    tile = run.crop((BAND_TILE, 0, BAND_TILE + 128, tl.height))
    fade = 24
    before = run.crop((BAND_TILE - fade, 0, BAND_TILE, tl.height))
    for i in range(fade):
        column = (128 - fade + i, 0, 128 - fade + i + 1, tl.height)
        blended = Image.blend(tile.crop(column), before.crop((i, 0, i + 1, tl.height)), (i + 1) / fade)
        tile.paste(blended, column[:2])
    corner_band = Image.new("RGBA", (95, tl.height), (0, 0, 0, 0))
    for i in range(95):
        x = BAND_TILE - 95 + i
        x = x if x >= clean else 2 * clean - x
        corner_band.paste(run.crop((x, 0, x + 1, tl.height)), (i, 0))

    # Straight runs, cut well clear of the portrait ring and the close box.
    sheet.paste(mapped(tl, (4, 4, 194, 260), 2, left_x, 2, -200), (4, 4))
    keep_box = (4, 4, 194, 260)
    sheet.paste(keep(sheet.crop(keep_box), left_rail), keep_box)
    sheet.paste(keep(mapped(tr, (202, 4, 392, 260), 2, right_x, 2, -200), right_rail), (202, 4))
    sheet.paste(keep(mapped(bl, (400, 4, 656, 204), 2, -140, 2, 175 - 2 * rail_top),
                     lambda x, y: bottom_rail(y, 175 - 2 * rail_top)), (400, 4))
    sheet.paste(fade_under_band(keep(mapped(tile, (202, 268, 458, 458), 2, 0, 2, band_y), band), band_y), (202, 268))

    # Corners. Top right keeps the stock close box the band's close button sits in.
    # Right-rail mappings start a column before the stock piece: that column repeats the first one, or the band shows a gap there.
    sheet.paste(fade_under_band(keep(mapped(tr, (664, 268, 854, 364), 2, right_x, 2, band_y),
                                     lambda x, y: band(x, y) or right_rail(x, y)), band_y, right_rail), (664, 268))
    sheet.paste(sheet.crop((665, 268, 666, 364)), (664, 268))
    # Stock's rail is dark beside its toolbar stone; here the same straight run as below meets the band.
    straight = keep(mapped(tr, (664, 268, 854, 364), 2, right_x, 2, -200),
                    lambda x, y: right_rail(x, y) and (y - band_y) // 2 >= BAND_RAIL + 4)
    sheet.paste(straight, (664, 268), straight.getchannel("A"))
    sheet.paste(keep(mapped(bl, (664, 124, 854, 204), 2, left_x, 2, corner_y),
                     lambda x, y: left_rail(x, y) or (bottom_rail(y, corner_y) and x >= 26)), (664, 124))
    sheet.paste(keep(mapped(br, (4, 388, 194, 468), 2, right_x, 2, corner_y),
                     lambda x, y: right_rail(x, y) or (bottom_rail(y, corner_y) and x <= 186)), (4, 388))
    sheet.paste(sheet.crop((5, 388, 6, 468)), (4, 388))

    # Top left has no stock counterpart without the ring: the top right's outer corner mirrored onto the
    # left rail, then the band from inside that corner's rim, and the left rail from under the band.
    rim = keep(mapped(ImageOps.mirror(tr), (0, 0, 190, 96), 2, left_x - 2 * MIRROR_SHIFT, 2, band_y),
               lambda x, y: x < CORNER_END and (y - band_y) // 2 <= BAND_RAIL)
    alpha = rim.getchannel("A").load()
    def inside_rim(x, y):
        if (y - band_y) // 2 > BAND_RAIL:
            return x >= 26
        return any(alpha[column, y] > 200 for column in range(26, min(x, CORNER_END - 1) + 1))
    corner = fade_under_band(keep(mapped(corner_band, (0, 0, 190, 96), 2, 0, 2, band_y),
                                  lambda x, y: band(x, y) and inside_rim(x, y)), band_y)
    corner.alpha_composite(rim)
    rail_from = band_y + 2 * (BAND_RAIL + 1)
    corner.alpha_composite(keep(mapped(tl, (0, 0, 190, 96), 2, left_x, 2, -200), lambda x, y: left_rail(x, y) and y >= rail_from))
    sheet.paste(corner, (466, 268))

    # Filtering reads past a rect's edge: the sheet's clear neighbours showed as a line at every join.
    for box in ((202, 268, 458, 458), (466, 268, 656, 364), (664, 268, 854, 364), (400, 4, 656, 204),
                (664, 124, 854, 204), (4, 388, 194, 468)):
        bleed_sideways(sheet, box)
    for box in ((4, 4, 194, 260), (202, 4, 392, 260)):
        bleed_upright(sheet, box)
    save_tga(sheet, OUT / "chrome-frame.tga")


def build_grounds():
    """Same tiling art as Forever's, in stock's greys, and the exact BLP format the client accepts."""
    for name, target, mode in (("ui-background-rock", ROCK_MEAN, "scale"), ("ui-background-marble", MARBLE_MEAN, "scale")):
        src = ROOT / "UI" / f"{name}.blp"
        grey = ImageOps.grayscale(Image.open(src).convert("RGB")).convert("RGB")
        OUT.mkdir(parents=True, exist_ok=True)
        write_like(src, recolour(grey, target, mode), OUT / f"{name}.blp")


def button_pieces(art):
    """Stock's 78x21 panel button (at 1,1) as Forever's 3-slice: a cap and a middle of one state."""
    return art.crop((1, 1, 21, 22)), art.crop((34, 1, 46, 22))


def paste_scaled(sheet, im, rect):
    left, top, right, bottom = rect
    sheet.paste(im.resize((right - left, bottom - top), Image.LANCZOS), (left, top))


def build_buttons(stock):
    states = {name: load(stock / f"buttons/ui-panel-button-{name}.blp") for name in ("up", "down", "disabled")}
    glow = load(stock / "buttons/ui-panel-button-highlight.blp").crop((0, 0, 80, 22))
    # Square, 19 by 19 with one clear row: the seat in utils/skins.lua draws it at stock size in the stock socket.
    close = {name: load(stock / f"buttons/ui-panel-minimizebutton-{name}.blp").crop((6, 7, 25, 26))
             for name in ("up", "down", "disabled")}
    close_glow = load(stock / "buttons/ui-panel-minimizebutton-highlight.blp").crop((6, 7, 25, 26))

    # utils/redbutton.lua: caps and middles per state, and the highlight strip of 221 across.
    sheet = load(ROOT / "UI" / "redbutton3slice.tga")
    rects = {"up": ((4, 76, 61, 140), (4, 148, 36, 212)), "down": ((136, 76, 193, 140), (84, 148, 116, 212)),
             "disabled": ((70, 76, 127, 140), (44, 148, 76, 212))}
    for name, (cap_rect, mid_rect) in rects.items():
        cap, mid = button_pieces(states[name])
        paste_scaled(sheet, cap, cap_rect)
        paste_scaled(sheet, mid, mid_rect)
    paste_scaled(sheet, glow, (4, 4, 225, 68))
    save_tga(sheet, OUT / "redbutton3slice.tga")

    # characterpanel/chrome.lua's close button rects on redbutton2x.
    sheet = silver(load(ROOT / "UI" / "redbutton2x.blp"))
    paste_scaled(sheet, close["up"], (39, 1, 75, 39))
    paste_scaled(sheet, close["disabled"], (39, 41, 75, 79))
    paste_scaled(sheet, close["down"], (39, 81, 75, 119))
    paste_scaled(sheet, close_glow, (115, 1, 151, 39))
    save_tga(sheet, OUT / "redbutton2x.tga")

    # utils/forever_atlas_chrome.lua: the options panel's and dialogs' buttons on chrome-buttons.
    sheet = silver(load(ROOT / "ForeverUI" / "chrome-buttons.tga"))
    pieces = (("up", (76, 220, 133, 284), (274, 220, 306, 284), (232, 4, 378, 68)),
              ("disabled", (142, 220, 199, 284), (314, 220, 346, 284), (4, 76, 150, 140)),
              ("down", (208, 220, 265, 284), (354, 220, 386, 284), (158, 76, 304, 140)))
    for name, left_rect, mid_rect, right_rect in pieces:
        cap, mid = button_pieces(states[name])
        paste_scaled(sheet, cap, left_rect)
        paste_scaled(sheet, mid, mid_rect)
        paste_scaled(sheet, states[name].crop((46, 1, 79, 22)), right_rect)
    paste_scaled(sheet, glow, (4, 4, 224, 68))
    for name, rects_for_state in (("up", ((312, 76, 376, 140), (292, 148, 356, 212))),
                                  ("disabled", ((384, 76, 448, 140), (364, 148, 428, 212))),
                                  ("down", ((4, 148, 68, 212), (436, 148, 500, 212)))):
        for rect in rects_for_state:
            paste_scaled(sheet, close[name], rect)
    save_tga(sheet, OUT / "chrome-buttons.tga")


def build_tabs(stock):
    """characterpanel/tabs.lua's rects on uiframetabs: caps and a 1-wide middle, inactive and active."""
    inactive = load(stock / "paperdollinfoframe/ui-character-inactivetab.blp")
    active = load(stock / "paperdollinfoframe/ui-character-activetab.blp")
    sheet = Image.new("RGBA", load(ROOT / "UI" / "uiframetabs.blp").size, (0, 0, 0, 0))

    def cut(art, top_rect, right_rect, mid_rect, x0, x1, y0, y1):
        cap_w = 30
        paste_scaled(sheet, art.crop((x0, y0, x0 + cap_w, y1)), top_rect)
        paste_scaled(sheet, art.crop((x1 - cap_w, y0, x1, y1)), right_rect)
        # The rects are one column wide but filtering reads the next one too, so the strip fills the sheet's width.
        paste_scaled(sheet, art.crop((60, y0, 61, y1)), (0, mid_rect[1], sheet.width, mid_rect[3]))

    cut(inactive, (1, 209, 36, 245), (1, 171, 38, 207), (0, 45, 1, 81), 6, 118, 2, 29)
    cut(active, (1, 127, 36, 169), (1, 83, 38, 125), (0, 1, 1, 43), 6, 119, 0, 32)
    save_tga(sheet, OUT / "uiframetabs.tga")


def plain_inset_corners(sheet):
    """Stock has no filigree: the inset trim's corners become its edges' rail, mitred across a small chamfer."""
    left, top, right, bottom, cut = 4, 4, 218, 218, 52
    px = sheet.load()
    mid_x, mid_y = (left + right) // 2, (top + bottom) // 2
    profiles = {"top": [px[mid_x, top + d] for d in range(cut)], "bottom": [px[mid_x, bottom - 1 - d] for d in range(cut)],
                "left": [px[left + d, mid_y] for d in range(cut)], "right": [px[right - 1 - d, mid_y] for d in range(cut)]}
    # The rail starts this far in, and the corner's chamfer is measured from there.
    start = next(d for d, pixel in enumerate(profiles["top"]) if pixel[3] > 128)
    for y in range(cut):
        for x in range(cut):
            depth = min(x, y, (x + y - start - 6) * 0.7071 + start)
            for flip_x, flip_y, side_x, side_y in ((0, 0, "left", "top"), (1, 0, "right", "top"),
                                                   (0, 1, "left", "bottom"), (1, 1, "right", "bottom")):
                profile = profiles[side_x if x < y else side_y]
                pixel = profile[int(depth)] if depth >= 0 else (0, 0, 0, 0)
                px[(right - 1 - x) if flip_x else (left + x), (bottom - 1 - y) if flip_y else (top + y)] = pixel


def build_ring(stock):
    """Professions sheet in grey metal with the stock portrait ring in the bronze ring's rect."""
    tl = load(stock / "paperdollinfoframe/ui-character-general-topleft.blp")
    sheet = silver(load(ROOT / "Professions" / "ProfessionsUI.tga"))
    # Stock ring centre and radii, on the 1x sheet; the layout draws 128 sheet px as 88 UI units.
    cx, cy, outer, inner = 37, 37, 34.5, 29.0
    scale = 128 / 88
    box = (424, 4, 552, 132)
    ring = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    src, dst = tl.load(), ring.load()
    for y in range(128):
        for x in range(128):
            sx, sy = (x - 64) / scale + cx, (y - 64) / scale + cy
            r = ((sx - cx) ** 2 + (sy - cy) ** 2) ** 0.5
            if inner <= r <= outer and 0 <= sx < 256 and 0 <= sy < 256:
                dst[x, y] = src[int(sx), int(sy)]
    sheet.paste(ring, box[:2])
    plain_inset_corners(sheet)
    save_tga(sheet, OUT / "ProfessionsUI.tga")


# --- Decorated windows: talents, spellbook, professions, collections ---

BLP_HEADER = 148 + 1024  # header, then the 256-entry palette DXT leaves unused


def dxt5_level(im, width, height):
    level = im.resize((width, height), Image.BOX) if im.size != (width, height) else im
    if width < 4 or height < 4:
        level = level.resize((max(4, width), max(4, height)), Image.NEAREST)
    buf = io.BytesIO()
    level.save(buf, "DDS", pixel_format="DXT5")
    return buf.getvalue()[128:][:max(1, (width + 3) // 4) * max(1, (height + 3) // 4) * 16]


def save_blp(im, path, alpha=True):
    """BLP2 with every mip level: DXT5, or DXT1 where no alpha is needed. The client draws palettised ones green."""
    path.parent.mkdir(parents=True, exist_ok=True)
    width, height = im.size
    source = im.convert("RGBA") if alpha else im.convert("RGB")
    encode = dxt5_level if alpha else dxt1_level
    blobs = []
    w, h = width, height
    while True:
        blobs.append(encode(source, w, h))
        if w == 1 and h == 1:
            break
        w, h = max(1, w // 2), max(1, h // 2)
    offsets, sizes, at = [], [], BLP_HEADER
    for blob in blobs:
        offsets.append(at)
        sizes.append(len(blob))
        at += len(blob)
    pad = [0] * (16 - len(blobs))
    header = b"BLP2" + struct.pack("<I4B2I", 1, 2, 8 if alpha else 0, 7 if alpha else 0, 1, width, height)
    header += struct.pack("<16I", *(offsets + pad)) + struct.pack("<16I", *(sizes + pad))
    path.write_bytes(header + bytes(1024) + b"".join(blobs))


def scale_to_mean(im, target):
    """Stock art to a target mean, its grain kept."""
    rgb = im.convert("RGB")
    means = [sum(c * n for c, n in enumerate(band.histogram())) / (rgb.size[0] * rgb.size[1]) for band in rgb.split()]
    bands = [band.point(lambda v, f=t / max(m, 1): min(255, round(v * f))) for band, t, m in zip(rgb.split(), target, means)]
    return Image.merge("RGB", bands)


def tile_mirrored(tile, size):
    """Covers `size` with a tile and its mirror images, so no seam shows."""
    width, height = tile.size
    across = Image.new("RGB", (width * 2, height))
    across.paste(tile, (0, 0))
    across.paste(ImageOps.mirror(tile), (width, 0))
    block = Image.new("RGB", (width * 2, height * 2))
    block.paste(across, (0, 0))
    block.paste(ImageOps.flip(across), (0, height))
    out = Image.new("RGB", size)
    for y in range(0, size[1], height * 2):
        for x in range(0, size[0], width * 2):
            out.paste(block, (x, y))
    return out


def dark_stone(stock, size):
    """Stock's stone page in grey, for dark grounds: its own black rock is too dark to brighten for a
    sheet shade without its 16-bit colour showing as green blocks, and too small to cover these sheets."""
    return ImageOps.grayscale(cover(stone(stock), *size)).convert("RGB")


def stone(stock):
    pieces = [load(stock / f"itemtextframe/itemtext-stone-{name}.blp") for name in ("topleft", "topright", "botleft", "botright")]
    sheet = Image.new("RGB", (pieces[0].width + pieces[1].width, pieces[0].height + pieces[2].height))
    sheet.paste(pieces[0], (0, 0))
    sheet.paste(pieces[1], (pieces[0].width, 0))
    sheet.paste(pieces[2], (0, pieces[0].height))
    sheet.paste(pieces[3], (pieces[0].width, pieces[0].height))
    return sheet


def parchment(stock):
    """The paper of stock's spellbook, its burnt lower edge included."""
    names = ("topleft", "topright", "botleft", "botright")
    pieces = [load(stock / f"spellbook/ui-spellbookpanel-{name}.blp") for name in names]
    sheet = Image.new("RGB", (512, 512))
    for piece, at in zip(pieces, ((0, 0), (256, 0), (0, 256), (256, 256))):
        sheet.paste(piece.convert("RGB"), at)
    return sheet.crop(PAGE_BOX)


# The paper in the assembled stock spellbook panel, clear of its rails.
PAGE_BOX = (26, 68, 330, 438)


def write_halves(wide, stem, size=512):
    """A 2048x1024 picture as NAME and NAME_r, the halves the talent window's Pair draws."""
    save_blp(wide.crop((0, 0, 1024, 1024)).resize((size, size), Image.LANCZOS), OUT / "Talents" / f"{stem}.blp", alpha=False)
    save_blp(wide.crop((1024, 0, 2048, 1024)).resize((size, size), Image.LANCZOS), OUT / "Talents" / f"{stem}_r.blp", alpha=False)


def talent_tree_art(stock, name):
    pieces = [load(stock / f"talentframe/{name}-{part}.blp").convert("RGB") for part in ("topleft", "topright", "bottomleft", "bottomright")]
    art = Image.new("RGB", (pieces[0].width + pieces[1].width, pieces[0].height + pieces[2].height))
    art.paste(pieces[0], (0, 0))
    art.paste(pieces[1], (pieces[0].width, 0))
    art.paste(pieces[2], (0, pieces[0].height))
    art.paste(pieces[3], (pieces[0].width, pieces[0].height))
    return art.crop((0, 0, art.width, TALENT_TREE_ROWS))


def cover(im, width, height):
    scale = max(width / im.width, height / im.height)
    grown = im.resize((round(im.width * scale), round(im.height * scale)), Image.BICUBIC)
    left, top = (grown.width - width) // 2, (grown.height - height) // 2
    return grown.crop((left, top, left + width, top + height))


# Each class's three trees in stock's tab order. Stock draws one tree's art per pane, so each class's
# sheet holds all three, and every spec sheet of that class swaps to it.
TALENT_TREES = {
    "warrior": ("warriorarms", "warriorfury", "warriorprotection"),
    "paladin": ("paladinholy", "paladinprotection", "paladincombat"),
    "hunter": ("hunterbeastmastery", "huntermarksmanship", "huntersurvival"),
    "rogue": ("rogueassassination", "roguecombat", "roguesubtlety"),
    "priest": ("priestdiscipline", "priestholy", "priestshadow"),
    "shaman": ("shamanelementalcombat", "shamanenhancement", "shamanrestoration"),
    "mage": ("magearcane", "magefire", "magefrost"),
    "warlock": ("warlockcurses", "warlocksummoning", "warlockdestruction"),
    "druid": ("druidbalance", "druidferalcombat", "druidrestoration"),
    "deathknight": ("deathknightblood", "deathknightfrost", "deathknightunholy"),
}
TALENT_SPEC_FILES = {
    "warrior": ("", "-fury", "-protection"), "paladin": ("", "-protection", "-retribution"),
    "hunter": ("", "-marksmanship", "-survival"), "rogue": ("", "-outlaw", "-subtlety"),
    "priest": ("", "-holy", "-shadow"), "shaman": ("", "-enhancement", "-restoration"),
    "mage": ("", "-fire", "-frost"), "warlock": ("", "-demonology", "-destruction"),
    "druid": ("", "-feral", "-restoration"), "deathknight": ("", "-frost", "-unholy"),
}
# Where the panes meet on the 2048-wide sheet: halfway between the tree columns of tree_canvas.lua
# (213, 560, 907 window units) under the left crop ns.SetClassArt takes at the default 11 tiers.
TALENT_SEAMS = (117, 634, 1096, 1613)
TALENT_TREE_ROWS = 336  # stock's lower pieces are 128 tall, with 80 rows of art
TALENT_ART_HEIGHT = 784
TALENT_SHADE = 0.8


def build_talent_grounds(stock):
    seam_shade = Image.new("L", (64, 1))
    for x in range(64):
        seam_shade.putpixel((x, 0), round(255 * (0.35 + 0.65 * abs(x - 31.5) / 31.5)))
    for klass, trees in TALENT_TREES.items():
        wide = Image.new("RGB", (2048, 1024))
        for index, tree in enumerate(trees):
            left, right = TALENT_SEAMS[index], TALENT_SEAMS[index + 1]
            pane = cover(talent_tree_art(stock, tree), right - left, TALENT_ART_HEIGHT)
            wide.paste(pane, (left, 0))
        # Off the crop at 11 tiers; shallower windows keep this strip in view.
        wide.paste(ImageOps.mirror(wide.crop((117, 0, 234, TALENT_ART_HEIGHT))), (0, 0))
        wide = wide.point(lambda v: round(v * TALENT_SHADE))
        black = Image.new("RGB", (64, TALENT_ART_HEIGHT))
        for seam in TALENT_SEAMS[1:3]:
            box = (seam - 32, 0, seam + 32, TALENT_ART_HEIGHT)
            wide.paste(Image.composite(wide.crop(box), black, seam_shade.resize((64, TALENT_ART_HEIGHT))), box[:2])
        write_halves(wide, klass)

    for kind in ("Cunning", "Ferocity", "Tenacity"):
        art = talent_tree_art(stock, f"hunterpet{kind.lower()}")
        wide = cover(art, 2048, 1024).filter(ImageFilter.GaussianBlur(28)).point(lambda v: round(v * 0.45))
        sharp = art.resize((round(art.width * 1024 / art.height), 1024), Image.BICUBIC).point(lambda v: round(v * TALENT_SHADE))
        mask = Image.new("L", sharp.size, 255)
        for x in range(90):
            for y in range(sharp.height):
                value = round(255 * x / 90)
                mask.putpixel((x, y), value)
                mask.putpixel((sharp.width - 1 - x, y), value)
        wide.paste(sharp, ((2048 - sharp.width) // 2, 0), mask)
        write_halves(wide, f"Pet_{kind}")

    ground = scale_to_mean(stone(stock), (40, 40, 38))
    write_halves(tile_mirrored(ground, (2048, 1024)), "glyph-ground", 256)


def tinted(piece, colour):
    """A stock white piece under the vertex colour stock gives it, baked."""
    grey = piece.convert("L")
    bands = [grey.point(lambda v, c=c: min(255, round(v * c))) for c in colour]
    return Image.merge("RGBA", bands + [piece.getchannel("A")])


def grey_ring(stock, centre, radius, gain):
    ring = glyph_ring(stock, centre, radius)
    grey = ImageOps.grayscale(ring.convert("RGB")).point(lambda v, g=gain: min(255, round(v * g)))
    return Image.merge("RGBA", (grey, grey, grey, ring.getchannel("A")))


def slot_edge(stock, name, box, inset):
    """A stock slot with its middle cut out: these sheets draw over the icon, stock draws under it."""
    piece = load(stock / name).crop(box).convert("RGBA")
    alpha = piece.getchannel("A")
    width, height = piece.size
    hole = Image.new("L", (width - inset * 2, height - inset * 2), 0)
    alpha.paste(hole, (inset, inset))
    piece.putalpha(alpha)
    return piece


def glyph_ring(stock, centre, radius):
    sheet = load(stock / "spellbook/ui-glyphframe.blp")
    return sheet.crop((centre[0] - radius, centre[1] - radius, centre[0] + radius, centre[1] + radius)).convert("RGBA")


def fit_into(sheet, piece, rect):
    left, top, right, bottom = rect
    sheet.paste((0, 0, 0, 0), rect)
    sheet.paste(piece.resize((right - left, bottom - top), Image.LANCZOS), (left, top))


# Stock's own talent slot colours: TalentFrame_Update's vertex colours.
TALENT_STATES = {"gray": (0.5, 0.5, 0.5), "locked": (0.3, 0.3, 0.3), "green": (0.1, 1.0, 0.1), "yellow": (1.0, 0.82, 0.0)}
TALENT_SQUARE_RECTS = {"gray": (906, 183, 986, 263), "green": (906, 269, 986, 349),
                       "locked": (904, 355, 984, 435), "yellow": (818, 271, 898, 351)}
TALENT_CIRCLE_RECTS = {"gray": (85, 385, 135, 435), "green": (141, 385, 191, 435),
                       "locked": (253, 385, 303, 435), "yellow": (197, 385, 247, 435)}
TALENT_APEX_RECTS = {"gray": (822, 3, 906, 87), "green": (912, 3, 996, 87),
                     "locked": (912, 93, 996, 177), "yellow": (822, 93, 906, 177)}


def build_talent_nodes(stock):
    sheet = silver(load(ROOT / "Talents/talents-sheet.tga"))
    square = slot_edge(stock, "buttons/ui-emptyslot-white.blp", (9, 9, 54, 54), 4)
    thin_ring = grey_ring(stock, GLYPH_THIN_RING, 30, 2)
    thick_ring = grey_ring(stock, GLYPH_THICK_RING, 40, 1.5)
    for state, colour in TALENT_STATES.items():
        fit_into(sheet, tinted(square, colour), TALENT_SQUARE_RECTS[state])
        fit_into(sheet, tinted(thin_ring, colour), TALENT_CIRCLE_RECTS[state])
        fit_into(sheet, tinted(thick_ring, colour), TALENT_APEX_RECTS[state])
    save_tga(sheet, OUT / "Talents/talents-sheet.tga")
    save_tga(silver(load(ROOT / "Talents/talentframeatlas.blp")), OUT / "Talents/talentframeatlas.tga")


# Centres in stock's ui-glyphframe sheet.
GLYPH_THIN_RING, GLYPH_THICK_RING = (434, 48), (434, 206)

# Forever's spell ring rects, and the icon inside each in its own pixels (book_slots.lua SHAPES on a
# 48-unit well with a 41-unit icon: GROW 1.2, so 2.2 sheet pixels a unit on the 138-wide rect).
SPELL_RINGS = {"iconframe": ((884, 4, 1022, 135), (-11, 1, 1, -7)),
               "iconframe-inactive": ((148, 320, 284, 447), (-10, 1, 2, -5))}


SPELLBOOK_CORNER = (4, 4, 604, 314)


def build_spellbook(stock):
    paper = parchment(stock)
    band = load(stock / "questframe/ui-questlogdualpane-left.blp").crop((120, 38, 512, 60)).convert("RGB")

    forever = load(ROOT / "Spellbook/spellbook-background.blp")
    right = paper.resize((807, 805), Image.LANCZOS).convert("RGBA")
    right.putalpha(forever.crop((4, 68, 811, 873)).getchannel("A"))
    forever.paste(right, (4, 68))
    forever.paste(band.resize((807, 58), Image.LANCZOS), (4, 4))
    rule = load(stock / "questframe/ui-horizontalbreak.blp").convert("RGBA")
    box = rule.getchannel("A").getbbox()
    fit_into(forever, rule.crop(box), (8, 880, 665, 891))
    save_blp(forever, OUT / "Spellbook/spellbook-background.blp")

    other = load(ROOT / "Spellbook/spellbook-background_r.blp")
    left = ImageOps.mirror(paper).resize((806, 805), Image.LANCZOS).convert("RGBA")
    left.putalpha(other.crop((156, 68, 962, 873)).getchannel("A"))
    other.paste(left, (156, 68))
    other.paste(band.resize((807, 58), Image.LANCZOS), (43, 4))
    save_blp(other, OUT / "Spellbook/spellbook-background_r.blp")

    # Stock has no ribbon: where the two pages meet, the book's fold.
    spine = Image.new("RGBA", (128, 1024), (0, 0, 0, 0))
    for x in range(102):
        strength = round(90 * math.exp(-(((x - 50.5) / 22) ** 2)))
        for y in range(557):
            spine.putpixel((x, y), (20, 10, 0, strength))
    save_tga(spine, OUT / "Spellbook/spellbook-ribbon.tga")

    elements = load(ROOT / "Spellbook/spellbookelements.blp")
    # Forever's page corner carries a square of its own paper, and stock's book has no curl.
    elements.paste((0, 0, 0, 0), SPELLBOOK_CORNER)
    edge = slot_edge(stock, "spellbook/ui-spellbook-spellbackground.blp", (0, 0, 43, 43), 3)
    for rect, (left_units, top_units, right_units, bottom_units) in SPELL_RINGS.values():
        # The icon's box in the rect, then the stock edge just outside it.
        grow, well, icon = 1.2, 48, 41
        span_x = well + (right_units - left_units) * grow
        span_y = well + (top_units - bottom_units) * grow
        per_x, per_y = (rect[2] - rect[0]) / span_x, (rect[3] - rect[1]) / span_y
        margin = (well - icon) / 2
        x0 = rect[0] + (margin - left_units * grow) * per_x
        y0 = rect[1] + (margin + top_units * grow) * per_y
        out = 3.0
        box = (round(x0 - out * per_x), round(y0 - out * per_y),
               round(x0 + (icon + out) * per_x), round(y0 + (icon + out) * per_y))
        elements.paste((0, 0, 0, 0), rect)
        elements.paste(edge.resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS), box[:2])
    save_blp(elements, OUT / "Spellbook/spellbookelements.blp")


# What the professions window shows after its vertex colour (P.SheetShade): dark, so dark stone.
PROF_GROUNDS = {
    "Backdrop1": (49 / 255, ((2, 2, 667, 572),), (30, 30, 29)),
    "Backdrop2": (120 / 255, ((2, 2, 667, 572),), (26, 26, 25)),
    "Banners": (118 / 255, ((2, 2, 666, 286), (2, 290, 666, 574)), (32, 32, 31)),
    "CardBase": (40 / 255, ((2, 2, 722, 970),), (34, 34, 33)),
}
PROF_DRAWINGS = {"Drawings1": 81 / 255, "Drawings2": 81 / 255, "Drawings3": 81 / 255, "Drawings4": 83 / 255,
                 "Drawings5": 100 / 255, "Drawings6": 100 / 255, "Drawings7": 100 / 255, "Drawings8": 55 / 255}
PROF_HEADROOM = 1.5  # room to lighten above the mean when printing onto rock


def shaded_ground(stock, size, shade, shown, soften=0):
    """Stone that shows at `shown` under the sheet's vertex colour."""
    ground = dark_stone(stock, size)
    if soften:
        ground = ground.filter(ImageFilter.GaussianBlur(soften))
    return scale_to_mean(ground, tuple(min(255, c / shade) for c in shown))


def carve(ground, light):
    """Prints `light` (mid-grey means unchanged) onto ground."""
    return Image.merge("RGB", [ImageChops.multiply(band, light) for band in ground.split()])


def build_professions(stock):
    for name, (shade, rects, shown) in PROF_GROUNDS.items():
        sheet = load(ROOT / f"Professions/{name}.blp")
        for rect in rects:
            piece = sheet.crop(rect)
            size = piece.size
            # Forever's shading stays: the fold down the middle, the darker edges.
            light = piece.convert("L").filter(ImageFilter.GaussianBlur(7))
            mean = sum(v * n for v, n in enumerate(light.histogram())) / (size[0] * size[1])
            light = light.point(lambda v, m=max(mean, 1): min(255, round(255 * v / m / PROF_HEADROOM)))
            ground = shaded_ground(stock, size, shade, tuple(c * PROF_HEADROOM for c in shown))
            out = carve(ground, light).convert("RGBA")
            out.putalpha(piece.getchannel("A"))
            sheet.paste(out, rect[:2])
        save_blp(sheet, OUT / f"Professions/{name}.blp")

    for name, shade in PROF_DRAWINGS.items():
        sheet = load(ROOT / f"Professions/{name}.blp")
        # The drawing's lines, cut from its paper and carved into the same rock, so no paper box shows.
        grey = sheet.convert("L")
        paper = grey.filter(ImageFilter.GaussianBlur(40))
        light = Image.frombytes("L", grey.size, bytes(
            min(255, round(255 * g / max(p, 1) / PROF_HEADROOM)) for g, p in zip(grey.tobytes(), paper.tobytes())))
        ground = shaded_ground(stock, grey.size, shade, tuple(c * PROF_HEADROOM for c in (34, 34, 33)), soften=6)
        out = carve(ground, light).convert("RGBA")
        out.putalpha(sheet.getchannel("A"))
        save_blp(out.resize((512, 512), Image.LANCZOS), OUT / f"Professions/{name}.blp")

    fills = load(ROOT / "Professions/Fills.tga")
    bar = load(stock / "targetingframe/ui-statusbar.blp").convert("L")
    y = 1
    while y + 34 <= fills.height:
        rect = (1, y, 857, y + 34)
        row = fills.crop(rect)
        if row.getchannel("A").getextrema()[1]:
            rgb = row.convert("RGB").resize((1, 1), Image.BOX).getpixel((0, 0))
            peak = max(max(rgb), 1)
            colour = tuple(c / peak * 0.9 for c in rgb)
            base = bar.resize(row.size, Image.BILINEAR)
            bands = [base.point(lambda v, c=c: min(255, round(v * c))) for c in colour]
            fills.paste(Image.merge("RGBA", bands + [row.getchannel("A")]), rect[:2])
        y += 36
    save_tga(fills, OUT / "Professions/Fills.tga")


def build_collections(stock):
    rows = load(ROOT / "Collections/ListButtons.blp")
    box = (1, 1, 210, 47)
    grey = rows.crop(box)
    value = grey.convert("L")
    rows.paste(Image.merge("RGBA", (value, value, value, grey.getchannel("A"))), box[:2])
    save_blp(rows, OUT / "Collections/ListButtons.blp")

    ground = scale_to_mean(dark_stone(stock, (512, 512)), (24, 24, 23))
    save_blp(ground, OUT / "Collections/MountJournal-BG.blp", alpha=False)

    # GOLD_ICON_FRAME (utils/iconframe.lua): an opening 0.4922 of the sheet, centred at 0.4727, 0.4336.
    frame = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    edge = slot_edge(stock, "buttons/ui-emptyslot.blp", (9, 9, 54, 54), 4)
    per = 63 / 37
    size = round(45 * per)
    frame.paste(edge.resize((size, size), Image.LANCZOS), (round(60.5 - size / 2), round(55.5 - size / 2)))
    save_tga(frame, OUT / "Collections/IconFrameGold.tga")


def build_windows(stock):
    build_talent_grounds(stock)
    build_talent_nodes(stock)
    build_spellbook(stock)
    build_professions(stock)
    build_collections(stock)


def check():
    """Every baked sheet must keep its Forever sheet's size, or the shared texcoords land elsewhere."""
    pairs = {name: source for source, name in SILVER_SHEETS}
    pairs.update({"chrome-frame.tga": "ForeverUI/chrome-frame.tga", "chrome-buttons.tga": "ForeverUI/chrome-buttons.tga",
                  "ProfessionsUI.tga": "Professions/ProfessionsUI.tga", "redbutton2x.tga": "UI/redbutton2x.blp",
                  "redbutton3slice.tga": "UI/redbutton3slice.tga", "uiframetabs.tga": "UI/uiframetabs.blp",
                  "ui-background-rock.blp": "UI/ui-background-rock.blp",
                  "ui-background-marble.blp": "UI/ui-background-marble.blp"})
    for name in UF_SHEETS:
        pairs[f"UnitFrames/{Path(name).stem}.tga"] = f"UnitFrames/Forever/{name}"
    pairs["UnitFrames/pvpforever.tga"] = "UnitFrames/pvpforever.blp"
    for name in ("forever_circle", "uiminimapborder", "forever_pointer", "forever_square_frame",
                 "forever_square_frame_rounded", "forever_square_pointer", "uiminimapsquareborder"):
        pairs[f"Minimap/{name}.tga"] = f"Minimap/{name}.tga"
    pairs["Castbar/uicastingbar2x.tga"] = "Castbar/uicastingbar2x.tga"
    for name in ("uiactionbar2x_", "uiactionbar2x_new", "uiactionbar2x_flying", "uiactionbar2x_forever"):
        pairs[f"ActionBars/{name}.tga"] = f"ActionBars/{name}.blp"
    pairs["ActionBars/uiactionbariconframe.tga"] = "ActionBars/uiactionbariconframe.tga"
    for name in ("Background", "Background_r", "Overlay", "Overlay_r"):
        pairs[f"XP/{name}.tga"] = f"XP/{name}.tga"
    pairs["XP/uiexperiencebar.tga"] = "XP/uiexperiencebar.blp"
    pairs["Micromenu/uimicromenu2x.tga"] = "Micromenu/uimicromenu2x.blp"
    pairs["Micromenu/MicroButton.tga"] = "Professions/MicroButton.tga"
    pairs["Micromenu/micropvp.tga"] = "Micromenu/micropvp.blp"
    pairs["Talents/talents-sheet.tga"] = "Talents/talents-sheet.tga"
    pairs["Talents/talentframeatlas.tga"] = "Talents/talentframeatlas.blp"
    for name in ("spellbook-background.blp", "spellbook-background_r.blp", "spellbook-ribbon.tga", "spellbookelements.blp"):
        pairs[f"Spellbook/{name}"] = f"Spellbook/{name}"
    for name in PROF_GROUNDS:
        pairs[f"Professions/{name}.blp"] = f"Professions/{name}.blp"
    pairs["Professions/Fills.tga"] = "Professions/Fills.tga"
    pairs["Collections/ListButtons.blp"] = "Collections/ListButtons.blp"
    pairs["Collections/MountJournal-BG.blp"] = "Collections/MountJournal-BG.blp"
    pairs["Collections/IconFrameGold.tga"] = "Collections/IconFrameGold.tga"
    # Lower-resolution sheets draw fine under the same texcoords as long as the proportions hold.
    scaled = {f"Professions/{name}.blp": f"Professions/{name}.blp" for name in PROF_DRAWINGS}
    for klass in TALENT_TREES:
        for half in ("", "_r"):
            scaled[f"Talents/{klass}{half}.blp"] = f"Talents/talents-bg-{klass}{half}.blp"
    for kind in ("Cunning", "Ferocity", "Tenacity"):
        for half in ("", "_r"):
            scaled[f"Talents/Pet_{kind}{half}.blp"] = f"Talents/Pet_{kind}{half}.blp"
    for half in ("", "_r"):
        scaled[f"Talents/glyph-ground{half}.blp"] = f"Talents/Artifact/Warrior{half}.blp"
    ok = True
    for name, source in sorted(scaled.items()):
        ours, theirs = load(OUT / name).size, load(ROOT / source).size
        if ours[0] * theirs[1] != ours[1] * theirs[0]:
            print(f"{name}: {ours}, {source} is {theirs}")
            ok = False
    for name, source in sorted(pairs.items()):
        ours, theirs = load(OUT / name).size, load(ROOT / source).size
        if ours != theirs:
            print(f"{name}: {ours}, {source} is {theirs}")
            ok = False
    # Shapes the client has shown wrong: a tab's middle must fill its row, the page corner must be gone.
    tabs = load(OUT / "uiframetabs.tga")
    for y in (20, 60):
        if tabs.crop((0, y, tabs.width, y + 1)).getchannel("A").getextrema()[0] == 0:
            print(f"uiframetabs.tga: row {y} has clear texels in the tab's middle")
            ok = False
    if load(OUT / "Spellbook/spellbookelements.blp").crop(SPELLBOOK_CORNER).getchannel("A").getextrema()[1]:
        print("spellbookelements.blp: Forever's page corner is still there")
        ok = False
    print("classic skin sheets:", "ok" if ok else "SIZE MISMATCH")
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        sys.exit(0 if check() else 1)
    if not args.stock:
        parser.error("--stock DIR is required to bake")
    build_frame(args.stock)
    build_grounds()
    build_buttons(args.stock)
    build_tabs(args.stock)
    build_ring(args.stock)
    build_silver()
    build_unit_frames(args.stock)
    build_minimap(args.stock)
    build_castbar(args.stock)
    build_action_bars(args.stock)
    build_xp()
    build_micro(args.stock)
    build_windows(args.stock)
    check()


if __name__ == "__main__":
    main()
