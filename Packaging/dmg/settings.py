# dmgbuild settings for the installer DMG; used by Scripts/make-dmg.sh.
#
# Icon positions are icon centers in points from the top left of the window.
# Scripts/dmg-background.swift draws the background for these positions.
import os.path

application = defines["app"]

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

# background.png; dmgbuild adds background@2x.png for Retina displays.
background = defines["background"]
# 400 points of background below the title bar (32 points on macOS 26).
window_rect = ((200, 140), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {
    os.path.basename(application): (170, 200),
    "Applications": (490, 200),
}
