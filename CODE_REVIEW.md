# Code Review — `feature-basal_therapy_history`

## Branch under review
- Workspace branch: `feature-basal_therapy_history`
- Workspace diff vs `main`: only two submodule pointer bumps.
- Submodule commits introduced:
  - `Loop` — `0475b0de` "Wire up therapy setting history provider in Loop app"
  - `LoopKit` — `f56fcdf9` "Add therapy setting history with comparison tables and trend analysis"

## What the feature does
Adds a "history" page to every therapy-setting editor (basal rate, carb ratio, ISF, correction range, suspend threshold, delivery limits, insulin model, pre-meal/workout overrides). Wraps each editor in a paged `TabView` whose second page is a new `TherapySettingHistoryView`. The view loads all `StoredSettings` from `SettingsStore`, filters them down to the points where the relevant setting changed, renders a comparison table (now vs. selected past) and a trend banner (increasing/decreasing/stable/fluctuating + percent change).

New code paths to keep in mind while triaging:
- `LoopKit/LoopKit/TherapySettingHistoryFilter.swift` — pure model: filtering + trend analysis.
- `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift` — SwiftUI view.
- `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingsView.swift` — adds `EditorWithHistoryWrapper` and threads `settingsProvider` through.
- `LoopKit/LoopKitUI/ViewModels/TherapySettingsViewModel.swift` — adds `public typealias SettingsHistoryProvider = () async throws -> [StoredSettings]` and a stored `settingsProvider`.
- `LoopKit/LoopKitTests/TherapySettingHistoryTests.swift` — unit tests for the filter/trend.
- `Loop/Loop/View Controllers/StatusTableViewController.swift` — provider closure + simulator-only stub data.
- `Loop/Loop/View Models/SettingsViewModel.swift` and `Loop/Loop/Views/SettingsView.swift` — pass the provider through.

## How to read this file
Each issue includes: severity, location(s), what the problem is, why it matters, a concrete next step, and a verification idea. Paths are relative to the workspace root.

Severity legend: **High** = real-user-visible incorrect behavior. **Medium** = robustness/perf/UX gap that will bite under realistic conditions. **Low** = quality / cleanup.

---

## High-severity

### H1. Trend math doesn't normalize glucose/ISF units
**Files:** `LoopKit/LoopKit/TherapySettingHistoryFilter.swift:153-173`

`extractRepresentativeValue` reads `.value` directly with no unit conversion:

```swift
case .insulinSensitivity:
    return items.map(\.value).reduce(0, +) / Double(items.count)
case .glucoseTargetRange:
    return items.map { ($0.value.minValue + $0.value.maxValue) / 2.0 }.reduce(0, +) / Double(items.count)
case .suspendThreshold:
    return settings.suspendThreshold?.value
```

But the storage units can vary across snapshots:
- `GlucoseRangeSchedule.unit` is per-schedule.
- `InsulinSensitivitySchedule.unit` is per-schedule.
- `GlucoseThreshold.unit` is per-instance.

If a user toggled their glucose unit preference at any point during their stored history, `analyzeTrend` mixes raw mg/dL numbers (e.g., 70) with raw mmol/L numbers (e.g., 3.9) and reports nonsense. Even within a single unit, differing schedule units between two adjacent stored snapshots produces a fake "change."

Compare: `isfComparisonTable` (`TherapySettingHistoryView.swift:364-396`), `correctionRangeComparisonTable` (`:400-435`), and `scalarComparisonTable` (`:439-469`) **do** convert via `HKQuantity` before display. Only the trend pipeline does not.

**Why it matters:** the trend banner is the most prominent piece of new UI. A wrong percent-change in a clinical setting (insulin therapy) is not just cosmetic.

**Investigate / fix:**
1. Verify whether `getStoredSettings()` historically yields heterogeneous-unit schedules in practice. Read `SettingsStore` encode/decode (`LoopKit/LoopKit/SettingsStore.swift:371-477`) to confirm `GlucoseRangeSchedule.unit` is preserved as-stored — it is. Confirm whether `bloodGlucoseUnit` ever differs across rows for real users.
2. Inside `extractRepresentativeValue`, convert to a canonical unit (mg/dL is the codebase convention — see `StoredSettings.codingGlucoseUnit`). For ISF use the schedule's `unit` to convert items into mg/dL/U; for glucose ranges use the schedule's `unit`; for `GlucoseThreshold` use its own `unit`.
3. Add a test in `TherapySettingHistoryTests.swift` constructing one snapshot with an mmol/L `GlucoseThreshold` and another with mg/dL, asserting the resulting trend has small magnitude (i.e., they're equivalent values, just different units).

**Verify by:** add unit-conversion test cases to `TherapySettingHistoryTests`; run with `xcodebuild test` against the `LoopKit` scheme.

---

### H2. `formatTrendValue` assumes the raw value is mg/dL
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:190-204`

```swift
case .suspendThreshold, .glucoseTargetRange:
    let glucoseUnit = displayGlucosePreference.unit
    if glucoseUnit == .millimolesPerLiter {
        let mmol = HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: value).doubleValue(for: .millimolesPerLiter)
        return String(format: "%.1f", mmol)
    }
    return String(format: "%.0f", value)
```

This explicitly hard-codes "input is mg/dL." If H1 is fixed by canonicalizing to mg/dL, this becomes correct by construction. If H1 is "fixed" by canonicalizing to something else, this becomes wrong. Treat it as the same bug — whatever canonical unit is chosen for the trend pipeline must match here.

**Investigate / fix:** Couple the change with H1. Document the canonical unit at the top of `TherapySettingHistoryFilter.swift` so this view doesn't drift again.

---

### H3. Simulator stub can violate the "newest-first" precondition assumed by the filter
**Files:** `Loop/Loop/View Controllers/StatusTableViewController.swift:1640-1651`, `Loop/Loop/View Controllers/StatusTableViewController.swift:2284-2342`

The provider closure does:

```swift
let realSettings = try await self?.deviceManager.settingsManager.settingsStore.getStoredSettings() ?? []
#if targetEnvironment(simulator)
if realSettings.count < 2 {
    return realSettings + StatusTableViewController.simulatedSettingsHistory()
}
#endif
return realSettings
```

`getStoredSettings()` returns rows sorted by `date DESC` (`LoopKit/LoopKit/SettingsStore.swift:221`). `simulatedSettingsHistory()` is also internally newest-first. But `realSettings + simulated` only stays sorted if the most-recent simulated date is older than the oldest real date. With `realSettings.count < 2`, you typically have a single real entry from "today" and a simulated entry built with `daysAgo(0)` (also today). The two "today" timestamps can land in either order.

`TherapySettingHistoryFilter.filterToChanges` (`LoopKit/LoopKit/TherapySettingHistoryFilter.swift:50-75`) walks the list assuming `allSettings[index - 1]` is *always* more recent than `allSettings[index]`. If that breaks, "more recent" is wrong, deltas reverse sign, and "current" badges land on the wrong row.

**Investigate / fix:** sort the merged array by `date` descending before returning; alternatively, only return `simulatedSettingsHistory()` when `realSettings.isEmpty` so the two never mix.

**Verify by:** in simulator, install the app fresh, open any therapy editor → swipe to history — confirm the "Now" / "Current" badge sits on a sane "today" entry.

---

### H4. `filterToChanges` has an undocumented sort-order precondition
**Files:** `LoopKit/LoopKit/TherapySettingHistoryFilter.swift:50-75`

The function silently assumes its input is sorted newest-first. There is no precondition comment, no assertion, no defensive sort. Production callers happen to be safe (Loop's provider relies on `SettingsStore.getStoredSettings`, which always sorts DESC). But this function is `public`, the typealias `SettingsHistoryProvider` is `public`, and any future caller who passes an oldest-first array gets:
- wrong "current" snapshot,
- delta signs flipped,
- trend `direction` reversed.

**Investigate / fix:** either add `precondition(allSettings.isSortedByDateDescending)` (cheap, debug-only via `assert`), or sort defensively at the entry point. Add a doc comment on the public function.

---

## Medium-severity

### M1. Editors for *every* therapy setting now get wrapped in a paged `TabView`
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingsView.swift:448-456, 639-661`

```swift
EditorWithHistoryWrapper(
    showHistory: mode == .settings && viewModel.settingsProvider != nil,
    therapySetting: therapySetting,
    settingsProvider: viewModel.settingsProvider,
    editor: screen(for: therapySetting, dismiss: dismiss).environment(\.dismissAction, dismiss)
)
```

The branch name is `feature-basal_therapy_history`, but the gate triggers for **every** therapy setting (basal, carb ratio, ISF, target range, suspend threshold, delivery limits, insulin model, pre-meal override, workout override). Each editor — many of which already contain their own scroll views, schedule editors, save toolbars — gets a horizontal-swipe paged `TabView` with a page-dot index indicator at the bottom (`.indexViewStyle(.page(backgroundDisplayMode: .always))`).

Concerns:
- Confirm intended scope — basal-only or all settings.
- Page dots may sit on top of bottom toolbars or "Save" buttons.
- Horizontal swipe from inside a schedule editor may now register as a page change instead of returning to a parent.

**Investigate / fix:** confirm intent with the author. If basal-only, gate on `therapySetting == .basalRate`. If all-settings, manually QA each editor on device for the bottom-bar overlap and gesture conflicts.

---

### M2. Unbounded history fetch on view appear
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:799-817`, `LoopKit/LoopKit/SettingsStore.swift:203-234`

```swift
private func loadHistory() async {
    ...
    let allSettings = try await provider()
    let changes = TherapySettingHistoryFilter.filterToChanges(allSettings, for: therapySetting)
    ...
}
```

Loop's provider calls `getStoredSettings()` with no `start`/`end`/`limit`. `SettingsStore` writes a row whenever therapy settings change (audit how often that happens — likely many per day during onboarding/troubleshooting plus background updates from algorithm decisions). On a long-running install this could be thousands of rows decoded on every editor open and held in `@State` for the lifetime of the view.

`testFilterToChanges_largeDataset_completesQuickly` covers 500 entries in pure-Swift filter time, but doesn't measure CoreData fetch + JSON decode time, which dominates.

**Investigate / fix:** decide on a window. A year of data is plausibly enough — pass `start: Calendar.current.date(byAdding: .year, value: -1, to: Date())`. Or apply `limit:` and document the trade-off.

**Verify by:** instrument the call site with a `signpost` and run on device with a multi-month history.

---

### M3. Percent change can blow up at small magnitudes
**Files:** `LoopKit/LoopKit/TherapySettingHistoryFilter.swift:120-121`

```swift
guard oldest.value != 0 else { return nil }
let percentChange = ((newest.value - oldest.value) / oldest.value) * 100
```

The guard catches exact zero but not "tiny." A schedule with a single-segment 0.025 U/hr basal that bumps to 0.5 yields percentChange ≈ 1900%, which then drives both the banner ("increased 1900% over 30 days") and the cutoff at line 133 (`abs(percentChange) < 2`). Real-user data is unlikely to hit this for basal but is plausible for `extractRepresentativeValue` outputs that include zeros (e.g., a target range midpoint can't be near zero, but a carb ratio in mid-conversion edits could be).

**Investigate / fix:** introduce a magnitude floor or clamp. Alternatively, fall back to "fluctuating" when `oldest.value` is below some setting-specific epsilon.

---

### M4. Inconsistent averaging strategy across settings
**Files:** `LoopKit/LoopKit/TherapySettingHistoryFilter.swift:153-173`

- `.basalRate` uses `BasalRateSchedule.total()` — time-weighted (correct).
- `.carbRatio`, `.insulinSensitivity`, `.glucoseTargetRange` use `items.value.reduce(0, +) / count` — simple, **un-weighted** mean.

A schedule with one segment 00:00–07:00 @ 10 g/U and another 07:00–24:00 @ 8 g/U has true daily average ≈ 8.58 g/U, but the code reports 9.0. If the user later splits the schedule into three equal segments without changing actual delivery, the unweighted mean shifts even though the patient's metabolism didn't.

**Investigate / fix:** compute weighted average using segment durations, mirroring `total()`. Add a regression test that varies cut-points without changing total daily exposure and asserts trend stays `.stable`.

---

### M5. Date formatting ignores user locale and recreates `DateFormatter` per call
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:906-921`

```swift
private static let timeOfDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"   // hardcoded 12-hour, English AM/PM
    return f
}()

private func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()       // allocated every call
    formatter.dateFormat = "MMM d"        // fixed month-day order
    return formatter.string(from: date)
}
```

- `"h:mm a"` is wrong in 24-hour locales (most of Europe).
- `"MMM d"` is wrong order for many locales (`d MMM` is more common in EU).
- `shortDate` is invoked from inside view bodies (`comparisonColumnHeaders`, `timelineSection`), so a fresh `DateFormatter` is built each layout pass — `DateFormatter` init is expensive.

**Investigate / fix:** use `dateStyle`/`timeStyle` instead of `dateFormat`. Cache the formatter in a `static let` like `timeOfDayFormatter` already is.

---

### M6. Localization-unfriendly format strings
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:184-186, 624, 703`

Several `String(format:)` callers use multiple positional `%@` / `%d` placeholders without positional indices. Example:

```swift
String(format: LocalizedString("%@ %@ → %@ %@ (%+.0f%%) across %d changes.", ...),
       formatTrendValue(trend.oldestValue), unit,
       formatTrendValue(trend.newestValue), unit,
       trend.percentChange, trend.dataPoints)
```

Translators cannot reorder these without breaking argument alignment. Use `%1$@`, `%2$@`, etc.

**Investigate / fix:** add positional indices to every format string with two or more placeholders.

---

### M7. `relativeDate` reads `Date()` per call from inside view bodies
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:926-949`

The "Today / Yesterday / N days ago / N weeks ago / N months ago" helper:
- captures `Date()` on each call, so a long-displayed view will quietly go stale (yesterday becomes "2 days ago" only on next layout pass);
- builds its own pluralization, missing locale plural rules (e.g., Russian, Polish).

**Investigate / fix:** consider `RelativeDateTimeFormatter` (handles locale plurals); for tests, accept a `now: Date` parameter so behavior is deterministic.

---

## Low-severity / quality

### L1. Dead code: `ScheduleMiniChart`
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:953-990`

Defined, never referenced. `grep -n "ScheduleMiniChart"` in that file returns one hit — the declaration. Delete or wire it up.

### L2. Dead code: `formatGlucoseValueShort`
**Files:** `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:876-878`

```swift
private func formatGlucoseValueShort(_ value: Double) -> String {
    formatGlucoseValue(value)
}
```

A no-op wrapper. Either inline the call sites or differentiate the function. Currently the only caller is `timelineValueSummary` for ISF.

### L3. "Two-pass" branch in `filterToChanges` is dead under any transitive `Equatable`
**Files:** `LoopKit/LoopKit/TherapySettingHistoryFilter.swift:67-72`

```swift
if result.count == 1 && allSettings.count > 1 {
    let oldest = allSettings.last!
    if settingChanged(from: result[0].settings, to: oldest, for: therapySetting) {
        result.append(TherapySettingChange(date: oldest.date, settings: oldest))
    }
}
```

`result.count == 1` means every adjacent pair compared equal. Under transitive `Equatable`, that implies first == last too, so this branch never appends. Either delete it, or add a comment explaining what non-transitive case it's hedging (and add a test that exercises it).

### L4. Tests don't cover the unit-conversion paths
**Files:** `LoopKit/LoopKitTests/TherapySettingHistoryTests.swift`

All glucose-related tests construct `mgdL` thresholds/schedules. None construct an mmol/L `GlucoseThreshold` or schedule. As a consequence, H1 / H2 are invisible to CI. Add coverage when fixing H1.

### L5. Misleading test name
**Files:** `LoopKit/LoopKitTests/TherapySettingHistoryTests.swift:523-532`

`testAnalyzeTrend_tighteningGlucoseRange_detectedAsDecreasing` — the range *width* is constant 10 across all three points; only the midpoint moves. The assertion is correct (midpoint trend is decreasing) but the name implies "the range is getting narrower," which is false. Rename to e.g. `testAnalyzeTrend_loweringGlucoseTargetMidpoint_detectedAsDecreasing`.

### L6. Duplicated simulator fixture
**Files:** `Loop/Loop/View Controllers/StatusTableViewController.swift:2284-2342`, `LoopKit/LoopKitUI/Views/Settings Editors/TherapySettingHistoryView.swift:1004-1042`

Two near-identical generators of fake stored settings for previewing/simulating. They differ in count (20 vs. 25), in cadence (`daysAgo(i*4)` vs. `daysAgo(i*3)`), and in fields populated. If only one is the source of truth for the screenshot/preview UX, delete the other; if both are intentional, share via `LoopKitTestingKit` so changes don't drift.

### L7. UUID syncIdentifier could foot-gun future tests
**Files:** Tests use `StoredSettings(...)` defaults across the file.

`StoredSettings: Equatable` is synthesized over all stored properties including `syncIdentifier: UUID = UUID()` — so `let a = StoredSettings(); let b = StoredSettings()` are not equal even with identical other fields. The current tests never compare `StoredSettings` directly (only specific schedule fields), so this is fine today. Worth a one-line note in the test file as a reader hint, since it's surprising.

---

## Suggested triage order
1. **H1 / H2** — wrong numbers under unit changes. One coupled fix.
2. **H3** — simulator-only ordering bug; small fix, prevents debugging confusion.
3. **H4** — sort-order doc + assertion; tiny.
4. **M1** — confirm intent of all-vs-basal scope before merging.
5. **M2** — bound the fetch.
6. Cleanups L1 / L2 / L5 — cheap wins.
7. **M3 / M4 / M5 / M6 / M7** — robustness/locale polish.

## How to verify the patch set
- `xcodebuild -workspace LoopWorkspace.xcworkspace -scheme LoopKit test` for filter/trend changes.
- Manual QA on simulator: open every therapy-setting editor, swipe to history, change displayGlucosePreference, re-enter, confirm trend banner numbers stay sane.
- On a development device with multi-month history, time `loadHistory()` before/after M2.
