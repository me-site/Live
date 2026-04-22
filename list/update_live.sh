#!/bin/bash

# ====================================================
# IPTV 自动化维护脚本 - 逻辑严密版
# ====================================================

TZ="Asia/Shanghai"
BASE_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")"; pwd)}"
CONFIG_DIR="$BASE_DIR/list"
DOWN_DIR="$BASE_DIR/down"
FILES_DIR="$BASE_DIR/files"

# --- 1. 环境准备 ---
echo "🧹 正在重置环境..."
rm -rf "$DOWN_DIR" "$FILES_DIR"
mkdir -p "$DOWN_DIR" "$FILES_DIR"

NAME_TXT="$CONFIG_DIR/name.txt"
NAME_M3U="$CONFIG_DIR/extinf.m3u"
DOWN_CONFIG="$CONFIG_DIR/down.txt"
LIVE_M3U="$BASE_DIR/live.m3u"
ALL_M3U="$DOWN_DIR/all.m3u"
THREAD_COUNT=30

# --- 2. 预处理名字映射表 (字典) ---
echo "🏗️ 正在构建映射字典..."
# 提取模板中所有的标准 tvg-name
TPL_NAMES="$DOWN_DIR/tpl_names.tmp"
sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p' "$NAME_M3U" | sort -u > "$TPL_NAMES"

# 建立 别名 -> 标准名 的映射表
DICT_MAP="$DOWN_DIR/dict.map"
> "$DICT_MAP"
if [ -f "$NAME_TXT" ]; then
    while read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        IFS='|' read -r -a aliases <<< "$line"
        target_std=""
        # 确定这一组别名中，哪个是模板里的标准名
        for a in "${aliases[@]}"; do
            clean_a=$(echo "$a" | xargs)
            if grep -qx "$clean_a" "$TPL_NAMES"; then
                target_std="$clean_a"
                break
            fi
        done
        # 如果找到标准名，将所有别名映射到它
        if [ -n "$target_std" ]; then
            for a in "${aliases[@]}"; do
                echo "$(echo "$a" | xargs | tr '[:lower:]' '[:upper:]')|$target_std" >> "$DICT_MAP"
            done
        fi
    done < "$NAME_TXT"
fi

# --- 3. 下载源并进行文件处理 (清洗都在 down 目录) ---
echo "📥 正在下载并处理源文件..."
PRIORITY_MAP="$DOWN_DIR/priority.map"
> "$PRIORITY_MAP"
line_num=100

while IFS=',' read -r f_n url || [ -n "$f_n" ]; do
    [[ -z "$f_n" || -z "$url" || "$f_n" == "#"* ]] && continue
    f_n=$(echo "$f_n" | xargs)
    url=$(echo "$url" | xargs)
    
    raw_file="$FILES_DIR/$f_n"
    work_file="$DOWN_DIR/$f_n"
    
    # 下载原始文件到 files
    curl -L -k -s --retry 2 --connect-timeout 10 -A "VLC/3.0.18" "$url" -o "$raw_file"
    [ ! -s "$raw_file" ] && continue
    
    # 复制到 down 目录进行处理
    cp "$raw_file" "$work_file"
    echo "$f_n|$line_num" >> "$PRIORITY_MAP"

    # A. TXT 转 M3U
    if [[ "$f_n" == *.txt ]]; then
        mv "$work_file" "${work_file}.tmp"
        echo "#EXTM3U" > "$work_file"
        while IFS=',' read -r cname curl_val || [ -n "$cname" ]; do
            [ -z "$curl_val" ] && continue
            echo "#EXTINF:-1 tvg-name=\"$cname\",$cname" >> "$work_file"
            echo "$curl_val" >> "$work_file"
        done < "${work_file}.tmp"
        rm "${work_file}.tmp"
    fi

    # B. tvg-name 双引号补全 (正则处理：补全缺失引号)
    # 匹配 tvg-name= 后接 [非引号非逗号字符] 直到遇到 [逗号或tvg-]
    sed -i -E 's/tvg-name="?([^" ,]+)"?([ ,]|tvg-)/tvg-name="\1"\2/g' "$work_file"

    # C. Gather.m3u 特殊处理
    if [[ "$f_n" == *"Gather"* ]]; then
        sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
        sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
        sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"
        sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    fi

    # D. 删除所有 http 开头的源
    sed -i '/^http:\/\/.*$/d' "$work_file"
    # 清理掉因为删除了 URL 而剩下的空 EXTINF 标签
    sed -i '/#EXTINF/{N;/^#EXTINF.*\n#EXTINF/d; /^#EXTINF.*\n$/d}' "$work_file"

    ((line_num++))
done < "$DOWN_CONFIG"

# --- 4. 汇总匹配池 (归一化) ---
echo "🔍 正在匹配并提取源..."
SOURCE_POOL="$DOWN_DIR/source_pool.tmp"
> "$SOURCE_POOL"

while read -r p_line; do
    f_n=$(echo "$p_line" | cut -d'|' -f1)
    p_val=$(echo "$p_line" | cut -d'|' -f2)
    work_file="$DOWN_DIR/$f_n"
    
    while read -r line; do
        if [[ "$line" =~ "#EXTINF" ]]; then
            # 提取 tvg-name
            c_name=$(echo "$line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
            [ -z "$c_name" ] && c_name=$(echo "$line" | awk -F',' '{print $NF}' | xargs)
            
            read -r c_url
            [[ ! "$c_url" =~ ^https:// ]] && continue
            
            # 字典转换
            key=$(echo "$c_name" | xargs | tr '[:lower:]' '[:upper:]')
            std_name=$(grep "^$key|" "$DICT_MAP" | head -n1 | cut -d'|' -f2)
            [ -z "$std_name" ] && std_name=$(grep -ix "$c_name" "$TPL_NAMES" | head -n1)
            
            if [ -n "$std_name" ]; then
                echo "$std_name|$c_url|$p_val" >> "$SOURCE_POOL"
            fi
        fi
    done < "$work_file"
done < "$PRIORITY_MAP"

# 排序：频道名优先，下载顺序次之
sort -t'|' -k1,1 -k3,3n "$SOURCE_POOL" -o "$DOWN_DIR/source_pool.sorted"

# --- 5. 拼合 all.m3u (以 extinf.m3u 为框架) ---
echo "📦 正在生成 all.m3u..."
RAW_INDEX="$DOWN_DIR/raw_index.tmp"
> "$RAW_INDEX"
idx=100000

while read -r tpl_line || [ -n "$tpl_line" ]; do
    if [[ "$tpl_line" =~ "#EXTINF" ]]; then
        t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
        [ -z "$t_name" ] && continue
        
        # 匹配 pool 中所有该名称的 URL
        grep "^$t_name|" "$DOWN_DIR/source_pool.sorted" | cut -d'|' -f2 | awk '!seen[$0]++' | while read -r m_url; do
            echo "${idx}|||${tpl_line}|||${m_url}" >> "$RAW_INDEX"
        done
        ((idx++))
    fi
done < "$NAME_M3U"

# 生成 all.m3u 备份
echo "#EXTM3U" > "$ALL_M3U"
sort -t'|' -k1,1n "$RAW_INDEX" | while read -r row; do
    echo "$row" | awk -F'|||' '{print $2}' >> "$ALL_M3U"
    echo "$row" | awk -F'|||' '{print $3}' >> "$ALL_M3U"
done

# --- 6. 并发测活生成 live.m3u ---
echo "⚡ 正在测活..."
CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"
> "$CLEAN_POOL"
export CLEAN_POOL

check_url() {
    item="$1"
    i_idx=$(echo "$item" | awk -F'|||' '{print $1}')
    i_inf=$(echo "$item" | awk -F'|||' '{print $2}')
    i_url=$(echo "$item" | awk -F'|||' '{print $3}')

    if [[ "$i_url" == https://rtp.cc.cd* || "$i_url" == https://melive.onrender.com* ]]; then
        echo "${i_idx}|||${i_inf}|||${i_url}" >> "$CLEAN_POOL"
    else
        code=$(curl -sL -k -I --connect-timeout 3 -A "VLC/3.0.18" "$i_url" 2>/dev/null | awk 'NR==1{print $2}')
        if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
            echo "${i_idx}|||${i_inf}|||${i_url}" >> "$CLEAN_POOL"
        fi
    fi
}
export -f check_url

cat "$RAW_INDEX" | xargs -P "$THREAD_COUNT" -I {} bash -c 'check_url "{}"'

# 写入最终 live.m3u
echo "#EXTM3U" > "$LIVE_M3U"
sort -t'|' -k1,1n "$CLEAN_POOL" | while read -r row; do
    echo "$row" | awk -F'|||' '{print $2}' >> "$LIVE_M3U"
    echo "$row" | awk -F'|||' '{print $3}' >> "$LIVE_M3U"
done

echo "✅ 任务完成！"
echo "📊 最终 live.m3u 频道总数: $(grep -c "#EXTINF" "$LIVE_M3U")"
