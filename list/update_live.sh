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

for file in "$FILES_DIR"/*; do
    [ -s "$file" ] || continue
    work_file="${file}.process"
    tr -d '\r' < "$file" > "$work_file"

    # 执行清洗
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    awk '
    BEGIN { IGNORECASE = 1 }
    /#EXTINF/ {
        name = "";
        if (match($0, /tvg-name="?([^",]*)"?/, a)) name = a[1];
        else if (match($0, /,(.*)$/, b)) name = b[1];
        gsub(/^[ \t]+|[ \t]+$/, "", name);
        while (getline url > 0) {
            gsub(/^[ \t]+|[ \t]+$/, "", url);
            if (url ~ /^https:\/\//) { if (name != "") print name "," url; break; }
            if (url ~ /^#EXTINF/) break; 
        }
    }
    !/#EXTINF/ && /https:\/\// && /,/ {
        split($0, p, ","); n=p[1]; u=p[2];
        gsub(/^[ \t]+|[ \t]+$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", u);
        if (u ~ /^https:\/\//) print n "," u;
    }
    ' "$work_file" >> "$raw_db_tmp"
    rm "$work_file"
done

# --- 【方案 A 的核心：物理去重】 ---
# 使用 awk 处理：以 URL (第二列) 为键，只保留第一次出现的行，保持原始顺序
awk -F',' '!seen[$2]++' "$raw_db_tmp" > "$raw_db"
rm "$raw_db_tmp"
echo "物理去重完成。原始数据条数: $(wc -l < "$raw_db_tmp" 2>/dev/null || echo 0)，去重后条数: $(wc -l < "$raw_db")"

# 4. 字典匹配与模板填充
echo "--- Step 3: 极速匹配与体检 ---"
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 预处理字典
NAME_DICT=$(tr -d '\r' < "$LIST_DIR/name.txt" | awk -F'|' '{
    line = ""
    for(i=1; i<=NF; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i); 
        if($i == "") continue;
        tmp = $i;
        gsub(/[+().^$*?]/, "\\\\&", tmp); 
        line = (line == "" ? tmp : line "|" tmp)
    }
    print line
}')

while IFS= read -r t_line || [ -n "$t_line" ]; do
    [[ -z "$t_line" || "$t_line" =~ ^#EXTM3U ]] && continue
    
    if [[ "$t_line" == "#EXTINF"* ]]; then
        t_name=$(echo "$t_line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        [ -z "$t_name" ] && t_name=$(echo "$t_line" | sed 's/.*,//')

        search_regex_part=$(echo "$NAME_DICT" | grep -Ei "(^|\|)$t_name(\||$)" | head -n 1)
        [ -z "$search_regex_part" ] && tmp_n=$(echo "$t_name" | sed 's/[+().^$*?]/\\&/g') && search_regex="^($tmp_n)," || search_regex="^($search_regex_part),"

        matched_sources=$(grep -Ei "$search_regex" "$raw_db")

        if [ -n "$matched_sources" ]; then
            echo "$matched_sources" | while IFS=',' read -r f_name f_url; do
                [ -z "$f_url" ] && continue
                
                # 写入汇总
                echo "$t_line" >> "$all_m3u"
                echo "$f_url" >> "$all_m3u"

                # 存活检测 (Step 3 现在只需要处理不重复的 URL，速度大增)
                is_valid=0
                if [[ "$f_url" == *".cc.cd"* ]] || [[ "$f_url" == *"onrender.com"* ]] || [[ "$f_url" == *"iill.top"* ]]; then
                    is_valid=1
                else
                    if curl -I -L -k -s -m 2 -o /dev/null -f "$f_url"; then
                        is_valid=1
                    fi
                fi

                if [ "$is_valid" -eq 1 ]; then
                    echo "$t_line" >> "$final_live"
                    echo "$f_url" >> "$final_live"
                fi
            done
        fi
    fi
done < "$LIST_DIR/extinf.m3u"

echo "--- 任务结束 ---"
