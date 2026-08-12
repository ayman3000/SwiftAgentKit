### Task 8 Report: Live end-to-end test driving Settings + README

**Status: COMPLETE — all live tests passed, full suite green.**

---

#### What the prior agent had done

- Wrote `Tests/SwiftAgentKitSimulatorTests/SimLiveTests.swift` (untracked, not committed).
- Modified `Sources/SwiftAgentKitSimulator/Resources/SimDriverProject/SimDriverUITests/DriverMain.swift`:
  changed the route-handling call from a direct (non-main-thread) invocation to
  `DispatchQueue.main.sync { self.routes.handle(request) }` to fix a threading
  issue where XCUITest APIs (launch, tap, snapshot, screenshot) must be called
  from the main thread.
- Did NOT commit, did NOT update README, died on an API error.

---

#### What this agent changed

1. **Deleted the stale driver build cache** (`~/Library/Application Support/SwiftAgentKitSimulator/`)
   so the next test run would rebuild from the modified DriverMain.swift source.

2. **Kept the DriverMain.swift main-thread fix as-is.** The `DispatchQueue.main.sync` change
   is correct: the XCUITest runner's run loop spins on the main thread, which is the only thread
   where XCUITest API calls are safe. The connection receive handler runs on a NWConnection
   background queue, so without this dispatch the XCUITest calls would crash or produce
   undefined behavior.

3. **No changes to SimLiveTests.swift.** The test as written by the prior agent passed on the
   first attempt without any label or timeout adaptations.

4. **Added a SwiftAgentKitSimulator section to README.md** (alongside MCP Server Integration),
   covering: what the product is, `makeSimulatorTools` one-call registration, the one-time
   30-60 s driver build note, the table of tools, and the live-test invocation with both env vars.

---

#### Live-test run output (tail)

```
Test Case '-[SwiftAgentKitSimulatorTests.SimLiveTests testDriveSettingsApp]' started.
Test Case '-[SwiftAgentKitSimulatorTests.SimLiveTests testDriveSettingsApp]' passed (28.109 seconds).
Test Suite 'SimLiveTests' passed at 2026-08-12 10:51:12.527.
     Executed 1 test, with 0 failures (0 unexpected) in 28.109 (28.111) seconds
```

Device: iPhone 17 Pro Max (iOS 26.1), UDID CFF8CA53-9F11-42F5-A291-86DDB7129C60 (already booted).
First run included driver build. The 28 s elapsed time covers driver build + all three assertions.

---

#### Full suite (no env vars)

200 tests passed, 0 failures. SimLiveTests was skipped (XCTSkip) as expected because
SAK_LIVE_TESTS and SAK_SIM_TESTS were not set.

---

#### Adaptations and concerns

- **No label adaptations needed.** iOS 26.1 Settings exposes "General" and "About" with those
  exact labels in the accessibility tree. The test's 20 s timeouts were not exercised — the
  elements appeared well within 5 s.
- **Screenshot size.** The PNG returned by the driver was >10 KB and had valid PNG magic bytes;
  no size assertion failures.
- **Threading fix is load-bearing.** Without `DispatchQueue.main.sync`, XCUITest calls from the
  NWConnection receive queue would race with the main thread and could silently corrupt state or
  crash the runner. Keep this fix in any future refactor of DriverMain.swift.
- **Driver build cache.** The build artifact is stored in
  `~/Library/Application Support/SwiftAgentKitSimulator/`. If DriverMain.swift or any driver
  source is changed, the cache must be deleted (`rm -rf`) before re-running live tests;
  otherwise the runner uses the old binary and changes have no effect.
