# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Publish a Vulkan SPIR-V library with an immutable data generation.

The library can contain provisional shaders; only fully specified variants are
runtime-consumable. That does not mean a complete NVN backend exists.
"""
from pathlib import Path
import hashlib
import json
import os


def build(output):
    out = Path(output)
    entries, chunks, offset, ready = [], [], 0, 0
    for path in sorted(out.glob('*.spv')):
        reflection_path = path.with_suffix('.res.json')
        if not reflection_path.is_file():
            raise ValueError('Every SPIR-V module needs its own v2 reflection: ' + path.name)
        reflection = json.loads(reflection_path.read_text(encoding='utf-8'))
        if reflection.get('schema') != 's2a.spirv-reflection.v2' or reflection.get('bindingConvention') != 'nvn-stage256-v1':
            raise ValueError('Legacy shader output must be retranslated, never relabelled: ' + path.name)
        payload = path.read_bytes()
        if payload[:4] != b'\x03\x02\x23\x07' or len(payload) < 20 or len(payload) % 4 or len(payload) > 16 * 1024 * 1024:
            raise ValueError('Invalid SPIR-V size/header: ' + path.name)
        digest = hashlib.sha256(payload).hexdigest()
        if digest != reflection.get('spirv_sha256') or reflection.get('key') != path.stem:
            raise ValueError('SPIR-V bytes and reflection generation differ: ' + path.name)
        entries.append({'key': path.stem, 'offset': offset, 'bytes': len(payload), 'sha256': digest, 'reflection': reflection})
        chunks.append(payload); offset += len(payload)
        ready += not reflection['requires_runtime_specialization'] and reflection['geometry_stride'] == 0
    if not entries or len(entries) > 65536 or offset > 2 * 1024 * 1024 * 1024:
        raise ValueError('Empty or oversized shader library')
    digest = hashlib.sha256()
    for b in chunks: digest.update(b)
    name = 'shaders-' + digest.hexdigest() + '.bin'
    data = out / name
    if data.exists():
        if hashlib.sha256(data.read_bytes()).hexdigest() != digest.hexdigest(): raise ValueError('Immutable shader generation changed')
    else:
        temporary = out / (name + '.tmp')
        with temporary.open('xb') as f:
            for b in chunks: f.write(b)
            f.flush(); os.fsync(f.fileno())
        temporary.replace(data)
    index = {'schema': 's2a.spirv-library.v2', 'bindingConvention': 'nvn-stage256-v1', 'data': name,
             'bytes': offset, 'sha256': digest.hexdigest(), 'entries': entries,
             'runtimeConsumableVariants': ready, 'runtimeReady': False,
             'reason': 'Library consumption is implemented; full NVN replay/resources/backend admission remains required'}
    temp = out / 'shaders.index.json.tmp'
    with temp.open('w', encoding='utf-8') as f:
        json.dump(index, f, ensure_ascii=False, indent=2); f.flush(); os.fsync(f.fileno())
    temp.replace(out / 'shaders.index.json')
    return {'shaders': len(entries), 'bytes': offset, 'runtimeConsumableVariants': ready,
            'runtimeReady': False, 'data': str(data)}
