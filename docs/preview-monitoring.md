# Preview monitoring and waveform visibility

The preview header puts rendered dimensions and frame rate beside the filename. A small native segmented control selects Preview embedded LUT or Log. A separate native push-on/push-off “False color” button sits 8 points to its right. At narrow widths, the header wraps onto two rows rather than clipping its controls.

The main preview now decodes at full native resolution (`scale = 1`), including LUT, Log, waveform and false-color input. It remains a BGRA8 display buffer; exports retain RGB16 processing. Sidebar thumbnails continue to use their separate reduced decode.

False color is off by default and independent of the LUT/Log selection. Switching between LUT and Log preserves the toggle. Turning false color off restores the selected preview. It analyzes the same adjusted encoded BGRA8 signal as the waveform, before the false-color overlay. It does not perform a color-space conversion or normalize to the brightest pixel. Thumbnails and exports do not include the overlay.

The Blackmagic-style purple/blue/green/pink/yellow/red palette maps active preview luminance to 0–100 bands: purple below 2, blue 2–4, green 38–42, pink 52–56, yellow 80–95 and red 95–100. Other values are grayscale. Encoded luminance uses 0.2126 R + 0.7152 G + 0.0722 B. The legend follows Blackmagic’s table from top to bottom: 95%WC (red), 80%WC (yellow), MG+1 (pink), 18%MG (green), NBDL (blue), BDL (purple). It displays those short labels beside the swatches, without a Meaning column. These bands show rendered signal levels; they do not identify a camera's native sensor saturation threshold, particularly in log footage that can clip below 95.

LUT mode preserves current adjusted rendering and embedded-LUT behavior. Log requests the source generation's default log gamma (Blackmagic Design Film, or DaVinci Intermediate for Gen 6) with LUT and custom display tone curve disabled. ISO, exposure, white balance, highlight recovery, gamut compression, lens correction and geometry still apply. These are cloned per-frame monitoring overrides, with no changes to stored tone parameters, source metadata or export rendering.

Waveform visibility defaults to hidden. Its close button and Window → Show/Hide Waveform update the same project property backed by the `waveformVisible` user-defaults key, restored on the next launch.

Validation: `preview_monitoring` exercises signal bands, input validation, real SDK LUT/Log switching with false color independently enabled, live exposure updates, exact overlay mapping of LUT preview pixels, waveform independence, rapidly superseded decode requests, visibility persistence, and native preview snapshots at 400/500/900 points. Native UI actions verify two mutually exclusive segments and a separate toggle exactly 8 points apart.
