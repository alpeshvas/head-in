# Deploy Context — indoor-positioning / SurveyRecorder

## Repo summary
- Prototype for phone-only indoor positioning using magnetic fingerprinting + inertial sensors + route/map constraints (`README.md` lines 1-20).
- Main deployable app is the standalone SwiftUI iOS survey recorder under `survey-recorder/`; it records Core Motion/device motion, raw magnetometer, pedometer, barometer, and checkpoint anchors to JSONL files, exportable via Share Sheet / Files app (`README.md` lines 31-46).
- The product/research direction explicitly avoids venue hardware/camera and targets route/checkpoint confidence rather than exact blue-dot GPS (`README.md` lines 62-67; `docs/research-notes.md` lines 148-220).

## App target/context
- Source of truth for project generation: `survey-recorder/project.yml`.
  - Project name `SurveyRecorder`; target `SurveyRecorder`; type `application`; platform `iOS`; sources `SurveyRecorder` (`project.yml` lines 1-15).
  - Bundle prefix: `com.headout.indoorpositioning`; generated bundle id currently resolves to `com.headout.indoorpositioning.SurveyRecorder` (`project.yml` line 3; `SurveyRecorder.xcodeproj/project.pbxproj` lines 216-218, 301-303).
  - iOS deployment target: `17.0` (`project.yml` lines 4-5; `project.pbxproj` lines 191, 275).
  - iPhone-only: `TARGETED_DEVICE_FAMILY = 1` (`project.yml` line 30; `project.pbxproj` lines 219-220, 304-305).
- App entry point: `survey-recorder/SurveyRecorder/SurveyRecorderApp.swift` lines 3-14 creates a SwiftUI `TabView` with `SetupView` and `SessionsView`.
- Setup flow: `SetupView` persists venue/route/floor/direction/device pose/checkpoints with `@AppStorage`; recording can start only with non-empty venue + route and at least 2 checkpoints (`SetupView.swift` lines 3-25, 80-95).
- Recording flow:
  - `SensorRecorder` samples at 100 Hz and conditionally starts device motion, raw magnetometer, pedometer, and altimeter if available (`SensorRecorder.swift` lines 6-60).
  - `RecordingController` writes `dm`, `mag`, `step`, `baro`, `anchor`, `anchor_undo`, and `end` JSONL records, disables idle timer during recording, and re-enables it on stop (`RecordingController.swift` lines 27-119, 127-168).
  - `SessionWriter` writes JSONL files to app Documents `/sessions`, includes metadata/device model/system version, buffers writes, and flushes on anchor/close (`SessionWriter.swift` lines 13-51, 54-81).
  - `SessionsView` lists `.jsonl` files, supports ShareLink export and delete (`SessionsView.swift` lines 3-55).

## Signing/build findings
- `SurveyRecorder.xcodeproj` exists locally but is generated and ignored: README says `xcodegen generate` produces it and then open it to set signing/run on a physical iPhone (`README.md` lines 39-44); `.gitignore` ignores `survey-recorder/SurveyRecorder.xcodeproj/` (`.gitignore` lines 4-5).
- `project.yml` has `CODE_SIGN_STYLE: Automatic`, but no `DEVELOPMENT_TEAM`, no `PRODUCT_BUNDLE_IDENTIFIER` override, no provisioning profile, and no entitlements file (`project.yml` lines 28-35; `find survey-recorder -name '*.entitlements'` found none).
- Current generated local Xcode project does have signing/team settings:
  - `ProvisioningStyle = Automatic` (`project.pbxproj` lines 99-105).
  - Debug target: `CODE_SIGN_IDENTITY = iPhone Developer`, `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = X4JNSD5GJ6`, `INFOPLIST_FILE = SurveyRecorder/Info.plist`, `PRODUCT_BUNDLE_IDENTIFIER = com.headout.indoorpositioning.SurveyRecorder` (`project.pbxproj` lines 202-220).
  - Release target has the same signing/bundle/team settings (`project.pbxproj` lines 287-305).
- Current local CLI build/sign status:
  - `xcodebuild -list -project survey-recorder/SurveyRecorder.xcodeproj` reports target/scheme `SurveyRecorder`.
  - `xcodebuild ... -destination 'generic/platform=iOS' build` succeeded locally and signed with an Apple Development identity + iOS Team Provisioning Profile for `com.headout.indoorpositioning.SurveyRecorder`.
  - Therefore code compilation/signing is not the current local blocker; physical install/launch target availability is.
- Current physical-device CLI blocker:
  - `xcrun devicectl list devices` shows known iPhones as `unavailable`; `xcodebuild -showdestinations` lists no concrete available physical iOS destination, only placeholders/simulators/My Mac.
  - Simulator is not a valid survey target: README explicitly says sensors do not exist on simulator and surveys require a real device (`README.md` line 46); code depends on hardware Core Motion/magnetometer/pedometer/barometer paths (`SensorRecorder.swift` lines 26-60).
- Versioning note: `project.yml` sets `MARKETING_VERSION: 0.1.0` and `CURRENT_PROJECT_VERSION: 1` (`project.yml` lines 34-35), but `Info.plist` currently hardcodes `CFBundleShortVersionString` to `1.0` and `CFBundleVersion` to `1` (`Info.plist` lines 19-22). Not a dev-install blocker, but worth reconciling before distribution.

## Runtime/device capabilities affecting testing
- Permissions / Info.plist:
  - `NSMotionUsageDescription` is present for motion/step/barometer use (`Info.plist` lines 25-26; `project.yml` line 19).
  - File sharing is enabled with `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` (`Info.plist` lines 23-28; `project.yml` lines 20-21).
  - Required capabilities: `magnetometer`, `accelerometer`, `gyroscope` (`Info.plist` lines 31-36; `project.yml` lines 24-27).
  - Portrait-only (`Info.plist` lines 37-40; `project.yml` lines 22-23).
- No location/camera/network/background-mode permissions were found in project/source. Recording is foreground-oriented; app disables idle timer while recording but does not declare background recording (`RecordingController.swift` lines 118-119, 154-168).
- Barometer and pedometer are optional at runtime: app records them only if `CMAltimeter.isRelativeAltitudeAvailable()` / `CMPedometer.isStepCountingAvailable()` (`SensorRecorder.swift` lines 46-59). Barometer is not in `UIRequiredDeviceCapabilities`.

## Deploy checklist — safest path to physical iPhone
1. Connect the intended iPhone by USB or ensure paired wireless debugging; unlock it, trust this Mac, and enable Developer Mode if iOS prompts. Confirm device is iOS 17+.
2. Verify CLI sees it as available: `xcrun devicectl list devices`. Do not proceed with CLI install while the iPhone is `unavailable`.
3. Open `survey-recorder/SurveyRecorder.xcodeproj` in Xcode (README-recommended path). Select target `SurveyRecorder` → Signing & Capabilities.
4. Confirm Automatic signing, Team `X4JNSD5GJ6` (or intended team), and bundle id `com.headout.indoorpositioning.SurveyRecorder`. If Xcode says the bundle id/profile/device is invalid, let Xcode repair/register the device/profile first.
5. Select the physical iPhone destination and Run from Xcode. Accept Motion & Fitness permission on first launch.
6. In app: enter venue ID, route ID, optional floor metadata, direction/device pose, and at least 2 checkpoints; record the route; tap Anchor at each checkpoint; Stop & Save; export from Sessions tab or Files app.
7. After Xcode has made the device available/provisioned, CLI install is reasonable:
   - Build: `xcodebuild -project survey-recorder/SurveyRecorder.xcodeproj -scheme SurveyRecorder -configuration Debug -destination 'platform=iOS,id=<DEVICE_ID>' build`
   - Install/launch the resulting `SurveyRecorder.app` from DerivedData with `xcrun devicectl device install app --device <DEVICE_ID> <path-to-SurveyRecorder.app>` and `xcrun devicectl device process launch --device <DEVICE_ID> com.headout.indoorpositioning.SurveyRecorder`.

## Risks / open questions
- `DEVELOPMENT_TEAM` is present only in the generated, gitignored `.xcodeproj`; regenerating from `project.yml` may drop team signing unless the team is added to `project.yml` or reset in Xcode.
- Current CLI deploy cannot target a real iPhone until one is available/trusted in `devicectl`/Xcode.
- Provisioning profile must include the intended physical device; Xcode is the safest way to repair/register it.
- Simulator can compile/run UI but cannot validate survey data because required sensors are absent/unreliable.
- Device placement and magnetic environment materially affect data quality; code records `devicePose` and live calibration, but field testing should keep pose consistent (`Models.swift` lines 10-24; `RecordView.swift` lines 73-113).
- No background mode: avoid locking/backgrounding the app during recording despite idle timer being disabled.
