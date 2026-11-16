"""资源替换类 mod（LayeredFS）导入（11-15 维护者「咱们也可以支持 mod 导入」）：一款游戏文件夹的 mods/ 是唯一的家。
  · 布局：mods/<名字>/romfs/**（服务层 services/S2A.Services/RomFsMods.cs 起局时按文件夹名升序叠到本体 RomFS 上，后叠的覆盖先叠的）。
    Mac 起局经 S2A_MODS_DIR 指到这里（pack/jobs/build.py）；装到 iPhone 时推进机上本款文档根 mods/（pack/jobs/install.py push_mods）。
  · 导入：玩家给 zip 或文件夹，按常见发布结构找出每个 romfs/（Atmosphere atmosphere/contents/<程序号>/romfs、Ryujinx <程序号>/<名字>/romfs、
    直接 <名字>/romfs、只有 romfs/），一个 romfs 一份 mod；标了别的程序号的 romfs 不收（不是这款的）。
  · 不收：exefs/（代码补丁：pchtxt / IPS，走社区补丁那条路，这里只报一句）、romfs 以外的东西、符号链接、逃出目录的路径。
  · 只是文件搬运：不解析、不执行 mod 里的任何东西。"""
from __future__ import annotations

import re
import shutil
import tempfile
import zipfile
from pathlib import Path

from core import Failure

DIR = "mods"
MAX_BYTES = 16 << 30          # 一次导入解开后的总大小上限（大号资源 mod 也就几 GB；防压缩炸弹）
MAX_FILES = 200_000
GID_RE = re.compile(r"^[0-9A-Fa-f]{16}$")
NAME_BAD = re.compile(r'[\x00-\x1f/\\:*?"<>|]')


def mods_dir(c, gid, create=True):
    import layout
    return layout.path(c, gid, DIR, create=create)


def _safe_name(s):
    s = NAME_BAD.sub("_", s).strip(" .") or "mod"
    return s[:80]


def _unpack(src, work):
    """zip → 解到 work；文件夹 → 原样用。逃出目录 / 符号链接 / 超量 → 报错"""
    src = Path(src)
    if src.is_dir():
        return src
    if not src.is_file() or not zipfile.is_zipfile(src):
        raise Failure("mod 要选 zip 压缩包或文件夹（7z / rar 先解压成文件夹再导入）：%s" % src.name, code="job_failed")
    out = Path(work) / "z"
    total = 0
    with zipfile.ZipFile(src) as z:
        infos = z.infolist()
        if len(infos) > MAX_FILES:
            raise Failure("这个压缩包文件太多（超过 %d 个）：%s" % (MAX_FILES, src.name), code="job_failed")
        for i in infos:
            name = i.filename.replace("\\", "/")
            parts = [p for p in name.split("/") if p not in ("", ".")]
            if not parts or ".." in parts or name.startswith("/"):
                continue
            if (i.external_attr >> 16) & 0o170000 == 0o120000:   # 符号链接：不收
                continue
            total += i.file_size
            if total > MAX_BYTES:
                raise Failure("这个压缩包解开超过 16 GB：%s" % src.name, code="job_failed")
            dst = out.joinpath(*parts)
            if i.is_dir():
                dst.mkdir(parents=True, exist_ok=True)
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            with z.open(i) as r, open(dst, "wb") as w:
                shutil.copyfileobj(r, w, 1 << 20)
    return out


def _find(root, gid):
    """→ ([(mod 名, romfs 目录)], [说明]）。romfs 目录名大小写都认；路径上出现别的程序号 = 不是这款，不收"""
    found, notes, exefs = [], [], False
    root = Path(root)
    if root.name.lower() == "romfs":   # 玩家直接选的就是 romfs 文件夹
        return [("", root)], notes
    for d in sorted(p for p in root.rglob("*") if p.is_dir() and not p.is_symlink()):
        low = d.name.lower()
        if low == "exefs" and any(f.suffix.lower() in (".pchtxt", ".ips") for f in d.iterdir() if f.is_file()):
            exefs = True
        if low != "romfs" or any(q.name.lower() == "romfs" for q in d.relative_to(root).parents if q != Path(".")):
            continue
        rel = d.relative_to(root).parts[:-1]
        ids = [p.upper() for p in rel if GID_RE.match(p)]
        if ids and gid.upper() not in ids:
            notes.append("「%s」是给另一款游戏（%s）的，没收" % ("/".join(rel) or "romfs", ids[-1]))
            continue
        label = [p for p in rel if not GID_RE.match(p) and p.lower() not in ("atmosphere", "contents", "mods")]
        found.append(("/".join(label[-2:]) if label else "", d))
    if exefs:
        notes.append("里面的代码补丁（exefs 的 pchtxt / IPS）这里不收：只导入资源替换（romfs）")
    return found, notes


def import_paths(c, game, paths):
    """玩家导入（zip 或文件夹，可多选）：每个找到的 romfs 存成 mods/<名字>/romfs（同名整份替换）。→ {imported: [名字], notes: [说明]}
    一个都没找到 = 报错（说清要什么结构）"""
    gid = game["id"].upper()
    home = mods_dir(c, gid)
    home.mkdir(parents=True, exist_ok=True)
    imported, notes = [], []
    for raw in paths:
        src = Path(raw)
        base = _safe_name(src.stem if src.is_file() else src.parent.name if src.name.lower() == "romfs" else src.name)
        with tempfile.TemporaryDirectory(dir=c.private) as work:
            root = _unpack(src, work)
            found, why = _find(root, gid)
            notes += why
            if not found:
                raise Failure("「%s」里没找到 romfs 文件夹：资源替换 mod 要带 romfs/（如 atmosphere/contents/%s/romfs）。" % (src.name, gid), code="job_failed")
            for label, rd in found:
                name = _safe_name(base if len(found) == 1 or not label else "%s - %s" % (base, label.replace("/", " - ")))
                files = [f for f in rd.rglob("*") if f.is_file() and not f.is_symlink()]
                if not files:
                    notes.append("「%s」的 romfs 是空的，没收" % name)
                    continue
                tmp = home / (".importing-" + name)
                shutil.rmtree(tmp, ignore_errors=True)
                shutil.copytree(rd, tmp / "romfs", symlinks=True, ignore=lambda d, ns: [n for n in ns if Path(d, n).is_symlink()])
                dst = home / name
                if dst.exists():
                    shutil.rmtree(dst)
                tmp.rename(dst)
                imported.append(name)
    return dict(imported=imported, notes=notes)


def listing(c, game):
    """→ [{name, files, bytes}]（按叠加顺序：文件夹名升序）"""
    home = mods_dir(c, game["id"].upper(), create=False)
    out = []
    if home.is_dir():
        for d in sorted(p for p in home.iterdir() if p.is_dir() and not p.name.startswith(".")):
            files = [f for f in (d / "romfs").rglob("*") if f.is_file()] if (d / "romfs").is_dir() else []
            out.append(dict(name=d.name, files=len(files), bytes=sum(f.stat().st_size for f in files)))
    return out


def remove(c, game, names):
    home = mods_dir(c, game["id"].upper(), create=False)
    have = {it["name"] for it in listing(c, game)}
    for n in names:
        if n not in have:
            raise Failure("没有这个 mod：%s。" % n, code="job_failed")
        shutil.rmtree(home / n)


def fingerprint(d):
    """一份 mod 的内容记号（相对路径 + 大小 + 改动时间）：装机时只推变了的（install.push_mods）"""
    import hashlib
    h = hashlib.sha256()
    for f in sorted(p for p in Path(d).rglob("*") if p.is_file()):
        st = f.stat()
        h.update(f"{f.relative_to(d).as_posix()}\t{st.st_size}\t{int(st.st_mtime)}\n".encode())
    return h.hexdigest()[:16]
