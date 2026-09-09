#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds YH, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "YH (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
    esac
done

if (( DEV )); then
    APP_NAME="YH (Developer)"
    EXECUTABLE="YHDeveloper"
    APP_BUNDLE_ID="com.mansoury703.yh.dev"
    BUILD_VARIANT_FLAGS=(-D YH_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="YH"
    EXECUTABLE="YH"
    APP_BUNDLE_ID="com.mansoury703.yh"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libYHNowPlaying.dylib"
TARGET="arm64-apple-macosx14.0"
ENTITLEMENTS="Resources/YH.entitlements"
LEGACY_IDENTITY="YH Utils Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p yh-signing \
        "$HOME/Library/Keychains/yh-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
if (( DEV || INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; creating the stable local one…"
    if ! ./Tools/setup-signing.sh; then
        echo "  ⚠ Tools/setup-signing.sh failed; signing ad-hoc instead." >&2
        echo "    Accessibility and Screen Recording grants will not survive rebuilds:" >&2
        echo "    System Settings will show them as granted while the app is not trusted." >&2
        echo "    After fixing the identity, clear the stale grant once with:" >&2
        echo "      tccutil reset Accessibility $APP_BUNDLE_ID" >&2
    fi
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${YH_INSTALL_CHILD:-0}" != "1" ]]; then
    YH_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `MetricsTests` keeps every suite name inside these two namespaces (a
# check in the test file holds it to that), which is what makes this sweep
# complete rather than a list to keep in step by hand.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "vorss.tests." "com.mansoury703.yh.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "vorss.tests.*.plist" -o -name "com.mansoury703.yh.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# --test: compile and run the standalone unit tests (pure helpers only: metrics,
# Homebrew parsing, defaults, localization contracts; no app, no UI, no IOKit),
# then exit. Fast and deterministic; no XCTest needed.
if (( TEST )); then
    echo "▸ Building & running unit tests against $(basename "$SDK")…"
    rm -rf build
    mkdir -p build
    # The full app build below remains optimized and is the optimizer gate.
    # Unit assertions do not need optimization; avoiding it cuts most of the
    # test harness compile time without reducing the code the tests exercise.
    swiftc -Onone -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" \
        Sources/YH/Services/Media/MediaSupport.swift \
        Sources/YH/Core/QuitProtectionSupport.swift \
        Sources/YH/Core/QuitProtectionStrings.swift \
        Sources/YH/Core/Defaults.swift \
        Sources/YH/Core/FeatureCatalog.swift \
        Sources/YH/Core/FeaturePresets.swift \
        Sources/YH/Core/FeatureHubStrings.swift \
        Sources/YH/Core/ShortcutSettingsStrings.swift \
        Sources/YH/Core/SettingsBackupSupport.swift \
        Sources/YH/Core/BackupStrings.swift \
        Sources/YH/Core/SnippetStrings.swift \
        Sources/YH/Core/BrightnessStrings.swift \
        Sources/YH/Core/MediaImageStrings.swift \
        Sources/YH/Core/QuickToggleStrings.swift \
        Sources/YH/Core/ScreenshotStrings.swift \
        Sources/YH/Core/RecentCaptureStrings.swift \
        Sources/YH/Core/RecorderStrings.swift \
        Sources/YH/Core/RecorderShareStrings.swift \
        Sources/YH/Core/CameraPreviewStrings.swift \
        Sources/YH/Core/ScratchpadStrings.swift \
        Sources/YH/Core/FinderRenameStrings.swift \
        Sources/YH/Core/CommandBarStrings.swift \
        Sources/YH/Core/FeedbackStrings.swift \
        Sources/YH/Core/RadialMenuStrings.swift \
        Sources/YH/Core/MenuBarAppearanceStrings.swift \
        Sources/YH/Core/AppAppearance.swift \
        Sources/YH/Core/AppearanceStrings.swift \
        Sources/YH/Core/BatteryTimeStrings.swift \
        Sources/YH/Core/KeepAwakeStrings.swift \
        Sources/YH/Core/BluetoothSleepStrings.swift \
        Sources/YH/Core/PermissionGuideStrings.swift \
        Sources/YH/Core/FanControlStrings.swift \
        Sources/YH/Services/FanControl/FanControlSupport.swift \
        Sources/YH/Services/Snippets/TextSnippetSupport.swift \
        Sources/YH/Services/RadialMenu/RadialMenuSupport.swift \
        Sources/YH/Services/QuickTools/ScratchpadSupport.swift \
        Sources/YH/Services/QuickTools/ScratchpadStore.swift \
        Sources/YH/Services/KillProcess/KillProcessSupport.swift \
        Sources/YH/Services/Recorder/RecorderSupport.swift \
        Sources/YH/Services/Recorder/RecordingSharingSupport.swift \
        Sources/YH/Services/PrivateFileStore.swift \
        Sources/YH/Services/Recorder/RecorderTakeStore.swift \
        Sources/YH/Services/Recorder/RecorderPresetImageStore.swift \
        Sources/YH/Services/Recorder/RecorderMotion.swift \
        Sources/YH/Services/Recorder/RecorderPointerTrack.swift \
        Sources/YH/Services/Recorder/RecorderTypingTrack.swift \
        Sources/YH/Services/Recorder/RecorderTimeline.swift \
        Sources/YH/Services/Recorder/RecorderTextOverlay.swift \
        Sources/YH/Services/Recorder/RecorderImageOverlay.swift \
        Sources/YH/Services/Recorder/RecorderBlurRegion.swift \
        Sources/YH/Services/Recorder/RecorderEditDocument.swift \
        Sources/YH/Core/AppInfo.swift \
        Sources/YH/Core/GlobalShortcut.swift \
        Sources/YH/Core/SymbolicHotKeys.swift \
        Sources/YH/Services/SystemShortcutTakeoverSupport.swift \
        Sources/YH/Core/Localization.swift \
        Sources/YH/Core/Localizations/Strings+*.swift \
        Sources/YH/Core/FeatureStrings.swift \
        Sources/YH/Core/KillProcessStrings.swift \
        Sources/YH/Core/WhatsAppDownloadStrings.swift \
        Sources/YH/Core/WhatsAppOrganizerStrings.swift \
        Sources/YH/Core/ReleaseNotes.swift \
        Sources/YH/Core/URLCleaning.swift \
        Sources/YH/Services/GeneralPasteboardAccess.swift \
        Sources/YH/Services/Audio/MixerRoutingSupport.swift \
        Sources/YH/Services/Audio/MusicLaunchSupport.swift \
        Sources/YH/Services/Bluetooth/BluetoothSleepSupport.swift \
        Sources/YH/UI/MenuPanel/MixerPercentNativeTextField.swift \
        Sources/YH/Services/Audio/BoostLimiter.swift \
        Sources/YH/Services/Audio/MixerRender.swift \
        Sources/YH/Services/Audio/PreciseVolumeRollerSupport.swift \
        Sources/YH/Services/DockPreview/DockPreviewSupport.swift \
        Sources/YH/Services/Homebrew/HomebrewSupport.swift \
        Sources/YH/Services/AppUpdates/AppUpdatesSupport.swift \
        Sources/YH/Services/AppUpdates/AppUpdateFeedSupport.swift \
        Sources/YH/Core/AppUpdateStrings.swift \
        Sources/YH/Core/DiskImageInstallerStrings.swift \
        Sources/YH/Services/DiskImageInstaller/DiskImageInstallerSupport.swift \
        Sources/YH/Services/Clipboard/ClipboardHistorySupport.swift \
        Sources/YH/Services/Clipboard/ClipboardAutoClearSupport.swift \
        Sources/YH/Services/AutoQuit/AutoQuitSupport.swift \
        Sources/YH/Services/Shelf/ShelfSupport.swift \
        Sources/YH/Services/Finder/FinderRenameSupport.swift \
        Sources/YH/Services/Update/UpdateInstallerSupport.swift \
        Sources/YH/Services/Update/UpdateServiceSupport.swift \
        Sources/YH/Services/InstalledApps.swift \
        Sources/YH/Services/LaunchAtLoginSupport.swift \
        Sources/YH/UI/Settings/SettingsSearchSupport.swift \
        Sources/YH/UI/Settings/FeatureVisibilitySupport.swift \
        Sources/YH/App/MenuBarSpacingSupport.swift \
        Sources/YH/App/StatusItemAnchorSupport.swift \
        Sources/YH/Services/DockClick/DockClickSupport.swift \
        Sources/YH/Services/Finder/CutPasteProgressSupport.swift \
        Sources/YH/Services/Finder/CutPastePrivilegeSupport.swift \
        Sources/YH/Services/Finder/FinderPasteImageSupport.swift \
        Sources/YH/Services/MiddleClick/MiddleClickSupport.swift \
        Sources/YH/Services/MouseNavigation/MouseNavigationSupport.swift \
        Sources/YH/Services/MouseButtons/MouseButtonShortcutSupport.swift \
        Sources/YH/Services/MouseButtons/MouseSpacesGestureSupport.swift \
        Sources/YH/Services/MouseClickDebounce/MouseClickDebounceSupport.swift \
        Sources/YH/Services/MouseExceptions/MouseAppExceptionSupport.swift \
        Sources/YH/Services/MouseExceptions/MouseAppExceptions.swift \
        Sources/YH/Services/WindowServerSupport.swift \
        Sources/YH/Core/MouseButtonStrings.swift \
        Sources/YH/Core/MouseClickDebounceStrings.swift \
        Sources/YH/Core/MouseExceptionStrings.swift \
        Sources/YH/Core/ClipboardIgnoredAppsStrings.swift \
        Sources/YH/Core/WindowPreviewExclusionStrings.swift \
        Sources/YH/Core/DiskExclusionStrings.swift \
        Sources/YH/Core/SwitcherAppRulesStrings.swift \
        Sources/YH/Services/QuickTools/QuickToolsSupport.swift \
        Sources/YH/Services/CommandBar/CommandBarSupport.swift \
        Sources/YH/Services/CommandBar/CommandBarPreferences.swift \
        Sources/YH/Services/CommandBar/CommandBarMath.swift \
        Sources/YH/Services/CommandBar/CommandBarUnits.swift \
        Sources/YH/Services/CommandBar/CommandBarEmoji.swift \
        Sources/YH/Services/CommandBar/CommandBarLinks.swift \
        Sources/YH/Services/CommandBar/CommandBarDates.swift \
        Sources/YH/Services/CommandBar/CommandBarRowShortcuts.swift \
        Sources/YH/Services/CommandBar/CommandBarSystemSettingsSupport.swift \
        Sources/YH/Services/CommandBar/CommandBarFileSearchSupport.swift \
        Sources/YH/Services/CommandBar/CommandBarQueryMemory.swift \
        Sources/YH/Services/SpotlightNamesSupport.swift \
        Sources/YH/Services/QuickTools/MicMuteSupport.swift \
        Sources/YH/Services/QuickTools/QuickTogglesSupport.swift \
        Sources/YH/Services/QuickTools/ScreenshotCapturePolicy.swift \
        Sources/YH/Services/QuickTools/ScreenshotSupport.swift \
        Sources/YH/Services/QuickTools/RecentCaptureStore.swift \
        Sources/YH/Services/QuickTools/ScreenshotSharingSupport.swift \
        Sources/YH/Services/QuickTools/WindowActivationPolicy.swift \
        Sources/YH/Services/KeyboardDebounce/KeyboardDebounceSupport.swift \
        Sources/YH/Services/SuperKey/SuperKeySupport.swift \
        Sources/YH/Services/SuperKey/SuperKeyMappingGuard.swift \
        Sources/YH/Core/SuperKeyStrings.swift \
        Sources/YH/Services/SessionActivity.swift \
        Sources/YH/Services/SessionActivitySupport.swift \
        Sources/YH/Services/ScrollWheelSupport.swift \
        Sources/YH/Services/SmoothScrollSupport.swift \
        Sources/YH/Services/MouseAcceleration/MouseAccelerationSupport.swift \
        Sources/YH/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift \
        Sources/YH/Services/Switcher/SwitcherModels.swift \
        Sources/YH/Services/Switcher/SwitcherSupport.swift \
        Sources/YH/Services/Switcher/SpaceHopSupport.swift \
        Sources/YH/Services/Switcher/WindowUseOrder.swift \
        Sources/YH/Services/Metrics/MetricFormat.swift \
        Sources/YH/Services/Metrics/VMStatisticsDecoder.swift \
        Sources/YH/Services/KeepAwakeAutomationSupport.swift \
        Sources/YH/Services/SudoersSupport.swift \
        Sources/YH/Services/Metrics/BatteryTimeSupport.swift \
        Sources/YH/Services/BoundedProcessRunner.swift \
        Sources/YH/Services/DetachedProcess.swift \
        Sources/YH/Services/ShellSupport.swift \
        Sources/YH/Services/Metrics/NetworkProcessSupport.swift \
        Sources/YH/Services/Metrics/NetworkSampler.swift \
        Sources/YH/Services/Metrics/SpeedTest.swift \
        Sources/YH/Services/Metrics/PeripheralBatterySupport.swift \
        Sources/YH/Services/Metrics/DiskSupport.swift \
        Sources/YH/Services/Metrics/MonitorSamplingPolicy.swift \
        Sources/YH/Services/Metrics/MaxCapacityProbe.swift \
        Sources/YH/Services/Metrics/TemperatureSensorSelector.swift \
        Sources/YH/Services/Metrics/SustainedAlertGate.swift \
        Sources/YH/Services/WindowLayout/WindowLayoutSupport.swift \
        Sources/YH/Services/WindowLayout/WindowGestureSupport.swift \
        Sources/YH/Core/WindowDirectionalStrings.swift \
        Sources/YH/Services/CleaningMode/CleaningUnlockCounter.swift \
        Sources/YH/Services/Display/ExtraBrightnessSupport.swift \
        Sources/YH/Services/Display/BrightnessSupport.swift \
        Sources/YH/Services/Cleaner/CleanerSupport.swift \
        Sources/YH/Services/Cleaner/CleanerPolicy.swift \
        Sources/YH/Services/Cleaner/CleanerSchedule.swift \
        Sources/YH/Services/Uninstall/UninstallerSupport.swift \
        Sources/YH/Services/ManagedDownloads/WhatsAppDownloadSupport.swift \
        Tests/MetricsTests.swift \
        Tests/RecentCaptureStoreTests.swift \
        Tests/RecorderPresetImageStoreTests.swift \
        Tests/SpeedTestTests.swift \
        -o build/metrics-tests
    # `set -e` would end the script on a failing run before the sweep below.
    test_status=0
    ./build/metrics-tests || test_status=$?
    ./Tests/PreferenceCleanupTests.sh || test_status=1
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/YH/**/*.swift)
if (( DEV )); then
    APP_OBJECT_DIR="build/objects/$EXECUTABLE"
    mkdir -p build "$APP_OBJECT_DIR"
    APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -j "$(sysctl -n hw.logicalcpu)" \
        -output-file-map "$APP_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
        "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
else
    rm -rf build
    mkdir -p build
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -target "$TARGET" -sdk "$SDK" \
        "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
fi

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/YH/Services/FanControl/FanControlSupport.swift \
    Sources/YH/Services/FanControl/FanControlXPC.swift \
    Sources/YH/Services/SystemMonitor/SMCClient.swift \
    Sources/YH/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/YH/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name YHNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
# Replace the upstream application artwork with YH's independent icon. The
# upstream generator is still used for neutral menu-bar assets.
YH_ICON_SOURCE="Resources/YHIconSource.png"
for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    filename="${spec#* }"
    sips -z "$size" "$size" "$YH_ICON_SOURCE" \
        --out "build/AppIcon.iconset/$filename" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
sips -z 512 512 "$YH_ICON_SOURCE" --out build/BrandMark.png >/dev/null
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ICON_TMP="$(mktemp -d)"
echo "  YH icon ready (classic macOS icon; adaptive upstream artwork disabled)"
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/com.mansoury703.yh.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mansoury703.yh.dev" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName YH (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName YH (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.mansoury703.yh.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :YHBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :YHFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "YH Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

mkdir -p "build/stage"
BUILD_STAGE="build/stage/$APP_NAME.app"
rm -rf "$BUILD_STAGE"
ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
    if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
        echo "  build/stage copy has local filesystem metadata; temp bundle was verified"
    else
        codesign --verify --deep --strict "$BUILD_STAGE"
    fi
fi
echo "✓ Bundle ready: $BUILD_STAGE"

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    # Remove the pre-rename apps so two menu bar items never coexist. Same bundle
    # id, so macOS keeps the granted permissions for the new bundle.
    for legacy in "Vorss:Vorss" "YH Utils:YHUtils"; do
        name="${legacy%%:*}"; proc="${legacy##*:}"
        if [[ -d "/Applications/$name.app" ]]; then
            stop_process "$proc"
            rm -rf "/Applications/$name.app"
            echo "  (legacy $name.app removed)"
        fi
    done
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
