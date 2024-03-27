#!/bin/bash

# 脚本名称:         check_nodes_status.sh
# 作者:             surly
# 版本:             1.1
# 创建日期:         2023-12-29th
# 最后修改日期:      2024-03-06th
# 描述:             该脚本用于检查各节点运行情况
#                   新增读取ip改为/etc/hosts 并从中获取对应hostname        

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

# 函数：输出绿色信息
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

  # 从 /etc/hosts 中获取需要查询的节点地址和对应的主机名
  nodes=($(grep -v "local" /etc/hosts | awk '{print $1}'))  # 提取IP地址
  hostnames=($(grep -v "local" /etc/hosts | awk '{print $2}'))  # 提取主机名

  # 依次对节点进行ping连接
  for ((i=0; i<${#nodes[@]}; i++)); do
    node=${nodes[i]}
    hostname=${hostnames[i]}
    
    echo "Checking node: $node"
    if ping -c 1 "$node" &> /dev/null; then
      # 节点正常 输出绿色
      print_green "Node $node ($hostname) is reachable."
    else
      # 节点异常 输出黄色
      print_yellow "Node $node ($hostname) is not reachable."
    fi
    echo "----------------------------------"
  done

  script_end
}

# 执行主函数
main
