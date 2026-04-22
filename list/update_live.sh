#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 字典原样匹配 (保留空格) + 优先级锁定版
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
THREAD_COUNT=25

# --- 测活函数 ---
check_url_worker() {
    IFS='|' read -r t u s p <<< "$1"
    if [[ "$s" == *"Smart"* || "$u" == https://rtp.cc.cd/* ]]; then
        echo "$t|$u|$s|$p" >> "$2"
        return
    fi
    local code=$(curl -sL -k -I --connect-timeout 3 --max-time 5 -A "VLC/3.0.18" "$u" 2>/dev/null | awk 'NR==1{print $2}')
    [[ "$code" =~ ^(200|206|301|302)$ ]] && echo "$t|$u|$s|$p" >> "$2"
}
export -f check_url_worker

# --- 步骤 1: 字典构建 ---
echo "🏗️ 构建标准字典..."
TEMPLATE_NAMES_FILE="$DOWN_DIR/template_names.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TEMPLATE_NAMES_FILE"
DICT_MAP="$DOWN_DIR/dict_map.tmp"; > "$DICT_MAP"

while IFS='|' read -r -a names; do
    target_std=""
    for n in "${names[@]}"; do
        clean_n=$(echo "$n" | xargs)
        [ -z "$clean_n" ] && continue
        target_std=$(grep -ix "$clean_n" "$TEMPLATE_NAMES_FILE" | head -n1)
        [ -n "$target_std" ] && break
    done
    
    if [ -n "$target_std" ]; then
        for n in "${names[@]}"; do
            clean_n=$(echo "$n" | xargs) # 仅去掉首尾极端空格，保留词间空格
            if [ -n "$clean_n" ]; then
                # 转换大写作为匹配 Key，但不删除内部空格
                key=$(echo "$clean_n" | tr '[:lower:]' '[:upper:]')
                echo "$key|$target_std" >> "$DICT_MAP"
            fi
        done
    fi
done < "$NAME_TXT"

# --- 步骤 2: 下载逻辑 ---
echo "📥 阶段 1: 下载源文件..."
sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    raw_path="$M3U_RAW_DIR/$f_n"; target_path="$DOWN_DIR/$f_n"
    
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$raw_path"
    
    if [ -s "$raw_path" ]; then
        sed 's/^\xEF\xBB\xBF//; s/\r//g' "$raw_path" > "$target_path"
        if [[ "$f_n" == *.txt ]]; then
            awk -F'[, ]+' '{if($1!="" && $2 ~ /^http/){print "#EXTINF:-1 tvg-name=\""$1"\","$1"\n"$2}}' "$target_path" > "${target_path}.tmp" && mv "${target_path}.tmp" "$target_path"
        fi
        if [[ "$f_n" == *"Gather"* ]]; then
            sed -i 's@https://tv\.iill\.top/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/@g' "$target_path"
            sed -i 's@https://v\.iill\.top/@https://rtp.cc.cd/play.php?url=https://v.iill.top/@g' "$target_path"
        fi
    fi
done

# --- 步骤 3: 匹配与权重分配 (保留空格逻辑) ---
echo "🔍 阶段 2: 匹配并分配权重..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"

for target_file in "$DOWN_DIR"/*; do
    [ ! -f "$target_file" ] && continue
    f_n=$(basename "$target_file")
    [[ "$f_n" == *.tmp || "$f_n" == *.idx || "$f_n" == *"clean"* ]] && continue
    
    case "$f_n" in
        *"MyTV"*)   p_val=100 ;;
        *"Live.txt"*) p_val=101 ;;
        *"MeLive"*)   p_val=102 ;;
        *"Gather"*)   p_val=110 ;;
        *)            p_val=120 ;;
    esac

    line_num=1000
    while read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            # 【独立提取】：直接提取 tvg-name 引号内的原始值，保留内部空格
            raw_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
            
            # 保底逻辑：如果没提取到引号内容，再取逗号后的值
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            read -r v_url || [ -n "$v_url" ]
            [ -z "$v_url" ] && [[ ! "$v_url" =~ ^https?:// ]] && continue
            
            # 【转换 Key】：仅转大写，不删空格，只清理掉提取过程中可能多出的引号
            match_key=$(echo "$raw_name" | tr '[:lower:]' '[:upper:]' | sed 's/"//g')
            
            # 字典查询：精准匹配带空格的名称
            std_name=$(grep -i "^$match_key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            
            if [ -n "$std_name" ]; then
                echo "$std_name|$v_url|$f_n|$p_val.$line_num" >> "$ALL_MATCHED"
            fi
            ((line_num++))
        fi
    done < "$target_file"
done

# --- 并行测活 ---
HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"
if [ -s "$ALL_MATCHED" ]; then
    cat "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url_worker "{}" "$1"' -- "$HEALTHY_LIST"
fi

# --- 步骤 4: 组装结果 ---
echo "📦 阶段 3: 组装最终结果..."
echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1 -k4,4n "$HEALTHY_LIST" > "$DOWN_DIR/final_pool.tmp"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
    [ -z "$t_name" ] && continue

    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$DOWN_DIR/final_pool.tmp" | awk '!seen[$0]++' | while read -r v_u; do
        echo "$tpl_line" >> "$LIVE_M3U"
        echo "$v_u" >> "$LIVE_M3U"
    done
done < <(grep "#EXTINF" "$NAME_M3U")

echo "✅ 完成！保留空格匹配已生效，优先级：MyTV > Live > MeLive。"
