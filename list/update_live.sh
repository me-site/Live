#!/bin/bash

# ====================================================
# IPTV 维护脚本 - IPTV Studio 精简版 (生成 live.m3u)
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
M3U_RAW_DIR="$BASE_DIR/files"
DOWN_DIR="$BASE_DIR/down"

mkdir -p "$M3U_RAW_DIR" "$DOWN_DIR" "$CONFIG_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"

# 统一输出文件
FINAL_M3U="$BASE_DIR/live.m3u"
MISSING_CHANNELS_FILE="$DOWN_DIR/missing_channels.txt"
DOWNLOAD_LOG="$DOWN_DIR/download_report.txt"

THREAD_COUNT=25
> "$MISSING_CHANNELS_FILE"
> "$DOWNLOAD_LOG"

# --- 步骤 1: 构建字典 ---
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

# --- 步骤 2: 下载原始镜像并执行特定逻辑 ---
echo "📥 阶段 1: 处理下载与特定源逻辑..."
IDX=100
PRIORITY_IDX="$DOWN_DIR/priority.idx"; > "$PRIORITY_IDX"

while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    echo "$f_n|$IDX" >> "$PRIORITY_IDX"
    ((IDX++))
    
    raw_path="$M3U_RAW_DIR/$f_n"
    target_path="$DOWN_DIR/$f_n"
    
    dl_info=$(curl -L -k -s --retry 2 --connect-timeout 10 -A "Mozilla/5.0" "$url" -o "$raw_path" -w "%{http_code},%{size_download}")
    h_code=$(echo $dl_info | cut -d',' -f1)

    if [ "$h_code" -eq 200 ]; then
        sed 's/^\xEF\xBB\xBF//; s/\r//g' "$raw_path" > "$target_path"

        # 统一 tvg-name 引号逻辑
        sed -i -E 's/tvg-name=["'\'']?([^"'\'',]+)["'\'']?/tvg-name=\1/g' "$target_path"
        sed -i -E 's/tvg-name=([^"'\,'\r\n]+?)([, ]+tvg-logo|[, ]+group-title|[, ]+catchup|$)/tvg-name="\1"\2/g' "$target_path"

        if [[ "$f_n" == *.txt ]]; then
            awk -F'[, ]+' '{if($1!="" && $2 ~ /^http/){print "#EXTINF:-1 tvg-name=\""$1"\","$1"\n"$2}}' "$target_path" > "${target_path}.tmp"
            mv "${target_path}.tmp" "$target_path"
        fi

        case "$f_n" in
           "Smart.m3u")
                awk '/^#EXTINF/ {if ($0 ~ /马来西亚|印度尼西亚|韩国|日本|印度|泰国|英国|越南|菲律宾|tvN|TvN/) {getline; next;}} { print $0 }' "$target_path" > "${target_path}.tmp" && mv "${target_path}.tmp" "$target_path"
                ;;
            "Merged.m3u")
                awk '{if ($0 ~ /^#EXTINF/) {if ($0 ~ /group-title="?(大陸频道|LiTV|未整理|GPT-.*)"?/) { skip = 1; } else { skip = 0; print $0; }} else { if (skip == 0) print $0; }}' "$target_path" > "${target_path}.tmp" && mv "${target_path}.tmp" "$target_path"
                awk '{if ($0 ~ /^#EXTINF/) {if ($0 ~ /group-title="?(綜合其他|兒童卡通|新闻财经|音乐综艺|电影戏剧|生活旅游|体育竞技|纪实探索|台湾备用)"?/) { n_p = 1; } else { n_p = 0; } print $0;} else if ($0 ~ /^https?:\/\//) {if (n_p == 1 && $0 !~ /^https:\/\/rtp\.cc\.cd\/tw\.php\?url=/) { print "https://rtp.cc.cd/tw.php?url=" $0; } else { print $0; } n_p = 0;} else { print $0; }}' "$target_path" > "${target_path}.tmp" && mv "${target_path}.tmp" "$target_path"
                ;;
            "Gather.m3u")
                awk '{if ($0 ~ /^#EXTINF/) {if ($0 ~ /电台|广播|游戏|Juli|港澳/) {skip = 1;} else {skip = 0; print $0;}} else if (skip == 0) {print $0;}}' "$target_path" > "${target_path}.tmp" && mv "${target_path}.tmp" "$target_path"
                sed -i '/rtp\.cc\.cd/! s@https://tv\.iill\.top/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/@g' "$target_path"
                sed -i '/rtp\.cc\.cd/! s@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_path"
                sed -i '/rtp\.cc\.cd/! s@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_path"
                ;;
            "Playlist.m3u")
                sed -i 's|https://sc2026.stream-link.org|https://link.itv.us.kg|g' "$target_path"
                ;;
        esac
    else
        echo "· $f_n    【 ❌ 】" >> "$DOWNLOAD_LOG"
    fi
done < "$DOWN_CONFIG"

# --- 步骤 3: 匹配与并发测活 ---
echo "🔍 阶段 2: 匹配与测活..."
ALL_MATCHED="$DOWN_DIR/all_matched.tmp"; > "$ALL_MATCHED"
UNIQUE_URLS="$DOWN_DIR/unique_urls.tmp"; > "$UNIQUE_URLS"
LIVE_URLS="$DOWN_DIR/live_urls.tmp"; > "$LIVE_URLS"

while IFS='|' read -r f_n p_val; do
    [ ! -f "$DOWN_DIR/$f_n" ] && continue
    while read -r line; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            raw_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
            [ -z "$raw_name" ] && raw_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            std_name=$(grep -i "^${raw_name^^}|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            if [ -n "$std_name" ]; then
                read -r v_url
                if [ -n "$v_url" ]; then
                    echo "$std_name|$v_url|$f_n|$p_val" >> "$ALL_MATCHED"
                    # 免检逻辑判断
                    if [[ "$f_n" == "Smart.m3u" || "$f_n" == "HunanTV.m3u" || "$f_n" == "Playlist.m3u" || \
                          "$v_url" == https://link.itv.us.kg* || "$v_url" == https://melive.onrender.com* || "$v_url" == https://rtp.cc.cd* ]]; then
                        echo "$v_url" >> "$LIVE_URLS"
                    else
                        echo "$v_url" >> "$UNIQUE_URLS"
                    fi
                fi
            fi
        fi
    done < "$DOWN_DIR/$f_n"
done < "$PRIORITY_IDX"

# URL 去重检测
[ -s "$UNIQUE_URLS" ] && sort -u "$UNIQUE_URLS" -o "$UNIQUE_URLS"

check_url_worker() {
    local u="$1"
    local code=$(curl -sL -k -I --connect-timeout 5 --max-time 8 "$u" 2>/dev/null | awk 'NR==1{print $2}')
    [[ "$code" =~ ^(200|206|301|302)$ ]] && echo "$u" >> "$2"
}
export -f check_url_worker

[ -s "$UNIQUE_URLS" ] && cat "$UNIQUE_URLS" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url_worker "{}" "$1"' -- "$LIVE_URLS"

HEALTHY_LIST="$DOWN_DIR/healthy_list.tmp"; > "$HEALTHY_LIST"
while IFS='|' read -r t u s p; do
    if grep -qF "$u" "$LIVE_URLS"; then
        echo "$t|$u|$s|$p" >> "$HEALTHY_LIST"
    fi
done < "$ALL_MATCHED"

# --- 步骤 4: 组装结果 (单文件模式) ---
echo "📦 阶段 3: 组装结果 (live.m3u)..."
printf "#EXTM3U\n" > "$FINAL_M3U"
MATCHED_STD_NAMES="$DOWN_DIR/matched_std_names.tmp"; > "$MATCHED_STD_NAMES"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' | xargs)
    [ -z "$t_name" ] && continue

    MATCH_RAW=$(awk -F'|' -v t="$t_name" '$1==t' "$HEALTHY_LIST" | sort -t'|' -k4 -n)
    
    if [ -n "$MATCH_RAW" ]; then
        echo "$t_name" >> "$MATCHED_STD_NAMES"
        while IFS='|' read -r _t v_u _src _p; do
            echo "$tpl_line" >> "$FINAL_M3U"
            echo "$v_u" >> "$FINAL_M3U"
        done <<< "$MATCH_RAW"
    fi
done < <(sed '1d' "$NAME_M3U")

# --- 步骤 5: 缺失频道统计 ---
while IFS='|' read -r -a names; do
    display_name=$(echo "${names[0]}" | tr -d '\r' | xargs)
    [ -z "$display_name" ] && continue
    std_name=$(grep -i "^${display_name^^}|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
    if [ -z "$std_name" ] || ! grep -q "^$std_name$" "$MATCHED_STD_NAMES"; then
        echo "$display_name" >> "$MISSING_CHANNELS_FILE"
    fi
done < "$NAME_TXT"

echo "✅ 任务完成。结果已保存至 live.m3u"
