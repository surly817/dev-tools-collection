#!/bin/bash

# 脚本名称: enhanced_batch_rename_files.sh
# 作者: surly
# 版本: 1.9
# 创建日期: 2024-03-21st
# 最后修改日期: 2024-03-26th
# 描述: 该脚本用于批量修改当前路径下文件名，删除指定字符串并在末尾加上递增数字以避免重名,支持历史查看、回退功能，执行完成将在本地存储log文件用以记录及恢复。

LOG_FILE="batch_rename_files.log"
current_path=$(pwd)
script_name=$(basename "$0")
time_stamp=$(date '+%Y-%m-%d %H:%M:%S')

# 输出颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# 将日志记录和回退标识加入分隔符中，方便识别
SEPARATOR="========================================"

# 函数：输出红色信息
print_red() {
  echo "${RED}$1${RESET}"
}

# 函数：输出黄色信息
print_yellow() {
  echo "${YELLOW}$1${RESET}"
}

# 函数：输出绿色信息
print_green() {
  echo "${GREEN}$1${RESET}"
}

# 记录每次文件改名
log_rename() {
    echo "改名: $1 -> $2" >> "$current_path/$LOG_FILE"
    print_green "已改名: $1 -> $2"
}

# 检查并处理上一次的运行
handle_previous_run() {
    if [ -f "$current_path/$LOG_FILE" ]; then
        # 检查上一次执行是否有进行改名操作
        local last_changes=$(grep "改名:" "$current_path/$LOG_FILE" | tail -n 1)

        if [ -z "$last_changes" ]; then
            # 如果上一次执行没有进行任何改名操作
            print_yellow "注意: 这不是脚本的首次执行，但上次执行未做任何修改。"
        else
            # 如果上一次执行进行了改名操作
            print_yellow "注意: 这不是脚本的首次执行。"
            read -p "是否查看上次的执行记录? (y/n): " view_log
            if [[ $view_log =~ ^[Yy]$ ]]; then
                show_last_record
                # 只有在用户选择查看上次执行记录后，才询问是否需要回退
                read -p "是否需要回退到上次的状态? (y/n): " revert
                if [[ $revert =~ ^[Yy]$ ]]; then
                    revert_changes
                fi
            fi
        fi
    fi
}

# 回退到上一次的状态
revert_changes() {
    print_yellow "回退到上一次的状态..."
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < "$current_path/$LOG_FILE"

    local len=${#lines[@]}
    local change_made=false

    for ((i=len-1; i>=0; i--)); do
        if [[ "${lines[i]}" == *"$SEPARATOR"* ]]; then
            if [ "$change_made" = true ]; then
                break
            fi
        elif [[ "${lines[i]}" == 改名:* ]]; then
            change_made=true
            original_name=$(echo "${lines[i]}" | awk -F ' -> ' '{print $2}')
            new_name=$(echo "${lines[i]}" | awk -F ' -> ' '{print $1}' | sed 's/改名: //')
            if [ -f "$current_path/$original_name" ]; then
                mv "$current_path/$original_name" "$current_path/$new_name"
                print_green "已回退: $original_name -> $new_name"
            else
                print_red "文件 $original_name 不存在，跳过回退。"
            fi
        fi
    done

    if [ "$change_made" = false ]; then
        print_yellow "上一次执行没有进行任何改名操作。"
    fi
}

# 显示上一次实际进行了修改的执行记录
show_last_record() {
    print_yellow "上次执行的记录："
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < "$current_path/$LOG_FILE"

    local len=${#lines[@]}
    local found_change=false
    local record=()

    # 从日志的最后一行开始向上遍历，寻找包含实际修改操作的记录
    for ((i=len-1; i>=0; i--)); do
        if [[ "${lines[i]}" == *"$SEPARATOR"* ]]; then
            if [ "$found_change" = true ]; then
                printf '%s\n' "${record[@]}" | awk '{line[NR]=$0} END {for(i=NR;i>0;i--) print line[i]}'
                return
            else
                record=()  # 重置记录，继续向上寻找包含修改操作的记录
            fi
        elif [[ "${lines[i]}" == 改名:* ]]; then
            found_change=true  # 找到改名操作，标记为找到修改
            record+=("${lines[i]}")
        elif [ "$found_change" = true ]; then
            record+=("${lines[i]}")
        fi
    done

    # 如果未找到包含实际修改操作的记录，显示提示信息
    if [ "$found_change" = false ]; then
        print_yellow "上一次执行没有进行任何改名操作。"
    fi
}

# 开始日志记录
start_logging() {
    echo "$SEPARATOR" >> "$current_path/$LOG_FILE"
    echo "执行时间: $time_stamp" >> "$current_path/$LOG_FILE"
    print_green "脚本开始执行"
}

# 执行文件重命名
perform_renaming() {
    local start_time=$(date +%s)
    local found=false

    read -p "请输入需要删除的字符串: " remove_string
    if [ -z "$remove_string" ]; then
        print_red "输入为空，脚本退出。"
        return
    fi

    print_yellow "以下文件将被重命名："
    for file in "$current_path"/*; do
        if [ -f "$file" ] && [ "$(basename "$file")" != "$script_name" ] && [ "$(basename "$file")" != "$LOG_FILE" ]; then
            local filename=$(basename "$file")
            if [[ "$filename" == *"$remove_string"* ]]; then
                found=true
                local new_filename="${filename//$remove_string/}"
                print_yellow "准备改名: $filename -> $new_filename"
            fi
        fi
    done

    if [ "$found" == false ]; then
        print_red "未发现包含 '$remove_string' 的文件。"
        return
    fi

    read -p "确认改名所有上述文件？(y/n): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_yellow "用户取消操作。"
        return
    fi

    print_green "开始重命名文件..."
    for file in "$current_path"/*; do
        if [ -f "$file" ] && [ "$(basename "$file")" != "$script_name" ] && [ "$(basename "$file")" != "$LOG_FILE" ]; then
            local filename=$(basename "$file")
            if [[ "$filename" == *"$remove_string"* ]]; then
                local new_filename="${filename//$remove_string/}"
                mv "$file" "$current_path/$new_filename"
                if [ $? -eq 0 ]; then
                    log_rename "$filename" "$new_filename"
                else
                    print_red "改名失败: $filename"
                fi
            fi
        fi
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    print_green "脚本执行耗时: $duration 秒"
}

# 结束日志记录
end_logging() {
    local end_script_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo "脚本结束时间: $end_script_time" >> "$current_path/$LOG_FILE"
    print_green "脚本结束时间: $end_script_time"
    
    local start_seconds=$(date -j -f '%Y-%m-%d %H:%M:%S' "$time_stamp" +%s 2>/dev/null || date --date="$time_stamp" +%s)
    local end_seconds=$(date -j -f '%Y-%m-%d %H:%M:%S' "$end_script_time" +%s 2>/dev/null || date --date="$end_script_time" +%s)
    
    # 计算脚本执行耗时
    local duration=$((end_seconds - start_seconds))
    echo "脚本总执行耗时: $duration 秒" >> "$current_path/$LOG_FILE"
    print_green "脚本总执行耗时: $duration 秒"
    
    echo "$SEPARATOR" >> "$current_path/$LOG_FILE"
}

# 主函数
main() {
    # 检查并处理日志文件和上次执行
    handle_previous_run

    # 记录脚本开始执行
    start_logging

    # 执行文件重命名操作
    perform_renaming

    # 结束日志记录
    end_logging
}

main "$@"
