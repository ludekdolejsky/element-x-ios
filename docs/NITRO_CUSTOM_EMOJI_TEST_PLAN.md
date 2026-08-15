# Nitro Custom Emoji Test Plan

## Purpose

This document is the regression plan for the custom emoji support added to the
Nitro fork of Element X iOS. It covers discovery, composer suggestions, message
serialization, timeline rendering, reactions, encryption warnings, and cache
behaviour.

It deliberately separates deterministic tests from scenarios that require a
real Matrix account or a physical Apple device. A simulator can validate app
logic and UI, but it cannot prove the complete Sygnal to APNs delivery path.

## Test Layers

- `Unit`: deterministic Swift test with mocked Matrix state or timeline data.
- `UI`: XCUITest against the app's mock coordinator in an iOS simulator.
- `Live`: manual or automated test against the Nitro Matrix homeserver.
- `Device`: physical TestFlight device test, required for real remote push.

## Automated Regression Matrix

| ID | Area | Scenario | Expected result | Layer |
|---|---|---|---|---|
| E01 | Pack discovery | Stable global, current-room, and joined parent-space packs are present | Packs are displayed room, nearest-to-farthest parent space, then global | Unit |
| E02 | Pack discovery | Only legacy `im.ponies` events are present | Legacy packs and global references load | Unit |
| E03 | Pack discovery | Stable global reference exists but is empty | No legacy global references are loaded accidentally | Unit |
| E04 | Pack validation | Pack contains invalid MXC URLs, stickers, or belongs to an unjoined space | Invalid and inaccessible entries are ignored | Unit |
| E05 | Duplicates | Multiple packs define the same shortcode | The global emoji wins without moving global packs above contextual packs | Unit |
| E06 | Aliases | Two shortcodes point to the same MXC image | Both aliases remain available | Unit |
| E07 | Cache | A load succeeds, then a transient room-state request fails | Stale cache remains usable; retries respect cache and backoff windows | Unit |
| E08 | Optional rooms | A referenced global or parent pack room returns an access error | Other packs still load and the optional room does not trigger a retry loop | Unit |
| E09 | Suggestions | User types `:` in an eligible composer position | Emoji suggestions open and include custom and system emoji | Unit/UI |
| E10 | Suggestions | User types a partial label, shortcode, keyword, or pack name | Matching custom emoji are returned | Unit |
| E11 | Suggestions | Custom and system matches coexist | Custom categories are shown before system categories | Unit/UI |
| E12 | Suggestions | Duplicate shortcode exists across categories | Selecting the suggestion uses the global custom emoji | Unit |
| E13 | Composer | Custom suggestion is selected in the plain composer | Visible composer text becomes `:shortcode:` and remains editable | Unit/UI |
| E14 | Composer | Custom suggestion is selected in the rich composer | Visible text remains an editable shortcode until send | Unit/UI |
| E15 | Send | Plain text containing a known shortcode is sent | Plain body keeps `:shortcode:`; formatted body contains the MXC custom-emoji image | Unit |
| E16 | Send | Plain text contains Markdown-like literals next to a custom shortcode | Literal Markdown remains literal and only the emoji shortcode is rendered | Unit |
| E17 | Send | Rich text contains formatting and a custom shortcode | Existing rich formatting is preserved and the shortcode becomes an emoji image | Unit |
| E18 | Send security | Shortcodes occur inside `a`, `code`, `pre`, `script`, `style`, or `textarea` | Excluded nodes are not rewritten as emoji | Unit |
| E19 | Picker | Attachment menu eligibility changes with composer state | Custom emoji picker is offered only for a new, empty, sendable message | Unit/UI |
| E20 | Standalone send | User selects a custom emoji from the room attachment picker | One message is sent with shortcode fallback and custom-emoji formatted body | Unit/UI |
| E21 | Thread send | User selects a custom emoji from the thread attachment picker | Message is sent in the selected thread, not the room root | Unit/UI |
| E22 | Encryption warning | First custom emoji media send occurs in an encrypted room and user cancels | Warning appears and no message is sent | Unit/UI |
| E23 | Encryption warning | User accepts the warning and sends another custom emoji later | First send proceeds and acknowledgement suppresses later warnings app-wide | Unit/UI |
| E24 | Draft | A message containing custom emoji is saved and restored as a draft | Shortcode is editable and original MXC metadata is preserved for send | Unit |
| E25 | Edit | An existing custom-emoji message is edited and resent | Shortcode is editable and original MXC metadata is preserved | Unit |
| E26 | Serialization | Repeated shortcode occurrences or aliases share an MXC URL | Every intended occurrence is rendered exactly once | Unit |
| E27 | Reply/thread | A custom-emoji message is replied to or composed in a thread | Reply/thread metadata and custom emoji metadata are both preserved | Unit/UI |
| E28 | Timeline | Formatted body contains an intact `data-mx-emoticon` marker | Emoji renders inline as media with accessible shortcode text | Unit/UI |
| E29 | Timeline | Matrix sanitizer removed `data-mx-emoticon` but plain fallback remains | Marker is safely recovered and emoji still renders inline | Unit/UI |
| E30 | Timeline | Sanitized message contains punctuation and repeated emoji | Recovery correlates the correct count and positions | Unit |
| E31 | Timeline security | Ordinary MXC image has no matching shortcode fallback | It remains an ordinary image and is not promoted to custom emoji | Unit |
| E32 | Timeline security | Marked image uses a non-MXC URL | It is rejected as custom emoji | Unit |
| E33 | Previews | Reply or message preview contains a custom emoji attachment | Preview uses readable `:shortcode:` fallback rather than `[img ...]` | Unit |
| E34 | Reactions | Custom reaction uses an MXC event key | Summary renders the custom image and toggle sends/removes the original MXC key | Unit/UI |
| E35 | Reactions | Reaction details contain custom and Unicode reactions | Both render correctly with useful accessibility labels | Unit/UI |
| E36 | Regression | Standard Unicode emoji is suggested, selected, sent, and reacted with | Existing system emoji behaviour is unchanged | Unit/UI |
| E37 | Picker state | Custom emoji is selected repeatedly | Custom emoji is not written into the Unicode frequently-used store | Unit |
| E38 | Composer regression | Text is selected, then rich-text formatting is enabled | Selection/focus is retained and the intended range can be formatted | Unit/UI |

## Live Matrix Matrix

These scenarios need a dedicated test account and rooms on the real homeserver.
They must not use or mutate the user's production rooms.

| ID | Scenario | Expected result | Layer |
|---|---|---|---|
| L01 | Join a room with room, global, and parent-space packs | The picker reflects live state and priority without relaunch | Live |
| L02 | Send a custom emoji from Nitro iOS and receive it on Nitro iOS | Sender and receiver render the same inline emoji | Live |
| L03 | Read the same message in an unmodified Matrix client | It shows the readable `:shortcode:` fallback if custom media is unsupported | Live |
| L04 | Send in an encrypted room, cancel once, then accept | Cancel sends nothing; accepted media decrypts and the warning policy persists | Live |
| L05 | Send, edit, reply, and thread-reply with custom emoji | Relations target the correct event and content survives sync/relaunch | Live |
| L06 | Add and remove a custom reaction from Nitro and a second client | Reaction counts and MXC keys converge on both clients | Live |
| L07 | Switch accounts/rooms after caches are populated | Emoji from one account or room never leak into another | Live |

## Push Matrix

| ID | Scenario | Expected result | Layer |
|---|---|---|---|
| P01 | Build Element X and the NSE with Nitro bundle/app-group settings | Both targets build and embed with matching configuration | Simulator |
| P02 | Feed representative notification payloads to notification logic | Payload handling does not swallow notifications when filtering entitlement is disabled | Unit |
| P03 | Receive remote push while app is backgrounded | Notification is displayed and opens the correct room | Device |
| P04 | Receive encrypted-room push while app is terminated or phone is locked | NSE produces the expected notification without exposing plaintext incorrectly | Device |
| P05 | Reboot device, leave app unopened, then receive a push | Delivery behaviour and any platform limitation are recorded explicitly | Device |

## Execution Rules

1. Run unit tests and mock UI tests before any live Matrix test.
2. Use a dedicated Matrix test account and disposable rooms for `L01` to `L07`.
3. Never infer APNs success from a simulator build; `P03` to `P05` require a physical TestFlight device.
4. Record the commit, Xcode version, simulator/device OS, commands, pass count, failures, and skipped scenarios below.
5. A scenario is only marked passed when its expected result is asserted or directly observed.

## Run Log

### 2026-08-11 - iOS Simulator

Environment:

- Source commit: `76c34e29bb37e2576c2257c1efb065eb0ed07a10` with the
  uncommitted Nitro patch.
- Host: `eramac00.local`, macOS 26.5.1.
- Toolchain: Xcode 26.6 (`17F113`).
- Primary simulator: iPhone 17, iOS 26.5 (`31C2D2A7-0107-4269-AC9A-95B5C012FF45`).
- Live account: dedicated `@elementx_ios_test:mn.nitrovery.com` account. Its
  credentials are stored outside the repository.
- Live fixtures: disposable global-pack, parent-space, room-pack, encrypted,
  isolation, and relation rooms on `mn.nitrovery.com`.
- Threads were enabled only in the simulator app-group preferences so the live
  thread relation could be exercised. No product default was changed.

Results:

| Check | Result | Evidence |
|---|---|---|
| Relevant unit suites | Pass | 197 tests, 0 failures, 0 skipped; `/tmp/NitroEmojiUnitTests.xcresult` |
| Sanitized custom emoji timeline UI smoke test | Pass | 1 test executed, 0 failures; `/tmp/NitroEmojiUITests.xcresult` |
| Clean Release simulator build | Pass | Element X, NSE, and Share Extension built and embedded; `/tmp/NitroReleaseBuild.xcresult` |
| Nitro artifact configuration | Pass | App `com.nitrovery.elementx`, NSE `com.nitrovery.elementx.nse`, both Info.plists use `group.com.nitrovery.elementx` |
| Normal app launch | Pass, unauthenticated | Version 26.08.2 reached the sign-in screen without UI-test environment variables |
| Live login and onboarding | Pass | Dedicated account signed in and reached the room list; `/tmp/NitroLiveOnboarding.xcresult` |
| Live pack discovery, send, autocomplete, serialization, and timeline | Pass | Room, parent-space, and global display order asserted; duplicate global shortcode won; literal Markdown remained literal; `/tmp/NitroLiveEmoji.xcresult` |
| Live encrypted-room warning | Pass | Cancel sent no event; acceptance sent exactly one event per accepted action; acknowledgement persisted; `/tmp/NitroLiveEncryptedEmoji.xcresult` |
| Live room isolation | Pass | Global emoji remained available while room and parent-space emoji did not leak; `/tmp/NitroLiveEmojiIsolation.xcresult` |
| Live edit relation | Pass | `m.replace` targeted the exact root event and preserved shortcode fallback plus MXC formatted content; `/tmp/NitroLiveEditIsolated.xcresult` |
| Live reaction, reply, and thread relations | Pass | Three tests, 0 failures; raw Matrix events confirmed exact targets and the expected MXC reaction key; `/tmp/NitroLiveRelationsFinal.xcresult` |
| Focused room-list preview unit tests | Pass | Custom emoji falls back to `:shortcode:` while an ordinary MXC image retains `[img: alt]`; 2 tests, 0 failures; `/private/tmp/NitroRoomListPreviewUnitReleaseCandidate.xcresult` |
| Live room-list custom emoji preview | Pass | A uniquely marked message rendered `:room-only:` without `[img:]` after returning to the room list; 1 test, 0 failures; `/private/tmp/NitroRoomListPreviewUIProduction2.xcresult` |
| Full UnitTests target | Fail outside Nitro scope | 1,153 total: 1,149 passed, 3 failed, 1 skipped; `/tmp/NitroFullUnitTests.xcresult` |
| Isolated voice cache rerun on iOS 26.5 | Fail | `fileURL`, `cacheCopy`, and `cacheMove` reproduce Cocoa error 513 |
| Isolated voice cache rerun on iOS 26.4 | Fail | Same three failures and Cocoa error 513; `/tmp/NitroVoiceCache264.xcresult` |

The full-suite failures are in unchanged upstream `VoiceMessageCache` code. The
simulator rejects setting complete file protection on a cached `.m4a` file. No
custom emoji, composer, timeline, reaction, settings, or notification test
failed.

Automated scenario status:

- Direct pass: `E01-E09`, `E11-E17`, `E20`, `E24-E25`, `E28-E33`, `E36-E37`.
- Partial pass: `E10` has custom-pack search coverage but not a separate assertion
  for every searchable field; `E18` asserts links and code nodes but not every
  excluded HTML tag; `E22-E23` assert warning presentation and acceptance but
  not cancel and second-send persistence; `E26` has metadata and count coverage
  in separate tests; `P02` proves Nitro pusher registration but not remote NSE
  delivery.
- Build-covered only: `E19`, `E21`, `E38`.
- Live coverage now supplements `E20`, `E22-E23`, `E25`, `E27`, and `E34`.

Live scenario status:

- Pass: `L01` pack discovery and priority, `L04` encrypted warning cancel and
  accept, and `L05` send/edit/reply/thread relations.
- Partial pass: `L02` sender rendering and Matrix round-trip were verified in the
  same live client, but a second Nitro device was not used.
- Partial pass: `L03` readable plain-body `:shortcode:` fallback was verified in
  raw Matrix events, but it was not visually checked in an unmodified client.
- Partial pass: `L06` adding a custom reaction was verified with the exact MXC
  key and target event. Removal and second-client convergence were not run.
- Partial pass: `L07` room isolation was verified, but switching to a second
  account was not run.

Resolved issue discovered by live testing:

- Room-list, thread, and notification text previews now replace recognized MXC
  custom emoji images with their readable `:shortcode:` fallback while
  preserving surrounding HTML formatting. Ordinary MXC images remain unchanged.
  The focused unit and live simulator tests above cover both branches.

Remaining physical-device scope:

- `P03-P05` were not run. Genuine Sygnal to APNs delivery while backgrounded,
  terminated, locked, or after reboot requires a physical TestFlight device.
- No physical device is required for the completed login, composer, pack,
  timeline, encrypted warning, edit, reaction, reply, or thread checks.

The live XCUITests use unique per-run markers and inspect the action-menu preview
before selecting a timeline item. This prevents a false pass caused by acting on
an older message from the same sender. Relation assertions were independently
checked against the Matrix Client-Server API after the UI run.

Commands were run from `/Users/ludek/Projects/element-x-ios` on
`eramac00.local`:

```bash
xcodebuild test -project ElementX.xcodeproj -scheme UnitTests \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -resultBundlePath /tmp/NitroEmojiUnitTests.xcresult \
  -only-testing:UnitTests/RoomScopedEmojiProviderTests \
  -only-testing:UnitTests/CompletionSuggestionServiceTests \
  -only-testing:UnitTests/ComposerToolbarViewModelTests \
  -only-testing:UnitTests/AttributedStringBuilderTests \
  -only-testing:UnitTests/TimelineItemFactoryTests \
  -only-testing:UnitTests/TimelineViewModelTests \
  -only-testing:UnitTests/EmojiPickerScreenViewModelTests \
  -only-testing:UnitTests/NotificationManagerTests

xcodebuild test -project ElementX.xcodeproj -scheme UITests \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -resultBundlePath /tmp/NitroEmojiUITests.xcresult \
  -only-testing:UITests/RoomScreenUITests/testSanitizedCustomEmojiTimeline

xcodebuild build -project ElementX.xcodeproj -scheme ElementX \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -derivedDataPath /tmp/NitroReleaseBuild \
  -resultBundlePath /tmp/NitroReleaseBuild.xcresult

xcodebuild test -project ElementX.xcodeproj -scheme UnitTests \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -resultBundlePath /tmp/NitroFullUnitTests.xcresult

# Live tests are opt-in. The password is injected from a file outside the repo.
NITRO_LIVE_MATRIX_LOGIN=1 \
NITRO_LIVE_MATRIX_PASSWORD="$(cat ~/.config/elementx-ios-test-password)" \
xcodebuild test-without-building \
  -xctestrun ~/Library/Developer/Xcode/DerivedData/ElementX-aszyvcyawpbnsbgboatbsduojcvi/Build/Products/UITests_UITests_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -only-testing:UITests/AuthenticationFlowCoordinatorUITests/testNitroLiveLogin

NITRO_LIVE_MATRIX_EMOJI=1 \
xcodebuild test-without-building \
  -xctestrun ~/Library/Developer/Xcode/DerivedData/ElementX-aszyvcyawpbnsbgboatbsduojcvi/Build/Products/UITests_UITests_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -only-testing:UITests/AuthenticationFlowCoordinatorUITests/testNitroLiveCustomEmojiRoomFlow

# The relation suite uses NITRO_LIVE_MATRIX_EMOJI_RELATIONS=1 in a temporary
# copy of the xctestrun environment and runs edit, reaction, reply, and thread.
cp ~/Library/Developer/Xcode/DerivedData/ElementX-aszyvcyawpbnsbgboatbsduojcvi/Build/Products/UITests_UITests_iphonesimulator26.5-arm64.xctestrun \
  /tmp/NitroLiveRelations.xctestrun
/usr/libexec/PlistBuddy \
  -c 'Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:NITRO_LIVE_MATRIX_EMOJI_RELATIONS string 1' \
  /tmp/NitroLiveRelations.xctestrun
xcodebuild test-without-building \
  -xctestrun /tmp/NitroLiveRelations.xctestrun \
  -destination 'platform=iOS Simulator,id=31C2D2A7-0107-4269-AC9A-95B5C012FF45' \
  -resultBundlePath /tmp/NitroLiveRelationsFinal.xcresult \
  -only-testing:UITests/AuthenticationFlowCoordinatorUITests/testNitroLiveCustomEmojiEditFlow \
  -only-testing:UITests/AuthenticationFlowCoordinatorUITests/testNitroLiveCustomEmojiReactionFlow \
  -only-testing:UITests/AuthenticationFlowCoordinatorUITests/testNitroLiveCustomEmojiReplyAndThreadFlow
```
