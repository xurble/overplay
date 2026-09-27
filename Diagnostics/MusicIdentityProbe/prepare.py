"""Prepare a standalone probe project; never copy Overplay's app/runtime code."""

from pathlib import Path
import plistlib
import shutil
import tempfile


repo = Path(__file__).resolve().parents[2]
destination = Path(tempfile.mkdtemp(prefix="overplay-identity-probe-"))
project = destination / "Overplay.xcodeproj"
project.mkdir()
shutil.copy2(repo / "Overplay.xcodeproj/project.pbxproj", project / "project.pbxproj")
shutil.copytree(repo / "Overplay.xcodeproj/xcshareddata", project / "xcshareddata")
shutil.copytree(repo / "Config", destination / "Config")
source = destination / "Overplay"
source.mkdir()
(destination / "OverplayTests").mkdir()
shutil.copy2(Path(__file__).with_name("IdentityProbeApp.swift"), source)
shutil.copy2(repo / "Overplay/Services/MusicLibrarySongResolver.swift", source)
shutil.copy2(repo / "Overplay/Overplay.entitlements", source)
for name in ["AGENTS.md", "TODO.md", "OVERPLAY_DESIGN_SPEC.md"]:
    (destination / name).write_text("Standalone read-only identity probe.\n")

info_path = destination / "Config/Info.plist"
info = plistlib.loads(info_path.read_bytes())
for key in ["UIApplicationSceneManifest", "BGTaskSchedulerPermittedIdentifiers",
            "UIBackgroundModes", "OverplayCloudKitContainerIdentifier"]:
    info.pop(key, None)
info["NSAppleMusicUsageDescription"] = "Read-only identity diagnostic; no music or app data is changed."
info_path.write_bytes(plistlib.dumps(info))

project_path = project / "project.pbxproj"
project_text = project_path.read_text().replace(
    "INFOPLIST_KEY_CFBundleDisplayName = Overplay;",
    'INFOPLIST_KEY_CFBundleDisplayName = "Overplay Identity Probe";',
)
project_path.write_text(project_text)
print(project)
