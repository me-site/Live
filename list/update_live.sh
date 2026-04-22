#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 模板 Logo 填充版
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
DOWN_DIR="$BASE_DIR/down"
FILES_DIR="$BASE_DIR/files"

# --- 1. 初始化 ---
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR" "$FILES_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
ALL_M3U="$DOWN_DIR/all.m3u"
LIVE_M3U="$BASE_DIR/live.m3u"
THREAD_COUNT=25

# --- 2. 下载并格式化源 (纠正 tvg-name 引号) ---
echo "📥 正在下载并预处理源文件..."
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

    # 规范化源文件：补全 tvg-name 引号，移除多余空格
    sed -i -E 's/tvg-name="?([^", ]+)"?/tvg-name="\1"/g' "$target_file"

    if [[ "$f_n" == *"Gather"* ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$target_file"
    fi
    ((idx++))
done

# --- 3. 建立匹配字典 ---
echo "🏗️ 正在构建字典映射..."
# 提取模板中定义的频道名（即你 Logo 对应的 key）
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

# --- 4. 扫描所有下载的源，分拣入库 ---
echo "🔍 扫描下载源并匹配模板频道..."
SOURCE_POOL="$DOWN_DIR/source_pool.tmp"; > "$SOURCE_POOL"

for f in "$FILES_DIR"/*; do
    [ ! -f "$f" ] && continue
    f_name=$(basename "$f")
    p_val=$(grep "^$f_name|" "$PRIORITY_MAP" | cut -d'|' -f2)
    [ -z "$p_val" ] && p_val=999
    
    # 支持 TXT 和 M3U 混合扫描
    if [[ "$f_name" == *.txt ]]; then
        while IFS=',' read -r c_name c_url || [ -n "$c_name" ]; do
            [[ ! "$c_url" =~ ^https:// ]] && continue
            key=$(echo "$c_name" | tr '[:lower:]' '[:upper:]')
            std_name=$(grep "^$key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            [ -z "$std_name" ] && std_name=$(grep -ix "$c_name" "$TPL_CHANNELS" | head -n1)
            [ -n "$std_name" ] && echo "$std_name|$c_url|$p_val" >> "$SOURCE_POOL"
        done < "$f"
    else
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
    fi
done

# 按文件名优先级排序
sort -t'|' -k1,1 -k3,3n "$SOURCE_POOL" -o "$DOWN_DIR/source_pool.sorted"

# --- 5. 以模板为核心进行填充 (all.m3u) ---
echo "📦 正在将源填入 Logo 模板..."
echo "#EXTM3U" > "$ALL_M3U"
RAW_INDEX="$DOWN_DIR/raw_index.tmp"; > "$RAW_INDEX"
tpl_line_idx=100000

while read -r line || [ -n "$line" ]; do
    [[ ! "$line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
    [ -z "$t_name" ] && continue

    # 在已排序的池子中查找属于该模板频道的所有 URL
    # 去重并保持顺序
    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$DOWN_DIR/source_pool.sorted" | awk '!seen[$0]++' | while read -r match_url; do
        # 写入索引：模板行号 | 模板原始整行(带Logo) | 匹配到的URL
        echo "$tpl_line_idx|$line|$match_url" >> "$RAW_INDEX"
    done
    ((tpl_line_idx++))
done < "$NAME_M3U"

# 生成 all.m3u 用于存档
cut -d'|' -f2,3 "$RAW_INDEX" | tr '|' '\n' >> "$ALL_M3U"

# --- 6. 测活生成最终 live.m3u ---
echo "⚡ 并发测活..."
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"
export CLEAN_POOL

check_task() {
    item="$1"
    idx=$(echo "$item" | cut -d'|' -f1)
    inf=$(echo "$item" | cut -d'|' -f2)
    url=$(echo "$item" | cut -d'|' -f3)

    if [[ "$url" == *"rtp.cc.cd"* || "$url" == *"melive.onrender.com"* ]]; then
        echo "$idx|$inf|$url" >> "$CLEAN_POOL"
    else
        code=$(curl -sL -k -I --connect-timeout 3 "$url" 2>/dev/null | awk 'NR==1{print $2}')
        if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
            echo "$idx|$inf|$url" >> "$CLEAN_POOL"
        fi
    fi
}
export -f check_task

cat "$RAW_INDEX" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_task "{}"'

# 最终回写：严格遵循模板物理顺序
echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1n "$CLEAN_POOL" | while IFS='|' read -r o_idx o_inf o_url; do
    echo "$o_inf" >> "$LIVE_M3U"
    echo "$o_url" >> "$LIVE_M3U"
done

echo "✅ 任务完成！所有源已按模板 Logo 样式填充并排序。"
