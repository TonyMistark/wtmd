"""Write DMG window layout (.DS_Store) directly, no Finder automation needed.

Same record set dmgbuild writes: bwsp (window bounds), icvp (icon view
options incl. the background image alias), icvl (icon view), and per-item
Iloc positions. Coordinates are icon top-left corners, matching the
design-space constants in Assets/gen_dmg_background.swift and make-dmg.sh.

Run:  python write_dmg_layout.py /Volumes/wtmd
"""

import sys

from ds_store import DSStore
from mac_alias import Alias

mount = sys.argv[1]

ICON_SIZE = 128
APP_CENTER = (170, 200)      # must match DMG_APP_CENTER_X / DMG_ICON_ROW_Y
APPS_CENTER = (490, 200)     # must match DMG_APPS_CENTER_X / DMG_ICON_ROW_Y
WINDOW = (660, 488)          # content 660x440 + title bar 28

alias = Alias.for_file(f"{mount}/.background/dmg-background.tiff")

bwsp = {
    "ShowStatusBar": False,
    "WindowBounds": f"{{{{200, 200}}, {{{WINDOW[0]}, {WINDOW[1]}}}}}",
    "ContainerShowSidebar": False,
    "PreviewPaneVisibility": False,
    "SidebarWidth": 0,
    "ShowTabView": False,
    "ShowToolbar": False,
    "ShowPathbar": False,
    "ShowSidebar": False,
}

icvp = {
    "viewOptionsVersion": 1,
    "backgroundType": 2,
    "backgroundColorRed": 1.0,
    "backgroundColorGreen": 1.0,
    "backgroundColorBlue": 1.0,
    "backgroundImageAlias": alias.to_bytes(),
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "arrangeBy": "none",
    "showIconPreview": False,
    "showItemInfo": False,
    "labelOnBottom": True,
    "textSize": 13.0,
    "iconSize": float(ICON_SIZE),
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
}

half = ICON_SIZE // 2
locations = {
    "wtmd.app": (APP_CENTER[0] - half, APP_CENTER[1] - half),
    "Applications": (APPS_CENTER[0] - half, APPS_CENTER[1] - half),
}

with DSStore.open(f"{mount}/.DS_Store", "w+") as d:
    d["."]["vSrn"] = ("long", 1)
    d["."]["bwsp"] = bwsp
    d["."]["icvp"] = icvp
    d["."]["icvl"] = ("type", "icnv")
    for name, pos in locations.items():
        d[name]["Iloc"] = pos

print(f"layout written to {mount}/.DS_Store")
