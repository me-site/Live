#!/bin/bash

# 1. 路径初始化与清理
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 清理旧数据
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 按照 down.txt 顺序下载直播源
echo "--- Step 1: 下载原始源 ---"
idx=0
while IFS= read -r url || [ -n "$url" ]; do
    url=$(echo "$url" | tr -d '\r' | xargs)
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    idx=$((idx+1))
    echo "Downloading: $url"
    curl -L -s -f --connect-timeout 15 "$url" -o "$FILES_DIR/src_${idx}.tmp"
done < "$LIST_DIR/down.txt"

# 3. 预处理并生成规范化的 raw_database.txt (Name,URL)
echo "--- Step 2: 格式化直播源 ---"
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db"

for file in "$FILES_DIR"/*; do
    [ -e "$file" ] || continue
    # 清理回车符
    work_file="${file}.work"
    tr -d '\r' < "$file" > "$work_file"

    # 执行 Gather.m3u 预处理原则
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    # 提取：兼容 M3U(tvg-name) 和 TXT(Name,URL)
    awk '
    BEGIN { IGNORECASE = 1 }
    # 处理 M3U
    /#EXTINF/ {
        name="";
        if (match($0, /tvg-name="?([^",]*)"?/, a)) name=a[1];
        else if (match($0, /,(.*)$/, b)) name=b[1];
        gsub(/^[ \t]+|[ \t]+$/, "", name);
        getline url;
        gsub(/^[ \t]+|[ \t]+$/, "", url);
        if (url ~ /^https:\/\//) print name "," url;
    }
    # 处理 TXT (CCTV1,https://...)
    !/#EXTINF/ && /,https:\/\// {
        split($0, c, ",");
        n=c[1]; u=c[2];
        gsub(/^[ \t]+|[ \t]+$/, "", n);
        gsub(/^[ \t]+|[ \t]+$/, "", u);
        if (u ~ /^https:\/\//) print n "," u;
    }
    ' "$work_file" >> "$raw_db"
    rm "$work_file"
done

# 4. 字典关联与模板填充
echo "--- Step 3: 字典匹配与模板填充 ---"
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 遍历模板 extinf.m3u
while IFS= read -r template_line || [ -n "$template_line" ]; do
    if [[ "$template_line" == "#EXTINF"* ]]; then
        # 提取 tvg-name 作为标准 ID (如 CCTV1)
        target_id=$(echo "$template_line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 在 name.txt 中找到包含该 ID 的整行，获取所有别名
        # 使用 grep -w 确保精确匹配，避免 CCTV1 匹配到 CCTV10
        alias_line=$(grep -Ei "(^|\|)$target_id(\||$)" "$LIST_DIR/name.txt" | tr -d '\r')
        
        if [ -z "$alias_line" ]; then
            # 如果字典没写，只搜自己
            search_regex="^$target_id,"
        else
            # 将 CCTV1|中央一台 转换为正则 ^(CCTV1|中央一台),
            # 对特殊符号如 () - 进行转义处理
            regex_part=$(echo "$alias_line" | sed 's/[][()\-+.^$*]/\\&/g')
            search_regex="^($regex_part),"
        fi

        # 在 raw_db 中搜寻所有命中别名的直播源
        grep -Ei "$search_regex" "$raw_db" | cut -d',' -f2- | while read -r stream_url; do
            [ -z "$stream_url" ] && continue
            
            # 写入汇总 all.m3u
            echo "$template_line" >> "$all_m3u"
            echo "$stream_url" >> "$all_m3u"

            # 校验有效性
            is_valid=0
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                is_valid=1
            else
                # 3秒超时检测
                if curl -I -s -m 3 -o /dev/null -f "$stream_url"; then
                    is_valid=1
                fi
            fi

            if [ "$is_valid" -eq 1 ]; then
                echo "$template_line" >> "$final_live"
                echo "$stream_url" >> "$final_live"
            fi
        done
    fi
done < "$LIST_DIR/extinf.m3u"

echo "任务完成！"
