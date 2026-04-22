#!/bin/bash

# 1. 初始化环境：清除 down 目录
rm -rf down/*
mkdir -p down files

# 2. 读取 list/down.txt 下载直接源
# 假设 down.txt 格式为: http://example.com/source.txt 或 m3u
while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    filename=$(basename "$url")
    echo "Downloading: $url"
    curl -L -s "$url" -o "files/$filename"
done < list/down.txt

# 3. 处理文件并提取直播源到临时文件
temp_sources="down/all_temp.txt"
touch "$temp_sources"

while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    filename=$(basename "$url")
    filepath="files/$filename"
    
    # 如果是 TXT 格式 (CCTV1,url)，转换为简易 m3u 格式存入临时流库
    if [[ "$filename" == *.txt ]]; then
        sed -i 's/\r//' "$filepath"
        awk -F',' '{print "#EXTINF:-1," $1 "\n" $2}' "$filepath" >> "$temp_sources"
    else
        cat "$filepath" >> "$temp_sources"
    fi
done < list/down.txt

# 4. 规范化 tvg-name 标签
# 处理各种缺失引号的情况
sed -i 's/tvg-name="\?\([^" ,]*\)"\?/tvg-name="\1"/g' "$temp_sources"

# 5. 过滤与替换 (Gather.m3u 处理逻辑)
# 排除特定关键字
sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$temp_sources"
# 特定前缀替换
sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$temp_sources"
sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$temp_sources"
sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$temp_sources"

# 6. 生成 all.m3u (仅限 HTTPS)
# 逻辑：提取 temp 中的频道名和 URL，存入 key-value 结构
# 只保留 HTTPS，且根据 name.txt 字典进行标准化
awk '
    BEGIN {
        # 加载字典
        while ((getline < "list/name.txt") > 0) {
            split($0, a, ","); # 假设字典格式: 原始名,统一名
            dict[a[1]] = a[2];
        }
    }
    /#EXTINF/ {
        # 提取 tvg-name
        match($0, /tvg-name="([^"]+)"/, m);
        t_name = m[1];
        # 匹配字典
        if (t_name in dict) t_name = dict[t_name];
        
        getline url;
        if (url ~ /^https:\/\//) {
            links[t_name] = url;
        }
    }
    END {
        for (name in links) {
            print "#EXTINF:-1 tvg-name=\"" name "\"," name "\n" links[name] > "down/all.m3u"
        }
    }
' "$temp_sources"

# 7. 填充模板生成 live.m3u
# 读取 list/extinf.m3u，根据其中的 tvg-name 匹配 all.m3u 里的 URL
output="live.m3u"
echo "#EXTM3U" > "$output"

# 逐行读取模板
while IFS= read -r line; do
    if [[ "$line" == "#EXTINF"* ]]; then
        # 获取模板中的 tvg-name
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        # 从 all.m3u 中查找对应的 URL (确保 URL 经过了 HTTPS 过滤和替换)
        source_url=$(grep -A 1 "tvg-name=\"$target_name\"" down/all.m3u | grep "^https")
        
        if [ -z "$source_url" ]; then
            continue # 如果没找到源，则跳过该频道
        fi
        
        # 检查源有效性 (排除特定前缀)
        if [[ "$source_url" == https://rtp.cc.cd* ]] || [[ "$source_url" == https://melive.onrender.com* ]]; then
            is_valid=0
        else
            # 5秒超时检测
            curl -o /dev/null -s -m 5 -f "$source_url"
            is_valid=$?
        fi
        
        if [ $is_valid -eq 0 ]; then
            echo "$line" >> "$output"
            echo "$source_url" >> "$output"
        fi
    fi
done < list/extinf.m3u

# 清理临时文件
rm -f down/all_temp.txt
echo "Update Complete."
