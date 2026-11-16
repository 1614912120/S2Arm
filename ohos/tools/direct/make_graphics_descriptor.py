#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Write graphics.v1.json for an OHOS program directory (the folder ready.json names as moduleDirectory).

The fields follow the native consumer (android/native/direct/graphics.c) and the Android packer
(android/tools/make_pack.py load_graphics). Identities come from the actual files:

  moduleSetDigest  SHA-256 over "<name>\\0<sha256 of name.patched.bin>\\n" for every module in ready.json order
  gameContentRoot  SHA-256 of ready.json bytes (the prepared revision: build IDs, patches, module directory)
  profiles/files   both [] for an empty offline library. The device computes its own effective profile
                   from real Vulkan caps during Prepare (provider_vk.c). To export an existing private
                   cache as an offline library, use make_offline_library.py afterwards.

Nothing here enables direct: the session also needs <state>/graphics_mode (enable_direct.py).
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

CLOSURE_RE = re.compile(r'[A-Za-z0-9._+:-]{1,127}')
# 缺省取链进包的编译器构建身份；手写标签会让设备上每次现场编译都被 IDENTITY 拒绝。
IDENTITY_CS = Path(__file__).resolve().parents[3] / 'graphics/tools/direct/compiler/obj/Release/net10.0/DirectBuildIdentity.g.cs'


def default_closure():
    match = re.search(r'TranslatorClosure = "([^"]+)"', IDENTITY_CS.read_text(encoding='utf-8')) if IDENTITY_CS.is_file() else None
    return match.group(1) if match else None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--game-root', type=Path, required=True,
                        help='folder holding ready.json and the module directory (files/games/<key> layout)')
    parser.add_argument('--closure', default=default_closure(),
                        help='translator closure (compiler build identity); default from ' + str(IDENTITY_CS))
    parser.add_argument('--out', type=Path, help='default: <game-root>/<moduleDirectory>/graphics.v1.json')
    args = parser.parse_args()
    if not args.closure:
        sys.exit(f'no closure: {IDENTITY_CS} missing (build the compiler first) and --closure not given')
    if not CLOSURE_RE.fullmatch(args.closure):
        sys.exit('closure must match ' + CLOSURE_RE.pattern)
    ready_bytes = (args.game_root / 'ready.json').read_bytes()
    ready = json.loads(ready_bytes)
    title = ready.get('titleId', '')
    if not re.fullmatch(r'[0-9A-F]{16}', title):
        sys.exit(f'ready.json titleId {title!r} is not 16 uppercase hex digits')
    module_dir = args.game_root / ready['moduleDirectory']
    names = [m if isinstance(m, str) else m.get('name') for m in ready['modules']]
    digest = hashlib.sha256()
    for name in names:
        binary = module_dir / f'{name}.patched.bin'
        if not binary.is_file():
            sys.exit(f'missing module {binary}')
        digest.update(name.encode() + b'\0' + sha(binary.read_bytes()).encode() + b'\n')
    doc = {
        'schema': 's2a-graphics-v1',
        'titleId': title,
        'gameContentRoot': 'sha256-' + sha(ready_bytes),
        'moduleSetDigest': 'sha256-' + digest.hexdigest(),
        'frontend': 'nvn',
        'backend': 'vulkan-direct',
        'directABI': 1,
        'translatorClosure': args.closure,
        'sourceParserVersion': 1,
        'runtimeCompilerABI': 's2a-direct-compile-v1',
        'profiles': [],
        'files': [],
    }
    raw = (json.dumps(doc, indent=2) + '\n').encode()
    out = args.out or module_dir / 'graphics.v1.json'
    out.write_bytes(raw)
    print(json.dumps({'path': str(out), 'bytes': len(raw), 'sha256': sha(raw), 'modules': names}, ensure_ascii=False))


if __name__ == '__main__':
    main()
