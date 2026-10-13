# Inspector geometry and tone curves

The Inspector uses native SwiftUI DisclosureGroups. Sections can open independently;
the header menu expands or collapses all sections. RAW adjustments start expanded,
and Anamorphic, Tone curve, and Lens correction start collapsed. Expansion state
lasts for the current window session and is not saved across launches.

The top icon row rotates clockwise in 90-degree steps and toggles horizontal and
vertical flips. Flips apply relative to the displayed image after rotation. Native
switch toggles replace the adjustment checkboxes.

Anamorphic defaults to **As shot**, retaining the SDK's original clip geometry.
Off and explicit ratios use SDK geometry clones and their processing attributes,
so an override replaces the recorded setting rather than applying a second
desqueeze. The SDK preserves width and reduces height for these overrides.
Rotation and flips copy decoded pixels without interpolation. Preview, thumbnail,
waveform, resolution choices, and export dimensions use the resulting geometry.
Exports continue decoding full-resolution RGB16 before any output downsampling.

Custom desqueeze (mode 8) reveals a numeric ratio field accepting 1–4×, initially
2×. It starts with SDK geometry set to Off, replacing any recorded desqueeze.
High-quality vImage resampling preserves width and reduces height to the nearest
even pixel count; rotation and flips follow desqueeze. RGB16 exports resample
each channel as unsigned 16-bit data, preserving precision. Ratios that are
nonfinite or outside the range leave the previous setting unchanged. Copy/Paste,
Apply to All, Reset, output dimensions, and render metadata include the custom
ratio. Explanatory text beneath Inspector fields is removed; tooltips remain.
The ratio editor keeps a separate text draft so clearing the field and typing a
decimal such as `1.35` does not reformat partial input. Return or leaving the field
commits a valid ratio; a `:1` suffix explains the ratio notation.

Temperature, Tint, Exposure, and tone parameters share a numeric slider control.
The existing two-row layout is retained, with an editable numeric field and
per-field reset icon in the label row and a full-width slider below. Clicking the
field selects its text; horizontal dragging adjusts the value, with Option for
finer control and a left/right cursor outside text editing. Text commits on Return
or focus loss. Values are rounded to each parameter's precision and clamped to its
range; invalid text restores the last valid value. Reset uses as-shot white
balance/tint, zero exposure, or the SDK's native tone default. Anamorphic input
keeps its separate draft-based editor. The native-control regression test covers
character-by-character input, dragging, fine dragging, limits, reset, disabled
fields, and a 250-point-wide layout.
Numeric fields track hover explicitly: idle hover and scrubbing show the east/west
cursor, while active text editing uses the I-beam. A window-scoped outside-click
monitor commits and dismisses the field editor before the clicked target handles
the event, including buttons and blank space that normally leave macOS text focus
unchanged. The monitor returns the original event and is removed with the control.
Idle fields are noneditable until a click completes without dragging. A new left
mouse-down dismisses any existing editor before hit testing, so dragging an
already-focused number also scrubs instead of selecting text. The cursor is a
custom black double-headed horizontal arrow with a white outline. Regression
checks dispatch mouse events through the window, covering both focused-field
drags and click-to-edit selection of the entire number.

Custom tone curves start disabled. Supported Blackmagic gamma/gamut combinations
use the SDK's source-generation defaults and writable parameter ranges. Controls
cover contrast, saturation, midpoint, highlight and shadow rolloff, black and white
levels, and video black level where supported. Source Custom gamma parameters are
read from the clip. Turning the option off restores source gamma processing.
Enabled curves render as Blackmagic Design Custom gamma and are labeled accordingly
in export metadata; they are not mislabeled as Film for automatic Resolve assignment.
The original BRAW is never modified.

Copy/Paste and Apply to All include geometry and tone settings. Unsupported tone
curves are disabled on destination clips, with destination defaults retained.
Reset restores As shot geometry, no rotation/flips, and a disabled custom curve.
Lens corrections remain disabled initially, including on supported clips.

Validation includes all rotation/flip combinations on a non-square pixel fixture,
SDK BGRA and RGB16 geometry/tone/reset checks, encoded HEVC and ProRes output
dimensions, unsupported-gamma handling, and Swift model Copy/Paste, Apply to All,
Reset, and thumbnail updates. Full-resolution frame checks also pass on the
Cinema Camera 6K A001_07181332_C129 clip. These are frame and short-export checks,
not a completed long-clip endurance export.
Custom-ratio checks cover 1×, 1.25×, 2.4×, and 4× in BGRA8 and RGB16, rotated
dimensions, invalid-input rejection, constant-channel 16-bit precision, and
HEVC/ProRes exports at 2.4×.
