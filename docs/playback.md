# Clip playback

Mouse-wheel scrolling over the preview zooms in/out; scrolling over the sidebar,
inspector or timeline retains its usual behavior. Command + / − also zoom, and
Z resets to fit. Keyboard zoom shortcuts preserve text-field input. Zoom controls
sit at the right of the clip-title pane, before the monitoring controls. Zoom
is per clip, centered, and bounded from 0.25× to 8× fit size. Metal playback samples
the original texture at the zoomed coordinates, preserving detail without
allocating enlarged drawable surfaces. Paused still previews use the same scale.

Play/Pause is at the far left of the playback bar. Controls at the right end of
the scrubber are Previous Clip, Reverse Play/Pause, Stop, Next Clip, and Loop Clip.
Every icon has a hover tooltip. Stop pauses and rewinds to
frame zero. Previous/Next preserve playback when already playing. Space toggles
the current playback direction and continues to insert text while editing a field.

Loop Clip is red when enabled and repeats the current clip. When disabled,
forward playback automatically continues to the next clip, and reverse playback
continues to the previous clip. Playback stops at the end of the list in either
direction. Single-frame clips are included when advancing. The loop setting is
also available in the Playback menu and is remembered across restarts.
Scrubbing, switching clips, changing adjustments or monitoring modes, starting
an export, and leaving the application pause playback.

The existing isolated SDK worker selects the Metal decode pipeline by default,
with its existing CPU fallback. A MetalKit view presents playback BGRA frames
directly as textures; three GPU submissions at most can be in flight. If Metal
presentation cannot initialize, the view falls back to native image display.
The existing worker IPC still copies decoded pixels through CPU memory. The
native bridge transfers ownership of immutable frame buffers to Swift without
copying them again. This removes additional full-frame copies without changing
the isolated-worker boundary. Three reusable display textures are released for
reuse only when their GPU submissions complete. The SDK chooses its default CPU
thread count for decompression feeding Metal, rather than being capped at four.

Playback defaults to full resolution. Playback > Resolution offers Full, 1/2,
1/4, and 1/8, and saves the choice across application restarts. Changing it during
playback restarts decoding at the displayed frame using the selected scale.
Pausing and seeking always restore the native-resolution still preview.
Playback analyzes waveforms up to five times
per second when the waveform is visible. False color uses the same encoded
signal and palette as paused monitoring.

Audio streams signed 16/24/32-bit PCM in bounded chunks of at most 65536 sample
frames through AVAudioEngine. About one second is buffered rather than loading
an entire recording. The audio player's presentation clock drives video frame
selection; silent sources use monotonic elapsed time. A bounded three-frame
read-ahead queue separates sequential decoding from timed presentation, with at
most one additional decode in progress. The queue is prefilled before audio and
video start together. Reverse playback reads source frames in descending order
and reverses PCM sample frames while preserving channel order. Late video frames are skipped to
retain source speed and audio synchronization. Audio underruns and audio-device
changes pause playback with a retry message.

## Verification

`braw_playback_test` checks fractional frame rates, PCM signed conversion, and
Metal pixel orientation. The SDK's one-frame sample checks single-frame playback.
Passing a multi-frame recording also checks continuous playback, audio clock
alignment, native-resolution pause, resume, seeks, adjustments, clip changes,
export suspension, looping, reverse audio/video, clip advancement and list
boundaries. An optional second argument sets the
sustained playback check duration in seconds.

With full-resolution playback on the local 6144×3456, 24 FPS multi-frame fixture,
an eight-second run of the complete app window observed 192 frame updates, 193
Metal draw submissions, zero observed skipped frames, and maximum audio/video
difference below 53 ms. Application memory grew by 81 MiB during the interval. The
test also checks immutable frame lifetime across decoder teardown and bounded
application memory. These measurements describe this fixture and machine; camera
format, processing settings, storage, and hardware affect throughput.
