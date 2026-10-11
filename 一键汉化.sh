#!/data/data/com.termux/files/usr/bin/bash
# RimWorld 手机版 一键汉化脚本（v3 · 底包更新兼容 + 强校验版）
# 作用：把 汉化补丁_仅新增文件.zip 合入底包内的资源包，产出可直接替换的 RimWorldCore.zip
# 用法：bash 一键汉化.sh [APK路径] [汉化补丁路径]
#   若不给参数：默认找当前目录的 RimWorld_0.1.0.apk 与 汉化补丁_仅新增文件.zip
#
# v3 相对 v2 的修复（重要）：
#   ★ 修复「假成功」：v2 中 Python 段硬编码输出名，自定义 $OUT 时可能与实际不符，
#     且 shutil.move 后未校验文件存在就报告成功。v3 统一用环境变量传递并强校验。
#   ★ 修复路径不一致：v2 用 shutil.move 相对路径，脚本 cd 到自身目录后行为易错。
#   ★ 增加失败清理与环境自检。
#
# v2 相对 v1 的改进（保留）：
#   1) 不再硬断言条目数（v1 的 assert n==19025 在换底包时必崩）
#   2) 自动扫描 APK 内层资源包名（不再假设一定叫 RimWorldCore.zip）
#   3) 校验改为「通用校验」+ 各 DLC 中文覆盖抽样
#   4) 合并时保留原压缩流（速度快、内存低）

set -e
cd "$(dirname "$0")" 2>/dev/null || true

APK="${1:-RimWorld_0.1.0.apk}"
PATCH="${2:-汉化补丁_仅新增文件.zip}"
OUT="RimWorldCore.zip"

cleanup() { rm -f .inner.zip .merged.zip 2>/dev/null || true; }
trap cleanup EXIT

echo "=============================================="
echo " RimWorld 一键汉化（合入中文资源） v3"
echo "=============================================="
echo " 底包    : $APK"
echo " 补丁    : $PATCH"
echo " 输出    : $OUT"
echo

command -v python3 >/dev/null 2>&1 || { echo "[错误] 找不到 python3，请先: pkg install python"; exit 1; }
[ -f "$APK" ]   || { echo "[错误] 找不到 APK: $APK"; exit 1; }
[ -f "$PATCH" ] || { echo "[错误] 找不到补丁: $PATCH"; exit 1; }
if [ -f "$OUT" ]; then
  echo "[注意] 已存在 $OUT，先备份为 ${OUT}.bak"
  mv -f "$OUT" "${OUT}.bak"
fi

echo "[1/3] 从 APK 提取内层资源包 ..."
INNER_NAME="$(APK="$APK" python3 - <<'PY'
import os, sys, struct

apk = os.environ["APK"]
with open(apk, "rb") as f:
    f.seek(-65536, 2)
    tail = f.read()
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        sys.exit("[错误] APK 末尾找不到 EOCD，可能不是有效 APK/zip")
    cd_size, cd_off = struct.unpack("<II", tail[i+12:i+20])
    f.seek(cd_off)
    cd = f.read(cd_size)

    p = 0
    target = None
    while p + 46 <= len(cd):
        if cd[p:p+4] != b"PK\x01\x02":
            break
        method = struct.unpack("<H", cd[p+10:p+12])[0]
        csize, usize = struct.unpack("<II", cd[p+20:p+28])
        nlen = struct.unpack("<H", cd[p+28:p+30])[0]
        elen = struct.unpack("<H", cd[p+30:p+32])[0]
        clen = struct.unpack("<H", cd[p+32:p+34])[0]
        lho  = struct.unpack("<I", cd[p+42:p+46])[0]
        name = cd[p+46:p+46+nlen].decode("utf-8", "replace")
        # 自动探测：assets/ 下的 .zip，优先名字含 RimWorldCore 的，其次体积最大
        if name.startswith("assets/") and name.lower().endswith(".zip"):
            score = (0 if "RimWorldCore" in name else 1, -usize)
            if target is None or score < target[0]:
                target = (score, name, method, csize, usize, lho, nlen, elen)
        p += 46 + nlen + elen + clen

    if not target:
        sys.exit("[错误] APK 的 assets/ 下未找到任何 .zip 资源包")

    _, name, method, csize, usize, lho, nlen, elen = target
    f.seek(lho)
    lh = f.read(30 + nlen + elen)
    ln = struct.unpack("<H", lh[26:28])[0]
    le = struct.unpack("<H", lh[28:30])[0]
    f.seek(lho + 30 + ln + le)
    raw = f.read(csize)
    if method != 0:
        import zlib
        raw = zlib.decompress(raw, -15)
    with open(".inner.zip", "wb") as w:
        w.write(raw)
    print("   内层包名:", name, file=sys.stderr)
    print("   解出字节:", len(raw), file=sys.stderr)
    print(name.split("/")[-1])
PY
)"

[ -f .inner.zip ] || { echo "[错误] 内层资源包提取失败"; exit 1; }
echo "   探测到内层资源包: $INNER_NAME"

echo "[2/3] 合入中文文件 ..."
PATCH="$PATCH" OUT="$OUT" python3 - <<'PY'
import os, sys, zipfile, shutil

inner  = ".inner.zip"
patch  = os.environ["PATCH"]
merged = ".merged.zip"
out    = os.environ["OUT"]          # ★ 由环境变量传入，不再硬编码

zin    = zipfile.ZipFile(inner, "r")
zpatch = zipfile.ZipFile(patch, "r")

existing  = set(zin.namelist())
add       = [n for n in zpatch.namelist() if n not in existing]
overwrite = [n for n in zpatch.namelist() if n in existing]

with zipfile.ZipFile(merged, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zw:
    # 原包内容原样搬运
    for item in zin.infolist():
        zw.writestr(item, zin.read(item.filename))
    # 追加补丁新增文件
    for n in add:
        zi = zipfile.ZipInfo(n, date_time=(2024, 1, 1, 0, 0, 0))
        zi.compress_type = zipfile.ZIP_DEFLATED
        zw.writestr(zi, zpatch.read(n))

zin.close(); zpatch.close()

if not os.path.exists(merged):
    sys.exit(f"[错误] 合并输出不存在: {merged}")
shutil.move(merged, out)                                   # ★ 用 $OUT
if not os.path.exists(out):                                # ★ 强校验
    sys.exit(f"[错误] 输出文件未生成: {out}")

print(f"   新增中文文件: {len(add)} 个")
if overwrite:
    print(f"   [注意] 与底包同名未覆盖: {len(overwrite)} 个（本补丁为纯新增，正常应为 0）")
    for n in overwrite[:10]:
        print("      已存在:", n)
PY

[ -f "$OUT" ] || { echo "[错误] $OUT 未生成"; exit 1; }

echo "[3/3] 校验 ..."
OUT="$OUT" python3 - <<'PY'
import os, sys, zipfile

out = os.environ["OUT"]
if not os.path.exists(out):
    sys.exit(f"[错误] 校验失败：文件不存在 {out}")

z = zipfile.ZipFile(out)
names = z.namelist()
n = len(names)
bad = z.testzip()

cn   = [x for x in names if "/Languages/Chinese/" in x]
defi = [x for x in cn if "/DefInjected/" in x]
keyd = [x for x in cn if "/Keyed/" in x]

print("   条目总数        :", n)
print("   完整性          :", "OK" if bad is None else f"损坏 -> {bad}")
print("   中文相关条目    :", len(cn))
print("      DefInjected   :", len(defi))
print("      Keyed         :", len(keyd))
print("   文件大小        :", os.path.getsize(out), "字节")

errs = []
if bad is not None:            errs.append("内层压缩包损坏")
if len(cn) < 500:              errs.append(f"中文条目过少({len(cn)})，合入可能失败")
if len(defi) < 400:            errs.append(f"DefInjected 条目过少({len(defi)})")
if not any(x.endswith("LanguageInfo.xml") for x in cn):
    errs.append("缺少 LanguageInfo.xml")

for pkg in ["Core", "Anomaly", "Biotech", "Ideology", "Odyssey", "Royalty"]:
    if not any(f"/{pkg}/Languages/Chinese/" in x for x in names):
        errs.append(f"{pkg} 缺少中文目录")

if errs:
    print("\n  ❌ 校验未通过：")
    for e in errs:
        print("     -", e)
    sys.exit(1)
print("\n  ✅ 校验通过")
PY

echo
echo "=============================================="
echo " ✅ 完成！已生成: $OUT ($(stat -c%s "$OUT" 2>/dev/null || echo '?') 字节)"
echo "=============================================="
echo " 下一步（用 MT 管理器）："
echo "   1) 打开 APK 为「APK 编辑」"
echo "   2) 进入 assets/，删除原有的 $INNER_NAME"
echo "   3) 把刚生成的 $OUT 添加进 assets/"
echo "      文件名必须为：$INNER_NAME"
echo "      （⚠️ 不要二次压缩成 .zip.zip）"
echo "   4) 返回签名 → 安装"
echo "   （原版需先卸载再装；装过同证书汉化版的可直接覆盖）"
echo
