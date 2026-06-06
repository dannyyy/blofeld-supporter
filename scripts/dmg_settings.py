# dmgbuild settings for the Blofeld installer DMG.
# Invoked by scripts/make-dmg.sh:
#   dmgbuild -s scripts/dmg_settings.py "<volume name>" <out.dmg>
# Inputs come from the environment so the layout stays in one place.
# Layout constants mirror scripts/make_dmg_background.swift -- keep in sync.

import os

application = os.environ["DMG_APP"]
appname = os.path.basename(application)

# --- volume ---
format = "UDZO"                 # compressed, read-only
files = [application]
symlinks = {"Applications": "/Applications"}
badge_icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

# --- window / icon view ---
background = os.environ["DMG_BACKGROUND"]
window_rect = ((220, 120), (620, 420))   # ((x, y), (content w, h)) -- matches the background
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    appname: (168, 270),
    "Applications": (452, 270),
}
