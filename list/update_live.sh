#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 深度诊断与暴力匹配版
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
THREAD_COUNT=25

# --- 步骤 1: 字典构建 (保持原样匹配) ---
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

# --- 步骤 2: 下载逻辑 ---
echo "📥 下载源文件..."
sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$DOWN_DIR/$f_n"
    # 如果是 Gather 依然做转发处理
    if [[ "$f_n" == *"Gather"* && -s "$DOWN_DIR/$f_n" ]]; then
        sed -i 's@https://[tv|v]\.iill\.top/@https://rtp.cc.cd/play.php?url=&@g' "$DOWN_DIR/$f_n"
    fi
done

# --- 步骤 3: 暴力匹配 (增加诊断日志) ---
echo "🔍 阶段 2: 匹配并分配权重..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"
echo "=== MeLive 提取记录 ===" > "$MELIVE_DEBUG"

for target_file in "$DOWN_DIR"/*; do
    [ ! -f "$target_file" ] && continue
    f_n=$(basename "$target_file")
    [[ "$f_n" == *.tmp || "$f_n" == *.idx || "$f_n" == "dict_map.tmp" ]] && continue
    
    # 分配优先级数字
    p_val=120
    [[ "$f_n" == *"MyTV"* ]] && p_val=100
    [[ "$f_n" == *"Live.txt"* ]] && p_val=101
    [[ "$f_n" == *"Smart"* ]] && p_val=102
    [[ "$f_n" == *"Gather"* ]] && p_val=110

    line_num=1000
    while read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            # 【暴力提取】：提取 tvg-name=" 之后到下一个引号之前的所有内容
            raw_name=$(echo "$line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
            
            # 保底取逗号后
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            read -r v_url || [ -n "$v_url" ]
            [[ ! "$v_url" =~ ^https?:// ]] && continue
            
            # 生成匹配 Key (转大写，删控制字符，保留内部空格)
            match_key=$(echo "$raw_name" | tr '[:lower:]' '[:upper:]' | tr -d '[:cntrl:]')
            
            # 诊断日志：专门记录 MeLive 的情况
            if [[ "$f_n" == *"MeLive"* ]]; then
                echo "文件:$f_n | 提取名:[$raw_name] | 匹配Key:[$match_key]" >> "$MELIVE_DEBUG"
            fi

            # 字典查询
            std_name=$(grep -i "^$match_key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            
            if [ -n "$std_name" ]; then
                echo "$std_name|$v_url|$f_n|$p_val.$line_num" >> "$ALL_MATCHED"
            fi
            ((line_num++))
        fi
    done < "$target_file"
done

# --- 测活与组装 (略显精简) ---
HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"
if [ -s "$ALL_MATCHED" ]; then
    # 这里简单处理：rtp.cc.cd 免检，其余通过直接写入
    grep "rtp.cc.cd" "$ALL_MATCHED" >> "$HEALTHY_LIST"
    grep -v "rtp.cc.cd" "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c '
        IFS="|' read -r t u s p <<< "{}"
        code=$(curl -sL -k -I --connect-timeout 2 "$u" 2>/dev/null | awk "NR==1{print \$2}")
        [[ "$code" =~ ^(200|206|301|302)$ ]] && echo "$t|$u|$s|$p" >> "'$HEALTHY_LIST'"
    '
fi

echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1 -k4,4n "$HEALTHY_LIST" > "$DOWN_DIR/final_pool.tmp"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
    
    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$DOWN_DIR/final_pool.tmp" | awk '!seen[$0]++' | while read -r v_u; do
        echo "$tpl_line" >> "$LIVE_M3U"
        echo "$v_u" >> "$LIVE_M3U"
    done
done < <(grep "#EXTINF" "$NAME_M3U")

echo "✅ 处理完成。如果 MeLive 还是没有，请查看 $MELIVE_DEBUG 文件内容。"
