#!/bin/bash

# 脚本名称: script_template.sh
# 作者: Surly
# 版本: 2.1
# 创建日期: 2024-01-04
# 最后修改日期: 2024-07-09
# 描述: 通用脚本模板，支持日志记录、错误处理和带颜色的日志输出
# 优化部分: 将过程日志也存储至log文件中，使用了新的日志输出定向和打印函数 
# print_message ｜ print_message_no_log 两种输出模式
# exec > >(tee -a "$LOG_FILE") 2>&1     在main函数中定义日志输出定向 配合print_message_no_log实现日志全输出[模版 + 过程]
# 若非⬆️方式处理log,使用print_message替换输出实现[部分log记录]
# 输出样式(若有): 
# 脚本测试环境: 

# 基础环境配置 Basic Environment Configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="$SCRIPT_DIR/${SCRIPT_NAME}.log"
CONFIG_FILE="$SCRIPT_DIR/${SCRIPT_NAME}.conf"
declare script_end_called=false
config_needed=false

# 输出颜色设置 Color Output Settings
declare -A COLORS=( [red]='\033[0;31m' [green]='\033[0;32m' [yellow]='\033[0;33m' [reset]='\033[0m' )

# 日志记录和回滚标识的分隔符 Separator for logs and rollback identification
SEPARATOR="========================================"

# 获取格式化时间戳 Function to get formatted timestamp
get_formatted_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# 函数：不同颜色输出信息 Function to print messages in different colors
print_message() {
  local level=$1
  local color=${COLORS[$2]}
  local message=$3
  echo -e "${color}[$level] $message${COLORS['reset']}" | tee -a "$LOG_FILE"
}

# 打印带颜色的消息，不写入日志
print_message_no_log() {
  local level=$1
  local color=${COLORS[$2]}
  local message=$3
  echo -e "${color}[$level] $message${COLORS['reset']}"
}

# 错误处理函数 Error Handling
trap_error() {
  local error=$?
  print_message_no_log ERROR red "发生错误，脚本退出。最后执行命令的退出状态：${error}"
  script_end
  exit "${error}"
}

# 信号捕获 Signal Catching
trap 'trap_error' ERR INT TERM
trap 'script_end' EXIT

# 开始日志记录 Start logging
script_start() {
  echo "$SEPARATOR" >> "$LOG_FILE"
  time_stamp=$(get_formatted_timestamp)
  print_message_no_log INFO yellow "脚本开始执行于：$time_stamp"
}

# 结束日志记录 End logging
script_end() {
  if [ "$script_end_called" = false ]; then
    script_end_called=true
    local end_script_time=$(get_formatted_timestamp)
    print_message_no_log INFO yellow "脚本结束执行于：$end_script_time"
    local start_seconds=$(date -d "$time_stamp" +%s)
    local end_seconds=$(date -d "$end_script_time" +%s)
    local duration=$((end_seconds - start_seconds))
    print_message_no_log INFO green "脚本总执行时间：$duration 秒"
    echo "$SEPARATOR" >> "$LOG_FILE"
  fi
}

# 配置检查和初始化 Configuration Check and Initialization
initialize() {
  if [ "$config_needed" = true ]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      print_message_no_log ERROR red "配置文件不存在：$CONFIG_FILE"
      exit 1
    fi

    # 如果需要从配置文件中读取内容，可以在此处添加相关代码
  fi
}

# 示例函数（用户可以添加自己的函数）
example_function() {
  print_message_no_log INFO green "这是一个示例函数"
  # 在这里添加实际的功能实现
}

# 主函数 Main Function
main() {
  # 重定向 stdout 和 stderr 到日志文件
  exec > >(tee -a "$LOG_FILE") 2>&1
  
  initialize
  script_start

  # 在这里添加脚本的主要逻辑
  # 示例操作
  example_function

  script_end
}

# 执行主函数 Execute Main Function
main "$@"
