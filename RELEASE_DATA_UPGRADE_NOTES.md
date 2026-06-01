# Release Data Upgrade Notes

Overplay is still pre-release, so the active development schema may reset during
local testing.

Before the first public beta or release:

- Review whether existing testers have CloudKit data that must be preserved.
- If preservation is required, add an explicit SwiftData migration from any
  pre-release stores that included `TrackedTrack`, `PlaybackEvent`, or
  `SettingsRecord`.
- If preservation is not required, document that beta testers should delete
  their local app data and CloudKit development data before installing the
  release build.
