"""Finder presentation for the direct-download Voxley installer."""
from pathlib import Path

app = Path(defines["app"]).resolve()
if not app.is_dir() or app.name != "Voxley.app":
    raise ValueError("The installer requires an existing Voxley.app bundle")

format = "UDZO"
filesystem = "HFS+"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
# The background is inside the signed app's Resources. No stray background file
# appears at the disk root, even when Finder's Show Hidden Files is enabled.
background = None
window_rect = ((160, 160), (720, 520))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
icon_size = 104
text_size = 15
label_pos = "bottom"
show_icon_preview = False
icon_locations = {"Voxley.app": (195, 230), "Applications": (525, 230)}
# Do not set FinderInfo on a signed bundle: codesign rejects that added xattr.
hide_extensions = []
