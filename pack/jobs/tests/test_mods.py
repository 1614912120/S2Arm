# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""资源替换类 mod 导入（pack/jobs/mods.py）与装机推送（install.push_mods）：游戏库换成临时目录，期望手写"""
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import install
import layout
import mods
from core import Failure

GID = "0100ABCD00010000"


class ModsTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        (self.t / "priv").mkdir()
        self.c = types.SimpleNamespace(private=self.t / "priv", msgs=[], diags=[])
        self.c.emit = lambda k, m, **_: self.c.msgs.append(m)
        self.c.diagnostic = lambda m, **k: self.c.diags.append((m, k.get("code")))
        p = patch.object(layout, "path", side_effect=lambda c, gid, *parts, create=True: self.t.joinpath("lib", gid.upper(), *parts))
        p.start(); self.addCleanup(p.stop)
        self.game = {"id": GID}

    def tree(self, files, root="src"):
        r = self.t / root
        for rel, data in files.items():
            f = r / rel; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(data)
        return r

    def zip(self, files, name="pack.zip", extra=()):
        z = self.t / name
        with zipfile.ZipFile(z, "w") as w:
            for rel, data in files.items():
                w.writestr(rel, data)
            for info, data in extra:
                w.writestr(info, data)
        return z

    def test_atmosphere_zip(self):
        z = self.zip({f"atmosphere/contents/{GID}/romfs/Data/a.bin": b"AA", f"atmosphere/contents/{GID}/romfs/b.txt": b"B"}, "HD Textures.zip")
        r = mods.import_paths(self.c, self.game, [str(z)])
        self.assertEqual(r["imported"], ["HD Textures"])
        d = self.t / "lib" / GID / "mods" / "HD Textures" / "romfs"
        self.assertEqual(((d / "Data/a.bin").read_bytes(), (d / "b.txt").read_bytes()), (b"AA", b"B"))
        self.assertEqual(mods.listing(self.c, self.game), [{"name": "HD Textures", "files": 2, "bytes": 3}])

    def test_variants_and_other_game_and_exefs(self):
        # Ryujinx 结构 <程序号>/<名字>/romfs：同一包里两个变体各成一份；标了别的程序号的不收；exefs 补丁只报一句
        src = self.tree({f"{GID}/Blue/romfs/x.bin": b"1", f"{GID}/Red/romfs/x.bin": b"2",
                         "0100FFFF00000000/Other/romfs/y.bin": b"3", f"{GID}/Blue/exefs/1.pchtxt": b"@nsobid-00"}, "Colors")
        r = mods.import_paths(self.c, self.game, [str(src)])
        self.assertEqual(sorted(r["imported"]), ["Colors - Blue", "Colors - Red"])
        self.assertTrue(any("0100FFFF00000000" in n for n in r["notes"]))
        self.assertTrue(any("exefs" in n for n in r["notes"]))
        self.assertFalse((self.t / "lib" / GID / "mods" / "Colors - Other").exists())

    def test_bare_romfs_folder_and_replace(self):
        src = self.tree({"romfs/a.bin": b"old"}, "Fix")
        mods.import_paths(self.c, self.game, [str(src / "romfs")])
        self.assertEqual([m["name"] for m in mods.listing(self.c, self.game)], ["Fix"])   # 直接选 romfs 文件夹：名字取上一级
        src2 = self.tree({"romfs/a.bin": b"new", "romfs/c.bin": b"c"}, "Fix2")
        mods.import_paths(self.c, self.game, [str(src2)])
        mods.import_paths(self.c, self.game, [str(src2)])   # 同名再导入 = 整份替换，不叠旧文件
        self.assertEqual((self.t / "lib" / GID / "mods" / "Fix2" / "romfs" / "a.bin").read_bytes(), b"new")
        self.assertEqual([(m["name"], m["files"]) for m in mods.listing(self.c, self.game)], [("Fix", 1), ("Fix2", 2)])   # 按名字升序

    def test_rejects(self):
        with self.assertRaises(Failure):   # 没有 romfs
            mods.import_paths(self.c, self.game, [str(self.zip({"readme.txt": b"x"}))])
        with self.assertRaises(Failure):   # 不是 zip 也不是文件夹
            (self.t / "a.7z").write_bytes(b"7z"); mods.import_paths(self.c, self.game, [str(self.t / "a.7z")])
        # 逃出目录的条目不解开
        z = self.zip({f"{GID}/m/romfs/ok.bin": b"ok"}, "evil.zip", extra=[("../../escape.bin", b"x")])
        mods.import_paths(self.c, self.game, [str(z)])
        self.assertFalse((self.t / "escape.bin").exists())
        self.assertEqual([m["name"] for m in mods.listing(self.c, self.game)], ["evil"])

    def test_remove(self):
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a"}, "One"))])
        mods.remove(self.c, self.game, ["One"])
        self.assertEqual(mods.listing(self.c, self.game), [])
        with self.assertRaises(Failure):
            mods.remove(self.c, self.game, ["Nope"])

    def test_push_only_changed_and_removed(self):
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a", "romfs/d/b": b"b"}, "Keep"))])
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/n": b"n"}, "New"))])
        keep = mods.fingerprint(self.t / "lib" / GID / "mods" / "Keep")
        calls = []
        cl = types.SimpleNamespace(put=lambda src, rel: calls.append(("put", rel)), rm=lambda rel: (calls.append(("rm", rel)) or (True, "")))
        ph = types.SimpleNamespace(client=lambda w: cl)
        now = install.push_mods(self.c, ph, GID, {"Keep": keep, "Gone": "x"})
        base = f"Documents/games/{GID}/mods"
        self.assertEqual(calls, [("rm", f"{base}/Gone"), ("put", f"{base}/New/romfs/n")])   # Keep 没变不推；Gone 电脑上删了机上也删
        self.assertEqual(set(now), {"Keep", "New"})
        calls.clear()
        self.assertEqual(install.push_mods(self.c, ph, GID, now), now)
        self.assertEqual(calls, [])

    def test_push_failure_is_warning(self):
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a"}, "A"))])
        def bad(src, rel): raise RuntimeError("断开")
        ph = types.SimpleNamespace(client=lambda w: types.SimpleNamespace(put=bad, rm=lambda rel: (True, "")))
        self.assertEqual(install.push_mods(self.c, ph, GID, {}), {})   # 没推成：不记，下次再推
        self.assertEqual([d[1] for d in self.c.diags], ["resource_transfer_failed"])


if __name__ == "__main__":
    unittest.main()
