# Chadwick XC Training App — developer notes

See [README.md](README.md) for what this project is, how to run it, current state, and roadmap. See [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md) for the upload contract.

This file covers things that aren't obvious from reading the code.

## Tech stack

- Flutter 3.44, Dart 3.x
- `health` ^13.3.1 (Health Connect on Android, HealthKit on iOS)
- `http` ^1.6.0
- `shared_preferences` ^2.5.5 — auth token, onboarding state, the automatic-upload toggle, the set of workout UUIDs already uploaded, and the last background-sync outcome. The **server** stays the source of truth for what's been uploaded (`GET /me/last-sample-time`; route dedup via `GET /routes`) — the local UUID set is a cache that's dropped whenever the server reports no data.
- `workmanager` ^0.9.0 — Android periodic background sync (iOS uses native BGTasks instead)
- `flutter_map` ^7.0.2 + `latlong2` — OpenStreetMap route rendering on the run detail page
- `geolocator` — only for `Geolocator.distanceBetween` (route distance math)
- Kotlin on Android, Swift on iOS, minSdk 28

## App structure

- `lib/main.dart` — all UI: onboarding, the Home / Schedule / Runs / Settings tabs, run detail, debug tools. Tab records carry both a `label` (bottom bar) and a `title` (app bar); they differ only on Home, captioned "Home" but titled "Chadwick XC Training"
- `lib/sync_service.dart` — the sync engine. **No widgets or BuildContext**, because background isolates run it too; progress comes back through an `onProgress` callback and a `SyncResult`
- `lib/background_sync.dart` — headless entrypoints + scheduling (see below)
- `lib/auth_service.dart` — sign-in and JWT persistence
- `lib/training_week.dart` — weekly mileage bucketing and chart, deliberately free of `health` types so it unit tests without a device

## Background sync

Both platforms wake a **headless Dart isolate** — no widgets, no `BuildContext` — that runs `runBackgroundSyncBody()`, which shares `SyncService` with the foreground app so the two can't drift. Both are gated on the same automatic-upload toggle (`autoSyncPrefsKey`) the user sets during onboarding.

- **Android:** `Workmanager().initialize(workManagerCallbackDispatcher)` in `main()` (Android only), then `registerPeriodicTask`. **15 minutes is WorkManager's floor** — the actual cadence is longer and OEM-dependent. Verify scheduling with `adb shell dumpsys jobscheduler | grep -A5 xctraining`; note that force-running via `cmd jobscheduler run` fails on some Pixels, which is a device limitation, not an app bug.
- **iOS:** `AppDelegate.swift` registers a `BGAppRefreshTask` *and* a HealthKit workout observer (immediate wake when a workout is saved). iOS grants the refresh task on its own schedule — typically hours. The Dart side must report back over the `xctraining/background_sync` channel before iOS's ~30s budget expires.

Two things that bite:

- **`DartPluginRegistrant.ensureInitialized()` is required** in every headless entrypoint, or the `health` / `shared_preferences` channels silently do nothing.
- **`prefs.reload()` before reading anything a background isolate wrote.** `SharedPreferences` caches in-process, so the UI isolate won't see out-of-process writes without it — this is why "Last Background Sync" once showed "never" right after a sync that had demonstrably succeeded.

Background runs are otherwise invisible, so every attempt records its outcome to `lastBackgroundSyncPrefsKey` for the debug page to display.

## Coding conventions

- `dart format` clean, `flutter analyze` must pass
- Prefer simple, readable code over clever abstractions
- Surface errors to the user on screen — never silently swallow
- Comment only when the "why" is non-obvious

## Server config

Both `_serverBase` and `_googleServerClientId` in `lib/main.dart` are read from `--dart-define`s at build time:

```
flutter run --dart-define-from-file=config/dev.json -d <device-id>
```

`config/dev.json` is per-developer and gitignored; copy `config/dev.json.example` to start. The defaults (when no flag is passed) are `http://10.0.2.2:8000` (the Android emulator's alias for the host's localhost) and an empty Google client ID (Google Sign-In disabled, dev-login still works).

To stamp the build with its source commit (shown on the Debug page as `Build: <hash>`), add `--dart-define=GIT_COMMIT=$(git rev-parse --short HEAD)` to the build/run command — append `-dirty` yourself if the tree isn't clean. Without it the field reads `dev`.

**The shared server runs at `https://xc-server.duckdns.org`** — reachable from any network, valid TLS, no tunnels needed. Use it unless you're developing against a local server.

For a *local* server: from the emulator use `http://10.0.2.2:8000`; from a physical phone either `adb reverse tcp:8000 tcp:8000` + `http://127.0.0.1:8000` (USB) or the host's LAN IP with the server bound to `0.0.0.0`. Local HTTP only works because the Android manifest allows cleartext traffic (`android:usesCleartextTraffic="true"`) and iOS has a dev-only `NSAllowsArbitraryLoads` exception in `ios/Runner/Info.plist` — both can be removed once local HTTP dev is no longer needed.

## Team schedule

The **Schedule tab** shows upcoming practices and meets, read from a Google Calendar **iCal feed** — `lib/schedule_service.dart`. The URL comes from `--dart-define=SCHEDULE_ICS_URL=...` (in `config/dev.json`); **empty removes the tab entirely**, so the app is fully usable without it.

Because that tab comes and goes — as does Debug in release builds — **tab positions are not fixed**. Resolve them with `_indexOfTab('runs')` rather than hardcoding an index; a stale literal silently navigates to the wrong page.

The tab renders one card per week, collapsing repeats *within* a week onto one row (`groupByWeek` + `compactDayLabel`): a Mon–Thu practice block is one line, not four. Grouping deliberately never merges across weeks, so a mid-season schedule change reads as a distinct week instead of folding into the one before it.

Get the URL from Google Calendar → hover the calendar → **Settings and sharing** → **Integrate calendar**:

- **Public address in iCal format** — requires making the calendar public.
- **Secret address in iCal format** — works on a private calendar, but the URL *is* the credential: anyone holding it can read the calendar, and it ships inside the app binary where it's trivially extractable. Prefer the public address, or move the fetch server-side (`GET /schedule`) if the schedule is ever sensitive.

Why iCal and not the Calendar API: the schedule is identical for every athlete, so per-user OAuth buys nothing and would pull in `calendar.readonly` — a **sensitive** scope in Google's classification, which gates publishing behind app verification. The cost is that **Google refreshes the published feed lazily**, so calendar edits can take hours to appear. Accepted deliberately: the coach announces changes by email/in person.

Two things that aren't obvious:

- **Recurring events must be expanded.** The feed stores one VEVENT plus an `RRULE` ("weekly, Mon–Fri, until Oct 31"), *not* one entry per practice. Code that just iterates the file's events shows a single practice and looks like it merely has no data — it fails silently, which is why `expandRecurrence()` carries the test coverage it does. `EXDATE` (a cancelled practice) and `RECURRENCE-ID` (a single occurrence moved) are the same trap one level down.
- **`TZID` times are read as local wall-clock.** Resolving them properly needs a full tz database; not worth the dependency for a team whose phones share the calendar's timezone. `Z`-suffixed times convert exactly. Occurrences are rebuilt from calendar fields rather than by adding a `Duration`, so a DST change mid-season can't drift practice by an hour.

Supported rules: `DAILY`, `WEEKLY` (with `BYDAY`), `MONTHLY`, `YEARLY`, each with `INTERVAL` / `COUNT` / `UNTIL`. Positional forms (`BYDAY=2TU`, "second Tuesday") deliberately fall back to a single occurrence rather than emitting wrong dates.

**"Hide past events"** (Settings; `hide_past_events`, defaults on) drops finished practices and meets via `dropPastEntries`. It filters **whole entries, never individual occurrences** — a Mon–Wed block still reads "Mon–Wed" on Wednesday and disappears only on Thursday. Trimming occurrence-by-occurrence would relabel it mid-week ("Tue–Wed", then "Wed"), which reads as the coach having changed the schedule rather than as time passing. This is also why `lookbehind` is a **full week** rather than a day: the earlier occurrences must stay in the parse window for the label to hold its shape.

The last good feed body is cached in `shared_preferences` so the schedule survives no connectivity; the UI labels it as a saved copy rather than passing it off as live.

## Auth

Every request to the server needs `Authorization: Bearer <jwt>`. Two ways to get one:

1. **Google Sign-In** (`POST /auth/google`) — exchanges a Google ID token for the server JWT. Requires the Google Cloud Console setup below.
2. **Dev login** (`POST /auth/dev-login`) — accepts any email and issues a JWT. Only available when the server is run with `DEV_MODE=true`. No Cloud Console setup needed.

The token is persisted in `shared_preferences` and replayed on every sync. 401 responses drop the token and force the user back to the sign-in card. See `lib/auth_service.dart`.

### Google Sign-In setup (one-time per project)

1. Open the [Google Cloud Console](https://console.cloud.google.com/), create or select a project, and enable the **Identity Services API**.
2. **OAuth consent screen** → set up an "External" consent screen (Internal works only inside a Google Workspace org). Required scopes: `openid`, `email`, `profile`.
3. **Credentials** → **Create credentials** → **OAuth client ID**, once per platform:
   - **Web application** — this is the *audience* the server validates ID tokens against. Copy its client ID into `config/dev.json` as `GOOGLE_SERVER_CLIENT_ID` and tell the server about it too.
   - **Android** — package name `com.github.codingwithwarren.xctraining`, SHA-1 of the keystore you sign with. Get the debug SHA-1 with `keytool -list -v -keystore "%USERPROFILE%/.android/debug.keystore" -alias androiddebugkey -storepass android -keypass android`. Add the release SHA-1 once you have a release keystore.
   - **iOS** — bundle ID `com.github.codingwithwarren.xctraining`. Put its client ID into `ios/Runner/Info.plist` as `GIDClientID`, and add the **reversed** client ID (`com.googleusercontent.apps.<id>`) as a URL scheme under `CFBundleURLTypes` so the sign-in callback returns. The iOS client is separate from the web client passed as `serverClientId`.
4. Add test users on the OAuth consent screen until you publish the app — Google rejects sign-ins from accounts that aren't listed during the "Testing" phase.

The `google_sign_in` package (v7+) uses Android's Credential Manager API under the hood, so no `google-services.json` is required — just the OAuth client IDs registered above.

**The ID token's `aud` differs by platform.** On Android it's the *web* client ID; on iOS it's the *iOS* client ID — the GoogleSignIn-iOS SDK always stamps the app's own client ID, and `serverClientId` only produces a `serverAuthCode`, not a different audience. So the server must accept **any** of the project's client IDs as a valid audience, not a single pinned value, or iOS sign-ins fail with `401 "Google token audience mismatch"`. See [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md) "Auth".

## Android / Health Connect gotchas

These bit us during development and aren't obvious from the code:

- `MainActivity` must extend `FlutterFragmentActivity`, not `FlutterActivity`. The `health` package's permission launcher uses `registerForActivityResult()` which needs a `ComponentActivity`.
- `Health().configure()` must be called before any other health operations — it registers the permission launcher. Without it you get "Permission launcher not found".
- Use `Health().hasPermissions()` on startup; don't force re-grant every launch.
- **Total vs Active calories are separate Health Connect permissions.** The `health` package's workout reader internally queries `TotalCaloriesBurnedRecord`, so the manifest needs `READ_TOTAL_CALORIES_BURNED` even though our Dart code uses `HealthDataType.ACTIVE_ENERGY_BURNED`. Without it, workout reads silently return empty (the package swallows the SecurityException).
- **Fitbit doesn't always write `ExerciseSessionRecord` for activities it tracks** — treadmill sessions in particular show up only as raw HR + step streams. This is why the server detects sessions from raw signals instead of trusting the explicit workouts list.
- Pixel Pro Fold has two displays. To screenshot the right one via adb: `screencap -p -d <display-id>`. To keep the screen on during dev: `adb shell settings put global stay_on_while_plugged_in 7`.

## iOS / HealthKit gotchas

Building for Apple needs the full **Xcode** app (not just Command Line Tools) plus **CocoaPods**. After `flutter pub get`, run `pod install` in `ios/` if pods drift.

- **Signing:** a free Apple ID works for on-device dev (7-day builds), but the team needs a **registered device** — connect the iPhone *before* Xcode can issue a provisioning profile (otherwise "your team has no devices"). Set the team + toggle the **HealthKit** capability in Xcode → Runner target → Signing & Capabilities; the entitlement file (`ios/Runner/Runner.entitlements`) is already wired. TestFlight/App Store needs the paid Developer Program.
- **Deployment target is iOS 14** (the `health` plugin's floor). It's set in both the `Podfile` and the Xcode project — keep them in sync.
- **The `health` plugin uses CocoaPods, not Swift Package Manager** (you'll see a warning saying so); the other plugins use SPM. Both are integrated.
- **Debug builds crash instantly when launched from the home screen** on iOS 26 ProMotion devices — a null deref in `VSyncClient` / `createTouchRateCorrectionVSyncClientIfNeeded` ([flutter#183900](https://github.com/flutter/flutter/issues/183900)). It's a Flutter engine bug for *untethered debug* launches, **not** an app bug. **Test with release builds**, which is also how TestFlight runs.
- **Install/launch with `flutter build` + `devicectl`, not `flutter run`** — the latter's launch step is flaky on Xcode 26 ("Timed out waiting for CONFIGURATION_BUILD_DIR"). The **phone must be unlocked** for the launch step (otherwise "device was not, or could not be, unlocked"); set Auto-Lock → Never during dev.
  ```
  flutter build ios --release --dart-define-from-file=config/dev.json
  xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
  xcrun devicectl device process launch --device <udid> com.github.codingwithwarren.xctraining
  ```
- **HealthKit usage strings** live in `ios/Runner/Info.plist` (`NSHealthShareUsageDescription`; the app only reads, so there's no Update key). A missing string crashes the app the moment it requests authorization.
- **"Workout Routes" is its own HealthKit read permission**, defaults OFF, and **iOS never reveals read-permission status to the app** — a denied route permission just returns empty, silently. If routes don't show, check Settings → Privacy & Security → Health → Chadwick XC Training → Workout Routes is on. Routes only exist for outdoor GPS workouts (indoor workouts have none).
- **No separate route-consent step on iOS.** Health Connect needs one (via the Android-only `xctraining/route_access` method channel in `MainActivity.kt`); HealthKit covers routes with the standard permission. So onboarding is **2 steps** on iOS (health → auto-upload) vs 3 on Android.
- **App Transport Security blocks cleartext HTTP** — see "Server config" for the dev-only `NSAllowsArbitraryLoads` + `NSLocalNetworkUsageDescription` in `Info.plist`.
