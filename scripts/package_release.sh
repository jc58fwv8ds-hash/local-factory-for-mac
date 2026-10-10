#!/bin/zsh

set -euo pipefail

readonly project_root="${0:A:h:h}"
readonly version="${1:-}"
readonly build_number="${2:-}"
readonly output_root="${3:-${project_root}/outputs}"
readonly signing_identity="${HARNESS_SIGNING_IDENTITY:--}"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print -u2 "Usage: scripts/package_release.sh <version> <build-number> [output-directory]"
    print -u2 "Version must use three numeric components, for example 0.4.5."
    exit 64
fi

if [[ ! "${build_number}" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 "Build number must be a positive integer."
    exit 64
fi

resolve_developer_dir() {
    local candidate
    if [[ -n "${HARNESS_DEVELOPER_DIR:-}" ]]; then
        candidate="${HARNESS_DEVELOPER_DIR}"
        if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
            print "${candidate}"
            return
        fi
        print -u2 "HARNESS_DEVELOPER_DIR does not point to a full Xcode toolchain."
        return 1
    fi

    candidate=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
        print "${candidate}"
        return
    fi

    for candidate in /Applications/Xcode.app/Contents/Developer \
        /Applications/Xcode*.app/Contents/Developer(N); do
        if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
            print "${candidate}"
            return
        fi
    done

    print -u2 "Full Xcode is required to create the Universal Binary release."
    return 1
}

if ! developer_dir=$(resolve_developer_dir); then
    exit 69
fi
readonly developer_dir
sdk_path=$(env DEVELOPER_DIR="${developer_dir}" \
    /usr/bin/xcrun --sdk macosx --show-sdk-path)
readonly sdk_path
swift_executable=$(env DEVELOPER_DIR="${developer_dir}" \
    /usr/bin/xcrun --find swift)
readonly swift_executable

readonly template_plist="${project_root}/Packaging/Harness-Info.plist"
readonly release_support="${project_root}/.build-release-support"
readonly final_app="${output_root}/Harness-v${version}.app"
readonly final_archive="${output_root}/Harness-v${version}.app.zip"

if [[ -e "${final_app}" || -e "${final_archive}" ]]; then
    print -u2 "Release output already exists; refusing to overwrite v${version}."
    exit 73
fi

mkdir -p "${project_root}/work" "${output_root}"
staging_root=$(mktemp -d "${project_root}/work/HarnessRelease.XXXXXX")
readonly staging_root
cleanup_release() {
    [[ ! -d "${staging_root}" ]] || rm -r -- "${staging_root}"
}
trap cleanup_release EXIT HUP INT TERM

readonly staged_app="${staging_root}/Harness-v${version}.app"
readonly staged_archive="${staging_root}/Harness-v${version}.app.zip"
readonly staged_contents="${staged_app}/Contents"

build_release_slice() {
    local architecture="$1"
    local scratch_path="${project_root}/.build-release-${architecture}"
    env \
        DEVELOPER_DIR="${developer_dir}" \
        CLANG_MODULE_CACHE_PATH="${scratch_path}/clang-module-cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="${scratch_path}/swiftpm-module-cache" \
        /usr/bin/xcrun swift build \
            -c release \
            --product Harness \
            --triple "${architecture}-apple-macosx14.0" \
            --sdk "${sdk_path}" \
            --cache-path "${release_support}/cache" \
            --config-path "${release_support}/config" \
            --security-path "${release_support}/security" \
            --manifest-cache local \
            -Xswiftc -warnings-as-errors \
            --disable-sandbox \
            --scratch-path "${scratch_path}"
}

"${project_root}/scripts/check_architecture.sh"
build_release_slice arm64
build_release_slice x86_64

mkdir -p "${staged_contents}/MacOS" "${staged_contents}/Resources"
readonly resource_bundle_name="Harness_HarnessApp.bundle"
readonly resource_bundle_source="${project_root}/.build-release-arm64/arm64-apple-macosx/release/${resource_bundle_name}"
if [[ ! -d "${resource_bundle_source}" ]]; then
    print -u2 "SwiftPM resource bundle is missing from the release build."
    exit 65
fi
ditto "${resource_bundle_source}" "${staged_contents}/Resources/${resource_bundle_name}"
/usr/bin/lipo -create \
    "${project_root}/.build-release-arm64/arm64-apple-macosx/release/Harness" \
    "${project_root}/.build-release-x86_64/x86_64-apple-macosx/release/Harness" \
    -output "${staged_contents}/MacOS/Harness"
/usr/bin/lipo "${staged_contents}/MacOS/Harness" -verify_arch arm64 x86_64
chmod 755 "${staged_contents}/MacOS/Harness"
cp "${template_plist}" "${staged_contents}/Info.plist"
plutil -replace CFBundleShortVersionString -string "${version}" "${staged_contents}/Info.plist"
plutil -replace CFBundleVersion -string "${build_number}" "${staged_contents}/Info.plist"
env \
    DEVELOPER_DIR="${developer_dir}" \
    SDKROOT="${sdk_path}" \
    CLANG_MODULE_CACHE_PATH="${release_support}/icon-clang-module-cache" \
    "${project_root}/scripts/build_app_icon.sh" \
        "${project_root}/Assets/AppIcon-1024.png" \
        "${staged_contents}/Resources" \
        "${swift_executable}"

if [[ "${signing_identity}" == "-" ]]; then
    codesign --force --deep --sign - "${staged_app}"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "${signing_identity}" \
        "${staged_app}"
fi

codesign --verify --deep --strict --verbose=2 "${staged_app}"
ditto -c -k --sequesterRsrc --keepParent "${staged_app}" "${staged_archive}"

readonly verification_root="${staging_root}/verification"
mkdir -p "${verification_root}"
ditto -x -k "${staged_archive}" "${verification_root}"
codesign --verify \
    --deep \
    --strict \
    --verbose=2 \
    "${verification_root}/Harness-v${version}.app"
/usr/bin/lipo \
    "${verification_root}/Harness-v${version}.app/Contents/MacOS/Harness" \
    -verify_arch arm64 x86_64

verified_version=$(plutil -extract CFBundleShortVersionString raw \
    "${verification_root}/Harness-v${version}.app/Contents/Info.plist")
verified_build=$(plutil -extract CFBundleVersion raw \
    "${verification_root}/Harness-v${version}.app/Contents/Info.plist")
if [[ "${verified_version}" != "${version}" || "${verified_build}" != "${build_number}" ]]; then
    print -u2 "Packaged version metadata did not survive archive extraction."
    exit 65
fi
if [[ ! -f "${verification_root}/Harness-v${version}.app/Contents/Resources/${resource_bundle_name}/qwen3_tts_worker.py" ]]; then
    print -u2 "Qwen3-TTS worker resource did not survive archive extraction."
    exit 65
fi
if [[ ! -f "${verification_root}/Harness-v${version}.app/Contents/Resources/${resource_bundle_name}/voice_engine_install_worker.py" ]]; then
    print -u2 "Voice engine installer resource did not survive archive extraction."
    exit 65
fi
if [[ ! -f "${verification_root}/Harness-v${version}.app/Contents/Resources/${resource_bundle_name}/VoiceEngineRuntime/pyproject.toml" \
    || ! -f "${verification_root}/Harness-v${version}.app/Contents/Resources/${resource_bundle_name}/VoiceEngineRuntime/uv.lock" ]]; then
    print -u2 "Locked voice engine runtime resources did not survive archive extraction."
    exit 65
fi

mv "${staged_app}" "${final_app}"
mv "${staged_archive}" "${final_archive}"

print "Release ready: ${final_app}"
print "Archive ready: ${final_archive}"
shasum -a 256 "${final_archive}"
