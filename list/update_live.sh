#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 先组装、后测活清洗（稳健回写版）
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
M3U_RAW_DIR="$BASE_DIR/files"
DOWN_DIR="$BASE_DIR/down"

# --- 初始化 ---
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR" "$M3U_RAW_DIR" "$CONFIG_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
LIVE_M3U="$BASE_DIR/live.m3u"
PRIORITY_MAP="$DOWN_DIR/priority_map.tmp"
THREAD_COUNT=25

# --- 步骤 1: 字典构建 ---
echo "🏗️ 构建标准字典..."
TEMPLATE_NAMES_FILE="$DOWN_DIR/template_names.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TEMPLATE_NAMES_FILE"
DICT_MAP="$DOWN_DIR/dict_map.tmp"; > "$DICT_MAP"

while IFS='|' read -r -a names; do
    target_std=""
    for n in "${names[@]}"; do
        clean_n=$(echo "$n" | xargs)
        [ -n "$clean_n" ] && target_std=$(grep -ix "$clean_n" "$TEMPLATE_NAMES_FILE" | head -n1)
        [ -n "$target_std" ] && break
    done
    if [ -n "$target_std" ]; then
        for n in "${names[@]}"; do
            clean_n=$(echo "$n" | xargs)
            if [ -n "$clean_n" ]; then
                key=$(echo "$clean_n" | tr '[:lower:]' '[:upper:]' | tr -d '[:cntrl:]')
                echo "$key|$target_std" >> "$DICT_MAP"
            fi
        done
    fi
done < "$NAME_TXT"

# --- 步骤 2: 下载逻辑 & 动态生成优先级 ---
echo "📥 下载源文件..."
> "$PRIORITY_MAP"
idx=100
sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    echo "$f_n|$idx" >> "$PRIORITY_MAP"
    
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$DOWN_DIR/$f_n"
    
    if [[ "$f_n" == *"Gather"* && -s "$DOWN_DIR/$f_n" ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$DOWN_DIR/$f_n"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$DOWN_DIR/$f_n"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$DOWN_DIR/$f_n"
    fi
    ((idx++))
done

# --- 步骤 3: 匹配并打上权重标记 ---
echo "🔍 阶段 2: 全量匹配中..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"

for target_file in "$DOWN_DIR"/*; do
    [ ! -f "$target_file" ] && continue
    f_n=$(basename "$target_file")
    [[ "$f_n" == *.tmp || "$f_n" == *.idx || "$f_n" == "dict_map.tmp" || "$f_n" == "priority_map.tmp" ]] && continue
    
    p_val=$(grep "^$f_n|" "$PRIORITY_MAP" | cut -d'|' -f2)
    [ -z "$p_val" ] && p_val=999

    line_num=1000
    while read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            raw_name=$(echo "$line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            read -r v_url || [ -n "$v_url" ]
            [[ ! "$v_url" =~ ^https?:// ]] && continue
            
            match_key=$(echo "$raw_name" | tr '[:lower:]' '[:upper:]' | tr -d '[:cntrl:]')
            std_name=$(grep -i "^$match_key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            
            if [ -n "$std_name" ]; then
                echo "$std_name|$v_url|$f_n|$p_val.$line_num" >> "$ALL_MATCHED"
            fi
            ((line_num++))
        fi
    done < "$target_file"
done

# --- 步骤 4: 按照优先级预组装 ---
echo "📦 阶段 3: 按照权重预组装 M3U..."
PRE_M3U="$DOWN_DIR/pre_live.m3u"
POOL_SORTED="$DOWN_DIR/pool_sorted.tmp"
sort -t'|' -k1,1 -k4,4n "$ALL_MATCHED" > "$POOL_SORTED"

# 创建带行号的临时文件，方便最后按顺序回写
> "$PRE_M3U"
row_idx=1
while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
    [ -z "$t_name" ] && continue

    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$POOL_SORTED" | awk '!seen[$0]++' | while read -r v_u; do
        # 格式: 行号|EXTINF行|URL
        echo "$row_idx|$tpl_line|$v_u" >> "$PRE_M3U"
        ((row_idx++))
    done
done < <(grep "#EXTINF" "$NAME_M3U")

# --- 步骤 5: 最终测活清洗 ---
echo "⚡ 阶段 4: 最终线路清洗..."
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"

check_worker() {
    row_data="$1"
    # 分解数据
    r_idx=$(echo "$row_data" | cut -d'|' -f1)
    inf_part=$(echo "$row_data" | cut -d'|' -f2)
    url_part=$(echo "$row_data" | cut -d'|' -f3)
    
    # 免检
    if [[ "$url_part" == *"rtp.cc.cd"* || "$url_part" == *"melive.onrender.com"* ]]; then
        echo "$r_idx|$inf_part|$url_part" >> "$2"
        return
    fi
    
    # 测活
    code=$(curl -sL -k -I --connect-timeout 3 "$url_part" 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
        echo "$row_data" >> "$2"
    fi
}
export -f check_worker

# 并发测活
cat "$PRE_M3U" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_worker "{}" "$1"' -- "$CLEAN_POOL"

# 最终组装：按第一列行号(r_idx)重新排序，确保优先级顺序
echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1n "$CLEAN_POOL" | while IFS='|' read -r r_idx inf_line url_line; do
    echo "$inf_line" >> "$LIVE_M3U"
    echo "$url_line" >> "$LIVE_M3U"
done

echo "✅ 处理完成，生成的 live.m3u 已更新。"
