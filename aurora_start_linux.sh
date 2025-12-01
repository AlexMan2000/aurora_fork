#!/usr/bin/env bash
set -euo pipefail

echo "=== Aurora blog installer for Amazon Linux (2 / 2023) ==="

# -------------------------------
# 0. 检查 & 检测系统
# -------------------------------
if [ ! -f /etc/os-release ]; then
  echo "/etc/os-release not found. This script is intended for Amazon Linux."
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "amzn" ]]; then
  echo "This script is intended for Amazon Linux (ID=amzn), but got ID=${ID:-unknown}"
  exit 1
fi

AMZN_VERSION="${VERSION_ID:-unknown}"
echo "Detected Amazon Linux version: ${AMZN_VERSION}"

# 当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -------------------------------
# 1. 安装 Docker（如果尚未安装）
# -------------------------------
if ! command -v docker &>/dev/null; then
  echo "Docker not found. Installing Docker..."

  # AL2: 用 amazon-linux-extras
  # AL2023: 用 dnf
  # Amazon Linux 2023 及之后版本
  sudo dnf install -y docker
  
else
  echo "Docker already installed."
fi

echo "Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# 确认 docker 能正常工作
if ! sudo docker info &>/dev/null; then
  echo "Docker daemon is not running properly. Please check 'sudo systemctl status docker'."
  exit 1
fi

# -------------------------------
# 2. 创建 Docker 网络
# -------------------------------
echo "Creating docker network 'aurora' (if not exists)..."
if ! sudo docker network inspect aurora &>/dev/null; then
  sudo docker network create aurora
  echo "Docker network 'aurora' created."
else
  echo "Docker network 'aurora' already exists."
fi

# 用于最后提示的公网 IP（在 EC2 上优先用 metadata）
public_ip="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || curl -s ifconfig.me || echo "localhost")"

# -------------------------------
# 3. 启动 MySQL
# -------------------------------
mysql_version="8.0.39-debian"
MYSQL_PASSWORD="Aurora_123456"

echo "Pulling MySQL image: mysql:${mysql_version} ..."
sudo docker pull "mysql:${mysql_version}"

echo "Creating MySQL data directories..."
sudo mkdir -p /opt/data/mysql/data
sudo mkdir -p /opt/data/mysql/conf
sudo mkdir -p /opt/data/mysql/mysqld
sudo chmod 777 /opt/data/mysql/data /opt/data/mysql/conf /opt/data/mysql/mysqld

config_file="my.cnf"
if [ ! -f "$config_file" ]; then
  echo "MySQL config file '$config_file' not found in ${SCRIPT_DIR}."
  exit 1
fi
sudo cp "$config_file" /opt/data/mysql/conf/

# 如果之前有 mysql 容器，先删掉
if sudo docker ps -a --format '{{.Names}}' | grep -q "^mysql$"; then
  echo "Removing existing mysql container..."
  sudo docker rm -f mysql
fi

echo "Starting MySQL container..."
sudo docker run \
  --name mysql \
  --restart=always \
  -p 3306:3306 \
  -v /opt/data/mysql/mysqld:/var/run/mysqld \
  -v /opt/data/mysql/data:/var/lib/mysql \
  -v /opt/data/mysql/conf:/etc/mysql/conf.d \
  -e MYSQL_ROOT_PASSWORD="${MYSQL_PASSWORD}" \
  -d "mysql:${mysql_version}"

sudo docker network connect aurora mysql || true

echo "Waiting for MySQL to be ready..."
sleep 20

echo "Creating 'aurora' database (if not exists)..."
sudo docker exec -i mysql mysql -uroot -p"${MYSQL_PASSWORD}" \
  -e "CREATE DATABASE IF NOT EXISTS aurora CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"

if [ ! -f "${SCRIPT_DIR}/aurora.sql" ]; then
  echo "aurora.sql not found in ${SCRIPT_DIR}."
  exit 1
fi

echo "Initializing database from aurora.sql..."
sudo docker exec -i mysql mysql -uroot -p"${MYSQL_PASSWORD}" aurora < "${SCRIPT_DIR}/aurora.sql"

# -------------------------------
# 4. 启动 Redis
# -------------------------------
redis_version="7.0.13"
REDIS_PASSWORD="123456"

echo "Pulling Redis image: redis:${redis_version} ..."
sudo docker pull "redis:${redis_version}"

if sudo docker ps -a --format '{{.Names}}' | grep -q "^redis$"; then
  echo "Removing existing redis container..."
  sudo docker rm -f redis
fi

echo "Starting Redis container..."
sudo docker run --name redis \
  --restart=always \
  -p 6379:6379 \
  -d "redis:${redis_version}" \
  --requirepass "${REDIS_PASSWORD}"

sudo docker network connect aurora redis || true

# -------------------------------
# 5. 启动 RabbitMQ
# -------------------------------
rabbitmq_version="3.12.14"

echo "Pulling RabbitMQ image: rabbitmq:${rabbitmq_version}-management ..."
sudo docker pull "rabbitmq:${rabbitmq_version}-management"

if sudo docker ps -a --format '{{.Names}}' | grep -q "^rabbitmq$"; then
  echo "Removing existing rabbitmq container..."
  sudo docker rm -f rabbitmq
fi

echo "Starting RabbitMQ container..."
sudo docker run --name rabbitmq \
  --restart=always \
  -p 5672:5672 \
  -p 15672:15672 \
  -e RABBITMQ_DEFAULT_USER=guest \
  -e RABBITMQ_DEFAULT_PASS=guest \
  -d "rabbitmq:${rabbitmq_version}-management"

sudo docker network connect aurora rabbitmq || true

# -------------------------------
# 6. 启动 MinIO
# -------------------------------
echo "Pulling MinIO image..."
sudo docker pull minio/minio

if sudo docker ps -a --format '{{.Names}}' | grep -q "^minio$"; then
  echo "Removing existing minio container..."
  sudo docker rm -f minio
fi

echo "Creating MinIO directories..."
sudo mkdir -p /opt/data/minio/config
sudo mkdir -p /opt/data/minio/data

echo "Starting MinIO container..."
sudo docker run \
  -p 9000:9000 \
  -p 9090:9090 \
  --name minio \
  -d --restart=always \
  -e "MINIO_ACCESS_KEY=minioadmin" \
  -e "MINIO_SECRET_KEY=minioadmin" \
  -v /opt/data/minio/data:/data \
  -v /opt/data/minio/config:/root/.minio \
  minio/minio server /data \
  --console-address ":9090" \
  -address ":9000"

sudo docker network connect aurora minio || true

echo "Configuring MinIO default bucket..."
minio_bucket="aurora"
minio_myname="myminio"

# 注意：这里不使用 -t，以避免非交互环境报错
sudo docker exec -i minio mc alias set "${minio_myname}" http://minio:9000 minioadmin minioadmin || true
sudo docker exec -i minio mc mb "${minio_myname}/${minio_bucket}" || true
sudo docker exec -i minio mc anonymous set public "${minio_myname}/${minio_bucket}" || true

# -------------------------------
# 7. 启动后端 Spring Boot 服务
# -------------------------------
echo "Pulling OpenJDK 8 image..."
sudo docker pull eclipse-temurin:8-jdk

if [ ! -f "${SCRIPT_DIR}/aurora-springboot-0.0.1.jar" ]; then
  echo "Backend jar 'aurora-springboot-0.0.1.jar' not found in ${SCRIPT_DIR}."
  exit 1
fi

if sudo docker ps -a --format '{{.Names}}' | grep -q "^aurora_server$"; then
  echo "Removing existing aurora_server container..."
  sudo docker rm -f aurora_server
fi

minio_url="http://${public_ip}:8066/minio/"

echo "Starting backend service container (aurora_server)..."
sudo docker run -d \
  -p 8080:8080 \
  --name aurora_server \
  --restart=always \
  -v "${SCRIPT_DIR}":"${SCRIPT_DIR}" \
  -w "${SCRIPT_DIR}" \
  eclipse-temurin:8-jdk \
  java -jar \
    -Dupload.minio.bucketName="${minio_bucket}" \
    -Dupload.minio.url="${minio_url}" \
    "${SCRIPT_DIR}/aurora-springboot-0.0.1.jar"

sudo docker network connect aurora aurora_server || true

# -------------------------------
# 8. 启动 Nginx（前台 & 后台）
# -------------------------------
echo "Pulling Nginx image..."
sudo docker pull nginx:latest

if [ ! -f "${SCRIPT_DIR}/nginx.conf" ]; then
  echo "nginx.conf not found in ${SCRIPT_DIR}."
  exit 1
fi

# 确保前端目录存在（哪怕先是空目录）
mkdir -p "${SCRIPT_DIR}/blog_web"
mkdir -p "${SCRIPT_DIR}/admin_web"

if sudo docker ps -a --format '{{.Names}}' | grep -q "^aurora_nginx$"; then
  echo "Removing existing aurora_nginx container..."
  sudo docker rm -f aurora_nginx
fi

echo "Starting Nginx container (aurora_nginx)..."
sudo docker run -d \
  --name aurora_nginx \
  --restart=always \
  -p 8066:8066 \
  -v "${SCRIPT_DIR}/nginx.conf":/etc/nginx/nginx.conf:ro \
  -v "${SCRIPT_DIR}/blog_web":/usr/local/aurora-vue/blog:ro \
  -v "${SCRIPT_DIR}/admin_web":/usr/local/aurora-vue/admin:ro \
  nginx:latest

sudo docker network connect aurora aurora_nginx || true

# -------------------------------
# 9. 完成提示
# -------------------------------
echo "All services started successfully!"
echo "请在安全组中开放 8066, 15672, 9090 等端口（按需）"

echo "前台博客访问地址:  http://${public_ip}:8066/"
echo "后台管理访问地址: http://${public_ip}:8066/admin/"
echo "RabbitMQ 管理地址: http://${public_ip}:15672/ (guest / guest)"
echo "MinIO 控制台地址:  http://${public_ip}:9090/ (minioadmin / minioadmin)"
echo "后台管理默认账号密码: admin@163.com / 123456"

echo "作者：花未眠（http://www.linhaojun.top/）"
echo "原部署脚本作者：karl（https://kangxianghui.top/）"
echo "Amazon Linux 适配 By ChatGPT"

