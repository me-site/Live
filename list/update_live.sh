#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 字典映射 & 严格格式版
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
DOWN_DIR="$BASE_DIR/down"
FILES_DIR="$BASE_DIR/files"

# --- 1. 初始化 ---
echo "🧹 清理旧数据..."
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR" "$FILES_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
ALL_M3U="$DOWN_DIR/all.m3u"
LIVE_M3U="$BASE_DIR/live.m3u"
THREAD_COUNT=25

[ ! -f "$NAME_M3U" ] && { echo "❌ 错误：找不到模板文件 $NAME_M3U"; exit 1; }

# --- 2. 下载并清洗源文件 ---
echo "📥 正在获取并处理远程源..."
PRIORITY_MAP="$DOWN_DIR/priority.map"
> "$PRIORITY_MAP"
idx=100

sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    target_file="$FILES_DIR/$f_n"
    
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$target_file"
    if [ ! -s "$target_file" ]; then continue; fi
    
    echo "$f_n|$idx" >> "$PRIORITY_MAP"

    # 预处理：统一转为 M3U
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

    # 属性纠正 & 代理替换 & 关键字过滤
    sed -i -E 's/tvg-name=([^" ,]+)/tvg-name="\1"/g' "$target_file"
    if [[ "$f_n" == *"Gather"* ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$target_file"
    fi
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$target_file"
    ((idx++))
done

# --- 3. 建立匹配字典 (核心逻辑) ---
echo "🏗️ 正在构建名字转换字典..."
TPL_CHANNELS="$DOWN_DIR/tpl_channels.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TPL_CHANNELS"

DICT_MAP="$DOWN_DIR/dict.map"; > "$DICT_MAP"
if [ -f "$NAME_TXT" ]; then
    while IFS='|' read -r -a names; do
        target_std=""
        # 在这一组别名中，寻找哪个是模板里存在的标准名
        for n in "${names[@]}"; do
            clean_n=$(echo "$n" | xargs)
            [ -z "$clean_n" ] && continue
            target_std=$(grep -ix "$clean_n" "$TPL_CHANNELS" | head -n1)
            [ -n "$target_std" ] && break
        done
        # 如果找到了标准名，把这组里的所有名字都指向它
        if [ -n "$target_std" ]; then
            for n in "${names[@]}"; do
                echo "$(echo "$n" | tr '[:lower:]' '[:upper:]')|$target_std" >> "$DICT_MAP"
            done
        fi
    done < "$NAME_TXT"
fi

# --- 4. 扫描并匹配 (应用字典) ---
echo "🔍 正在应用字典并匹配频道..."
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
            [[ ! "$c_url" =~ ^https?:// ]] && continue
            
            # 转换逻辑：
            # A. 先查字典映射
            key=$(echo "$c_name" | tr '[:lower:]' '[:upper:]')
            std_name=$(grep "^$key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            
            # B. 字典没中，直接查模板匹配
            if [ -z "$std_name" ]; then
                std_name=$(grep -ix "$c_name" "$TPL_CHANNELS" | head -n1)
            fi

            [ -n "$std_name" ] && echo "$std_name|$c_url|$p_val" >> "$SOURCE_POOL"
        fi
    done < "$f"
done

[ ! -s "$SOURCE_POOL" ] && { echo "❌ 匹配池为空，请检查 name.txt 映射是否正确！"; exit 1; }
sort -t'|' -k1,1 -k3,3n "$SOURCE_POOL" -o "$DOWN_DIR/source_pool.sorted"

# --- 5. 还原模板原始行 ---
echo "📦 正在还原模板格式..."
RAW_INDEX="$DOWN_DIR/raw_index.tmp"; > "$RAW_INDEX"
tpl_count=100000

while read -r tpl_line || [ -n "$tpl_line" ]; do
    if [[ "$tpl_line" =~ "#EXTINF" ]]; then
        t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
        [ -z "$t_name" ] && continue

        grep "^$t_name|" "$DOWN_DIR/source_pool.sorted" | cut -d'|' -f2 | awk '!seen[$0]++' | while read -r match_url; do
            echo "${tpl_count}|||${tpl_line}|||${match_url}" >> "$RAW_INDEX"
        done
        ((tpl_count++))
    fi
done < "$NAME_M3U"

# --- 6. 测活输出 ---
echo "⚡ 测活并生成最终文件..."
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"
export CLEAN_POOL

check_url() {
    item="$1"
    idx=$(echo "$item" | awk -F'|||' '{print $1}')
    inf=$(echo "$item" | awk -F'|||' '{print $2}')
    url=$(echo "$item" | awk -F'|||' '{print $3}')

    if [[ "$url" == *"rtp.cc.cd"* || "$url" == *"melive.onrender.com"* || "$url" == *"php.jdshipin.com"* ]]; then
        echo "${idx}|||${inf}|||${url}" >> "$CLEAN_POOL"
    else
        code=$(curl -sL -k -I --connect-timeout 3 "$url" 2>/dev/null | awk 'NR==1{print $2}')
        if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
            echo "${idx}|||${inf}|||${url}" >> "$CLEAN_POOL"
        fi
    fi
}
export -f check_url

cat "$RAW_INDEX" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url "{}"'

echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1n "$CLEAN_POOL" | while read -r final_row; do
    out_inf=$(echo "$final_row" | awk -F'|||' '{print $2}')
    out_url=$(echo "$final_row" | awk -F'|||' '{print $3}')
    echo "$out_inf" >> "$LIVE_M3U"
    echo "$out_url" >> "$LIVE_M3U"
done

echo "✅ 任务完成！"
echo "📊 最终 live.m3u 频道数: $(grep -c "#EXTINF" "$LIVE_M3U")"
