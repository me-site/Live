#!/bin/bash

# 1. 路径初始化
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 强制清理并重建目录
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 下载原始源
echo "--- Step 1: 下载源文件 (增加了30秒强制超时) ---"
idx=0
while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | tr -d '\r' | xargs)
    # 跳过空行和以 # 开头的注释行
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
    
    # 核心修改：增加了 --max-time 30，防止坏死链接卡住脚本
    curl -L -k -s -f \
         -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
         --connect-timeout 10 \
         --max-time 30 \
         "$url" -o "$FILES_DIR/$filename"
    
    if [ -s "$FILES_DIR/$filename" ]; then
        echo "   [成功] 文件大小: $(du -sh "$FILES_DIR/$filename" | cut -f1)"
    else
        echo "   [跳过] 下载失败或响应超时"
        rm -f "$FILES_DIR/$filename"
    fi
done < "$LIST_DIR/down.txt"

# 3. 提取、去重并生成 raw_database.txt
echo "--- Step 2: 提取数据并执行物理去重 ---"
raw_db_tmp="$DOWN_DIR/raw_database_tmp.txt"
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db_tmp"

for file in "$FILES_DIR"/*.tmp; do
    [ -s "$file" ] || continue
    work_file="${file}.process"
    
    iconv -t UTF-8//IGNORE "$file" > "$work_file" 2>/dev/null || cp "$file" "$work_file"
    tr -d '\r' < "$work_file" > "${work_file}.clean"
    
    sed -i '/\(电台\|精選\|游戏\|广播\)/d' "${work_file}.clean"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "${work_file}.clean"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "${work_file}.clean"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "${work_file}.clean"

    awk -F',' '
    BEGIN { IGNORECASE = 1 }
    /#EXTINF/ {
        name = "";
        if (match($0, /tvg-name="?([^",]*)"?/, a)) name = a[1];
        else if (match($0, /,(.*)$/, b)) name = b[1];
        gsub(/^[ \t]+|[ \t]+$/, "", name);
        while (getline url > 0) {
            gsub(/^[ \t]+|[ \t]+$/, "", url);
            if (url ~ /^https?:\/\//) { if (name != "") print name "," url; break; }
            if (url ~ /^#/) break; 
        }
        next;
    }
    /https?:\/\// {
        if (NF >= 2) {
            n=$1; u=$2; if (NF > 2) u=$(NF); 
            gsub(/^[ \t]+|[ \t]+$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", u);
            if (u ~ /^http/ && n !~ /^#/) print n "," u;
        }
    }
    ' "${work_file}.clean" >> "$raw_db_tmp"
    rm -f "$work_file" "${work_file}.clean"
done

awk -F',' '!seen[$2]++' "$raw_db_tmp" > "$raw_db"
echo "物理去重完成。有效行数: $(wc -l < "$raw_db")"

# 4. 字典匹配与模板填充
echo "--- Step 3: 开始匹配、体检与汇总 ---"
all_m3u="$WORKDIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

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
        [ -z "$t_name" ] && t_name=$(echo "$t_line" | sed 's/.*,//' | xargs)

        search_regex_part=$(echo "$NAME_DICT" | grep -Ei "(^|\|)$t_name(\||$)" | head -n 1)
        [ -z "$search_regex_part" ] && tmp_n=$(echo "$t_name" | sed 's/[+().^$*?]/\\&/g') && search_regex="^($tmp_n)," || search_regex="^($search_regex_part),"

        matched_sources=$(grep -Ei "$search_regex" "$raw_db")
        [ -z "$matched_sources" ] && matched_sources=$(grep -F "$t_name," "$raw_db" | head -n 5)

        if [ -n "$matched_sources" ]; then
            echo "$matched_sources" | while IFS=',' read -r f_name f_url; do
                [ -z "$f_url" ] && continue
                echo "$t_line" >> "$all_m3u"
                echo "$f_url" >> "$all_m3u"
                is_valid=0
                if [[ "$f_url" == *".cc.cd"* ]] || [[ "$f_url" == *"onrender.com"* ]] || [[ "$f_url" == *"iill.top"* ]]; then
                    is_valid=1
                else
                    if curl -I -L -k -s -m 2 -o /dev/null -f "$f_url"; then
                        is_valid=1
                    fi
                fi
                [ "$is_valid" -eq 1 ] && echo "$t_line" >> "$final_live" && echo "$f_url" >> "$final_live"
            done
        fi
    fi
done < "$LIST_DIR/extinf.m3u"

rm -f "$DOWN_DIR/raw_database_tmp.txt"
echo "--- 任务结束 ---"
