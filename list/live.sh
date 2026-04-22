#!/bin/bash

set -e

BASE=$(pwd)

DOWN_LIST="$BASE/list/down.txt"
FILES_DIR="$BASE/files"
DOWN_DIR="$BASE/down"
LIST_DIR="$BASE/list"

EXTINF_TEMPLATE="$LIST_DIR/extinf.m3u"
NAME_DICT="$LIST_DIR/name.txt"

mkdir -p "$FILES_DIR" "$DOWN_DIR"

echo "===== 清理 down 目录 ====="
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR"

echo "===== 下载源 ====="
declare -A seen

while IFS=',' read -r name url; do
  [ -z "$url" ] && continue

  hash=$(echo "$url" | md5sum | cut -d' ' -f1)

  if [[ -z "${seen[$hash]}" ]]; then
    seen[$hash]=1
    echo "下载: $name"
    curl -L --max-time 20 "$url" -o "$FILES_DIR/$hash.txt" || continue
  fi
done < "$DOWN_LIST"

echo "===== TXT 转 M3U ====="

TMP_M3U="$DOWN_DIR/tmp.m3u"
> "$TMP_M3U"

for file in "$FILES_DIR"/*.txt; do
  [ -e "$file" ] || continue

  while IFS= read -r line || [ -n "$line" ]; do
    name=$(echo "$line" | cut -d',' -f1)
    url=$(echo "$line" | cut -d',' -f2-)

    [ -z "$url" ] && continue

    echo "#EXTINF:-1,tvg-name=\"$name\" group-title=\"直播\",$name" >> "$TMP_M3U"
    echo "$url" >> "$TMP_M3U"
  done < "$file"
done

echo "===== tvg-name 修复 ====="
sed -i 's/tvg-name=[^"]*"/tvg-name="/g' "$TMP_M3U"
sed -i 's/tvg-name=\([^,"]*\)/tvg-name="\1"/g' "$TMP_M3U"

echo "===== name.txt 字典规范 ====="
while IFS= read -r line || [ -n "$line" ]; do
  IFS='|' read -ra arr <<< "$line"
  main="${arr[0]}"

  for alias in "${arr[@]:1}"; do
    sed -i "s/tvg-name=\"$alias\"/tvg-name=\"$main\"/g" "$TMP_M3U"
  done
done < "$NAME_DICT"

echo "===== Gather 规则处理 ====="
work_file="$TMP_M3U"

sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"

sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

echo "===== 合并 all.m3u ====="
ALL="$DOWN_DIR/all.m3u"
cp "$work_file" "$ALL"

echo "===== HTTP Probe 检测 + http过滤（安全版） ====="
FINAL="$BASE/live.m3u"
> "$FINAL"

# 暂时关闭 set -e 防止循环中断
set +e

while read -r line || [ -n "$line" ]; do

  # 非URL直接保留
  if [[ "$line" != http* ]]; then
    echo "$line" >> "$FINAL"
    continue
  fi

  # 特殊域名直接保留（不检测）
  if [[ "$line" == *"rtp.cc.cd"* ]] || [[ "$line" == *"melive.onrender.com"* ]]; then
    echo "$line" >> "$FINAL"
    continue
  fi

  # HTTP Probe 检测 (10秒超时)
  http_code=$(curl -L --max-time 10 -o /dev/null -s -w "%{http_code}" -r 0-1024 "$line")
  if [[ "$http_code" == "200" || "$http_code" == "206" ]]; then
    echo "$line" >> "$FINAL"
  else
    echo "⚠ 弃用源（不可访问或超时）: $line"
  fi

done < "$ALL"

# 恢复 set -e
set -e

echo "===== 完成 ====="
echo "输出: live.m3u"
