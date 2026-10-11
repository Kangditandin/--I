#!/data/data/com.termux/files/usr/bin/bash
# RimWorld 手机版 一键汉化脚本
# 作用：把 汉化补丁_仅新增文件.zip 合入原版 RimWorldCore.zip，产出可直接替换的 RimWorldCore.zip
# 用法：bash 一键汉化.sh [原版APK路径] [汉化补丁路径]
#   - 若不给参数，默认找当前目录的 RimWorld_0.1.0.apk 与 汉化补丁_仅新增文件.zip
#
# 输出：./RimWorldCore.zip   （已含全量中文，需用 MT 管理器替换进 APK 的 assets/ 并重新签名）

set -e
cd "$(dirname "$0")" 2>/dev/null || true

APK="${1:-RimWorld_0.1.0.apk}"
PATCH="${2:-汉化补丁_仅新增文件.zip}"
OUT="RimWorldCore.zip"
TMP=".rw_patch_tmp"

echo "=============================================="
echo " RimWorld 一键汉化（合入中文资源）"
echo "=============================================="
echo " APK     : $APK"
echo " 补丁    : $PATCH"
echo " 输出    : $OUT"
echo

# --- 检查命令 ---
command -v python3 >/dev/null 2>&1 || { echo "[错误] 找不到 python3，请先: pkg install python"; exit 1; }
[ -f "$APK" ]   || { echo "[错误] 找不到 APK: $APK"; exit 1; }
[ -f "$PATCH" ] || { echo "[错误] 找不到补丁: $PATCH"; exit 1; }
[ -f "$OUT" ]   && { echo "[注意] 已存在 $OUT，将覆盖（原文件先备份为 ${OUT}.bak）"; mv -f "$OUT" "${OUT}.bak"; }

echo "[1/3] 从 APK 提取原版 RimWorldCore.zip ..."
APK="$APK" OUT="$OUT" python3 - <<'PY'
import os, sys, struct, zipfile, io

apk = os.environ["APK"]; out = os.environ["OUT"]

with open(apk, "rb") as f:
    f.seek(-65536, 2); tail = f.read()
    i = tail.rfind(b"PK\x05\x06")
    if i < 0: sys.exit("[错误] APK 末尾找不到 EOCD，可能不是有效 APK/zip")
    cd_size, cd_off = struct.unpack("<II", tail[i+12:i+20])
    f.seek(cd_off); cd = f.read(cd_size)

    p = 0; target = None
    while p < len(cd):
        if cd[p:p+4] != b"PK\x01\x02": break
        method = struct.unpack("<H", cd[p+10:p+12])[0]
        csize, usize = struct.unpack("<II", cd[p+20:p+28])
        nlen = struct.unpack("<H", cd[p+28:p+30])[0]
        elen = struct.unpack("<H", cd[p+30:p+32])[0]
        clen = struct.unpack("<H", cd[p+32:p+34])[0]
        lho = struct.unpack("<I", cd[p+42:p+46])[0]
        name = cd[p+46:p+46+nlen].decode("utf-8", "replace")
        if name == "assets/RimWorldCore.zip":
            target = (method, csize, usize, lho, nlen, elen); break
        p += 46 + nlen + elen + clen

    if not target:
        sys.exit("[错误] APK 内未找到 assets/RimWorldCore.zip")

    method, csize, usize, lho, nlen, elen = target
    f.seek(lho); lh = f.read(30 + nlen + elen)
    ln = struct.unpack("<H", lh[26:28])[0]
    le = struct.unpack("<H", lh[28:30])[0]
    f.seek(lho + 30 + ln + le)
    raw = f.read(csize)
    if method != 0:
        import zlib
        raw = zlib.decompress(raw, -15)
    with open(out, "wb") as w:
        w.write(raw)
    print("   提取完成:", out, len(raw), "字节")
PY

echo "[2/3] 合入中文文件 ..."
OUT="$OUT" PATCH="$PATCH" python3 - <<'PY'
import os, zipfile, shutil

out = os.environ["OUT"]; patch = os.environ["PATCH"]
merged = out + ".merged"

zin = zipfile.ZipFile(out, "r")
zpatch = zipfile.ZipFile(patch, "r")

add = [n for n in zpatch.namelist() if n not in set(zin.namelist())]

with zipfile.ZipFile(merged, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zw:
    for item in zin.infolist():
        zw.writestr(item, zin.read(item.filename))
    for n in add:
        zw.writestr(n, zpatch.read(n))

zin.close(); zpatch.close()
shutil.move(merged, out)
print("   合入完成，新增中文文件:", len(add), "个")
PY

echo "[3/3] 校验 ..."
OUT="$OUT" python3 - <<'PY'
import os, zipfile
out = os.environ["OUT"]
z = zipfile.ZipFile(out)
bad = z.testzip()
n = len(z.namelist())
core = "Data/Core/Languages/Chinese/Keyed/Misc.xml" in z.namelist()
print("   条目总数:", n, "（应为 19025）")
print("   完整性  :", "OK" if bad is None else ("损坏: " + bad))
print("   Core中文:", "OK" if core else "缺失")
assert n == 19025, "条目数异常，合入可能失败"
PY

sz=$(stat -c%s "$OUT" 2>/dev/null || echo "?")
echo
echo "=============================================="
echo " ✅ 完成！已生成: $OUT ($sz 字节)"
echo "=============================================="
echo " 下一步（用 MT 管理器）："
echo "   1) 打开 RimWorld_0.1.0.apk 为「APK 编辑」"
echo "   2) 进入 assets/，删除原 RimWorldCore.zip"
echo "   3) 把刚生成的 $OUT 添加进 assets/（文件名须为 RimWorldCore.zip）"
echo "   4) 返回签名 → 安装"
echo "   （原版需先卸载再装；装过同证书汉化版的可直接覆盖）"
echo
