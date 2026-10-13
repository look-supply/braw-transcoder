# Saving a clip's embedded LUT

File → Save Embedded LUT… saves the current preview clip's original embedded
LUT as a `.cube` file. The native save dialog suggests the embedded LUT's name
(or the clip name) and confirms replacement of an existing file. The command is
disabled without a selected clip containing an embedded LUT, during importing
or video export, and while another LUT save is in progress.

The decoder worker obtains `IBlackmagicRawPost3DLUT` using
`GetEmbeddedPost3DLUT`, then uses the SDK's `WriteCubeFile`. It explicitly selects
the embedded LUT rather than a sidecar override or the active post-processing
LUT. The worker returns cube bytes to the bridge, which writes the chosen
destination atomically. Temporary worker files are removed. No camera LUT,
exposure, gamut, or tone adjustments are incorporated in the saved LUT, and
the source BRAW is unchanged. Saving directly over the source file is rejected.
Native clip work runs on its existing serial queue, keeping the UI responsive.

The regression test parses the SDK sample's 33×33×33 cube, verifies exactly one
RGB triplet per grid entry, finite values, identical output with preview settings
changed and after decoder release/reopen, replacement, and write-error handling.
The same checks pass on A005_07092109_C001.braw's 17×17×17 embedded LUT.
