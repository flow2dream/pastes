#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"
variant="${2:-development}"
if [[ $# -gt 2 ]]; then
    printf 'Usage: %s [debug|release] [development|production]\n' "$0" >&2
    exit 2
fi
case "$configuration" in
    debug|Debug) configuration=debug; configuration_dir=Debug ;;
    release|Release) configuration=release; configuration_dir=Release ;;
    *) printf 'Usage: %s [debug|release] [development|production]\n' "$0" >&2; exit 2 ;;
esac
case "$variant" in
    development)
        app_name="Pastes Dev"
        bundle_identifier="com.pastes.app.pastes.dev"
        development_build=true
        automatic_checks=false
        output_dir="$project_dir/build/$configuration_dir"
        ;;
    production)
        if [[ "$configuration" != release ]]; then
            printf 'Production applications require the release configuration.\n' >&2
            exit 2
        fi
        app_name="Pastes"
        bundle_identifier="com.pastes.app.pastes"
        development_build=false
        automatic_checks=true
        output_dir="$project_dir/build/Distribution"
        ;;
    *) printf 'Usage: %s [debug|release] [development|production]\n' "$0" >&2; exit 2 ;;
esac

version="$(awk '/MARKETING_VERSION =/ {gsub(/;/, "", $3); print $3; exit}' "$project_dir/pastes.xcodeproj/project.pbxproj")"
build_number="$(awk '/CURRENT_PROJECT_VERSION =/ {gsub(/;/, "", $3); print $3; exit}' "$project_dir/pastes.xcodeproj/project.pbxproj")"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf 'Project marketing and build versions must be nonempty numeric versions.\n' >&2
    exit 2
fi

signing_identity="-"
signing_config="$project_dir/.pastes-signing-identity"
if [[ "${PASTES_SIGN_IDENTITY+x}" == x ]]; then
    signing_identity="$PASTES_SIGN_IDENTITY"
elif [[ -e "$signing_config" ]]; then
    if [[ ! -f "$signing_config" ]]; then
        printf '.pastes-signing-identity must be a single-line file.\n' >&2
        exit 2
    fi
    {
        IFS= read -r signing_identity || true
        signing_extra=""
        if IFS= read -r signing_extra || [[ -n "$signing_extra" ]]; then
            printf '.pastes-signing-identity must contain exactly one line.\n' >&2
            exit 2
        fi
    } < "$signing_config"
fi
if [[ "$signing_identity" != "-" && ! "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    printf 'Signing identity must be "-" or a 40-digit certificate SHA-1 hash.\n' >&2
    exit 2
fi

cd "$project_dir"
/usr/bin/xcrun swift build --configuration "$configuration" --product pastes
bin_dir="$(/usr/bin/xcrun swift build --configuration "$configuration" --show-bin-path)"
app_dir="$output_dir/$app_name.app"

# Stage a complete replacement before touching the previous build.
mkdir -p "$project_dir/build"
staging_dir="$(mktemp -d "$project_dir/build/.pastes-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/$app_name.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"
cp "$bin_dir/pastes" "$staged_app/Contents/MacOS/pastes"
/usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$staged_app/Contents/MacOS/pastes"
cp "$project_dir/pastes/Info.plist" "$staged_app/Contents/Info.plist"

framework_dir="$bin_dir/Sparkle.framework"
if [[ ! -d "$framework_dir" ]]; then
    framework_dir="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [[ ! -d "$framework_dir" ]]; then
    printf 'Sparkle.framework was not produced by Swift Package Manager.\n' >&2
    exit 1
fi
/usr/bin/ditto "$framework_dir" "$staged_app/Contents/Frameworks/Sparkle.framework"
sparkle_license="$project_dir/.build/artifacts/sparkle/Sparkle/LICENSE"
if [[ ! -s "$sparkle_license" ]]; then
    sparkle_license="$project_dir/.build/checkouts/Sparkle/LICENSE"
fi
if [[ ! -s "$sparkle_license" ]]; then
    printf 'Sparkle LICENSE is required for application distribution.\n' >&2
    exit 1
fi
cp "$sparkle_license" "$staged_app/Contents/Resources/Sparkle-LICENSE.txt"

plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable pastes' "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.0' "$plist"
/usr/libexec/PlistBuddy -c "Add :PASTESDevelopmentBuild bool $development_build" "$plist"
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool $automatic_checks" "$plist"
/usr/libexec/PlistBuddy -c 'Add :SUAllowsAutomaticUpdates bool false' "$plist"
/usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool false' "$plist"

iconset="$staging_dir/AppIcon.iconset"
mkdir -p "$iconset"
cp "$project_dir/pastes/Assets.xcassets/AppIcon.appiconset/"*.png "$iconset/"
/usr/bin/iconutil --convert icns --output "$staged_app/Contents/Resources/AppIcon.icns" "$iconset"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$plist"
/usr/bin/plutil -lint "$plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" != "$bundle_identifier" \
   || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" != "$version" \
   || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" != "$build_number" \
   || "$(/usr/libexec/PlistBuddy -c 'Print :PASTESDevelopmentBuild' "$plist")" != "$development_build" \
   || "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$plist")" != "$automatic_checks" \
   || "$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$plist")" != false ]]; then
    printf 'Application metadata did not match the selected build variant.\n' >&2
    exit 1
fi

# Sign nested executables and bundles before signing their containing app.
while IFS= read -r -d '' executable; do
    if [[ "$(/usr/bin/file -b "$executable")" == Mach-O* ]]; then
        /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
            --preserve-metadata=identifier,entitlements,flags,runtime "$executable"
    fi
done < <(/usr/bin/find "$staged_app/Contents/Frameworks" -type f -perm -111 -print0)
while IFS= read -r -d '' bundle; do
    /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
        --preserve-metadata=identifier,entitlements,flags,runtime "$bundle"
done < <(/usr/bin/find "$staged_app/Contents/Frameworks" -depth -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
    --entitlements "$project_dir/pastes/pastes.entitlements" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

mkdir -p "$(dirname "$app_dir")"
if [[ -e "$app_dir" ]]; then
    rm -rf "$app_dir"
fi
mv "$staged_app" "$app_dir"
printf '\nBuilt: %s\n' "$app_dir"
