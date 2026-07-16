#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 /path/to/PiPanel.app [codesign-identity]" >&2
    exit 64
fi

app_path="$1"
identity="${2:--}"

if [[ ! -d "$app_path" ]]; then
    echo "Application bundle not found: $app_path" >&2
    exit 66
fi

sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle/Versions/B"
media_remote="$app_path/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"

required_paths=(
    "$sparkle_version/Autoupdate"
    "$sparkle_version/XPCServices/Downloader.xpc"
    "$sparkle_version/XPCServices/Installer.xpc"
    "$sparkle_version/Updater.app"
    "$sparkle"
    "$media_remote"
)

for path in "${required_paths[@]}"; do
    if [[ ! -e "$path" ]]; then
        echo "Required signing target not found: $path" >&2
        exit 66
    fi
done

sign_args=(
    --force
    --sign "$identity"
)

if [[ "$identity" == "-" ]]; then
    # An ad-hoc signature has no Team ID. Enabling Hardened Runtime here would turn on
    # Library Validation and dyld would reject embedded third-party frameworks before main().
    sign_args+=(--timestamp=none)
elif [[ "$identity" == "PiPanel Local Code Signing" ]]; then
    # The local certificate intentionally has no Apple Team ID. Keep Library Validation off so
    # MediaRemoteAdapter and Sparkle can load; a secure timestamp would not make this identity
    # eligible for notarization and would add a needless network dependency.
    sign_args+=(--timestamp=none)
else
    sign_args+=(--options runtime --timestamp)
fi

sign_target() {
    local target="$1"
    local target_args=("${sign_args[@]}")

    # Release builds produced with CODE_SIGNING_ALLOWED=NO leave the outer app unsigned, while
    # prebuilt frameworks may still carry their vendor signature. Preserve useful metadata only
    # when it exists; codesign rejects --preserve-metadata on a completely unsigned bundle.
    if codesign -d "$target" >/dev/null 2>&1; then
        target_args+=(--preserve-metadata=identifier,entitlements,requirements)
    fi
    codesign "${target_args[@]}" "$target"
}

# Sign inside-out so every enclosing bundle seals the final signatures of its children.
sign_target "$sparkle_version/Autoupdate"
sign_target "$sparkle_version/XPCServices/Downloader.xpc"
sign_target "$sparkle_version/XPCServices/Installer.xpc"
sign_target "$sparkle_version/Updater.app"
sign_target "$sparkle"
sign_target "$media_remote"
sign_target "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
