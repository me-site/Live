#!/bin/bash

# 1. 路径初始化
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 运行第1步：强制清理并重建目录
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

echo "--- 调试信息：当前目录结构 ---"
ls -R "$LIST_DIR"

# 2. 下载原始源
echo "--- Step 1: 开始下载源文件 ---"
count=0
while IFS= read -r url || [ -n "$url" ]; do
    # 移除 URL 中的回车符并跳过空行/注释
    url=$(echo "$url" | tr -d '\r' | xargs)
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    
    count=$((count+1))
    filename="source_${count}.tmp"
    echo "正在下载 [${count}]: $url"
    
    # 增加 -f 报错开关，确保下载失败时有记录
    curl -L -s -f --connect-timeout 15 "$url" -o "$FILES_DIR/$filename"
    
    if [ ! -s "$FILES_DIR/$filename" ]; then
        echo "警告：文件 $filename 下载为空，请检查 URL 有效性。"
    fi
done < "$LIST_DIR/down.txt"

# 3. 预处理并写入 raw_database.txt
echo "--- Step 2: 提取信息并生成 raw_database.txt ---"
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db"

for filepath in "$FILES_DIR"/*; do
    [ -e "$filepath" ] || continue
    
    # 清理换行符并预处理
    work_file="${filepath}.process"
    tr -d '\r' < "$filepath" > "$work_file"

    # 执行 Gather.m3u 替换原则
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    # 核心提取逻辑：兼容各种不规范的 tvg-name 标签
    awk '
    BEGIN { IGNORECASE = 1 }
    # 匹配 M3U 格式
    /#EXTINF/ {
        line = $0;
        name = "";
        # 1. 尝试匹配 tvg-name="内容" 或 tvg-name=内容
        if (match(line, /tvg-name="?([^",]*)"?/, arr)) {
            name = arr[1];
        } 
        # 2. 如果没匹配到，取最后一个逗号后的内容
        if (name == "") {
            if (match(line, /,[ \t]*([^,]+)$/, arr)) {
                name = arr[1];
            }
        }
        gsub(/^[ \t]+|[ \t]+$/, "", name); # 去除前后空格
        
        getline url;
        url = xargs(url); # 清理 URL 空格
        if (url ~ /^https:\/\//) {
            print name "," url;
        }
    }
    # 匹配 TXT 格式 (名称,https://...)
    !/#EXTINF/ && /,https:\/\// {
        split($0, parts, ",");
        name = parts[1];
        url = parts[2];
        gsub(/^[ \t]+|[ \t]+$/, "", name);
        gsub(/^[ \t]+|[ \t]+$/, "", url);
        if (url ~ /^https:\/\//) {
            print name "," url;
        }
    }
    function xargs(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    ' "$work_file" >> "$raw_db"
    
    rm "$work_file"
done

# 关键性调试：检查数据库是否有内容
if [ ! -s "$raw_db" ]; then
    echo "!!! 错误：raw_database.txt 为空 !!!"
    echo "原因排查：1.源里全都是 http 而没有 https; 2.tvg-name 标签格式极其特殊; 3.down.txt 里的链接失效"
    exit 0
else
    echo "成功：提取到 $(wc -l < "$raw_db") 条直播源信息。"
fi

# 4. 后续拼合逻辑
echo "--- Step 3: 根据模板拼合最终文件 ---"
all_m3u="$DOWN_DIR/all.m3u"
final_live="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$all_m3u"
echo "#EXTM3U" > "$final_live"

# 预加载 name.txt 到内存提高匹配效率
while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    # 提取模板中的 tvg-name
    if [[ "$line" == "#EXTINF"* ]]; then
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 从字典找所有关联的备选名称
        # 正则：匹配行首、行中或行尾的 target_name，由 | 分隔
        aliases=$(grep -Ei "(^|\|)$target_name(\||$)" "$LIST_DIR/name.txt" | tr -d '\r')
        
        if [ -z "$aliases" ]; then
            # 如果字典没写，就搜自己
            search_regex="^$target_name,"
        else
            # 将 别名1|别名2 转换为 grep 正则 ^(别名1|别名2),
            search_regex="^($(echo "$aliases" | tr '|' '\n' | sed 's/[]\/$*.^|[]/\\&/g' | tr '\n' '|' | sed 's/|$//')),"
        fi

        # 在 raw_db 中查找所有匹配项
        grep -Ei "$search_regex" "$raw_db" | while IFS=',' read -r found_name stream_url; do
            [ -z "$stream_url" ] && continue
            
            # 写入汇总 all.m3u
            echo "$line" >> "$all_m3u"
            echo "$stream_url" >> "$all_m3u"

            # 校验并写入 live.m3u
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                echo "$line" >> "$final_live"
                echo "$stream_url" >> "$final_live"
            else
                # 只发 Head 请求检测，3秒超时
                if curl -I -s -m 3 -o /dev/null -f "$stream_url"; then
                    echo "$line" >> "$final_live"
                    echo "$stream_url" >> "$final_live"
                fi
            fi
        done
    fi
done < "$LIST_DIR/extinf.m3u"

echo "脚本执行完毕。"
