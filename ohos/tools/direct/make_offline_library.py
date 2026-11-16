#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Export a trusted, stopped-session private cache to a new OHOS staging directory.

Output: graphics.v1.json plus shaders/vulkan/direct/<ABI>/<profile>/<identity>.program.
Deploy graphics.v1.json to <moduleDirectory>/; deploy shaders/ to game/shaders/.
These destinations differ: provider_vk.c sets S2A_SHADER_REVISION_ROOT to game_data_dir.
The source cache and descriptor are read-only. No compiler, device, or packer is invoked.
Use the SAME title/revision descriptor and linked compiler closure as the source session.
Cache containers do not carry the title or canonical identity preimage: these associations
cannot be reconstructed or authenticated from a cache alone. Never relabel a foreign cache.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import struct

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    's2a_android_direct_library', REPO / 'android/tools/direct_library.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


TEX_USE_NAME = 'tex-use.v1'
SEED_MANIFEST = 'offline-seed.v1.json'
TEX_USE_LIMIT = 16384

def tex_use_records(raw):
    """Native append journal: 8-byte stage key, little-endian uint32 mask; last wins."""
    if not raw or len(raw) % 12 or len(raw) > 16 * 1024 * 1024:
        raise contract.LibraryError('tex-use.v1 must contain complete 12-byte records (1..16 MiB)')
    records = {}
    for offset in range(0, len(raw), 12):
        key, mask = struct.unpack_from('<8sI', raw, offset)
        records[key] = mask
    if len(records) > TEX_USE_LIMIT:
        raise contract.LibraryError('tex-use.v1 exceeds native stage table capacity')
    return records


def tex_use_bytes(records):
    if len(records) > TEX_USE_LIMIT:
        raise contract.LibraryError('merged tex-use.v1 exceeds native stage table capacity')
    return b''.join(struct.pack('<8sI', key, records[key]) for key in sorted(records))


def read_seed(overlay, descriptor):
    """Sidecar is deliberately outside native graphics.files (which only permits programs/index)."""
    overlay = Path(overlay)
    manifest = overlay / SEED_MANIFEST
    if not manifest.exists():
        if (overlay / TEX_USE_NAME).exists():
            raise contract.LibraryError('tex-use.v1 has no seed manifest')
        return None
    if manifest.is_symlink() or (overlay / TEX_USE_NAME).is_symlink():
        raise contract.LibraryError('linked seed metadata is not allowed')
    meta = json.loads(manifest.read_text(encoding='utf-8'))
    if (meta.get('schema') != 's2a-ohos-offline-seed-v1' or
            meta.get('identityPolicy') != 'texture-use-v1' or
            meta.get('descriptorSha256') != descriptor['sha256'] or
            meta.get('closure') != descriptor['translator_closure'] or
            meta.get('profiles') != descriptor['profile_hashes']):
        raise contract.LibraryError('seed manifest does not match the offline descriptor/identity policy')
    raw = contract._read_file(str(overlay / TEX_USE_NAME), TEX_USE_NAME, 16 * 1024 * 1024)
    if meta.get('bytes') != len(raw) or meta.get('sha256') != contract.sha256_bytes(raw):
        raise contract.LibraryError('tex-use.v1 size/hash mismatch')
    records = tex_use_records(raw)
    if meta.get('stages') != len(records):
        raise contract.LibraryError('tex-use.v1 stage count mismatch')
    return raw


def install_seed(overlay, cache, target_descriptor, profile, *, session_stopped=False):
    """Local deployment step before launch. Never deletes programs; existing learned masks win.

    The caller must stop the target session and give its actual descriptor/profile/cache path.
    This tool neither contacts devices nor guesses a different revision's writable cache.
    """
    if not session_stopped:
        raise contract.LibraryError('stop the target session before installing its seed')
    result = verify(overlay)
    source = contract.load_descriptor(Path(overlay) / 'graphics.v1.json')
    target = contract.load_descriptor(target_descriptor)
    for key in ('titleId', 'gameContentRoot', 'moduleSetDigest', 'translatorClosure',
                'directABI', 'sourceParserVersion', 'runtimeCompilerABI'):
        if source['doc'][key] != target['doc'][key]:
            raise contract.LibraryError('target revision differs: ' + key)
    if profile not in source['profile_hashes']:
        raise contract.LibraryError('target live profile differs from seed library')
    raw = read_seed(overlay, source)
    if raw is None:
        raise contract.LibraryError('this library has no texture-use seed')
    cache = Path(cache).absolute()
    closure = source['translator_closure']
    suffix = '-' + closure[8:24] if closure.startswith('s2a-dc1-') and len(closure) >= 24 else ''
    if cache.name != 'nvn-vk-r20261029d' + suffix:
        raise contract.LibraryError('cache directory name differs from target closure')
    # Reject redirected destinations, including existing ancestor links.
    if any(p.is_symlink() for p in (cache, *cache.parents)):
        raise contract.LibraryError('linked cache destination is not allowed')
    dest = cache / TEX_USE_NAME
    if dest.is_symlink():
        raise contract.LibraryError('linked tex-use destination is not allowed')
    old = dest.read_bytes() if dest.exists() else None
    merged = tex_use_records(raw)
    if old:
        merged.update(tex_use_records(old))  # Includes all-ones fallback masks: never narrow them.
    combined = tex_use_bytes(merged)
    cache.mkdir(parents=True, exist_ok=True)
    backup = None
    if old is not None and old != combined:
        backup = cache / (TEX_USE_NAME + '.before-' + contract.sha256_bytes(old))
        if os.path.lexists(backup):
            if backup.is_symlink() or backup.read_bytes() != old:
                raise contract.LibraryError('existing backup is not the original seed')
        else:
            with backup.open('xb') as f:
                f.write(old)
    if old != combined:
        fd, tmp = tempfile.mkstemp(prefix='tex-use.tmp-', dir=cache)
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(combined)
                f.flush()
                os.fsync(f.fileno())
            if (dest.read_bytes() if dest.exists() else None) != old:
                raise contract.LibraryError('target seed changed: session must remain stopped')
            os.replace(tmp, dest)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    return dict(result, seedStages=len(merged), seedPath=str(dest),
                seedSha256=contract.sha256_bytes(combined), backup=str(backup) if backup else None)


def verify(overlay):
    overlay = Path(overlay)
    descriptor = contract.load_descriptor(overlay / 'graphics.v1.json')
    if descriptor['direct_abi'] != 1 or descriptor['source_parser_version'] != 1:
        raise contract.LibraryError('OHOS runtime currently requires directABI/sourceParserVersion 1')
    if not descriptor['files']:
        raise contract.LibraryError('offline overlay must contain programs')
    direct = overlay / contract.DIRECT_PREFIX
    contract._reject_linked_path(str(overlay), contract.DIRECT_PREFIX, 'overlay')
    contract.verify_descriptor_files(str(direct), descriptor['files'], 'OHOS overlay')
    count = contract.verify_program_files(str(direct), descriptor['files'], descriptor)
    seed = read_seed(overlay, descriptor)
    return {'seedStages': len(tex_use_records(seed)) if seed is not None else None, 'programs': count, 'profiles': descriptor['profile_hashes'],
            'closure': descriptor['translator_closure'], 'descriptorSha256': descriptor['sha256']}


def build(cache, descriptor, out, profile, closure, *, require_tex_use=False, identities=None):
    cache, out = Path(cache).resolve(), Path(out).absolute()
    source = contract.load_descriptor(descriptor)
    if source['direct_abi'] != 1 or source['source_parser_version'] != 1:
        raise contract.LibraryError('OHOS runtime currently requires directABI/sourceParserVersion 1')
    if not contract.CONTENT_ROOT.fullmatch(profile):
        raise contract.LibraryError('profile must be sha256-<64 lowercase hex> from the target device')
    if closure != source['translator_closure']:
        raise contract.LibraryError('descriptor closure differs from the linked compiler closure')
    if not cache.is_dir():
        raise contract.LibraryError('cache must be an exported private-cache directory')
    if os.path.lexists(out):
        raise contract.LibraryError(f'refusing to overwrite output: {out}')
    if out.resolve().is_relative_to(cache):
        raise contract.LibraryError('output must be outside the input cache')
    seed_path = cache / TEX_USE_NAME
    seed = None
    if seed_path.exists():
        if seed_path.is_symlink():
            raise contract.LibraryError('linked source tex-use seed is not allowed')
        seed = tex_use_bytes(tex_use_records(contract._read_file(str(seed_path), TEX_USE_NAME, 16 * 1024 * 1024)))
    elif require_tex_use:
        raise contract.LibraryError('new texture-use identities require tex-use.v1 from the same stopped session')
    if identities is None:
        programs = sorted(cache.glob('*.program'))
    else:
        identities = list(identities)
        if not identities or len(set(identities)) != len(identities) or any(not contract.HEX64.fullmatch(x) for x in identities):
            raise contract.LibraryError('program inventory must contain unique full lowercase identity hashes')
        programs = [cache / (identity + '.program') for identity in sorted(identities)]
    if not programs:
        raise contract.LibraryError('cache contains no .program containers')
    # Keep a single profile per export. No silent filtering of stale or mixed identities.
    expected = dict(source, profile_hashes=[profile])
    doc = dict(source['doc'], profiles=[{'profileHash': profile}], files=[])
    out.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=out.name + '.tmp-', dir=out.parent))
    try:
        for path in programs:
            identity = path.stem
            if not contract.HEX64.fullmatch(identity) or path.is_symlink() or not path.is_file():
                raise contract.LibraryError(f'invalid cache entry: {path.name}')
            raw = contract._read_file(str(path), path.name,
                                      contract.PCACHE_HEADER + contract.PCACHE_MAX_PAYLOAD)
            payload, _ = contract.decode_container(raw, identity, path.name)
            contract.validate_result(payload, path.name, descriptor=expected, expected_profile=profile)
            relative = f'{contract.DIRECT_PREFIX}1/{profile}/{identity}.program'
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)  # Preserve identity, envelope whitespace, and hashes verbatim.
            doc['files'].append({'path': relative, 'size': len(raw),
                                 'sha256': contract.sha256_bytes(raw)})
        (staging / 'graphics.v1.json').write_text(
            json.dumps(doc, indent=2) + '\n', encoding='utf-8', newline='\n')
        if seed is not None:
            (staging / TEX_USE_NAME).write_bytes(seed)
            desc = contract.load_descriptor(staging / 'graphics.v1.json')
            meta = dict(schema='s2a-ohos-offline-seed-v1', identityPolicy='texture-use-v1',
                        descriptorSha256=desc['sha256'], closure=closure, profiles=[profile],
                        bytes=len(seed), sha256=contract.sha256_bytes(seed),
                        stages=len(tex_use_records(seed)))
            (staging / SEED_MANIFEST).write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8', newline='\n')
        result = verify(staging)
        # os.rename refuses an existing destination on Windows; never replace a live revision.
        if os.path.lexists(out):
            raise contract.LibraryError(f'output appeared during export: {out}')
        os.rename(staging, out)
        return dict(result, output=str(out))
    finally:
        # Only our newly allocated temporary directory; never source cache or existing output.
        if staging.exists():
            shutil.rmtree(staging)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    create = sub.add_parser('build')
    create.add_argument('--cache', type=Path, required=True)
    create.add_argument('--descriptor', type=Path, required=True,
                        help='graphics.v1.json used by this title/revision during capture')
    create.add_argument('--out', type=Path, required=True, help='new staging directory; descriptor goes to moduleDirectory, shaders go to game/')
    create.add_argument('--profile', required=True, help='live target profileHash; never a synthetic hash')
    create.add_argument('--closure', required=True, help='closure of the compiler linked into the target HAP')
    create.add_argument('--program-identities', type=Path, help='explicit capture inventory: one full identity per line; no implicit inclusion of historical cache files')
    create.add_argument('--require-tex-use', action='store_true', help='require the same-session texture-use journal for new identities')
    deploy = sub.add_parser('install-seed', help='local stopped-session seed deployment; preserves existing learned masks and backups')
    deploy.add_argument('overlay', type=Path)
    deploy.add_argument('--cache', type=Path, required=True)
    deploy.add_argument('--target-descriptor', type=Path, required=True)
    deploy.add_argument('--profile', required=True)
    deploy.add_argument('--session-stopped', action='store_true')
    check = sub.add_parser('verify')
    check.add_argument('overlay', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == 'verify':
            result = verify(args.overlay)
        elif args.command == 'install-seed':
            result = install_seed(args.overlay, args.cache, args.target_descriptor, args.profile, session_stopped=args.session_stopped)
        else:
            result = build(args.cache, args.descriptor, args.out, args.profile, args.closure, require_tex_use=args.require_tex_use,
                           identities=args.program_identities.read_text(encoding='utf-8').splitlines() if args.program_identities else None)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (contract.LibraryError, OSError, ValueError) as error:
        print(f'offline library: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
