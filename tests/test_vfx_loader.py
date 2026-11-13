#!/usr/bin/env python3
"""Check repeated and concurrent VFX loads when the SDK is incomplete."""

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def patch_file(name):
    patch = (ROOT / "vfx-filters.patch").read_text()
    part = patch.split(f"diff --git a/{name} ", 1)[1].split("\ndiff --git ", 1)[0]
    return "\n".join(line[1:] for line in part.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


class LoaderTests(unittest.TestCase):
    def test_missing_symbol_never_publishes_loaded_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "osdep").mkdir()
            (root / "osdep/threads.h").write_text('''
#include <pthread.h>
typedef pthread_mutex_t mp_static_mutex;
#define MP_STATIC_MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#define mp_mutex_lock pthread_mutex_lock
#define mp_mutex_unlock pthread_mutex_unlock
''')
            (root / "cuda.h").write_text("typedef void *CUstream;\n")
            (root / "vfx_loader.h").write_text(patch_file("video/filter/vfx_loader.h"))
            (root / "vfx_loader.c").write_text(patch_file("video/filter/vfx_loader.c"))
            (root / "runner.c").write_text('''
#include <pthread.h>
#include "vfx_loader.h"
static void *run(void *ignored) {
    for (int i = 0; i < 5; i++)
        if (vfx_load_libraries()) return (void *)1;
    return 0;
}
int main(void) {
    pthread_t threads[4];
    for (int i = 0; i < 4; i++)
        if (pthread_create(&threads[i], 0, run, 0)) return 2;
    for (int i = 0; i < 4; i++) {
        void *result;
        if (pthread_join(threads[i], &result) || result) return 3;
    }
    return g_vfx_lib != 0 || g_nvcv_lib != 0;
}
''')
            sdk = root / ".local/lib/vsr-player"
            sdk.mkdir(parents=True)
            (root / "empty.c").write_text("void placeholder(void) {}\n")
            for library in ("libVideoFX.so", "libNVCVImage.so"):
                subprocess.run(["cc", "-shared", "-fPIC", str(root / "empty.c"),
                                "-o", str(sdk / library)], check=True)
            binary = root / "runner"
            subprocess.run(["cc", "-D_GNU_SOURCE", "-I", str(root),
                            str(root / "runner.c"), str(root / "vfx_loader.c"),
                            "-pthread", "-ldl", "-o", str(binary)], check=True)
            env = dict(os.environ, HOME=str(root))
            subprocess.run([str(binary)], env=env, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
