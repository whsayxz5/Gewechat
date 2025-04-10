#!/bin/bash

# Gewechat 一键启动脚本
# 功能:
# 1. 启动单个gewe容器，并挂载和配置默认端口
# 2. 批量启动多个gewe容器，并自动创建挂载目录和按顺序分配端口
# 3. 所有容器运行在单独的gewe容器网络

# 颜色设置
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
BOLD="\033[1m"
RESET="\033[0m"

# 默认配置
DEFAULT_PORT=2531
DEFAULT_FILE_PORT=2532
DEFAULT_MOUNT_DIR="$PWD/gewechat/data"
NETWORK_NAME="gewe_network"
IMAGE_NAME="gewe"

# 打印欢迎信息
print_welcome() {
    clear
    echo -e "${GREEN}${BOLD}=================================================${RESET}"
    echo -e "${GREEN}${BOLD}           Gewechat 一键启动脚本 V1.0           ${RESET}"
    echo -e "${GREEN}${BOLD}=================================================${RESET}"
    echo ""
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: Docker未安装，请先安装Docker${RESET}"
        exit 1
    fi
}

# 拉取并标记镜像
pull_image() {
    echo -e "${YELLOW}正在拉取镜像...${RESET}"
    docker pull registry.cn-chengdu.aliyuncs.com/tu1h/wechotd:alpine
    docker tag registry.cn-chengdu.aliyuncs.com/tu1h/wechotd:alpine $IMAGE_NAME
    echo -e "${GREEN}镜像准备完成${RESET}"
}

# 创建Docker网络
create_network() {
    if ! docker network inspect $NETWORK_NAME &> /dev/null; then
        echo -e "${YELLOW}正在创建Docker网络: $NETWORK_NAME${RESET}"
        docker network create $NETWORK_NAME
        echo -e "${GREEN}网络创建成功${RESET}"
    else
        echo -e "${GREEN}网络 $NETWORK_NAME 已存在${RESET}"
    fi
}

# 获取下一个可用的容器编号
get_next_container_number() {
    local prefix=$1
    local start_num=$2  # 开始尝试的编号，默认为1
    
    if [ -z "$start_num" ]; then
        start_num=1
    fi
    
    # 查找所有以指定前缀开头的容器
    local containers=$(docker ps -a --format '{{.Names}}' | grep "^$prefix[0-9]*$")
    
    if [ -z "$containers" ] && [ "$start_num" = "1" ]; then
        # 如果没有找到容器，返回1作为第一个编号
        echo "1"
        return
    fi
    
    # 如果明确指定了起始编号，则直接使用
    if [ "$start_num" -gt "1" ]; then
        echo "$start_num"
        return
    fi
    
    # 检查不带数字的容器名是否存在
    if docker ps -a --format '{{.Names}}' | grep -q "^$prefix$"; then
        # 如果存在不带数字的容器(如"gewe")，则从1开始尝试
        echo "1"
    else
        # 如果不存在不带数字的容器，则返回0表示可以使用不带数字的容器名
        echo "0"
    fi
}

# 顺序尝试容器名
try_container_names_sequentially() {
    local prefix=$1
    local start_num=$2
    local max_attempts=$3
    
    if [ -z "$start_num" ]; then
        start_num=0
    fi
    
    for i in $(seq $start_num $max_attempts); do
        local name
        if [ "$i" = "0" ]; then
            name="$prefix"
        else
            name="$prefix$i"
        fi
        
        # 检查是否已存在同名容器
        if ! docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
            echo "$name"
            return 0
        fi
    done
    
    # 如果找不到可用的容器名，返回空
    return 1
}

# 检查指定端口是否被占用
check_port_available() {
    local port=$1
    # 检查端口是否被Docker容器使用
    if docker ps -a --format '{{.Ports}}' | grep -q ":$port->"; then
        return 1
    fi
    
    # 检查端口是否被其他进程使用
    if command -v nc &> /dev/null; then
        nc -z localhost $port &> /dev/null && return 1
    elif command -v lsof &> /dev/null; then
        lsof -i:$port &> /dev/null && return 1
    else
        # 如果没有nc和lsof，尝试使用/dev/tcp (bash内置功能)
        (echo > /dev/tcp/localhost/$port) 2>/dev/null && return 1
    fi
    
    return 0
}

# 获取下一组可用端口
get_next_available_ports() {
    local base_port=$DEFAULT_PORT
    local max_attempts=100
    local attempts=0
    
    # 从基础端口开始，找到第一组可用端口
    local api_port=$base_port
    local file_port=$((base_port + 1))
    
    while [ $attempts -lt $max_attempts ]; do
        # 检查API端口是否可用
        if check_port_available $api_port; then
            # 检查文件端口是否可用
            if check_port_available $file_port; then
                echo "$api_port $file_port"
                return 0
            fi
        fi
        
        # 尝试下一组端口
        api_port=$((api_port + 2))
        file_port=$((file_port + 2))
        attempts=$((attempts + 1))
    done
    
    # 如果找不到可用的端口对，返回失败
    echo -e "${RED}错误: 无法找到可用的端口对。已尝试 $max_attempts 组端口。${RESET}"
    return 1
}

# 启动单个容器
start_single_container() {
    local max_attempts=20  # 最多尝试20次不同的编号
    local success=false
    
    # 获取一个可用的容器名称
    local name=$(try_container_names_sequentially "gewe" 0 $max_attempts)
    
    if [ -z "$name" ]; then
        echo -e "${RED}错误: 无法找到可用的容器名称，已尝试gewe到gewe$max_attempts${RESET}"
        return 1
    fi
    
    # 设置挂载目录
    local mount_dir
    if [ "$name" = "gewe" ]; then
        mount_dir="$DEFAULT_MOUNT_DIR"
    else
        # 从gewe1, gewe2等提取数字部分
        local num=${name#gewe}
        mount_dir="${DEFAULT_MOUNT_DIR}_$num"
    fi
    
    # 获取可用端口
    local ports_result=$(get_next_available_ports)
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 无法启动容器，端口分配失败${RESET}"
        return 1
    fi
    
    local port=$(echo $ports_result | cut -d ' ' -f 1)
    local file_port=$(echo $ports_result | cut -d ' ' -f 2)
    
    echo -e "${YELLOW}正在启动 $name 容器，使用端口 $port 和 $file_port${RESET}"
    
    # 创建挂载目录
    mkdir -p $mount_dir
    
    # 启动容器
    docker run -itd \
        --name=$name \
        --network=$NETWORK_NAME \
        -v $mount_dir:/root/temp \
        -p $port:2531 \
        -p $file_port:2532 \
        --restart=always \
        $IMAGE_NAME
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}容器启动成功！${RESET}"
        echo -e "${GREEN}容器名称: ${YELLOW}$name${RESET}"
        echo -e "${GREEN}API服务地址: ${YELLOW}http://localhost:$port/v2/api/${RESET}"
        echo -e "${GREEN}文件下载地址: ${YELLOW}http://localhost:$file_port/download/${RESET}"
        echo -e "${GREEN}挂载目录: ${YELLOW}$mount_dir${RESET}"
        return 0
    else
        echo -e "${RED}容器 $name 启动失败${RESET}"
        return 1
    fi
}

# 批量启动容器
start_multiple_containers() {
    local count=$1
    local success_count=0
    
    echo -e "${YELLOW}正在批量启动 $count 个Gewe容器...${RESET}"
    
    # 顺序尝试创建容器
    local next_index=0
    local current_attempt=0
    
    while [ $success_count -lt $count ] && [ $current_attempt -lt 100 ]; do
        local name
        if [ $next_index -eq 0 ]; then
            name="gewe"
        else
            name="gewe$next_index"
        fi
        
        # 检查是否已存在同名容器
        if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
            echo -e "${YELLOW}容器 $name 已存在，尝试下一个名称${RESET}"
            next_index=$((next_index + 1))
            current_attempt=$((current_attempt + 1))
            continue
        fi
        
        # 设置挂载目录
        local mount_dir
        if [ $next_index -eq 0 ]; then
            mount_dir="$DEFAULT_MOUNT_DIR"
        else
            mount_dir="${DEFAULT_MOUNT_DIR}_$next_index"
        fi
        
        # 获取可用端口
        local ports_result=$(get_next_available_ports)
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: 无法启动容器，端口分配失败${RESET}"
            next_index=$((next_index + 1))
            current_attempt=$((current_attempt + 1))
            continue
        fi
        
        local port=$(echo $ports_result | cut -d ' ' -f 1)
        local file_port=$(echo $ports_result | cut -d ' ' -f 2)
        
        echo -e "${YELLOW}正在启动容器 $((success_count + 1))/$count: $name${RESET}"
        echo -e "${YELLOW}容器 $name 将使用端口 $port 和 $file_port${RESET}"
        
        # 创建挂载目录
        mkdir -p $mount_dir
        
        # 启动容器
        docker run -itd \
            --name=$name \
            --network=$NETWORK_NAME \
            -v $mount_dir:/root/temp \
            -p $port:2531 \
            -p $file_port:2532 \
            --restart=always \
            $IMAGE_NAME
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}容器 $name 启动成功！${RESET}"
            echo -e "${GREEN}API服务地址: ${YELLOW}http://localhost:$port/v2/api/${RESET}"
            echo -e "${GREEN}文件下载地址: ${YELLOW}http://localhost:$file_port/download/${RESET}"
            echo -e "${GREEN}挂载目录: ${YELLOW}$mount_dir${RESET}"
            success_count=$((success_count + 1))
        else
            echo -e "${RED}容器 $name 启动失败！${RESET}"
        fi
        
        next_index=$((next_index + 1))
        current_attempt=$((current_attempt + 1))
        
        # 避免同时启动过多容器
        sleep 2
    done
    
    if [ $success_count -lt $count ]; then
        echo -e "${YELLOW}警告: 只成功启动了 $success_count/$count 个容器${RESET}"
    else
        echo -e "${GREEN}批量启动完成, 成功启动 $success_count 个容器${RESET}"
    fi
}

# 显示可用端口
show_available_ports() {
    echo -e "${YELLOW}正在查找可用端口...${RESET}"
    local ports_result=$(get_next_available_ports)
    
    if [ $? -eq 0 ]; then
        local port=$(echo $ports_result | cut -d ' ' -f 1)
        local file_port=$(echo $ports_result | cut -d ' ' -f 2)
        echo -e "${GREEN}找到可用端口: ${YELLOW}$port${GREEN} (API) 和 ${YELLOW}$file_port${GREEN} (文件下载)${RESET}"
    else
        echo -e "${RED}当前无法找到可用端口对${RESET}"
    fi
}

# 显示已运行的gewe容器
list_containers() {
    echo -e "${YELLOW}当前运行的Gewe容器:${RESET}"
    
    # 获取所有gewe容器
    local containers=$(docker ps -a --filter "name=gewe" --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo -e "${RED}未找到任何Gewe容器${RESET}"
        return 1
    fi
    
    # 打印容器详细信息
    for container in $containers; do
        echo -e "${BLUE}============================================================${RESET}"
        echo -e "${GREEN}容器名: ${BLUE}$container${RESET}"
        
        # 获取容器状态
        local status=$(docker ps -a --filter "name=$container" --format "{{.Status}}")
        echo -e "${GREEN}状态: ${RESET}$status"
        
        # 获取端口映射
        local ports=$(docker ps -a --filter "name=$container" --format "{{.Ports}}")
        echo -e "${GREEN}端口映射: ${RESET}$ports"
        
        # 获取挂载信息 - 使用格式化输出每个挂载点
        echo -e "${GREEN}挂载目录: ${RESET}"
        docker inspect --format '{{range .Mounts}}  {{.Source}} -> {{.Destination}}{{println}}{{end}}' $container
        
        # 获取创建时间
        local created=$(docker ps -a --filter "name=$container" --format "{{.CreatedAt}}")
        echo -e "${GREEN}创建时间: ${RESET}$created"
    done
    
    echo -e "${BLUE}============================================================${RESET}"
    echo ""
    echo -e "${GREEN}共 $(echo "$containers" | wc -l | tr -d ' ') 个Gewe容器${RESET}"
}

# 停止容器
stop_container() {
    # 获取所有gewe容器
    local containers=$(docker ps -a --filter "name=gewe" --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo -e "${RED}未找到任何Gewe容器${RESET}"
        return 1
    fi
    
    PS3="请选择要停止的容器 (输入数字): "
    select container in $containers "返回"; do
        if [ "$container" = "返回" ]; then
            return 0
        elif [ -n "$container" ]; then
            echo -e "${YELLOW}正在停止容器 $container...${RESET}"
            docker stop $container
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}容器 $container 已停止${RESET}"
            else
                echo -e "${RED}停止容器 $container 失败${RESET}"
            fi
            return 0
        else
            echo -e "${RED}无效的选择${RESET}"
        fi
    done
}

# 删除容器
delete_container() {
    # 获取所有gewe容器
    local containers=$(docker ps -a --filter "name=gewe" --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo -e "${RED}未找到任何Gewe容器${RESET}"
        return 1
    fi
    
    PS3="请选择要删除的容器 (输入数字): "
    select container in $containers "返回"; do
        if [ "$container" = "返回" ]; then
            return 0
        elif [ -n "$container" ]; then
            echo -e "${RED}警告: 删除容器将丢失容器内的所有数据，除非已挂载到外部${RESET}"
            read -p "确定要删除容器 $container 吗? (y/n): " confirm
            
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -e "${YELLOW}正在停止并删除容器 $container...${RESET}"
                docker stop $container && docker rm $container
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}容器 $container 已删除${RESET}"
                else
                    echo -e "${RED}删除容器 $container 失败${RESET}"
                fi
            else
                echo -e "${YELLOW}已取消删除操作${RESET}"
            fi
            return 0
        else
            echo -e "${RED}无效的选择${RESET}"
        fi
    done
}

# 进入容器
enter_container() {
    # 获取所有运行中的gewe容器
    local containers=$(docker ps --filter "name=gewe" --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo -e "${RED}未找到任何运行中的Gewe容器${RESET}"
        return 1
    fi
    
    PS3="请选择要进入的容器 (输入数字): "
    select container in $containers "返回"; do
        if [ "$container" = "返回" ]; then
            return 0
        elif [ -n "$container" ]; then
            echo -e "${YELLOW}正在进入容器 $container...${RESET}"
            echo -e "${YELLOW}提示: 输入 'exit' 退出容器${RESET}"
            docker exec -it $container /bin/bash
            return 0
        else
            echo -e "${RED}无效的选择${RESET}"
        fi
    done
}

# 添加测试容器通信功能
test_container_communication() {
    # 获取所有运行中的gewe容器
    local containers=$(docker ps --filter "name=gewe" --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo -e "${RED}未找到任何运行中的Gewe容器${RESET}"
        return 1
    fi
    
    PS3="请选择源容器 (执行测试的容器) (输入数字): "
    select source_container in $containers "返回"; do
        if [ "$source_container" = "返回" ]; then
            return 0
        elif [ -n "$source_container" ]; then
            # 选择目标容器
            PS3="请选择目标容器 (要访问的容器) (输入数字): "
            select target_container in $containers "返回"; do
                if [ "$target_container" = "返回" ]; then
                    break
                elif [ -n "$target_container" ]; then
                    echo -e "${YELLOW}正在测试从 $source_container 访问 $target_container...${RESET}"
                    
                    # 使用curl测试API访问
                    echo -e "${BLUE}测试指令: curl http://$target_container:2531/v2/api/ -v${RESET}"
                    docker exec $source_container sh -c "curl http://$target_container:2531/v2/api/ -v"
                    
                    local result=$?
                    if [ $result -eq 0 ]; then
                        echo -e "${GREEN}通信测试成功！您可以在容器内使用 http://$target_container:2531/v2/api/ 访问服务${RESET}"
                    else
                        echo -e "${RED}通信测试失败 (代码: $result)${RESET}"
                    fi
                    break
                fi
            done
            return 0
        fi
    done
}

# 显示容器网络信息
show_network_info() {
    echo -e "${YELLOW}Gewe容器网络信息:${RESET}"
    
    # 检查网络是否存在
    if ! docker network inspect $NETWORK_NAME &> /dev/null; then
        echo -e "${RED}错误: $NETWORK_NAME 网络不存在${RESET}"
        return 1
    fi
    
    # 显示网络详情
    echo -e "${BLUE}网络名称: ${GREEN}$NETWORK_NAME${RESET}"
    echo -e "${BLUE}============================================================${RESET}"
    
    # 获取网络详情
    local subnet=$(docker network inspect $NETWORK_NAME --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
    local gateway=$(docker network inspect $NETWORK_NAME --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
    
    echo -e "${GREEN}子网: ${RESET}$subnet"
    echo -e "${GREEN}网关: ${RESET}$gateway"
    echo -e "${BLUE}============================================================${RESET}"
    
    # 显示连接到该网络的容器
    echo -e "${GREEN}连接到 $NETWORK_NAME 的容器:${RESET}"
    echo -e "${BLUE}容器名称\t\tIP地址${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    
    # 获取连接到该网络的容器
    local containers=$(docker network inspect $NETWORK_NAME --format '{{range $k, $v := .Containers}}{{$k}}{{end}}')
    
    if [ -z "$containers" ]; then
        echo -e "${RED}没有容器连接到 $NETWORK_NAME 网络${RESET}"
    else
        docker network inspect $NETWORK_NAME --format '{{range $k, $v := .Containers}}{{$v.Name}}\t{{$v.IPv4Address}}\n{{end}}'
    fi
    
    echo -e "${BLUE}============================================================${RESET}"
    echo -e "${GREEN}容器间通信提示:${RESET}"
    echo -e " - 在同一网络中的容器可以通过容器名直接通信"
    echo -e " - 示例: 在容器内使用 ${YELLOW}http://gewe:2531/v2/api/${RESET} 访问gewe容器的API"
    echo -e " - 示例: 在容器内使用 ${YELLOW}http://gewe1:2531/v2/api/${RESET} 访问gewe1容器的API"
    echo -e " - 您可以使用'测试容器通信'选项来验证容器间通信"
}

# 添加容器到网络
connect_container_to_network() {
    # 获取所有gewe容器
    local containers=$(docker ps -a --filter "name=gewe" --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo -e "${RED}未找到任何Gewe容器${RESET}"
        return 1
    fi
    
    PS3="请选择要添加到网络的容器 (输入数字): "
    select container in $containers "返回"; do
        if [ "$container" = "返回" ]; then
            return 0
        elif [ -n "$container" ]; then
            # 检查容器是否已经连接到网络
            if docker network inspect $NETWORK_NAME --format '{{range $k, $v := .Containers}}{{$v.Name}}{{end}}' | grep -q "$container"; then
                echo -e "${YELLOW}容器 $container 已连接到 $NETWORK_NAME 网络${RESET}"
                return 0
            fi
            
            echo -e "${YELLOW}正在将容器 $container 添加到 $NETWORK_NAME 网络...${RESET}"
            docker network connect $NETWORK_NAME $container
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}容器 $container 已成功添加到 $NETWORK_NAME 网络${RESET}"
                echo -e "${GREEN}现在可以使用容器名进行容器间通信${RESET}"
                echo -e "${GREEN}示例: 在其他容器中使用 ${YELLOW}http://$container:2531/v2/api/${RESET} 访问此容器"
            else
                echo -e "${RED}将容器 $container 添加到网络失败${RESET}"
            fi
            
            return 0
        fi
    done
}

# 显示引导菜单
show_menu() {
    while true; do
        print_welcome
        echo -e "${GREEN}请选择操作:${RESET}"
        echo -e "${YELLOW}1.${RESET} 启动单个Gewe容器"
        echo -e "${YELLOW}2.${RESET} 批量启动多个Gewe容器"
        echo -e "${YELLOW}3.${RESET} 查看当前运行的容器"
        echo -e "${YELLOW}4.${RESET} 停止容器"
        echo -e "${YELLOW}5.${RESET} 删除容器"
        echo -e "${YELLOW}6.${RESET} 进入容器"
        echo -e "${YELLOW}7.${RESET} 仅拉取镜像"
        echo -e "${YELLOW}8.${RESET} 检查可用端口"
        echo -e "${YELLOW}9.${RESET} 容器网络管理"
        echo -e "${YELLOW}0.${RESET} 退出"
        echo ""
        read -p "请输入选项 [0-9]: " choice
        
        case $choice in
            1) # 启动单个容器
                start_single_container
                read -p "按Enter键继续..."
                ;;
            2) # 批量启动容器
                read -p "请输入要启动的容器数量: " count
                if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
                    start_multiple_containers $count
                else
                    echo -e "${RED}错误: 请输入有效的数字${RESET}"
                fi
                read -p "按Enter键继续..."
                ;;
            3) # 查看容器列表
                list_containers
                read -p "按Enter键继续..."
                ;;
            4) # 停止容器
                stop_container
                read -p "按Enter键继续..."
                ;;
            5) # 删除容器
                delete_container
                read -p "按Enter键继续..."
                ;;
            6) # 进入容器
                enter_container
                ;;
            7) # 仅拉取镜像
                pull_image
                read -p "按Enter键继续..."
                ;;
            8) # 检查可用端口
                show_available_ports
                read -p "按Enter键继续..."
                ;;
            9) # 容器网络管理
                show_network_submenu
                ;;
            0) # 退出
                echo -e "${GREEN}谢谢使用，再见！${RESET}"
                exit 0
                ;;
            *) # 无效选项
                echo -e "${RED}错误: 请输入有效的选项 [0-9]${RESET}"
                read -p "按Enter键继续..."
                ;;
        esac
    done
}

# 显示网络管理子菜单
show_network_submenu() {
    while true; do
        print_welcome
        echo -e "${GREEN}容器网络管理:${RESET}"
        echo -e "${YELLOW}1.${RESET} 显示容器网络信息"
        echo -e "${YELLOW}2.${RESET} 测试容器间通信"
        echo -e "${YELLOW}3.${RESET} 添加容器到网络"
        echo -e "${YELLOW}0.${RESET} 返回主菜单"
        echo ""
        read -p "请输入选项 [0-3]: " subchoice
        
        case $subchoice in
            1) # 显示网络信息
                show_network_info
                read -p "按Enter键继续..."
                ;;
            2) # 测试容器通信
                test_container_communication
                read -p "按Enter键继续..."
                ;;
            3) # 添加容器到网络
                connect_container_to_network
                read -p "按Enter键继续..."
                ;;
            0) # 返回主菜单
                return
                ;;
            *) # 无效选项
                echo -e "${RED}错误: 请输入有效的选项 [0-3]${RESET}"
                read -p "按Enter键继续..."
                ;;
        esac
    done
}

# 主函数
main() {
    check_docker
    
    # 如果有命令行参数，则使用旧的命令行模式
    if [ $# -gt 0 ]; then
        local command=$1
        local param=$2
        
        case $command in
            "single")
                create_network
                pull_image
                start_single_container
                ;;
            "multi")
                if [[ ! $param =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}错误: 请指定有效的容器数量${RESET}"
                    exit 1
                fi
                create_network
                pull_image
                start_multiple_containers $param
                ;;
            "list")
                list_containers
                ;;
            "pull")
                pull_image
                ;;
            "menu")
                show_menu
                ;;
            "ports")
                show_available_ports
                ;;
            "help" | "")
                show_help
                ;;
            *)
                echo -e "${RED}错误: 未知命令 '$command'${RESET}"
                show_help
                exit 1
                ;;
        esac
    else
        # 无参数，使用引导式菜单
        show_menu
    fi
}

# 显示帮助信息
show_help() {
    echo "使用方法:"
    echo "  ./gewe_start.sh [命令] [参数]"
    echo ""
    echo "命令:"
    echo "  single             启动单个gewe容器"
    echo "  multi <数量>       批量启动指定数量的gewe容器"
    echo "  list               列出当前运行的gewe容器"
    echo "  pull               仅拉取并标记镜像"
    echo "  ports              检查可用端口"
    echo "  menu               启动引导式菜单"
    echo "  help               显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  ./gewe_start.sh single       # 启动单个容器"
    echo "  ./gewe_start.sh multi 3      # 启动3个容器"
    echo "  ./gewe_start.sh list         # 列出所有容器"
    echo "  ./gewe_start.sh              # 启动引导式菜单"
}

# 执行主函数
main "$@" 