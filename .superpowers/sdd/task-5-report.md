# Task 5 Report: SimClient actor + SimDriving protocol

## Root Cause of the Hang

`StubHTTPServer.make()` wired `listener.newConnectionHandler` AFTER calling `listener.start(queue:)` and waiting for `.ready` via `DispatchSemaphore`. By the time `newConnectionHandler` was assigned (inside the `private init`), the listener was already in the `.ready` state and accepting TCP connections. With `NWListener`, incoming connections while `newConnectionHandler` is `nil` are silently dropped at the framework level — no error, no callback. The test's `SimClient(baseURL:)` used `URLSession.shared` (default 60 s request timeout), so each of the 3 tests hung for 60 s waiting for a response that never came (3 × 60 s = 180 s hang).

## Fix

### StubHTTPServer (test file)

Restructured `make()` into a true single-phase init:

1. `NWListener` is created.
2. A `StubHTTPServer` instance is constructed immediately (with `port: 0` placeholder).
3. `listener.newConnectionHandler` is wired to the server **before** `listener.start()`.
4. `listener.stateUpdateHandler` (semaphore) is also wired before `start()`.
5. `listener.start(queue:)` is called — connections can now arrive safely because the handler is already set.
6. `sem.wait()` blocks until `.ready`, then `portNumber` is read from `listener.port`.

The `port` stored property was replaced with a computed `portNumber: UInt16` that reads from the live `listener.port` after `.ready` fires.

### SimClient (production file)

The test-only `init(baseURL:)` was changed from using `URLSession.shared` (60 s timeout) to a private `URLSessionConfiguration.ephemeral` with `timeoutIntervalForRequest = 10`. This means a misbehaving stub fails fast (10 s) rather than hanging the suite for 60 s per test — a defense-in-depth measure, not the primary fix.

## Test Output

```
Test Suite 'SimClientTests' passed at 2026-08-12 08:06:07.273.
     Executed 3 tests, with 0 failures (0 unexpected) in 0.045 (0.045) seconds
```

All 3 tests pass in **45 ms** total (previously hung >8 minutes).

Full suite: **200 tests, 0 failures**.
