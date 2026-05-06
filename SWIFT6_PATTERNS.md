# SWIFT6_PATTERNS.md — Type-checker Antipatterns (Xcode 26.4 / Swift 6)

Reference for agents working on Q-Audion iOS. Extracted from
CLAUDE.md §13 (W174-W258 saga) — keeping it as a separate doc since
it's stable reference material, not session log.

**TL;DR — five rules to avoid silent type-checker exhaustion:**

1. No multi-segment interpolation `"\(a) ... \(b)"` inside closures
2. No `String + String` concat inside `print()` / function with many overloads
3. No `String(numericValue)` — use `String(describing:)`
4. No closure-body deeper than `closure → Task → do/catch` — extract methods
5. No struct construction with > 8 args inside `@ViewBuilder` — wrap in a `@ViewBuilder` computed property

If you see "the compiler is unable to type-check this expression in
reasonable time" — apply rules 1-5 in order.

---

## 1. Multi-segment interpolation in closures (W174 / W251)

```swift
// ❌ TYPE-CHECKER TIMEOUT
Task { @MainActor in
    print("[X] received \(obj.field) at \(timestamp)ms (\(other.nested))")
    snackbar?.show(.init(text: "\(a) of \(b) failed.", ...))
}

// ✅ Pre-bind to locals
Task { @MainActor in
    let a = obj.field
    let b = timestamp
    let msg: String = "\(a) of \(b) failed."
    snackbar?.show(.init(text: msg, ...))
}
```

## 2. `+` operator inside `print(...)` (W253)

`print` has many overloads (variadic / separator / terminator /
to:&Output). Combined with `String + String → String` overload set,
the type-checker explodes:

```swift
// ❌ TIMES OUT
let errMsg: String = error.localizedDescription
print("[VoiceNote] start failed: " + errMsg)

// ✅ Build line first, pass single String
let errMsg: String = error.localizedDescription
let line: String = "[VoiceNote] start failed: " + errMsg
print(line)
```

## 3. `String(numericValue)` overload trap (W255)

`String(_:)` has many numeric overloads. Use the single-overload alternatives:

```swift
// ❌ TIMES OUT (even though Int is unambiguous)
let recDur: String = String(rec.durationMs)

// ✅ String(describing:) has a single overload
let recDur: String = String(describing: rec.durationMs)

// Other safe forms:
"\(rec.durationMs)"          // single-segment interpolation
rec.durationMs.description   // property access
```

## 4. Even pre-bound `+` concat times out at sufficient depth (W256)

```swift
// ❌ TIMES OUT (both sides explicitly typed):
let errMsg: String = error.localizedDescription
let line: String = "[VoiceNote] start failed: " + errMsg
print(line)
```

Inside a deeply-nested closure (`Task { do { try await ... } catch { ... } }`
inside a SwiftUI ViewBuilder argument), even `+` between two explicit
Strings explodes.

**Pragmatic rule for debug prints in nested closures**: don't build
the String at all.

1. Drop the print (debug logs aren't load-bearing — `_ = error` to
   suppress unused-variable warnings)
2. Use multiple `print()` calls with single-literal args
3. Move formatting to a top-level helper function

Production code should use `os_log` / `Logger` anyway.

## 5. Closure depth itself is the killer (W258)

Even bog-standard 2-argument method calls time out at sufficient depth:

```
ChatDetailScreen.swift:145:29: error: the compiler is unable to type-check
container.markFailed(messageId: UUID(), reason: .generic)
^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

**Structural fix: extract closure body to a named method.**

```swift
// ❌ BEFORE — 4 levels of closure constraints:
onStartVoiceNote: {
    HapticFeedback.recordingStart()
    Task {
        do {
            try await voiceNoteRecorder.start()
        } catch VoiceNoteRecorder.RecorderError.permissionDenied {
            container.markFailed(messageId: UUID(), reason: .generic)
        } catch {
            _ = error
        }
    }
}

// ✅ AFTER — closure is trivial, type-checker has clean scope per method:
onStartVoiceNote: handleVoiceNoteStart,

private func handleVoiceNoteStart() {
    HapticFeedback.recordingStart()
    Task { await self.startVoiceNoteAsync() }
}

private func startVoiceNoteAsync() async {
    do {
        try await voiceNoteRecorder.start()
    } catch {
        await MainActor.run {
            container.markFailed(messageId: UUID(), reason: .generic)
        }
    }
}
```

**Rule of thumb**: any inline closure body deeper than
`closure → Task → do/catch` should be moved to a method. Reference
the method by name in the closure-binding parameter (no `{ ... }` at
the call site).

## 6. Large struct construction in @ViewBuilder (W261)

Even with every closure argument method-extracted, a struct with
> 8 arguments inside `@ViewBuilder` exhausts the type-checker:

```
ChatDetailScreen.swift:102:13: error: the compiler is unable to type-check
MessageComposer(
^~~~~~~~~~~~~~~~
```

**Fix**: wrap the construction in a `@ViewBuilder` computed property.

```swift
// ❌ BEFORE — inline in ZStack
ZStack {
    messageList
    MessageComposer(text: ..., editingTarget: ..., /* 12 more args */)
}

// ✅ AFTER — single property reference
ZStack {
    messageList
    composerView
}

@ViewBuilder
private var composerView: some View {
    MessageComposer(text: ..., editingTarget: ..., /* 14 args */)
}
```

The body's `ZStack` now sees `composerView` (a single 'some View'),
and the actual N-arg construction lives in a property getter with its
own clean type-check scope.

## 7. Calendar.Identifier `@unknown default` (W289)

In Xcode 26.4 strict mode `@unknown default` isn't enough for
`Calendar.Identifier` (the SDK added new cases like `.dangi`). Use
a regular `default` instead — covers all current + future identifiers.

```swift
// ❌ "switch must be exhaustive"
switch id {
case .gregorian: return "Gregoriano"
// ... other cases ...
@unknown default: return "Sconosciuto"
}

// ✅
switch id {
case .gregorian: return "Gregoriano"
// ... other cases ...
default: return "Sconosciuto"
}
```

Same applies to `UIUserInterfaceIdiom` and other less-frozen enums.

## 8. ByteCountFormatter has no `.locale` property

NVIDIA-generated code mistakenly assumed it does. It doesn't —
ByteCountFormatter derives formatting from the system locale
automatically. Use NumberFormatter (which DOES have `.locale`) for
explicit locale-controlled formatting.

```swift
// ❌
let formatter = ByteCountFormatter()
formatter.locale = Locale(identifier: "it_IT")  // doesn't compile

// ✅ Either omit it (uses system locale)
let formatter = ByteCountFormatter()
formatter.allowedUnits = [.useGB, .useMB]
formatter.countStyle = .decimal

// ✅ Or use NumberFormatter for explicit locale
let nf = NumberFormatter()
nf.locale = Locale(identifier: "it_IT")
nf.minimumFractionDigits = 1
```

---

## Diagnostic infrastructure

The build pipeline (`codemagic.yaml` Step 6 + Step 7) is set up to
surface these errors cleanly:

- **Step 6** "Diagnose Swift compile (raw xcodebuild)" runs
  `xcodebuild ... > diag.log 2>&1` (file redirect, not pipe) so
  xcbeautify can't swallow the actual error
- **Step 7** "Build IPA" pre-prints `diag.log` so the operator sees
  the diagnostic even if they only paste the IPA step's output

If a build fails opaquely (just "Failed to archive", no `error:`
line) — open the diag.log artifact or look at Step 7's prefix output.

---

## Saga timeline (W174 → W262)

Total elapsed: 38 build attempts spread across v1.0.225 → v1.0.262.

| Build | Pattern | Fix |
|-------|---------|-----|
| v1.0.221 | Multi-segment interpolation | Pre-bind locals |
| v1.0.251 | `\(reason.localizedDescription)` in 5-arg struct literal | Pre-bind + concat |
| v1.0.253 | `print(... + errMsg)` | Build line first |
| v1.0.255 | `String(rec.durationMs)` | `String(describing:)` |
| v1.0.256 | Even `let line: String = "..." + errMsg` | Drop print entirely |
| v1.0.258 | `container.markFailed(...)` in deep closure | Extract methods |
| v1.0.259 | Photo-picker callback closure | Extract methods + static helper |
| v1.0.260 | Composer Binding(set:) closure | Extract method |
| v1.0.261 | 14-arg MessageComposer in ZStack | @ViewBuilder property wrapper |
| v1.0.262 | Real API mismatch — pipeline GREEN | Add missing init parameter |

After v1.0.262, no further type-checker fires through v1.0.300+.

---

**Last updated:** 2026-05-02 (W312 audit completion sprint).
