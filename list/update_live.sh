#!/bin/bash
set -e

# 基础路径
BASE="${GITHUB_WORKSPACE:-$(pwd)}"
LIST_DIR="$BASE/list"
FILES_DIR="$BASE_DIR/files"
DOWN_DIR="$BASE/down"

# 配置文件
DOWN_LIST="$LIST_DIR/down.txt"
EXTINF_TEMPLATE="$LIST_DIR/extinf.m3u"
NAME_DICT="$LIST_DIR/name.txt"

# 结果文件
ALL_M3U="$DOWN_DIR/all.m3u"
LIVE_M3U="$BASE/live.m3u"

# 初始化环境
mkdir -p "$FILES_DIR" "$DOWN_DIR"
rm -rf "$DOWN_DIR"/*
echo "===== 环境初始化完成 ====="

# 1. 下载源文件
declare -A seen
while IFS=',' read -r name url || [ -n "$name" ]; do
    [[ -z "$url" || "$name" == "#"* ]] && continue
    hash=$(echo "$url" | md5sum | cut -d' ' -f1)
    if [[ -z "${seen[$hash]}" ]]; then
        seen[$hash]=1
        echo "正在下载: $name"
        curl -L -k -s --max-time 20 --retry 2 "$url" -o "$FILES_DIR/$hash.txt" || true
    fi
done < "$DOWN_LIST"

# 2. 清洗并标准化所有源到 pool.m3u
POOL="$DOWN_DIR/pool.m3u"
> "$POOL"

for file in "$FILES_DIR"/*; do
    [ -e "$file" ] || continue
    # 统一处理：如果是 TXT 格式则简单封装
    # 强力纠正引号：确保 tvg-name="内容" 格式
    sed -i -E 's/tvg-name=([^" ,]+)/tvg-name="\1"/g' "$file"
    
    cat "$file" >> "$POOL"
done

# 3. 关键字过滤与 Gather 代理替换
echo "===== 执行 Gather 替换与关键字过滤 ====="
# 删除包含关键字的行及其下一行
sed -i '/#EXTINF.*\(电台\|精選\|游戏\|广播\)/{N;d;}' "$POOL"
# Gather 替换
sed -i 's@https://v\.iill\.top/tw/@https://rtp.cc.cd/play.php?url=https://v.iill.top/tw/@g' "$POOL"
sed -i 's@https://v\.iill\.top/4gtv/@https://rtp.cc.cd/play.php?url=https://v.iill.top/4gtv/@g' "$POOL"
sed -i 's@https://tv\.iill\.top/ofiii/@https://rtp.cc.cd/play.php?url=https://tv.iill.top/ofiii/@g' "$POOL"
# 删除所有 http 源
sed -i '/^http:\/\/.*$/d' "$POOL"

# 4. 构建字典映射并规范化 POOL 中的名称
echo "===== 规范化频道名称 ====="
while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS='|' read -ra arr <<< "$line"
    main=$(echo "${arr[0]}" | xargs)
    for alias in "${arr[@]}"; do
        alias_clean=$(echo "$alias" | xargs)
        [ -z "$alias_clean" ] && continue
        # 将所有别名统一替换为标准名，注意保留双引号
        sed -i "s/tvg-name=\"$alias_clean\"/tvg-name=\"$main\"/g" "$POOL"
    done
done < "$NAME_DICT"

# 5. 按照模板 extinf.m3u 的顺序提取源
echo "===== 按照模板填充 all.m3u ====="
echo "#EXTM3U" > "$ALL_M3U"
# 预提取 pool 里的所有 URL 对应关系
TEMP_SORTED="$DOWN_DIR/pool_sorted.tmp"
grep "#EXTINF" -A 1 "$POOL" | grep -v "\-\-" > "$TEMP_SORTED"

while read -r tpl_line || [ -n "$tpl_line" ]; do
    [[ ! "$tpl_line" =~ "#EXTINF" ]] && continue
    # 提取模板里的标准 tvg-name
    t_name=$(echo "$tpl_line" | sed -n 's/.*tvg-name="\([^"]*\)".*/\1/p')
    [ -z "$t_name" ] && continue

    # 从 pool 中找出所有匹配该名称的 URL
    # 使用 fgrep 确保精确匹配
    grep -F "tvg-name=\"$t_name\"" -A 1 "$TEMP_SORTED" | grep "^https" | awk '!seen[$0]++' | while read -r match_url; do
        # 写入时务必给 $tpl_line 加引号，防止丢失引号
        echo "$tpl_line" >> "$ALL_M3U"
        echo "$match_url" >> "$ALL_M3U"
    done
done < "$EXTINF_TEMPLATE"

# 6. 并发测活并生成 live.m3u
echo "===== 执行并发测活 ====="
# 准备带索引的任务文件，防止并发导致顺序错乱
TASK_FILE="$DOWN_DIR/tasks.tmp"
> "$TASK_FILE"
t_idx=100000
while read -r line; do
    if [[ "$line" =~ "#EXTINF" ]]; then
        info="$line"
        read -r url
        echo "$t_idx|$info|$url" >> "$TASK_FILE"
        ((t_idx++))
    fi
done < "$ALL_M3U"

export CLEAN_POOL="$DOWN_DIR/clean_pool.tmp"
> "$CLEAN_POOL"

check_url() {
    local row="$1"
    local idx=$(echo "$row" | cut -d'|' -f1)
    local inf=$(echo "$row" | cut -d'|' -f2)
    local url=$(echo "$row" | cut -d'|' -f3)

    if [[ "$url" == *"rtp.cc.cd"* || "$url" == *"melive.onrender.com"* ]]; then
        echo "$idx|$inf|$url" >> "$CLEAN_POOL"
    else
        # 探测头信息，判断是否 200/206
        code=$(curl -sL -k -I --connect-timeout 3 "$url" 2>/dev/null | awk 'NR==1{print $2}')
        if [[ "$code" =~ ^(200|206|301|302)$ ]]; then
            echo "$idx|$inf|$url" >> "$CLEAN_POOL"
        fi
    fi
}
export -f check_url

# 使用 xargs 或 parallel 运行测活
cat "$TASK_FILE" | xargs -P 20 -I {} bash -c 'check_url "{}"'

# 7. 汇总最终结果
echo "#EXTM3U" > "$LIVE_M3U"
sort -n "$CLEAN_POOL" | while IFS='|' read -r o_idx o_inf o_url; do
    echo "$o_inf" >> "$LIVE_M3U"
    echo "$o_url" >> "$LIVE_M3U"
done

echo "===== 任务完成！ ====="
echo "最终频道数: $(grep -c "#EXTINF" "$LIVE_M3U")"
