#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi

"$project_dir/scripts/build.sh" release production
app_dir="$project_dir/build/Distribution/Pastes.app"
plist="$app_dir/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf 'The production application must have valid marketing and build versions.\n' >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" != com.pastes.app.pastes \
   || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" != Pastes \
   || "$(/usr/libexec/PlistBuddy -c 'Print :PASTESDevelopmentBuild' "$plist")" != false \
   || "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$plist")" != true \
   || "$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$plist")" != false \
   || "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$plist")" != false ]]; then
    printf 'Refusing to package an application with incorrect production metadata.\n' >&2
    exit 1
fi
architecture="$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/pastes")"
if [[ "$architecture" != arm64 ]]; then
    printf 'This release package expects an arm64 application; found %s.\n' "$architecture" >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_dir"

release_dir="$project_dir/build/releases/v$version"
mkdir -p "$release_dir"
staging_dir="$(mktemp -d "$project_dir/build/.pastes-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
image_root="$staging_dir/volume"
mkdir -p "$image_root"
/usr/bin/ditto "$app_dir" "$image_root/Pastes.app"
ln -s /Applications "$image_root/Applications"
/usr/bin/codesign --verify --deep --strict "$image_root/Pastes.app"

archive_name="Pastes-$version-arm64.dmg"
staged_archive="$staging_dir/$archive_name"
/usr/bin/hdiutil create -volname Pastes -srcfolder "$image_root" -ov -format UDZO "$staged_archive"
/usr/bin/hdiutil verify "$staged_archive"

# Move only the completed, verified image into the versioned output directory.
mv -f "$staged_archive" "$release_dir/$archive_name"
(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "$archive_name" > SHA256SUMS
    /usr/bin/shasum -a 256 --check SHA256SUMS
)
printf '\nPackaged build %s: %s\n' "$build_number" "$release_dir/$archive_name"
printf 'Checksums: %s\n' "$release_dir/SHA256SUMS"
printf 'The package uses the configured signing identity; notarization is not performed.\n'
