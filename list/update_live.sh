#!/bin/bash

# 1. 初始化路径与清理
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 每次运行时第1步：清除 down 目录
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 按照 down.txt 顺序下载直播源
echo "Step 1: Downloading original sources..."
while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    curl -L -s --connect-timeout 10 "$url" -o "$FILES_DIR/$filename"
done < "$LIST_DIR/down.txt"

# 3. 预处理并格式化为临时数据库 (TXT: Name,URL)
echo "Step 2: Pre-processing and formatting..."
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db"

# 遍历所有下载的文件
for filepath in "$FILES_DIR"/*; do
    [ -e "$filepath" ] || continue
    filename=$(basename "$filepath")
    work_file="$DOWN_DIR/$filename.tmp"
    
    cp "$filepath" "$work_file"
    sed -i 's/\r//' "$work_file"

    # --- 预处理：执行 Gather.m3u 处理原则 ---
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    # --- 格式化：提取并转为 Name,URL (仅限 HTTPS) ---
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
        grep "," "$work_file" | grep "https://" >> "$raw_db"
    fi
    rm "$work_file"
done

# 4. 基于模板匹配字典，生成 all.m3u 并构建 live.m3u
echo "Step 3: Matching dictionary and building final files..."
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 逐行读取模板 extinf.m3u
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "#EXTINF"* ]]; then
        # 提取模板中的标准 tvg-name
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 从 name.txt 中找到包含 target_name 的那一行的所有别名
        # 格式：别名1|别名2|标准名|别名3
        aliases=$(grep -E "(^|\|)$target_name(\||$)" "$LIST_DIR/name.txt")
        
        # 如果字典里没找到，就只拿 target_name 本身作为匹配项
        if [ -z "$aliases" ]; then
            search_pattern="^$target_name,"
        else
            # 将 别名1|别名2 转换为正则表达式 (^别名1,|^别名2,)
            search_pattern=$(echo "$aliases" | sed 's/|/,|^/g' | sed 's/^/^/' | sed 's/$/ ,/')
            # 简化逻辑：直接匹配这些名字开头的行
            search_regex="^($(echo "$aliases" | sed 's/|/|/g')),"
        fi

        # 在数据库中查找匹配的 URL (保留搜索顺序中最后一个匹配项)
        stream_url=$(grep -E "$search_regex" "$raw_db" | tail -n 1 | cut -d',' -f2)

        if [ -n "$stream_url" ]; then
            # 写入 all.m3u (全量汇总)
            echo "$line" >> "$all_m3u"
            echo "$stream_url" >> "$all_m3u"

            # 校验有效性后写入 live.m3u
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
        fi
    fi
done < "$LIST_DIR/extinf.m3u"

echo "Process Complete."
