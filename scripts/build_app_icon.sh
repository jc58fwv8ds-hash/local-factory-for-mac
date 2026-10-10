#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
master_icon="${1:-${project_root}/Assets/AppIcon-1024.png}"
iconset_dir="${project_root}/work/AppIcon.iconset"
resources_dir="${2:-${project_root}/work/Harness.app/Contents/Resources}"
swift_executable="${3:-swift}"
output_icon="${resources_dir}/AppIcon.icns"
sidebar_icon="${resources_dir}/AppIcon.png"

mkdir -p "${iconset_dir}" "${resources_dir}"

sizes=(
    "16 icon_16x16.png"
    "32 icon_16x16@2x.png"
    "32 icon_32x32.png"
    "64 icon_32x32@2x.png"
    "128 icon_128x128.png"
    "256 icon_128x128@2x.png"
    "256 icon_256x256.png"
    "512 icon_256x256@2x.png"
    "512 icon_512x512.png"
    "1024 icon_512x512@2x.png"
)

for specification in "${sizes[@]}"; do
    size="${specification%% *}"
    file_name="${specification#* }"
    sips -z "${size}" "${size}" "${master_icon}" \
        --out "${iconset_dir}/${file_name}" >/dev/null
done

"${swift_executable}" \
    "${project_root}/scripts/make_icns.swift" \
    "${iconset_dir}" \
    "${output_icon}"
cp "${master_icon}" "${sidebar_icon}"
