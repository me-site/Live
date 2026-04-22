#!/bin/bash

# 1. 初始化路径与清理
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 每次运行前清除 down 目录
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 按照 down.txt 顺序下载直播源
echo "Step 1: Downloading sources..."
while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    # 下载原始文件到 files
    curl -L -s --connect-timeout 10 "$url" -o "$FILES_DIR/$filename"
    # 拷贝到 down 进行后续处理
    cp "$FILES_DIR/$filename" "$DOWN_DIR/$filename"
done < "$LIST_DIR/down.txt"

# 3. 处理 down 目录下的文件
echo "Step 2: Processing files and fixing quotes..."
temp_all_raw="$DOWN_DIR/all_raw.tmp"
touch "$temp_all_raw"

while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    filepath="$DOWN_DIR/$filename"
    
    # A. 如果是 TXT 格式，处理成 M3U
    if [[ "$filename" == *.txt ]]; then
        sed -i 's/\r//' "$filepath"
        awk -F',' '{print "#EXTINF:-1 tvg-name=\""$1"\","$1"\n"$2}' "$filepath" > "${filepath}.m3u"
        rm "$filepath"
        filepath="${filepath}.m3u"
    fi

    # B. 补全 tvg-name 引号 (适配带空格名称)
    # 匹配规则：tvg-name= 后接可选的引号，直到遇到下一个 , 或 tvg- 开头
    # 使用 perl 正则处理更复杂的非贪婪匹配
    perl -pi -e 's/tvg-name="?([^",]*?)"?(?=\s|,|tvg-)/tvg-name="$1"/g' "$filepath"

    # C. 执行 Gather.m3u 替换原则
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$filepath"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$filepath"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$filepath"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$filepath"

    # D. 汇总
    cat "$filepath" >> "$temp_all_raw"
done < "$LIST_DIR/down.txt"

# 4. 字典匹配并生成 all.m3u (删除 http)
echo "Step 3: Matching dictionary (| separator) and generating all.m3u..."
# name.txt 格式：源名称|模板名称
awk -F'|' 'NR==FNR{dict[$1]=$2; next} 
{
    if($0 ~ /#EXTINF/){
        # 提取 tvg-name 内容
        match($0, /tvg-name="([^"]+)"/, m);
        name = m[1];
        
        # 匹配字典
        if(name in dict) {
            sub(/tvg-name="[^"]+"/, "tvg-name=\""dict[name]"\"", $0);
            name = dict[name];
        }
        
        info = $0;
        getline url;
        # 仅保留 HTTPS
        if(url ~ /^https:\/\//){
            res[name] = info "\n" url;
        }
    }
} 
END {
    for(i in res) print res[i]
}' "$LIST_DIR/name.txt" "$temp_all_raw" > "$DOWN_DIR/all.m3u"

# 5. 基于模板 extinf.m3u 最终生成 live.m3u
echo "Step 4: Verifying streams and building final live.m3u..."
echo "#EXTM3U" > "$WORKDIR/live.m3u"

while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "#EXTINF"* ]]; then
        # 获取模板要求的 tvg-name
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 从汇总库里找源
        stream_url=$(grep -A 1 "tvg-name=\"$target_name\"" "$DOWN_DIR/all.m3u" | grep "^https")
        
        if [ -n "$stream_url" ]; then
            is_valid=0
            # 免检清单
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                is_valid=1
            else
                # 连通性检查
                if curl -I -s -m 3 -o /dev/null -f "$stream_url"; then
                    is_valid=1
                fi
            fi
            
            if [ "$is_valid" -eq 1 ]; then
                echo "$line" >> "$WORKDIR/live.m3u"
                echo "$stream_url" >> "$WORKDIR/live.m3u"
            fi
        fi
    fi
done < "$LIST_DIR/extinf.m3u"

rm -f "$temp_all_raw"
echo "Process Finished Successfully."
