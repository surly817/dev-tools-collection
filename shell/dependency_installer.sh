#!/bin/bash

# 依赖项列表文件
DEPENDENCIES_FILE="dependencies.txt" 

# 日志文件 
LOG_FILE="dependency_install.log"

# 安装命令,可以指定多个
INSTALL_COMMANDS=("yum install -y" "apt install -y" "brew install")

# 输出提示语句
echo -e '\033[32m脚本开始执行\033[0m'
echo "本程序用于检测当前环境是否符合 $DEPENDENCIES_FILE 中所需依赖"
echo "当前安装命令为 yum install -y apt install -y brew install"
echo "执行日志将输出控制台并保留在 $LOG_FILE 文件中"

# 检查文件是否存在
if [ ! -f "dependencies.txt" ]; then
  echo -e "\033[31m错误：文件 $DEPENDENCIES_FILE 不存在，请确保文件存在。脚本终止。\033[0m"
  exit 1
fi

# 当前文件存在依赖数
# 统计非空行的数量
non_empty_line_count=$(grep -v '^$' $DEPENDENCIES_FILE | wc -l)

# 输出非空行数量
echo "当前文件所示需比对依赖数: $non_empty_line_count"

# 检测依赖项是否已安装的函数
check_installed() {
  if command -v "$1" > /dev/null 2>&1; then
    return 0 
  else  
    return 1
  fi  
}

# 安装依赖项的函数
install_dependency() {
  
  # 参数解析
  local dependency="$1"
  
  # 循环尝试各安装源 
  local result=1
  for cmd in "${INSTALL_COMMANDS[@]}"; do
    echo "$(date) - Trying to install '$dependency' using '$cmd'" >> "$LOG_FILE"
    # 执行安装命令,检查结果
    eval "$cmd $dependency" 2>&1 | tee -a "$LOG_FILE"
    result=$?  
    if [ $result -eq 0 ]; then
      return 0
    fi
  done   
  
  # 安装失败处理
  if [ $result -ne 0 ]; then
    echo "$(date) - Failed to install '$dependency'" >> "$LOG_FILE"
    # 高亮显示
    echo -e "\033[31m$(date) - $dependency install FAILED\033[0m" >> "$LOG_FILE" 
    print_log_highlight
  fi
  
  return $result
}

# 错误内容高亮输出控制台
print_log_highlight() {

    # 提取日志中高亮失败部分 
    cat "$LOG_FILE" | grep $'\e' | while read line; do
    echo -e "$line"
  done  
}

# 主流程
echo "$(date) - Start dependency check and install" > "$LOG_FILE"

while IFS= read -r dependency; do
  
  if check_installed "$dependency"; then  
    echo "$(date) - $dependency is already installed" >> "$LOG_FILE"
  else
    
    # 尝试安装2次
    for i in {1..2}; do
      install_dependency "$dependency"
      if [ $? -eq 0 ]; then
        break  
      fi 
    done
    
  fi
  
done < "$DEPENDENCIES_FILE"  
echo "$(date) - Dependency check and Install finished" >> "$LOG_FILE"

# 输出提示语句
echo -e '\033[32m脚本执行完成\033[0m'
