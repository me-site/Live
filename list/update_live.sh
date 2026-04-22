#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 先组装、后测活清洗版
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

# --- 步骤 3: 匹配并打上权重标记 (此时不测活) ---
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

# --- 步骤 4: 按照优先级预组装 (包含所有源) ---
echo "📦 阶段 3: 按照权重预组装 M3U..."
PRE_M3U="$DOWN_DIR/pre_live.m3u"
echo "#EXTM3U" > "$PRE_M3U"
POOL_SORTED="$DOWN_DIR/pool_sorted.tmp"
sort -t'|' -k1,1 -k4,4n "$ALL_MATCHED" > "$POOL_SORTED"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
    [ -z "$t_name" ] && continue

    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$POOL_SORTED" | awk '!seen[$0]++' | while read -r v_u; do
        # 此时我们将 模板行 和 URL 先拼在一起，中间用特殊符号隔开，方便测活
        echo "$tpl_line|$v_u" >> "$PRE_M3U"
    done
done < <(grep "#EXTINF" "$NAME_M3U")

# --- 步骤 5: 最终测活清洗 ---
echo "⚡ 阶段 4: 最终线路清洗 (并发检测)..."
echo "#EXTM3U" > "$LIVE_M3U"

# 导出变量供多线程使用
export LIVE_M3U
check_and_write() {
    line="$1"
    inf_part=$(echo "$line" | cut -d'|' -f1)
    url_part=$(echo "$line" | cut -d'|' -f2)
    
    # 免检名单
    if [[ "$url_part" == *"rtp.cc.cd"* || "$url_part" == *"melive.onrender.com"* ]]; then
        echo -e "$inf_part\n$url_part" >> "$2"
        return
    fi
    
    # 实际检测
    code=$(curl -sL -k -I --connect-timeout 3 "$url_part" 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
        echo -e "$inf_part\n$url_part" >> "$2"
    fi
}
export -f check_and_write

# 清洗池
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"
grep -v "#EXTM3U" "$PRE_M3U" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_and_write "{}" "$1"' -- "$CLEAN_POOL"

# 按照预组装的物理顺序重新写回文件（保持优先级）
# 因为 xargs 并发写入是无序的，我们需要用原文件的顺序来过滤
while read -r original_line; do
    [[ "$original_line" == "#EXTM3U" ]] && continue
    grep -Fqx "$original_line" "$CLEAN_POOL" && (echo "$original_line" | tr '|' '\n' >> "$LIVE_M3U")
done < "$PRE_M3U"

echo "✅ 完成！先组装后清洗逻辑已生效。"
