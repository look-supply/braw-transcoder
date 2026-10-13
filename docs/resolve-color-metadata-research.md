# Resolve automatic MOV input-color recognition

Research date: 2026-10-10. Gen5 automatic recognition is verified in Resolve
21.1.0.17 for HEVC, H.264, and ProRes. Gen6 detection is deferred at the
user's request.

## Camera-name compatibility fix

The user's later native-resolution HEVC export `A001_07181332_C129.mov`
already had correctly placed metadata and the SDK's Film/Blackmagic Design
gamut/Gen5 values, but a fresh Resolve import still fell back to Project.
Its actual camera is **Blackmagic Cinema Camera 6K**, rather than the Pocket
Cinema Camera 6K Pro used in the first integration check.

Controlled metadata-only variants established that the failure follows the
camera name embedded in `com.blackmagic-design.camera.colorScience`.
Changing `cameraType` alone did not fix it. Keeping the actual cameraType
while selecting the recognized URSA Mini Pro 12K Gen5 color-science
descriptor did produce automatic Film Gen5 input color space and gamma.
This is a color-profile compatibility descriptor, not replacement of the
source camera identity.

Blackmagic's SDK technical reference defines a common Gen5 gamut and OETF;
its [Cinema Camera documentation](https://www.blackmagicdesign.com/ca/products/blackmagiccinemacamera)
states that the Cinema Camera 6K uses the same Gen5 color science as the
URSA Mini Pro 12K. Therefore confirmed SDK Film/Blackmagic Design/Gen5
exports now use `Blackmagic URSA Mini Pro 12K, Color Science Gen 5` as the
recognized profile descriptor. `cameraType` and the descriptive source
camera tag remain the real SDK-reported camera. Gen4 is camera-specific and
is not normalized to that Gen5 profile; Gen6 and custom gamma are not
mapped to Gen5.

A corrected `_color-tagged.mov` copy of the user's exact export was made
without re-encoding. Per-stream SHA256 packet hashes confirmed all 290
video packets and 376 audio packets were unchanged. The original MOV was
retained. New exports from 12-frame copies of both the full-frame source
and the Pocket source were checked independently through the actual
Metal/HEVC export path.

## Confirmed fix: QuickTime metadata placement

The Apple source uses `moov/meta`. FFmpeg's `+use_metadata_tags` writes
`moov/udta/meta`. Fresh Resolve imports ignored the Blackmagic Film keys at
the latter location, falling back to `Project` / `Gamma 2.4`. Moving the same
metadata directly under `moov` caused automatic assignment to **Blackmagic
Design Film Gen 5** for both Input Color Space and Input Gamma. No manual
input assignment was made. Both QuickTime-style and FullBox meta headers
worked at the corrected location; the implementation retains FFmpeg's
FullBox payload.

`QuickTimeMetadata.cpp` finalizes every completed temporary MOV by moving
metadata out of `udta` and directly under `moov`, before atomic publication.
It retains the `udta` header so the total moov size stays exact: all media
bytes, faststart layout, and chunk offsets remain unchanged. Only the bounded
moov index is read/written. Invalid or oversized indexes fail before
replacing the user's existing destination file.

The actual app export path was checked with fresh 12-frame HEVC, H.264,
and ProRes exports from the supplied Gen5 BRAW. Resolve assigned Film Gen5
color space and gamma automatically for all three. Five CTest checks pass,
including metadata placement, media/offset preservation, repeated
finalization, and failure safety. Reproduce the integration check with
`python3 scripts/check_resolve_color_detection.py <export.mov>` while
Resolve's local scripting connection is enabled. It preserves the current
project, creates a separate test project, then restores the original and
removes only its own test project.

Additional negative results: Blackmagic's `filmlog` identifier in the Apple
`logs` atom did not enable recognition. The Gen6 DWG/Intermediate fixture
remained undetected after metadata relocation. A DWG/Intermediate reference
MOV rendered by Resolve with Same as Project tags also fell back to Project
on fresh import. This change does not claim Gen6 automatic detection.

## Implementation and export verification

`ExportColorMetadata.h` selects Blackmagic's camera metadata keys for two
SDK-reported native encodings: Gen4/5 Blackmagic Design Film + Blackmagic
Design gamut, and Gen6 DaVinci Intermediate + DaVinci Wide Gamut. Camera
identity and generation are read from the export decoder. Other combinations
retain descriptive source tags without being identified as native Film.

The Gen6 pair was verified against SDK 6.0: setting Gen6 on cloned clip
processing attributes automatically selected DaVinci Intermediate and
DaVinci Wide Gamut. A 12-frame test BRAW made from the supplied Gen5 source
with those Gen6 processing attributes was then exported through the actual
Metal/HEVC path. It is a Gen6-processing fixture, not a claim that the
original recording was shot with Gen6.

Real HEVC exports of the Gen5 and Gen6-processing fixtures preserved their
distinct SDK gamut/gamma/generation values and wrote the camera type,
generation-qualified `colorScience`, and Blackmagic `filmlog` identifier.
The Custom/Gen4 SDK sample exported without the vendor Film marker. All four
CTest checks passed. The metadata helper rejects mismatched generation and
encoding pairs, absent camera identity, external-camera names, and custom
gamma. Export metadata tests do not establish Resolve's interpretation.

Initially the scripting connection was unavailable and Computer Use denied
access. The direct scripting connection subsequently became available and
enabled the controlled import tests above. No input color space was manually
assigned as a substitute for testing automatic detection.

## Findings from the supplied camera files

The original iPhone file `B003_09291412_C143.mov` is HEVC/hvc1, 3840×2160,
10-bit 4:2:2. Its video sample description contains:

| Field | Observed value |
| --- | --- |
| `colr` | `nclc`, primaries 2, transfer 2, matrix 9 |
| `logs` | `com.apple.apple-wide-gamut.apple-log` |
| CoreMedia `LogTransferFunction` | `com.apple.apple-wide-gamut.apple-log` |

The `logs` payload is the identifier string directly, with an 8-byte atom
header and a total atom length of 44 bytes. CoreMedia reads it as a log
transfer-function extension. Apple's CoreVideo headers identify this as
Apple Log 2 and prescribe unspecified/absent standard primaries and transfer
fields, with a BT.2020 YCbCr matrix. This matches the observed 2-2-9 `colr`.
Apple's documentation describes Apple Log 2 as Apple Gamut plus an Apple log
curve: [Apple Log 2 documentation](https://developer.apple.com/documentation/avfoundation/avcapturecolorspace/applelog2).

`ffprobe` 8.1.2 does not expose the log identifier. Our bundled FFmpeg also
loses it during video-only stream-copy remuxes, both with ordinary metadata
handling and with `-movflags +use_metadata_tags`. AVFoundation no longer
reports `LogTransferFunction` in either resulting test MOV. No pixels were
re-encoded. These tests used copies in `/private/tmp`; the original was
unchanged. Current upstream MOV reader/writer source searches also found no
`logs` handling: [reader](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/mov.c),
[writer](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c).

The SDK reports these processing attributes for the supplied long BRAW
`A003_08311600_C007.braw`:

| Attribute | Observed value |
| --- | --- |
| Gamma | Blackmagic Design Film |
| Gamut | Blackmagic Design |
| Color-science generation | 5 |
| Camera | Blackmagic Pocket Cinema Camera 6K Pro |

In contrast, the SDK's one-frame `sample.braw` reports Custom gamma and Gen4.
That fixture must not be treated as standard Blackmagic Film.

## Blackmagic Film recognition candidate

A firsthand examination of an original Pocket 4K Film ProRes file reports
these keys:

```text
com.apple.proapps.customgamma = com.blackmagic-design.camera.filmlog
com.blackmagic-design.camera.cameraType = Blackmagic Pocket Cinema Camera 4K
com.blackmagic-design.camera.colorScience = Blackmagic Pocket Cinema Camera 4K, Color Science Gen 4
```

Source: [Nick Shaw's camera-file inspection](https://community.acescentral.com/t/acescg-in-vfx-for-non-aces-shows-in-nuke-ocio-and-multiple-cameras/3139).
This is evidence of camera metadata, not a published guarantee of Resolve's
automatic assignment behavior.

A read-only string inspection of the installed Resolve executable found
all three keys/identifiers, plus both Apple Log identifiers. It also found
older Cinema Camera/Production Camera Film identifiers. This supports the
hypothesis that Resolve understands camera-specific metadata; executable
strings alone do not prove selection rules, precedence, container placement,
or behavior for every codec/generation.

Our existing `com.brawtranscoder.source.*` tags are descriptive values in
MOV metadata. They preserve the SDK values, but have no established meaning
to Resolve. The earlier inference that ordinary NCLC tags were the only
route to automatic assignment was too broad: the supplied file establishes
a separate log identifier inside its video sample description.

## Gen6 and correct tagging

Blackmagic RAW 6.0 officially supports Gen6. Blackmagic describes the Gen6
processing pipeline as redesigned around DaVinci Wide Gamut, and says Gen5
clips can be processed as Gen6 in Resolve. Sources:
[SDK release notes](https://www.blackmagicdesign.com/support),
[URSA Cine color science](https://www.blackmagicdesign.com/products/blackmagicursacine).
Generation is therefore not safely interchangeable with a fixed Gen5
gamut/gamma pair. The actual SDK processing output determines what tags
would truthfully describe exported pixels.

Do not copy an Apple Log identifier onto Blackmagic Film pixels. Do not map
all proprietary Film encodings to Rec.709 or Rec.2020 standard transfer
codes. Do not assume a new identifier such as `filmlog6` exists. A custom
gamma must remain custom unless its exact curve is established.

## Validation status and follow-up

1. Completed: generate short Film export fixtures with source-driven camera type and
   color-science generation, using the observed Blackmagic metadata keys.
   Keep the current descriptive source tags for auditability.
2. Completed for the supplied Gen5 clip and three codecs: import fixtures into a fresh Resolve Color Managed project with automatic
   input detection enabled. Record the assigned input color space before
   making any manual assignment; compare with the original BRAW. Test HEVC
   and ProRes separately. Project defaults/manual overrides can mask failure.
3. Gen6 detection is deferred at the user's request; custom-gamma guard tests pass. Only claim support for
   combinations that Resolve actually assigns correctly. Identify the
   decoded gamut/gamma from SDK attributes, including sidecar processing.
4. If a track-level `logs` identifier is needed for a verified encoding,
   implement/test sample-description writing explicitly or use a native
   media writer that preserves it. Adding `-metadata LogTransferFunction=…`
   to FFmpeg is not equivalent to writing a `logs` atom.

The Gen5 fix combines Blackmagic's vendor keys with the Apple-style metadata
location. The transcoder continues to work independently of Resolve; the
direct scripting connection is used only by the integration check.

## Recording metadata verification (2026-10-10)

The export now includes scalar clip metadata and the first frame's camera
metadata. The SDK iterator starts at its first key; calling Next before
GetKey had omitted manufacturer. Frame metadata supplies lens/aperture,
focal length, focus distance, shutter, and native white balance. MOV vendor
keys mirror the original Blackmagic Camera iPhone file, with additional
keys confirmed in Resolve's installed reader. Original scalar values are
also kept under `com.brawtranscoder.source.metadata.*`. Binary LUTs and
arrays are excluded; the camera LUT remains a preview setting.

Fresh SDK imports of 12-frame HEVC exports from A001_07181332_C129 and
A003_08311600_C007 were compared with their native BRAW metadata. Resolve
read camera identity/manufacturer/firmware, clip number, lens, aperture,
focal length, distance, ND, ISO, white balance/tint, shutter angle/type,
sensor FPS, date, camera number, reel, scene, take, day/night, environment,
shot type, and production name when present. Recording date is normalized
from YYYY:MM:DD to YYYY-MM-DD without inventing a time or timezone.
Original timecodes matched: 13:32:48:15 and 15:59:24:13. Both color space
and gamma still detected as Blackmagic Design Film Gen 5. No SetMetadata
or manual color assignment was used. The test project was deleted and the
previous user project restored.

A separate export with ISO 800, WB 5600 K, tint -3 was freshly imported;
Resolve reported those adjusted values. Original ISO 400, WB 4500 K and
tint 15 remain preserved in source metadata. Other fields vary by frame;
this export stores a first-frame snapshot, not timed camera telemetry.
Unsupported scalar fields are retained in the MOV, but Resolve's metadata
panel only exposes keys its reader recognizes. Specifically isGood is not
written as UTF-8 because Resolve interprets the character "0" as byte 48;
the original good_take value is preserved in the source namespace.
