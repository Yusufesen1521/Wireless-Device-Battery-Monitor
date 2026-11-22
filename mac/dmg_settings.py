# dmgbuild settings for the BatteryHub disk image (mac/Makefile.mac, `dmg` target).
# The window shows BatteryHub on the left, an arrow, and the Applications folder on the right, over
# mac/dmg-background.tiff. Icon positions must match mac/make_dmg_background.swift.
#
# dmgbuild writes the window layout (.DS_Store) itself, so this works without a logged-in Finder,
# e.g. on GitHub's macOS runners.

import os.path

app = defines.get("app", "BatteryHub.app")  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon", "mac/AppIcon.icns")  # noqa: F821  (volume icon in Finder and on the desktop)
background = defines.get("background", "mac/dmg-background.tiff")  # noqa: F821

# Window: no toolbar or sidebar. The background is 640 x 420; the window is taller because recent
# Finder versions draw a tab bar above the content (about 68 pt) even with the toolbar hidden. On older
# macOS the extra space is a thin strip below the background, in the same near-white colour.
window_rect = ((200, 120), (640, 490))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (160, 190),
    "Applications": (480, 190),
}
