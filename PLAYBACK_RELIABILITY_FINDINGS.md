# Overplay playback reliability: findings so far

As of 2026-10-09.

## Summary

Overplay's worst failure is Apple Music's player stopping answering: calls slow
down, then `prepareToPlay` never returns and Overplay stays stuck until it is
force-quit. The evidence points to Apple's shared Apple Music service rather
than Overplay alone. Another app-owned player, Soor's Application mode, is
labelled unreliable by its own developer. In May 2026 an Apple engineer
confirmed a similar MusicKit failure on iOS 26.4.2 was not expected behaviour.

- **Overplay's own suspects are gone.** The playback rewrite (PR #62,
  2026-10-05) removed everything Overplay did that might provoke the wedge, and
  the failure still recurred on 2026-10-09.
- **Overplay now handles the hang.** Since PR #91 (2026-10-09), a call
  unanswered for 8 seconds marks the player stuck and every surface advises
  force-quitting.
- **No public report matches exactly.** Nobody has posted a `prepareToPlay`
  that simply never returns, and we have not yet filed our own Feedback report.

## What we've seen

The same pattern recurs: Apple Music's responses slow down, then a playback call
stops answering. Everything below was observed on the owner's iPhone 15 Pro
unless noted.

| Date | What happened | Evidence |
| --- | --- | --- |
| 2026-10-09 | Network collapsed, then a new start's `prepareToPlay` never returned (02:15:50). All 9 Play presses ran recovery, whose `prepareToPlay` also never returned. Apple's Music app recovered by itself in about 15 minutes; Overplay stayed stuck until force-quit. | Activity log: artwork downloads took 54 s and 11 s; no answer, success or failure, to any prepare call |
| 2026-10-07 | A new queue loads in stages (2, then about 70, then all entries, in 0.3 to 0.4 s). Until the start song has loaded, MusicKit reports track 1 as current and playing. Shuffle set before the load finishes mixes only the first few songs. | Device probes on a 96-song playlist, iOS 26.6.1, Wi-Fi |
| 2026-10-07 | `prepareToPlay` never returned once; an unbounded wait in Overplay then left Play only pausing until relaunch. | Device probe |
| 2026-10-07 | On a drive, CarPlay shuffle taps 11 to 20 s after a resume did not take. | Owner report; suspected slow loading on cellular, unconfirmed |
| 2026-10-06 | MusicKit edits only playlists the app created (`ICPlaylistUpdateErrorDomain -1`), and an Overplay-made playlist lost that ownership. Any playlist edit on the Mac crashes (`MPModelLibraryPlaylistEditChangeRequest` missing). | iOS 26.6.1 and macOS 26.5 |
| 2026-10-05 | The phone's library lacked songs that iCloud had, so playlist sync could not resolve them. | Sync logs |
| 2026-09-07 | The whole Apple Music stack stopped responding, Apple's Music app included; a reboot recovered it. Calls slowed first (one went from 7 ms to 4,603 ms; library lookups from about 1 ms to 600 ms), then play failed with `MPMusicPlayerControllerErrorDomain` error 6. | 69-hour device log: 385 calls, queues capped at 50, so queue size was ruled out |
| Late Aug 2026 | Play and skip counting stopped after 27 August ([GitHub #26](https://github.com/xurble/overplay/issues/26)). | Suspected MusicKit reissuing queue entry IDs; never confirmed on device |

The 2026-10-09 recovery suggests earlier "needs a reboot" incidents may have
been the same stall inside Overplay's process: force-quitting Overplay was
enough.

## What we've tried

None of these cured the hang: each withdrawn approach either added Apple Music
traffic when the service was struggling or failed for other reasons, and the
current safeguards contain the hang rather than prevent it. Withdrawn
approaches are recorded in the spec's History section (H-1 to H-14) and must
not return without new device evidence.

| When | Approach | Result | Status |
| --- | --- | --- | --- |
| 2026-10-09 | Treat a call unanswered for 8 s as a stuck player: show force-quit advice everywhere, allow one fresh-queue attempt, then make no more Apple Music calls (PR #91) | Contains the hang; force-quit then works | Current |
| 2026-10-09 | Full activity logging: one log file per launch, error chains, audio session events (PRs #86, #91) | Gives evidence after an incident; Settings can share the log | Current |
| 2026-10-07 | Wait for the whole queue to load (up to 3 s) before shuffling or playing; bound every wait to 8 s (PRs #78, #81) | Fixes the track-1 flash and partial shuffle | Current |
| 2026-10-06 | Prepare songs from the Apple Music catalogue when their library ID is gone (PR #77) | Starts playback that used to fail | Current |
| 2026-10-04 | Playback rewrite (PR #62): single calls, no confirmation loops, no automatic retries or queue rebuilds, state from what the player reports | Removed every Overplay behaviour suspected of provoking the wedge; the hang still recurred on 2026-10-09 | Current |
| Until 2026-10-04 | Overplay as a second Now Playing client, writing system Now Playing and handling remote commands (H-7) | Two clients competed for the Lock Screen and CarPlay; leading suspect for the September wedge | Withdrawn |
| Until 2026-10-04 | Waiting up to 2.1 s for the player to confirm each command, then replacing the queue on timeout (H-5) | Added queue replacements exactly when Apple Music was slow; dropped user commands | Withdrawn |
| Until 2026-10-04 | Tracking songs by queue entry ID (H-4) | MusicKit does not keep those IDs; Overplay lost track of what was playing and counts stopped | Withdrawn |
| Until 2026-10-04 | Automatic recovery from a frozen stream, and repairing queue order mid-track (H-9, H-6) | Automatic traffic during degradation; audible glitches | Withdrawn |
| Until 2026-10-04 | Polling Apple play counts every 60 s, including during playback (H-12) | Largest background MusicKit load; now bounded and paused during playback | Reduced |
| 2026-09-07 | Handing over the queue 50 songs at a time (H-2) | The 69-hour log showed degradation anyway; a window cannot be shuffled | Withdrawn |
| 2026-09-07 | Overplay's own shuffle and repeat, rebuilding the queue at the end (H-1) | A constant fight with system surfaces; repeat was probably never disabled | Withdrawn |
| Never merged | Playing from an Overplay-owned Apple Music playlist so Apple owns shuffle (H-3) | Could not start at an arbitrary song; every change needed a playlist edit | Parked |

## Research: Soor

Soor's developer recommends its System player, which hands playback to Apple's
Music app, because their app-owned player is "known to cause random playback
issues". Overplay's player is the app-owned kind. We inspected Soor 3.5.9
(Tanmay Sonawane, Mac App Store build, 2026-10-09): the quotes below are Soor's
own settings text, read from its app binary.

| | Soor System (default) | Soor Application ("experimental") | Overplay |
| --- | --- | --- | --- |
| Apple API | MediaPlayer `systemMusicPlayer` | MediaPlayer `applicationQueuePlayer` | MusicKit `ApplicationMusicPlayer` |
| Who owns the queue | Apple's Music app, shared | Soor | Overplay |
| Reorder or delete queue items | No | Yes | Not offered |
| Quitting the app | Music keeps playing | Music stops | Music stops |
| Lock Screen artwork opens | Music app | Soor | Overplay |
| Developer's verdict | "More stable and rarely causes playback issues" | "Known to cause random playback issues" | Hang recurred 2026-10-09 |

What this means for Overplay:

- **The app-owned player is fragile for others too.** It points to Apple's
  playback service as at least part of the cause, not only Overplay's code.
  Both APIs are thought to use the same system service; that is unverified.
- **A System mode is a fix of last resort.** Soor's own CarPlay Now Playing
  screen needs its Application mode, and System mode cannot reorder the queue.
  Overplay's CarPlay-first design and its playlist flows depend on owning the
  queue, so it is kept only as a fallback if the Soor test shows Apple's
  app-owned player is at fault.
- **Soor waits too.** It waits 0.5 s while the current song loads before
  reading the queue, the same staged loading we measured.
- **A Mac bug to watch for.** Soor logs "macOS is incorrectly returning system
  player queue, instead of app player queue". Bear this in mind when a queue
  looks wrong only in Mac testing.

Soor's volume and output pill inspired Overplay's audio output pill, merged on
2026-10-09.

## Research: public bug reports

The closest public report is a May 2026 Apple Developer Forums thread in which
MusicKit playback broke until the Music app was opened; an Apple engineer
called it unexpected. Nobody reports a `prepareToPlay` that never returns.
Searches on 2026-10-09 covered the Developer Forums, the public
[feedback-assistant/reports](https://github.com/feedback-assistant/reports)
repository (one unrelated 2022 MusicKit report) and OpenRadar (nothing found).

| Our problem | Closest report | What it says | Match |
| --- | --- | --- | --- |
| Playback calls stop answering | [MusicKit playback broken after Apple Music's "What's New?" screen](https://developer.apple.com/forums/thread/825433), iOS 26.4.2, May 2026 | `prepareToPlay` and queue calls fail until the user opens Apple's Music app. An Apple engineer said MusicKit relies on shared Apple Music services (account, tokens, subscription) that start only when the Music app runs. Suggested workaround: ask users to open Apple Music once. No FB number posted. | Close: same shared machinery, but our Music app recovered while Overplay stayed stuck |
| Playback calls stop answering | [Remote call timed out on large collections](https://developer.apple.com/forums/thread/750838), iOS 18, 2024 | `MPMusicPlayerControllerErrorDomain` code 9, "Remote call timed out", on queues over about 300 songs. No Apple reply. | Partial: our queues are about 97 songs and size was ruled out |
| Queue loads in stages | [Unexpectedly transient queue entries](https://developer.apple.com/forums/thread/701326), 2022 | An Apple engineer: queue entries resolve asynchronously; apps should watch the queue for changes. | Explains our observation; Overplay now waits for the full load |
| Queue loads in stages | [Not all songs added to the queue](https://developer.apple.com/forums/thread/765314), iOS 18, 2024 | With shuffle on, the queue stops at a song already in the library. | Neighbouring bug |
| Editing only app-made playlists | [Which playlists can MusicKit edit?](https://developer.apple.com/forums/thread/722278), iOS 16 | Confirms the rule; the error is generic. Filed as FB11706965 and FB11740727. No Apple reply. | Confirms; nothing on ownership being lost |
| Mac: output and volume | [Albums for macOS developer's priorities](https://developer.apple.com/forums/thread/832470), June 2026 | On the Mac, `AVRoutePickerView` (FB13934910) and `MPVolumeView` (FB21042385) do not work with `ApplicationMusicPlayer`; Apple acknowledged both. | Confirms hiding Overplay's audio output pill on the Mac |
| Apple play counts | Same thread | Songs played through `ApplicationMusicPlayer` on the Mac do not update play count or last-played date (FB17675148). | Affects the Apple play-count comparison if it also happens on iPhone; unverified |

Nothing was found for the Mac playlist-edit crash, playlist ownership being
lost, or Soor's Mac queue bug. The spec also cites three threads not reopened
for this document: 727737 (MusicKit reports item IDs from a different domain),
688007 (remote-command customisation is unsupported with the application
player) and 847151 (iOS 27 CarPlay Now Playing, unverified).

## Next steps

The most useful next step is to report the hang to Apple with evidence; the
rest test whether the cause is Apple's or Overplay's.

- [ ] File a Feedback report for `prepareToPlay` never returning: attach the
  activity log (Settings, Apple Music Call Activity, Share Activity Log) and a
  sysdiagnose, cite forum thread 825433, and record the FB number in the spec's
  Known Defects.
- [ ] Next time Overplay hangs, open Apple's Music app before force-quitting
  Overplay, to test the forum thread's explanation.
- [ ] Use Soor in its Application mode for a few days, including CarPlay and
  long sessions. If it stalls the same way, the cause is Apple's player, and a
  System mode becomes the fix of last resort.
- [ ] Decide on PR #92 (open): remind the user to take a sysdiagnose before
  force-quitting a stuck player.
- [ ] Explain the 2026-10-09 stall (Now Playing stuck on one song, Overplay
  stuck after Apple Music recovered), tracked in
  [GitHub #90](https://github.com/xurble/overplay/issues/90).
- [ ] Look for `sessionCarriedOver` in the activity log, to confirm whether
  MusicKit reissues queue entry IDs.
- [ ] On the next drive, check the `loaded=` counts when a CarPlay shuffle tap
  does not take.
- [ ] Check whether Apple's play count and last-played date update on iPhone
  after Overplay plays a song.
