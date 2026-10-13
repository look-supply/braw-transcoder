# Third-party components

## FFmpeg

`ffmpeg/ffmpeg` is the tracked macOS arm64 encoder executable. CMake copies it into the app bundle and beside the integration tests. Removing it breaks the current packaging and export checks.

The executable reports FFmpeg 8.1 and a build with `--enable-gpl`, `libx264`, and `libx265`. Its `-L` output identifies GPL version 2 or later. Its download origin and matching source package are not recorded in this repository. Release packaging still needs verified binary provenance, the applicable license notices, and corresponding source distribution information; this file does not supply those missing materials.

## Blackmagic RAW SDK

The decoder uses the separately installed Blackmagic RAW SDK 6.0. CMake obtains the headers, dispatch implementation, and framework from `BRAW_SDK_ROOT`. The SDK framework is not stored in this repository. SDK distribution terms must be handled as part of installer packaging if it is bundled in a future release.

The project's own source code is distributed under the [GNU Affero General Public License version 3](../LICENSE). Third-party components retain their applicable licenses.
