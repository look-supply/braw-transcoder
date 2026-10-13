# Export panel layout

Field order is Codec → Resolution → Data Rate/Profile → Output → export actions.
ProRes replaces Data Rate with Profile in the same slot, preserving the resolution
choice and position. Export and Inspector share a native full-width popup control,
so field labels align with the visible controls rather than empty SwiftUI frames.

The wrapping layout moves complete labeled fields in reading order. Each row
shares its extra width, uses top alignment and 12-point gaps, and keeps destination
and actions together when they fit. Buttons adapt between a vertical pair in a
narrow column and a horizontal pair when a complete row is available. Labels use
the Inspector's 11-point medium style with 4-point control spacing. The panel uses
12-point padding and existing macOS surfaces and colors.

The center pane is a VStack: the preview takes remaining space, while Export takes
its intrinsic height. The window minimum width is 1000 points. No fixed-height
export split pane clips wrapped fields or leaves empty space during progress.

During export, settings and export buttons are replaced entirely by filename,
overall progress, clip/frame counts, percentage, and Cancel. Cancelling disables
the button and changes its title. On completion, cancellation, or failure, the
settings return with their existing selections and the operation's status message.
Output-directory persistence, selected/all export behavior, codec settings, and
aspect-preserving downsampling are retained.

Native UI regression checks render 360, 500, 720, and 1000-point panels, switch to
ProRes while checking the resolution's frame and selection, exercise custom-folder
layout, and verify that active export contains no dropdowns or output switch.
Progress and cancellation states are also rendered, alongside full-app checks at
1200×820 and 1000-point minimum window width. The complete 15-test suite passes.
