# Multichannel audio export

Export reads sample rate, channel count, bit depth and sample count from each source clip through the Blackmagic RAW SDK. Audio is extracted in bounded interleaved chunks, retaining source channel order. There is no fixed stereo or four-channel cap.

The encoder reads that PCM with the source channel count and sample rate and copies it into the MOV audio track, preserving its original 16-, 24- or 32-bit depth. Channel-layout guessing is disabled because discrete camera inputs are not necessarily surround speakers. This shared path applies to H.264, HEVC and ProRes. The output is one multichannel audio track, with no downmix or audio compression.

Regression checks round-trip 1, 2, 4, 8 and 16 channels at all three supported PCM bit depths through MOV, checking format and exact sample bytes. A real BRAW SDK sample also undergoes export with each video codec and byte-for-byte comparison against the SDK audio. Four-channel BRAW capture itself remains to be verified with a recording when available.
