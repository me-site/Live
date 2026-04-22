#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 全量拼合 + 格式纠正 + 测活版
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")"; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
DOWN_DIR="$BASE_DIR/down"
FILES_DIR="$BASE_DIR/files"  # 下载原文件存放地

# --- 步骤 1: 初始化 ---
echo "🧹 正在清理并初始化目录..."
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR" "$FILES_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
ALL_M3U="$DOWN_DIR/all.m3u"
LIVE_M3U="$BASE_DIR/live.m3u"
THREAD_COUNT=25

# --- 步骤 2: 下载与格式纠正 ---
echo "📥 正在下载源文件并处理格式..."
> "$DOWN_DIR/priority.map"
idx=100

sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    target_file="$FILES_DIR/$f_n"
    
    # 下载
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$target_file"
    [ ! -s "$target_file" ] && continue
    echo "$f_n|$idx" >> "$DOWN_DIR/priority.map"

    # A. 如果是 TXT 格式，转为 M3U
    if [[ "$f_n" == *.txt ]]; then
        temp_m3u="$DOWN_DIR/${f_n%.txt}.m3u"
        echo "#EXTM3U" > "$temp_m3u"
        while IFS=',' read -r name vurl || [ -n "$name" ]; do
            [ -z "$vurl" ] && continue
            echo "#EXTINF:-1 tvg-name=\"$name\",$name" >> "$temp_m3u"
            echo "$vurl" >> "$temp_m3u"
        done < "$target_file"
        mv "$temp_m3u" "$target_file"
    fi

    # B. 纠正 tvg-name 格式 (补全双引号)
    # 匹配 tvg-name=名称 后跟 tvg- 或 , 的情况
    sed -i -E 's/tvg-name="?([^", ]+)"?/tvg-name="\1"/g' "$target_file"

    # C. Gather 特殊代理规则
    if [[ "$f_n" == *"Gather"* ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$target_file"
    fi
    ((idx++))
done

# --- 步骤 3: 字典映射与拼合 all.m3u ---
echo "🏗️ 正在构建字典并拼合 all.m3u..."

# 提取 extinf.m3u 所有的标准名
TEMPLATE_NAMES="$DOWN_DIR/tpl_names.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TEMPLATE_NAMES"

# 构建映射表 (Key: 原名 | Value: 标准名)
DICT_MAP="$DOWN_DIR/dict.map"
> "$DICT_MAP"
while IFS='|' read -r -a names; do
    target_std=""
    for n in "${names[@]}"; do
        clean_n=$(echo "$n" | xargs)
        [ -z "$clean_n" ] && continue
        target_std=$(grep -ix "$clean_n" "$TEMPLATE_NAMES" | head -n1)
        [ -n "$target_std" ] && break
    done
    if [ -n "$target_std" ]; then
        for n in "${names[@]}"; do
            echo "$(echo "$n" | tr '[:lower:]' '[:upper:]')|$target_std" >> "$DICT_MAP"
        done
    fi
done < "$NAME_TXT"

# 提取各文件线路并标记权重
MATCH_POOL="$DOWN_DIR/match_pool.tmp"; > "$MATCH_POOL"
for f in "$FILES_DIR"/*; do
    [ ! -f "$f" ] && continue
    f_name=$(basename "$f")
    p_val=$(grep "^$f_name|" "$DOWN_DIR/priority.map" | cut -d'|' -f2)
    [ -z "$p_val" ] && p_val=999
    
    # 解析文件
    while read -r line; do
        if [[ "$line" =~ "tvg-name=\"" ]]; then
            raw_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
            read -r v_url
            # 过滤：必须是 https 开头
            [[ ! "$v_url" =~ ^https:// ]] && continue
            
            key=$(echo "$raw_name" | tr '[:lower:]' '[:upper:]')
            std_name=$(grep "^$key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            if [ -n "$std_name" ]; then
                echo "$std_name|$line|$v_url|$p_val" >> "$MATCH_POOL"
            fi
        fi
    done < "$f"
done

# --- 步骤 4: 严格按照模板顺序组装 all.m3u ---
echo "#EXTM3U" > "$ALL_M3U"
PRE_SORTED_POOL="$DOWN_DIR/pool.sorted"
sort -t'|' -k1,1 -k4,4n "$MATCH_POOL" > "$PRE_SORTED_POOL"

tpl_idx=10000
while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
    [ -z "$t_name" ] && continue

    # 按照权重顺序写入 all.m3u
    awk -F'|' -v t="$t_name" '$1==t {print $2 "|" $3}' "$PRE_SORTED_POOL" | awk '!seen[$0]++' | while read -r pair; do
        # 存入临时结构：行号|EXTINF|URL
        echo "$tpl_idx|$pair" >> "$DOWN_DIR/all_raw.tmp"
    done
    ((tpl_idx++))
done < <(grep "#EXTINF" "$NAME_M3U")

# 生成最终的 all.m3u (存入 down 目录)
echo "#EXTM3U" > "$ALL_M3U"
cat "$DOWN_DIR/all_raw.tmp" | cut -d'|' -f2,3 | tr '|' '\n' >> "$ALL_M3U"

# --- 步骤 5: 测活并生成 live.m3u ---
echo "⚡ 正在测活 (跳过免检源)..."
export CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"

check_line() {
    row="$1"
    idx=$(echo "$row" | cut -d'|' -f1)
    inf=$(echo "$row" | cut -d'|' -f2)
    url=$(echo "$row" | cut -d'|' -f3)

    if [[ "$url" == *"rtp.cc.cd"* || "$url" == *"melive.onrender.com"* ]]; then
        echo "$idx|$inf|$url" >> "$CLEAN_POOL"
        return
    fi

    code=$(curl -sL -k -I --connect-timeout 3 "$url" 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
        echo "$idx|$inf|$url" >> "$CLEAN_POOL"
    fi
}
export -f check_line

# 并发测活
cat "$DOWN_DIR/all_raw.tmp" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_line "{}"'

# 按照 all.m3u 原始物理顺序回写到根目录 live.m3u
echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1n "$CLEAN_POOL" | while IFS='|' read -r r_idx r_inf r_url; do
    echo "$r_inf" >> "$LIVE_M3U"
    echo "$r_url" >> "$LIVE_M3U"
done

echo "✅ 处理完成！"
echo "1. 全量源已保存至: down/all.m3u (仅限https)"
echo "2. 最终存活源已保存至: live.m3u"
