#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 严格 down.txt 顺序优先级 (修复引号版)
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
echo "📥 下载源文件并锁定 down.txt 顺序..."
> "$PRIORITY_MAP"
idx=100
sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    echo "$f_n|$idx" >> "$PRIORITY_MAP"
    
    # 下载文件
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$DOWN_DIR/$f_n"
    
    # 【精准替换】：针对 Gather.m3u 中的三个特定目录前缀加代理
    if [[ "$f_n" == *"Gather"* && -s "$DOWN_DIR/$f_n" ]]; then
        # 处理 tw/
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$DOWN_DIR/$f_n"
        # 处理 4gtv/
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$DOWN_DIR/$f_n"
        # 处理 ofiii/ (注意这个是在 tv 域名下)
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$DOWN_DIR/$f_n"
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
            
            if [[ "$f_n" == *"MeLive"* ]]; then
                echo "文件:$f_n | 提取名:[$raw_name] | 匹配Key:[$match_key]" >> "$MELIVE_DEBUG"
            fi

            std_name=$(grep -i "^$match_key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            if [ -n "$std_name" ]; then
                echo "$std_name|$v_url|$f_n|$p_val.$line_num" >> "$ALL_MATCHED"
            fi
            ((line_num++))
        fi
    done < "$target_file"
done

# --- 步骤 4: 测活 (增加 melive 免检) ---
HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"
if [ -s "$ALL_MATCHED" ]; then
    echo "⚡ 开始测活..."
    
    # 【免检逻辑】：使用 grep -E 支持扩展正则，匹配 rtp.cc.cd 或 melive.onrender.com
    grep -E "rtp\.cc\.cd|melive\.onrender\.com" "$ALL_MATCHED" >> "$HEALTHY_LIST"
    
    # 【需检测逻辑】：排除掉上述两个免检域名的源进行实际测活
    grep -v -E "rtp\.cc\.cd|melive\.onrender\.com" "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c "
        item='{}'
        IFS='|' read -r t u s p <<< \"\$item\"
        code=\$(curl -sL -k -I --connect-timeout 2 \"\$u\" 2>/dev/null | awk 'NR==1{print \$2}')
        if [[ \"\$code\" =~ ^(200|206|301|302)\$ ]]; then
            echo \"\$t|\$u|\$s|\$p\" >> \"$HEALTHY_LIST\"
        fi
    "
fi

# --- 步骤 5: 按照模板组装 ---
echo "📦 阶段 3: 按照 down.txt 权重组装最终结果..."
echo "#EXTM3U" > "$LIVE_M3U"
FINAL_POOL="$DOWN_DIR/final_pool.tmp"
sort -t'|' -k1,1 -k4,4n "$HEALTHY_LIST" > "$FINAL_POOL"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | awk -F'tvg-name="' '{print $2}' | awk -F'"' '{print $1}')
    [ -z "$t_name" ] && continue

    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$FINAL_POOL" | awk '!seen[$0]++' | while read -r v_u; do
        echo "$tpl_line" >> "$LIVE_M3U"
        echo "$v_u" >> "$LIVE_M3U"
    done
done < <(grep "#EXTINF" "$NAME_M3U")

echo "✅ 完成！"
