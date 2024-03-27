#!/bin/bash
# 脚本名称: service_manager.sh
# 作者: Surly
# 版本: 1.7
# 创建日期: 2024-01-04
# 最后修改日期: 2024-01-04
# 描述: 该脚本用于管理服务......

# 获取脚本所在目录
SCRIPT_DIR="/home/atguigu/bin"

# 函数：输出红色信息
print_red() {
  echo -e "\033[31m$1\033[0m"
}

# 函数：输出黄色信息
print_yellow() {
  echo -e "\033[33m$1\033[0m"
}

# 函数：输出绿色信息
print_green() {
  echo -e "\033[32m$1\033[0m"
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

# 函数：启动服务
start_service() {
    print_yellow "Starting $1..."
    $SCRIPT_DIR/$1 start
    sleep 5  # 等待一段时间，确保服务启动完成
}

# 函数：停止服务
stop_service() {
    print_yellow "Stopping $1..."
    $SCRIPT_DIR/$1 stop
    sleep 5  # 等待一段时间，确保服务关闭完成
}

# 主函数
main() {
    script_start

    # 根据传入的参数执行相应操作
    case "$1" in
        start)
            start_service z1oo
            start_service h1adoop
            start_service k1afka
            start_service h2ive
            start_service h3base
            start_service c2lickhouse.sh
            ;;
        stop)
            stop_service c2lickhouse.sh
            stop_service h3base
            stop_service h2ive
            stop_service k1afka
            stop_service h1adoop
            stop_service z1oo
            ;;
        *)
            print_red "Usage: $0 {start|stop}"
            exit 1
            ;;
    esac

    script_end
}

# 执行主函数并传递脚本的所有参数
main "$@"
