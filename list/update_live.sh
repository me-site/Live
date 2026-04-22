#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 最终整合版
# ====================================================

TZ="Asia/Shanghai"
# 自动识别基础目录，适配 GitHub Actions
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
DOWN_DIR="$BASE_DIR/down"
FILES_DIR="$BASE_DIR/files"

# --- 步骤 1: 初始化 ---
echo "🧹 正在清理并初始化仓库目录..."
# 每次运行前清除并重建 down 目录
rm -rf "$DOWN_DIR"
mkdir -p "$DOWN_DIR" "$FILES_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
ALL_M3U="$DOWN_DIR/all.m3u"
LIVE_M3U="$BASE_DIR/live.m3u"
THREAD_COUNT=25  # 测活并发数

# --- 步骤 2: 下载与格式预处理 ---
echo "📥 正在下载源文件并纠正 tvg-name 格式..."
PRIORITY_MAP="$DOWN_DIR/priority.map"
> "$PRIORITY_MAP"
idx=100

sed 's/\r//g; /^$/d' "$DOWN_CONFIG" | while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs); url=$(echo "$url" | xargs)
    target_file="$FILES_DIR/$f_n"
    
    echo "正在处理: $f_n"
    curl -L -k -s --retry 2 --connect-timeout 15 -A "VLC/3.0.18" "$url" -o "$target_file"
    [ ! -s "$target_file" ] && continue
    echo "$f_n|$idx" >> "$PRIORITY_MAP"

    # A. TXT 转 M3U
    if [[ "$f_n" == *.txt ]]; then
        temp_m3u="$DOWN_DIR/${f_n%.txt}.m3u"
        echo "#EXTM3U" > "$temp_m3u"
        while IFS=',' read -r name vurl || [ -n "$name" ]; do
            [ -z "$vurl" ] && continue
            echo "#EXTINF:-1 tvg-name=\"$name\",$name" >> "$temp_m3u"
            echo "$vurl" >> "$temp_m3u"
        done < "$target_file"
        mv "$temp_m3u" "$target_file"
    fi

    # B. 纠正 tvg-name 格式 (补全双引号，识别 tvg- 开头或逗号结束)
    # 针对 tvg-name=CCTV1、tvg-name="CCTV1 等不规范格式统一纠正
    sed -i -E 's/tvg-name="?([^", ]+)"?/tvg-name="\1"/g' "$target_file"

    # C. Gather 特殊代理规则
    if [[ "$f_n" == *"Gather"* ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$target_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$target_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$target_file"
    fi
    ((idx++))
done

# --- 步骤 3: 建立标准字典 ---
echo "🏗️ 正在构建字典映射..."
TEMPLATE_NAMES="$DOWN_DIR/tpl_names.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TEMPLATE_NAMES"

DICT_MAP="$DOWN_DIR/dict.map"
> "$DICT_MAP"
while IFS='|' read -r -a names; do
    target_std=""
    for n in "${names[@]}"; do
        clean_n=$(echo "$n" | xargs)
        [ -z "$clean_n" ] && continue
        target_std=$(grep -ix "$clean_n" "$TEMPLATE_NAMES" | head -n1)
        [ -n "$target_std" ] && break
    done
    if [ -n "$target_std" ]; then
        for n in "${names[@]}"; do
            echo "$(echo "$n" | tr '[:lower:]' '[:upper:]')|$target_std" >> "$DICT_MAP"
        done
    fi
done < "$NAME_TXT"

# --- 步骤 4: 拼合全量 all.m3u ---
echo "📦 正在拼合 all.m3u (严格模板顺序 & 仅限 HTTPS)..."
MATCH_POOL="$DOWN_DIR/match_pool.tmp"; > "$MATCH_POOL"

for f in "$FILES_DIR"/*; do
    [ ! -f "$f" ] && continue
    f_name=$(basename "$f")
    p_val=$(grep "^$f_name|" "$PRIORITY_MAP" | cut -d'|' -f2)
    [ -z "$p_val" ] && p_val=999
    
    while read -r line; do
        if [[ "$line" =~ "tvg-name=\"" ]]; then
            raw_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
            read -r v_url
            # 过滤：删除 http 开头的，只保留 https
            [[ ! "$v_url" =~ ^https:// ]] && continue
            
            key=$(echo "$raw_name" | tr '[:lower:]' '[:upper:]')
            std_name=$(grep "^$key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            if [ -n "$std_name" ]; then
                echo "$std_name|$line|$v_url|$p_val" >> "$MATCH_POOL"
            fi
        fi
    done < "$f"
done

# 预排序：标准名 + 下载源优先级
POOL_SORTED="$DOWN_DIR/pool.sorted"
sort -t'|' -k1,1 -k4,4n "$MATCH_POOL" > "$POOL_SORTED"

# 按照 extinf.m3u 模板物理顺序组装
RAW_ALL_LIST="$DOWN_DIR/all_raw.tmp"; > "$RAW_ALL_LIST"
tpl_idx=100000
while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
    [ -z "$t_name" ] && continue

    awk -F'|' -v t="$t_name" '$1==t {print $2 "|" $3}' "$POOL_SORTED" | awk '!seen[$0]++' | while read -r pair; do
        echo "$tpl_idx|$pair" >> "$RAW_ALL_LIST"
    done
    ((tpl_idx++))
done < <(grep "#EXTINF" "$NAME_M3U")

# 生成 down/all.m3u
echo "#EXTM3U" > "$ALL_M3U"
cut -d'|' -f2,3 "$RAW_ALL_LIST" | tr '|' '\n' >> "$ALL_M3U"

# --- 步骤 5: 最终测活生成 live.m3u ---
echo "⚡ 正在执行最终测活..."
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"; > "$CLEAN_POOL"

export CLEAN_POOL
check_worker() {
    row="$1"
    r_idx=$(echo "$row" | cut -d'|' -f1)
    r_inf=$(echo "$row" | cut -d'|' -f2)
    r_url=$(echo "$row" | cut -d'|' -f3)

    # 免检名单
    if [[ "$r_url" == *"rtp.cc.cd"* || "$r_url" == *"melive.onrender.com"* ]]; then
        echo "$r_idx|$r_inf|$r_url" >> "$CLEAN_POOL"
        return
    fi

    # 测活
    code=$(curl -sL -k -I --connect-timeout 3 "$r_url" 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
        echo "$r_idx|$r_inf|$r_url" >> "$CLEAN_POOL"
    fi
}
export -f check_worker

# 并发执行
cat "$RAW_ALL_LIST" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_worker "{}"'

# 恢复物理顺序并写回 live.m3u
echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1n "$CLEAN_POOL" | while IFS='|' read -r o_idx o_inf o_url; do
    echo "$o_inf" >> "$LIVE_M3U"
    echo "$o_url" >> "$LIVE_M3U"
done

echo "✅ 任务完成！"
