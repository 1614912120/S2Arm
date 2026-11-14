#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Regenerate the embedded original depth/stencil helper shaders; no downloads."""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--glslc', default='glslc')
args = parser.parse_args()
lines = ['// SPDX-License-Identifier: Apache-2.0', '// Copyright 2026 S2Arm contributors', '// Generated from blit_shaders/*.vert and *.frag by blit_shaders/generate.py.',
         '// Regenerate: python3 android/native/nvn/blit_shaders/generate.py --glslc "$GLSLC"',
         '#pragma once']
with tempfile.TemporaryDirectory(prefix='s2a-depth-shaders-') as directory:
    for source, name in [('fullscreen.vert', 'vs'), ('depth.frag', 'depth'), ('stencil.frag', 'stencil')]:
        target = Path(directory) / 'shader.spv'
        subprocess.run([args.glslc, '--target-env=vulkan1.1', '-O', str(here/source), '-o', str(target)], check=True)
        data = target.read_bytes()
        words = struct.unpack('<'+'I'*(len(data)//4), data)
        lines.append('static const uint32_t k_dsb_'+name+'[] = {')
        for offset in range(0, len(words), 8):
            lines.append('    '+', '.join(f'0x{word:08x}u' for word in words[offset:offset+8])+',')
        lines.append('};')
(here.parent/'backend_vulkan_depth_blit_spv.h').write_text('\n'.join(lines)+'\n')
