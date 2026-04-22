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

# 4. 字典匹配与模板填充
echo "--- Step 3: 字典精准匹配与模板拼合 ---"
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 确保字典文件没有 Windows 换行符
sed -i 's/\r//g' "$LIST_DIR/name.txt"

while IFS= read -r t_line || [ -n "$t_line" ]; do
    # 跳过空行和 M3U 头部
    [[ -z "$t_line" || "$t_line" =~ ^#EXTM3U ]] && continue
    
    if [[ "$t_line" == "#EXTINF"* ]]; then
        # 1. 提取模板中的标准 ID (tvg-name)
        t_name=$(echo "$t_line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 2. 在 name.txt 中找到包含该 ID 的那一行
        # 使用 grep -Ei 确保不区分大小写，并匹配由 | 分隔的独立项
        alias_line=$(grep -Ei "(^|\|)$t_name(\||$)" "$LIST_DIR/name.txt" | head -n 1)
        
        if [ -z "$alias_line" ]; then
            # 字典没找到，保底方案：只搜 tvg-name 自己
            search_list="$t_name"
        else
            # 将别名行按 | 拆分，并清理每一项前后的空格
            search_list=$(echo "$alias_line" | tr '|' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$')
        fi

        # 3. 遍历每一个别名，去 raw_db 里捞源
        # 这里的关键是使用 Fgrep 或精准正则，避免 + - ( ) 干扰
        while read -r single_alias; do
            [ -z "$single_alias" ] && continue
            
            # 使用 awk 的精准匹配功能（比 grep 更适合处理带符号的字符串）
            # 只有当 raw_db 的第一列完全等于别名时才输出
            awk -v alias="$single_alias" -F',' '
                tolower($1) == tolower(alias) { print $0 }
            ' "$raw_db" | while IFS=',' read -r f_name f_url; do
                [ -z "$f_url" ] && continue
                
                # 写入汇总文件 all.m3u
                echo "$t_line" >> "$all_m3u"
                echo "$f_url" >> "$all_m3u"
                echo "   [匹配成功] 模板:$t_name <- 匹配到别名:$single_alias (原始名:$f_name)"

                # 4. 校验有效性并写入 live.m3u
                is_valid=0
                if [[ "$f_url" == https://rtp.cc.cd* ]] || [[ "$f_url" == https://melive.onrender.com* ]]; then
                    is_valid=1
                else
                    # 增加 -L (重定向) 和 -k (忽略证书)
                    if curl -I -L -k -s -m 3 -o /dev/null -f "$f_url"; then
                        is_valid=1
                    fi
                fi

                if [ "$is_valid" -eq 1 ]; then
                    echo "$t_line" >> "$final_live"
                    echo "$f_url" >> "$final_live"
                fi
            done
        done <<< "$search_list"
    fi
done < "$LIST_DIR/extinf.m3u"

echo "--- 脚本运行结束 ---"
