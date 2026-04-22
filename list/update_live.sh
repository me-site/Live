#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 1:1 像素级还原模板格式
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
    [ ! -s "$target_file" ] && continue
    
    echo "$f_n|$idx" >> "$PRIORITY_MAP"

    # 【A. 纠正属性格式】 确保下载的源文件里 tvg-name 等属性带有双引号，方便后续匹配
    sed -i -E 's/tvg-name=([^" ,]+)/tvg-name="\1"/g' "$target_file"
    sed -i -E 's/tvg-logo=([^" ,]+)/tvg-logo="\1"/g' "$target_file"
    sed -i -E 's/group-title=([^" ,]+)/group-title="\1"/g' "$target_file"

    # 【B. Gather.m3u 特殊 URL 替换】
    if [[ "$f_n" == *"Gather"* ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$target_file"
    fi

    # 【C. 关键字过滤】 删除电台、精選、游戏、广播等频道
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$target_file"

    # 如果是 TXT 则转为 M3U
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
    
    ((idx++))
done

# --- 3. 提取模板频道列表 ---
TPL_CHANNELS="$DOWN_DIR/tpl_channels.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TPL_CHANNELS"

# --- 4. 扫描所有源并匹配 (归一化匹配) ---
echo "🔍 正在匹配源频道..."
SOURCE_POOL="$DOWN_DIR/source_pool.tmp"; > "$SOURCE_POOL"

for f in "$FILES_DIR"/*; do
    [ ! -f "$f" ] && continue
    f_name=$(basename "$f")
    p_val=$(grep "^$f_name|" "$PRIORITY_MAP" | cut -d'|' -f2)
    
    cat "$f" | while read -r line; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            c_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
            [ -z "$c_name" ] && c_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            read -r c_url
            [[ ! "$c_url" =~ ^https:// ]] && continue
            
            std_name=$(grep -ix "$c_name" "$TPL_CHANNELS" | head -n1)
            [ -n "$std_name" ] && echo "$std_name|$c_url|$p_val" >> "$SOURCE_POOL"
        fi
    done
done

sort -t'|' -k1,1 -k3,3n "$SOURCE_POOL" -o "$DOWN_DIR/source_pool.sorted"

# --- 5. 核心：从模板提取原始行 ---
echo "📦 正在按照模板还原格式..."
RAW_INDEX="$DOWN_DIR/raw_index.tmp"; > "$RAW_INDEX"
tpl_count=100000

while read -r tpl_line || [ -n "$tpl_line" ]; do
    if [[ "$tpl_line" =~ "#EXTINF" ]]; then
        t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
        [ -z "$t_name" ] && continue

        awk -F'|' -v t="$t_name" '$1==t {print $2}' "$DOWN_DIR/source_pool.sorted" | awk '!seen[$0]++' | while read -r match_url; do
            # 存入：索引 ||| 原始模板行 ||| 匹配到的URL
            echo "${tpl_count}|||${tpl_line}|||${match_url}" >> "$RAW_INDEX"
        done
        ((tpl_count++))
    fi
done < "$NAME_M3U"

# --- 6. 测活并输出最终 live.m3u ---
echo "⚡ 正在测活输出..."
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

echo "✅ 完成！格式已严格保留，关键字已过滤。"
