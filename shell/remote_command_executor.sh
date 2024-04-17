#!/bin/bash

# 脚本名称: remote_command_executor.sh
# 作者: Surly
# 版本: 2.2
# 创建日期: 2024-04-11
# 最后修改日期: 2024-04-16
# 描述: 在多个主机上执行指定命令，并带有日志记录和错误处理功能
# 脚本测试环境: Linux hadoop102 3.10.0-1160.83.1.el7.x86_64 #1 SMP Wed Jan 25 16:41:43 UTC 2023 x86_64 x86_64 x86_64 GNU/Linux / CentOS Linux release 7.9.2009 (Core)

# 基础环境配置
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="$SCRIPT_DIR/$(basename "$0" .sh).log"
CONFIG_FILE="$SCRIPT_DIR/remote_command_executor.conf"
declare -a hosts
declare input_command=""
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
    # 更新标志，表明 script_end 已被调用
    script_end_called=true
    local end_script_time=$(get_formatted_timestamp)
    print_message INFO yellow "脚本结束执行于：$end_script_time"
    local start_seconds=$(date -d "$time_stamp" +%s)
    local end_seconds=$(date -d "$end_script_time" +%s)
    local duration=$((end_seconds - start_seconds))
    print_message INFO green "脚本总执行时间：$duration 秒"
    echo "$SEPARATOR" >> "$LOG_FILE"  # 在执行结束后添加分隔符
  fi
}

# 初始化配置检查
initialize() {
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

  # 如果已通过命令行参数提供了命令，则不需要提示输入命令
  if [ -z "$input_command" ]; then
    if [ $# -lt 1 ]; then
      print_message INFO yellow "请输入要执行的命令: "
      read input_command
    else
      input_command=$1
    fi
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

# 主机连通性检查
check_host_connectivity() {
  local host=$1
  ping -c 1 -W 1 "$host" &> /dev/null
  if [ $? -ne 0 ]; then
    print_message WARNING yellow "主机 $host 无法连接。"
    return 1
  fi
}

# 加载主机名
load_hosts() {
  if [ "$is_hosts_saved" == false ]; then
    # 直接使用用户输入的主机名
    return
  fi
  source "$CONFIG_FILE"
  print_message INFO yellow "正在从配置文件加载主机名..."
  if [ -n "${HOSTS:-}" ]; then
    IFS=' ' read -r -a hosts <<< "${HOSTS}"
  else
    print_message ERROR red "配置文件中未包含主机名。"
    exit 1
  fi
}

# 生成以主机名为中心的分隔符
generate_host_separator() {
  local host=$1
  local line_length=${#host}
  local padding_length=$(( (30 - line_length) / 2 ))
  local padding=$(printf '%*s' $padding_length '')
  local separator="${padding// /-}$host${padding// /-}"
  [ $(( (line_length + 2 * padding_length) % 2 )) -ne 0 ] && separator="${separator}-"
  echo "$separator"
}

# 执行远程命令
execute_remote_command() {
  local command=$1
  for host in "${hosts[@]}"
  do
    if check_host_connectivity "$host"; then
      local host_separator=$(generate_host_separator "$host")
      echo "$host_separator"
      print_message INFO green "正在 $host 上执行命令：$command"
      ssh "$host" "$command" || print_message WARNING red "$host 上执行命令失败。"
      echo "$host_separator"
    fi
  done
}

# 主函数
main() {
  script_start
  initialize "$@"

  if [ -n "${hosts[*]}" ]; then
    print_message INFO yellow "将在以下主机上执行命令：${hosts[*]}"
  fi

  load_hosts

  execute_remote_command "$input_command"
  script_end
}

main "$@"
