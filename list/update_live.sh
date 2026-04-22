#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 严格 down.txt 顺序优先级版
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
MELIVE_DEBUG="$DOWN_DIR/debug_melive.log"
PRIORITY_MAP="$DOWN_DIR/priority_map.tmp" # 用于存储文件名与顺序的对应关系
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
echo "📥 下载源文件并锁定 down.txt 顺序..."
> "$PRIORITY_MAP"
idx=100 # 起始权重
sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    
    # 记录文件名对应的优先级数字 (例如 MyTV.m3u|100, Live.txt|101...)
    echo "$f_n|$idx" >> "$PRIORITY_MAP"
    
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$DOWN_DIR/$f_n"
    
    # 特殊处理 Gather 转发
    if [[ "$f_n" == *"Gather"* && -s "$DOWN_DIR/$f_n" ]]; then
        sed -i 's@https://tv\.iill\.top/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/@g' "$DOWN_DIR/$f_n"
        sed -i 's@https://v\.iill\.top/@https://rtp.cc.cd/play.php?url=https://v.iill.top/@g' "$DOWN_DIR/$f_n"
    fi
    ((idx++))
done

# --- 步骤 3: 匹配并应用动态权重 ---
echo "🔍 阶段 2: 匹配并应用动态权重..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"
echo "=== MeLive 提取记录 ===" > "$MELIVE_DEBUG"

for target_file in "$DOWN_DIR"/*; do
    [ ! -f "$target_file" ] && continue
    f_n=$(basename "$target_file")
    [[ "$f_n" == *.tmp || "$f_n" == *.idx || "$f_n" == "dict_map.tmp" || "$f_n" == "priority_map.tmp" ]] && continue
    
    # 从优先级映射表中读取该文件的权重
    p_val=$(grep "^$f_n|" "$PRIORITY_MAP" | cut -d'|' -f2)
    [ -z "$p_val" ] && p_val=999 # 不在 down.txt 里的文件排到最后

    line_num=1000
    while read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            # 暴力提取 tvg-name
            raw_name=$(echo "$line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            read -r v_url || [ -n "$v_url" ]
            [[ ! "$v_url" =~ ^https?:// ]] && continue
            
            match_key=$(echo "$raw_name" | tr '[:lower:]' '[:upper:]' | tr -d '[:cntrl:]')
            
            if [[ "$f_n" == *"MeLive"* ]]; then
                echo "文件:$f_n | 提取名:[$raw_name] | 匹配Key:[$match_key]" >> "$MELIVE_DEBUG"
            fi

            std_name=$(grep -i "^$match_key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            
            if [ -n "$std_name" ]; then
                # 记录：标准名|URL|来源文件名|权重.行号
                echo "$std_name|$v_url|$f_n|$p_val.$line_num" >> "$ALL_MATCHED"
            fi
            ((line_num++))
        fi
    done < "$target_file"
done

# --- 步骤 4: 测活 ---
HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"
if [ -s "$ALL_MATCHED" ]; then
    echo "⚡ 开始测活..."
    # rtp.cc.cd 免检
    grep "rtp.cc.cd" "$ALL_MATCHED" >> "$HEALTHY_LIST"
    grep -v "rtp.cc.cd" "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c '
        IFS="|' read -r t u s p <<< "{}"
        code=$(curl -sL -k -I --connect-timeout 2 "$u" 2>/dev/null | awk "NR==1{print \$2}")
        [[ "$code" =~ ^(200|206|301|302)$ ]] && echo "$t|$u|$s|$p" >> "'$HEALTHY_LIST'"
    '
fi

# --- 步骤 5: 按照模板组装 ---
echo "📦 阶段 3: 按照 down.txt 权重组装最终结果..."
echo "#EXTM3U" > "$LIVE_M3U"

# 排序：1.频道名(k1) 2.权重数字(k4,n) -> 这样保证了 down.txt 越靠前的源排在越前面
FINAL_POOL="$DOWN_DIR/final_pool.tmp"
sort -t'|' -k1,1 -k4,4n "$HEALTHY_LIST" > "$FINAL_POOL"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    # 提取模板中的标准名
    t_name=$(echo "$tpl_line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
    [ -z "$t_name" ] && continue

    # 从排好序的池子里拉取该频道的所有有效 URL，并物理去重
    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$FINAL_POOL" | awk '!seen[$0]++' | while read -r v_u; do
        echo "$tpl_line" >> "$LIVE_M3U"
        echo "$v_u" >> "$LIVE_M3U"
    done
done < <(grep "#EXTINF" "$NAME_M3U")

echo "✅ 完成！现在直播源顺序完全遵循 down.txt 的排列顺序。"
