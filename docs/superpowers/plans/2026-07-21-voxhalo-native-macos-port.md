# VoxHalo Native macOS Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a full-feature, native Apple Silicon macOS 26 VoxHalo application that matches the observable behavior of Windows upstream through commit `0867afe48e2196e84512c842aacb6117a1f8799e` and produces a locally signed `dist/VoxHalo.app`.

**Architecture:** A Swift Package opened and built by Xcode separates a minimal SwiftUI executable from a testable `VoxHaloKit` library. Swift actors own networking and session state, `@MainActor` models own UI state, AppKit owns the click-through overlay, Core Audio owns device/tap capture, and a small Objective-C++ bridge keeps the real-time AUHAL callback allocation-free. Both capture paths feed one converter, exact-frame accumulator, four-frame queue, and serialized session drain.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Foundation/URLSession, Core Audio, AudioToolbox, AVFAudio, CoreGraphics, CoreText, OSLog, Network (loopback tests only), Objective-C++, XCTest, Swift Package Manager, Xcode 26.6, macOS 26, arm64.

---

## Locked baseline and execution rules

- Windows behavioral reference: [`hellcatjack/VoxHalo_win@2f5627b`](https://github.com/hellcatjack/VoxHalo_win/commit/2f5627b14b4af5f476fef50f03f4cd269b031c09), branch `master`, commit time 2026-07-13 04:42:18 UTC.
- Upstream extension: commits `040bda5..0867afe` inspected on 2026-07-21 add ASR hotword context, persistence, acknowledgement status, reconnect snapshots, backend-aligned validation, and privacy/startup hardening. Tasks 0–20 remain the historical base-port sequence; Task 21 applies this extension.
- Original `2f5627b` GitHub archive rechecked on 2026-07-21: 71 files, byte-identical to the reviewed archive, aggregate sorted-file manifest SHA-256 `76a4502b8df5784bf178ccd2046e7207eb7949017e9e7a20398ead97fc5a3de4`.
- Product design: `docs/superpowers/specs/2026-07-13-macos-native-port-design.md`.
- Product name: `VoxHalo`; bundle identifier: `com.hellcatjack.voxhalo`; deployment target: macOS 26.0; architecture: arm64.
- Apple frameworks only. No package dependencies, virtual audio driver, persisted password, sandbox, backend mutation, Intel slice, notarization, or App Store work.
- Use strict Swift 6 concurrency. Core Audio callbacks may call only the Objective-C++ bridge and preallocated memory; they may not await, allocate Swift objects, log, write files, use the network, or touch the main actor.
- Follow red-green-refactor for every task. Do not combine unrelated tasks in one commit. Preserve user changes if the worktree becomes dirty.
- Commands below assume repository root `/Users/pccs/Desktop/codex/Voxhalo_mac`.

## Source tree and ownership

```text
Package.swift                                  SwiftPM products, targets, framework links
Config/Info.plist                              App identity, privacy strings, ATS exception
Config/VoxHalo.entitlements                    Hardened-runtime audio-input entitlement
Sources/VoxHaloApp/VoxHaloApp.swift            SwiftUI entry point and scene
Sources/VoxHaloApp/AppDelegate.swift            Dependency graph and application teardown
Sources/VoxHaloKit/Core/                       Platform-neutral directions, events, subtitles
Sources/VoxHaloKit/Networking/                 Endpoint, auth, WebSocket transport/client
Sources/VoxHaloKit/Audio/                      Catalog, permission, conversion, capture, queue
Sources/VoxHaloKit/Session/                    Session state machine and recovery
Sources/VoxHaloKit/Persistence/                Settings, JSON preservation, diagnostics
Sources/VoxHaloKit/Display/                    Persistent display UUID catalog
Sources/VoxHaloKit/Overlay/                    AppKit panel, outlined text, update pump
Sources/VoxHaloKit/Operator/                   Main-actor model and SwiftUI operator view
Sources/VoxHaloRealtimeAudio/include/          C API for real-time-safe AUHAL capture
Sources/VoxHaloRealtimeAudio/                  Objective-C++ callback/ring implementation
Tests/VoxHaloKitTests/                         Unit, native AppKit, and integration tests
Tests/VoxHaloKitTests/TestSupport/             Fakes, clocks, local server, Core Audio shim
scripts/build-app.sh                           Release build, bundle assembly, local signing
scripts/run-app.sh                             Build and launch helper
scripts/verify-app.sh                          Signature, entitlement, architecture, plist checks
docs/manual-test-checklist.md                  macOS permissions/audio/network/overlay matrix
docs/user-guide.md                             Operator usage and privacy behavior
```

`VoxHaloKit` contains all behavior except `@main` and final dependency construction. Tests import only `VoxHaloKit`; AppKit views/controllers therefore remain in that library. The executable owns live objects and termination cleanup but contains no business logic.

## Shared contracts used throughout the plan

Use these names and signatures consistently:

```swift
public enum TranslationDirection: Int, Codable, CaseIterable, Sendable {
    case chineseToEnglish = 0
    case englishToChinese = 1
    public var backendLanguage: String { get }
    public var backendDirection: String { get }
    public var targetLanguageLabel: String { get }
    public var sourceLanguageLabel: String { get }
}

public struct SubtitleDisplayModel: Equatable, Sendable {
    public let stablePrimaryLines: [String]
    public let activePrimaryText: String
    public let referenceText: String
    public let targetLanguage: String
    public let sourceLanguage: String
    public let isProcessing: Bool
    public let primarySegments: [String]
    public let referenceSegments: [String]
    public var stablePrimaryText: String { get }
    public var primaryText: String { get }
}

public enum AudioSourceKind: String, Codable, Sendable { case systemAudio, hardwareInput }
public struct AudioSource: Identifiable, Codable, Hashable, Sendable {
    public static let systemAudioID = "system-default-loopback"
    public static let systemAudio = AudioSource(
        id: systemAudioID, name: "System Audio", kind: .systemAudio
    )
    public let id: String
    public let name: String
    public let kind: AudioSourceKind
}

public struct AudioCallbackTimestamp: Equatable, Comparable, Sendable {
    public let nanosecondsSinceBoot: UInt64
    public func duration(since earlier: Self) -> Duration
}

public struct CapturedAudioFrame: Equatable, Sendable {
    public let pcm16LE: Data
    public let callbackTimestamp: AudioCallbackTimestamp
}

public enum AudioFrameQueueEvent: Equatable, Sendable {
    case frame(CapturedAudioFrame)
    case overflow
}

public protocol AudioCapturing: Sendable {
    func start(
        source: AudioSource,
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) async throws
    func stop() async
}

public protocol AudioPermissionProviding: Sendable {
    func authorize(_ source: AudioSource) async throws
}

public protocol AudioSourceValidating: Sendable {
    func validateAvailable(_ source: AudioSource) throws
}

public protocol VoxBridgeClientProtocol: Sendable {
    var isConnected: Bool { get async }
    func outputs() async -> AsyncStream<VoxBridgeClientOutput>
    func connect(to endpoint: VoxBridgeEndpoint,
                 credentials: VoxBridgeAuthCredentials?) async throws
    func start(direction: TranslationDirection) async throws
    func setTranslationDirection(_ direction: TranslationDirection) async throws
    func sendAudioFrame(_ frame: Data) async throws
    func finish() async throws
    func disconnect() async
}
```

The session coordinator owns one mutable `SubtitleStateStore`, one `BoundedAudioFrameQueue`, one output continuation, one socket-output task, one queue-drain task, and at most one shared Stop task. Production clocks use `ContinuousClock`; tests inject a manual monotonic clock.

### Task 0: Accept the Xcode license and verify the exact upstream baseline

**Files:**

- Verify: `docs/superpowers/specs/2026-07-13-macos-native-port-design.md`
- Reference only: `/tmp/VoxHalo_win_latest`

- [ ] **Step 1: Accept Apple's license as the Mac owner**

This is the only step the agent must not perform on the user's behalf. In Terminal, the user runs:

```bash
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Expected: both commands exit 0. If the user wants to review rather than accept directly, run `sudo xcodebuild -license` and complete Apple's interactive flow.

- [ ] **Step 2: Verify the toolchain**

Run:

```bash
xcodebuild -version
swift --version
git --version
uname -m
sw_vers -productVersion
```

Expected: Xcode `26.6` build `17F113`; Swift reports a working compiler; Git reports a version; architecture is `arm64`; macOS is 26.x.

- [ ] **Step 3: Verify upstream has not moved before implementation starts**

Run:

```bash
curl -fsSL https://api.github.com/repos/hellcatjack/VoxHalo_win/commits/master \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
```

Expected: `2f5627b14b4af5f476fef50f03f4cd269b031c09`. If it differs, stop before coding, download the new archive, diff behavior and tests, and revise the design and this plan.

- [ ] **Step 4: Confirm the planning repository is healthy**

Run:

```bash
git status --short
git log --oneline --decorate -2
```

Expected: only explicitly known work is present, and the design/plan commits are visible. Do not discard unrelated changes.

### Task 1: Scaffold the native package and launchable application shell

**Files:**

- Create: `Package.swift`
- Create: `Sources/VoxHaloKit/Core/VoxHaloVersion.swift`
- Create: `Sources/VoxHaloApp/VoxHaloApp.swift`
- Create: `Sources/VoxHaloApp/AppDelegate.swift`
- Create: `Sources/VoxHaloRealtimeAudio/include/VoxHaloRealtimeAudio.h`
- Create: `Sources/VoxHaloRealtimeAudio/VoxHaloRealtimeAudio.mm`
- Create: `Tests/VoxHaloKitTests/App/VoxHaloVersionTests.swift`
- Create: `.gitignore`

- [ ] **Step 1: Write the failing package smoke test**

```swift
import XCTest
@testable import VoxHaloKit

final class VoxHaloVersionTests: XCTestCase {
    func testProductIdentityIsStable() {
        XCTAssertEqual(VoxHaloVersion.productName, "VoxHalo")
        XCTAssertEqual(VoxHaloVersion.bundleIdentifier, "com.hellcatjack.voxhalo")
        XCTAssertEqual(VoxHaloVersion.minimumMacOS, "26.0")
    }
}
```

- [ ] **Step 2: Add the package manifest and verify red**

Create this manifest; `Network` is linked only into the test target for the loopback WebSocket server:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxHalo",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VoxHaloKit", targets: ["VoxHaloKit"]),
        .executable(name: "VoxHalo", targets: ["VoxHaloApp"])
    ],
    targets: [
        .target(
            name: "VoxHaloRealtimeAudio",
            path: "Sources/VoxHaloRealtimeAudio",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "VoxHaloKit",
            dependencies: ["VoxHaloRealtimeAudio"],
            path: "Sources/VoxHaloKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText")
            ]
        ),
        .executableTarget(
            name: "VoxHaloApp",
            dependencies: ["VoxHaloKit"],
            path: "Sources/VoxHaloApp"
        ),
        .testTarget(
            name: "VoxHaloKitTests",
            dependencies: ["VoxHaloKit"],
            path: "Tests/VoxHaloKitTests",
            linkerSettings: [.linkedFramework("Network")]
        )
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
```

Run:

```bash
swift test --filter VoxHaloVersionTests
```

Expected: FAIL because `VoxHaloVersion` is missing.

- [ ] **Step 3: Add the minimal shell**

```swift
public enum VoxHaloVersion {
    public static let productName = "VoxHalo"
    public static let bundleIdentifier = "com.hellcatjack.voxhalo"
    public static let minimumMacOS = "26.0"
}
```

Use this initial app shell:

```swift
import SwiftUI

@main
struct VoxHaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("VoxHalo") { Text("VoxHalo") }
    }
}
```

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {}
}
```

The C header declares `int32_t VHRealtimeAudioBridgeVersion(void);` inside `extern "C"` guards and the `.mm` implementation returns `1`; this proves the mixed-language dependency links.

- [ ] **Step 4: Build and test the shell**

Run:

```bash
swift test
swift build --product VoxHalo
file "$(swift build --show-bin-path)/VoxHalo"
```

Expected: tests PASS, build succeeds, and `file` reports a Mach-O 64-bit arm64 executable.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "build: scaffold native VoxHalo package"
```

### Task 2: Port direction values, wire events, parsing, and outbound messages

**Files:**

- Create: `Sources/VoxHaloKit/Core/TranslationDirection.swift`
- Create: `Sources/VoxHaloKit/Core/VoxBridgeEvent.swift`
- Create: `Sources/VoxHaloKit/Networking/VoxBridgeEventParser.swift`
- Create: `Sources/VoxHaloKit/Networking/VoxBridgeMessages.swift`
- Create: `Tests/VoxHaloKitTests/Core/TranslationDirectionTests.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeEventParserTests.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeMessagesTests.swift`

- [ ] **Step 1: Write exact mapping and parser tests**

```swift
func testChineseToEnglishWireMapping() throws {
    let direction = TranslationDirection.chineseToEnglish
    XCTAssertEqual(direction.rawValue, 0)
    XCTAssertEqual(direction.backendLanguage, "Chinese")
    XCTAssertEqual(direction.backendDirection, "zh2en")
    XCTAssertEqual(direction.targetLanguageLabel, "English")
    XCTAssertEqual(direction.sourceLanguageLabel, "Chinese")
    XCTAssertEqual(
        try String(data: VoxBridgeMessageEncoder.start(direction), encoding: .utf8),
        #"{"language":"Chinese","translation_direction":"zh2en","type":"start"}"#
    )
}

func testParserReadsEveryFieldAndNestedStability() throws {
    let event = try VoxBridgeEventParser.parse(Data(#"{"type":"partial","sentence_id":"s1","text":"你好","state_text":"state","delta_text":"delta","text_reset":true,"tentative_text":"tent","committed_text":"done","translation":"hello","language":"Chinese","message":"m","reason":"r","translation_direction":"zh2en","translation_source_language":"Chinese","translation_target_language":"English","seq":7,"sample_rate":16000,"ts_ms":1234,"slice_commit":true,"is_stable":false,"stability":{"is_stable":true,"phase":"final","reason":"endpoint","sentence_id":"s1","segment_id":2,"seq":7,"committed_count":3,"tentative_chars":4,"unstable_chars":5}}"#.utf8))
    XCTAssertEqual(event.type, .partial)
    XCTAssertEqual(event.rawType, "partial")
    XCTAssertEqual(event.sentenceID, "s1")
    XCTAssertEqual(event.translation, "hello")
    XCTAssertEqual(event.timestampMilliseconds, 1234)
    XCTAssertEqual(event.stability?.unstableCharacters, 5)
}
```

Add cases for all known raw types (`ready`, `started`, `partial`, `sentence_committed`, `sentence_updated`, `sentence_translation`, `sentence_reset`, `translation_direction`, `processing`, `final`, `error`, `pong`), unknown raw-type preservation, missing type, malformed JSON, wrong-typed optional fields becoming `nil`, UTF-8 Chinese input, English-to-Chinese mapping, exact finish JSON, and exact `set_translation_direction` JSON.

- [ ] **Step 2: Run the focused tests to verify red**

Run:

```bash
swift test --filter 'TranslationDirectionTests|VoxBridgeEventParserTests|VoxBridgeMessagesTests'
```

Expected: build FAIL because the direction, event, parser, and encoder types do not exist.

- [ ] **Step 3: Implement the wire types without permissive coercion**

Define `VoxBridgeEventType` with the 13 cases above. Define `VoxBridgeEvent` with required `type`/`rawType` and optional `sentenceID`, `text`, `stateText`, `deltaText`, `textReset`, `tentativeText`, `committedText`, `translation`, `language`, `message`, `reason`, `translationDirection`, `translationSourceLanguage`, `translationTargetLanguage`, `sequence`, `sampleRate`, `timestampMilliseconds`, `sliceCommit`, `isStable`, and `stability`. Define `VoxBridgeStability` with optional `isStable`, `phase`, `reason`, `sentenceID`, `segmentID`, `sequence`, `committedCount`, `tentativeCharacters`, and `unstableCharacters`.

Implement the parser with `JSONSerialization` accessors that return a value only for the expected JSON kind. Map exact lowercase event strings and preserve an unrecognized or absent type in `rawType`. Implement outbound messages with small `Encodable` structs and a `JSONEncoder` configured with `.sortedKeys`, producing:

```json
{"language":"Chinese","translation_direction":"zh2en","type":"start"}
{"translation_direction":"en2zh","type":"set_translation_direction"}
{"type":"finish"}
```

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter 'TranslationDirectionTests|VoxBridgeEventParserTests|VoxBridgeMessagesTests'
swift test
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Core Sources/VoxHaloKit/Networking Tests/VoxHaloKitTests/Core Tests/VoxHaloKitTests/Networking
git commit -m "feat: port VoxBridge wire protocol"
```

### Task 3: Port the immutable subtitle display model and text helpers

**Files:**

- Create: `Sources/VoxHaloKit/Core/SubtitleText.swift`
- Create: `Sources/VoxHaloKit/Core/SubtitleRow.swift`
- Create: `Sources/VoxHaloKit/Core/SubtitleDisplayModel.swift`
- Create: `Tests/VoxHaloKitTests/Core/SubtitleDisplayModelTests.swift`

- [ ] **Step 1: Write display normalization and bounds tests**

```swift
func testPrimaryTextIsNormalizedAndLimitedToNewest480UTF16Units() {
    let old = String(repeating: "旧", count: 300)
    let active = String(repeating: "新", count: 300)
    let model = SubtitleDisplayModel(
        stablePrimaryLines: ["  \(old)\n"], activePrimaryText: "\t\(active)  ",
        referenceText: " source ", referenceSegments: nil,
        targetLanguage: "English", sourceLanguage: "Chinese", isProcessing: true
    )
    XCTAssertTrue(model.primaryText.hasPrefix("..."))
    XCTAssertLessThanOrEqual(model.primaryText.utf16.count, 483)
    XCTAssertEqual(model.referenceSegments, ["source"])
}
```

Add tests for Unicode whitespace collapse, empty strings being removed, stable text excluding the active segment, supplied reference segments winning over fallback text, maximum 24 materialized segments, `empty(for:)` labels, and repeated reads returning the stored arrays without rebuilding them.

Port `DisplayModelReusesMaterializedPrimarySegmentsForRepeatedReads` here. The other three Windows `SubtitleViewModelTests` are replaced by the view-invalidation tests in Tasks 17-18: structured target/reference publication, independent target/reference updates, and no target redraw for a reference-only change.

- [ ] **Step 2: Run the tests to verify red**

Run: `swift test --filter SubtitleDisplayModelTests`

Expected: build FAIL because subtitle model types are missing.

- [ ] **Step 3: Implement one canonical text pipeline**

`SubtitleText.normalized(_:)` must split on Unicode whitespace, remove empty components, and join with one ASCII space. `SubtitleText.recentWindow(_:maximumUTF16Units:)` must trim from the front on a composed-character boundary until the suffix uses at most 480 UTF-16 code units, then prefix `...`. `SubtitleDisplayModel` must normalize once in its initializer, store arrays, derive `stablePrimaryText` by joining stable lines, derive `primaryText` from stable plus active, and keep only the newest 24 nonempty primary/reference segments. `SubtitleRow` stores sentence ID, source text, translation, maximum observed sequence, and optional timestamp milliseconds.

```swift
enum SubtitleText {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func recentWindow(_ text: String, maximumUTF16Units: Int = 480) -> String {
        let clean = normalized(text)
        guard clean.utf16.count > maximumUTF16Units else { return clean }
        var suffix = clean[clean.startIndex...]
        while suffix.utf16.count > maximumUTF16Units, !suffix.isEmpty {
            suffix.removeFirst()
        }
        return "..." + String(suffix)
    }
}
```

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter SubtitleDisplayModelTests
swift test
git add Sources/VoxHaloKit/Core Tests/VoxHaloKitTests/Core
git commit -m "feat: add bounded subtitle display model"
```

Expected: all tests PASS and the commit succeeds.

### Task 4: Port sentence ordering, translation, and correction semantics

**Files:**

- Create: `Sources/VoxHaloKit/Core/SubtitleStateStore.swift`
- Create: `Tests/VoxHaloKitTests/Core/SubtitleStateStoreTranslationTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/VoxBridgeEventFactory.swift`

- [ ] **Step 1: Write the translation-state tests**

```swift
func testOutOfOrderTranslationsFillInsertionTimeline() {
    var store = SubtitleStateStore(direction: .chineseToEnglish)
    store.apply(.sentenceCommitted(id: "s1", text: "一", sequence: 1))
    store.apply(.sentenceCommitted(id: "s2", text: "二", sequence: 2))
    store.apply(.sentenceTranslation(id: "s2", text: "two", sequence: 4))
    store.apply(.sentenceTranslation(id: "s1", text: "one", sequence: 3))
    XCTAssertEqual(store.current.primarySegments, ["one", "two"])
    XCTAssertEqual(store.rows.map(\.sentenceID), ["s1", "s2"])
}

func testHistoricalTranslationChangesOnlyAfterSentenceUpdated() {
    var store = translatedStore(("s1", "一", "one"), ("s2", "二", "two"))
    store.apply(.sentenceTranslation(id: "s1", text: "ONE unsolicited", sequence: 9))
    XCTAssertEqual(store.current.primarySegments, ["one", "two"])
    XCTAssertEqual(store.rows[0].translation, "ONE unsolicited")
    store.apply(.sentenceUpdated(id: "s1", text: "第一", sequence: 10))
    store.apply(.sentenceTranslation(id: "s1", text: "first", sequence: 11))
    XCTAssertEqual(store.current.primarySegments, ["first", "two"])
}
```

Port these Windows facts using their behavioral names: `TranslationBecomesPrimaryText`, `PartialUpdatesReferenceWithLiveRecognizedTextWithoutChangingTranslation`, `PartialBeforeCommitShowsTentativeReferenceImmediately`, `HistoricalSourceUpdateDoesNotReplaceLowerLatestRecognizedSentence`, `SentenceUpdatePreservesDisplayedTranslation`, `TranslationArrivingBeforeSourceIsDisplayedAndPreserved`, `SentenceUpdateKeepsDisplayedTranslationUntilReplacementTranslationArrives`, `PrimaryTextShowsRecentTranslationsAsContinuousStream`, `RepeatedTranslationForSameSentenceUpdatesActiveLineWithoutStableHistory`, `NewSentenceTranslationFinalizesPreviousActiveLineIntoStableHistory`, `OutOfOrderSentenceTranslationsFillCommittedTimelineWithoutDroppingLateOlderSentence`, `StableHistoryKeepsDisplayedSentencesWhenActiveSentenceAdvances`, `StableHistoryRetainsDisplayedSentencesForVerticalScroll`, `HistoricalTranslationWithoutSourceUpdateDoesNotRewriteStableDisplayedTranslation`, and `HistoricalSentenceUpdateUsesReplacementTranslationToAvoidDroppingUpgradedContent`.

- [ ] **Step 2: Run the tests to verify red**

Run: `swift test --filter SubtitleStateStoreTranslationTests`

Expected: build FAIL because `SubtitleStateStore` and event test factories are missing.

- [ ] **Step 3: Implement ordered rows and a separate displayed-translation map**

Implement `SubtitleStateStore` as a mutable `Sendable` struct owned by the session actor. Its state must include direction, insertion-ordered rows, `[String: String]` displayed translations, a translation-refresh `Set<String>`, reference sentence/text, aggregate fallbacks, dirty flags, and cached materialized arrays. Source upsert preserves translation and order, raises sequence to `max(old,new)`, and updates the live reference only for a new/latest/current-reference sentence. Translation upsert creates a source-less row when needed; it changes visible text only for a first translation, the last displayed sentence, or a sentence marked by `sentence_updated`.

Expose only:

```swift
public struct SubtitleStateStore: Sendable {
    public private(set) var current: SubtitleDisplayModel
    public private(set) var rows: [SubtitleRow]
    public init(direction: TranslationDirection)
    public mutating func reset(direction: TranslationDirection)
    @discardableResult public mutating func apply(_ event: VoxBridgeEvent) -> SubtitleDisplayModel
}
```

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter SubtitleStateStoreTranslationTests
swift test
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Core Tests/VoxHaloKitTests/Core Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: port authoritative subtitle sentence state"
```

### Task 5: Complete partial, aggregate, reset, bounds, and allocation behavior

**Files:**

- Modify: `Sources/VoxHaloKit/Core/SubtitleStateStore.swift`
- Create: `Tests/VoxHaloKitTests/Core/SubtitleStateStoreReferenceTests.swift`
- Create: `Tests/VoxHaloKitTests/Core/SubtitleStateStoreAggregateTests.swift`
- Create: `Tests/VoxHaloKitTests/Core/SubtitleStateStoreResetAndBoundsTests.swift`
- Create: `Tests/VoxHaloKitTests/Core/SubtitleStateStorePerformanceTests.swift`

- [ ] **Step 1: Write partial and aggregate tests**

```swift
func testPartialTargetTailRequiresCommittedPrefix() {
    var store = translatedStore(("s1", "你好", "hello"))
    store.apply(.partial(
        tentative: "世界", committed: "你好", translation: "hello world"
    ))
    XCTAssertEqual(store.current.primarySegments, ["hello", "world"])
    store.apply(.partial(
        tentative: "世界", committed: "你好", translation: "unrelated live tail"
    ))
    XCTAssertEqual(store.current.primarySegments, ["hello", "world"])
}

func testResetClearsAllStateButKeepsDirectionLabels() {
    var store = translatedStore(("s1", "你好", "hello"))
    store.apply(.processing())
    store.apply(.sentenceReset())
    XCTAssertTrue(store.rows.isEmpty)
    XCTAssertEqual(store.current, .empty(for: .chineseToEnglish))
}
```

Port the remaining Windows facts: `ReferenceSegmentsRetainRecentRecognizedSentencesForVerticalScroll`, `ReferenceSegmentsAppendLivePartialAfterCommittedRecognition`, `PartialCommittedAggregateKeepsShortRecognizedSentenceWhenLiveReferenceAdvances`, `LaterSentenceEventsReplacePartialCommittedAggregateFallbackWithoutDuplicating`, `ResetClearsRowsAndDisplayText`, `FinalCommitReconcileResetClearsDisplayedRowsForBackendRebuild`, `FinalCommitReconcileReplayBuildsOnlyBackendCanonicalRows`, `PrimaryTextKeepsNewestContinuousStreamWithinReadableWindow`, `PartialChangesOnlyReferenceAndLeavesStructuredTargetTextStable`, `PartialUsesTentativeTextAfterCommittedPrefixForLiveReference`, `PartialWithShortTentativeDoesNotRepeatedlyNormalizeLargeCommittedHistory`, `PartialUpdatesDoNotRebuildStableTargetAndReferenceHistory`, `PartialTextResetTrustsBackendStateTextWithoutLocalPrefixTrimming`, `FinalAggregateTranslationIsDisplayedWhenSentenceTranslationEventIsMissing`, `FinalDoesNotReplaceLatestCommittedReferenceWithAggregateText`, `PartialAggregateTranslationDoesNotAddLiveTargetTail`, `PartialTranslationBeforeSentenceTranslationDoesNotShowPrimarySubtitle`, `BackendStableChineseSentenceTranslationIsDisplayedWithoutLocalHoldback`, `ChineseCompleteSentenceEndingWithObjectPronounIsDisplayed`, `ChineseCompleteSentenceEndingWithCompoundWordContainingDuiIsDisplayed`, and `ChineseCompleteSentenceEndingWithCompoundWordContainingLaiIsDisplayed`.

Add explicit tests for processing on/final off, newest 24 target segments, newest 24 reference segments, a composed Unicode boundary at the 480-UTF-16-unit limit, and `reset(direction:)` changing both labels.

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter 'SubtitleStateStoreReferenceTests|SubtitleStateStoreAggregateTests|SubtitleStateStoreResetAndBoundsTests|SubtitleStateStorePerformanceTests'
```

Expected: FAIL on partial-prefix, aggregate-tail, reset-cache, processing, or allocation assertions.

- [ ] **Step 3: Implement the exact reconciliation rules**

Normal partial candidate priority is `tentativeText`, `text`, `stateText`, `committedText`; when `textReset == true`, priority is `tentativeText`, `stateText`, `text`, `deltaText`, `committedText` and the value is trusted without local prefix trimming. Otherwise strip a case-insensitive committed/current reference prefix when present. A partial aggregate translation is accepted only when `committedText` is nonblank and its case-sensitive normalized target begins with the already displayed target stream. A final aggregate may add a loose tail after the last displayed segment using case-insensitive matching. `final` clears processing, supplies reference text only when none exists, and never replaces the latest committed reference.

Keep primary/reference caches independently dirty. Rebuild primary arrays only after translation/aggregate changes and reference arrays only after source/reference changes. Retain newest 24 segments. `sentence_reset` and `reset(direction:)` clear rows, displayed maps, refresh markers, all aggregates, reference IDs/text, caches, and processing; only direction reset changes labels.

The event dispatcher is exhaustive and intentionally ignores non-display events:

```swift
switch event.type {
case .sentenceCommitted: upsertSource(event, marksTranslationRefresh: false)
case .sentenceUpdated: upsertSource(event, marksTranslationRefresh: true)
case .sentenceTranslation: applyTranslation(event)
case .partial:
    applyPartialCommittedAggregate(event)
    applyLiveReference(event)
case .sentenceReset: clearSubtitleState()
case .processing: isProcessing = true
case .final: applyFinal(event)
case .unknown, .ready, .started, .translationDirection, .error, .pong: break
}
current = buildCurrent()
return current
```

- [ ] **Step 4: Prove behavior and bounded allocation**

Run:

```bash
swift test --filter SubtitleStateStore
swift test
```

Expected: all ported state tests PASS. The two performance tests use `XCTMemoryMetric` across 100 identical reference-only partial updates and assert less than 2 MB allocated; a test-only rebuild counter also remains unchanged for stable target history.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Core Tests/VoxHaloKitTests/Core
git commit -m "feat: complete streaming subtitle reconciliation"
```

### Task 6: Implement safe settings persistence and normalization

**Files:**

- Create: `Sources/VoxHaloKit/Persistence/JSONValue.swift`
- Create: `Sources/VoxHaloKit/Persistence/AppSettings.swift`
- Create: `Sources/VoxHaloKit/Persistence/SettingsStore.swift`
- Create: `Tests/VoxHaloKitTests/Persistence/AppSettingsTests.swift`
- Create: `Tests/VoxHaloKitTests/Persistence/SettingsStoreTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/TemporaryDirectory.swift`

- [ ] **Step 1: Write defaults, privacy, preservation, and permission tests**

```swift
func testLegacyPasswordIsRemovedAndUnknownFieldsSurviveSave() throws {
    try legacyJSON.write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = SettingsStore(baseDirectory: temporaryDirectory)
    var loaded = try store.load()
    loaded.targetFontSize = 50
    try store.save(loaded)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    XCTAssertNil(object.first { $0.key.caseInsensitiveCompare("AuthPassword") == .orderedSame })
    XCTAssertEqual(object["future_option"] as? String, "preserved")
    XCTAssertEqual(object["TopTranslationFontSize"] as? Double, 50)
}

func testURLSanitizerRemovesCredentialsFragmentAndSensitiveQueries() throws {
    let input = URL(string: "ws://name:pass@example.test/ws?room=7&API%5FKEY=x#secret")!
    XCTAssertEqual(AppSettings.sanitizedEndpoint(input)?.absoluteString,
                   "ws://example.test/ws?room=7")
}
```

Port all 11 Windows settings methods and both theory rows. Cover the public default `wss://ushome.amycat.com:18024/ws`; migration of legacy `ws://192.168.1.31:8024/ws` to that public default; only absolute `ws`/`wss` with host; direction raw values; missing-device fallback deferred to catalog selection; all numeric fallback/clamp rules; invalid colors falling back; no password property; unknown JSON values round-tripping; atomic replacement; directory mode `0700`; file mode `0600`; and removal of decoded case-insensitive query names `token`, `access_token`, `refresh_token`, `id_token`, `session_token`, `api_key`, `apikey`, `password`, `passwd`, `secret`, `client_secret`, `authorization`.

- [ ] **Step 2: Run the tests to verify red**

Run: `swift test --filter 'AppSettingsTests|SettingsStoreTests'`

Expected: build FAIL because persistence types are missing.

- [ ] **Step 3: Implement typed known fields plus lossless unknown fields**

Use a recursive `JSONValue: Codable, Equatable, Sendable`. `AppSettings` stores safe fields and `[String: JSONValue] unknownFields`; its manual decoder recognizes the Windows PascalCase known keys case-insensitively, removes any `AuthPassword` key case-insensitively, preserves `DisplayMode` and `PreferredMonitorDeviceName` as unknown legacy data, and lets canonical known keys override duplicates on encoding. Encode canonical safe keys such as `BackendUrl`, `Direction`, `PreferredAudioDeviceId`, `PreferredDisplayUUID`, `TopTranslationAreaHeight`, `TopTranslationFontSize`, `TopTranslationTopOffset`, `TopTranslationColor`, `AuthUsername`, and the four `RecognitionSubtitle...` values. For numeric values, NaN, infinity, and nonpositive input fall back to the Windows default; other input clamps to target area `120...640` default 264, target font `18...56` default 36, target top offset `0...900`, reference area `48...360` default 96, reference font `16...42` default 24, and reference bottom offset `0...900`. Normalize any valid `#RRGGBB` color to uppercase and fall back on malformed values; the operator UI limits new selections to the six approved choices.

`SettingsStore` defaults to `~/Library/Application Support/VoxHalo/settings.json`, creates the directory at `0700`, writes JSON to a same-directory temporary file at `0600`, calls `FileHandle.synchronize()`, then uses `FileManager.replaceItemAt` or `moveItem` atomically and reapplies permissions. Environment variables override username/password/diagnostics at runtime only; password never enters `AppSettings`.

```swift
public struct AppSettings: Equatable, Sendable {
    public static let publicEndpoint = URL(string: "wss://ushome.amycat.com:18024/ws")!
    public var backendURL: URL
    public var direction: TranslationDirection
    public var preferredAudioDeviceID: String?
    public var preferredDisplayUUID: String?
    public var targetAreaHeight: Double
    public var targetFontSize: Double
    public var targetTopOffset: Double
    public var targetColor: String
    public var authUsername: String
    public var referenceAreaHeight: Double
    public var referenceFontSize: Double
    public var referenceBottomOffset: Double
    public var referenceColor: String
    public var unknownFields: [String: JSONValue]
}
```

- [ ] **Step 4: Run tests and inspect a real temporary save**

Run:

```bash
swift test --filter 'AppSettingsTests|SettingsStoreTests'
swift test
```

Expected: all tests PASS; permission assertions read POSIX modes `0700` and `0600` after masking file-type bits.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Persistence Tests/VoxHaloKitTests/Persistence Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add private settings persistence"
```

### Task 7: Implement opt-in, permanently redacted diagnostics

**Files:**

- Create: `Sources/VoxHaloKit/Persistence/DiagnosticsLogger.swift`
- Create: `Tests/VoxHaloKitTests/Persistence/DiagnosticsLoggerTests.swift`

- [ ] **Step 1: Write the redaction matrix tests**

```swift
func testSensitiveIdentityAndDeviceValuesAreAlwaysRedacted() async throws {
    let logger = try DiagnosticsLogger(environment: [
        "TRANSLATEPCCS_DIAGNOSTICS": "1",
        "TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS": "1"
    ], logsDirectory: temporaryDirectory)
    await logger.record(.sessionStart(host: "example.test", port: 443,
        direction: .chineseToEnglish, username: "operator", deviceID: "uid-1", deviceName: "Studio Mic"))
    let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
    XCTAssertTrue(text.contains("example.test"))
    for secret in ["operator", "uid-1", "Studio Mic"] { XCTAssertFalse(text.contains(secret)) }
}
```

Port the five Windows diagnostics facts. Add password, cookie, authorization header, URL userinfo/query secret, username, audio name, and audio UID probes. With transcript opt-in absent, text bodies must be `[REDACTED]` while lengths and stability metadata remain. With diagnostics absent, no directory or file is created.

- [ ] **Step 2: Run the tests to verify red**

Run: `swift test --filter DiagnosticsLoggerTests`

Expected: build FAIL because diagnostics types are missing.

- [ ] **Step 3: Implement structured events instead of arbitrary log strings**

Define `DiagnosticEvent` cases for session start, backend event metadata, connection category, audio counters, capture category, and error category. `DiagnosticsLogger` is an actor, derives enable flags only when the exact environment value is `1`, creates `~/Library/Logs/VoxHalo` at `0700` and `client.log` at `0600`, emits UTC JSON Lines, and replaces permanently sensitive fields before encoding. It never accepts a password, cookie, authorization value, full endpoint URL, or unrestricted dictionary at its public API.

```swift
public enum DiagnosticEvent: Sendable {
    case sessionStart(host: String, port: Int, direction: TranslationDirection,
                      username: String?, deviceID: String, deviceName: String)
    case backend(type: String, sequence: Int?, textLength: Int,
                 translationLength: Int, stability: VoxBridgeStability?,
                 transcript: String?, translation: String?)
    case connection(category: String)
    case audio(frameCount: UInt64, byteCount: Int)
    case capture(category: String)
    case failure(category: String)
}

public protocol DiagnosticsLogging: Sendable {
    func record(_ event: DiagnosticEvent) async
}
```

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter DiagnosticsLoggerTests
swift test
git add Sources/VoxHaloKit/Persistence Tests/VoxHaloKitTests/Persistence
git commit -m "feat: add redacted opt-in diagnostics"
```

Expected: all tests PASS and log permissions are `0600`.

### Task 8: Validate endpoints and implement optional login authentication

**Files:**

- Create: `Sources/VoxHaloKit/Networking/VoxBridgeEndpoint.swift`
- Create: `Sources/VoxHaloKit/Networking/VoxBridgeAuthCredentials.swift`
- Create: `Sources/VoxHaloKit/Networking/HTTPTransport.swift`
- Create: `Sources/VoxHaloKit/Networking/VoxBridgeAuthenticator.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeEndpointTests.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeAuthCredentialsTests.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeAuthenticatorTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeHTTPTransport.swift`

- [ ] **Step 1: Write endpoint, credential, and authentication tests**

```swift
func testLoginURLUsesHTTPFamilySameAuthorityAndLoginPath() throws {
    let endpoint = try VoxBridgeEndpoint(validating:
        XCTUnwrap(URL(string: "wss://example.test:18024/ws?ignored=1#fragment")))
    XCTAssertEqual(endpoint.loginURL.absoluteString, "https://example.test:18024/login")
}

func testAuthenticationPostsEscapedFormAndReturnsCookies() async throws {
    let transport = FakeHTTPTransport(response: .init(
        statusCode: 303,
        headers: ["Set-Cookie": "voxbridge_session=session-123; Path=/"],
        body: Data("must never appear in errors".utf8)
    ))
    let cookies = try await VoxBridgeAuthenticator(transport: transport).login(
        endpoint: try VoxBridgeEndpoint(validating: URL(string: "ws://127.0.0.1:9000/ws")!),
        credentials: .init(username: "operator name", password: "p&ss=word")
    )
    XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
    XCTAssertEqual(String(data: transport.lastRequest!.httpBody!, encoding: .utf8),
                   "password=p%26ss%3Dword&username=operator%20name")
    XCTAssertEqual(cookies.first?.name, "voxbridge_session")
}
```

Add tests that only absolute `ws`/`wss` URLs with host validate; runtime endpoint normalization removes userinfo and fragment before socket/login use; login also clears query; blank password returns no credentials and skips HTTP; blank username defaults to `admin`; nonblank username is trimmed; password is preserved verbatim; redirect following is disabled; 200 through 399 are accepted; 401 throws exactly `VoxBridge authentication failed.`; other `>=400` failures contain only `HTTP N`; and no error description contains body, username, password, cookie, or URL userinfo/query.

- [ ] **Step 2: Run focused tests to verify red**

Run:

```bash
swift test --filter 'VoxBridgeEndpointTests|VoxBridgeAuthCredentialsTests|VoxBridgeAuthenticatorTests'
```

Expected: build FAIL because endpoint/auth types are missing.

- [ ] **Step 3: Implement validation and login**

```swift
public struct VoxBridgeEndpoint: Equatable, Sendable {
    public let webSocketURL: URL
    public init(validating url: URL) throws
    public var loginURL: URL { get }
    public var isInsecure: Bool { webSocketURL.scheme?.lowercased() == "ws" }
}

public struct VoxBridgeAuthCredentials: Equatable, Sendable {
    public let username: String
    public let password: String
    public static func make(username: String?, password: String?) -> Self?
}
```

`HTTPTransport.send(_:)` returns status, case-insensitive headers, body, and cookies. Its URLSession implementation uses an ephemeral configuration and a delegate returning `nil` from `willPerformHTTPRedirection`; the 3xx response is therefore observable. Encode form components according to RFC 3986, sort keys for deterministic tests, set `application/x-www-form-urlencoded`, parse cookies with `HTTPCookie.cookies(withResponseHeaderFields:for:)`, and return them only in memory.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter 'VoxBridgeEndpointTests|VoxBridgeAuthCredentialsTests|VoxBridgeAuthenticatorTests'
swift test
git add Sources/VoxHaloKit/Networking Tests/VoxHaloKitTests/Networking Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add safe VoxBridge authentication"
```

Expected: all tests PASS.

### Task 9: Implement the WebSocket transport and actor client

**Files:**

- Create: `Sources/VoxHaloKit/Networking/VoxBridgeTransport.swift`
- Create: `Sources/VoxHaloKit/Networking/URLSessionVoxBridgeTransport.swift`
- Create: `Sources/VoxHaloKit/Networking/VoxBridgeClientProtocol.swift`
- Create: `Sources/VoxHaloKit/Networking/VoxBridgeClient.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeClientTests.swift`
- Create: `Tests/VoxHaloKitTests/Networking/VoxBridgeClientLoopbackTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeVoxBridgeTransport.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/LocalVoxBridgeServer.swift`

- [ ] **Step 1: Write client actor tests using a deterministic fake transport**

```swift
func testStartAudioDirectionAndFinishAreSerialized() async throws {
    let transport = FakeVoxBridgeTransport()
    let client = VoxBridgeClient(transportFactory: { _, _ in transport }, authenticator: .fakeSuccess())
    try await client.connect(to: testEndpoint, credentials: nil)
    async let first: Void = client.start(direction: .chineseToEnglish)
    async let second: Void = client.sendAudioFrame(Data([1, 2, 3, 4]))
    _ = try await (first, second)
    try await client.setTranslationDirection(.englishToChinese)
    try await client.finish()
    XCTAssertEqual(await transport.sentKinds, [.text, .binary, .text, .text])
    XCTAssertEqual(await transport.maximumConcurrentSendCount, 1)
}

func testMalformedTextReportsParseErrorAndReceiveLoopContinues() async throws {
    let (client, transport) = connectedClient()
    let outputs = await client.outputs()
    await transport.yield(.text("{"))
    await transport.yield(.text(#"{"type":"ready","sample_rate":16000}"#))
    let firstTwo = await outputs.prefix(2).collect()
    XCTAssertEqual(firstTwo.map(\.summary), ["parseError", "event:ready"])
}
```

Port all five Windows client facts: start/audio/finish, runtime direction, fragmented server text as one event, login-cookie handshake, and rejected login before socket opening. Add connect replacing/closing a previous socket, send-before-connect failure, concurrent send serialization, binary receive ignored, unknown event delivery, receive close/error output, cancellation, and idempotent disconnect even if close throws.

- [ ] **Step 2: Run tests to verify red**

Run: `swift test --filter 'VoxBridgeClientTests|VoxBridgeClientLoopbackTests'`

Expected: build FAIL because transport/client types are missing.

- [ ] **Step 3: Implement typed output and actor ownership**

```swift
public enum VoxBridgeConnectionEvent: Equatable, Sendable {
    case connected
    case disconnected
    case parseError
    case receiveError(String)
}

public enum VoxBridgeClientOutput: Equatable, Sendable {
    case event(VoxBridgeEvent)
    case connection(VoxBridgeConnectionEvent)
}

public enum VoxBridgeTransportMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
    case closed
}
```

`VoxBridgeClient` is an actor. `connect` first awaits cleanup of only the prior transport/receive task, optionally authenticates, builds a URLSession transport carrying `HTTPCookie.requestHeaderFields(with:)`, opens it, emits `.connected`, and starts exactly one receive task. Output subscriptions remain alive across this internal reconnect cleanup. Actor-isolated sends go through one FIFO send chain and fail with `notConnected` before opening. The receive loop ignores binary messages, parses complete logical text messages, emits `.parseError` and continues after malformed JSON, emits `.disconnected` for close, and emits a redacted error category then ends on network failure. Public `disconnect` cancels/awaits receive, attempts normal close, releases transport/session, finishes output streams, and is idempotent.

Foundation's `URLSessionWebSocketTask.receive()` supplies one logical message after WebSocket frame reassembly. `LocalVoxBridgeServer` uses `Network` plus a minimal RFC 6455 handshake/frame writer to prove a two-frame text message is delivered once; it binds only loopback, accepts synthetic credentials, and never contacts the real backend.

- [ ] **Step 4: Run focused, full, and loopback tests**

Run:

```bash
swift test --filter VoxBridgeClientTests
swift test --filter VoxBridgeClientLoopbackTests
swift test
```

Expected: all tests PASS and no test accesses `ushome.amycat.com`.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Networking Tests/VoxHaloKitTests/Networking Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add actor based VoxBridge client"
```

### Task 10: Define audio sources, permissions, and the live device catalog

**Files:**

- Create: `Sources/VoxHaloKit/Audio/AudioSource.swift`
- Create: `Sources/VoxHaloKit/Audio/AudioCaptureError.swift`
- Create: `Sources/VoxHaloKit/Audio/AudioPermissionProvider.swift`
- Create: `Sources/VoxHaloKit/Audio/CoreAudioHardware.swift`
- Create: `Sources/VoxHaloKit/Audio/CoreAudioDeviceCatalog.swift`
- Create: `Tests/VoxHaloKitTests/Audio/AudioSourceTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/AudioPermissionProviderTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/CoreAudioDeviceCatalogTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeCoreAudioHardware.swift`

- [ ] **Step 1: Write catalog and selection tests**

```swift
func testCatalogStartsWithSyntheticSystemAudioAndOnlyInputDevices() throws {
    let hardware = FakeCoreAudioHardware(devices: [
        .init(id: 11, uid: "speaker", name: "Output", inputChannels: 0, isAlive: true),
        .init(id: 12, uid: "mic", name: "USB Mic", inputChannels: 2, isAlive: true)
    ])
    let catalog = CoreAudioDeviceCatalog(hardware: hardware)
    XCTAssertEqual(try catalog.sources(), [.systemAudio,
        AudioSource(id: "mic", name: "USB Mic", kind: .hardwareInput)])
    XCTAssertEqual(AudioSourceSelection.preferred(from: try catalog.sources(), savedID: "missing"),
                   .systemAudio)
}
```

Add tests for saved UID selection, UID-to-transient-ID resolution, alphabetical name/UID ordering, renamed/attached/removed refresh exactly once, zero-channel exclusion, dead-device exclusion, VoxHalo private aggregate UID-prefix exclusion, observer teardown, microphone authorized/denied/restricted/not-determined mapping, and active hardware removal producing `.deviceDisconnected(uid:)` instead of switching.

- [ ] **Step 2: Run focused tests to verify red**

Run: `swift test --filter 'AudioSourceTests|AudioPermissionProviderTests|CoreAudioDeviceCatalogTests'`

Expected: build FAIL because audio catalog types are missing.

- [ ] **Step 3: Implement the Core Audio property seam and production adapter**

`CoreAudioHardware` must wrap `AudioObjectGetPropertyDataSize`, `AudioObjectGetPropertyData`, `AudioObjectAddPropertyListenerBlock`, and removal behind a protocol so tests never require physical hardware. Enumerate `kAudioHardwarePropertyDevices`, read persistent `kAudioDevicePropertyDeviceUID`, `kAudioObjectPropertyName`, `kAudioDevicePropertyDeviceIsAlive`, and input-scope `kAudioDevicePropertyStreamConfiguration` channel counts. Observe device-list plus per-device name/alive properties and deliver deduplicated sorted snapshots on a serial catalog queue.

`AudioPermissionProvider` uses `AVAudioApplication.shared.recordPermission` and `await AVAudioApplication.requestRecordPermission()` only for hardware input. System Audio permission is not preflighted because Core Audio requests it during tap startup; map that native startup failure in Task 15.

```swift
public protocol AudioDeviceCataloging: AudioSourceValidating, Sendable {
    func sources() throws -> [AudioSource]
    func deviceID(forUID uid: String) throws -> AudioDeviceID
    func startObserving(_ onChange: @escaping @Sendable ([AudioSource]) -> Void) throws
    func stopObserving()
}

public enum AudioCaptureFailure: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceUnavailable(uid: String)
    case deviceDisconnected(uid: String)
    case pipelineOverloaded
    case unsupportedFormat
    case coreAudio(operation: String, status: OSStatus)
}
```

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter 'AudioSourceTests|AudioPermissionProviderTests|CoreAudioDeviceCatalogTests'
swift test
git add Sources/VoxHaloKit/Audio Tests/VoxHaloKitTests/Audio Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add Core Audio source catalog"
```

Expected: all tests PASS.

### Task 11: Convert native audio, accumulate exact frames, and bound delivery

**Files:**

- Create: `Sources/VoxHaloKit/Audio/VoxBridgePCMFormat.swift`
- Create: `Sources/VoxHaloKit/Audio/PCM16MonoConverter.swift`
- Create: `Sources/VoxHaloKit/Audio/PCMFrameAccumulator.swift`
- Create: `Sources/VoxHaloKit/Audio/BoundedAudioFrameQueue.swift`
- Create: `Tests/VoxHaloKitTests/Audio/PCM16MonoConverterTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/PCMFrameAccumulatorTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/BoundedAudioFrameQueueTests.swift`

- [ ] **Step 1: Write numeric conversion, framing, and overflow tests**

```swift
func testFloatStereoDownmixAndLittleEndianPCM() throws {
    let buffer = try makeFloatBuffer(sampleRate: 48_000,
        left: [0.5, 0.5, 0.5], right: [0.5, 0.5, 0.5])
    let pcm = try PCM16MonoConverter(sourceFormat: buffer.format).convert(buffer)
    let first = Int16(littleEndian: pcm.withUnsafeBytes { $0.load(as: Int16.self) })
    XCTAssertEqual(first, 16_384, accuracy: 2)
}

func testFifthFrameClearsStaleFramesAndNextFreshFrameSurvives() async {
    let queue = BoundedAudioFrameQueue(capacity: 4)
    let generation = queue.reset()
    for byte in 1...5 { queue.offer(frame(byte), generation: generation) }
    XCTAssertEqual(await queue.next(), .overflow)
    queue.offer(frame(6), generation: generation)
    XCTAssertEqual(await queue.next(), .frame(frame(6)))
}
```

Add tests for 44.1/48 kHz sample-count accuracy across irregular chunks; interleaved/noninterleaved float32/int16/int24/int32; opposite-channel cancellation; channel averaging; clipping; NaN/infinity safety; explicit little-endian serialization; converter state across callbacks; exact 10,240-byte frames; partial/exact/multiple append; discard remainder without padding; four-frame FIFO; exactly one overflow marker; finish unblocking `next`; late offers ignored; and scratch-buffer reuse.

- [ ] **Step 2: Run focused tests to verify red**

Run:

```bash
swift test --filter 'PCM16MonoConverterTests|PCMFrameAccumulatorTests|BoundedAudioFrameQueueTests'
```

Expected: build FAIL because conversion/queue types are missing.

- [ ] **Step 3: Implement the shared conversion boundary**

```swift
public enum VoxBridgePCMFormat {
    public static let sampleRate = 16_000.0
    public static let channelCount: AVAudioChannelCount = 1
    public static let frameDurationMilliseconds = 320
    public static let frameByteCount = 10_240
}
```

Use one stateful `AVAudioConverter` per source format, request 16 kHz mono float output, downmix through its channel layout, clamp finite samples to `-1...1`, quantize with symmetric `Int16` limits, and write `littleEndian` values into reusable `Data`. `PCMFrameAccumulator.append` copies only enough bytes to complete frames and returns each exact 10,240-byte `Data`; `discardRemainder` empties the tail.

`AudioCallbackTimestamp` wraps monotonic nanoseconds since boot; production obtains it in the Objective-C++ callback from `mach_continuous_time()` plus `mach_timebase_info`, while tests construct exact values. `BoundedAudioFrameQueue` uses `NSLock` plus one checked continuation and a small enum-state machine. `reset() -> UInt64` increments and returns a generation token; `offer(_:generation:)` and `finish(generation:)` ignore stale tokens. Capacity is four. On the fifth queued frame it clears old frames, drops that fifth frame, queues one `.overflow`, and accepts the next later frame. Finishing the active generation resumes a waiter with `nil`.

```swift
public final class BoundedAudioFrameQueue: @unchecked Sendable {
    public init(capacity: Int = 4)
    @discardableResult public func reset() -> UInt64
    public func offer(_ frame: CapturedAudioFrame, generation: UInt64)
    public func signalOverflow(generation: UInt64)
    public func next() async -> AudioFrameQueueEvent?
    public func finish(generation: UInt64)
}
```

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter 'PCM16MonoConverterTests|PCMFrameAccumulatorTests|BoundedAudioFrameQueueTests'
swift test
git add Sources/VoxHaloKit/Audio Tests/VoxHaloKitTests/Audio
git commit -m "feat: add bounded PCM audio pipeline"
```

Expected: all tests PASS; Thread Sanitizer is clean when the queue test is later run through Xcode.

### Task 12: Build the transactional session start and backend-event pipeline

**Files:**

- Create: `Sources/VoxHaloKit/Session/SubtitleSessionModels.swift`
- Create: `Sources/VoxHaloKit/Session/SessionClock.swift`
- Create: `Sources/VoxHaloKit/Session/SubtitleSessionCoordinator.swift`
- Create: `Tests/VoxHaloKitTests/Session/SubtitleSessionCoordinatorStartTests.swift`
- Create: `Tests/VoxHaloKitTests/Session/SubtitleSessionCoordinatorEventTests.swift`
- Create: `Tests/VoxHaloKitTests/Session/SubtitleSessionDiagnosticsTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/CallRecorder.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeVoxBridgeClient.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeAudioCapture.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeAudioPermissionProvider.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeAudioSourceValidator.swift`

- [ ] **Step 1: Write the exact-order and rollback tests**

```swift
func testStartUsesRequiredOrderAndDoesNotWaitForReady() async throws {
    let fixture = SessionFixture()
    try await fixture.coordinator.start(fixture.configuration)
    XCTAssertEqual(await fixture.calls.values, [
        "validate:endpoint", "validate:source", "permission:systemAudio", "connect", "store.reset:chineseToEnglish",
        "client.start:chineseToEnglish", "audio.start:system-default-loopback",
        "state:running"
    ])
    XCTAssertFalse(fixture.client.readyWasRequested)
}

func testAudioStartupFailureRollsBackSocketAndPublishesOneFailure() async {
    let fixture = SessionFixture(audioStartError: AudioCaptureFailure.unsupportedFormat)
    await XCTAssertThrowsErrorAsync { try await fixture.coordinator.start(fixture.configuration) }
    XCTAssertEqual(await fixture.calls.values.suffix(3), ["audio.stop", "disconnect", "state:stopped"])
    XCTAssertEqual(await fixture.outputs.failures.count, 1)
}
```

Add a failing case at endpoint/source validation, permission denial, authentication/connect, start send, and audio start. Assert reverse cleanup only for acquired resources, no `running` publication on failure, a concise single error, safe shutdown after each partial start, and reset occurring after connect but before start. Port `StartConnectsBackendStartsDirectionAndAudio`, `StartResetsSubtitleStateToSelectedDirection`, and the three Windows diagnostics-session facts.

- [ ] **Step 2: Run tests to verify red**

Run:

```bash
swift test --filter 'SubtitleSessionCoordinatorStartTests|SubtitleSessionCoordinatorEventTests|SubtitleSessionDiagnosticsTests'
```

Expected: build FAIL because session types are missing.

- [ ] **Step 3: Implement the session surface and transactional start**

```swift
public struct SubtitleSessionConfiguration: Sendable {
    public let endpoint: VoxBridgeEndpoint
    public let direction: TranslationDirection
    public let audioSource: AudioSource
    public let credentials: VoxBridgeAuthCredentials?
}

public struct SubtitleSessionPolicy: Sendable {
    public var finalWaitTimeout: Duration = .seconds(120)
    public var callbackGapThreshold: Duration = .seconds(480)
}

public protocol SessionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public enum SubtitleSessionState: Equatable, Sendable {
    case stopped, starting, running, finishing
}

public enum SubtitleSessionOutput: Equatable, Sendable {
    case state(SubtitleSessionState)
    case subtitle(SubtitleDisplayModel)
    case status(String)
    case failure(String)
}
```

`SubtitleSessionCoordinator` is an actor injected with client, capture, source validator, permission provider, queue, initial store, diagnostics, clock, and policy. `start` rejects any non-stopped state; publishes `starting`; revalidates the endpoint and selected source; authorizes the selected source (hardware prompts, system returns ready for native-start prompt); connects; resets the store; sends start; obtains a new queue generation, starts one drain task and capture whose callback captures that generation; then publishes `running`. Track acquired stages and roll back capture, queue/tasks, and socket in reverse order. A separate client-output task applies known subtitle events, publishes immutable snapshots, records structured diagnostics, marks backend errors/faults, and never terminates on unknown events or parse errors.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter SubtitleSessionCoordinator
swift test
```

Expected: all tests PASS and startup never waits for `ready` or `started`.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Session Tests/VoxHaloKitTests/Session Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add transactional subtitle sessions"
```

### Task 13: Complete reconnect, overload, callback-gap, and Stop semantics

**Files:**

- Modify: `Sources/VoxHaloKit/Session/SubtitleSessionCoordinator.swift`
- Modify: `Sources/VoxHaloKit/Session/SubtitleSessionModels.swift`
- Create: `Tests/VoxHaloKitTests/Session/SubtitleSessionCoordinatorRecoveryTests.swift`
- Create: `Tests/VoxHaloKitTests/Session/SubtitleSessionCoordinatorStopTests.swift`
- Create: `Tests/VoxHaloKitTests/Session/SessionAudioPipelineTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/ManualSessionClock.swift`

- [ ] **Step 1: Write recovery and overload tests**

```swift
func testExactlyEightMinuteCallbackGapReconnectsBeforeFreshFrame() async throws {
    let fixture = try await runningSession()
    fixture.audio.emit(frame(1), at: fixture.audioTimestamp)
    fixture.clock.advance(by: .seconds(480))
    fixture.advanceAudioTimestamp(by: .seconds(480))
    fixture.audio.emit(frame(2), at: fixture.audioTimestamp)
    await fixture.waitForAudioSends(2)
    XCTAssertEqual(await fixture.client.operations.suffix(3), ["connect", "start:zh2en", "audio:2"])
}

func testOverflowDropsStaleAudioAndReconnectsBeforeLaterFreshFrame() async throws {
    let fixture = try await runningSession(clientSendSuspended: true)
    for byte in 1...5 { fixture.audio.emit(frame(byte), at: fixture.audioTimestamp) }
    await fixture.client.resumeSends()
    fixture.audio.emit(frame(6), at: fixture.audioTimestamp)
    await fixture.waitForStatus("Audio pipeline overloaded")
    XCTAssertEqual(await fixture.client.lastAudioByte, 6)
    XCTAssertEqual(await fixture.client.reconnectCount, 1)
}
```

Port `AudioAfterBackendIdleTimeoutReconnectsAndContinuesSending`, `AudioAfterReceiveLoopFailureReconnectsEvenWhenSocketStillLooksOpen`, and `AudioAfterLongLocalSilenceReconnectsBeforeSendingNextFrame`. Add 7:59 not reconnecting; callback-time rather than drain-time comparison; closed socket; backend error with/without message; first send failing then the same frame retried once; credential/direction reuse; burst fault gating to one reconnect; queue or native-ring overload status exactly once; stale frame removal; device disconnection stopping without source switching; runtime capture failure cleanup; and last subtitle preservation.

- [ ] **Step 2: Write Stop concurrency and final-wait tests**

```swift
func testStopOrdersCaptureFinishFinalDisconnectAndKeepsSubtitle() async throws {
    let fixture = try await runningSession(withSubtitle: "hello")
    async let stop: Void = fixture.coordinator.stop()
    await fixture.waitForOperation("finish")
    fixture.client.emit(.event(.final(translation: nil)))
    await stop
    XCTAssertEqual(await fixture.calls.values.suffix(5),
                   ["audio.stop", "finish", "final", "disconnect", "state:stopped"])
    XCTAssertEqual(await fixture.outputs.latestSubtitle?.primaryText, "hello")
}

func testConcurrentStopsShareOneOperationAndTimeoutAt120Seconds() async throws {
    let fixture = try await runningSession()
    async let a: Void = fixture.coordinator.stop()
    async let b: Void = fixture.coordinator.stop()
    fixture.clock.advance(by: .seconds(120))
    _ = await (a, b)
    XCTAssertEqual(await fixture.client.finishCount, 1)
    XCTAssertEqual(await fixture.client.disconnectCount, 1)
    XCTAssertEqual(fixture.outputs.statuses.last, "Final wait timeout")
}
```

Port `StopWaitsForBackendFinalBeforeReportingStopped` and `ConcurrentStopAsyncCallsDoNotRaceFinalEventState`. Add finish only while connected; install waiter before sending finish; error also releases waiter; no audio after Stop begins; repeated stopped call is no-op; timeout is clock-driven and nonblocking; disconnect happens after wait; capture and native callbacks stop first; queue/drain/output tasks end; and partial-start Stop is safe.

- [ ] **Step 3: Run the new tests to verify red**

Run:

```bash
swift test --filter 'SubtitleSessionCoordinatorRecoveryTests|SubtitleSessionCoordinatorStopTests|SessionAudioPipelineTests'
```

Expected: FAIL on missing reconnect, overflow, shared-stop, or manual-time behavior.

- [ ] **Step 4: Implement one serialized drain, reconnect task, and shared stop task**

The Objective-C++ audio callback records `AudioCallbackTimestamp` before offering the frame with the generation token captured for that Start. The only drain task compares consecutive callback timestamps; a gap `>= policy.callbackGapThreshold` marks the backend faulted. A client disconnect/receive error/backend error/send error/queue overflow also marks it faulted. A native-ring drop calls `signalOverflow(generation:)` and follows the same path. Before the next send, `ensureBackendSession` awaits one cached reconnect task that reuses endpoint, in-memory credentials, and direction; it does not reset subtitles. A failed send reconnects then retries that same frame once. Overflow publishes `Audio pipeline overloaded`, never sends cleared/fifth frames, and reconnects before the later fresh frame. Device disconnection and other fatal runtime capture failures stop capture, disconnect, publish one concise failure and `stopped`, and never select another source; `.pipelineOverloaded` is the recoverable exception.

`stop` returns/awaits one cached `Task<Void, Never>`. `performStop` changes state to finishing, stops capture, finishes the queue and waits for drain termination, installs a final/error continuation, sends finish only if connected, races the continuation against injected-clock sleep for 120 seconds, cancels client-output work, disconnects, clears session-only resources, and publishes stopped. Do not reset the store.

```swift
private func ensureBackendSession() async throws
private func drainAudio(generation: UInt64) async
private func handleClientOutput(_ output: VoxBridgeClientOutput) async
private func performStop() async

public func stop() async {
    if let stopTask { await stopTask.value; return }
    let task = Task { await self.performStop() }
    stopTask = task
    await task.value
    stopTask = nil
}
```

- [ ] **Step 5: Run with race diagnostics**

Run:

```bash
swift test --filter 'SubtitleSessionCoordinatorRecoveryTests|SubtitleSessionCoordinatorStopTests|SessionAudioPipelineTests'
swift test
swift test -Xswiftc -strict-concurrency=complete
```

Expected: all tests PASS and the compiler emits no new data-race errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/VoxHaloKit/Session Tests/VoxHaloKitTests/Session Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add resilient session recovery and stop"
```

### Task 14: Implement the real-time bridge and hardware-input AUHAL capture

**Files:**

- Modify: `Sources/VoxHaloRealtimeAudio/include/VoxHaloRealtimeAudio.h`
- Modify: `Sources/VoxHaloRealtimeAudio/VoxHaloRealtimeAudio.mm`
- Create: `Sources/VoxHaloKit/Audio/RealtimeAudioBufferRing.swift`
- Create: `Sources/VoxHaloKit/Audio/AUHALInputUnit.swift`
- Create: `Sources/VoxHaloKit/Audio/HardwareInputCapture.swift`
- Create: `Tests/VoxHaloKitTests/Audio/RealtimeAudioBufferRingTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/AUHALInputUnitTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/HardwareInputCaptureTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeAUHAL.swift`

- [ ] **Step 1: Write bridge and AUHAL setup-order tests**

```swift
func testHardwareCaptureUsesRequiredAUHALOrder() async throws {
    let hal = FakeAUHAL()
    let capture = HardwareInputCapture(deviceCatalog: catalog(uid: "mic", id: 42), halFactory: { hal })
    try await capture.start(source: .hardware(uid: "mic", name: "USB Mic"),
                            onFrame: { _ in }, onFailure: { _ in })
    XCTAssertEqual(hal.calls, [
        "createHALOutput", "enableInput:bus1", "disableOutput:bus0",
        "setDevice:42", "readFormat:output:bus1", "readMaxFrames",
        "allocateRing", "installInputCallback", "initialize", "start"
    ])
}
```

Add tests for the C ring capacity/FIFO/generation reset; callback write without heap allocation; UID resolution at Start; microphone denial before AUHAL creation; source-format propagation; conversion to exact frames; no callback after Stop; device-disconnect failure; repeated Stop; and failure after every setup call rolling back all completed calls in reverse order.

- [ ] **Step 2: Run tests to verify red**

Run:

```bash
swift test --filter 'RealtimeAudioBufferRingTests|AUHALInputUnitTests|HardwareInputCaptureTests'
```

Expected: build/test FAIL because the bridge and capture types are absent.

- [ ] **Step 3: Implement the allocation-free Objective-C++ boundary**

The C header exposes an opaque `VHRealtimeRing` plus create/destroy/reset/write/read/drop-count functions and an opaque `VHAUHALInput` plus create/configure/start/stop/dispose functions. Creation preallocates enough fixed-size `AudioBufferList` slots and payload storage for at least 1.28 seconds at the queried native sample rate/maximum callback frame count; the slot count is fixed until Stop. The C callback calls `AudioUnitRender` for input bus 1 into a free slot, samples `mach_continuous_time()`, converts it to monotonic nanoseconds with cached `mach_timebase_info`, atomically publishes the slot index/timestamp, and returns; it performs no malloc/free, Objective-C messaging, dispatch, locks, Swift callbacks, logging, or file/network work. A Swift serial worker drains slots, constructs `AVAudioPCMBuffer` outside the callback, runs `PCM16MonoConverter` and `PCMFrameAccumulator`, and offers timestamped complete frames using the active queue generation. A changed drop count reports `.pipelineOverloaded` so the session clears stale complete frames and uses the normal overload recovery path.

The public C surface is fixed to these operations so no Objective-C object crosses into Swift:

```c
typedef struct VHRealtimeRing VHRealtimeRing;
typedef struct VHAUHALInput VHAUHALInput;

typedef struct {
    uint32_t byteCount;
    uint32_t frameCount;
    uint64_t callbackNanoseconds;
} VHRealtimePacket;

VHRealtimeRing *VHRealtimeRingCreate(uint32_t slotCount, uint32_t bytesPerSlot);
void VHRealtimeRingDestroy(VHRealtimeRing *ring);
void VHRealtimeRingReset(VHRealtimeRing *ring);
bool VHRealtimeRingWrite(VHRealtimeRing *ring, const void *source,
                         uint32_t byteCount, uint32_t frameCount,
                         uint64_t callbackNanoseconds);
bool VHRealtimeRingRead(VHRealtimeRing *ring, void *destination,
                        uint32_t destinationCapacity, VHRealtimePacket *packet);
uint64_t VHRealtimeRingDroppedPacketCount(const VHRealtimeRing *ring);

OSStatus VHAUHALInputCreate(AudioDeviceID deviceID, VHRealtimeRing *ring,
                            VHAUHALInput **output);
OSStatus VHAUHALInputGetFormat(VHAUHALInput *input, AudioStreamBasicDescription *format);
OSStatus VHAUHALInputStart(VHAUHALInput *input);
OSStatus VHAUHALInputStop(VHAUHALInput *input);
void VHAUHALInputDispose(VHAUHALInput *input);
```

AUHAL setup order is: create `kAudioUnitType_Output`/`kAudioUnitSubType_HALOutput`; enable input element 1; disable output element 0; set `kAudioOutputUnitProperty_CurrentDevice`; read output-scope bus-1 format/max frames; allocate bridge; install `kAudioOutputUnitProperty_SetInputCallback`; initialize; start. Stop removes delivery generation first, then stops, uninitializes, disposes, drains worker, discards accumulator remainder, and releases bridge memory.

- [ ] **Step 4: Run focused tests and an empty-callback stress check**

Run:

```bash
swift test --filter 'RealtimeAudioBufferRingTests|AUHALInputUnitTests|HardwareInputCaptureTests'
swift test
```

Then start/stop a built-in microphone capture 100 times with a test harness while Allocations and Thread Sanitizer are enabled in Xcode. Expected: tests PASS, zero allocations/locks inside the callback stack, no callbacks after Stop, and no sanitizer issue. If hardware permission is denied, the automated fake tests still pass and the permission recovery is covered in Task 20 manual acceptance.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloRealtimeAudio Sources/VoxHaloKit/Audio Tests/VoxHaloKitTests/Audio Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: capture hardware input with AUHAL"
```

### Task 15: Implement private global system-audio tap capture

**Files:**

- Create: `Sources/VoxHaloKit/Audio/CoreAudioTapResources.swift`
- Create: `Sources/VoxHaloKit/Audio/SystemAudioTapCapture.swift`
- Create: `Sources/VoxHaloKit/Audio/CoreAudioCaptureService.swift`
- Create: `Tests/VoxHaloKitTests/Audio/CoreAudioTapResourcesTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/SystemAudioTapCaptureTests.swift`
- Create: `Tests/VoxHaloKitTests/Audio/CoreAudioCaptureServiceTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeCoreAudioTapAPI.swift`

- [ ] **Step 1: Write tap composition and exhaustive rollback tests**

```swift
func testSystemTapUsesActualTapUIDAndPrivateAggregate() async throws {
    let api = FakeCoreAudioTapAPI(createdTapUID: "actual-tap-uid")
    let capture = SystemAudioTapCapture(api: api, halFactory: fakeHALFactory)
    try await capture.start(source: .systemAudio, onFrame: { _ in }, onFailure: { _ in })
    XCTAssertEqual(api.processTapConfiguration?.isPrivate, true)
    XCTAssertEqual(api.processTapConfiguration?.excludesProcessObjectIDs, [])
    XCTAssertEqual(api.aggregateConfiguration?.tapUID, "actual-tap-uid")
    XCTAssertEqual(api.aggregateConfiguration?.driftCompensation, true)
    XCTAssertEqual(api.aggregateConfiguration?.tapAutoStart, false)
}
```

Add tests for description name `VoxHalo System Audio`, unique UUID, `.unmuted`, stereo global tap excluding no processes; reading actual `kAudioTapPropertyUID` and `kAudioTapPropertyFormat`; unique private aggregate UID/name; aggregate tap auto-start disabled; AUHAL binding to aggregate; prompt-denial error mapping; no-audio Start returning promptly; rollback after tap create, UID/format read, aggregate create, HAL configure/initialize/start; cleanup continuing after an intermediate failure; repeated Stop; and zero live tap/aggregate/unit IDs after application termination.

- [ ] **Step 2: Run tests to verify red**

Run:

```bash
swift test --filter 'CoreAudioTapResourcesTests|SystemAudioTapCaptureTests|CoreAudioCaptureServiceTests'
```

Expected: build FAIL because tap/capture service types are missing.

- [ ] **Step 3: Implement Apple's process-tap lifecycle exactly**

Create `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, set its name, `isPrivate = true`, `muteBehavior = .unmuted`, and a UUID, then call `AudioHardwareCreateProcessTap`. Read the created object's real UID and format. Call `AudioHardwareCreateAggregateDevice` with a private aggregate dictionary containing `kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`, drift compensation, and a unique UID; leave `kAudioAggregateDeviceTapAutoStartKey` false so Start does not wait for playback. Bind the same real-time AUHAL bridge to the aggregate and feed the shared converter/accumulator.

Cleanup always runs in this order and attempts every action even if one fails: stop/uninitialize/dispose AUHAL, destroy aggregate device, destroy process tap. Retain IDs until destruction succeeds so application termination can retry. Map the permission-denial status observed on macOS 26 to `.systemAudioPermissionDenied`; unknown statuses remain `.coreAudio(operation:status:)` and expose no device identity.

`CoreAudioCaptureService` selects `SystemAudioTapCapture` for `.systemAudio` and `HardwareInputCapture` for `.hardwareInput`, permits only one live child, and forwards frames/failures without switching sources.

```swift
struct ProcessTapConfiguration: Equatable, Sendable {
    let name: String
    let uuid: UUID
    let isPrivate: Bool
    let excludesProcessObjectIDs: [AudioObjectID]
    let isMuted: Bool
}

struct AggregateTapConfiguration: Equatable, Sendable {
    let name: String
    let uid: String
    let tapUID: String
    let isPrivate: Bool
    let driftCompensation: Bool
    let tapAutoStart: Bool
}

protocol CoreAudioTapAPI: Sendable {
    func createProcessTap(_ configuration: ProcessTapConfiguration) throws -> AudioObjectID
    func tapUID(_ tapID: AudioObjectID) throws -> String
    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription
    func createAggregate(_ configuration: AggregateTapConfiguration) throws -> AudioDeviceID
    func destroyAggregate(_ deviceID: AudioDeviceID) throws
    func destroyProcessTap(_ tapID: AudioObjectID) throws
}

actor CoreAudioCaptureService: AudioCapturing {
    func start(source: AudioSource,
               onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
               onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void) async throws
    func stop() async
}
```

- [ ] **Step 4: Run automated and real no-audio startup checks**

Run:

```bash
swift test --filter 'CoreAudioTapResourcesTests|SystemAudioTapCaptureTests|CoreAudioCaptureServiceTests'
swift test
```

Expected: all automated tests PASS. With System Audio Recording permission granted, a no-playback capture starts and stops within two seconds and leaves no private aggregate in Audio MIDI Setup.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxHaloKit/Audio Tests/VoxHaloKitTests/Audio Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: capture global system audio with Core Audio taps"
```

### Task 16: Persistently identify displays and react to screen changes

**Files:**

- Create: `Sources/VoxHaloKit/Display/DisplayDescriptor.swift`
- Create: `Sources/VoxHaloKit/Display/DisplayCatalog.swift`
- Create: `Tests/VoxHaloKitTests/Display/DisplayCatalogTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/FakeScreenProvider.swift`

- [ ] **Step 1: Write UUID, geometry, and fallback tests**

```swift
func testDescriptorsUseCGDisplayUUIDAndPointGeometry() throws {
    let screen = FakeScreen(number: 88, localizedName: "Side Display",
                            frame: NSRect(x: -1920, y: 0, width: 1920, height: 1080),
                            backingScaleFactor: 2)
    let catalog = DisplayCatalog(provider: FakeScreenProvider(screens: [screen]),
                                 uuidResolver: { _ in UUID(uuidString: "11111111-2222-3333-4444-555555555555")! })
    let value = try XCTUnwrap(catalog.displays().first)
    XCTAssertEqual(value.id, "11111111-2222-3333-4444-555555555555")
    XCTAssertEqual(value.frame.origin.x, -1920)
    XCTAssertEqual(value.scale, 2)
}
```

Add tests for display names, selected UUID winning regardless of array order, saved-display disappearance falling back to main, negative coordinates, point rather than pixel sizes on Retina, attach/remove/rearrange/rename notification refresh, and listener removal. Replace the Windows `MonitorServiceTests` raw-index behavior with this persistent UUID behavior.

- [ ] **Step 2: Run tests to verify red**

Run: `swift test --filter DisplayCatalogTests`

Expected: build FAIL because display types are missing.

- [ ] **Step 3: Implement AppKit/CoreGraphics display mapping**

Read the `NSScreenNumber` from each screen's `deviceDescription`, convert to `CGDirectDisplayID`, then call `CGDisplayCreateUUIDFromDisplayID`; persist the canonical uppercase UUID string. Store the `NSScreen.frame` in points and the backing scale separately. Observe `NSApplication.didChangeScreenParametersNotification` on the main actor and publish deduplicated snapshots. `selectedDisplay(savedUUID:)` returns an exact UUID match or the main screen, never an array-index substitute.

```swift
public struct DisplayDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let frame: CGRect
    public let scale: CGFloat
    public let isMain: Bool
}

@MainActor
public protocol DisplayCataloging: AnyObject {
    func displays() -> [DisplayDescriptor]
    func selectedDisplay(savedUUID: String?) -> DisplayDescriptor
    func startObserving(_ handler: @escaping @Sendable ([DisplayDescriptor]) -> Void)
    func stopObserving()
}
```

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter DisplayCatalogTests
swift test
git add Sources/VoxHaloKit/Display Tests/VoxHaloKitTests/Display Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: add persistent macOS display catalog"
```

Expected: all tests PASS.

### Task 17: Build the outlined, click-through, full-screen overlay

**Files:**

- Create: `Sources/VoxHaloKit/Overlay/OutlinedTextView.swift`
- Create: `Sources/VoxHaloKit/Overlay/SubtitleOverlayView.swift`
- Create: `Sources/VoxHaloKit/Overlay/SubtitleOverlayPanel.swift`
- Create: `Sources/VoxHaloKit/Overlay/SubtitleOverlayController.swift`
- Create: `Tests/VoxHaloKitTests/Overlay/OutlinedTextViewTests.swift`
- Create: `Tests/VoxHaloKitTests/Overlay/SubtitleOverlayViewTests.swift`
- Create: `Tests/VoxHaloKitTests/Overlay/SubtitleOverlayPanelTests.swift`
- Create: `Tests/VoxHaloKitTests/Overlay/SubtitleOverlayControllerTests.swift`

- [ ] **Step 1: Write native panel-contract tests**

```swift
@MainActor
func testPanelIsTransparentNonactivatingAlwaysOnTopAndClickThrough() {
    let panel = SubtitleOverlayPanel()
    XCTAssertFalse(panel.isOpaque)
    XCTAssertEqual(panel.backgroundColor, .clear)
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertEqual(panel.level, .screenSaver)
    XCTAssertTrue(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary,
                                                     .stationary, .ignoresCycle]))
}
```

Port or replace all 15 `SubtitleWindowTests` plus both display-mode theory rows: transparent/noninteractive; no activation/mouse capture; vector stroke without bitmap effects/background panel; geometry reuse; denser target typography; continuous target text; target above reference; reference scroll/left alignment; live layout changes; coalesced reference scroll; and transparency after placement. Add selected-screen full-frame placement, negative coordinates, Retina point scaling, screen-removal fallback, panel not entering normal window cycle, and showing empty at launch.

- [ ] **Step 2: Write outlined text and layout tests**

```swift
@MainActor
func testLayoutKeepsTargetNearTopAndReferenceNearBottom() {
    let view = SubtitleOverlayView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    view.apply(layout: .defaults, display: .sample)
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.referenceRegion.frame.minY, 0)
    XCTAssertGreaterThan(view.targetRegion.frame.minY, view.referenceRegion.frame.maxY)
    XCTAssertEqual(view.targetTextView.alignment, .left)
    XCTAssertEqual(view.referenceTextView.alignment, .left)
}
```

Assert target height/top offset and reference height/bottom offset are clamped before frames are computed; text wraps to region width; target uses one continuous string; reference uses bounded segments; both scroll to newest content; and unchanged text/font/bounds/color reuses one cached CoreText framesetter/path calculation.

Add a reference-only model update assertion that the target `OutlinedTextView`'s content generation and framesetter identity stay unchanged while the reference generation advances. Add the inverse target-only assertion. These are the macOS replacements for `UpdatePublishesStructuredDisplayText`, `UpdateRaisesIndependentStructuredSubtitleNotifications`, and `ReferenceOnlyUpdateDoesNotNotifyUnchangedPrimarySubtitleProperties`.

- [ ] **Step 3: Run tests to verify red**

Run:

```bash
swift test --filter 'OutlinedTextViewTests|SubtitleOverlayViewTests|SubtitleOverlayPanelTests|SubtitleOverlayControllerTests'
```

Expected: build FAIL because overlay types are missing.

- [ ] **Step 4: Implement vector text and panel ownership**

`OutlinedTextView` is a flipped, noninteractive `NSView` that caches a `CTFramesetter` keyed by normalized text, font, color, stroke width, and layout width. Draw with an attributed string containing foreground color, dark stroke color, negative stroke width for fill-plus-stroke, paragraph line wrapping, and left alignment. Invalidate cache only when a key changes.

`SubtitleOverlayView` owns separate target/reference `NSScrollView` regions with transparent backgrounds and no scrollers. Target renders `model.primaryText` as one block; reference renders `model.referenceSegments.joined(separator: " ")`. It computes frames from normalized settings and scrolls each document view to its newest bottom edge after layout, coalescing repeated scroll requests into one main-run-loop action.

`SubtitleOverlayPanel` uses style masks `.borderless` and `.nonactivatingPanel`, is nonopaque/clear/no-shadow, cannot become key/main, ignores mouse events, sets `isExcludedFromWindowsMenu = true` and `hidesOnDeactivate = false`, has `.screenSaver` level and all four required collection behaviors, and is excluded from normal cycling. `SubtitleOverlayController` retains the panel, fills the selected screen, observes display snapshots, moves to main on removal, applies display/layout changes immediately, and orders the empty panel front at launch without activating the app.

```swift
final class SubtitleOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class SubtitleOverlayController {
    public func showEmpty(on displayUUID: String?)
    public func apply(model: SubtitleDisplayModel)
    public func apply(layout: SubtitleLayoutSettings)
    public func selectDisplay(uuid: String?)
    public func close()
}
```

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter 'OutlinedTextViewTests|SubtitleOverlayViewTests|SubtitleOverlayPanelTests|SubtitleOverlayControllerTests'
swift test
git add Sources/VoxHaloKit/Overlay Tests/VoxHaloKitTests/Overlay
git commit -m "feat: add click through subtitle overlay"
```

Expected: all tests PASS.

### Task 18: Coalesce subtitle updates without blocking interaction

**Files:**

- Create: `Sources/VoxHaloKit/Overlay/SubtitleUIUpdatePump.swift`
- Create: `Tests/VoxHaloKitTests/Overlay/SubtitleUIUpdatePumpTests.swift`
- Create: `Tests/VoxHaloKitTests/TestSupport/ManualMainActorScheduler.swift`

- [ ] **Step 1: Port all six update-pump facts**

```swift
@MainActor
func testBurstCoalescesToLatestModelAfter150Milliseconds() {
    let scheduler = ManualMainActorScheduler()
    var applied: [SubtitleDisplayModel] = []
    let pump = SubtitleUIUpdatePump(minimumInterval: .milliseconds(150),
                                    scheduler: scheduler) { applied.append($0) }
    pump.post(model("one")); pump.post(model("two")); pump.post(model("three"))
    XCTAssertTrue(applied.isEmpty)
    scheduler.advance(by: .milliseconds(149)); XCTAssertTrue(applied.isEmpty)
    scheduler.advance(by: .milliseconds(1)); XCTAssertEqual(applied.map(\.primaryText), ["three"])
}
```

Port `PostDoesNotApplySubtitleSynchronously`, `PostCoalescesBurstIntoLatestDisplayBeforeDispatcherRuns`, `PostCanScheduleAnotherUpdateAfterCurrentBatchIsApplied`, `PostThrottlesBurstUpdatesWithinMinimumInterval`, `InteractiveWindowMoveDefersSubtitleApplyUntilMoveCompletes`, and `AlreadyQueuedSubtitleApplyIsDeferredWhenInteractiveMoveStarts`. On macOS, interactive deferral is driven by the operator window's `windowWillStartLiveResize`/`windowDidEndLiveResize` and move notifications.

- [ ] **Step 2: Run the test to verify red**

Run: `swift test --filter SubtitleUIUpdatePumpTests`

Expected: build FAIL because the pump is missing.

- [ ] **Step 3: Implement one main-actor pending slot**

The pump is `@MainActor`, stores only the latest pending model, schedules at most one deadline task, enforces 150 ms between applications, and cancels its task on deinit. `beginInteractiveChange` prevents apply but keeps the latest model; `endInteractiveChange` schedules it immediately if the interval elapsed or at the remaining deadline. Applying may synchronously post another model without losing it.

```swift
@MainActor
public final class SubtitleUIUpdatePump {
    public init(minimumInterval: Duration = .milliseconds(150),
                scheduler: any MainActorScheduling,
                apply: @escaping (SubtitleDisplayModel) -> Void)
    public func post(_ model: SubtitleDisplayModel)
    public func beginInteractiveChange()
    public func endInteractiveChange()
    public func cancel()
}
```

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter SubtitleUIUpdatePumpTests
swift test
git add Sources/VoxHaloKit/Overlay Tests/VoxHaloKitTests/Overlay Tests/VoxHaloKitTests/TestSupport
git commit -m "feat: coalesce subtitle UI updates"
```

Expected: all tests PASS.

### Task 19: Build the operator model, SwiftUI controls, and application lifecycle

**Files:**

- Create: `Sources/VoxHaloKit/Operator/SubtitleColorChoice.swift`
- Create: `Sources/VoxHaloKit/Operator/SubtitleLayoutSettings.swift`
- Create: `Sources/VoxHaloKit/Operator/OperatorModel.swift`
- Create: `Sources/VoxHaloKit/Operator/OperatorView.swift`
- Create: `Sources/VoxHaloKit/Operator/PermissionSettingsLink.swift`
- Create: `Sources/VoxHaloKit/App/AppEnvironment.swift`
- Modify: `Sources/VoxHaloApp/VoxHaloApp.swift`
- Modify: `Sources/VoxHaloApp/AppDelegate.swift`
- Create: `Config/Info.plist`
- Create: `Config/VoxHalo.entitlements`
- Create: `Tests/VoxHaloKitTests/Operator/OperatorModelTests.swift`
- Create: `Tests/VoxHaloKitTests/Operator/OperatorViewTests.swift`
- Create: `Tests/VoxHaloKitTests/App/AppEnvironmentTests.swift`
- Create: `Tests/VoxHaloKitTests/App/BundleConfigurationTests.swift`

- [ ] **Step 1: Write model locking, persistence, and credential tests**

```swift
@MainActor
func testRunningLocksSessionInputsButLeavesDisplayLayoutLive() async throws {
    let fixture = OperatorFixture()
    fixture.model.password = "memory only"
    await fixture.model.start()
    XCTAssertFalse(fixture.model.canEditBackend)
    XCTAssertFalse(fixture.model.canEditDirection)
    XCTAssertFalse(fixture.model.canEditAudioSource)
    XCTAssertTrue(fixture.model.canEditDisplayAndLayout)
    fixture.model.targetFontSize = 50
    XCTAssertEqual(fixture.overlay.lastLayout.targetFontSize, 50)
    XCTAssertFalse(try fixture.savedJSON().keys.contains {
        $0.caseInsensitiveCompare("AuthPassword") == .orderedSame
    })
}
```

Port all eight `OperatorViewModelTests`: overlay-only display mode/legacy normalization, settings load, username/layout save without password, provided credential handoff, environment password memory-only handoff, authentication failure resetting running state, and live layout persistence. Port the five `MainWindowTests` as native structure/live-update tests. Add insecure `ws://` warning, missing saved audio fallback before Start, active device removal stopping with a concise message, Start/Stop enablement including finishing state, denied-permission Settings link, and environment username/password precedence without persistence.

- [ ] **Step 2: Write bundle privacy and security tests**

```swift
func testInfoPlistContainsRequiredPrivacyAndATSKeys() throws {
    let plist = try loadPlist("Config/Info.plist")
    XCTAssertNotNil(plist["NSMicrophoneUsageDescription"] as? String)
    XCTAssertNotNil(plist["NSAudioCaptureUsageDescription"] as? String)
    let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
    XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
}
```

Assert bundle name/executable/identifier, `LSMinimumSystemVersion = 26.0`, high-resolution capability, the audio-input entitlement true, and absence of App Sandbox entitlement.

- [ ] **Step 3: Run tests to verify red**

Run:

```bash
swift test --filter 'OperatorModelTests|OperatorViewTests|AppEnvironmentTests|BundleConfigurationTests'
```

Expected: build FAIL because operator/app types and configuration files are missing.

- [ ] **Step 4: Implement the operator surface and exact choices**

`OperatorModel` is `@MainActor ObservableObject`. It loads settings, environment overrides, catalog/display snapshots, and session outputs; constructs credentials only at Start; persists safe changes atomically; sends layout/display changes directly to the overlay; and sends subtitle snapshots through the 150 ms pump. It exposes exactly six colors: White `#FFFFFF`, Soft White `#F4F4F4`, Warm Yellow `#FFD966`, Cyan `#8FE8FF`, Soft Green `#B7F7C4`, Pink `#FFB3D1`.

```swift
@MainActor
public final class OperatorModel: ObservableObject {
    @Published public var backendURL: String
    @Published public var username: String
    @Published public var password: String = ""
    @Published public var direction: TranslationDirection
    @Published public var selectedAudioSourceID: String
    @Published public var selectedDisplayUUID: String?
    @Published public var layout: SubtitleLayoutSettings
    @Published public private(set) var state: SubtitleSessionState = .stopped
    @Published public private(set) var status: String = "Stopped"
    @Published public private(set) var errorMessage: String?

    public var canEditBackend: Bool { state == .stopped }
    public var canEditDirection: Bool { state == .stopped }
    public var canEditAudioSource: Bool { state == .stopped }
    public var canEditDisplayAndLayout: Bool { true }
    public var endpointIsInsecure: Bool { backendURL.lowercased().hasPrefix("ws://") }

    public func start() async
    public func stop() async
}
```

`OperatorView` uses native SwiftUI `TextField`, `SecureField`, `Picker`, `Slider`/numeric fields, and Buttons for backend URL, username/password, two directions, audio source, display, Start/Stop/status, and both target/reference height/font/offset/color groups. Show `ws:// is not encrypted` beside an insecure endpoint. Disable backend/username/password/direction/audio while starting/running/finishing; keep display/layout live; disable Start unless stopped and valid; enable Stop only while starting/running and disable it while finishing.

Use defaults/ranges: target area 264 (`120...640`), font 36 (`18...56`), top offset 0 (`0...900`); reference area 96 (`48...360`), font 24 (`16...42`), bottom offset 0 (`0...900`); target white and reference soft white.

- [ ] **Step 5: Compose live dependencies and safe termination**

`AppEnvironment.live()` builds settings/diagnostics, Core Audio adapters, URLSession transports, store/session, display catalog, overlay controller, update pump, and operator model exactly once. It catches a malformed or unreadable settings file, uses safe defaults, and places one concise load failure in operator status rather than making dependency construction throw. `AppDelegate` retains the environment, shows an empty overlay in `applicationDidFinishLaunching`, and observes screen changes. In `applicationShouldTerminate`, return `.terminateLater`, run one async Stop plus device-listener/tap/aggregate cleanup, then call `NSApp.reply(toApplicationShouldTerminate:)`; repeated termination requests share that work.

```swift
@MainActor
public final class AppEnvironment {
    public let operatorModel: OperatorModel
    public let overlayController: SubtitleOverlayController
    public static func live() -> AppEnvironment
    public func applicationDidFinishLaunching()
    public func shutDown() async
}
```

`Info.plist` sets `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=1.0.0`, `CFBundleVersion=1`, `LSMinimumSystemVersion=26.0`, `NSHighResolutionCapable=true`, clear microphone/system-audio explanations, and the approved ATS arbitrary-load exception. Entitlements contain only `com.apple.security.device.audio-input = true` for this release.

- [ ] **Step 6: Run tests and commit**

```bash
swift test --filter 'OperatorModelTests|OperatorViewTests|AppEnvironmentTests|BundleConfigurationTests'
swift test
git add Sources/VoxHaloKit Sources/VoxHaloApp Config Tests/VoxHaloKitTests
git commit -m "feat: add native operator application"
```

Expected: all tests PASS and the executable target builds.

### Task 20: Package, verify, document, and accept the complete app

**Files:**

- Create: `scripts/build-app.sh`
- Create: `scripts/run-app.sh`
- Create: `scripts/verify-app.sh`
- Create: `Tests/VoxHaloKitTests/App/ProjectPackagingTests.swift`
- Create: `README.md`
- Create: `docs/architecture.md`
- Create: `docs/configuration.md`
- Create: `docs/security-and-privacy.md`
- Create: `docs/user-guide.md`
- Create: `docs/manual-test-checklist.md`

- [ ] **Step 1: Write packaging tests before the scripts**

```swift
func testReleaseScriptBuildsFixedArm64AppPathAndSignsWithEntitlements() throws {
    let script = try String(contentsOfFile: "scripts/build-app.sh")
    XCTAssertTrue(script.contains("swift build -c release --arch arm64 --product VoxHalo"))
    XCTAssertTrue(script.contains("dist/VoxHalo.app/Contents/MacOS/VoxHalo"))
    XCTAssertTrue(script.contains("--options runtime"))
    XCTAssertTrue(script.contains("Config/VoxHalo.entitlements"))
}
```

Port the eight Windows `ProjectPackagingTests` concepts and all 16 path/privacy theory rows to macOS: fixed product identity/output; Release arm64; no source/settings/log/password copied into bundle; required plist/entitlement keys; build/run helpers; docs paths; and scripts using fail-fast shell settings. Add executable permission checks, assert `Package.resolved` has no third-party dependency and product source contains no `Security`/Keychain persistence API, and add a build test that runs only when `VOXHALO_RUN_PACKAGING_TESTS=1`.

- [ ] **Step 2: Run packaging tests to verify red**

Run: `swift test --filter ProjectPackagingTests`

Expected: FAIL because scripts and documentation do not exist.

- [ ] **Step 3: Implement deterministic bundle assembly and verification**

`scripts/build-app.sh` must use `set -euo pipefail`, export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, run `swift build -c release --arch arm64 --product VoxHalo`, recreate `dist/VoxHalo.app/Contents/MacOS` and `Resources`, install the binary at mode `0755`, copy `Config/Info.plist`, then run:

```bash
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements Config/VoxHalo.entitlements dist/VoxHalo.app
scripts/verify-app.sh dist/VoxHalo.app
```

`verify-app.sh` fails unless `plutil -lint` passes; identifier is `com.hellcatjack.voxhalo`; minimum OS is 26.0; executable is arm64; `codesign --verify --deep --strict` passes; hardened runtime and audio-input entitlement are present; sandbox entitlement is absent; and no filename or file content contains `settings.json`, `client.log`, `AuthPassword`, a test secret, or a Windows `.exe/.dll/.pdb`. `run-app.sh` calls the build then `open -n dist/VoxHalo.app`.

- [ ] **Step 4: Write operator and developer documentation**

Document the architecture boundaries, build commands, source baseline SHA, default endpoint, all environment variables, settings/log paths and modes, password non-persistence, permanent/default redactions, `ws://` warning, microphone/System Audio Recording permission recovery, device/display fallback rules, Start/Stop/reconnect/final-wait behavior, and local-signing permission implications. The manual checklist must have pass/fail boxes for each item in the approved design's manual acceptance matrix and record macOS version, Xcode version, app commit, app signature hash, audio device UID recorded only outside logs, endpoint direction, result, and notes.

- [ ] **Step 5: Run the complete automated quality gate**

Run:

```bash
swift test
swift test -Xswiftc -strict-concurrency=complete
VOXHALO_RUN_PACKAGING_TESTS=1 swift test --filter ProjectPackagingTests
scripts/build-app.sh
scripts/verify-app.sh dist/VoxHalo.app
swift test list | tee /tmp/voxhalo-test-list.txt
```

Expected: every test passes; every one of the 148 Windows concrete facts has either a portable port or a documented macOS-native replacement; additional macOS, privacy, rollback, and overflow tests pass; `dist/VoxHalo.app` verifies as arm64 and locally signed.

- [ ] **Step 6: Run the manual acceptance matrix on the unchanged final build**

Use `docs/manual-test-checklist.md` and do not rebuild between permission approval and final checks. Verify grant/deny/recovery for microphone and System Audio Recording; built-in mic, available USB/line input, and actual playing system audio; 16 kHz PCM16 mono 10,240-byte frames; both directions against the configured real backend with user-provided credentials when required; partial/reference stability; reconnect; 120-second timeout; multi-display/negative-coordinate/Retina placement; Spaces/full-screen visibility; click-through/no focus theft; all live layout controls; safe relaunch persistence; diagnostics default-off and transcript redaction; permanent identity/device/credential redaction; and clean tap/aggregate removal after Stop and quit.

Expected: every applicable row passes. A row requiring unavailable USB/line hardware is marked `Not available on this Mac` with the catalog behavior still covered automatically; it is not silently reported as passed.

- [ ] **Step 7: Commit the release-ready port**

```bash
git add scripts Tests/VoxHaloKitTests/App README.md docs Config Package.swift Sources
git commit -m "build: package and document VoxHalo for macOS"
git status --short
```

Expected: commit succeeds and `git status --short` is empty.

### Task 21: Port the latest ASR hotword-context extension

**Files:**

- Create: `Sources/VoxHaloKit/Networking/AsrContextTermsParser.swift`
- Create: `Tests/VoxHaloKitTests/Networking/AsrContextTermsParserTests.swift`
- Modify: networking protocol/message/event files
- Modify: settings, operator model/view, session coordinator, diagnostics, tests, and user/privacy documentation

- [x] **Step 1:** Lock the upstream range `2f5627b..0867afe` and port its parser contract: whitespace/English-comma/Chinese-comma splitting, first-spelling case-insensitive de-duplication, sentence-punctuation rules, 24-term limit, and 160-Unicode-scalar joined limit.
- [x] **Step 2:** Always serialize `asr_context_terms`, including `[]`, and parse `asr_context_active`, `asr_context_term_count`, and `asr_context_chars`.
- [x] **Step 3:** Preserve an immutable term snapshot through initial Start and reconnect; report acknowledgement/legacy status without a later Running update overwriting it.
- [x] **Step 4:** Persist raw `AsrContextTermsText`, add the native multiline editor, validate before connecting, and roll back backend startup rejection without leaving capture running.
- [x] **Step 5:** Restrict diagnostics to term counts/character counts/acknowledgement metadata and backend-error length. Never pass configured arrays or backend error text into the logger.
- [x] **Step 6:** Run focused tests, the complete strict-concurrency/warnings-as-errors suite, packaging gate, bundle verifier, and privacy scan; add the manual hotword matrix.
- [ ] **Step 7:** Execute the live backend/audio hotword rows against the unchanged signed bundle and record the result without storing live credentials or identifying terms.

## Completion gate and coverage map

| Approved requirement | Implementing tasks | Proof |
|---|---:|---|
| Exact directions, JSON, events, subtitle reconciliation | 2-5 | parser/message tests plus all 36 state-store facts |
| Safe settings, password non-persistence, URL sanitation | 6 | settings/default/range/privacy/permission tests |
| Opt-in and permanent diagnostics redaction | 7, 12 | logger and session-shape tests |
| Login, cookies, WebSocket, fragments, binary PCM | 8-9 | fake-transport plus loopback integration tests |
| Transactional Start, reconnect, 8-minute gap, final wait | 12-13 | call traces, manual clock, overflow and concurrent-Stop tests |
| Hardware and global system capture | 10-11, 14-15 | fake Core Audio setup/rollback plus manual capture matrix |
| 16 kHz PCM16 mono, 320 ms frames, bounded memory | 11, 14-15 | numeric conversion, exact byte, ring and overflow tests |
| Persistent multi-display click-through overlay | 16-18 | UUID/geometry, AppKit panel, layout, CoreText, coalescing tests |
| Full operator feature set and lifecycle cleanup | 19 | model/view/bundle/environment tests |
| arm64 locally signed `dist/VoxHalo.app` | 20 | packaging tests, verification script, unchanged-build acceptance |
| Rare/professional vocabulary context with privacy hardening | 21 | parser/protocol/settings/operator/session/diagnostic tests plus live backend checklist |

The port is complete only after Tasks 20–21 automated gates pass and the applicable manual rows are recorded. A green unit suite without real microphone/system-audio, real backend/hotword acknowledgement, permission, multi-display/full-screen, teardown, and relaunch checks is not the finished product.
