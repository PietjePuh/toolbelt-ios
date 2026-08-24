# App/

SwiftUI sources go here.

Intentionally empty: creating an `.xcodeproj` is best done in Xcode on a Mac,
or generated (XcodeGen / Swift Package Manager) so it is reviewable as text
rather than an opaque pbxproj. Decide which before the first commit of a
project file — see `docs/DECISIONS.md`.

The build workflow detects the absence of a project and skips cleanly, so CI
stays green until there is something real to compile.
