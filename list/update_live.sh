#!/bin/bash

# 1. 路径初始化
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 强制清理
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 下载原始源 (针对 "别名,链接" 格式优化)
echo "--- Step 1: 下载源文件 ---"
idx=0
while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | tr -d '\r' | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    if [[ "$line" == *","* ]]; then
        alias_name=$(echo "$line" | cut -d',' -f1)
        url=$(echo "$line" | cut -d',' -f2-)
    else
        alias_name="source"
        url="$line"
    fi

    idx=$((idx+1))
    filename="src_${idx}.tmp"
    echo "正在下载 [${idx}] ${alias_name}: $url"
    
    curl -L -k -s -f \
         -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
         --connect-timeout 20 "$url" -o "$FILES_DIR/$filename"
    
    [ -s "$FILES_DIR/$filename" ] && echo "   [成功] 文件大小: $(du -sh "$FILES_DIR/$filename" | cut -f1)" || echo "   [失败] 下载为空"
done < "$LIST_DIR/down.txt"

# 3. 提取、去重并生成 raw_database.txt
echo "--- Step 2: 提取数据并执行物理去重 ---"
raw_db_tmp="$DOWN_DIR/raw_database_tmp.txt"
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db_tmp"

# 检查下载目录下是否有文件
file_count=$(ls -1 "$FILES_DIR"/*.tmp 2>/dev/null | wc -l)
echo "待处理文件数: $file_count"

for file in "$FILES_DIR"/*.tmp; do
    [ -s "$file" ] || continue
    
    # 预处理：转码并清理
    work_file="${file}.process"
    iconv -t UTF-8//IGNORE "$file" > "$work_file" 2>/dev/null || cp "$file" "$work_file"
    tr -d '\r' < "$work_file" > "${work_file}.clean"
    
    # 执行清洗原则
    sed -i '/\(电台\|精選\|游戏\|广播\)/d' "${work_file}.clean"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "${work_file}.clean"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "${work_file}.clean"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "${work_file}.clean"

    # 更强大的提取逻辑：同时兼容标准 M3U, 简易 M3U 和 名字,链接 格式
    awk -F',' '
    BEGIN { IGNORECASE = 1 }
    # 匹配 M3U 的 EXTINF 行
    /#EXTINF/ {
        name = "";
        if (match($0, /tvg-name="?([^",]*)"?/, a)) name = a[1];
        else if (match($0, /,(.*)$/, b)) name = b[1];
        gsub(/^[ \t]+|[ \t]+$/, "", name);
        # 找下一行非空的链接
        while (getline url > 0) {
            gsub(/^[ \t]+|[ \t]+$/, "", url);
            if (url ~ /^https?:\/\//) {
                if (name != "") print name "," url;
                break;
            }
            if (url ~ /^#/) break; 
        }
        next;
    }
    # 匹配 名字,链接 或 纯链接 格式
    /https?:\/\// {
        if (NF >= 2) {
            n=$1; u=$2;
            # 处理 URL 里自带逗号的情况
            if (NF > 2) u=$(NF); 
            gsub(/^[ \t]+|[ \t]+$/, "", n);
            gsub(/^[ \t]+|[ \t]+$/, "", u);
            if (u ~ /^http/ && n !~ /^#/) print n "," u;
        }
    }
    ' "${work_file}.clean" >> "$raw_db_tmp"
    rm -f "$work_file" "${work_file}.clean"
done

# 物理去重：保留第一次出现的 URL
awk -F',' '!seen[$2]++' "$raw_db_tmp" > "$raw_db"

echo "物理去重完成。"
echo "原始提取总行数: $(wc -l < "$raw_db_tmp" 2>/dev/null || echo 0)"
echo "去重后有效行数: $(wc -l < "$raw_db")"
echo "--- 任务结束 ---"
