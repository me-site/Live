#!/bin/bash

# 1. 环境初始化
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)
LIST_DIR="$WORKDIR/list"
FILES_DIR="$WORKDIR/files"
DOWN_DIR="$WORKDIR/down"

# 每次运行第1部：清除 down 目录
rm -rf "$DOWN_DIR"/*
mkdir -p "$DOWN_DIR" "$FILES_DIR"

# 2. 下载原始源 (按照 down.txt 顺序)
echo "Step 1: Downloading sources..."
while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    # 下载没有任何改变的直播源到 files
    curl -L -s --connect-timeout 10 "$url" -o "$FILES_DIR/$filename"
done < "$LIST_DIR/down.txt"

# 3. 预处理与格式化为 TXT
echo "Step 2: Pre-processing and formatting to TXT..."
# 准备一个汇总的数据库文件 (Name,URL 格式)
raw_db="$DOWN_DIR/raw_database.txt"
touch "$raw_db"

while IFS= read -r url || [ -n "$url" ]; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    filename=$(basename "$url" | cut -d? -f1)
    filepath="$FILES_DIR/$filename"
    work_file="$DOWN_DIR/$filename.tmp"
    cp "$filepath" "$work_file"

    # 执行 Gather.m3u 处理原则
    sed -i 's/\r//' "$work_file"
    sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$work_file"
    sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$work_file"
    sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$work_file"
    sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$work_file"

    # 提取信息并转换为 CCTV1,URL 形式
    # 兼容 M3U 和 TXT 原始格式
    if grep -q "#EXTINF" "$work_file"; then
        # 从 M3U 提取：先拿 tvg-name，没有再拿逗号后的名称
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
            getline url;
            if (url ~ /^https:\/\//) {
                print name "," url;
            }
        }' "$work_file" >> "$raw_db"
    else
        # 已经是 TXT 格式的，直接过滤掉 http 并规范化
        grep "," "$work_file" | grep "https://" >> "$raw_db"
    fi
    rm "$work_file"
done < "$LIST_DIR/down.txt"

# 4. 生成 all.m3u (字典匹配与去重)
echo "Step 3: Matching dictionary and creating all.m3u..."
# name.txt 格式: 源名称|统一名称
awk -F'|' 'NR==FNR{dict[$1]=$2; next} 
{
    split($0, a, ",");
    name=a[1]; url=a[2];
    if (name in dict) name=dict[name];
    # 存入数组去重，保留最后出现的源
    res[name] = url;
}' "$LIST_DIR/name.txt" "$raw_db" | awk -F' ' '{
    # 此处逻辑在下一步最终拼合
}' # 只是说明，实际逻辑在下面

# 5. 最终合成 live.m3u 并检测有效性
echo "Step 4: Final assembly and health check..."
echo "#EXTM3U" > "$WORKDIR/live.m3u"
all_m3u="$DOWN_DIR/all.m3u"
echo "#EXTM3U" > "$all_m3u"

# 为了提高效率，将处理好的 raw_db 加载进内存
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "#EXTINF"* ]]; then
        # 1. 取模板中的 tvg-name
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 2. 在 raw_db 中寻找匹配源 (需通过字典映射查找)
        # 我们查找：哪个原始名映射到了 target_name，或者原始名本身就是 target_name
        stream_url=$(awk -F'|' -v t_name="$target_name" '
            NR==FNR { if($2==t_name) mapped[$1]=1; next }
            {
                split($0, a, ",");
                if (a[1] == t_name || mapped[a[1]] == 1) {
                    print a[2];
                    exit;
                }
            }' "$LIST_DIR/name.txt" "$raw_db")

        if [ -n "$stream_url" ]; then
            # 3. 写入 all.m3u (不检测)
            echo "$line" >> "$all_m3u"
            echo "$stream_url" >> "$all_m3u"

            # 4. 检测有效性后写入根目录 live.m3u
            is_valid=0
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                is_valid=1
            else
                # 3秒快速检测响应头
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

echo "Job Finished."
