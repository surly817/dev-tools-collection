#!/bin/bash

# 脚本名称: file_distributor.sh
# 作者: Surly
# 版本: 1.7
# 创建日期: 2024-04-15
# 最后修改日期: 2024-04-18
# 描述: 将文件分发到指定的集群机器，支持配置文件和带颜色的日志记录
# 脚本测试环境: Linux hadoop102 3.10.0-1160.83.1.el7.x86_64 #1 SMP Wed Jan 25 16:41:43 UTC 2023 x86_64 x86_64 x86_64 GNU/Linux / CentOS Linux release 7.9.2009 (Core)

# 基础环境配置
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="$SCRIPT_DIR/file_distributor.log"
CONFIG_FILE="$SCRIPT_DIR/file_distributor.conf"
declare -a hosts
declare is_hosts_saved=false
declare script_end_called=false

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
  # 如果未提供文件路径参数，则显示使用方法并退出
  if [ -z "$1" ]; then
    print_message ERROR red "用法: $0 <需分发的文件>" 
    exit 1
  fi

  is_hosts_saved=false
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ "$HOSTS_SAVED" == "true" ] && [ -n "$HOSTS" ]; then
      IFS=' ' read -r -a hosts <<< "$HOSTS"
      print_message INFO yellow "使用的主机配置: ${hosts[*]}"
    else
      input_hosts_and_command
    fi
  else
    input_hosts_and_command
  fi
}


# 输入主机名和命令的函数
input_hosts_and_command() {
  print_message WARNING yellow "未找到主机配置文件，请输入主机名（用空格分隔）: "
  print_message WARNING yellow "注意此处关联主机若未配置免密则需反复输入密码操作!"
  read -ra hosts
  printf -v joined_hosts '%s ' "${hosts[@]}"
  print_message INFO yellow "是否将这些主机配置保存为常用配置？(y/n): "
  read save_choice
  if [[ $save_choice =~ ^[Yy]$ ]]; then
    echo "HOSTS_SAVED=true" > "$CONFIG_FILE"
    echo "HOSTS=\"$joined_hosts\"" >> "$CONFIG_FILE"
    is_hosts_saved=true
  else
    is_hosts_saved=false
  fi
}

# 检查主机连通性
check_host_connectivity() {
  for host in "${hosts[@]}"; do
    if ping -c 1 "$host" &> /dev/null; then
      print_message INFO green "主机 $host 可以连通"
    else
      print_message ERROR red "主机 $host 无法连通"
      exit 1
    fi
  done
}

# 检查文件和发送
distribute_file() {
  local file="$1"

  # 如果指定的文件不存在，则显示错误信息并退出
  if [ ! -f "$file" ]; then
    print_message ERROR red "文件 $file 不存在。脚本退出"
    exit 1
  fi

  # 默认同步模式为跳过已存在的文件
  local rsync_options="-av --ignore-existing"

  for host in "${hosts[@]}"; do
    print_message INFO yellow "正在向 $host 分发文件 $file..."
    pdir=$(cd -P "$(dirname "$file")" && pwd)
    fname=$(basename "$file")

    # 在远程主机上创建目录，忽略已存在的目录
    ssh "$host" "mkdir -p \"$pdir\"" 2>/dev/null || print_message ERROR red "在 $host 上创建目录失败"

    # 使用 rsync 命令同步文件，忽略已存在的文件
    rsync $rsync_options "$pdir/$fname" "$host:$pdir" 2>/dev/null && print_message INFO green "成功将 $fname 发送至 $host:$pdir" || print_message ERROR red "向 $host 发送 $fname 失败"
  done
}

# 主程序
main() {
  script_start
  initialize "$1"
  check_host_connectivity
  distribute_file "$1"
  script_end
}

main "$@"
