#!/bin/bash

# 1. 环境初始化
# 进入仓库根目录（假设脚本在 list 文件夹内，先退回根目录）
cd "$(dirname "$0")/.."
WORKDIR=$(pwd)

# 每次运行清除 down 目录并确保必要目录存在
rm -rf "$WORKDIR/down"/*
mkdir -p "$WORKDIR/down" "$WORKDIR/files"

# 2. 下载原始源至 files 目录
echo "开始下载原始源..."
while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    # 获取文件名
    filename=$(basename "$url" | cut -d? -f1)
    echo "正在下载: $url"
    curl -L -s --connect-timeout 10 "$url" -o "$WORKDIR/files/$filename"
done < "$WORKDIR/list/down.txt"

# 3. 预处理：将所有源统一转为 M3U 并规范化格式
temp_all="$WORKDIR/down/all_raw.m3u"
touch "$temp_all"

echo "正在预处理直播源格式..."
for file in "$WORKDIR/files"/*; do
    [ -e "$file" ] || continue
    filename=$(basename "$file")
    
    if [[ "$filename" == *.txt ]]; then
        # 处理 TXT 格式 (Name,URL)
        sed -i 's/\r//' "$file"
        awk -F',' '{print "#EXTINF:-1 tvg-name=\""$1"\","$1"\n"$2}' "$file" >> "$temp_all"
    else
        # 处理 M3U 格式
        cat "$file" >> "$temp_all"
    fi
done

# 4. 核心逻辑：规范化 tvg-name 引号
# 匹配规则：补全未加引号或引号不全的情况
# 识别后边跟 tvg- 或 , 的边界
sed -i 's/tvg-name=\([^" ,]*\)\([, ]\)/tvg-name="\1"\2/g' "$temp_all"
sed -i 's/tvg-name="\([^" ,]*\)\([, ]\)/tvg-name="\1"\2/g' "$temp_all"

# 5. 字典匹配与替换逻辑 (Gather.m3u 处理原则)
echo "执行过滤与替换规则..."

# 排除特定关键字
sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$temp_all"

# 特定前缀替换
sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$temp_all"
sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$temp_all"
sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$temp_all"

# 6. 生成 all.m3u (仅限 HTTPS 且去重)
# 使用 awk 处理字典匹配 (name.txt 格式: 原始名,统一名)
awk -F',' 'NR==FNR{dict[$1]=$2; next} 
{
    if($0 ~ /#EXTINF/){
        match($0, /tvg-name="([^"]+)"/, m);
        orig_name = m[1];
        # 如果字典里有，则替换
        if(orig_name in dict){
            sub(/tvg-name="[^"]+"/, "tvg-name=\""dict[orig_name]"\"", $0);
        }
        info = $0;
        getline url;
        # 仅保留 https
        if(url ~ /^https:\/\//){
            # 以名称为 key 存入，实现简单的去重（保留最后一个发现的源）
            res[orig_name] = info "\n" url;
        }
    }
} 
END {
    for(i in res) print res[i]
}' "$WORKDIR/list/name.txt" "$temp_all" > "$WORKDIR/down/all.m3u"

# 7. 最终合成 live.m3u (基于 extinf.m3u 模板)
echo "正在检测直播源有效性并合成 live.m3u..."
final_file="$WORKDIR/live.m3u"
echo "#EXTM3U" > "$final_file"

# 提取 extinf.m3u 中的所有 tvg-name 顺序
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "#EXTINF"* ]]; then
        # 获取模板中的目标名称
        target_name=$(echo "$line" | grep -o 'tvg-name="[^"]*"' | cut -d'"' -f2)
        
        # 从 all.m3u 中查找该名称对应的 URL
        # 注意：这里查找的是经过字典统一后的名称
        stream_url=$(grep -A 1 "tvg-name=\"$target_name\"" "$WORKDIR/down/all.m3u" | grep "^https")
        
        if [ -n "$stream_url" ]; then
            # 校验有效性
            is_valid=0
            if [[ "$stream_url" == https://rtp.cc.cd* ]] || [[ "$stream_url" == https://melive.onrender.com* ]]; then
                is_valid=1
            else
                # 3秒快速检测，仅检查 Header
                if curl -I -s -m 3 -o /dev/null -f "$stream_url"; then
                    is_valid=1
                fi
            fi
            
            # 如果有效则写入
            if [ "$is_valid" -eq 1 ]; then
                echo "$line" >> "$final_file"
                echo "$stream_url" >> "$final_file"
            fi
        fi
    fi
done < "$WORKDIR/list/extinf.m3u"

# 清理临时产物
rm -f "$temp_all"
echo "任务完成！live.m3u 已生成。"
