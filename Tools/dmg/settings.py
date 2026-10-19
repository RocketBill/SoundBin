# Layout of SoundBin's disk image window, for dmgbuild. Tools/release.sh runs it from the repo root:
#   dmgbuild -s Tools/dmg/settings.py -D app=path/to/SoundBin.app SoundBin SoundBin.dmg
# The background is drawn by Tools/DMGBackground.swift, and its icon positions must match these.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
# The disk itself shows SoundBin's icon in Finder and on the desktop.
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

# dmgbuild pairs background.png with background@2x.png for Retina displays.
background = "Tools/dmg/background.png"
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (180, 170),
    "Applications": (460, 170),
}
