#!/bin/bash

# 脚本名称: cluster_manager.sh
# 作者: Surly
# 版本: 1.1
# 创建日期: 2024-07-09
# 最后修改日期: 2024-07-09
# 描述: root状态下hdp102启动 管理集群的启动、停止和状态检查

# 基础环境配置
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="$SCRIPT_DIR/${SCRIPT_NAME}.log"
CONFIG_FILE="$SCRIPT_DIR/${SCRIPT_NAME}.conf"
declare script_end_called=false
config_needed=false
USER_NAME=atguigu

# 输出颜色设置
declare -A COLORS=( [red]='\033[0;31m' [green]='\033[0;32m' [yellow]='\033[0;33m' [reset]='\033[0m' )

# 分隔符
SEPARATOR="========================================"

# 获取格式化时间戳
get_formatted_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# 打印带颜色的消息
print_message() {
  local level=$1
  local color=${COLORS[$2]}
  local message=$3
  echo -e "${color}[$level] $message${COLORS['reset']}" | tee -a "$LOG_FILE"
}

# 错误处理
trap_error() {
  local error=$?
  print_message ERROR red "发生错误，脚本退出。最后执行命令的退出状态：${error}"
  script_end
  exit "${error}"
}

# 设置 trap
trap 'trap_error' ERR INT TERM
trap 'script_end' EXIT

# 开始和结束日志
script_start() {
  echo "$SEPARATOR" >> "$LOG_FILE"
  time_stamp=$(get_formatted_timestamp)
  print_message INFO yellow "脚本开始执行于：$time_stamp"
}

script_end() {
  if [ "$script_end_called" = false ]; then
    script_end_called=true
    local end_script_time=$(get_formatted_timestamp)
    print_message INFO yellow "脚本结束执行于：$end_script_time"
    local start_seconds=$(date -d "$time_stamp" +%s)
    local end_seconds=$(date -d "$end_script_time" +%s)
    local duration=$((end_seconds - start_seconds))
    print_message INFO green "脚本总执行时间：$duration 秒"
    echo "$SEPARATOR" >> "$LOG_FILE"
  fi
}

# 初始化配置检查
initialize() {
  if [ "$config_needed" = true ]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      print_message ERROR red "配置文件不存在：$CONFIG_FILE"
      exit 1
    fi

    # 如果需要从配置文件中读取内容，可以在此处添加相关代码
  fi
}

# 函数：启动集群
start_cluster() {
  print_message INFO green "正在启动集群..."
  su -c '~/bin/server_manager.sh start' $USER_NAME
  print_message INFO green "集群启动完成。"
}

# 函数：停止集群
stop_cluster() {
  print_message INFO green "正在停止集群..."
  su -c '~/bin/server_manager.sh stop' $USER_NAME
  print_message INFO green "集群停止完成。"
}

# 函数：检查集群状态
check_status() {
  print_message INFO green "正在检查集群状态..."
  su -c '~/bin/j1ps' $USER_NAME
  print_message INFO green "集群状态检查完成。"
}

# 主程序
main() {
  script_start

  case "$1" in
    start)
      start_cluster
      ;;
    stop)
      stop_cluster
      ;;
    status)
      check_status
      ;;
    *)
      print_message ERROR red "无效的命令。使用方法: $SCRIPT_NAME {start|stop|status}"
      exit 1
      ;;
  esac

  script_end
}

main "$@"
