#!/bin/bash

# 脚本名称: manage_PalServer.sh
# 作者: Surly
# 版本: 1.11
# 创建日期: 2024年1月24日
# 最后修改日期: 2024年1月29日
# 描述: 该脚本用于管理 PalServer 启动、重启、停止、保存、状态查询和修改配置。
#       执行启动、重启、停止、修改配置时会进行存档备份

# 输出样式设置
RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'
RESET='\033[0m'

# 定义PalServer.sh脚本路径
PAL_SERVER_SCRIPT="/home/steam/Steam/steamapps/common/PalServer/PalServer.sh"
# 定义PalWorldSettings.ini文件路径
INI_FILE="/home/steam/Steam/steamapps/common/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini"
# 定义日志目录
LOG_DIR="/opt/PalServer/log"
# 定义日志文件名
LOG_FILE="${LOG_DIR}/PalServer_$(date '+%Y%m%d_%H%M%S').log"
# 定义占用的端口号
PORT=8211
# 定义备份目录
BAK_DIR="/opt/PalServer/backup"
# 定义备份文件名
BAK_FILE="${BAK_DIR}/Save_$(date '+%Y%m%d_%H%M%S').tar.gz"
# 定义被备份目录
SOU_FILE="/home/steam/Steam/steamapps/common/PalServer/Pal/"

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

# 函数：输出黄色信息，并带有递增的等待时间提示
print_yellow_with_incremental_delay() {
  local message="$1"
  local total_delay_seconds="$2"
  local current_delay_seconds=0
  local delay_increment=1

  while [ "$current_delay_seconds" -lt "$total_delay_seconds" ]; do
    echo -e "${YELLOW}${message} - Waiting for ${current_delay_seconds}s...${RESET}"
    sleep "$delay_increment"
    ((current_delay_seconds += delay_increment))
  done

  # 输出最后一次等待时间
  echo -e "${YELLOW}${message} - Waiting for ${total_delay_seconds}s...${RESET}"
}

# 程序开始命令
start_server() {
    pid=$(lsof -i :$PORT | awk 'NR==2 {print $2}')
    if [ -n "$pid" ]; then
        print_yellow "PalServer is already running with PID: $pid."
        return
    fi

    echo "Starting PalServer..."
    # 切换用户并执行启动命令 前提进行对应文件权限修改[777]
    echo "当前时间 $(date)" 
    su steam -c "$PAL_SERVER_SCRIPT >> "$LOG_FILE" 2>&1 &"
    print_green "PalServer started. Check $LOG_FILE for details."
    should_continue=true
}

# 程序停止命令
stop_server() {
    echo "Stopping PalServer..."
    pid=$(lsof -i :$PORT | awk 'NR==2 {print $2}')
    if [ -n "$pid" ]; then
        kill -15 $pid
        print_green "PalServer stopped."
    else
        print_yellow "PalServer is not running."
    fi
}

# 程序状态检查命令
check_status() {
    pid=$(lsof -i :$PORT | awk 'NR==2 {print $2}')
    if [ -n "$pid" ]; then
        print_green "PalServer is running with PID: $pid."
    else
        print_yellow "PalServer is not running."
    fi
}

# 备份数据命令
backup_data() {
    echo "Backing up data..."
    tar -zcf "$BAK_FILE" -C  "$SOU_FILE" "Saved/" 
    print_green "Data backed up to $BAK_FILE."
}

# 停止并修改配置命令
stop_and_modify() {
    stop_server
    echo "Modifying $INI_FILE..."
    # 进行修改操作，可以使用vim编辑器或其他编辑器，这里假设使用vim
    vim "$INI_FILE"
    start_server
}

# 主函数
main() {
  script_start

  # 判断文件目录是否存在，不存在则创建
  if [ ! -d $LOG_DIR ];then
     mkdir -p $LOG_DIR
  fi

  # 判断备份目录是否存在，不存在则创建
  if [ ! -d "$BAK_DIR" ]; then
      mkdir -p "$BAK_DIR"
  fi

  # 解释参数并执行相应操作
  case "$1" in
      start)
          start_server
          if [ "$should_continue" == true ]; then
            print_yellow_with_incremental_delay start 3
            backup_data
          fi
          ;;
      stop)
          backup_data
          print_yellow_with_incremental_delay backup 3
          stop_server
          ;;
      status)
          check_status
          ;;
      restart)
          backup_data
          print_yellow_with_incremental_delay backup 3
          stop_server
          print_yellow_with_incremental_delay stop 3
          start_server
          ;;
      modify)
          backup_data
          print_yellow_with_incremental_delay backup 3
          stop_and_modify
          ;;
      backup)
          backup_data
          ;;
      *)
          print_yellow "Usage: $0 {start|stop|restart|status|modify|backup}"
          ;;
    esac

    script_end
  }

# 执行主函数
main "$@"
