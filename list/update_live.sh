#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 严格双引号 & 关键字过滤版
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
DOWN_DIR="$BASE_DIR/down"
FILES_DIR="$BASE_DIR/files"

# --- 1. 初始化 ---
echo "🧹 初始化目录..."
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR" "$FILES_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
ALL_M3U="$DOWN_DIR/all.m3u"
LIVE_M3U="$BASE_DIR/live.m3u"
THREAD_COUNT=25

# --- 2. 下载并预处理 ---
echo "📥 正在下载并清洗源文件..."
PRIORITY_MAP="$DOWN_DIR/priority.map"
> "$PRIORITY_MAP"
idx=100

sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    target_file="$FILES_DIR/$f_n"
    
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$target_file"
    [ ! -s "$target_file" ] && continue
    
    echo "$f_n|$idx" >> "$PRIORITY_MAP"

    # A. 如果是 TXT 则转为 M3U (严格带引号)
    if [[ "$f_n" == *.txt ]]; then
        temp_m3u="$DOWN_DIR/${f_n%.txt}.m3u"
        echo "#EXTM3U" > "$temp_m3u"
        while IFS=',' read -r cname curl_val || [ -n "$cname" ]; do
            [ -z "$curl_val" ] && continue
            echo "#EXTINF:-1 tvg-name=\"$cname\",$cname" >> "$temp_m3u"
            echo "$curl_val" >> "$temp_m3u"
        done < "$target_file"
        mv "$temp_m3u" "$target_file"
    fi

    # B. 纠正引号格式
    sed -i -E 's/tvg-name=([^" ,]+)/tvg-name="\1"/g' "$target_file"

    # C. Gather.m3u 特殊 URL 替换
    if [[ "$f_n" == *"Gather"* ]]; then
        echo "🔧 正在应用 Gather 代理替换规则..."
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$target_file"
    fi

    # D. 关键字硬过滤
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$target_file"

    ((idx++))
done

# --- 3. 建立匹配字典 ---
echo "🏗️ 构建字典映射..."
TPL_CHANNELS="$DOWN_DIR/tpl_channels.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TPL_CHANNELS"

DICT_MAP="$DOWN_DIR/dict.map"; > "$DICT_MAP"
while IFS='|' read -r -a names; do
    target_std=""
    for n in "${names[@]}"; do
        clean_n=$(echo "$n" | xargs)
        [ -z "$clean_n" ] && continue
        target_std=$(grep -ix "$clean_n" "$TPL_CHANNELS" | head -n1)
        [ -n "$target_std" ] && break
    done
    if [ -n "$target_std" ]; then
        for n in "${names[@]}"; do
            echo "$(echo "$n" | tr '[:lower:]' '[:upper:]')|$target_std" >> "$DICT_MAP"
        done
    fi
done < "$NAME_TXT"

# --- 4. 扫描所有源 ---
echo "🔍 扫描并匹配..."
SOURCE_POOL="$DOWN_DIR/source_pool.tmp"; > "$SOURCE_POOL"

for f in "$FILES_DIR"/*; do
    [ ! -f "$f" ] && continue
    f_name=$(basename "$f")
    p_val=$(grep "^$f_name|" "$PRIORITY_MAP" | cut -d'|' -f2)
    
    while read -r line; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            c_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
            [ -z "$c_name" ] && c_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            read -r c_url
            [[ ! "$c_url" =~ ^https:// ]] && continue
            
            key=$(echo "$c_name" | tr '[:lower:]' '[:upper:]')
            std_name=$(grep "^$key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            [ -z "$std_name" ] && std_name=$(grep -ix "$c_name" "$TPL_CHANNELS" | head -n1)
            [ -n "$std_name" ] && echo "$std_name|$c_url|$p_val" >> "$SOURCE_POOL"
        fi
    done < "$f"
done

sort -t'|' -k1,1 -k3,3n "$SOURCE_POOL" -o "$DOWN_DIR/source_pool.sorted"

# --- 5. 以模板为核心生成 all.m3u (严格保留原始行) ---
echo "📦 填充模板生成临时库..."
RAW_INDEX="$DOWN_DIR/raw_index.tmp"; > "$RAW_INDEX"
tpl_line_idx=100000

while read -r line || [ -n "$line" ]; do
    [[ ! "$line" =~ "#EXTINF" ]] && continue
    # 提取用于匹配的名字，但不修改原始 $line
    t_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
    [ -z "$t_name" ] && continue

    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$DOWN_DIR/source_pool.sorted" | awk '!seen[$0]++' | while read -r match_url; do
        # 使用三个竖线作为特殊分隔符，防止属性冲突
        echo "${tpl_line_idx}|||${line}|||${match_url}" >> "$RAW_INDEX"
    done
    ((tpl_line_idx++))
done < "$NAME_M3U"

# --- 6. 测活生成最终 live.m3u ---
echo "⚡ 并发测活..."
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"
export CLEAN_POOL

check_url() {
    item="$1"
    # 使用 awk 分解，避免 IFS 剥离引号
    idx=$(echo "$item" | awk -F'|||' '{print $1}')
    inf=$(echo "$item" | awk -F'|||' '{print $2}')
    url=$(echo "$item" | awk -F'|||' '{print $3}')

    if [[ "$url" == *"rtp.cc.cd"* || "$url" == *"melive.onrender.com"* ]]; then
        echo "${idx}|||${inf}|||${url}" >> "$CLEAN_POOL"
    else
        # 增加超时判断
        code=$(curl -sL -k -I --connect-timeout 3 "$url" 2>/dev/null | awk 'NR==1{print $2}')
        if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
            echo "${idx}|||${inf}|||${url}" >> "$CLEAN_POOL"
        fi
    fi
}
export -f check_url

cat "$RAW_INDEX" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url "{}"'

echo "#EXTM3U" > "$LIVE_M3U"
# 最终排序输出，确保不丢失任何引号
sort -t'|' -k1,1n "$CLEAN_POOL" | while read -r line; do
    o_inf=$(echo "$line" | awk -F'|||' '{print $2}')
    o_url=$(echo "$line" | awk -F'|||' '{print $3}')
    if [ -n "$o_inf" ] && [ -n "$o_url" ]; then
        echo "$o_inf" >> "$LIVE_M3U"
        echo "$o_url" >> "$LIVE_M3U"
    fi
done

echo "✅ 完成！live.m3u 已生成，双引号已严格保留。"
