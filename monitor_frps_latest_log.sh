#!/bin/bash

# 脚本名称: monitor_frps_latest_log.sh
# 作者: Surly
# 版本: 1.0
# 创建日期: 2023-12-30th
# 最后修改日期: 2023-12-30th
# 描述: 该脚本用于监控frps日志默认参数10 亦可添加参数调整前置展示数量

# 输出样式设置
RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'
RESET='\033[0m'

# 函数：输出红色信息
print_red() {
  echo -e "${RED}$1${RESET}"
}

# 函数：输出黄色信息
print_yellow() {
  echo -e "${YELLOW}$1${RESET}"
}

# 函数：输出黄色信息
print_green() {
  echo -e "${GREEN}$1${RESET}"
}

# 函数：脚本开始执行
script_start() {
  echo "----------------------------------------"
  print_green "脚本开始执行"
  echo "----------------------------------------"
}

# 函数：脚本结束执行
script_end() {
  echo "----------------------------------------"
  print_green "脚本执行结束"
  echo "----------------------------------------"
}

# 主函数
main() {
  script_start

  # 目录路径
  log_dir="/opt/module/frp_0.45.0_linux_amd64/logs/"

  # 获取最新文件
  latest_file=$(ls --time=ctime -1 "$log_dir" | head -n 1)

  # 检查是否有找到文件
  if [ -n "$latest_file" ]; then
      # 构建完整文件路径
      full_path="${log_dir}${latest_file}"

      # 检查是否提供了命令行参数，如果没有，默认使用10
      tail_lines=${1:-10}

      # 输出提示信息
      print_green "正在实时监视文件: $full_path"
      print_green "显示最后 $tail_lines 行日志（可通过命令行参数更改）"

      # 使用tail命令读取文件的最后n行（根据提供的参数）
      tail -n "$tail_lines" -f "$full_path"
  else
      print_red "未找到日志文件"
  fi

  script_end
}

# 执行主函数
main "$@"