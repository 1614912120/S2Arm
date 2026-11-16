#!/bin/bash
# 补帧画质客观评测：tools/fi_eval.sh <帧目录> <输出目录> [模式名=环境…]…
#   帧目录 = 一段 60 帧游戏的连续真帧 f_<n>.png（Mac 局 S2A_DIRECT_REC=<起始帧>:<帧数> 存在 <局目录>/rec/；DM_NVN_SHOT_OUT=1920x1080 = 补帧的输入尺寸）。
#   偶数帧当 30 帧游戏交的帧，用生产补帧代码（graphics/nvn/tests/fi_eval.m 含 nvn_mtl.m）补出中间帧，与真的奇数帧比 PSNR / SSIM（整体 / 静止区 / 运动边缘区）。
#   每个模式参数是「名字=环境变量串」，环境用 + 连接，如 zero=DM_PRESENT_FI_MV=0  mv=DM_PRESENT_FI_MV=1  copy=FI_EVAL_MODE=copy；不给就跑缺省四组（零矢量 / 自算矢量 / 复制真帧 / 两帧平均）。
#   输出：<输出目录>/<模式>.tsv（逐帧）与 summary.tsv（每模式三行：全部 / 慢段 / 快段的均值，快慢按镜头运动量中位数分；区域另有 hud = 整段 ≥ 90% 时间不变的常驻界面像素），终端打对位表。
#   区域均值只算该区域有像素的帧（某帧没有运动边缘就不计入边缘列）。FI_EVAL_REUSE=1：已有 <模式>.tsv 的不重跑、只重算汇总。
#   FI_EVAL_SAVE=<间隔>：每隔这么多帧存一张补出帧到 <输出目录>/shots/（肉眼核对用）。FI_EVAL_BUILD：编译目录（缺省 <输出目录>/build）。
#   帧与输出都含游戏画面，只放仓库外。
set -u
FR=$(cd "${1:?帧目录}" && pwd) || exit 2; OUT=${2:?输出目录}; shift 2
R=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
for p in "$FR" "$OUT"; do case "$p/" in "$R"/*) echo "🔴 $p 在仓库里：帧 / 评测输出含游戏画面，只放仓库外"; exit 2;; esac; done
B=${FI_EVAL_BUILD:-$OUT/build}; mkdir -p "$B"
(cd "$R" && make -s BUILD="$B" CC=cc fi-eval-tool) > "$OUT/build.log" 2>&1 || { echo "🔴 评测工具编不过（见 $OUT/build.log）"; tail -5 "$OUT/build.log"; exit 1; }
[ $# -gt 0 ] || set -- zero=DM_PRESENT_FI_MV=0 mv=DM_PRESENT_FI_MV=1 copy=FI_EVAL_MODE=copy blend=FI_EVAL_MODE=blend
SV=${FI_EVAL_SAVE:-0}; [ "$SV" -gt 0 ] && mkdir -p "$OUT/shots"
printf 'mode\tseg\tn\tmotion\tpsnr\tssim\tpsnr_static\tssim_static\tpsnr_edge\tssim_edge\tpsnr_hud\tssim_hud\tgpu_ms\tjob_ms\n' > "$OUT/summary.tsv"
for m in "$@"; do
  name=${m%%=*}; envs=${m#*=}; [ "$name" = "$m" ] && envs=
  # 环境串用 + 分隔，逐个按 KEY=VAL 加进 env 参数（不靠分词）
  ea=(); rest=$envs; while [ -n "$rest" ]; do one=${rest%%+*}; ea+=("$one"); [ "$one" = "$rest" ] && rest= || rest=${rest#*+}; done
  [ -n "${FI_EVAL_REUSE:-}" ] && [ -s "$OUT/$name.tsv" ] || env DM_PRESENT_FI=1 "${ea[@]}" "$B/tools/fi_eval" "$FR" "$OUT/$name.tsv" ${SV:+$( [ "$SV" -gt 0 ] && printf '%s %s' "$OUT/shots" "$SV")} > "$OUT/$name.log" 2>&1 \
    || { echo "🔴 模式 $name 失败（见 $OUT/$name.log）"; tail -3 "$OUT/$name.log"; continue; }
  # 快慢按本段镜头运动量中位数分（同一帧目录各模式一样）
  med=$(awk -F'\t' 'NR > 1 {print $2}' "$OUT/$name.tsv" | sort -g | awk '{a[NR] = $1} END {print NR ? a[int((NR + 1) / 2)] : 0}')
  awk -F'\t' -v m="$name" -v med="$med" 'function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ } function add(s) { n[s]++; for (c = 2; c <= 14; c++) if (num($c)) { v[s, c] += $c; k[s, c]++ } }
    function f(s, c) { return k[s, c] ? v[s, c] / k[s, c] : "nan" }
    NR > 1 { add("全部"); add($2 <= med ? "慢" : "快") }
    END { split("全部 慢 快", S, " "); for (i = 1; i <= 3; i++) { s = S[i]; if (!n[s]) continue
      printf "%s\t%s\t%d\t%.2f\t%.2f\t%.4f\t%.2f\t%.4f\t%.2f\t%.4f\t%.2f\t%.4f\t%s\t%s\n", m, s, n[s], f(s, 2), f(s, 3), f(s, 4), f(s, 5), f(s, 6), f(s, 7), f(s, 8), f(s, 13), f(s, 14), k[s, 11] ? sprintf("%.2f", v[s, 11] / k[s, 11]) : "-", k[s, 12] ? sprintf("%.2f", v[s, 12] / k[s, 12]) : "-" } }' "$OUT/$name.tsv" >> "$OUT/summary.tsv"
done
echo "帧目录 ${FR}，$(ls "$FR" | grep -c '^f_[0-9]*\.png$') 张真帧；PSNR 单位 dB；静止 = 前后两帧不变的像素，边缘 = 运动且有边缘的像素，hud = 整段 ≥ 90% 时间不变的像素（常驻界面）"
column -t -s $'\t' "$OUT/summary.tsv"
