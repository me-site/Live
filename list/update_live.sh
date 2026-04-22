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
    # 清理回车和前后空格
    line=$(echo "$line" | tr -d '\r' | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    # 拆分别名和 URL (支持 别名,URL 和 纯URL)
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
    
    # 增加 User-Agent 伪装，避免被 GitHub 或 Worker 拦截
    # 使用 -k 忽略证书错误，-L 跟踪重定向
    curl -L -k -s -f \
         -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
         --connect-timeout 20 "$url" -o "$FILES_DIR/$filename"
    
    if [ -s "$FILES_DIR/$filename" ]; then
        echo "   [成功] 文件大小: $(du -sh "$FILES_DIR/$filename" | cut -f1)"
    else
        echo "   [失败] 下载为空，请检查链接或网络！"
    fi
done < "$LIST_DIR/down.txt"

# 3. 提取并生成 raw_database.txt
echo "--- Step 2: 提取并清洗数据 ---"
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db"

for file in "$FILES_DIR"/*; do
    [ -s "$file" ] || continue
    work_file="${file}.process"
    tr -d '\r' < "$file" > "$work_file"

    # 执行你要求的 Gather.m3u 处理原则
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    # 兼容 M3U 和 TXT 的提取逻辑
    awk '
    BEGIN { IGNORECASE = 1 }
    /#EXTINF/ {
        name = "";
        if (match($0, /tvg-name="?([^",]*)"?/, a)) name = a[1];
        else if (match($0, /,(.*)$/, b)) name = b[1];
        gsub(/^[ \t]+|[ \t]+$/, "", name);
        while (getline url > 0) {
            gsub(/^[ \t]+|[ \t]+$/, "", url);
            if (url ~ /^https:\/\//) {
                if (name != "") print name "," url;
                break;
            }
            if (url ~ /^#EXTINF/) break; 
        }
    }
    !/#EXTINF/ && /https:\/\// && /,/ {
        split($0, p, ",");
        n=p[1]; u=p[2];
        gsub(/^[ \t]+|[ \t]+$/, "", n);
        gsub(/^[ \t]+|[ \t]+$/, "", u);
        if (u ~ /^https:\/\//) print n "," u;
    }
    ' "$work_file" >> "$raw_db"
    rm "$work_file"
done

# 4. 字典匹配逻辑 (保持你的多源要求)
echo "--- Step 3: 根据模板生成 live.m3u ---"
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

while IFS= read -r t_line || [ -n "$t_line" ]; do
    if [[ "$t_line" == "#EXTINF"* ]]; then
        t_name=$(echo "$t_line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 在 name.txt 找别名
        alias_line=$(grep -Ei "(^|\|)$t_name(\||$)" "$LIST_DIR/name.txt" | tr -d '\r')
        
        if [ -z "$alias_line" ]; then
            search_regex="^$t_name,"
        else
            # 对名称里的特殊字符转义
            regex_safe=$(echo "$alias_line" | sed 's/[][()\-+.^$*]/\\&/g')
            search_regex="^($regex_safe),"
        fi

        # 在数据库里找所有符合别名的源
        grep -Ei "$search_regex" "$raw_db" | cut -d',' -f2- | while read -r stream_url; do
            [ -z "$stream_url" ] && continue
            
            echo "$t_line" >> "$all_m3u"
            echo "$stream_url" >> "$all_m3u"

            # 免检与存活检测
            is_valid=0
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                is_valid=1
            else
                if curl -I -L -k -s -m 3 -o /dev/null -f "$stream_url"; then
                    is_valid=1
                fi
            fi

            if [ "$is_valid" -eq 1 ]; then
                echo "$t_line" >> "$final_live"
                echo "$stream_url" >> "$final_live"
            fi
        done
    fi
done < "$LIST_DIR/extinf.m3u"

echo "脚本运行结束。"
