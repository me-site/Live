#!/bin/bash

# ====================================================
# IPTV 维护脚本 - 深度模拟播放器下载 + 完整保底逻辑版
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
M3U_RAW_DIR="$BASE_DIR/files"
DOWN_DIR="$BASE_DIR/down"

# --- 目录初始化 ---
mkdir -p "$M3U_RAW_DIR"
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR"
mkdir -p "$CONFIG_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"

LIVE_M3U="$BASE_DIR/live.m3u"
MISSING_CHANNELS_FILE="$DOWN_DIR/missing_channels.txt"
DOWNLOAD_LOG="$DOWN_DIR/download_report.txt"

THREAD_COUNT=25
> "$MISSING_CHANNELS_FILE"
> "$DOWNLOAD_LOG"

# --- 步骤 1: 构建标准字典 ---
echo "🏗️ 正在构建标准字典..."
TEMPLATE_NAMES_FILE="$DOWN_DIR/template_names.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TEMPLATE_NAMES_FILE"

DICT_MAP="$DOWN_DIR/dict_map.tmp"; > "$DICT_MAP"
while IFS='|' read -r -a names; do
    [ ${#names[@]} -eq 0 ] && continue
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

# --- 步骤 2: 下载原始镜像并处理逻辑 (保留核心逻辑并增强模拟) ---
echo "📥 阶段 1: 处理下载逻辑..."
IDX=100
PRIORITY_IDX="$DOWN_DIR/priority.idx"; > "$PRIORITY_IDX"

while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    echo "$f_n|$IDX" >> "$PRIORITY_IDX"
    ((IDX++))
    
    raw_path="$M3U_RAW_DIR/$f_n"
    target_path="$DOWN_DIR/$f_n"

    # 动态获取域名用于 Referer
    domain=$(echo "$url" | awk -F[/:] '{print $1"//"$4}')

    # 执行下载到临时文件 (增强模拟播放器头)
    dl_info=$(curl -L -k -s --retry 3 --retry-delay 5 --connect-timeout 20 \
        -A "VLC/3.0.18 LibVLC/3.0.18" \
        -H "Referer: $domain" \
        -H "Origin: $domain" \
        -H "Connection: keep-alive" \
        -H "Range: bytes=0-" \
        -H "Accept: */*" \
        "$url" -o "$raw_path.new" -w "%{http_code}")

    # 判断下载是否有效（排除 403 和 CF 拦截页）
    if [[ "$dl_info" =~ ^(200|206)$ ]] && ! grep -q "Just a moment..." "$raw_path.new" && [ -s "$raw_path.new" ]; then
        mv "$raw_path.new" "$raw_path"
        echo "DEBUG: $f_n 下载成功。"
    else
        rm -f "$raw_path.new"
        echo "DEBUG: $f_n GitHub 下载失败 (CF拦截或Code:$dl_info)，尝试调用本地缓存。"
    fi

    # 核心判断：如果有文件（不论是新下的还是旧的）才进行后续处理
    if [ -f "$raw_path" ] && [ -s "$raw_path" ]; then
        h_size=$(awk "BEGIN {printf \"%.1f MB\", $(stat -c%s "$raw_path")/1048576}")
        echo "· $f_n    【 $h_size 】" >> "$DOWNLOAD_LOG"

        sed 's/^\xEF\xBB\xBF//; s/\r//g' "$raw_path" > "$target_path"

        if [[ "$f_n" == *.txt ]]; then
            awk -F'[, ]+' '{if($1!="" && $2 ~ /^http/){print "#EXTINF:-1 tvg-name=\""$1"\","$1"\n"$2}}' "$target_path" > "${target_path}.tmp"
            mv "${target_path}.tmp" "$target_path"
        fi

        # 规范化 tvg-name 标签
        sed -i -E 's/tvg-name=["'\'']?([^"'\'',]+)["'\'']?/tvg-name=\1/g' "$target_path"
        sed -i -E 's/tvg-name=([^",]+)([, ]+tvg-logo|[, ]+catchup|,)/tvg-name="\1"\2/g' "$target_path"
        sed -i -E 's/tvg-name=([^", ]+)$/tvg-name="\1"/g' "$target_path"

        case "$f_n" in
            "Gather.m3u")
                awk '{if ($0 ~ /^#EXTINF/) {if ($0 ~ /电台|广播|游戏|地方|Juli|港澳/) {skip = 1;} else {skip = 0; print $0;}} else if (skip == 0) {print $0;}}' "$target_path" > "${target_path}.tmp" && mv "${target_path}.tmp" "$target_path"
                sed -i 's@https://tv\.iill\.top/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/@g' "$target_path"
                sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_path"
                sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_path"
                ;;
        esac
    else
        echo "· $f_n    【 ❌ 彻底失效 】" >> "$DOWNLOAD_LOG"
    fi
done < "$DOWN_CONFIG"

# --- 步骤 3: 匹配与测活 ---
echo "🔍 阶段 2: 匹配与测活..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"
while IFS='|' read -r f_n p_val; do
    [ ! -f "$DOWN_DIR/$f_n" ] && continue
    while read -r line; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            raw_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            std_name=$(grep -i "^${raw_name^^}|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            if [ -n "$std_name" ]; then
                read -r v_url
                [ -n "$v_url" ] && echo "$std_name|$v_url|$f_n|$p_val" >> "$ALL_MATCHED"
            fi
        fi
    done < "$DOWN_DIR/$f_n"
done < "$PRIORITY_IDX"

HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"

# 1. 定义测活规则（函数）
check_url_worker() {
    IFS='|' read -r t u s p <<< "$1"
    
    # 免检逻辑 (Smart, Playlist 以及 rtp.cc.cd 开头的源)
    if [[ "$s" == "Smart.m3u" || "$s" == "Playlist.m3u" || "$u" == https://rtp.cc.cd/* ]]; then
        echo "$t|$u|$s|$p" >> "$2"
        return
    fi
    
    # 普通源：模拟 VLC 测活
    local code=$(curl -sL -k -I --connect-timeout 5 --max-time 8 -A "VLC/3.0.18 LibVLC/3.0.18" "$u" 2>/dev/null | awk 'NR==1{print $2}')
    [[ "$code" =~ ^(200|206|301|302)$ ]] && echo "$t|$u|$s|$p" >> "$2"
}

# 2. 导出函数环境（让多线程 xargs 能识别到它）
export -f check_url_worker

# 3. 启动并行任务（发令枪）
if [ -s "$ALL_MATCHED" ]; then
    echo "🚀 正在并行测活中，请稍候..."
    cat "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url_worker "{}" "$1"' -- "$HEALTHY_LIST"
else
    echo "⚠️ 警告：没有找到任何匹配的频道，请检查 name.txt 或字典配置。"
fi

# --- 步骤 4: 组装结果 (修正排序增强版) ---
echo "📦 阶段 3: 组装 live.m3u..."
printf "#EXTM3U\n" > "$LIVE_M3U"

# 预处理测活结果，确保它是纯净的数字排序
# 这样在循环内部处理时会更快更准
SORTED_HEALTHY="$DOWN_DIR/healthy_sorted.tmp"
sort -t'|' -k4 -n "$HEALTHY_LIST" > "$SORTED_HEALTHY"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    
    # 提取模板中的 tvg-name
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
    [ -z "$t_name" ] && continue

    # 从排好序的文件中提取匹配该频道的源
    # 因为 SORTED_HEALTHY 已经全局按权重排过序了，这里拿到的顺序必然是 down.txt 的顺序
    MATCH_RAW=$(awk -F'|' -v t="$t_name" '$1==t' "$SORTED_HEALTHY")
    
    if [ -n "$MATCH_RAW" ]; then
        while IFS='|' read -r _t v_u _src _p; do
            # 过滤非 https 或 flv 的逻辑保持不变
            skip_live=0
            [[ ! "$v_u" =~ ^https:// ]] && skip_live=1
            [[ "$v_u" =~ \.flv ]] && skip_live=1

            if [ $skip_live -eq 0 ]; then
                echo "$tpl_line" >> "$LIVE_M3U"
                echo "$v_u" >> "$LIVE_M3U"
            fi
        done <<< "$MATCH_RAW"
    fi
done < <(grep "#EXTINF" "$NAME_M3U") # 更加稳健的读取方式，直接过滤 EXTINF 行

echo "✅ 任务完成，live.m3u 已生成。"
