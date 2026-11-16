#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S2Arm OHOS local packaging CLI. Game inputs, keys and signing stay outside Git."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, re, shutil, struct, subprocess, sys, tarfile, time, uuid
import patch_catalog
import shader_package

if hasattr(sys.stdout, "reconfigure"): sys.stdout.reconfigure(encoding="utf-8")

REPO = Path(__file__).resolve().parents[3]

def direct_closure():
    """translatorClosure of the compiler build linked into the engine (closure.py output embedded by DirectClosure.targets)."""
    generated=REPO/'graphics/tools/direct/compiler/obj/Release/net10.0/DirectBuildIdentity.g.cs'
    match=re.search(r'TranslatorClosure = "([^"]+)"',generated.read_text(encoding='utf-8')) if generated.is_file() else None
    if not match: raise ValueError(f'找不到直连编译器构建身份 {generated}（先跑 NativeAOT）')
    return match.group(1)
BUNDLE = 'io.s2arm.ohos.dev'

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def write(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temp.replace(path)

def sha(path):
    with Path(path).open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()

def key(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}', value): raise ValueError('游戏代号请用小写字母、数字和连字符')
    return value


class BigTarInfo(tarfile.TarInfo):
    """手机端用 toybox tar 解包：它不认 PAX 扩展头里的 size。≥8 GiB 的单个文件（P5R 的 ALL_ASIA.CPK 13.6 GB）
    在纯 PAX 格式下 ustar 头的 size 写 0，toybox 按 0 读、把文件数据当下一个头 → “tar: bad header”。
    PAX 头照旧（含 size），只把 ustar 主头的 size 同时写成 GNU base-256（toybox/GNU tar/bsdtar 都认）。"""
    def create_pax_header(self, info, encoding):
        buf = bytearray(super().create_pax_header(info, encoding))
        if self.size >= 8**11:
            h = len(buf) - 512                  # 最后一块是 ustar 主头
            buf[h+124:h+136] = tarfile.itn(self.size, 12, tarfile.GNU_FORMAT)
            buf[h+148:h+156] = b'        '
            buf[h+148:h+155] = b'%06o\0' % tarfile.calc_chksums(bytes(buf[h:h+512]))[0]
        return bytes(buf)

class Studio:
    def __init__(self, args):
        self.args = args; self.config = read(args.config)
        self.repo = Path(self.config.get('repo', REPO)).resolve()
        self.root = Path(self.config['privateRoot']).resolve()
        if self.root == self.repo or self.repo in self.root.parents: raise ValueError('工作和游戏数据目录必须放在 Git 仓库外')
        self.root.mkdir(parents=True, exist_ok=True)
        self.catalog_path = self.root/self.config.get('library', 'library.json')
        self.catalog = read(self.catalog_path) if self.catalog_path.exists() else {}
        self.job = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:6]
        self.logs = self.root/'jobs'/self.job; self.logs.mkdir(parents=True)
        self.seq = 0
        self.python = self.config.get('python', sys.executable)
        self.dotnet = self.config.get('dotnet', 'dotnet')
        self.deveco = Path(self.config['deveco'])
        self.ndk = self.deveco/'sdk/default/openharmony/native'
        self.hdc = self.deveco/'sdk/default/openharmony/toolchains/hdc.exe'
        self.stage = Path(self.config['appStage'])
        # 出包产物（HAP、资源包 tar）目录：批量出包时放大盘（packagesRoot），缺省私有库下 packages/
        self.packages = Path(self.config.get('packagesRoot') or self.root/'packages')
        self.env = dict(os.environ, PYTHONUTF8='1', PYTHONIOENCODING='utf-8', S2A_TARGET='ohos',
                        JAVA_HOME=str(self.deveco/'jbr'), DEVECO_SDK_HOME=str(self.deveco/'sdk'))
        self.env['PATH'] = os.pathsep.join([*self.config.get('pathPrepend', []), str(self.deveco/'jbr/bin'), str(self.ndk/'llvm/bin'), self.env.get('PATH','')])
        # 宿主 C 改写器的构建环境（Windows：llvm-mingw 的 CC、DevEco 的 cmake/ninja、钉版 capstone/lz4 源码目录），pack/rewriter.py 按它编和取缓存
        self.env.update({k: str(v) for k, v in self.config.get('rewriterEnv', {}).items()})
        # 自旋闸缺省开，同上游 pack/stage_rewrite.sh
        self.env.setdefault('S2A_REWRITE_SPIN', '1')
        # 宽屏扫描器等工具要钉版 capstone / lz4（tools/rewriter-requirements.txt），可单独指定解释器
        self.tool_python = self.config.get('toolPython', self.python)

    def event(self, stage, message, state='running', result=None):
        self.seq += 1
        item = dict(schema=1, contract='s2a.job-event.v1', jobId=self.job, seq=self.seq,
                    timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    type='result' if result is not None else 'stage', operation=self.args.command or 'tui',
                    stage=stage, stageId=stage, state=state, message=message, description=message,
                    code='job.' + state, nextAction='查看本地日志' if state=='failed' else '继续使用 S2Arm')
        if result is not None: item['result'] = result
        with (self.logs/'events.ndjson').open('a', encoding='utf-8') as f: f.write(json.dumps(item,ensure_ascii=False)+'\n')
        print(json.dumps(item,ensure_ascii=False) if self.args.json else f'[{stage}] {message}', flush=True)

    def run(self, stage, command, cwd=None):
        self.event(stage, '正在执行 ' + stage)
        stamp = f'{self.seq:03d}-{stage}'
        with (self.logs/(stamp+'.out')).open('wb') as out, (self.logs/(stamp+'.err')).open('wb') as err:
            p = subprocess.run([str(x) for x in command], cwd=cwd or self.repo, env=self.env, stdout=out, stderr=err)
        # Keys are never read into diagnostics; command paths can be private local paths.
        write(self.logs/(stamp+'.json'), {'command':[str(x) for x in command], 'exitCode':p.returncode})
        if p.returncode: raise RuntimeError(f'{stage} 失败，退出码 {p.returncode}；日志 {self.logs}')
        return (self.logs/(stamp+'.out')).read_text(encoding='utf-8',errors='replace')

    def device(self, stage, args):
        target = self.args.device or self.config.get('device')
        if not target: raise ValueError('请在本地配置中设置 device，或传 --device')
        result = self.run(stage, [self.hdc, '-t', target, *args])
        if '[Fail]' in result or 'error:' in result.lower(): raise RuntimeError(stage+'：设备返回失败，查看日志')
        return result

    def unpacker(self):
        dll = self.repo/'pack/nx_unpack/bin/Release/net10.0/nx_unpack.dll'
        if not dll.exists(): self.run('unpacker.build',[self.dotnet,'build',self.repo/'pack/nx_unpack/nx_unpack.csproj','-c','Release','--nologo'])
        keys = Path(self.config['keys'])
        if not keys.is_file(): raise ValueError('本地配置中的密钥文件不存在；使用自己的导出文件')
        return [self.dotnet,dll,keys]

    def doctor(self):
        paths = {'DevEco':self.deveco,'OHOS SDK':self.ndk,'HDC':self.hdc,'签包工程':self.stage,
                 '运行引擎':Path(self.config['engine']), 'Python':Path(self.python)}
        result = {label:path.exists() for label,path in paths.items()}
        for label, present in result.items(): self.event('doctor',label+(' · 就绪' if present else ' · 缺少'))
        if not all(result.values()): raise RuntimeError('请补齐缺少的本地工具或引擎')
        return result

    def library(self):
        result=[]
        for game, item in self.catalog.items():
            result.append({'key':game,'name':item['metadata']['name'],'version':item['metadata']['version'],
                           'mode':item['metadata'].get('executionMode','generic'),'root':item['root']})
        if not self.args.json:
            for item in result: print(f"  {item['key']:16} {item['name']}  {item['version']}  [{item['mode']}]")
        return {'games':result}

    def register(self, game, root, metadata, carriers, game_root=None):
        game=key(game); root=Path(root).resolve()
        game_dir=Path(game_root) if game_root else root/'game'   # adopt：游戏资源在上游工作根（库里记 gameRoot，不写进设备上的 ready.json）
        if not (game_dir/'exefs/main').is_file() or not (root/metadata.get('moduleDirectory','ohos')/'main.patched.bin').is_file():
            raise ValueError('目录中缺少原始程序或改写模块')
        if not re.fullmatch('[0-9A-Fa-f]{16}',metadata['titleId']): raise ValueError('无效的 titleId')
        metadata['titleId']=metadata['titleId'].upper(); metadata['executionMode']='direct'
        metadata['modeReason']='NVN→Vulkan 直连（只走直连）'
        if game in self.catalog and Path(self.catalog[game]['root']).resolve()!=root: raise ValueError('代号已有另一份游戏，请选择新代号')
        self.catalog[game]={'root':str(root),'metadata':metadata,'carriers':str(Path(carriers).resolve())}
        if game_root: self.catalog[game]['gameRoot']=str(Path(game_root).resolve())
        write(self.catalog_path,self.catalog); self.event('library.register',metadata['name']+' 已加入本地库')
        return self.catalog[game]

    def prepare(self, args):
        game=key(args.key); root=self.root/'games'/game
        if game in self.catalog:
            item=self.catalog[game]
            self.event('prepare.reuse','复用已解包源并核对改写指纹；更换本体或更新包请使用新代号')
            return self.finish_prepare(game,Path(item['root']),dict(item['metadata']))
        root.mkdir(parents=True,exist_ok=True)
        sources=[]
        for source in ([] if (root/'game/unpack.tsv').is_file() else args.source or []):
            path=Path(source).resolve()
            sources.extend(sorted(p for p in path.rglob('*') if p.suffix.lower() in ['.nsp','.xci','.nsz','.xcz']) if path.is_dir() else [path])
        if not sources and not (root/'game/unpack.tsv').is_file(): raise ValueError('请选择 NSP/XCI/NSZ/XCZ 文件或目录')
        containers=[]
        for path in sources:
            if path.suffix.lower() in ['.nsz','.xcz']:
                unpacked=root/'containers';unpacked.mkdir(exist_ok=True)
                dest=unpacked/(path.stem+('.nsp' if path.suffix.lower()=='.nsz' else '.xci'))
                if not dest.exists():
                    nsz=self.config.get('nsz')
                    if not nsz: raise ValueError('压缩包需要在本地配置中指定 nsz 工具')
                    self.run('container.expand',[nsz,'-D','--minimal-output','--keys',self.config['keys'],'-o',unpacked,path],Path(nsz).parent)
                containers.append(dest)
            else: containers.append(path)
        if not (root/'game/unpack.tsv').is_file():
            self.run('game.extract',[*self.unpacker(),root/'game',*(['--title-id='+args.title_id] if args.title_id else []),*containers])
        meta={}
        for line in (root/'game/unpack.tsv').read_text(encoding='utf-8').splitlines():
            name,_,value=line.partition('\t');meta[name]=value
        metadata={'titleId':meta['title_id'].upper(),'name':meta.get('name_zh') or meta['name'],
                  'version':meta['display_version'],'modules':[],'moduleDirectory':'ohos'}
        return self.finish_prepare(game, root, metadata)

    # 上游产物根（pack/orch/oneclick_win.py 组的工作根）里属于程序目录的改写产物，与 rewrite() 写进 ohos-<指纹>/ 的同一组
    MODULE_FILES = ('*.patched.bin', '*.fixups.tsv', '*.gaps.tsv', '*.gates.tsv', '*.sites.tsv', '*.widen.tsv', 'main.npdm',
                    'addr_need.tsv', 'widen_*.tsv', 'fps.tsv', 'nro_modules.tsv', 'nro_exports.tsv', 'gpu_drivers.tsv')
    # 进资源包 game/ 的条目（设备上 games/<代号>/game/）：同 nx_unpack 解包目录，外加上游轻阶段的产物（能力清单）
    GAME_ENTRIES = ('exefs', 'romfs', 'systemdata', 'ctl', 'aoc', 'unpack.tsv', 'romfs.s2aidx', 'icon.jpg', 's2a_caps.tsv', 'shaders')   # shaders/direct = 上游 Vulkan 直连库（b-<链>-vk，运行时按键读库接上前只随包带）

    def adopt(self, args):
        """上游一键出包链（pack/orch/oneclick_win.py --target ohos：解包 → 改写 → 轻阶段 → 抽取 + 直连库 → 组工作根）出的工作根 → 本地库。
        程序目录与签名载体按工作根里的改写产物现出；游戏资源不拷，打包时从工作根直接读（metadata.gameRoot）。"""
        game=key(args.key); w=Path(os.path.realpath(args.root))
        if not (w/'exefs/main').is_file() or not (w/'main.patched.bin').is_file(): raise ValueError('工作根缺 exefs/main 或 main.patched.bin（改写阶段没跑）')
        for f in sorted(w.glob('*.fixups.tsv')):
            head=f.read_text(encoding='utf-8').splitlines()[:16]
            if '# TARGET\tohos' not in head or '# REWRITE_ABI\tohos-sp-safe-v1' not in head:
                raise ValueError(f.name+' 不是鸿蒙目标改写产物（出包时要 S2A_TARGET=ohos）')
        meta={}
        for line in (w/'unpack.tsv').read_text(encoding='utf-8').splitlines():
            name,_,value=line.partition('\t');meta[name]=value
        modules=sorted((p.name for p in (w/'exefs').iterdir() if p.is_file() and (w/(p.name+'.patched.bin')).is_file()),
                       key=lambda n:(0 if n=='main' else 2 if n=='sdk' else 1,n))
        files=sorted({p for pat in self.MODULE_FILES for p in w.glob(pat) if p.is_file()})
        fingerprint=patch_catalog.digest({'schema':1,'target':'ohos','via':'pack.orch','modules':{n:sha(w/'exefs'/n) for n in modules},
                                          'files':{p.name:sha(p) for p in files},'carrierBuilder':sha(self.repo/'ohos/build_signed_modules.py'),
                                          'stage':sha(Path(__file__))})
        # 库里已有的代号：沿用原目录，同一原始程序才收（手机上走程序更新、资源与存档不动）
        root=Path(self.catalog[game]['root']) if game in self.catalog else self.root/'games'/game;root.mkdir(parents=True,exist_ok=True)
        if game in self.catalog and self.catalog[game]['metadata']['titleId'].upper()!=meta['title_id'].upper(): raise ValueError('代号已有另一款游戏，请选择新代号')
        out=root/('ohos-'+fingerprint[:16])
        metadata={'titleId':meta['title_id'].upper(),'name':meta.get('name_zh') or meta['name'],'version':meta['display_version'],
                  'modules':modules,'moduleDirectory':out.name,
                  'sourceBuildIds':{n:(w/'exefs'/n).read_bytes()[0x40:0x60].hex().upper() for n in modules},
                  'preparationFingerprint':fingerprint,'patches':[],'patchesGameplayVerified':False,'requiredRuntimeAbis':[],
                  'presentationAspect':None,'patchTables':{},'pipeline':'pack.orch'}
        receipt=out/'preparation.json'
        if receipt.is_file():
            prior=read(receipt);carriers=Path(prior['carriers'])
            if prior.get('fingerprint')==fingerprint and carriers.is_file() and all(Path(c['library']).is_file() and sha(c['library'])==c['librarySha256'] for c in read(carriers)):
                self.event('code.reuse','工作根改写产物与载体构建器未变，复用签名载体')
                metadata.update(prior['metadata'])
                return self.register(game,root,metadata,carriers,w)
        out.mkdir(exist_ok=True)
        for p in files: shutil.copy2(p,out/p.name)
        carriers=root/('carriers-'+fingerprint[:16])/self.job
        self.run('modules.signable',[self.python,self.repo/'ohos/build_signed_modules.py','--input',out,
                  '--output',carriers,'--native-sdk',self.ndk,'--modules',*modules])
        ready=self.logs/(game+'-ready.json');write(ready,metadata)
        shutil.copy2(self.graphics_descriptor(root,metadata,ready),out/'graphics.v1.json')
        outputs={p.name:sha(p) for p in out.iterdir() if p.is_file() and p.name!='preparation.json'}
        write(receipt,{'fingerprint':fingerprint,'outputs':outputs,'carriers':str(carriers/'manifest.json'),'metadata':metadata})
        self.event('code.adopt',f'工作根 {w.name} → {out.name}（{len(modules)} 个模块，{len(files)} 个程序文件）')
        return self.register(game,root,metadata,carriers/'manifest.json',w)

    def patch_plan(self, root, metadata):
        indexes=getattr(self.args,'patch_index',None) or self.config.get('patchSources',[])
        options=self.config.get('patchOptions',{})
        fps=getattr(self.args,'fps',None) or options.get('fps',60)
        aspect=getattr(self.args,'aspect',None) or options.get('aspect')
        if aspect=='native': aspect=None
        enabled=not getattr(self.args,'no_patches',False) and options.get('enabled',False)
        recipes=getattr(self.args,'patch_recipe',None) or self.config.get('patchRecipes',[])
        plan=patch_catalog.scan(indexes if enabled else [],Path(root)/'game/exefs',metadata,fps,aspect,enabled,recipes if enabled else [])
        write(self.logs/'patch-plan.json',plan)
        self.event('patches.match',f"按原始构建号选择 {len(plan['selected'])} 项补丁；未匹配项与原因已记录")
        return plan

    def patches(self, args):
        item=self.catalog[key(args.key)]; root=Path(item['root'])
        plan=self.patch_plan(root,item['metadata'])
        result={'report':str(self.logs/'patch-plan.json'),'selected':plan['selected'],
                'identity':plan['identity'],'gameplayVerified':False}
        if args.prepare_copy:
            result['preparedExeFs']=str(patch_catalog.materialize(plan,root/'game/exefs',self.root/'patch-candidates'/args.key))
            result['tables']=patch_catalog.write_tables(plan,self.root/'patch-candidates'/args.key/plan['fingerprint']/'tables')
            result['rewritten']=False
        return result

    def finish_prepare(self, game, root, metadata):
        root=Path(root);plan=self.patch_plan(root,metadata)
        exefs=patch_catalog.materialize(plan,root/'game/exefs',root/'patch-candidates')
        modules=list(plan['identity']['modules'])
        modules.sort(key=lambda n:(0 if n=='main' else 2 if n=='sdk' else 1,n))
        # Include the actual input, target, patch selection and implementation.
        # Mere existence of an old .patched.bin must never authorize reuse.
        sources={name:sha(exefs/name) for name in modules}
        inputs={'schema':1,'target':'ohos','patch':plan['fingerprint'],'modules':sources,
                'npdm':sha(exefs/'main.npdm'),'rewriter':self.rewriter_identity(),
                'carrierBuilder':sha(self.repo/'ohos/build_signed_modules.py'),
                'stage':sha(Path(__file__)),
                'patcher':sha(Path(__file__).with_name('patch_catalog.py')),
                'spin':self.env.get('S2A_REWRITE_SPIN','0'),
                'tables':{p.parent.name+'/'+p.name:sha(p) for p in self.build_tables((exefs/'main').read_bytes()[0x40:0x50].hex())},
                'widenVerified':self.widen_verified_row((exefs/'main').read_bytes()[0x40:0x50].hex(),metadata['titleId']) or ''}
        fingerprint=patch_catalog.digest(inputs)
        out=root/('ohos-'+fingerprint[:16]);out.mkdir(exist_ok=True)
        receipt=out/'preparation.json'
        if receipt.is_file():
            prior=read(receipt)
            files_ok=prior.get('fingerprint')==fingerprint and all((out/n).is_file() and sha(out/n)==v for n,v in prior['outputs'].items())
            carriers=Path(prior['carriers'])
            carriers_ok=carriers.is_file() and all(Path(c['library']).is_file() and sha(c['library'])==c['librarySha256'] for c in read(carriers))
            if files_ok and carriers_ok:
                self.event('code.reuse','程序、补丁、改写器及产物哈希均未改变，复用签名载体')
                metadata.update(prior['metadata'])
                return self.register(game,root,metadata,carriers)
            raise ValueError('已有完整改写候选被修改，保留现场并停止；请使用新游戏代号')
        tables=patch_catalog.write_tables(plan,out)
        if tables: raise ValueError('社区补丁表尚未接到上游 C 改写器；请关闭 patchOptions.enabled')
        self.rewrite(exefs,out,modules,root/'game/romfs',metadata['titleId'])
        system=root/'game/systemdata';system.mkdir(exist_ok=True)
        seed=self.config.get('systemData')
        # 种子就是本游戏自己的系统数据目录时不自拷（Windows 上会撞文件占用 WinError 32）
        if seed and Path(seed).resolve()!=system.resolve(): shutil.copytree(seed,system,dirs_exist_ok=True)
        for tid in ['0100000000000802','0100000000000823']:
            dest=system/tid
            if not dest.exists():
                self.run('sysdata.prepare',[self.python,self.repo/'pack/sysdata_synth.py',tid,dest])
                (dest/'.synth').write_text('s2arm upstream format generator\n',encoding='utf-8')
        carriers=root/('carriers-'+fingerprint[:16])/self.job
        self.run('modules.signable',[self.python,self.repo/'ohos/build_signed_modules.py','--input',out,
                  '--output',carriers,'--native-sdk',self.ndk,'--modules',*modules])
        index_dll=self.repo/'services/romfs_index/bin/Release/net10.0/romfs_index.dll'
        if not index_dll.exists(): self.run('index.build',[self.dotnet,'build',self.repo/'services/romfs_index/romfs_index.csproj','-c','Release','--nologo'])
        self.run('resources.index',[self.dotnet,index_dll,root/'game'])
        selected=[c for c in plan['candidates'] if c['status']=='selected']
        metadata.update({'modules':modules,'moduleDirectory':out.name,'sourceBuildIds':{n:m['buildId'] for n,m in plan['identity']['modules'].items()},
                         'preparationFingerprint':fingerprint,'patches':[{k:c[k] for k in ['id','kind','source','sha256','buildId','fps','aspect','hud','license']} for c in selected],
                         'patchesGameplayVerified':False,
                         'requiredRuntimeAbis':sorted({c['requiresRuntime'] for c in selected if c.get('requiresRuntime')}),
                         'presentationAspect':next((c['aspect'] for c in selected if c['kind']=='aspect'),None),
                         'patchTables':{name:value['sha256'] for name,value in tables.items()}})
        # 直连描述随程序目录走（启动器要求程序目录里有 graphics.v1.json 才开局）
        ready=self.logs/(game+'-ready.json');write(ready,metadata)
        shutil.copy2(self.graphics_descriptor(root,metadata,ready),out/'graphics.v1.json')
        outputs={p.name:sha(p) for p in out.iterdir() if p.is_file() and p.name!='preparation.json'}
        write(receipt,{'fingerprint':fingerprint,'inputs':inputs,'outputs':outputs,'carriers':str(carriers/'manifest.json'),'metadata':metadata})
        return self.register(game,root,metadata,carriers/'manifest.json')

    def rewriter_path(self):
        if not getattr(self, '_rewriter', None):
            out = self.run('code.rewriter-build', [self.python, '-X', 'utf8', self.repo/'pack/rewriter.py', 'c-path'])
            self._rewriter = Path(out.strip().splitlines()[-1])
        return self._rewriter

    def rewriter_identity(self):
        """改写器编译输入指纹 + 实际二进制摘要 + 本阶段调的转换脚本：任何一项变了都重改写。"""
        source = self.run('code.rewriter-source', [self.python, '-X', 'utf8', self.repo/'pack/rewriter.py', 'source']).strip()
        return patch_catalog.digest({'source': source, 'binary': sha(self.rewriter_path()),
                                     'nro': sha(self.repo/'runtime/rewriter/nro_to_nso.py'),
                                     'widen': sha(self.repo/'graphics/widen/scan/wide_scan.py'),
                                     'addr': sha(self.repo/'tools/addr_need.py')})

    def build_tables(self, build):
        """按 main 构建号挑仓库表（同 pack/stage_rewrite.sh）：60 帧表 runtime/fps/<前 16 位>.tsv、宽屏启用 / 放宽表
        graphics/widen/tables/<款>_<构建号>/、宽屏已验证名单里平台列为 ohos 的那一行。表内容进指纹，改表重出程序目录。"""
        found = []
        fps = self.repo/'runtime/fps'/(build[:16]+'.tsv')
        if fps.is_file(): found.append(fps)
        for table in sorted((self.repo/'graphics/widen/tables').glob('*_'+build)):
            found += sorted(p for p in table.glob('widen_*.tsv') if p.name.startswith(('widen_enable.', 'widen_full')))
        return found

    def widen_verified_row(self, build, title):
        path = self.repo/'graphics/widen/tables/verified.tsv'
        if not path.is_file(): return None
        for line in path.read_text(encoding='utf-8').splitlines():
            cols = line.split('\t')
            if line.startswith('#') or len(cols) < 4: continue
            if cols[0].upper() == title.upper() and cols[1].lower() == build and cols[3].lower() == 'ohos': return line
        return None

    def rewrite(self, exefs, out, modules, romfs, title=''):
        """上游 pack/stage_rewrite.sh 的同一组步骤，目标 ohos：地址需求 → 宽屏候选 → 帧率表 → 逐模块 C 改写 → GPU 驱动名单 / NRO 导出表。"""
        exefs, out, romfs = Path(exefs), Path(out), Path(romfs)
        py = [self.tool_python, '-X', 'utf8']
        build = (exefs/'main').read_bytes()[0x40:0x50].hex()
        shutil.copy2(exefs/'main.npdm', out/'main.npdm')
        self.run('code.addr-need', [*py, self.repo/'tools/addr_need.py', build, out/'addr_need.tsv',
                                    '--npdm', exefs/'main.npdm', '--key', '--main', exefs/'main'])
        self.run('code.widen-scan', [*py, self.repo/'graphics/widen/scan/wide_scan.py', exefs, '--tsv', out/'widen_sites.tsv'])
        for stale in list(out.glob('widen_enable*.tsv')) + list(out.glob('widen_full*.tsv')) + [out/'widen_verified.tsv', out/'fps.tsv']:
            stale.unlink(missing_ok=True)
        tables = [p for p in self.build_tables(build) if p.name.startswith('widen_')]
        for table in tables: shutil.copy2(table, out/table.name)
        self.event('code.widen', '宽屏表 '+(', '.join(sorted(t.parent.name+'/'+t.name for t in tables)) or '无＝不加宽'))
        verified = self.widen_verified_row(build, title) if tables else None
        if verified: (out/'widen_verified.tsv').write_text(verified+'\n', encoding='utf-8', newline='\n')
        self.event('code.widen-verified', '宽屏已验证（ohos）' if verified else '不在 ohos 宽屏已验证名单：16:9 出包（S2A_WIDEN_VERIFIED=1 可试）')
        fps = self.repo/'runtime/fps'/(build[:16]+'.tsv')
        saved = self.env; self.env = dict(saved, S2A_TARGET='ohos')
        for name in ('S2A_FPS_TSV', 'S2A_CPATCH_TSV', 'S2A_CODE_PATCH', 'S2A_CODE_BUILD'): self.env.pop(name, None)
        if fps.is_file():
            shutil.copy2(fps, out/'fps.tsv'); self.env['S2A_FPS_TSV'] = str(out/'fps.tsv')
            self.event('code.fps', '帧率表 '+fps.name)
        try:
            # romfs 里的 NRO 先转成 NSO（nro0…）与 exefs 模块一样改写；运行时按 nro_modules.tsv 映射
            nroexe = out/'nroexe'
            shutil.rmtree(nroexe, ignore_errors=True)
            if romfs.is_dir():
                self.run('code.nro', [*py, self.repo/'runtime/rewriter/nro_to_nso.py', romfs, nroexe])
            if (nroexe/'nro_modules.tsv').is_file(): shutil.move(nroexe/'nro_modules.tsv', out/'nro_modules.tsv')
            inputs = [(exefs/m, m) for m in modules] + [(p, p.name) for p in sorted(nroexe.glob('nro*')) if p.is_file()]
            for path, name in inputs:
                self.run('code.rewrite', [self.rewriter_path(), path, out, name, out/'widen_sites.tsv'])
                header = (out/(name+'.fixups.tsv')).read_text(encoding='utf-8').splitlines()
                if '# TARGET\tohos' not in header or '# REWRITE_ABI\tohos-sp-safe-v1' not in header:
                    raise RuntimeError(name+' 改写产物不是鸿蒙目标（TARGET/REWRITE_ABI 不符）')
            shutil.rmtree(nroexe, ignore_errors=True)
        finally:
            self.env = saved
        (out/'gpu_drivers.tsv').write_text(self.run('code.gpu-drivers', [*py, self.repo/'graphics/nvn/games/profile_guess.py', '--gpu-drivers', exefs]), encoding='utf-8', newline='\n')   # 与上游 shell 重定向同字节（Windows 不转 CRLF）
        if romfs.is_dir():
            self.run('code.nro-exports', [*py, self.repo/'tools/nro_exports.py', romfs, out/'nro_exports.tsv'])
        self.event('code.rewrite', f'改写 {len(modules)} 个模块（目标 ohos，构建号 {build[:16]}）')

    def oneclick(self, args):
        item=self.prepare(args)
        application=self.build()
        resources=self.package(args.key)
        result={'application':application,'resources':resources,'metadata':item['metadata'],
                'installed':False,'gameplayVerified':False}
        if args.install:
            self.install(application['hap']);self.deploy(args.key);result['installed']=True
        write(self.logs/'oneclick-manifest.json',result)
        return result

    def extracted(self, args):
        game=key(args.key);root=self.root/'games'/game
        if game in self.catalog:
            item=self.catalog[game]
            self.event('prepare.reuse','复用该代号原有解包源；更换游戏版本请使用新代号')
            return self.finish_prepare(game,Path(item['root']),dict(item['metadata']))
        root.mkdir(parents=True,exist_ok=True)
        game_root=root/'game';game_root.mkdir(exist_ok=True)
        exefs=Path(args.exefs).resolve();romfs=Path(args.romfs).resolve();control=Path(args.control).resolve()
        npdm=(exefs/'main.npdm').read_bytes()
        aci=struct.unpack_from('<I',npdm,0x70)[0]
        if npdm[aci:aci+4]!=b'ACI0': raise ValueError('原始 main.npdm 缺少 ACI0 程序标识')
        title=f'{struct.unpack_from("<Q",npdm,aci+0x10)[0]:016X}'
        nacp=control.read_bytes()
        def text_at(offset,length): return nacp[offset:offset+length].split(b'\0',1)[0].decode('utf-8',errors='replace').strip()
        name=text_at(0,0x200);version=text_at(0x3060,16)
        self.event('game.copy','准备已解包的 '+name)
        if not (game_root/'exefs/main').exists(): shutil.copytree(exefs,game_root/'exefs',dirs_exist_ok=True)
        # Original resource directories remain read-only; copies never share writable file bytes.
        if not (game_root/'.romfs-copy-complete').exists():
            shutil.copytree(romfs,game_root/'romfs',dirs_exist_ok=True)
            (game_root/'.romfs-copy-complete').write_text('complete\n',encoding='utf-8')
        (game_root/'ctl').mkdir(exist_ok=True);shutil.copy2(control,game_root/'ctl/control.nacp')
        if args.icon: shutil.copy2(args.icon,game_root/'icon.jpg')
        metadata={'titleId':title,'name':name,'version':version,'modules':[],'moduleDirectory':'ohos'}
        return self.finish_prepare(game,root,metadata)

    def split(self, archive, limit_gb):
        """Byte-exact volumes name.tar.001, .002 ... (concatenated in name order they are the archive)."""
        limit=int(limit_gb*1073741824)
        if limit<64*1048576: raise ValueError('分卷大小至少 0.0625 GiB')
        parts=[];index=0
        with open(archive,'rb') as src:
            while True:
                index+=1;path=archive.with_name(archive.name+f'.{index:03d}');left=limit;h=hashlib.sha256()
                with open(path,'wb') as out:
                    while left>0:
                        chunk=src.read(min(left,8*1048576))
                        if not chunk: break
                        out.write(chunk);h.update(chunk);left-=len(chunk)
                size=path.stat().st_size
                if size==0: path.unlink();break
                parts.append({'path':str(path),'bytes':size,'sha256':h.hexdigest()})
                self.event('resources.split',f'分卷 {path.name} {size/1073741824:.2f} GiB')
                if size<limit: break
        return parts

    def package(self, game, split_gb=0):
        game=key(game);item=self.catalog[game];root=Path(item['root'])
        archive=self.packages/(game+'-'+self.job+'.tar');archive.parent.mkdir(exist_ok=True)
        ready=self.logs/(game+'-ready.json');write(ready,item['metadata'])
        self.event('resources.package','正在打包 '+item['metadata']['name'])
        count=0;size=0;last=time.monotonic()
        with tarfile.open(archive,'w',format=tarfile.PAX_FORMAT,tarinfo=BigTarInfo) as tar:
            gr=item.get('gameRoot')
            # adopt 的游戏资源在上游工作根：逐条目取实际目录（工作根条目是联接），包内路径仍是 game/<条目>
            tops=([(Path(os.path.realpath(Path(gr)/e)),'game/'+e) for e in self.GAME_ENTRIES if (Path(gr)/e).exists()] if gr else [(root/'game','game')])
            tops.append((root/item['metadata'].get('moduleDirectory','ohos'),item['metadata'].get('moduleDirectory','ohos')))
            for top,arc in tops:
                subtree=arc
                if top.is_file():
                    tar.add(top,arcname=arc,recursive=False);count+=1;size+=top.stat().st_size;continue
                for directory,dirs,names in os.walk(top,followlinks=False):
                    dirs.sort()
                    for name in dirs:
                        if (Path(directory)/name).is_symlink(): raise ValueError('资源目录中不允许符号链接')
                    for name in sorted(names):
                        if not subtree.startswith('game') and name=='preparation.json': continue
                        path=Path(directory)/name
                        if path.is_symlink(): raise ValueError('资源目录中不允许符号链接')
                        tar.add(path,arcname=arc+'/'+path.relative_to(top).as_posix(),recursive=False)
                        count+=1;size+=path.stat().st_size
                        if time.monotonic()-last>5:
                            self.event('resources.package',f'已打包 {count} 个文件 / {size/1073741824:.2f} GiB')
                            last=time.monotonic()
            tar.add(ready,arcname='ready.json')
            # The phone's in-app importer (TarImport.ets) publishes the package under this key.
            marker=self.logs/(game+'-s2arm-import.json');write(marker,{'key':game})
            tar.add(marker,arcname='s2arm-import.json')
            if not (root/item['metadata'].get('moduleDirectory','ohos')/'graphics.v1.json').is_file():
                raise ValueError('程序目录缺直连描述 graphics.v1.json，请重新准备')
        result={'key':game,'path':str(archive),'bytes':archive.stat().st_size,'sha256':sha(archive)}
        if split_gb: result['parts']=self.split(archive,split_gb)
        item['package']=result;write(self.catalog_path,self.catalog);return result

    def graphics_descriptor(self, root, metadata, ready):
        """graphics.v1.json for the direct path (ohos/tools/direct/make_graphics_descriptor.py rules).
        Only for prepared modules with rewritten binaries; the device computes its own effective profile."""
        directory=Path(root)/metadata.get('moduleDirectory','ohos');names=metadata.get('modules') or []
        if not names or not all((directory/f'{n}.patched.bin').is_file() for n in names): return None
        digest=hashlib.sha256()
        for n in names: digest.update(n.encode()+b'\0'+sha(directory/f'{n}.patched.bin').encode()+b'\n')
        # closure 必须等于链进包的编译器的 DirectBuildIdentity（否则每次现场编译都 IDENTITY 拒绝）
        closure=direct_closure()
        doc={'schema':'s2a-graphics-v1','titleId':metadata['titleId'].upper(),'gameContentRoot':'sha256-'+sha(ready),
             'moduleSetDigest':'sha256-'+digest.hexdigest(),'frontend':'nvn','backend':'vulkan-direct','directABI':1,
             'translatorClosure':closure,'sourceParserVersion':1,'runtimeCompilerABI':'s2a-direct-compile-v1',
             # 没有离线着色器文件时 profiles 也必须为空（上游 graphics.c：files/profiles 要么都空、要么都有）
             'profiles':[],'files':[]}
        path=self.logs/(metadata['titleId'].lower()+'-graphics.v1.json')
        path.write_bytes((json.dumps(doc,indent=2)+'\n').encode())
        return path

    def build(self):
        ready_path = getattr(self.args, 'match_ready', None)
        if ready_path:
            ready = read(ready_path)
            profiles = [entry['metadata'] for entry in self.catalog.values()]
            fields = ('titleId', 'moduleDirectory', 'preparationFingerprint')
            if not all(ready.get(field) for field in fields) or not any(
                all(profile.get(field) == ready[field] for field in fields) for profile in profiles
            ):
                raise ValueError('程序目录与签名载体不匹配，请选择包含目标设备 preparationFingerprint 的游戏库')
        required={abi for item in self.catalog.values() for abi in item['metadata'].get('requiredRuntimeAbis',[])}
        if required: raise ValueError('安装包要求尚不支持的运行期补丁ABI：'+'、'.join(sorted(required)))
        self.event('app.stage','组合通用界面、运行库与游戏代码载体')
        app=self.repo/'ohos/app'
        for rel in ['AppScope','entry/src/main/ets','entry/src/main/resources','entry/src/main/cpp']:
            shutil.copytree(app/rel,self.stage/rel,dirs_exist_ok=True)
        # hvigor resolves the native module's typings from the installed oh_modules copy, not cpp/types:
        # refresh it, otherwise a new NAPI export fails ArkTS checking against a stale declaration.
        typings=self.stage/'entry/oh_modules/libs2aprobehost.so'
        if typings.is_dir():
            shutil.copytree(app/'entry/src/main/cpp/types/libs2aprobehost',typings,dirs_exist_ok=True)
        shutil.copytree(self.repo/'ohos/probes/external-memory',
                        self.stage/'entry/src/main/cpp/s2a_memory_probe_source',dirs_exist_ok=True)
        shutil.copy2(self.repo/'ohos/native/ohos_h264.c',
                     self.stage/'entry/src/main/cpp/s2a_memory_probe_source/ohos_h264.c')
        # Build the isolated VM probe from the same platform source as the game runtime.
        shutil.rmtree(self.stage/'entry/src/main/cpp/s2a_memory_probe_source/vm-source',ignore_errors=True)
        for rel in ['platform/plat.h', 'graphics/track/track_platform.h', 'android/native/runtime/tracking/platform.c', 'ohos/native/plat_ohos.c', 'ohos/native/tsd_ohos.h', 'android/native/guest_signal.h', 'android/native/memory.h', 'android/native/runtime/tracking/mirror.h', 'ohos/native/guest_read.c', 'runtime/include/s2a_native.h', 'graphics/track/s2a_track.h']:
            dest=self.stage/'entry/src/main/cpp/s2a_memory_probe_source/vm-source'/rel
            dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(self.repo/rel,dest)
        libs=self.stage/'entry/libs/arm64-v8a';libs.mkdir(parents=True,exist_ok=True)
        shutil.copy2(self.config['engine'],libs/'libS2AEngine.so')
        # Only this library's games: carriers left by an earlier build in the same stage are removed.
        for stale in libs.glob('libs2a_guest_*.so'): stale.unlink()
        carrier_names={}
        for item in self.catalog.values():
            carriers = read(item['carriers'])
            if ready_path and item['metadata']['titleId'] == ready['titleId']:
                directory = Path(item['root']) / ready['moduleDirectory']
                if sorted(c['module'] for c in carriers) != sorted(ready['modules']):
                    raise ValueError('签名载体的模块列表与设备不同')
                for carrier in carriers:
                    for suffix, field in (('.patched.bin', 'rawSha256'), ('.fixups.tsv', 'fixupsSha256')):
                        if sha(directory / (carrier['module'] + suffix)) != carrier[field]:
                            raise ValueError('签名载体与目标程序文件的摘要不同：' + carrier['module'] + suffix)
            for carrier in carriers:
                path=Path(carrier['library'])
                if sha(path)!=carrier['librarySha256']: raise ValueError('游戏代码载体与清单不一致')
                if path.name in carrier_names and carrier_names[path.name]!=carrier['librarySha256']:
                    raise ValueError('同一构建号有不同补丁代码载体，不能放入同一个壳：'+path.name)
                carrier_names[path.name]=carrier['librarySha256']
                shutil.copy2(path,libs/path.name)
        self.run('app.build',[self.deveco/'tools/node/node.exe',self.deveco/'tools/hvigor/bin/hvigorw.js','--mode','module',
            '-p','product=default','-p','module=entry@default','-p','buildMode=debug','assembleHap','--no-daemon'],self.stage)
        hap=self.stage/'entry/build/default/outputs/default/entry-default-signed.hap'
        self.run('app.signature',[self.deveco/'jbr/bin/java.exe','-jar',self.deveco/'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar',
                 'verify-app','-inFile',hap,'-outCertChain',self.logs/'certificate.cer','-outProfile',self.logs/'profile.p7b'])
        dest=self.packages/('S2Arm-'+self.job+'.hap');dest.parent.mkdir(exist_ok=True);shutil.copy2(hap,dest)
        version=read(app/'AppScope/app.json5')['app']
        manifest={'schema':'s2a.artifact.v2','target':'ohos','files':[{'path':dest.name,'role':'application','size':dest.stat().st_size,'sha256':sha(dest)}],
                  'details':{'schema':'s2a.artifact.ohos.v1','bundle':BUNDLE,'versionCode':version['versionCode'],
                             'versionName':version['versionName'],'executionMode':'direct','privateGameCode':True}}
        write(dest.with_suffix('.json'),manifest)
        if not ready_path: write(self.root/'latest-build.json',{'hap':str(dest),'manifest':str(dest.with_suffix('.json'))})
        return {'hap':str(dest),'sha256':manifest['files'][0]['sha256']}

    def install(self, hap=None):
        path=Path(hap or read(self.root/'latest-build.json')['hap'])
        manifest=read(path.with_suffix('.json'))
        if manifest['details']['bundle']!=BUNDLE or manifest['files'][0]['sha256']!=sha(path): raise ValueError('安装包身份或摘要不匹配')
        result=self.device('app.install',['install','-r',path])
        if 'install bundle successfully' not in result: raise RuntimeError('设备未确认安装成功')
        self.device('app.open',['shell','aa','start','-a','EntryAbility','-b',BUNDLE])
        return {'installed':str(path)}

    def deploy(self, game):
        game=key(game);item=self.catalog[game]
        base='data/storage/el2/base/haps/entry/files';dest=base+'/games/'+game
        exists=self.device('resources.check',['shell','-b',BUNDLE,'if test -e '+dest+'/ready.json; then echo PRESENT; else echo ABSENT; fi'])
        if 'PRESENT' in exists: return self.deploy_code_update(game,item,dest)
        package=item.get('package') or self.package(game);path=Path(package['path'])
        if sha(path)!=package['sha256']: raise ValueError('资源包已变化，请重新出包')
        upload=base+'/import-'+self.job+'.tar';temp=base+'/games/.import-'+self.job
        self.device('resources.send',['file','send','-b',BUNDLE,path,'/'+upload])
        check=self.device('resources.digest',['shell','-b',BUNDLE,'sha256sum '+upload])
        if not check.split() or check.split()[0]!=package['sha256']: raise RuntimeError('设备资源包摘要不一致')
        result=self.device('resources.import',['shell','-b',BUNDLE,
             'test ! -e '+dest+' && mkdir -p '+temp+' && tar -xmf '+upload+' -C '+temp+' && echo S2ARM_IMPORT_OK'])
        # 上传的 tar 只是传输副本：解完就删（旧实现一直留着，每款游戏在手机上占两倍空间）。
        # 失败时连半截临时目录一起清掉：重试用新任务号重新发送，旧副本不会被复用，只会堆积。
        if 'S2ARM_IMPORT_OK' not in result:
            self.device('resources.cleanup',['shell','-b',BUNDLE,'rm -f '+upload+'; rm -rf '+temp])
            raise RuntimeError('导入未完成：手机上的上传副本与临时目录已清理，可直接重试（'+result.strip()[-160:]+'）')
        self.device('resources.cleanup',['shell','-b',BUNDLE,'rm -f '+upload])
        request=self.logs/('pending-import-'+self.job+'.json')
        write(request,{'key':game,'directory':'.import-'+self.job})
        self.device('resources.finalize',['file','send','-b',BUNDLE,request,'/'+base+'/'+request.name])
        self.event('resources.ready','资源已送达；打开游戏库或点击刷新完成导入')
        return {'transferred':game,'finalizeOnLibraryOpen':True,'sha256':package['sha256']}


    def deploy_code_update(self, game, item, dest):
        root=Path(item['root']);metadata=item['metadata']
        remote=self.device('resources.identity',['shell','-b',BUNDLE,'cat '+dest+'/ready.json']).strip()
        current=json.loads(remote)
        if current.get('titleId','').upper()!=metadata['titleId']:
            raise ValueError('手机已有另一游戏身份，保留资源与存档')
        if current.get('preparationFingerprint') and current.get('preparationFingerprint')==metadata.get('preparationFingerprint'):
            self.event('resources.reuse','手机程序指纹相同，复用现有资源和存档')
            return {'reused':True}
        directory=metadata.get('moduleDirectory','ohos')
        if not re.fullmatch(r'ohos-[0-9a-f]{16}',directory):
            self.event('resources.reuse','手机已有游戏；此旧版准备记录没有可增量更新的程序指纹')
            return {'reused':True,'legacyMetadata':True}
        # Never replace game assets with another version merely because the title
        # matches. Compare the original executable before a code-only update.
        original=self.device('resources.original-hash',['shell','-b',BUNDLE,'sha256sum '+dest+'/game/exefs/main']).split()
        main=Path(item['gameRoot'])/'exefs/main' if item.get('gameRoot') else root/'game/exefs/main'   # 上游工作根（adopt）的原始程序在产物目录
        if not original or original[0]!=sha(main):
            raise ValueError('手机原始程序与本地版本不同，未改资源或存档；请使用新游戏代号')
        archive=self.logs/'code-update.tar'
        ready=self.logs/'code-update-ready.json';write(ready,metadata)
        with tarfile.open(archive,'w',format=tarfile.PAX_FORMAT,tarinfo=BigTarInfo) as tar:
            for path in sorted((root/directory).iterdir()):
                if path.name=='preparation.json': continue
                if not path.is_file() or path.is_symlink(): raise ValueError('程序目录只允许普通文件')
                tar.add(path,arcname=directory+'/'+path.name,recursive=False)
            tar.add(ready,arcname='ready.json',recursive=False)
            # 上游工作根（adopt）里随出包变的小件：能力清单（60 帧 / 宽屏开关，runtime/src/caps.c 读 game/s2a_caps.tsv）
            caps=Path(item['gameRoot'])/'s2a_caps.tsv' if item.get('gameRoot') else None
            if caps and caps.is_file(): tar.add(caps,arcname='game/s2a_caps.tsv',recursive=False)
        base='data/storage/el2/base/haps/entry/files'
        upload=base+'/code-update-'+self.job+'.tar';temp=base+'/games/.code-update-'+self.job
        self.device('resources.code-send',['file','send','-b',BUNDLE,archive,'/'+upload])
        remote_hash=self.device('resources.code-hash',['shell','-b',BUNDLE,'sha256sum '+upload]).split()
        if not remote_hash or remote_hash[0]!=sha(archive): raise RuntimeError('程序更新包传输哈希不一致')
        extracted=self.device('resources.code-extract',['shell','-b',BUNDLE,'mkdir -p '+temp+' && tar -xmf '+upload+' -C '+temp+' && echo S2ARM_CODE_EXTRACTED'])
        if 'S2ARM_CODE_EXTRACTED' not in extracted: raise RuntimeError('程序包未完整解开，未更新当前游戏元数据')
        # The app's hdc debug shell may not rename (HarmonyOS denies it for -b), so the new
        # directory is copied into place and every file is checked by hash before ready.json moves.
        existing=self.device('resources.code-check',['shell','-b',BUNDLE,'if test -d '+dest+'/'+directory+'; then echo PRESENT; else echo ABSENT; fi'])
        if 'PRESENT' not in existing:
            published=self.device('resources.code-publish',['shell','-b',BUNDLE,'test ! -e '+dest+'/'+directory+' && cp -r '+temp+'/'+directory+' '+dest+'/'+directory+' && test -f '+dest+'/'+directory+'/main.patched.bin && echo S2ARM_CODE_READY'])
            if 'S2ARM_CODE_READY' not in published: raise RuntimeError('新增程序目录未就绪，未更新当前游戏元数据')
        for path in sorted((root/directory).iterdir()):
            if path.name=='preparation.json': continue
            if not re.fullmatch(r'[A-Za-z0-9_.-]+',path.name): raise ValueError('无效程序文件名')
            value=self.device('resources.code-existing-hash',['shell','-b',BUNDLE,'sha256sum '+dest+'/'+directory+'/'+path.name]).split()
            if not value or value[0]!=sha(path):
                raise RuntimeError('手机程序目录内容与本地不同，未更新当前游戏元数据' if 'PRESENT' not in existing else '手机同指纹程序目录内容不同，未覆盖')
        # ready.json is published last; old code directories and every save stay.
        if caps and caps.is_file():
            self.device('resources.code-caps',['shell','-b',BUNDLE,'cp '+temp+'/game/s2a_caps.tsv '+dest+'/game/s2a_caps.tsv'])
            got=self.device('resources.code-caps-hash',['shell','-b',BUNDLE,'sha256sum '+dest+'/game/s2a_caps.tsv']).split()
            if not got or got[0]!=sha(caps): raise RuntimeError('能力清单回读不一致，未更新当前游戏元数据')
        self.device('resources.code-activate',['shell','-b',BUNDLE,'cp '+temp+'/ready.json '+dest+'/ready.json'])
        check=json.loads(self.device('resources.code-readback',['shell','-b',BUNDLE,'cat '+dest+'/ready.json']))
        if check!=metadata: raise RuntimeError('程序更新元数据回读不一致')
        self.device('resources.code-cleanup',['shell','-b',BUNDLE,'rm -r '+temp+' '+upload])
        return {'codeUpdated':True,'moduleDirectory':directory,'assetsAndSavesPreserved':True}

    def launch(self, game, request_id=None, timeout=120):
        game=key(game)
        request_id=request_id or ('launch-'+uuid.uuid4().hex)
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{7,63}',request_id): raise ValueError('请求ID需8–64位小写字母、数字或连字符')
        if not 1 <= timeout <= 600: raise ValueError('等待时间需1–600秒')
        write(self.logs/'launch-request.json',{'requestId':request_id,'key':game})
        self.device('launch.request',['shell','aa','start','-a','EntryAbility','-b',BUNDLE,
                    '--ps','s2armLaunchId',request_id,'--ps','s2armGameKey',game])
        path='data/storage/el2/base/haps/entry/files/launch-results/launch-result-'+request_id+'.json'
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            response=self.device('launch.poll',['shell','-b',BUNDLE,
                     'if test -f '+path+'; then cat '+path+'; else echo S2ARM_LAUNCH_PENDING; fi']).strip()
            if response and response!='S2ARM_LAUNCH_PENDING':
                # 结果文件可能正写到一半：先重读几次。一直读不出 JSON 就把设备的原话报出来
                # （例如 hdc 服务被旧版占用时是 "/bin/sh: - : unknown option"），不等到超时。
                try: result=json.loads(response); bad=0
                except ValueError:
                    bad=locals().get('bad',0)+1
                    if bad>=5: raise RuntimeError('启动结果读不出来（设备返回）：'+response[:160])
                    time.sleep(1); continue
                if result.get('requestId')!=request_id or result.get('key')!=game:
                    raise RuntimeError('启动请求ID冲突；未尝试第二次起局')
                write(self.logs/'launch-result.json',result)
                if result.get('status')=='runtime-started':
                    self.event('launch.runtime','运行时已启动；不代表首帧或可玩验收')
                    return result
                if result.get('status')!='accepted':
                    raise RuntimeError('启动未完成：'+str(result.get('status'))+' · '+str(result.get('message')))
            time.sleep(1)
        raise RuntimeError('等待启动结果超时，未停止游戏。请求ID='+request_id+'；可用同一 --request-id 查询，勿盲目新起局')

    def extract_shaders(self, game, output=None, source=None):
        game=key(game);item=self.catalog[game]
        out=Path(output or self.root/'shaders'/(game+'-'+self.job)).resolve()
        root=Path(source).resolve() if source else Path(item['root'])/'game'
        self.run('shaders.extract',[self.python,Path(__file__).with_name('shader_extract.py'),
            '--repo',self.repo,'--input',root,'--output',out])
        result=self.shaders(out/'jobs.json',out/'compiled')
        result['extraction']=str(out/'extraction.json')
        return result

    def shaders(self, jobs, output):
        tool=self.config.get('shaderTranslator')
        if not tool: raise ValueError('本地尚未配置 Vulkan 离线翻译器；通用模式仍可出包，不能标为直连就绪')
        out=Path(output).resolve()
        if out==self.repo or self.repo in out.parents: raise ValueError('着色器产物必须在仓外')
        self.run('shaders.batch',[self.dotnet,tool,Path(jobs).resolve(),out])
        result=shader_package.build(out)
        result['resourceRelativePath']='shaders/vulkan'
        return result

    def choose(self, prompt, choices):
        gum=shutil.which('gum')
        if gum:
            p=subprocess.run([gum,'choose','--header',prompt,*choices],capture_output=True,text=True,encoding='utf-8')
            return p.stdout.strip() if p.returncode==0 else ''
        print('\n'+prompt)
        for i,value in enumerate(choices,1): print(f'  {i}. {value}')
        answer=input('选择编号（回车退出）: ').strip()
        return choices[int(answer)-1] if answer.isdigit() and 0<int(answer)<=len(choices) else ''

    def tui(self):
        print('\nS2Arm  /  STUDIO 05\n你的游戏，随身继续。')
        while True:
            action=self.choose('要做什么？',['查看游戏库','一键出包','准备游戏','查看补丁适配','离线翻译着色器','构建鸿蒙安装包','安装到手机','传输游戏资源','检查环境','退出'])
            if action in ['', '退出']: return {'closed':True}
            try:
                if action=='查看游戏库': self.library()
                elif action in ['准备游戏','一键出包']:
                    source=input('游戏文件或目录: ').strip().strip('"');game=input('游戏代号（英文/数字）: ').strip()
                    request=argparse.Namespace(key=game,source=[source],title_id=None,install=False)
                    if action=='一键出包': self.oneclick(request)
                    else: self.prepare(request)
                elif action=='查看补丁适配':
                    game=self.choose('选择游戏',list(self.catalog))
                    if game: print(self.patches(argparse.Namespace(key=game,prepare_copy=False))['report'])
                elif action=='离线翻译着色器':
                    game=self.choose('选择游戏',list(self.catalog))
                    if game: self.extract_shaders(game)
                elif action=='构建鸿蒙安装包': self.build()
                elif action=='安装到手机': self.install()
                elif action=='传输游戏资源':
                    game=self.choose('选择游戏',list(self.catalog))
                    if game: self.deploy(game)
                elif action=='检查环境': self.doctor()
            except (OSError,ValueError,RuntimeError,KeyError) as error: print('未完成：'+str(error))

def patch_arguments(parser):
    parser.add_argument('--patch-index',action='append',help='本地补丁 INDEX.tsv，可重复；不下载或分发补丁')
    parser.add_argument('--patch-recipe',action='append',help='显式本地构建号与原始SHA绑定的补丁配方，可重复')
    parser.add_argument('--fps',choices=['native','60'],help='请求60帧补丁；运行期配方须与兼容FPS引擎一起出包')
    parser.add_argument('--aspect',help='native或宽:高；参数配方按精确比例生成，静态补丁须比例相同')
    parser.add_argument('--no-patches',action='store_true',help='关闭本次出包补丁')

def main():
    parser=argparse.ArgumentParser(description='S2Arm 本地出包与鸿蒙部署（可选 gum 交互）')
    parser.add_argument('--config',type=Path,default=Path(os.environ.get('S2ARM_CONFIG',Path.home()/'.config/s2arm/ohos.json')))
    parser.add_argument('--json',action='store_true',help='输出上游 JobEvent v1 NDJSON')
    parser.add_argument('--device',help='HDC Wi-Fi 地址或设备标识')
    sub=parser.add_subparsers(dest='command')
    for name in ['doctor','library','tui']: sub.add_parser(name)
    build=sub.add_parser('build')
    build.add_argument('--match-ready',type=Path,help='按目标设备 ready.json 核对程序指纹，生成专用包并保留当前 latest')
    adopt=sub.add_parser('adopt',help='收上游一键出包（oneclick_win --target ohos）组好的工作根');adopt.add_argument('--key',required=True);adopt.add_argument('--root',required=True)
    add=sub.add_parser('add');add.add_argument('--key',required=True);add.add_argument('--prepared',required=True);add.add_argument('--metadata',required=True);add.add_argument('--carriers',required=True)
    prepare=sub.add_parser('prepare');prepare.add_argument('--key',required=True);prepare.add_argument('--source',action='append',help='已解包过的代号可省略');prepare.add_argument('--title-id')
    patch_arguments(prepare)
    oneclick=sub.add_parser('oneclick',help='准备程序与资源、构建签名壳、输出分离资源包')
    oneclick.add_argument('--key',required=True);oneclick.add_argument('--source',action='append',required=True);oneclick.add_argument('--title-id')
    oneclick.add_argument('--install',action='store_true',help='出包后同签安装并导入；请先在游戏内保存退出')
    patch_arguments(oneclick)
    patches=sub.add_parser('patches',help='按原始Title ID/Build ID核对补丁，不操作手机')
    patches.add_argument('key');patches.add_argument('--prepare-copy',action='store_true',help='只生成独立NSO候选，不改写、不装机')
    patch_arguments(patches)
    for name in ['package','deploy']:
        command=sub.add_parser(name);command.add_argument('key')
        if name=='package': command.add_argument('--split-gb',type=float,default=0,help='把游戏包切成不超过该大小（GiB）的分卷 .tar.001…，便于网盘传输；手机导入时一起选中全部分卷')
    extracted=sub.add_parser('prepare-extracted');extracted.add_argument('--key',required=True);extracted.add_argument('--exefs',required=True);extracted.add_argument('--romfs',required=True);extracted.add_argument('--control',required=True);extracted.add_argument('--icon')
    patch_arguments(extracted)
    launch=sub.add_parser('launch');launch.add_argument('key');launch.add_argument('--request-id');launch.add_argument('--timeout',type=int,default=120)
    install=sub.add_parser('install');install.add_argument('--hap')
    shaders=sub.add_parser('shaders');origin=shaders.add_mutually_exclusive_group(required=True)
    origin.add_argument('--jobs');origin.add_argument('--key');shaders.add_argument('--output');shaders.add_argument('--input',help='可选：只扫描指定资源目录')
    args=parser.parse_args();studio=None
    try:
        studio=Studio(args)
        if args.command in ['doctor','library','build','tui',None]: result=getattr(studio,args.command or 'tui')()
        elif args.command=='add': result=studio.register(args.key,args.prepared,read(args.metadata),args.carriers)
        elif args.command=='prepare': result=studio.prepare(args)
        elif args.command=='adopt': result=studio.adopt(args)
        elif args.command=='oneclick': result=studio.oneclick(args)
        elif args.command=='patches': result=studio.patches(args)
        elif args.command=='prepare-extracted': result=studio.extracted(args)
        elif args.command=='package': result=studio.package(args.key,args.split_gb)
        elif args.command=='deploy': result=studio.deploy(args.key)
        elif args.command=='install': result=studio.install(args.hap)
        elif args.command=='launch': result=studio.launch(args.key,args.request_id,args.timeout)
        elif args.command=='shaders':
            if args.key: result=studio.extract_shaders(args.key,args.output,args.input)
            elif args.output: result=studio.shaders(args.jobs,args.output)
            else: raise ValueError('--jobs 需要 --output')
        studio.event('job','任务完成','succeeded',result or {});return 0
    except KeyboardInterrupt:
        if studio: studio.event('job','已取消；已有产物保留','cancelled',{})
        return 130
    except (OSError,ValueError,RuntimeError,KeyError) as error:
        if studio: studio.event('job',str(error),'failed',{})
        else: print('无法开始：'+str(error),file=sys.stderr)
        return 1

if __name__=='__main__': raise SystemExit(main())
