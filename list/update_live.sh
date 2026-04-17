#!/bin/bash

# ====================================================
# IPTV 维护脚本 - Live 专属修复版 (强制 HTTPS)
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
M3U_RAW_DIR="$BASE_DIR/files"
DOWN_DIR="$BASE_DIR/down"

# --- 目录初始化 ---
# 确保 files 存在
mkdir -p "$M3U_RAW_DIR"
# 每次运行清理并重建 down 目录
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR"
# 确保配置目录存在
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

# --- 步骤 2: 下载原始镜像并处理逻辑 ---
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
    
    # 强化版的 curl：模拟更真实的浏览器头部，并增加重试次数
    dl_info=$(curl -L -k -s --retry 3 --retry-delay 5 --connect-timeout 15 \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8" \
        -H "Accept-Language: zh-CN,zh;q=0.9" \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        "$url" -o "$raw_path" -w "%{http_code},%{size_download}")

    h_code=$(echo $dl_info | cut -d',' -f1)
    b_size=$(echo $dl_info | cut -d',' -f2)

    # 打印调试信息，方便在 GitHub Actions 日志里看
    echo "DEBUG: 访问 $f_n 状态码: $h_code, 大小: $b_size"

    if [ "$h_code" -eq 200 ]; then
        h_size=$(awk "BEGIN {printf \"%.1f MB\", $b_size/1048576}")
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
        echo "· $f_n    【 ❌ 】" >> "$DOWNLOAD_LOG"
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
check_url_worker() {
    IFS='|' read -r t u s p <<< "$1"
    if [[ "$s" == "ChinaTV.m3u" || "$s" == "Playlist.m3u" ]]; then
        echo "$t|$u|$s|$p" >> "$2"
        return
    fi
    local code=$(curl -sL -k -I --connect-timeout 5 --max-time 8 "$u" 2>/dev/null | awk 'NR==1{print $2}')
    [[ "$code" =~ ^(200|206|301|302)$ ]] && echo "$t|$u|$s|$p" >> "$2"
}
export -f check_url_worker
[ -s "$ALL_MATCHED" ] && cat "$ALL_MATCHED" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url_worker "{}" "$1"' -- "$HEALTHY_LIST"

# --- 步骤 4: 组装结果 (强制 HTTPS & 非 FLV) ---
echo "📦 阶段 3: 组装 live.m3u..."
printf "#EXTM3U\n" > "$LIVE_M3U"
MATCHED_STD_NAMES="$DOWN_DIR/matched_std_names.tmp"; > "$MATCHED_STD_NAMES"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
    [ -z "$t_name" ] && continue

    MATCH_RAW=$(awk -F'|' -v t="$t_name" '$1==t' "$HEALTHY_LIST" | sort -t'|' -k4 -n)
    
    if [ -n "$MATCH_RAW" ]; then
        echo "$t_name" >> "$MATCHED_STD_NAMES"
        while IFS='|' read -r _t v_u _src _p; do
            skip_live=0
            [[ ! "$v_u" =~ ^https:// ]] && skip_live=1
            [[ "$v_u" =~ \.flv ]] && skip_live=1

            if [ $skip_live -eq 0 ]; then
                echo "$tpl_line" >> "$LIVE_M3U"
                echo "$v_u" >> "$LIVE_M3U"
            fi
        done <<< "$MATCH_RAW"
    fi
done < <(sed '1d' "$NAME_M3U")

# --- 步骤 5: 缺失统计 ---
while IFS='|' read -r -a names; do
    display_name=$(echo "${names[0]}" | xargs)
    std_name=$(grep -i "^${display_name^^}|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
    if [ -z "$std_name" ] || ! grep -q "^$std_name$" "$MATCHED_STD_NAMES"; then
        echo "$display_name" >> "$MISSING_CHANNELS_FILE"
    fi
done < "$NAME_TXT"

echo "✅ 任务完成，live.m3u 已生成。"
