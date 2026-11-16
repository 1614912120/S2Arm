# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Version-bound, local-only code patch preparation for the OHOS packer.

NSO code is patched before native rewriting. Original inputs are never modified.
FPSLocker scripts and runtime cheats are evidence, not static executable patches.
"""
from pathlib import Path
import csv
import hashlib
import json
import re
import shutil
import struct
from fractions import Fraction
import math

SCHEMA = 's2a.ohos.patch-plan.v2'
MAX_PATCH_BYTES = 16 * 1024 * 1024
MAX_WRITE_BYTES = 1024 * 1024


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def build_matches(expected, actual):
    expected = expected.strip().upper()
    actual = actual.strip().upper()
    return bool(re.fullmatch(r'[0-9A-F]{16,64}', expected) and len(expected) % 2 == 0
                and any(c != '0' for c in expected) and actual.startswith(expected))


def identify(exefs):
    exefs = Path(exefs)
    modules = {}
    for path in sorted(exefs.iterdir()):
        if not path.is_file() or path.name in ('rtld', 'main.npdm'):
            continue
        with path.open('rb') as stream:
            header = stream.read(0x100)
        if header[:4] != b'NSO0':
            continue
        if len(header) != 0x100 or not re.fullmatch(r'[A-Za-z0-9_]{1,15}', path.name):
            raise ValueError('无效的 NSO 模块：' + path.name)
        modules[path.name] = {'buildId': header[0x40:0x60].hex().upper(), 'sha256': sha(path)}
    if 'main' not in modules:
        raise ValueError('没有 main NSO，无法核对补丁版本')
    npdm = (exefs / 'main.npdm').read_bytes()
    if len(npdm) < 0x74:
        raise ValueError('main.npdm 不完整')
    aci = struct.unpack_from('<I', npdm, 0x70)[0]
    if aci + 0x18 > len(npdm) or npdm[aci:aci + 4] != b'ACI0':
        raise ValueError('main.npdm 缺少 ACI0')
    return {'titleId': f'{struct.unpack_from("<Q", npdm, aci + 0x10)[0]:016X}',
            'modules': modules, 'npdmSha256': sha(exefs / 'main.npdm')}


def _local_path(root, relative):
    # Collection filenames are preserved on POSIX; the supplied Windows copy
    # substitutes illegal filename characters, without changing file contents.
    parts = relative.replace('\\', '/').split('/')
    if not parts or any(p in ('', '.', '..') for p in parts) or Path(relative).is_absolute():
        raise ValueError('补丁索引路径必须位于索引目录内')
    raw = root.joinpath(*parts)
    candidate = raw if raw.exists() else root.joinpath(*[re.sub(r'[<>:"|?*]', '_', p).rstrip('. ') for p in parts])
    if not candidate.resolve().is_relative_to(root.resolve()):
        raise ValueError('补丁路径越出索引目录')
    return candidate


def parse_pchtxt(path):
    if Path(path).stat().st_size > MAX_PATCH_BYTES:
        raise ValueError('PCHTXT 文件过大')
    lines = Path(path).read_text(encoding='utf-8-sig').splitlines()
    if not lines or not re.fullmatch(r'@nsobid-([0-9a-fA-F]{32,64})', lines[0].strip()):
        raise ValueError('PCHTXT 缺少完整构建号')
    build = lines[0].strip()[8:].upper()
    enabled, shift, writes, total = False, 0, [], 0
    for number, raw in enumerate(lines[1:], 2):
        if not raw.strip():
            enabled = False  # Matches IPSwitchPatcher, including section boundaries.
            continue
        line = raw.split('#', 1)[0].split('//', 1)[0].strip()
        if not line:
            continue
        if line == '@stop':
            break
        if line in ('@enabled', '@disabled'):
            enabled = line == '@enabled'
            continue
        if line == '@flag print_values':
            continue
        if line.startswith('@flag offset_shift '):
            shift = int(line.split()[-1], 0)
            continue
        if line.startswith('@'):
            raise ValueError(f'PCHTXT 第 {number} 行指令不受支持')
        if not enabled:
            continue
        match = re.fullmatch(r'([0-9a-fA-F]{1,8})\s+([0-9a-fA-F]+)', line)
        if not match or len(match[2]) % 2:
            raise ValueError(f'PCHTXT 第 {number} 行不是静态十六进制写入')
        # IPSwitch offsets add offset_shift, then the NSO loader removes its
        # protected 0x100-byte header. With shift=0x100, offset is image-relative.
        offset = int(match[1], 16) + shift - 0x100
        data = bytes.fromhex(match[2])
        total += len(data)
        if offset < 0 or total > MAX_WRITE_BYTES:
            raise ValueError('补丁写入受保护的 NSO 头或超出大小限制')
        writes.append((offset, data))
    if not writes:
        raise ValueError('补丁没有启用的静态写入')
    return build, writes


def parse_ips(path, build):
    payload = Path(path).read_bytes()
    if len(payload) > MAX_PATCH_BYTES:
        raise ValueError('IPS 文件过大')
    width, end = (3, b'EOF') if payload[:5] == b'PATCH' else (4, b'EEOF')
    if payload[:5] not in (b'PATCH', b'IPS32'):
        raise ValueError('IPS 文件头无效')
    cursor, writes, total = 5, [], 0
    while payload[cursor:cursor + len(end)] != end:
        if cursor + width + 2 > len(payload):
            raise ValueError('IPS 记录被截断')
        offset = int.from_bytes(payload[cursor:cursor + width], 'big') - 0x100
        cursor += width
        size = int.from_bytes(payload[cursor:cursor + 2], 'big')
        cursor += 2
        if size:
            data = payload[cursor:cursor + size]
            cursor += size
            if len(data) != size:
                raise ValueError('IPS 写入数据被截断')
        else:
            if cursor + 3 > len(payload):
                raise ValueError('IPS RLE 被截断')
            size = int.from_bytes(payload[cursor:cursor + 2], 'big')
            data = payload[cursor + 2:cursor + 3] * size
            cursor += 3
        if offset < 0 or not size:
            raise ValueError('IPS 写入 NSO 头或包含空记录')
        total += size
        if total > MAX_WRITE_BYTES:
            raise ValueError('IPS 展开写入总量超过限制')
        writes.append((offset, data))
    if cursor + len(end) != len(payload) or not writes:
        raise ValueError('不支持 IPS 截断/扩展文件或空补丁')
    return build, writes


def _parse_candidate(candidate, actual_build):
    path = Path(candidate['file'])
    if sha(path) != candidate['sha256']:
        raise ValueError('补丁内容与索引 SHA256 不一致')
    if path.suffix.lower() == '.pchtxt':
        build, writes = parse_pchtxt(path)
        if candidate['buildId'] and not (build_matches(candidate['buildId'], build) or build_matches(build, candidate['buildId'])):
            raise ValueError('PCHTXT 与索引构建号不一致')
    elif path.suffix.lower() == '.ips':
        build = path.stem.split('.')[0].upper()
        if not re.fullmatch(r'[0-9A-F]{32,64}', build):
            build = candidate['buildId']
        if not re.fullmatch(r'[0-9A-F]{32,64}', build):
            raise ValueError('IPS 缺少完整构建号')
        _, writes = parse_ips(path, build)
    else:
        raise ValueError('此格式需要运行期插件或资源适配，不能静态写入 NSO')
    if not build_matches(build, actual_build):
        # A full 32-byte ID with trailing zero padding is the standard NSO form.
        if build.ljust(64, '0') != actual_build:
            raise ValueError('补丁构建号不匹配')
    return writes


def _nso_segments(path):
    payload = Path(path).read_bytes()
    if len(payload) < 0x100 or payload[:4] != b'NSO0':
        raise ValueError('NSO 无效')
    flags = struct.unpack_from('<I', payload, 0x0c)[0]
    segments = []
    for index in range(3):
        file_offset, memory_offset, size = struct.unpack_from('<III', payload, 0x10 + index * 0x10)
        compressed_size = struct.unpack_from('<I', payload, 0x60 + index * 4)[0]
        stored_size = compressed_size if flags & (1 << index) else size
        if size > 512 * 1024 * 1024 or file_offset < 0x100 or file_offset + stored_size > len(payload):
            raise ValueError('NSO 段边界无效')
        data = payload[file_offset:file_offset + stored_size]
        if flags & (1 << index):
            import lz4.block
            data = lz4.block.decompress(data, uncompressed_size=size)
        if len(data) != size:
            raise ValueError('NSO 段长度不一致')
        if flags & (8 << index) and hashlib.sha256(data).digest() != payload[0xa0 + index * 32:0xc0 + index * 32]:
            raise ValueError('NSO 段哈希不一致')
        if any(memory_offset < start + len(old) and start < memory_offset + size for start, old in segments):
            raise ValueError('NSO 内存段重叠')
        segments.append((memory_offset, bytearray(data)))
    return payload, segments


def _valid_writes(segments, writes):
    for offset, data in writes:
        if not any(start <= offset and offset + len(data) <= start + len(raw) for start, raw in segments):
            raise ValueError(f'补丁偏移 0x{offset:x} 不在有文件内容的 NSO 段内')




def aspect_ratio(value):
    """Exact user viewport ratio; no device model or game is hardcoded here."""
    if value in (None, '', 'native'): return None
    parts = str(value).lower().replace('x', ':').split(':')
    if len(parts) != 2 or any(not re.fullmatch(r'\d+(?:\.\d+)?', p) for p in parts):
        raise ValueError('画幅请用宽:高或宽x高，例如 2848:1320')
    if any(len(p) > 12 for p in parts): raise ValueError('画幅参数过长')
    try: ratio = Fraction(parts[0]) / Fraction(parts[1])
    except ZeroDivisionError: raise ValueError('画幅高度必须大于零') from None
    if not 1 <= ratio <= 4: raise ValueError('候选画幅须在 1:1 至 4:1 之间')
    return ratio


def _bytes_at(segments, offset, size):
    for start, data in segments:
        if start <= offset and offset + size <= start + len(data):
            return bytes(data[offset - start:offset - start + size])
    raise ValueError(f'补丁读点不在有文件内容的 NSO 段内：0x{offset:x}')


def _static_code_boundaries(segments, writes):
    # Raw patches have no relocation islands or function-boundary proof. Reject
    # a contiguous overwrite which extends past an existing RET into real code.
    addresses = sorted({off + i for off, data in writes for i in range(len(data))})
    if not addresses: return
    groups = []; first = previous = addresses[0]
    for address in addresses[1:]:
        if address != previous + 1: groups.append((first, previous + 1)); first = address
        previous = address
    groups.append((first, previous + 1))
    begin, data = segments[0]; end = begin + len(data)
    for first, last in groups:
        for offset in range((max(first, begin) + 3) & ~3, min(last, end) - 4, 4):
            original = int.from_bytes(_bytes_at(segments, offset, 4), 'little')
            following = int.from_bytes(_bytes_at(segments, offset + 4, 4), 'little')
            if original & 0xfffffc1f == 0xd65f0000 and following not in (0, 0xd503201f):
                raise ValueError(f'unsafe-cross-function-overwrite: 0x{offset:x} 的 RET 后还有真实指令，需离线跳板')


def _recipe(path, identity, segments, fps, aspect):
    path = Path(path).resolve()
    if path.stat().st_size > 65536: raise ValueError('补丁配方超过 64KiB')
    raw = json.loads(path.read_text(encoding='utf-8-sig'))
    if raw.get('schema') != 's2a.ohos.patch-recipe.v1': raise ValueError('不支持此补丁配方 schema')
    main = identity['modules']['main']
    if raw.get('titleId', '').upper() != identity['titleId']: raise ValueError('recipe-title-id-mismatch')
    build = raw.get('buildId', '').upper()
    if len(build) < 32 or not build_matches(build, main['buildId']): raise ValueError('recipe-build-id-mismatch')
    if raw.get('originalSha256') != main['sha256']: raise ValueError('recipe-original-sha256-mismatch')
    record = {'id': digest(['recipe', sha(path)])[:20], 'kind': raw.get('kind'),
              'source': raw.get('source', ''), 'originalPath': path.name, 'file': str(path),
              'sha256': sha(path), 'buildId': build, 'version': raw.get('version', ''),
              'format': 's2a.ohos.patch-recipe.v1', 'fps': raw.get('fps', ''), 'aspect': '',
              'hud': raw.get('hud', 'not-applicable'), 'license': raw.get('license', '未声明；仅本地使用'),
              'status': 'eligible', 'reason': '', 'writes': [], 'guardedOffsets': [],
              'limitations': raw.get('limitations', []), 'requiresRuntime': raw.get('requiresRuntime')}
    for guard in raw.get('guards', []):
        offset = int(guard['offset'], 0); value = bytes.fromhex(guard['hex'])
        if not value or len(value) > 1024 or _bytes_at(segments, offset, len(value)) != value:
            raise ValueError(f'recipe-context-guard-mismatch: 0x{offset:x}')
    if raw.get('kind') == 'aspect':
        ratio = aspect_ratio(aspect)
        if ratio is None: raise ValueError('aspect-not-requested')
        if not float(raw.get('minAspect', 1)) <= float(ratio) <= float(raw.get('maxAspect', 4)):
            raise ValueError('aspect-outside-reviewed-recipe-range')
        sites = raw.get('sites', [])
        if not 1 <= len(sites) <= 128: raise ValueError('画幅配方代码点数量无效')
        bits = struct.unpack('<I', struct.pack('<f', float(ratio)))[0]
        lines = [f'# Explicit local aspect recipe; viewport {ratio.numerator}:{ratio.denominator}; gameplay unverified.', f'build {build}']
        for site in sites:
            offset = int(site['offset'], 0); original = int(site['original'], 16); reg = site['register']
            if not re.fullmatch(r's(?:[0-9]|[12][0-9]|3[01])', reg): raise ValueError('画幅目标浮点寄存器无效')
            if offset % 4 or offset < segments[0][0] or offset + 4 > segments[0][0] + len(segments[0][1]):
                raise ValueError('画幅指令不在代码段内')
            if int.from_bytes(_bytes_at(segments, offset, 4), 'little') != original:
                raise ValueError(f'recipe-original-word-mismatch: 0x{offset:x}')
            record['guardedOffsets'].append(offset)
            lines.append(f'c main {offset:#x} f32_const {original:08x} {reg} {bits:08x}')
        record.update(tableName='code-patches.tsv', tableText='\n'.join(lines) + '\n',
                      aspect=f'{ratio.numerator}:{ratio.denominator}', aspectFloatBits=f'{bits:08x}')
    elif raw.get('kind') == 'fps':
        if str(fps) != '60' or raw.get('fps') != 60: raise ValueError('target-fps-not-requested')
        if raw.get('requiresRuntime') != 's2a.ohos.fps.v1': raise ValueError('FPS配方缺少运行期ABI契约')
        table = _local_path(path.parent, raw['table'])
        if table.stat().st_size > 65536 or sha(table) != raw.get('tableSha256'):
            raise ValueError('FPS table sha256 mismatch')
        table_text = table.read_bytes().decode('utf-8')
        lines = [line.split('#', 1)[0].split() for line in table_text.splitlines()]
        lines = [line for line in lines if line]
        builds = [c[1] for c in lines if len(c) == 2 and c[0] == 'build']
        if len(builds) != 1 or len(builds[0]) != 32 or not build_matches(builds[0], main['buildId']):
            raise ValueError('FPS table build mismatch')
        if ['abi', 's2a.ohos.fps.v1'] not in lines or ['target', '60'] not in lines:
            raise ValueError('FPS table runtime contract missing')
        for c in lines:
            if c[0] != 'c': continue
            if len(c) < 5 or c[1] != 'main': raise ValueError('FPS table module unsupported')
            offset, original = int(c[2], 16), int(c[4], 16)
            if offset % 4 or offset < segments[0][0] or offset + 4 > segments[0][0] + len(segments[0][1]):
                raise ValueError('FPS instruction outside text')
            if int.from_bytes(_bytes_at(segments, offset, 4), 'little') != original:
                raise ValueError(f'FPS table original mismatch: 0x{offset:x}')
            record['guardedOffsets'].append(offset)
        if not 1 <= len(record['guardedOffsets']) <= 128: raise ValueError('FPS table missing guarded code')
        record.update(tableName='fps.tsv', tableText=table_text)
    else: raise ValueError('配方只支持 aspect 或 fps')
    if len(set(record['guardedOffsets'])) != len(record['guardedOffsets']): raise ValueError('配方代码点重复')
    record['tableSha256'] = hashlib.sha256(record['tableText'].encode()).hexdigest()
    return record


def write_tables(plan, directory):
    """Emit immutable companion tables consumed by the rewriter and runtime."""
    directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
    outputs = {}
    for candidate in plan['candidates']:
        if candidate['id'] not in plan['selected'] or not candidate.get('tableName'): continue
        if sha(candidate['file']) != candidate['sha256']: raise ValueError('配方在扫描后变化')
        name = candidate['tableName']
        if name not in ('fps.tsv', 'code-patches.tsv') or name in outputs: raise ValueError('配套表文件名冲突')
        data = candidate['tableText'].encode('utf-8')
        if hashlib.sha256(data).hexdigest() != candidate['tableSha256']: raise ValueError('配套表摘要不符')
        dest = directory / name
        if dest.exists() and dest.read_bytes() != data: raise ValueError('已有配套表内容不同，保留现场')
        if not dest.exists(): dest.write_bytes(data)
        outputs[name] = {'path': str(dest), 'sha256': candidate['tableSha256']}
    return outputs


def scan(indexes, exefs, metadata, fps=60, aspect=None, enabled=True, recipes=()):
    identity = identify(exefs)
    if metadata.get('titleId', '').upper() != identity['titleId']:
        raise ValueError('目录 main.npdm 与游戏元数据身份不一致')
    actual = identity['modules']['main']['buildId']
    candidates, source_records = [], []
    for entry in indexes:
        index = Path(entry).resolve()
        if index.is_dir():
            index /= 'INDEX.tsv'
        source_records.append({'index': str(index), 'sha256': sha(index)})
        with index.open(encoding='utf-8-sig', newline='') as stream:
            for row in csv.DictReader(stream, delimiter='\t'):
                title = row.get('title_id', '').upper()
                build = row.get('build_id', '').upper()
                if title != identity['titleId'] and not (not title and build_matches(build, actual)):
                    continue
                kind = 'aspect' if 'aspect' in row else 'fps'
                record = {'id': digest([row.get('source'), row.get('path'), row.get('sha256')])[:20],
                          'kind': kind, 'source': row.get('source', ''), 'originalPath': row.get('path', ''),
                          'sha256': row.get('sha256', ''), 'buildId': build, 'version': row.get('version', ''),
                          'format': row.get('type', row.get('kind', '')), 'fps': row.get('target_fps', ''),
                          'aspect': row.get('aspect', ''), 'hud': row.get('ui_fix', 'unknown'),
                          'license': row.get('license') or '未在索引声明；仅本地使用，不随工具分发',
                          'status': 'skipped', 'reason': ''}
                candidates.append(record)
                try:
                    relative = row.get('dup_of') if row.get('in_pack') == 'dup' else row.get('path')
                    if not relative:
                        raise ValueError('索引未提供本地文件')
                    path = _local_path(index.parent, relative)
                    record['file'] = str(path)
                    if build and not build_matches(build, actual):
                        raise ValueError('build-id-mismatch')
                    if 'yaml' in record['format'].lower():
                        raise ValueError('requires-fpslocker-runtime: 含动态步长/注入脚本，鸿蒙尚未接该插件')
                    if not path.is_file():
                        raise ValueError('not-in-lite-package: 索引条目需完整资源/压缩包解析')
                    if kind == 'fps' and (str(fps) != '60' or record['fps'] != '60'):
                        raise ValueError('target-fps-not-requested')
                    if kind == 'aspect' and (not aspect or record['aspect'] != aspect):
                        raise ValueError('aspect-not-requested: 保留原比例，未套其它比例补丁')
                    writes = _parse_candidate(record, actual)
                    if not enabled:
                        raise ValueError('patches-disabled')
                    record['status'] = 'eligible'
                    record['writes'] = [{'offset': offset, 'hex': data.hex()} for offset, data in writes]
                except (ValueError, OSError) as error:
                    record['reason'] = str(error)
    if recipes and enabled:
        _, recipe_segments = _nso_segments(Path(exefs) / 'main')
        for recipe_path in recipes:
            path = Path(recipe_path).resolve()
            source_records.append({'recipe': str(path), 'sha256': sha(path)})
            try:
                candidates.append(_recipe(path, identity, recipe_segments, fps, aspect))
            except (ValueError, KeyError, OSError, TypeError) as error:
                candidates.append({'id': digest(['recipe', sha(path)])[:20], 'kind': 'recipe', 'source': str(path),
                                   'sha256': sha(path), 'status': 'skipped', 'reason': str(error)})
    eligible = [c for c in candidates if c['status'] == 'eligible']
    if sum(len(w['hex']) // 2 for c in eligible for w in c['writes']) > MAX_WRITE_BYTES * 4:
        raise ValueError('本组补丁写入总量过大，未选择或应用')
    if eligible:
        _, segments = _nso_segments(Path(exefs) / 'main')
        for c in eligible:
            try:
                _valid_writes(segments, [(w['offset'], bytes.fromhex(w['hex'])) for w in c['writes']])
                _static_code_boundaries(segments, [(w['offset'], bytes.fromhex(w['hex'])) for w in c['writes']])
            except ValueError as error:
                c.update(status='skipped', reason=str(error))
    owners, conflicts, seen_hashes = {}, set(), set()
    for c in candidates:
        if c['status'] != 'eligible':
            continue
        content_key = (c['sha256'], c.get('tableSha256'))
        if content_key in seen_hashes:
            c.update(status='skipped', reason='duplicate-content')
            continue
        seen_hashes.add(content_key)
        for write in c['writes']:
            for index, byte in enumerate(bytes.fromhex(write['hex'])):
                offset = write['offset'] + index
                if offset in owners:
                    if any(value != byte for value, _ in owners[offset]):
                        conflicts.add(c['id'])
                        conflicts.update(owner for _, owner in owners[offset])
                    owners[offset].append((byte, c['id']))
                else:
                    owners[offset] = [(byte, c['id'])]
    table_owners, guarded_owners = {}, {}
    for c in candidates:
        if c['status'] != 'eligible': continue
        name = c.get('tableName')
        if name:
            if name in table_owners:
                conflicts.update([c['id'], table_owners[name]])
            table_owners[name] = c['id']
        for off in c.get('guardedOffsets', []):
            for address in range(off, off + 4):
                if address in owners: conflicts.update([c['id'], *[owner for _, owner in owners[address]]])
                if address in guarded_owners: conflicts.update([c['id'], guarded_owners[address]])
                guarded_owners[address] = c['id']
    for c in candidates:
        if c['id'] in conflicts:
            c.update(status='skipped', reason='conflicting-code-patches')
        elif c['status'] == 'eligible':
            c.update(status='selected', reason='identity-and-bytes-validated; gameplay-unverified')
    selected = [c for c in candidates if c['status'] == 'selected']
    result = {'schema': SCHEMA, 'identity': identity, 'sources': source_records,
              'request': {'fps': fps, 'aspect': aspect, 'enabled': enabled}, 'candidates': candidates,
              'selected': [c['id'] for c in selected], 'gameplayVerified': False,
              'notes': ['补丁写入通过不代表实际60帧或HUD/过场已适配。', '所有补丁与游戏派生产物保留本地，不随工具分发。']}
    result['fingerprint'] = digest({'schema': SCHEMA, 'identity': identity,
                                    'selected': [(c['id'], c['sha256'], c['writes'], c.get('tableSha256'), c.get('requiresRuntime')) for c in selected]})
    return result


def materialize(plan, exefs, output):
    """Produce immutable NSOs under a content key; never edit original bytes."""
    exefs, output = Path(exefs).resolve(), Path(output).resolve()
    if output == exefs or output.is_relative_to(exefs) or exefs.is_relative_to(output):
        raise ValueError('补丁候选目录必须独立于原始 exeFS')
    if identify(exefs) != plan['identity']:
        raise ValueError('原始 exeFS 在扫描后已改变')
    selected = [c for c in plan['candidates'] if c['id'] in plan['selected']]
    selected = [c for c in selected if c['writes']]  # Code tables use rewriter-owned islands, no NSO edits.
    if not selected:
        return exefs
    destination = output / plan['fingerprint']
    receipt = destination / 'prepared.json'
    if receipt.is_file():
        previous = json.loads(receipt.read_text(encoding='utf-8'))
        if previous['fingerprint'] == plan['fingerprint'] and all(sha(destination / 'exefs' / name) == value for name, value in previous['outputs'].items()):
            return destination / 'exefs'
        raise ValueError('已有补丁候选被修改，保留现场并停止')
    destination.mkdir(parents=True, exist_ok=False)
    target = destination / 'exefs'
    target.mkdir()
    for path in exefs.iterdir():
        if path.is_symlink() or not path.is_file():
            raise ValueError('exeFS 只允许普通文件')
        shutil.copy2(path, target / path.name)
    payload, segments = _nso_segments(exefs / 'main')
    for candidate in selected:
        writes = _parse_candidate(candidate, plan['identity']['modules']['main']['buildId'])
        if [{'offset': off, 'hex': data.hex()} for off, data in writes] != candidate['writes']:
            raise ValueError('补丁解析结果在扫描后变化')
        _valid_writes(segments, writes)
        for offset, data in writes:
            for start, segment in segments:
                if start <= offset and offset + len(data) <= start + len(segment):
                    segment[offset - start:offset - start + len(data)] = data
                    break
    result = bytearray(payload[:0x100])
    struct.pack_into('<I', result, 0x0c, (struct.unpack_from('<I', result, 0x0c)[0] & ~7) | 0x38)
    for index, (_, segment) in enumerate(segments):
        struct.pack_into('<I', result, 0x10 + index * 0x10, len(result))
        struct.pack_into('<I', result, 0x60 + index * 4, len(segment))
        result[0xa0 + index * 32:0xc0 + index * 32] = hashlib.sha256(segment).digest()
        result.extend(segment)
    name_offset, name_size = struct.unpack_from('<I', payload, 0x1c)[0], struct.unpack_from('<I', payload, 0x2c)[0]
    if name_size:
        if name_offset + name_size > len(payload):
            raise ValueError('NSO 模块名越界')
        struct.pack_into('<I', result, 0x1c, len(result))
        result.extend(payload[name_offset:name_offset + name_size])
    (target / 'main').write_bytes(result)
    _nso_segments(target / 'main')  # Recheck exact lengths and recomputed segment hashes.
    atomic_json(destination / 'plan.json', plan)
    atomic_json(receipt, {'fingerprint': plan['fingerprint'], 'outputs': {p.name: sha(p) for p in target.iterdir()},
                          'originalUnchanged': identify(exefs) == plan['identity']})
    return target
