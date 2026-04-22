#!/bin/bash

# 1. 路径初始化与清理
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 运行第1步：清除 down 目录
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 按照 down.txt 顺序下载直接源
echo "Step 1: Downloading sources..."
while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    curl -L -s --connect-timeout 10 "$url" -o "$FILES_DIR/$filename"
done < "$LIST_DIR/down.txt"

# 3. 预处理与格式化为 TXT (保留特殊符号)
echo "Step 2: Pre-processing and Formatting..."
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db"

while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    filepath="$FILES_DIR/$filename"
    work_file="$DOWN_DIR/$filename.tmp"
    
    [ ! -f "$filepath" ] && continue
    cp "$filepath" "$work_file"
    sed -i 's/\r//' "$work_file"

    # --- 预处理：执行 Gather.m3u 替换原则 ---
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    # --- 格式化为 Name,URL 并过滤 HTTP ---
    if grep -q "#EXTINF" "$work_file"; then
        awk '
        /#EXTINF/ {
            name=""; 
            if ($0 ~ /tvg-name="/) {
                match($0, /tvg-name="([^"]+)"/, a);
                name=a[1];
            }
            if (name == "") {
                match($0, /,(.*)$/, b);
                name=b[1];
            }
            gsub(/^[ \t]+|[ \t]+$/, "", name);
            getline url;
            if (url ~ /^https:\/\//) {
                print name "," url;
            }
        }' "$work_file" >> "$raw_db"
    else
        grep "," "$work_file" | grep "https://" | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1 "," $2}' >> "$raw_db"
    fi
    rm "$work_file"
done < "$LIST_DIR/down.txt"

# 4. 字典匹配与多链接拼合生成
echo "Step 3: Dictionary multi-matching and health check..."
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 逐行读取模板 extinf.m3u
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "#EXTINF"* ]]; then
        # 提取模板要求的 tvg-name
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 在 name.txt 中找到包含 target_name 的那一行的所有别名
        aliases=$(grep -E "(^|\|)$target_name(\||$)" "$LIST_DIR/name.txt")
        
        if [ -z "$aliases" ]; then
            search_regex="^$target_name,"
        else
            search_regex="^($(echo "$aliases" | sed 's/|/|/g')),"
        fi

        # 从数据库中提取所有匹配到的链接 (不再使用 tail -n 1，而是全部提取)
        # 根据 down.txt 的下载顺序，raw_db 中已按序排列
        grep -E "$search_regex" "$raw_db" | cut -d',' -f2 | while read -r stream_url; do
            [ -z "$stream_url" ] && continue

            # 1. 写入 all.m3u (全量)
            echo "$line" >> "$all_m3u"
            echo "$stream_url" >> "$all_m3u"

            # 2. 校验有效性后写入 live.m3u
            is_valid=0
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                is_valid=1
            else
                if curl -I -s -m 3 -o /dev/null -f "$stream_url"; then
                    is_valid=1
                fi
            fi

            if [ "$is_valid" -eq 1 ]; then
                echo "$line" >> "$final_live"
                echo "$stream_url" >> "$final_live"
            fi
        done
    fi
done < "$LIST_DIR/extinf.m3u"

echo "Done. live.m3u updated with multi-source matching."
