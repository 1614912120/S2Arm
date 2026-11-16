#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Content-based NVN extraction for the local Vulkan batch translator.

Uses the existing container readers. Unsupported archives are recorded, never
reported as complete coverage. No per-title rules or game-specific edits.
"""
import argparse, hashlib, importlib.util, json, os, struct, sys
from pathlib import Path


def extract(repo, source, output):
    repo,source,output=map(lambda p:Path(p).resolve(),(repo,source,output))
    if output==repo or repo in output.parents: raise ValueError('Shader output must be outside Git')
    output.mkdir(parents=True,exist_ok=True)
    profile=output/'source-profile';profile.mkdir(exist_ok=True)
    # The shared parser imports profile labels; these carry no translation facts.
    (profile/'game.tsv').write_text('shader_groups\t\nshader_note\tAutomatic content scan\nmodules\tmain sdk\n',encoding='utf-8')
    os.environ['DM_GAME']=str(profile)
    parser=repo/'translator/shader_split.py'
    spec=importlib.util.spec_from_file_location('s2arm_shared_shader_split',parser)
    shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
    code_dir=output/'guest';code_dir.mkdir(exist_ok=True)
    unique={};unsupported=[];scanned=0
    for directory,dirs,names in os.walk(source):
        dirs.sort()
        for name in sorted(names):
            path=Path(directory)/name;rel=path.relative_to(source).as_posix()
            if path.is_symlink(): continue
            if path.stat().st_size>64*1024*1024:
                unsupported.append({'source':rel,'reason':'Large archive needs its container reader; not scanned by this bounded pass'})
                continue
            try:
                with path.open('rb') as f: magic=f.read(4)
                if magic==b'NSO0':
                    data=shared.nso_image(str(path));found=[]
                    shared.scan_blob(data,rel,found)
                    found+=shared.glslc_shaders(data,rel,need=False)
                    found=shared.uniq_keys(found)
                else:
                    _,found,_,extra=shared.scan_file((str(path),rel))
                    if extra=='defer': unsupported.append({'source':rel,'reason':'Unity type tree required'})
                for short,row in found.items():
                    where,stage,control,code=row
                    digest=hashlib.sha256(control[:shared.ctl_len(control)]+code).hexdigest()
                    unique.setdefault(digest,row)
                scanned+=1
            except (Exception,SystemExit) as error:
                unsupported.append({'source':rel,'reason':str(error)[:400]})
            if scanned and scanned%500==0: print(f'scanned {scanned}; unique shaders {len(unique)}',flush=True)
    jobs=[];sources=[]
    for digest,(where,stage,control,code) in sorted(unique.items()):
        try:
            c1o,c1end=struct.unpack_from('<2I',control,0x700)
            if not 0<=c1o<=c1end<=len(code): raise ValueError('Invalid constant segment bounds')
            constants=code[c1o:c1end]
            if stage!='cs': instructions=code[0x30:]
            elif code[:4]==shared.CS_MAGIC:
                if any(code[0x30:0x100]): raise ValueError('Unknown compute header padding')
                instructions=code[0x100:]
            else: instructions=code
            path=code_dir/(digest+'.bin');path.write_bytes(instructions)
            base={'key':digest,'code':str(path),'stage':stage,'c1':constants.hex(),
                  'debug':False,'originUpperLeft':True,'runtimeSpecializationRequired':True}
            if stage=='cs':
                base['local']=list(struct.unpack_from('<3I',control,0x748))
                base['shared']=(struct.unpack_from('<I',control,0x754)[0]+15)//16*16
            # Both depth conventions are legal runtime inputs. Do not guess one.
            for depth in ([False,True] if stage in ('vs','gs','ds') else [False]):
                jobs.append(dict(base,key=digest+('-depth11' if depth else '-depth01'),depthMode=depth))
            sources.append({'key':digest,'source':where,'stage':stage})
        except (ValueError,struct.error) as error:
            unsupported.append({'source':where,'reason':str(error)})
    (output/'jobs.json').write_text(json.dumps(jobs,ensure_ascii=False,indent=2),encoding='utf-8')
    report={'schema':'s2a.shader-extraction.v1','scannedFiles':scanned,'uniqueShaders':len(sources),
            'jobs':len(jobs),'coverage':'partial','unsupported':unsupported,'sources':sources,
            'runtimeReady':False,'reason':'Runtime texture, vertex and pipeline facts still required'}
    (output/'extraction.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:report[k] for k in ('scannedFiles','uniqueShaders','jobs','coverage','runtimeReady')}),flush=True)
    if not jobs: raise ValueError('No supported shader containers found; see extraction.json')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();extract(a.repo,a.input,a.output)
