#!/bin/bash
# 脚本名称: advanced_batch_rename_files.sh
# 作者: surly
# 版本: 2.1
# 创建日期: 2024-03-21st
# 最后修改日期: 2024-04-07th
# 描述: 本脚本用于批量重命名当前目录下的文件。支持删除特定字符串、添加内容、替换内容，并在必要时在文件名末尾添加递增数字以避免重复。脚本还支持查看历史记录、回滚更改，并将更改记录在本地日志文件中以供记录和恢复。
# Description: This script is used for batch renaming files in the current directory. It supports deleting specific strings, adding content, replacing content, and appending incremental numbers to avoid duplicates. It also supports viewing history, rollback, and logs changes locally for recording and recovery.

# 基础环境配置 Basic Environment Configuration
LOG_FILE="batch_rename_files.log"
current_path=$(pwd)
script_name=$(basename "$0")
time_stamp=$(date '+%Y-%m-%d %H:%M:%S')

# 输出颜色设置 Color Output Settings
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# 日志记录和回滚标识的分隔符 Separator for logs and rollback identification
SEPARATOR="========================================"

# 函数：不同颜色输出信息 Function to print messages in different colors
print_message() {
  case $1 in
    red) echo "${RED}$2${RESET}" ;;
    green) echo "${GREEN}$2${RESET}" ;;
    yellow) echo "${YELLOW}$2${RESET}" ;;
  esac
}

# 记录每次文件重命名 Log each file rename
log_rename() {
  echo "Renamed: $1 -> $2" >> "$current_path/$LOG_FILE"  # 记录日志 Log entry
  print_message green "Renamed: $1 -> $2"  # 打印信息 Print message
}

# 检查并处理上一次运行 Check and handle previous run
handle_previous_run() {
  if [ -f "$current_path/$LOG_FILE" ]; then
    local last_changes=$(grep "Renamed:" "$current_path/$LOG_FILE" | tail -n 1)
    if [ -z "$last_changes" ]; then
      print_message yellow "Note: This is not the first script execution, but no modifications were made last time."
      print_message yellow "注意: 这不是脚本的首次执行，但上次没有进行任何修改。"
    else
      print_message yellow "Note: This is not the first script execution."
      print_message yellow "注意: 这不是脚本的首次执行。"
      echo "Would you like to view the last execution log? (y/n): " 
      read -p "是否查看上次执行日志？(y/n): " view_log  # 添加中文提示 Add Chinese prompt
      if [[ $view_log =~ ^[Yy]$ ]]; then
        show_last_record
        echo "Would you like to revert to the previous state? (y/n): " 
        read -p "是否回滚到上一个状态？(y/n): " revert  # 添加中文提示 Add Chinese prompt
        if [[ $revert =~ ^[Yy]$ ]]; then
          revert_changes
        fi
      fi
    fi
  fi
}

# 回滚到上一次状态 Revert to the previous state
revert_changes() {
  print_message yellow "Reverting to the previous state..."
  print_message yellow "回滚到上一次状态..."
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
    elif [[ "${lines[i]}" == Renamed:* ]]; then
      change_made=true
      original_name=$(echo "${lines[i]}" | awk -F ' -> ' '{print $2}')
      new_name=$(echo "${lines[i]}" | awk -F ' -> ' '{print $1}' | sed 's/Renamed: //')
      if [ -f "$current_path/$original_name" ]; then
        mv "$current_path/$original_name" "$current_path/$new_name"
        print_message green "Reverted: $original_name -> $new_name"
        print_message green "已回滚: $original_name -> $new_name"
      else
        print_message red "File $original_name does not exist, skipping revert."
        print_message red "文件 $original_name 不存在，跳过回滚。"
      fi
    fi
  done
  if [ "$change_made" = false ]; then
    print_message yellow "No modifications were made in the last execution."
    print_message yellow "上次执行未进行任何修改。"
  fi
}

# 显示上次实际更改的记录 Show the last record of actual changes
show_last_record() {
  print_message yellow "Last execution record:"
  print_message yellow "上次执行记录："
  local temp_file=$(mktemp)  # 创建一个临时文件

  # 将逆序的日志内容写入临时文件
  tail -r "$current_path/$LOG_FILE" > "$temp_file"

  local found_change=false
  local record_started=false

  # 从临时文件读取行
  while IFS= read -r line; do
    if [[ "$line" == *"$SEPARATOR"* ]]; then
      if [ "$record_started" = true ]; then
        break  # 如果已经开始记录，并遇到了分隔符，则停止
      fi
    elif [[ "$line" == Renamed:* ]]; then
      found_change=true  # 找到了重命名记录
      record_started=true  # 开始记录
      echo "$line"  # 显示当前行
    elif [ "$found_change" = true ]; then
      echo "$line"  # 显示当前行
    fi
  done < "$temp_file"

  rm "$temp_file"  # 删除临时文件

  if [ "$found_change" = false ]; then
    print_message yellow "No modifications were made in the last execution."
    print_message yellow "上次执行未进行任何修改。"
  fi
}

# 开始日志记录 Start logging
start_logging() {
  echo "$SEPARATOR" >> "$current_path/$LOG_FILE"
  echo "Script Start Time: $time_stamp" >> "$current_path/$LOG_FILE"
  echo "脚本开始时间: $time_stamp" >> "$current_path/$LOG_FILE"
  print_message green "Script execution started"
  print_message green "脚本开始执行"
}

# 添加或替换字符串的函数 Function for adding or replacing a string
add_or_replace_string() {
  local operation=$1 # add 或 replace / add or replace
  local target_string
  local position
  local replace_string
  if [[ "$operation" == "replace" ]]; then
    echo "Enter the string to replace: " 
    read -p "请输入要替换的字符串: " target_string  # 添加中文提示 Add Chinese prompt
    echo "Enter the replacement string: " 
    read -p "请输入替换后的字符串: " replace_string  # 添加中文提示 Add Chinese prompt
  else
    echo "Enter the string to add: " 
    read -p "请输入要添加的字符串: " target_string  # 添加中文提示 Add Chinese prompt
  fi
  echo "Enter the position for addition/replacement (0 for beginning, -1 for end, any other number for a specific position): "
  read -p "请输入添加/替换的位置 (0代表开始处，-1代表末尾，其他数字代表具体位置): " position  # 添加中文提示 Add Chinese prompt
  local regex='^-?[0-9]+$'
  if ! [[ $position =~ $regex ]]; then
    print_message red "Position must be an integer."
    print_message red "位置必须是整数。"
    return
  fi
  for file in "$current_path"/*; do
    if [ -f "$file" ] && [ "$(basename "$file")" != "$script_name" ] && [ "$(basename "$file")" != "$LOG_FILE" ]; then
      local filename=$(basename "$file")
      local extension="${filename##*.}"
      local basename="${filename%.*}"
      local new_basename
      local new_filename
      if [[ "$operation" == "add" ]]; then
        if [[ $position -eq 0 ]]; then
          new_basename="$target_string$basename"
        elif [[ $position -eq -1 ]]; then
          new_basename="$basename$target_string"
        else
          local front="${basename:0:$position}"
          local back="${basename:$position}"
          new_basename="$front$target_string$back"
        fi
      elif [[ "$operation" == "replace" ]]; then
        new_basename="${basename//$target_string/$replace_string}"
      fi
      local counter=1
      new_filename="$new_basename.$extension"
      while [ -f "$current_path/$new_filename" ]; do
        new_filename="${new_basename}_$counter.$extension"
        ((counter++))
      done
      mv "$file" "$current_path/$new_filename"
      if [ $? -eq 0 ]; then
        log_rename "$filename" "$new_filename"
      else
        print_message red "Operation failed for: $filename"
        print_message red "操作失败: $filename"
      fi
    fi
  done
}

# 执行删除指定字符串的操作 Perform deletion of a specified string
perform_deletion() {
  echo "Enter the string to delete: "
  read -p "请输入要删除的字符串: " remove_string  # 添加中文提示 Add Chinese prompt
  if [ -z "$remove_string" ]; then
    print_message red "Input is empty, exiting script."
    print_message red "输入为空，脚本退出。"
    exit 1
  fi
  local found=false
  for file in "$current_path"/*; do
    if [ -f "$file" ] && [ "$(basename "$file")" != "$script_name" ] && [ "$(basename "$file")" != "$LOG_FILE" ]; then
      local filename=$(basename "$file")
      if [[ "$filename" == *"$remove_string"* ]]; then
        found=true
        local new_filename="${filename//$remove_string/}"
        local final_filename=$new_filename
        local counter=1
        while [ -f "$current_path/$final_filename" ]; do
          final_filename="${new_filename}_${counter}"
          ((counter++))
        done
        mv "$file" "$current_path/$final_filename"
        log_rename "$filename" "$final_filename"
      fi
    fi
  done
  if [ "$found" = false ]; then
    print_message yellow "No files found containing the specified string."
    print_message yellow "未找到包含指定字符串的文件。"
  fi
}

# 根据操作类型执行文件重命名 Execute file renaming based on operation type
perform_renaming() {
  echo "Select operation type:"
  echo "选择操作类型："
  echo "1. Delete specific content"
  echo "1. 删除特定内容"
  echo "2. Add specific content"
  echo "2. 添加特定内容"
  echo "3. Replace specific content"
  echo "3. 替换特定内容"
  echo "Enter your choice (1/2/3): "
  read -p "输入您的选择 (1/2/3): " op_type  # 添加中文提示 Add Chinese prompt
  case $op_type in
    1) perform_deletion ;;
    2) add_or_replace_string "add" ;;
    3) add_or_replace_string "replace" ;;
    *) print_message red "Invalid operation type" 
       print_message red "无效的操作类型" ;;
  esac
}

# 结束日志记录 End logging
end_logging() {
  local end_script_time=$(date '+%Y-%m-%d %H:%M:%S')
  echo "Script End Time: $end_script_time" >> "$current_path/$LOG_FILE"
  echo "脚本结束时间: $end_script_time" >> "$current_path/$LOG_FILE"
  print_message green "Script execution ended"
  print_message green "脚本执行结束"
  local start_seconds=$(date -j -f '%Y-%m-%d %H:%M:%S' "$time_stamp" +%s 2>/dev/null || date --date="$time_stamp" +%s)
  local end_seconds=$(date -j -f '%Y-%m-%d %H:%M:%S' "$end_script_time" +%s 2>/dev/null || date --date="$end_script_time" +%s)
  local duration=$((end_seconds - start_seconds))
  echo "Total Execution Time: $duration seconds" >> "$current_path/$LOG_FILE"
  echo "脚本总执行耗时: $duration 秒" >> "$current_path/$LOG_FILE"
  print_message green "Total Execution Time: $duration seconds"
  print_message green "脚本总执行耗时: $duration 秒"
  echo "$SEPARATOR" >> "$current_path/$LOG_FILE"
}

# 主函数 Main function
main() {
  # 检查并处理上次执行和日志 Check and handle previous run and logs
  handle_previous_run
  # 开始日志记录 Start logging
  start_logging
  # 执行文件重命名 Execute file renaming
  perform_renaming
  # 结束日志记录 End logging
  end_logging
}

main "$@"
