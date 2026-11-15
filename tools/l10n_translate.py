#!/usr/bin/env python3
"""日 / 西 / 法等新语言的界面文案批量翻译（11-14 i18n 加新语言）：以英文为原文（简中一并给作语义参考），按
launchers/shared/glossary.json 的固定译法，经 Claude API（ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY，可走中转站）分批翻，
占位符（{0}、%@、%ld、%1$@ …）逐条核对，不一致的单条重翻。只在维护者机器上跑，产物随仓库提交；门禁与玩家机器不调 API。

写两处（只补缺的键，人工改过的保留）：
  launchers/shared/l10n/<语言>.json            launcher（按 id）/ text（按简中原句）
  launchers/macos/frontend/l10n/<语言>.json     Mac 前端文案（同 en.json 的键）
翻过的句子缓存在 ~/.cache/s2arm-l10n/<语言>.json，中途断了重跑接着翻。

用法：python3 tools/l10n_translate.py ja|es|fr [--model claude-sonnet-5-5] [--workers 8]
"""
import concurrent.futures as cf
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "launchers/shared"
FRONT = ROOT / "launchers/macos/frontend/l10n"
TABLE = ROOT / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json"
NAMES = {"ja": ("日本語", 3), "es": ("Español", 4), "fr": ("Français", 5)}
LANGUAGE_NAME = {"ja": "Japanese", "es": "Spanish (neutral, for Spain and Latin America)", "fr": "French"}
SLOT = re.compile(r"\{\d+\}|%(?:\d+\$)?(?:l{0,2}[dus]|@|\.?\d*f)")
LETTERS = re.compile(r"[A-Za-z]")
CHUNK = 40


def slots(text):
    return Counter(re.sub(r"%\d+\$", "%", s) for s in SLOT.findall(text or ""))


def settings():
    base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise SystemExit("没有 ANTHROPIC_API_KEY")
    return base, key


def system_prompt(lang):
    glossary = json.loads((SHARED / "glossary.json").read_text(encoding="utf-8"))["terms"]
    terms = "\n".join(f"- {t['en']} → {t[lang]}" for t in glossary if t.get(lang))
    return f"""You translate user-interface strings of S2Arm, a desktop launcher that turns Nintendo Switch games the player owns into native iPhone / iPad / Mac apps, from English into {LANGUAGE_NAME[lang]}.

Rules:
1. Each item has "en" (the English UI text to translate) and "zh" (the original Simplified Chinese, for meaning only). Translate the meaning; keep it as short and plain as the English. These are buttons, labels, hints and error messages.
2. Keep every placeholder exactly as written and the same number of times: {{0}}, {{1}}, %@, %d, %ld, %1$@, %2$ld and similar. You may reorder them if the grammar needs it.
3. Keep unchanged: product and brand names (S2Arm, NX2Apple, iPhone, iPad, Mac, macOS, Windows, Xcode, Impactor, Apple ID, iCloud, GitHub, Switch, Switch 2, Joy-Con, NSP, XCI, IMG, IPA, Metal, .NET), file names, paths, command lines, code, URLs, version numbers.
4. Use these fixed translations for product terms:
{terms}
5. Keep line breaks (\\n) where they are. Do not add quotes, notes or explanations.
6. Never write bracketed plural forms such as (s), (x), (es), (e) or déconnecté(e); rephrase so the sentence works for any count and gender, e.g. "Games: {{0}}" instead of "{{0}} game(s)".

Reply with one JSON object only: {{"<id>": "<translation>", ...}} for every id you were given."""


def call(base, key, model, system, items, attempt=0):
    payload = {"model": model, "max_tokens": 8000, "system": system,
               "messages": [{"role": "user", "content": json.dumps(items, ensure_ascii=False)}]}
    req = urllib.request.Request(base + "/v1/messages", data=json.dumps(payload).encode(),
                                 headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            raw = r.read().decode("utf-8", "replace")
        try:
            text = json.loads(raw)["content"][0]["text"]
            start, end = text.find("{"), text.rfind("}")
            return json.loads(text[start:end + 1])
        except (ValueError, KeyError, IndexError) as e:   # 回的不是消息 JSON（中转站限流返回空 / 网页）或模型没回 JSON：带原文进日志
            raise ValueError(f"{type(e).__name__}：返回开头「{raw[:160]}」") from None
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):   # key 被拒：重试没用，立刻停、说清楚（11-14 自犯：中转站 401 空转 30 分钟没报）
            raise SystemExit(f"🔴 API 拒绝了这个 key（HTTP {e.code}：{e.read()[:200].decode('utf-8', 'replace')}）：检查 ANTHROPIC_API_KEY / 中转站余额后重跑")
        if attempt < 4:
            time.sleep(5 * (attempt + 1))
            return call(base, key, model, system, items, attempt + 1)
        print(f"  这一批没翻成（HTTP {e.code}），下次重跑再翻", file=sys.stderr, flush=True)
        return {}
    except Exception as e:
        if attempt < 4:
            time.sleep(5 * (attempt + 1))
            return call(base, key, model, system, items, attempt + 1)
        print(f"  这一批没翻成（{type(e).__name__}: {str(e)[:120]}），下次重跑再翻", file=sys.stderr)
        return {}


def sources():
    """要翻的英文原文：{英文: 简中参考}；以及三处各自的 键 → 英文"""
    spec = json.loads((SHARED / "experience.v1.json").read_text(encoding="utf-8"))
    launcher = {i["id"]: (i["en"], i["zh-Hans"]) for i in spec["launcher"]["items"]}
    text = {e["source"]: (e["en"], e["source"]) for e in json.loads(TABLE.read_text(encoding="utf-8"))}

    def walk(o, top):
        if isinstance(o, dict):
            if isinstance(o.get("zh-Hans"), str) and isinstance(o.get("en"), str):
                text.setdefault(o["zh-Hans"], (o["en"], o["zh-Hans"]))
            for k, v in o.items():
                if not (top and k == "launcher"):
                    walk(v, False)
        elif isinstance(o, list):
            for v in o:
                walk(v, False)
    walk(spec, True)
    en = json.loads((FRONT / "en.json").read_text(encoding="utf-8"))
    zh = json.loads((FRONT / "zh.json").read_text(encoding="utf-8"))
    front = {k: (v, zh.get(k, "")) for k, v in en.items() if k != "_language" and isinstance(v, str)}
    return launcher, text, front


def main(argv):
    if not argv or argv[0] not in NAMES:
        raise SystemExit(__doc__)
    lang = argv[0]
    model = argv[argv.index("--model") + 1] if "--model" in argv else "claude-sonnet-5-5"
    workers = int(argv[argv.index("--workers") + 1]) if "--workers" in argv else 8
    base, key = settings()
    launcher, text, front = sources()
    cache_path = Path.home() / ".cache/s2arm-l10n" / f"{lang}.json"
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    keep = lambda en: not LETTERS.search(en)   # 没有字母的（纯符号 / 数字 / 占位符）原样
    wanted = {}
    for k, (en, zh) in list(launcher.items()) + list(text.items()) + list(front.items()):
        if en and not keep(en) and not (isinstance(k, str) and k.startswith("language.")):
            wanted.setdefault(en, zh)
    todo = [en for en in wanted if en not in cache]
    print(f"{lang}：要翻的英文 {len(wanted)} 句（去重后），缓存里已有 {len(wanted) - len(todo)}，这次翻 {len(todo)}")
    system = system_prompt(lang)
    call(base, key, model, "Reply with OK.", {"0": "ping"})   # 先试一次：key 被拒就在这里停，不开并发空转
    batches = [todo[i:i + CHUNK] for i in range(0, len(todo), CHUNK)]

    def run(batch):
        items = {str(n): {"en": en, "zh": wanted[en]} for n, en in enumerate(batch)}
        got = call(base, key, model, system, items)
        out, retry = {}, []
        for n, en in enumerate(batch):
            t = got.get(str(n))
            (out.__setitem__(en, t) if isinstance(t, str) and t.strip() and slots(t) == slots(en) else retry.append(en))
        for en in retry:   # 占位符不对或漏了：单条重翻两次
            for _ in range(2):
                t = call(base, key, model, system, {"0": {"en": en, "zh": wanted[en]}}).get("0")
                if isinstance(t, str) and t.strip() and slots(t) == slots(en):
                    out[en] = t
                    break
        return out
    done = 0
    with cf.ThreadPoolExecutor(workers) as pool:
        for out in pool.map(run, batches):
            cache.update(out)
            done += 1
            if done % 10 == 0 or done == len(batches):
                cache_path.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")
                print(f"  {done}/{len(batches)} 批")
    cache_path.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")

    def target(k, en):
        if keep(en) or (isinstance(k, str) and k.startswith("language.")):
            return en
        return cache.get(en)
    out_path = SHARED / "l10n" / f"{lang}.json"
    old = json.loads(out_path.read_text(encoding="utf-8")) if out_path.exists() else {}
    doc = {"_note": f"{NAMES[lang][0]}：tools/l10n_translate.py 以英文为原文经 Claude 批量翻译、按 glossary.json 固定译法、占位符逐条核对；人工改过的条目重跑不覆盖。",
           "language": lang, "launcher": {}, "text": {}}
    for part, table in (("launcher", launcher), ("text", text)):
        for k, (en, _) in table.items():
            t = old.get(part, {}).get(k) or target(k, en)
            if t:
                doc[part][k] = t
    out_path.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    fpath = FRONT / f"{lang}.json"
    fold = json.loads(fpath.read_text(encoding="utf-8")) if fpath.exists() else {}
    fdoc = {"_language": {"name": NAMES[lang][0], "order": NAMES[lang][1], "locales": [lang]}}
    for k, (en, _) in front.items():
        t = fold.get(k) or target(k, en)
        if t:
            fdoc[k] = t
    fpath.write_text(json.dumps(fdoc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    missing = len(todo) - sum(1 for en in todo if en in cache)
    print(f"{lang}：共享界面 {len(doc['launcher'])}/{len(launcher)}、作业层与共享句 {len(doc['text'])}/{len(text)}、Mac 前端 {len(fdoc) - 1}/{len(front)}；没翻成 {missing} 句（重跑补）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
