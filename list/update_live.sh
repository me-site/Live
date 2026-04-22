#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 优先级绝对锁定 + 增强匹配修复版
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
    # Smart 和 rtp.cc.cd 免检，其余 curl 测活
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
        target_std=$(grep -i "^$clean_n$" "$TEMPLATE_NAMES_FILE" | head -n1)
        [ -n "$target_std" ] && break
    done
    if [ -n "$target_std" ]; then
        for n in "${names[@]}"; do
            clean_n=$(echo "$n" | xargs)
            [ -n "$clean_n" ] && echo "${clean_n^^}|$target_std" >> "$DICT_MAP"
        done
    fi
done < "$NAME_TXT"

# --- 步骤 2: 下载逻辑 ---
echo "📥 阶段 1: 下载源文件..."
# 增加对 down.txt 的清洗，防止换行符干扰
sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    raw_path="$M3U_RAW_DIR/$f_n"
    target_path="$DOWN_DIR/$f_n"
    
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

# --- 步骤 3: 匹配与权重分配 (深度兼容版) ---
echo "🔍 阶段 2: 匹配并分配权重..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"

for target_file in "$DOWN_DIR"/*; do
    [ ! -f "$target_file" ] && continue
    f_n=$(basename "$target_file")
    [[ "$f_n" == *.tmp || "$f_n" == *.idx || "$f_n" == *"clean"* ]] && continue
    
    case "$f_n" in
        *"MyTV"*)   p_val=100 ;;
        *"Live.txt"*) p_val=101 ;;
        *"MeLive"*)   p_val=102 ;; # 确保 MeLive 优先级很高
        *"Gather"*)   p_val=110 ;;
        *"Smart"*)    p_val=111 ;;
        *)            p_val=120 ;;
    esac

    echo "DEBUG: 正在分析文件 [$f_n] ..."

    line_num=1000
    while read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            # 1. 提取原始名称并清理
            raw_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            # 2. 读取下一行 URL
            read -r v_url || [ -n "$v_url" ]
            [ -z "$v_url" ] && continue
            
            # 3. 【核心修复】繁简预处理 + 去空格
            # 将常见的繁体字临时替换为简体进行匹配（针对台湾源）
            search_name=$(echo "$raw_name" | sed 's/台/台/g; s/視/视/g; s/國/国/g; s/際/际/g; s/體/体/g; s/育/育/g; s/新聞/新闻/g; s/綜合/综合/g; s/娛樂/娱乐/g')
            search_key=$(echo "$search_name" | tr '[:lower:]' '[:upper:]' | sed 's/ //g')

            # 4. 在字典中查找
            std_name=$(grep -i "^$search_key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            
            # 5. 【保底逻辑】如果精准匹配失败，尝试关键词包含匹配
            if [ -z "$std_name" ]; then
                std_name=$(grep -i "$search_key" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            fi
            
            if [ -n "$std_name" ]; then
                echo "$std_name|$v_url|$f_n|$p_val.$line_num" >> "$ALL_MATCHED"
            else
                # 记录哪些名字没匹配上，方便你查问题
                echo "DEBUG: 未匹配频道: [$raw_name] 来自 $f_n" >> "$DOWN_DIR/unmatched.log"
            fi
            ((line_num++))
        fi
    done < "$target_file"
done

# 并行测活
HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"
if [ -s "$ALL_MATCHED" ]; then
    echo "🚀 启动并行测活 (线程: $THREAD_COUNT)..."
    cat "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url_worker "{}" "$1"' -- "$HEALTHY_LIST"
else
    echo "❌ 错误：没有任何匹配结果，请检查字典或源文件。"
fi

# --- 步骤 4: 组装结果 ---
echo "📦 阶段 3: 组装最终结果..."
echo "#EXTM3U" > "$LIVE_M3U"

# 排序逻辑：频道名升序(k1)，权重数字升序(k4,n)
FINAL_POOL="$DOWN_DIR/final_pool.tmp"
sort -t'|' -k1,1 -k4,4n "$HEALTHY_LIST" > "$FINAL_POOL"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
    [ -z "$t_name" ] && continue

    # 从排好序的池中提取 URL，并保持物理权重去重
    awk -F'|' -v t="$t_name" '$1==t {print $2}' "$FINAL_POOL" | awk '!seen[$0]++' | while read -r v_u; do
        [[ ! "$v_u" =~ ^https?:// ]] && continue
        echo "$tpl_line" >> "$LIVE_M3U"
        echo "$v_u" >> "$LIVE_M3U"
    done
done < <(grep "#EXTINF" "$NAME_M3U")

echo "✅ 完成！优先级已强制锁定：MyTV(100) > Live(101) > MeLive(102)。"
