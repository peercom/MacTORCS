#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Compiles the render path's Metal sources into one prebuilt library so the
# app never compiles shaders at launch. The order mirrors
# ShaderLibrary.sourceOrder; ShaderLibraryTests pins the two together.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?usage: build-shaders.sh <output.metallib>}"
shaders="Packages/TORCSRender/Shaders"
order=(Common BRDF Post Exposure Atmosphere Shadow Forward Sky Occlusion Reflections MotionBlur Bloom Particles SkidMarks DepthOfField Resolve)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
all="$work/All.metal"
: > "$all"
for name in "${order[@]}"; do
    echo "#include \"$name.metal\"" >> "$all"
done
# -fpreserve-invariance matches the runtime compile options: the temporal
# path depends on positions being reproducible between passes.
xcrun -sdk macosx metal -std=metal3.1 -fpreserve-invariance -O2 -I "$shaders" -c "$all" -o "$work/All.air"
xcrun -sdk macosx metallib "$work/All.air" -o "$out"
echo "Built $out"
