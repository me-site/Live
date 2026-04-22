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

# 4. 字典匹配与模板填充 (极速版)
echo "--- Step 3: 极速匹配与模板拼合 ---"
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 预处理字典：清理空格和换行，存入内存（变量）
NAME_DICT=$(tr -d '\r' < "$LIST_DIR/name.txt" | sed 's/[ \t]*|[ \t]*/|/g')

while IFS= read -r t_line || [ -n "$t_line" ]; do
    [[ -z "$t_line" || "$t_line" =~ ^#EXTM3U ]] && continue
    
    if [[ "$t_line" == "#EXTINF"* ]]; then
        # 1. 快速提取 tvg-name
        t_name=$(echo "$t_line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        [ -z "$t_name" ] && t_name=$(echo "$t_line" | sed 's/.*,//')

        # 2. 从内存变量中快速定位别名行
        # 逻辑：找到包含 |t_name| 的行，提取整行别名
        alias_line=$(echo "$NAME_DICT" | grep -Ei "(^|\|)$t_name(\||$)" | head -n 1)
        
        if [ -z "$alias_line" ]; then
            # 没字典则只搜自己
            search_regex="^$t_name,"
        else
            # 将 别名1|别名2 转换为正则: ^(别名1|别名2),
            # 这里一次性处理，大幅减少循环次数
            regex_safe=$(echo "$alias_line" | sed 's/[][()\-+.^$*]/\\&/g')
            search_regex="^($regex_safe),"
        fi

        # 3. 一次性从 raw_db 捞出该频道的所有 URL
        # grep -Ei 的速度极快，远超逐行判断
        matched_sources=$(grep -Ei "$search_regex" "$raw_db")

        if [ -n "$matched_sources" ]; then
            echo "$matched_sources" | while IFS=',' read -r f_name f_url; do
                [ -z "$f_url" ] && continue
                
                # 写入汇总 (无需检测，极快)
                echo "$t_line" >> "$all_m3u"
                echo "$f_url" >> "$all_m3u"

                # 4. 存活检测 (这是最耗时的部分)
                # 免检名单加速
                if [[ "$f_url" == https://rtp.cc.cd* ]] || [[ "$f_url" == https://melive.onrender.com* ]]; then
                    echo "$t_line" >> "$final_live"
                    echo "$f_url" >> "$final_live"
                else
                    # 存活检测
                    if curl -I -L -k -s -m 2 -o /dev/null -f "$f_url"; then
                        echo "$t_line" >> "$final_live"
                        echo "$f_url" >> "$final_live"
                    fi
                fi
            done
        fi
    fi
done < "$LIST_DIR/extinf.m3u"

echo "--- 极速更新完成 ---"
