#!/usr/bin/env python3
"""Exercise the actual CUDA transfer functions on the CPU without an NVIDIA GPU."""

import ast
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def kernel_source():
    patch = (ROOT / "vfx-filters.patch").read_text()
    section = patch.split("diff --git a/video/filter/dlssnr_proc.c ", 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    lines = [line[1:] for line in section.splitlines() if line.startswith("+") and not line.startswith("+++")]
    start = lines.index("static const char *kSrc =") + 1
    strings = []
    for line in lines[start:]:
        stripped = line.strip()
        if not stripped.startswith('"'):
            break
        strings.append(ast.literal_eval(stripped.removesuffix(";")))
        if stripped.endswith(";"):
            break
    return "".join(strings).split('extern "C" __global__ void k_lin', 1)[0]


class HlgTests(unittest.TestCase):
    def test_reference_luminance_and_roundtrip(self):
        prefix = r'''
#include <cmath>
#include <cstdio>
#define __device__ static
#define __forceinline__ inline
struct float3 { float x, y, z; };
static float3 make_float3(float x, float y, float z) { return {x, y, z}; }
'''
        check = r'''
static bool close(float a, float b, float eps = 0.00002f) {
    return fabsf(a - b) < eps;
}
int main() {
    float3 white = decode3(make_float3(1, 1, 1), 2);
    if (!close(white.x, 0.1f) || !close(white.y, 0.1f) || !close(white.z, 0.1f))
        return 1;
    float3 in = make_float3(0.75f, 0.50f, 0.25f);
    float3 linear = decode3(in, 2);
    float s0 = (expf((in.x - 0.55991073f) / 0.17883277f) + 0.28466892f) / 12.0f;
    float s1 = in.y * in.y / 3.0f, s2 = in.z * in.z / 3.0f;
    float y = 0.2627f * s0 + 0.6780f * s1 + 0.0593f * s2;
    float scale = 0.1f * powf(y, 0.2f);
    if (!close(linear.x, s0 * scale) || !close(linear.y, s1 * scale) || !close(linear.z, s2 * scale))
        return 2;
    float3 out = encode3(linear, 2);
    if (!close(out.x, in.x) || !close(out.y, in.y) || !close(out.z, in.z))
        return 3;
    float3 black = encode3(decode3(make_float3(0, 0, 0), 2), 2);
    return (!close(black.x, 0) || !close(black.y, 0) || !close(black.z, 0));
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "hlg.cpp"
            binary = pathlib.Path(directory) / "hlg"
            source.write_text(prefix + kernel_source() + check)
            subprocess.run(["c++", "-std=c++17", "-O2", str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
