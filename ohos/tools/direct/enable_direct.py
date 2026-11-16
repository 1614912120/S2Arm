#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Turn the NVN->Vulkan direct path on/off for one installed game on an OHOS device (hdc).

  on      push graphics.v1.json into the game's module directory, create the draw-time program cache
          directory, and write "direct" to <state>/graphics_mode
  off     remove <state>/graphics_mode only (next start takes the unchanged generic v1 path);
          the descriptor and any compiled programs stay for the next try
  status  print what the device has

Generic remains the default: without graphics_mode the engine never reads the descriptor. A failed
direct start is not turned into generic silently; switch "off" and start again. Saves are untouched.
"""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

HDC = r'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
FILES = 'data/storage/el2/base/haps/entry/files'


def run(args, target, check=True):
    p = subprocess.run([HDC] + (['-t', target] if target else []) + [str(a) for a in args], capture_output=True)
    out = (p.stdout + p.stderr).decode('utf-8', errors='replace')
    if check and (p.returncode or '[Fail]' in out):
        sys.exit(f'hdc {" ".join(map(str, args))} failed: {out.strip()}')
    return out


def shell(cmd, bundle, target, check=True):
    return run(['shell', '-b', bundle, cmd], target, check)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('action', choices=['on', 'off', 'status'])
    ap.add_argument('--target', help='hdc target (IP:port or serial); default: the only connected device')
    ap.add_argument('--bundle', default='com.xiaoboluo.s2arm.probe')
    ap.add_argument('--game-key', default='my-game', help='folder under files/games')
    ap.add_argument('--title-id', default='01007EF00011E000')
    ap.add_argument('--descriptor', type=Path, help='graphics.v1.json from make_graphics_descriptor.py (on)')
    a = ap.parse_args()
    game = f'{FILES}/games/{a.game_key}'
    state = f'{FILES}/states/{a.title_id}'
    ready = json.loads(shell(f'cat {game}/ready.json', a.bundle, a.target))
    module_dir = f'{game}/{ready["moduleDirectory"]}'
    if a.action == 'status':
        print(shell(f'cat {state}/graphics_mode 2>/dev/null || echo "no graphics_mode = generic"', a.bundle, a.target, False).strip())
        print(shell(f'sha256sum {module_dir}/graphics.v1.json 2>/dev/null || echo "no descriptor"', a.bundle, a.target, False).strip())
        print(shell(f'ls {module_dir}/shaders/vulkan/direct 2>/dev/null | wc -l', a.bundle, a.target, False).strip(), 'compiled program files')
        return
    if a.action == 'off':
        shell(f'rm -f {state}/graphics_mode', a.bundle, a.target)
        print('direct off: next start is generic')
        return
    if not a.descriptor or not a.descriptor.is_file():
        sys.exit('on needs --descriptor <graphics.v1.json>')
    doc = json.loads(a.descriptor.read_bytes())
    if doc.get('titleId') != a.title_id:
        sys.exit(f'descriptor titleId {doc.get("titleId")} != {a.title_id}')
    # gameContentRoot binds the exact ready.json bytes installed on the device.
    remote_ready = shell(f'sha256sum {game}/ready.json', a.bundle, a.target).split()[0]
    if doc.get('gameContentRoot') != 'sha256-' + remote_ready:
        sys.exit(f'descriptor was made for another ready.json (device {remote_ready}); regenerate it from the installed program package')
    run(['file', 'send', '-b', a.bundle, a.descriptor, f'/{module_dir}/graphics.v1.json'], a.target)
    want = hashlib.sha256(a.descriptor.read_bytes()).hexdigest()
    got = shell(f'sha256sum {module_dir}/graphics.v1.json', a.bundle, a.target).split()[0]
    if got != want:
        sys.exit(f'descriptor hash mismatch after send: {got} != {want}')
    shell(f'mkdir -p {module_dir}/shaders/vulkan/direct {state} && echo direct > {state}/graphics_mode', a.bundle, a.target)
    print(shell(f'cat {state}/graphics_mode', a.bundle, a.target).strip(), '- descriptor', got)


if __name__ == '__main__':
    main()
