# Gyro data in transcoded MOVs and DaVinci Resolve

Research date: October 12, 2026.

## Conclusion

There is no documented or demonstrated working route found in this research for enabling Resolve’s native Camera Gyro stabilizer on our transcoded ProRes/HEVC MOVs by copying BRAW metadata. This is a compatibility finding, not proof that an undocumented metadata-track transplant is impossible. Motion data can be stored in MOV, and a Gyroflow-based workflow inside Resolve is credible. Embedded CAMM motion tracks are a candidate for a single-file implementation; GCSV sidecars are a simpler documented interchange route. Neither has been implemented or validated in this app.

## Evidence

### Current Resolve manual

The installed September 2026 Resolve 21.1 reference manual was searched through all 4,351 pages using PDFKit. Chapter 152, page 3503, describes Camera Gyro for footage from a Blackmagic Cinema Camera with a gyro. No general-purpose MOV gyro import format or external gyro log input for that mode was found.

Chapter 200, page 4283, separately documents Apple Immersive Motion Data, displaying acceleration and gyro graphs for immersive clips. Thus it would be inaccurate to say Resolve cannot read motion data outside its ordinary BRAW stabilization workflow. This feature does not establish native gyro stabilization for ordinary ProRes/HEVC exports.

Local primary source: `/Applications/DaVinci Resolve/DaVinci Resolve Manual.pdf`.

### Motion data is a timed stream

Gyroflow’s telemetry parser reads BRAW metadata-track samples containing `mogy` and `moac` packets. It also uses frame timing, rolling-shutter readout, sensor geometry and lens information. Copying ordinary camera/white-balance/color-space tags does not preserve this time series. The parser adjusts BRAW gyro timing by half the sensor readout time, demonstrating why timestamps require careful validation.

Primary implementation: https://github.com/AdrianEddy/telemetry-parser/blob/master/src/blackmagic/mod.rs

The BRAW SDK exposes motion sample count, rate and ranges through the gyroscope and accelerometer interfaces. It does not provide a public MOV writer or a documented Resolve-native motion-data injection interface. Our existing extraction helper is not connected to the IPC/export path and derives timestamps from sample index/rate; it is not yet a validated motion exporter.

SDK reference: https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicRAW-SDK.pdf

### Inspection of local recordings

Read-only QuickTime atom inspection of `A001_07181332_C129.braw` found video, timecode, audio, and two `meta`/`mebx` tracks, each containing 9,152 samples. Together with the parser implementation, these are consistent with gyro and accelerometer tracks; their payloads were not independently decoded during this inspection.

The original Blackmagic Camera iPhone MOV `B003_09291412_C143.mov`, previously used to investigate color tagging, contained only HEVC video, AAC audio and timecode tracks. It is not a reference file demonstrating embedded gyro support.

### Established Resolve plug-in route

Gyroflow’s OpenFX plug-in processes video inside Resolve using a source file or a `.gyroflow` project with motion data and settings. Its documentation explains lens calibration, input rotation and anamorphic stretching. This is a separate stabilizer from Resolve’s built-in Camera Gyro mode.

Primary documentation: https://docs.gyroflow.xyz/app/video-editor-plugins/davinci-resolve-openfx

GCSV is a documented gyro sidecar format, with timestamps, units, orientation and optional lens/readout fields. It supports companion-file detection. Accurate video/motion synchronization still needs validation.

Format: https://docs.gyroflow.xyz/app/technical-details/gcsv-format

### Candidate single-file route

Google’s CAMM specification defines timed motion samples, including gyro and acceleration, with explicit coordinate and timing requirements. Gyroflow’s CAMM parser lists both `.mp4` and `.mov` extensions and decodes those samples. Therefore a MOV carrying a CAMM track is a technically supported input category for Gyroflow, although our proposed BRAW-to-CAMM conversion has not been built or tested.

Specification: https://developers.google.com/streetview/publish/camm-spec

Parser: https://github.com/AdrianEddy/telemetry-parser/blob/master/src/camm/mod.rs

There is no evidence found that Resolve’s native Camera Gyro stabilizer accepts CAMM. Its support in Gyroflow is not evidence of native Resolve support.

## Implementation implications

For a reliable first feature, use an explicitly named Gyroflow motion export, initially a GCSV/project workflow. An embedded CAMM track could follow after a synchronization and lens-calibration prototype. Preserve sample timing, axis conventions, sensor crop/readout, and relevant lens information. Coordinate desqueeze, rotation, mirroring and distortion correction with the stabilization geometry; do not attach unchanged motion/profile data to transformed pixels and assume compatibility.

Native Resolve support should remain an experiment. A controlled test would compare original gyro-bearing BRAW against an unchanged-geometry MOV carrying transplanted BRAW motion tracks and required metadata, then inspect Camera Gyro availability and stabilization. A CAMM MOV should be tested separately in Gyroflow. No such import experiment was performed here.

## Search scope and limitations

Research included Blackmagic documentation and support pages, the installed Resolve manual and developer interfaces, Blackmagic forum discussions, firsthand user reports, Gyroflow documentation/source and the CAMM standard. Community reports of unsuccessful metadata transfers and vendor-specific gyro support were treated as corroboration, not as authoritative proof. Broad web claims about arbitrary iPhone orientation tags enabling native Resolve gyro stabilization were not supported by the primary sources checked.
