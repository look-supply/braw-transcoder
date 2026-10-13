#!/usr/bin/env python3
"""Check fresh automatic assignments in a temporary Resolve-managed project."""
import argparse
import json
from pathlib import Path
import sys
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("clips", nargs="+", type=Path)
    parser.add_argument("--expected-input", default="Blackmagic Design Film Gen 5")
    parser.add_argument("--expected-gamma", default="Blackmagic Design Film Gen 5")
    parser.add_argument("--recording-reference", type=Path, help="Compare MOV camera metadata and timecode with this BRAW")
    args = parser.parse_args()
    for path in args.clips:
        if not path.is_file():
            parser.error(f"Missing clip: {path}")
    sys.path.insert(0, "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
    import DaVinciResolveScript
    resolve = DaVinciResolveScript.scriptapp("Resolve")
    if not resolve:
        raise RuntimeError("Open Resolve and enable local external scripting before running this check")
    manager = resolve.GetProjectManager()
    original = manager.GetCurrentProject()
    if not original:
        raise RuntimeError("Open a project first so it can be restored after the check")
    original_name = original.GetName()
    if not manager.SaveProject():
        raise RuntimeError("Cannot preserve current project before switching")
    test_name = "BRAW automatic detection check " + uuid.uuid4().hex[:12]
    project = None
    try:
        project = manager.CreateProject(test_name)
        if not project:
            raise RuntimeError("Cannot create the temporary test project")
        if not project.SetSettings({
            "colorScienceMode": "davinciYRGBColorManagedv2",
            "colorSpaceInput": "Rec.709 (Scene)",
            "colorSpaceTimeline": "DaVinci WG/Intermediate",
            "isAutoColorManage": "0",
        }):
            raise RuntimeError("Cannot configure the temporary test project")
        reference_metadata = None
        reference_tc = None
        if args.recording_reference:
            refs = project.GetMediaPool().ImportMedia([str(args.recording_reference.resolve())])
            if not refs:
                raise RuntimeError("Cannot import BRAW recording reference")
            reference_metadata = refs[0].GetMetadata()
            reference_tc = refs[0].GetClipProperty("Start TC")
        failures = []
        for path in args.clips:
            clips = project.GetMediaPool().ImportMedia([str(path.resolve())])
            if not clips:
                raise RuntimeError(f"Resolve could not import {path}")
            for clip in clips:
                props = clip.GetClipProperty()
                actual = (props.get("Input Color Space"), props.get("Input Gamma"))
                print(json.dumps({"file": path.name, "input": actual[0], "gamma": actual[1], "metadata": clip.GetMetadata(), "start_tc": props.get("Start TC")}))
                if reference_metadata is not None:
                    recording = clip.GetMetadata()
                    for field in (
                        "Camera #", "Camera Aperture", "Camera FPS", "Camera Firmware",
                        "Camera ID", "Camera Manufacturer", "Camera Type", "Clip Number",
                        "Date Recorded", "Day / Night", "Distance", "Environment",
                        "Focal Point (mm)", "ISO", "Lens Type", "ND Filter", "Reel Number",
                        "Scene", "Shot Type", "Shutter Angle", "Shutter Type", "Take",
                        "White Balance Tint", "White Point (Kelvin)", "Production Name",
                    ):
                        expected = reference_metadata.get(field)
                        if not expected:
                            continue
                        observed = recording.get(field)
                        if field == "Date Recorded":
                            expected = expected.replace(":", "-")
                        if field in ("Camera FPS", "ND Filter") and observed is not None:
                            matches = abs(float(expected) - float(observed)) < 0.001
                        else:
                            matches = observed == expected
                        if not matches:
                            failures.append(f"{path.name}: {field} expected {expected!r}, got {observed!r}")
                    if props.get("Start TC") != reference_tc:
                        failures.append(f"{path.name}: original timecode changed")
                if actual != (args.expected_input, args.expected_gamma):
                    failures.append(path.name)
        if failures:
            raise RuntimeError("Automatic assignment failed: " + ", ".join(failures))
    finally:
        if not manager.LoadProject(original_name):
            raise RuntimeError("Could not restore the original Resolve project")
        if project and not manager.DeleteProject(test_name):
            print(f"Temporary test project retained: {test_name}", file=sys.stderr)


if __name__ == "__main__":
    main()
