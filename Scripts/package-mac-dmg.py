#!/usr/bin/env python3
"""Build a Finder-styled DMG, then inspect its real mounted resources/layout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

from dmgbuild import build_dmg
from ds_store import DSStore
from mac_alias import Alias

ROOT = Path(__file__).resolve().parent.parent
BACKGROUND = Path("Contents/Resources/VoxleyInstallerBackground.tiff")


def bundle_inventory(app: Path) -> dict:
    inventory = {}
    for path in app.rglob("*"):
        name = str(path.relative_to(app))
        if path.is_symlink():
            inventory[name] = ("symlink", os.readlink(path))
        elif path.is_file():
            inventory[name] = ("file", path.stat().st_mode & 0o777,
                               hashlib.sha256(path.read_bytes()).hexdigest())
        elif path.is_dir():
            inventory[name] = ("directory", path.stat().st_mode & 0o777)
    return inventory


def install_background_reference(mount: Path) -> None:
    """Point Finder at signed bundle artwork without creating a root-level file."""
    with DSStore.open(str(mount / ".DS_Store"), "r+") as store:
        icons = store["."]["icvp"]
        icons["backgroundType"] = 2
        icons["backgroundImageAlias"] = Alias.for_file(str(mount / "Voxley.app" / BACKGROUND)).to_bytes()
        store["."]["icvp"] = icons


def verify(image: Path, source_app: Path) -> dict:
    attachment = subprocess.check_output([
        "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", str(image)
    ])
    volume = next(entry for entry in plistlib.loads(attachment)["system-entities"] if "mount-point" in entry)
    mount = Path(volume["mount-point"])
    try:
        assert (mount / "Voxley.app").is_dir(), "App missing from installer"
        assert os.readlink(mount / "Applications") == "/Applications"
        visible = {path.name for path in mount.iterdir() if not path.name.startswith(".")}
        assert visible == {"Voxley.app", "Applications"}, visible
        # Check Finder metadata in the final compressed image, not staging only.
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            window = store["."]["bwsp"]
            icons = store["."]["icvp"]
            locations = {name: tuple(store[name]["Iloc"])
                         for name in ("Voxley.app", "Applications")}
            assert store["."]["icvl"] == (b"type", b"icnv")
        assert window["WindowBounds"] == "{{160, 160}, {720, 520}}", window
        for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
            assert not window[key], (key, window)
        assert icons["arrangeBy"] == "none"
        assert icons["iconSize"] == 104
        assert icons["backgroundType"] == 2
        assert locations == {"Voxley.app": (195, 230), "Applications": (525, 230)}
        assert not any(path.name.startswith(".background") for path in mount.iterdir())
        background = mount / "Voxley.app" / BACKGROUND
        assert background.is_file(), "Retina background missing"
        assert background.read_bytes() == (ROOT / "Packaging/macOS/background.tiff").read_bytes()
        alias = Alias.from_bytes(icons["backgroundImageAlias"])
        assert alias.target.filename == background.name, alias.target.filename
        assert alias.target.posix_path.lstrip("/") == str(Path("Voxley.app") / BACKGROUND)
        # Compare links without following Sparkle framework directory aliases.
        assert bundle_inventory(source_app) == bundle_inventory(mount / "Voxley.app")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mount / "Voxley.app")], check=True)
        info = plistlib.loads((mount / "Voxley.app/Contents/Info.plist").read_bytes())
        assert info["CFBundleIdentifier"] == "com.protomota.voxley"
        sparkle = plistlib.loads((ROOT / "Scripts/Sparkle.plist").read_bytes())
        assert all(info[key] == value for key, value in sparkle.items())
        assert (mount / "Voxley.app/Contents/Frameworks/Sparkle.framework/Sparkle").is_file()
        return {"window_size": [720, 520], "icon_locations": locations,
                "icon_size": 104, "background": str(Path("Voxley.app") / BACKGROUND),
                "app_version": info.get("CFBundleShortVersionString"),
                "app_build": info.get("CFBundleVersion"),
                "app_bytes_match": True, "applications_target": "/Applications"}
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)


def main() -> None:
    if not __debug__:
        raise RuntimeError("Run without Python -O so installer verification is enabled")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    app, image = args.app.resolve(), args.output.resolve()
    if app.name != "Voxley.app" or not (app / "Contents/Info.plist").is_file():
        parser.error("--app must be an existing Voxley.app bundle")
    if not (app / BACKGROUND).is_file():
        parser.error("Embed Packaging/macOS/background.tiff in the app's Resources before signing")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if not args.verify_only:
        if image.exists():
            parser.error("--output already exists; choose a fresh output path")
        image.parent.mkdir(parents=True, exist_ok=True)
        mounted = {}

        def remember_mount(mount_point, options):
            mounted["path"] = Path(mount_point)

        def finish_layout(event):
            if event.get("type") == "operation::finished" and event.get("operation") == "dsstore::create":
                install_background_reference(mounted["path"])

        build_dmg(str(image), "Voxley", settings_file=str(ROOT / "Packaging/macOS/settings.py"),
                  defines={"app": str(app)},
                  settings={"create_hook": remember_mount}, callback=finish_layout)
    report = verify(image, app)
    image.with_suffix(".layout.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Installer layout verified:", json.dumps(report))


if __name__ == "__main__":
    main()
