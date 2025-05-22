#!/bin/bash
set -Eeuo pipefail

# 添加颜色定义到开头
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# 定义log函数，以便在trap中使用
log() { 
  local level="${1:-INFO}"
  local msg="${2:-}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # 修复颜色显示问题，避免直接输出原始ANSI序列
  case "$level" in
    "INFO")     printf "[%s] [INFO] %s\n" "$timestamp" "$msg" ;;
    "SUCCESS")  printf "[%s] [SUCCESS] %s\n" "$timestamp" "$msg" ;;
    "WARN")     printf "[%s] [WARN] %s\n" "$timestamp" "$msg" ;;
    "ERROR")    printf "[%s] [ERROR] %s\n" "$timestamp" "$msg" ;;
    *)          printf "[%s] [%s] %s\n" "$timestamp" "$level" "$msg" ;;
  esac
}

# 改进错误处理方式，更加健壮，避免小错误导致整个脚本终止
handle_error() {
  local exit_code=$?
  local line_no=$1
  
  # 记录错误但继续执行
  printf "[ERROR] 在第 %d 行发生错误 (退出码 %d)\n" "$line_no" "$exit_code" >&2
  
  # 除非是严重错误，否则不终止脚本执行
  if [ $exit_code -gt 1 ]; then
    log "ERROR" "发生严重错误，请检查上面的日志以获取详细信息"
  else
    log "WARN" "发生非严重错误，脚本将继续执行"
    return 0  # 返回成功状态，允许脚本继续执行
  fi
}

# 设置ERR trap，但允许脚本继续执行
trap 'handle_error $LINENO' ERR

# ===== 配置选项 =====
# 通用配置
PROJECT_PREFIX="${PROJECT_PREFIX:-gemini-key}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
MAX_PARALLEL_JOBS="${CONCURRENCY:-20}"  # 默认设置为20
TEMP_DIR="/tmp/gcp_script_$(date +%s)"

# Gemini模式配置
TIMESTAMP=$(date +%s)
# 修改随机字符生成方式，避免管道操作可能导致的SIGPIPE错误
RANDOM_CHARS=$(date +%s%N | sha256sum | head -c4)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
GEMINI_TOTAL_PROJECTS=175  # 默认项目数
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
AGGREGATED_KEY_FILE="aggregated_verbose_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-000000-AAAAAA-BBBBBB}"
VERTEX_PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
# 确保ENABLE_EXTRA_ROLES数组始终有默认值，避免未定义变量错误
ENABLE_EXTRA_ROLES=("${ENABLE_EXTRA_ROLES[@]:-roles/iam.serviceAccountUser roles/aiplatform.user}")

# 添加版本号和脚本信息
VERSION="1.0.0"
LAST_UPDATED="2025-05-22"

# ===== 风险提示与帮助文档 =====

# 风险与免责声明
WELCOME_BANNER(){
  clear
  echo -e "${RED}${BOLD}======================================================${NC}"
  echo -e "${RED}${BOLD}⚠️  重要风险提示  ⚠️${NC}"
  echo -e "${RED}${BOLD}======================================================${NC}"
  echo -e "${YELLOW}• 使用本脚本批量创建 ${BOLD}Gemini API${NC}${YELLOW} 项目/密钥，可能触发GCP风控，导致账号或项目被 ${BOLD}停用/封禁${NC}${YELLOW}。请谨慎操作。${NC}"
  echo -e "${YELLOW}• 使用 ${BOLD}Vertex AI${NC}${YELLOW} 需要有效结算账户，并会消耗 \$300 免费额度后开始 ${BOLD}实际计费${NC}${YELLOW}。请务必设置预算和警报。${NC}"
  echo -e "${YELLOW}• 本脚本仅作学习测试用途，作者及维护者不对任何费用或账号封禁承担责任。${NC}"
  echo -e "${RED}${BOLD}======================================================${NC}"
  echo ""
  echo -e "${CYAN}${BOLD}脚本将先显示帮助文档，阅读后方可继续。${NC}"
  echo ""
  read -p "按回车键查看帮助文档..." _
  show_help
  echo ""
  if ! ask_yes_no "我已阅读并理解所有风险，是否继续使用脚本?" "N"; then
    log "INFO" "用户取消，脚本终止。"
    exit 0
  fi
}

# ===== 初始化 =====
# 创建临时目录和密钥目录
mkdir -p "$TEMP_DIR"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
SECONDS=0

# ===== 工具函数 =====
# 日志函数已在文件开头定义

# 改进的指数退避重试函数
retry() {
  local max_attempts="$MAX_RETRY_ATTEMPTS"
  local cmd="$@"
  local attempt=1
  local timeout=5
  local error_log="${TEMP_DIR}/error_$(date +%s)_$RANDOM.log"

  until "$@"; do
    local error_code=$?
    (( attempt >= max_attempts )) && { 
      log "ERROR" "命令在 $max_attempts 次尝试后最终失败: $cmd"; 
      return $error_code; 
    }
    local delay=$(( attempt*10 + RANDOM%5 ))
    log "WARN" "重试 $attempt/$max_attempts: $cmd (等待 ${delay}s)"
    sleep $delay
    ((attempt++))
  done
}

# 检查依赖
require_cmd() { 
  command -v "$1" &>/dev/null || { 
    log "ERROR" "缺少依赖: $1"; exit 1; 
  }; 
}

# 交互确认
ask_yes_no() {
  local prompt="$1" default=${2:-N} resp
  if [[ "$default" == "N" ]]; then
    [[ -t 0 ]] && read -r -p "$prompt [y/N]: " resp
  else
    [[ -t 0 ]] && read -r -p "$prompt [Y/n]: " resp
  fi
  resp=${resp:-$default}
  [[ $resp =~ ^[Yy]$ ]]
}

# 选项提示
prompt_choice() {
  local prompt="$1" opts="$2" def="$3" ans
  [[ -t 0 ]] && read -r -p "$prompt [$opts] (默认 $def) " ans
  ans=${ans:-$def}
  [[ $opts =~ (^|\|)$ans($|\|) ]] || ans=$def
  printf '%s' "$ans"
}

# 生成唯一后缀
unique_suffix() { 
  date +%s%N | sha256sum | head -c6
}

# 新增: 安全检测服务是否已启用 (兼容 pipefail)
is_service_enabled() {
  local proj="$1" svc="$2"
  # 保存当前 errexit 与 pipefail 状态
  local _errexit_set=0 _pipefail_set=0
  if set -o | grep -q "errexit.*on"; then _errexit_set=1; fi
  if set -o | grep -q "pipefail.*on"; then _pipefail_set=1; fi
  set +e +o pipefail
  gcloud services list --enabled --project="$proj" \
        --filter="$svc" --format='value(config.name)' 2>/dev/null | grep -q .
  local rc=$?
  [ $_errexit_set -eq 1 ] && set -e
  [ $_pipefail_set -eq 1 ] && set -o pipefail
  return $rc
}

# ---------- 通用安全辅助函数 ----------
with_no_err() {
  local _e=$(set +o | grep errexit)
  local _p=$(set +o | grep pipefail)
  set +e +o pipefail
  "$@"; local rc=$?
  eval "$_e"; eval "$_p"
  return $rc
}

safe_mapfile() {
  local __arr=$1; shift
  with_no_err mapfile -t "$__arr" < <("$@") || return 1
  return 0
}

# 生成新项目ID
new_project_id() { 
  local prefix="$1"
  echo "${prefix}-$(unique_suffix)"
}

# 检查环境
check_env() {
  require_cmd gcloud
  gcloud config list account --quiet &>/dev/null || { 
    log "ERROR" "请先运行 gcloud init"; 
    exit 1; 
  }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || { 
    log "ERROR" "请先 gcloud auth login"; 
    exit 1; 
  }
}

# 配额检查
check_quota() {
  log "INFO" "检查GCP项目创建配额..."
  local current_project=$(gcloud config get-value project 2>/dev/null)
  if [ -z "$current_project" ]; then 
    log "WARN" "无法获取当前GCP项目ID，无法准确检查配额。将跳过配额检查。"
    return 0
  fi

  local projects_quota
  local quota_cmd
  local quota_output
  local error_msg

  quota_cmd="gcloud services quota list --service=cloudresourcemanager.googleapis.com --consumer=projects/$current_project --filter='metric=cloudresourcemanager.googleapis.com/project_create_requests' --format=json 2>${TEMP_DIR}/quota_error.log"
  if quota_output=$(retry "$quota_cmd"); then
      projects_quota=$(echo "$quota_output" | grep -oP '(?<="effectiveLimit": ")[^"]+' | head -n 1)
  else
    log "INFO" "GA services quota list 命令失败，尝试 alpha services quota list..."
    quota_cmd="gcloud alpha services quota list --service=cloudresourcemanager.googleapis.com --consumer=projects/$current_project --filter='metric(cloudresourcemanager.googleapis.com/project_create_requests)' --format=json 2>${TEMP_DIR}/quota_error.log"
    if quota_output=$(retry "$quota_cmd"); then
        projects_quota=$(echo "$quota_output" | grep -oP '(?<="INT64": ")[^"]+' | head -n 1)
    else
        error_msg=$(cat "${TEMP_DIR}/quota_error.log" 2>/dev/null)
        rm -f "${TEMP_DIR}/quota_error.log"
        log "WARN" "无法获取配额信息 (尝试GA和alpha命令均失败): ${error_msg:-'命令执行失败'}"
        log "WARN" "将使用默认设置继续，但强烈建议手动检查配额，避免失败。"
        if ask_yes_no "无法检查配额，是否继续执行? [y/N]: " "N"; then
          return 0
        else
          log "INFO" "操作已取消。"
          return 1
        fi
    fi
  fi
  rm -f "${TEMP_DIR}/quota_error.log"

  if [ -z "$projects_quota" ] || ! [[ "$projects_quota" =~ ^[0-9]+$ ]]; then
    log "WARN" "无法从输出中准确提取项目创建配额值。将使用默认设置继续。"
    return 0
  fi

  local quota_limit=$projects_quota
  log "INFO" "检测到项目创建配额限制大约为: $quota_limit"
  
  if [ "$GEMINI_TOTAL_PROJECTS" -gt "$quota_limit" ]; then
    log "WARN" "计划创建的Gemini项目数($GEMINI_TOTAL_PROJECTS) 大于检测到的配额限制($quota_limit)"
    echo "选项:"
    echo "1. 继续尝试创建 $GEMINI_TOTAL_PROJECTS 个项目 (很可能部分失败)"
    echo "2. 调整为创建 $quota_limit 个项目 (更符合配额限制)"
    echo "3. 取消操作"
    
    read -p "请选择 [1/2/3]: " quota_option
    case $quota_option in
      1) log "INFO" "将尝试创建 $GEMINI_TOTAL_PROJECTS 个项目，请注意配额限制。" ;;
      2) GEMINI_TOTAL_PROJECTS=$quota_limit; log "INFO" "已调整计划，将创建 $GEMINI_TOTAL_PROJECTS 个项目" ;;
      3|*) log "INFO" "操作已取消"; return 1 ;;
    esac
  else 
    log "SUCCESS" "计划创建的项目数($GEMINI_TOTAL_PROJECTS) 在检测到的配额限制($quota_limit)之内。"
  fi
  return 0
}

# 启用服务API
enable_services() {
  local proj=$1
  shift
  local svc
  
  log "INFO" "为项目 $proj 启用必要的API服务..."
  
  # 如果没有传入特定服务，使用默认必要服务列表
  if [ $# -eq 0 ]; then
    local default_services=(
      "aiplatform.googleapis.com"      # Vertex AI API
      "iam.googleapis.com"             # Identity and Access Management API
      "iamcredentials.googleapis.com"  # IAM Service Account Credentials API
      "cloudresourcemanager.googleapis.com" # Resource Manager API
    )
    set -- "${default_services[@]}"
  fi
  
  for svc in "$@"; do
    log "INFO" "检查并启用服务: $svc"
    if is_service_enabled "$proj" "$svc"; then
      log "INFO" "服务 $svc 已经启用"
      continue
    fi
    
    if retry gcloud services enable "$svc" --project="$proj" --quiet; then
      log "SUCCESS" "成功启用服务: $svc"
    else
      log "ERROR" "无法启用服务 $svc，这可能导致功能受限"
    fi
  done
  
  # 验证关键服务是否已启用
  log "INFO" "验证关键服务是否已成功启用..."
  local all_enabled=true
  for svc in "$@"; do
    if ! is_service_enabled "$proj" "$svc"; then
      log "ERROR" "服务 $svc 验证失败，未成功启用"
      all_enabled=false
    fi
  done
  
  if $all_enabled; then
    log "SUCCESS" "所有必要服务已成功启用"
    return 0
  else
    log "WARN" "部分服务可能未成功启用，这可能影响后续操作"
    return 1
  fi
}

# 结算账户管理
link_billing()   { retry gcloud beta billing projects link   "$1" --billing-account="$BILLING_ACCOUNT" --quiet; }
unlink_billing() { retry gcloud beta billing projects unlink "$1" --quiet; }

# 列出开放结算账户
list_open_billing() {
  gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' \
    | awk '{printf "%s %s\n", $1, substr($0,index($0,$2))}' | sed 's|billingAccounts/||'
}

# 选择结算账户
choose_billing() {
  mapfile -t ACCS < <(list_open_billing)
  (( ${#ACCS[@]} == 0 )) && { 
    log "ERROR" "未找到 OPEN 结算账户"; 
    exit 1; 
  }
  if (( ${#ACCS[@]} == 1 )); then 
    BILLING_ACCOUNT="${ACCS[0]%% *}"; 
    return; 
  fi
  printf "可用结算账户：\n"
  local i
  for i in "${!ACCS[@]}"; do 
    printf "  %d) %s\n" "$i" "${ACCS[$i]}"
  done
  local sel
  while true; do
    read -r -p "请输入编号 [0-$((${#ACCS[@]}-1))] (默认 0): " sel
    sel=${sel:-0}
    [[ $sel =~ ^[0-9]+$ ]] && (( sel>=0 && sel < ${#ACCS[@]} )) && break
    echo "无效输入，请重新输入数字。"
  done
  BILLING_ACCOUNT="${ACCS[$sel]%% *}"
}

# 解析JSON (从message.sh)
parse_json() {
  local json="$1"
  local field="$2"
  local value=""

  if [ -z "$json" ]; then return 1; fi

  case "$field" in
    ".keyString")
      value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p')
      ;;
    ".[0].name")
      value=$(echo "$json" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -n 1)
      ;;
    *)
      local field_name=$(echo "$field" | tr -d '.["]')
      value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*\")[^\"]*" 2>/dev/null)
      if [ -z "$value" ]; then
           value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*)[^,\s\}]+" 2>/dev/null | head -n 1)
      fi
      ;;
  esac

  if [ -n "$value" ]; then
    echo "$value"
    return 0
  else
    log "ERROR" "parse_json: 备用方法未能提取有效值 '$field'"
    return 1
  fi
}

# 写入密钥到文件 (从message.sh)
write_keys_to_files() {
    local api_key="$1"

    if [ -z "$api_key" ]; then
        log "ERROR" "write_keys_to_files called with empty API key!"
        return
    fi

    # 使用文件锁确保写入原子性
    (
        flock 200
        # 写入纯密钥文件 (只有密钥，每行一个)
        echo "$api_key" >> "$PURE_KEY_FILE"
        # 写入逗号分隔文件 (只有密钥，用逗号分隔)
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
    ) 200>"${TEMP_DIR}/key_files.lock" # 使用一个统一的锁文件
}

# 进度条显示
show_progress() {
    local completed=$1
    local total=$2
    if [ $total -le 0 ]; then 
      printf "\r%-80s" " "
      printf "\r[总数无效: %d]" "$total"
      return
    fi
    # 确保 completed 不超过 total
    if [ $completed -gt $total ]; then completed=$total; fi

    local percent=$((completed * 100 / total))
    local completed_chars=$((percent * 50 / 100))
    if [ $completed_chars -lt 0 ]; then completed_chars=0; fi
    if [ $completed_chars -gt 50 ]; then completed_chars=50; fi
    local remaining_chars=$((50 - completed_chars))
    local progress_bar=$(printf "%${completed_chars}s" "" | tr ' ' '#')
    local remaining_bar=$(printf "%${remaining_chars}s" "")
    printf "\r%-80s" " "
    printf "\r[%s%s] %d%% (%d/%d)" "$progress_bar" "$remaining_bar" "$percent" "$completed" "$total"
}

# 从vertex.sh中的服务账号功能
list_cloud_keys()  { 
  # 添加错误处理
  gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)' 2>/dev/null | sed 's|.*/||' || echo ""
}
latest_cloud_key() { gcloud iam service-accounts keys list --iam-account="$1" --limit=1 --sort-by=~createTime --format='value(name)' | sed 's|.*/||'; }

# 生成服务账号密钥
gen_key() {
  local proj=$1 sa=$2 ts=$(date +%Y%m%d-%H%M%S)
  local key_file="${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-${ts}.json"
  
  # 确保密钥目录存在
  mkdir -p "$KEY_DIR" 2>/dev/null
  
  # 添加错误处理和返回值
  if ! retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa" --project="$proj" --quiet; then
    log "ERROR" "无法为服务账号 $sa 创建密钥"
    return 1
  fi
  
  chmod 600 "$key_file"
  log "INFO" "[$proj] 新JSON格式密钥已创建 → $key_file"
  log "INFO" "此JSON密钥文件可直接用于访问Vertex AI API"
  return 0
}

# 置备服务账号
provision_sa() {
  local proj=$1 
  local sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
  
  log "INFO" "开始为项目 $proj 配置服务账号 $sa"
  
  # 确保必要的API已启用
  enable_services "$proj"
  
  # 检查并创建服务账号
  if gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null; then
    log "INFO" "服务账号 $sa 已存在"
  else
    log "INFO" "创建新服务账号 $sa"
    if retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet; then
      log "SUCCESS" "成功创建服务账号 $sa"
    else
      log "ERROR" "无法创建服务账号，请检查IAM权限"
      return 1
    fi
  fi
  
  # 分配所需角色
  local roles=(
    "roles/aiplatform.admin"          # Vertex AI Administrator (必备权限)
    "roles/iam.serviceAccountUser"    # Service Account User
    "roles/iam.serviceAccountTokenCreator"  # Token Creator (可能需要用于生成访问令牌)
    "roles/aiplatform.user"           # Vertex AI User
  )
  
  # 添加自定义角色
  roles+=("${ENABLE_EXTRA_ROLES[@]}")
  
  # 去重
  roles=($(echo "${roles[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
  
  log "INFO" "为服务账号分配以下角色: ${roles[*]}"
  local binding_failures=0
  
  for r in "${roles[@]}"; do 
    log "INFO" "分配角色: $r"
    if retry gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --quiet; then
      log "SUCCESS" "成功将角色 $r 分配给服务账号 $sa"
    else
      log "ERROR" "无法将角色 $r 分配给服务账号，这可能导致权限不足"
      ((binding_failures++))
    fi
  done
  
  if [ $binding_failures -gt 0 ]; then
    log "WARN" "有 $binding_failures 个角色分配失败，这可能导致API调用权限不足"
  else
    log "SUCCESS" "所有角色分配成功"
  fi
  
  # 验证权限设置
  log "INFO" "验证服务账号权限..."
  if gcloud projects get-iam-policy "$proj" --format="json" | grep -q "$sa"; then
    log "SUCCESS" "服务账号 $sa 权限配置已验证"
    
    # 为服务账号创建密钥
    log "INFO" "为服务账号 $sa 创建密钥..."
    if ! gen_key "$proj" "$sa"; then
      log "ERROR" "为服务账号 $sa 创建密钥失败"
      return 1
    fi
    
    return 0
  else
    log "WARN" "无法验证服务账号权限，这可能导致后续使用API时出现权限问题"
    return 1
  fi
}

# 使用Vertex API创建项目
create_vertex_project() {
  local pid=$(new_project_id "$VERTEX_PROJECT_PREFIX")
  log "INFO" "[$BILLING_ACCOUNT] 创建项目 $pid"
  
  # 创建项目
  if ! retry gcloud projects create "$pid" --name="$pid" --quiet; then
    log "ERROR" "创建项目 $pid 失败"
    return 1
  fi
  log "SUCCESS" "项目 $pid 创建成功"
  
  # 关联结算账户
  if ! link_billing "$pid"; then
    log "ERROR" "为项目 $pid 关联结算账户 $BILLING_ACCOUNT 失败"
    log "WARN" "没有结算账户，API将无法正常工作"
    if ask_yes_no "是否继续设置项目(没有结算账户API可能无法工作)? [y/N]: " "N"; then
      log "INFO" "继续设置项目，但请注意API可能无法工作"
    else
      log "INFO" "取消项目设置"
      return 1
    fi
  else
    log "SUCCESS" "已成功将项目 $pid 关联到结算账户 $BILLING_ACCOUNT"
  fi
  
  # 启用所有必要的API
  enable_services "$pid"
  
  # 配置服务账号和权限
  if ! provision_sa "$pid"; then
    log "ERROR" "为项目 $pid 设置服务账号失败"
    return 1
  fi
  
  # 添加缺失的生成密钥功能
  local sa="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
  if ! gen_key "$pid" "$sa"; then
    log "ERROR" "为项目 $pid 生成密钥失败"
    return 1
  fi
  
  log "SUCCESS" "项目 $pid 完成所有设置"
  return 0
}

# 显示Vertex项目状态
show_vertex_status() {
  echo ""
  echo -e "${CYAN}${BOLD}===== 当前项目状态 =====${NC}"
  echo -e "结算账户: ${YELLOW}$BILLING_ACCOUNT${NC}"
  echo ""
  
  # 获取所有已启用API的项目
  mapfile -t ALL_PROJECTS < <(gcloud projects list --format='value(projectId)' 2>/dev/null || echo "")
  
  if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then
    echo "未找到任何项目"
    return
  fi
  
  # 查找已经设置了Vertex的项目
  local vertex_projects=()
  local vertex_count=0
  
  echo -e "${BOLD}项目状态:${NC}"
  printf "%-30s | %-12s | %-12s | %-10s | %s\n" "项目ID" "结算账户" "Vertex API" "服务账号" "密钥文件"
  printf "%s\n" "$(printf '=%.0s' {1..80})"
  
  for proj in "${ALL_PROJECTS[@]}"; do
    # 检查项目是否启用了Vertex API
    if is_service_enabled "$proj" 'aiplatform.googleapis.com'; then
      # 项目启用了Vertex API
      local api_status="${GREEN}已启用${NC}"
      vertex_projects+=("$proj")
      ((vertex_count++))
      
      # 检查服务账号状态
      local sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
      local sa_status="${RED}未创建${NC}"
      if gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null; then
        sa_status="${GREEN}已创建${NC}"
      fi
      
      # 检查密钥文件
      local keycount=$(ls -1 ${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-*.json 2>/dev/null | wc -l || echo "0")
      local key_status="${YELLOW}$keycount${NC}"
      
      # 检查结算账户
      local billing_status=$(gcloud beta billing projects describe "$proj" --format='value(billingAccountName)' 2>/dev/null | sed 's|billingAccounts/||' || echo "未绑定")
      
      # 打印项目信息
      printf "%-30s | %-12s | %-25s | %-23s | %s\n" "$proj" "$billing_status" "$api_status" "$sa_status" "$key_status"
    fi
  done
  
  if [ $vertex_count -eq 0 ]; then
    echo "未找到启用了Vertex API的项目"
  fi
  
  echo ""
  echo -e "${CYAN}密钥文件位置:${NC} $KEY_DIR"
  echo -e "${CYAN}启用Vertex API的项目数:${NC} $vertex_count"
  echo ""
}

# 处理Vertex账单
handle_vertex_billing() {
  local billing_acc="$1"
  log "INFO" "======================================================" 
  log "INFO" "处理结算账户: $billing_acc"
  log "INFO" "======================================================"
  
  # ===== 步骤1: 检查已绑定到此结算账户的项目 =====
  log "INFO" "获取绑定到结算账户 $billing_acc 的项目列表..."
  
  # 直接获取所有项目，然后筛选符合条件的
  log "INFO" "获取所有项目列表，并筛选结算账户..."
  local all_projects_output
  all_projects_output=$(gcloud projects list --format="value(projectId)" 2>/dev/null || echo "")
  
  # 检查是否成功获取项目列表
  if [ -z "$all_projects_output" ]; then
    log "WARN" "无法获取项目列表，假设没有关联项目"
    BILLING_PROJECTS=()
  else
    mapfile -t ALL_PROJECTS < <(echo "$all_projects_output")
    log "INFO" "找到 ${#ALL_PROJECTS[@]} 个项目，检查它们的结算账户..."
    
    # 创建一个空数组存储匹配的项目
    BILLING_PROJECTS=()
    
    # 对每个项目检查其结算账户
    for proj in "${ALL_PROJECTS[@]}"; do
      local proj_billing
      proj_billing=$(gcloud beta billing projects describe "$proj" --format="value(billingAccountName)" 2>/dev/null || echo "")
      
      # 提取结算账户ID部分并比较
      if [[ "$proj_billing" == *"$billing_acc"* ]]; then
        BILLING_PROJECTS+=("$proj")
        log "INFO" "项目 $proj 使用结算账户 $billing_acc"
      fi
    done
  fi
  
  # 计算项目数量
  local account_project_count=${#BILLING_PROJECTS[@]}
  
  log "INFO" "结算账户 $billing_acc 已绑定 $account_project_count / $MAX_PROJECTS_PER_ACCOUNT 个项目"
  
  if [ $account_project_count -gt 0 ]; then
    echo "已绑定的项目:"
    for ((i=0; i<account_project_count && i<10; i++)); do
      echo " - ${BILLING_PROJECTS[$i]}"
    done
    if [ $account_project_count -gt 10 ]; then
      echo " - ... 以及其他 $((account_project_count - 10)) 个项目"
    fi
  else
    log "INFO" "结算账户 $billing_acc 目前没有绑定任何项目"
  fi
  
  # ===== 步骤2: 用户选择操作方式 =====
  echo ""
  echo "请选择操作方式:"
  echo "1. 在现有项目上创建Vertex AI密钥"
  echo "2. 创建新项目并生成Vertex AI密钥"
  echo "3. 同时处理现有项目和创建新项目"
  echo "0. 返回上一级菜单"
  echo ""
 
  # 使用循环处理用户输入，确保输入有效
  local operation_choice=""
  while true; do
    read -p "请选择 [0-3]: " operation_choice
    
    # 检查输入是否为有效选项
    if [[ "$operation_choice" =~ ^[0-3]$ ]]; then
      break  # 输入有效，退出循环
    else
      echo "无效选项: '$operation_choice'，请输入0-3之间的数字"
    fi
  done
  
  case $operation_choice in
    1) 
      if [ $account_project_count -eq 0 ]; then
        log "WARN" "此结算账户下没有现有项目，无法执行此操作"
        if ask_yes_no "是否切换到创建新项目? [y/N]: " "N"; then
          operation_choice=2
        else
          return 0
        fi
      else
        handle_existing_projects "$billing_acc"
      fi
      ;;
    2) 
      handle_new_projects "$billing_acc"
      ;;
    3)
      if [ $account_project_count -eq 0 ]; then
        log "WARN" "此结算账户下没有现有项目，将只创建新项目"
      else
        handle_existing_projects "$billing_acc"
      fi
      handle_new_projects "$billing_acc"
      ;;
    0|"") 
      log "INFO" "操作已取消，返回上一级"
      return 0
      ;;
    *)
      log "ERROR" "无效选项: $operation_choice"
      return 1
      ;;
  esac
  
  show_vertex_status
}

# 添加处理现有项目的函数
handle_existing_projects() {
  local billing_acc="$1"
  
  # 获取此结算账户下的项目，直接使用BILLING_PROJECTS数组
  # 这个数组是在handle_vertex_billing中填充的
  local account_project_count=${#BILLING_PROJECTS[@]}
  
  if [ $account_project_count -eq 0 ]; then
    log "WARN" "此结算账户下没有现有项目，无法处理"
    return 1
  fi
  
  # 让用户选择要处理的项目
  echo ""
  log "INFO" "请选择要处理的项目:"
  echo "0. 处理所有项目"
  for ((i=0; i<account_project_count; i++)); do
    echo "$((i+1)). ${BILLING_PROJECTS[$i]}"
  done
  echo ""
  
  local proj_num_choice=""
  while true; do
    read -p "请输入项目编号 [0-$account_project_count]: " proj_num_choice
    
    # 如果输入为空，提示用户重新输入
    if [[ -z "$proj_num_choice" ]]; then
      echo "输入不能为空，请重新输入项目编号"
      continue
    fi
    
    # 验证输入的有效性
    if [[ "$proj_num_choice" == "0" ]]; then
      break
    elif [[ "$proj_num_choice" =~ ^[0-9]+$ ]] && [ "$proj_num_choice" -ge 1 ] && [ "$proj_num_choice" -le $account_project_count ]; then
      break
    else
      echo "无效的项目编号: $proj_num_choice，请重新输入"
    fi
  done
  
  local selected_projects=()
  if [[ "$proj_num_choice" == "0" ]]; then
    log "INFO" "将处理所有 $account_project_count 个项目"
    selected_projects=("${BILLING_PROJECTS[@]}")
  else
    selected_projects=("${BILLING_PROJECTS[$((proj_num_choice-1))]}")
    log "INFO" "将处理项目: ${selected_projects[0]}"
  fi
  
  # 警告用户操作将产生费用
  echo ""
  show_warning "
  您选择处理以下项目:
  $(printf '\n  • %s' "${selected_projects[@]}")
  
  此操作将:
  1. 检查并启用 Vertex AI API 和必要服务（如未启用）
  2. 检查并按需创建服务账号和API密钥
  3. 可能产生实际费用
  
  请确保您了解相关费用和风险。
  " || return 1
  
  # 处理选定的项目
  local total_projects=${#selected_projects[@]}
  local current=0
  local success_count=0
  
  log "INFO" "开始处理 $total_projects 个现有项目..."
  
  # 处理每个选定的项目
  for proj in "${selected_projects[@]}"; do
    ((current++))
    log "INFO" "[$current/$total_projects] 正在处理项目: $proj"
    
    # 确保这个项目存在且可访问
    if ! gcloud projects describe "$proj" &>/dev/null; then
      log "ERROR" "无法访问项目 $proj，请检查项目ID和权限"
      continue
    fi
    
    # 1. 首先检查项目是否已启用Vertex AI API
    local api_enabled=false
    if is_service_enabled "$proj" 'aiplatform.googleapis.com'; then
      log "INFO" "项目 $proj 已启用 Vertex AI API"
      api_enabled=true
    else
      log "INFO" "项目 $proj 尚未启用 Vertex AI API，正在启用..."
      if enable_services "$proj"; then
        log "SUCCESS" "成功为项目 $proj 启用所需API"
        api_enabled=true
      else
        log "ERROR" "为项目 $proj 启用API失败"
        continue
      fi
    fi
    
    # 2. 检查服务账号状态
    local sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
    local sa_exists=false
    if gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null; then
      log "INFO" "服务账号 $sa 已存在"
      sa_exists=true
    else
      log "INFO" "服务账号 $sa 不存在，是否创建?"
      if ask_yes_no "是否为项目 $proj 创建服务账号? [y/N]: " "N"; then
        # 只配置服务账号，不生成密钥
        if retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet; then
          log "SUCCESS" "成功创建服务账号 $sa"
          sa_exists=true
          
          # 分配所需角色
          local roles=(
            "roles/aiplatform.admin"          # Vertex AI Administrator (必备权限)
            "roles/iam.serviceAccountUser"    # Service Account User
            "roles/iam.serviceAccountTokenCreator"  # Token Creator (可能需要用于生成访问令牌)
            "roles/aiplatform.user"           # Vertex AI User
          )
          
          # 添加自定义角色
          roles+=("${ENABLE_EXTRA_ROLES[@]}")
          
          # 去重
          roles=($(echo "${roles[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
          
          log "INFO" "为服务账号分配以下角色: ${roles[*]}"
          local binding_failures=0
          
          for r in "${roles[@]}"; do 
            log "INFO" "分配角色: $r"
            if retry gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --quiet; then
              log "SUCCESS" "成功将角色 $r 分配给服务账号 $sa"
            else
              log "ERROR" "无法将角色 $r 分配给服务账号，这可能导致权限不足"
              ((binding_failures++))
            fi
          done
        else
          log "ERROR" "为项目 $proj 创建服务账号失败"
          continue
        fi
      else
        log "INFO" "跳过为项目 $proj 创建服务账号"
        continue
      fi
    fi
    
    # 3. 检查现有密钥并管理
    if $sa_exists; then
      # 添加错误处理，防止获取密钥列表失败导致脚本崩溃
      local existing_keys=()
      
      # 尝试获取密钥列表，如果失败则输出警告但继续执行
      if ! safe_mapfile existing_keys list_cloud_keys "$sa"; then
        log "WARN" "获取服务账号 $sa 的密钥列表失败，假定没有现有密钥"
        existing_keys=()
      fi
      
      local key_count=${#existing_keys[@]}
      
      if [ $key_count -gt 0 ]; then
        log "INFO" "服务账号 $sa 已有 $key_count 个密钥"
        echo "现有密钥:"
        for key in "${existing_keys[@]}"; do
          echo " - $key"
        done
        
        echo ""
        echo "密钥操作选项:"
        echo "1. 保留现有密钥并创建新密钥"
        echo "2. 删除所有现有密钥后创建新密钥"
        echo "3. 不创建新密钥，保持现状"
        
        local key_op=""
        while true; do
          read -p "请选择操作 [1-3]: " key_op
          
          if [[ "$key_op" =~ ^[1-3]$ ]]; then
            break
          else
            echo "无效选项: '$key_op'，请输入1-3之间的数字"
          fi
        done
        
        case $key_op in
          1)
            log "INFO" "保留现有密钥并创建新密钥"
            ;;
          2)
            log "INFO" "删除所有现有密钥后创建新密钥"
            for key in "${existing_keys[@]}"; do
              if retry gcloud iam service-accounts keys delete "$key" --iam-account="$sa" --quiet; then
                log "SUCCESS" "已删除密钥: $key"
              else
                log "ERROR" "删除密钥 $key 失败"
              fi
            done
            ;;
          3)
            log "INFO" "不创建新密钥，保持现状"
            continue
            ;;
        esac
      else
        log "INFO" "服务账号 $sa 没有现有密钥"
      fi
      
      # 创建新密钥
      if gen_key "$proj" "$sa"; then
        log "SUCCESS" "成功为项目 $proj 生成新密钥"
        ((success_count++))
      else
        log "ERROR" "为项目 $proj 生成密钥失败"
      fi
    fi
  done
  
  log "INFO" "已完成 $total_projects 个现有项目的处理，成功: $success_count，失败: $((total_projects - success_count))"
  return 0
}

# 添加创建新项目的函数
handle_new_projects() {
  local billing_acc="$1"
  
  # 直接使用BILLING_PROJECTS数组(已在handle_vertex_billing中生成)
  local account_project_count=${#BILLING_PROJECTS[@]}
  
  log "INFO" "结算账户 $billing_acc 当前已绑定 $account_project_count 个项目"
  
  # 计算可创建的最大项目数
  local max_new_projects=$((MAX_PROJECTS_PER_ACCOUNT - account_project_count))
  
  if [ $max_new_projects -le 0 ]; then
    log "WARN" "结算账户 $billing_acc 已达到最大项目数量 ($MAX_PROJECTS_PER_ACCOUNT)，无法创建新项目"
    return 1
  fi
  
  # 提示用户选择要创建的项目数量
  log "INFO" "结算账户最多可以关联 $MAX_PROJECTS_PER_ACCOUNT 个项目"
  log "INFO" "当前已关联 $account_project_count 个项目，还可以创建 $max_new_projects 个新项目"
  
  local num_to_create=""
  while true; do
    read -p "请输入要创建的新项目数量 [1-$max_new_projects]: " num_to_create
    
    # 如果输入为空，提示用户重新输入
    if [[ -z "$num_to_create" ]]; then
      echo "输入不能为空，请重新输入数量"
      continue
    fi
    
    # 验证输入的有效性
    if [[ "$num_to_create" =~ ^[0-9]+$ ]] && [ "$num_to_create" -ge 1 ] && [ "$num_to_create" -le $max_new_projects ]; then
      break
    else
      echo "无效的项目数量: $num_to_create，应在1-$max_new_projects之间，请重新输入"
    fi
  done
  
  # 让用户自定义项目前缀
  local default_prefix="vertex-$(date +%m%d)"
  local custom_prefix=""
  read -p "请输入项目前缀 (默认: $default_prefix): " custom_prefix
  custom_prefix=${custom_prefix:-$default_prefix}
  
  # 验证前缀格式
  if ! [[ "$custom_prefix" =~ ^[a-z][a-z0-9-]{0,28}$ ]]; then
    log "WARN" "项目前缀必须以小写字母开头，只能包含小写字母、数字和连字符"
    log "WARN" "将使用默认前缀: $default_prefix"
    custom_prefix=$default_prefix
  fi
  
  # 确认创建
  echo ""
  show_warning "
  您将在结算账户 $billing_acc 下创建 $num_to_create 个新项目
  项目前缀: $custom_prefix
  
  每个项目将:
  1. 启用 Vertex AI API 等服务
  2. 创建服务账号和API密钥
  3. 开始根据使用量计费
  
  请确保您了解相关费用和风险。
  " || return 1
  
  # 开始创建项目
  local created=0
  local success_count=0
  log "INFO" "开始创建 $num_to_create 个新项目..."
  
  # 临时保存原来的前缀
  local original_prefix=$VERTEX_PROJECT_PREFIX
  VERTEX_PROJECT_PREFIX=$custom_prefix
  
  while (( created < num_to_create )); do 
    # 将create_vertex_project的执行放在子shell中，防止错误传播
    if (create_vertex_project); then
      ((success_count++))
    else
      log "WARN" "项目创建失败，但将继续创建剩余项目"
    fi
    ((created++))
    show_progress "$created" "$num_to_create"
  done
  
  # 恢复原来的前缀
  VERTEX_PROJECT_PREFIX=$original_prefix
  
  echo # 换行，结束进度条
  log "SUCCESS" "已完成 $num_to_create 个新项目的创建，成功: $success_count，失败: $((num_to_create - success_count))"
  
  # 添加成功后的使用提示
  log "INFO" "所有服务账号密钥已保存到: $KEY_DIR 目录"
  log "INFO" "使用这些密钥可以通过 API 访问 Vertex AI 服务"
  log "WARN" "请记住，使用 API 会产生实际费用，请谨慎使用"
  
  return 0
}

# Vertex API 主函数
vertex_main() {
  SECONDS=0
  check_env
  
  log "INFO" "======================================================"
  log "INFO" "功能: 创建 Vertex AI API 密钥"
  log "INFO" "======================================================"
  
  mapfile -t ALL_BILLING < <(list_open_billing)
  local billing_count=${#ALL_BILLING[@]}
  
  if [ $billing_count -eq 0 ]; then
    log "ERROR" "未找到任何开放结算账户，无法继续操作"
    echo -e "${RED}Vertex AI 需要有效的结算账户才能使用!${NC}"
    echo "请先设置一个有效的结算账户，然后再尝试使用此功能。"
    return 1
  elif [ $billing_count -eq 1 ]; then
    BILLING_ACCOUNT="${ALL_BILLING[0]%% *}"
    log "INFO" "只检测到一个开放结算账户: $BILLING_ACCOUNT"
    
    # 再次确认使用结算账户
    echo ""
    show_warning "
    您将使用结算账户: $BILLING_ACCOUNT
    
    此操作将创建实际的 GCP 资源并产生费用。
    " || return 1
    
    handle_vertex_billing "$BILLING_ACCOUNT"
  else
    log "INFO" "检测到 $billing_count 个开放结算账户:"
    for i in "${!ALL_BILLING[@]}"; do
      echo "  $((i+1)). ${ALL_BILLING[$i]}"
    done
    
    echo ""
    echo "操作选项:"
    echo "1. 仅处理一个选定的结算账户"
    echo "2. 批量处理所有结算账户"
    echo "0. 返回主菜单"
    
    # 使用循环处理用户输入，确保输入有效
    local mode=""
    while true; do
      read -p "请选择操作 [0-2]: " mode
      
      # 检查输入是否为有效选项
      if [[ "$mode" =~ ^[0-2]$ ]]; then
        break  # 输入有效，退出循环
      else
        echo "无效选项: '$mode'，请输入0-2之间的数字"
      fi
    done
    
    case $mode in
      1) 
        echo ""
        local acc_num=""
        while true; do
          read -p "请输入要处理的结算账户编号 [1-$billing_count]: " acc_num
          
          # 检查输入是否为有效选项
          if [[ "$acc_num" =~ ^[0-9]+$ ]] && [ "$acc_num" -ge 1 ] && [ "$acc_num" -le $billing_count ]; then
            break  # 输入有效，退出循环
          else
            echo "无效的结算账户编号: '$acc_num'，请输入1-$billing_count之间的数字"
          fi
        done
        
        BILLING_ACCOUNT="${ALL_BILLING[$((acc_num-1))]%% *}"
        
        # 再次确认使用结算账户
        echo ""
        show_warning "
        您将使用结算账户: $BILLING_ACCOUNT
        
        此操作将创建实际的 GCP 资源并产生费用。
        " || return 1
        
        handle_vertex_billing "$BILLING_ACCOUNT"
        ;;
      2)
        log "INFO" "将依次处理所有 $billing_count 个结算账户"
        
        # 再次确认使用所有结算账户
        echo ""
        show_warning "
        您将使用所有 $billing_count 个结算账户:
        $(printf '\n• %s' "${ALL_BILLING[@]}")
        
        此操作将创建大量实际的 GCP 资源并产生费用。
        " || return 1
        
        for acc in "${ALL_BILLING[@]}"; do 
          handle_vertex_billing "${acc%% *}"
        done
        ;;
      0|"") 
        log "INFO" "操作已取消，返回主菜单"
        return 0
        ;;
      *)
        log "ERROR" "无效选项: $mode"
        return 1
        ;;
    esac
  fi
  
  # 统计总体执行时间
  local duration=$SECONDS
  local minutes=$((duration / 60))
  local seconds_rem=$((duration % 60))
  log "INFO" "======================================================"
  log "INFO" "Vertex AI 密钥管理操作完成"
  log "INFO" "总执行时间: $minutes 分 $seconds_rem 秒"
  log "INFO" "密钥已保存在目录: $KEY_DIR"
  log "INFO" "======================================================"
  
  # 使用提示
  echo ""
  echo -e "${CYAN}${BOLD}=== 使用提示 ===${NC}"
  echo -e "1. 所有 Vertex AI 服务账号密钥已保存在: ${BOLD}$KEY_DIR${NC} 目录"
  echo -e "2. 使用密钥前请确认有足够的资金或设置预算警报"
  echo -e "3. 记得在不需要时禁用或删除项目以避免产生额外费用"
  echo -e "4. 如API请求失败，请检查服务账号是否有正确的IAM权限"
  echo ""
}

# Gemini项目创建和API密钥获取的主流程
gemini_main() {
  SECONDS=0
  
  clear
  echo -e "${CYAN}${BOLD}======================================================"
  echo -e "    Google Gemini API 密钥管理工具"  
  echo -e "======================================================${NC}"
  
  # 检查GCP登录状态
  check_env || return 1
  
  echo -e "${YELLOW}Gemini API是Google提供的大语言模型API，可用于AI聊天、文本生成等服务${NC}"
  echo -e "${YELLOW}通常有免费额度，但可能需要有效结算账户才能充分使用${NC}"
  echo ""
  
  echo "请选择操作:"
  echo "1. 创建新项目并获取API密钥"
  echo "2. 从现有项目获取API密钥"
  echo "3. 删除现有项目"
  echo "0. 返回主菜单"
  echo ""
  
  # 使用循环处理用户输入，确保输入有效
  local gemini_choice=""
  while true; do
    read -p "请选择操作 [0-3]: " gemini_choice
    
    # 检查输入是否为有效选项
    if [[ "$gemini_choice" =~ ^[0-3]$ ]]; then
      break  # 输入有效，退出循环
    else
      echo "无效选项: '$gemini_choice'，请输入0-3之间的数字"
    fi
  done
  
  case $gemini_choice in
    1) gemini_create_projects ;;
    2) gemini_get_keys_from_existing ;;
    3) gemini_delete_projects ;;
    0|"") return 0 ;;
  esac
  
  # 显示执行时间
  local duration=$SECONDS
  local minutes=$((duration / 60))
  local seconds_rem=$((duration % 60))
  log "INFO" "Gemini API密钥管理操作完成，耗时: $minutes 分 $seconds_rem 秒"
  return 0
}

# 创建新项目并获取Gemini API密钥
gemini_create_projects() {
  log "INFO" "======================================================" 
  log "INFO" "功能: 创建新项目并获取Gemini API密钥" 
  log "INFO" "======================================================"
  
  # 配额检查
  check_quota || return 1
  
  # 询问项目数量
  read -p "请输入要创建的项目数量 [1-100]: " num_projects
  if ! [[ "$num_projects" =~ ^[0-9]+$ ]] || [ "$num_projects" -lt 1 ] || [ "$num_projects" -gt 100 ]; then
    log "ERROR" "无效的项目数量，应在1-100之间"
    return 1
  fi
  
  # 询问项目前缀
  local timestamp=$(date +%s)
  local default_prefix="gemini-api"
  read -p "请输入项目前缀 (默认: $default_prefix): " custom_prefix
  custom_prefix=${custom_prefix:-$default_prefix}
  
  # 验证前缀格式
  if ! [[ "$custom_prefix" =~ ^[a-z][a-z0-9-]{0,28}$ ]]; then
    log "WARN" "项目前缀必须以小写字母开头，只能包含小写字母、数字和连字符"
    log "WARN" "将使用默认前缀: $default_prefix"
    custom_prefix=$default_prefix
  fi
  
  # 确认创建
  log "INFO" "将创建 $num_projects 个项目，前缀: $custom_prefix"
  if ! ask_yes_no "确认继续? [y/N]: " "N"; then
    log "INFO" "操作已取消"
    return 1
  fi
  
  # 准备密钥文件
  local gemini_key_file="gemini_keys.txt"
  local gemini_comma_file="gemini_keys_comma.txt"
  > "$gemini_key_file"
  > "$gemini_comma_file"
  
  # 创建项目并获取密钥
  log "INFO" "开始创建项目并获取密钥..."
  local projects_created=0
  local success_count=0
  
  for ((i=1; i<=num_projects; i++)); do
    local project_id="${custom_prefix}-$(date +%s)-$i"
    project_id=$(echo "$project_id" | tr -cd 'a-z0-9-' | cut -c 1-30)
    
    log "INFO" "[$i/$num_projects] 创建项目: $project_id"
    
    # 创建项目
    if ! retry gcloud projects create "$project_id" --name="$project_id" --quiet; then
      log "ERROR" "创建项目 $project_id 失败"
      continue
    fi
    ((projects_created++))
    
    # 启用API
    log "INFO" "为项目 $project_id 启用 Generative Language API"
    if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
      log "ERROR" "为项目 $project_id 启用API失败"
      continue
    fi
    
    # 创建API密钥
    log "INFO" "为项目 $project_id 创建API密钥"
    local key_output
    if ! key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --format="json" --quiet); then
      log "ERROR" "为项目 $project_id 创建API密钥失败"
      continue
    fi
    
    # 提取API密钥
    local api_key
    api_key=$(echo "$key_output" | grep -o '"keyString": "[^"]*' | cut -d'"' -f4)
    if [ -z "$api_key" ]; then
      log "ERROR" "无法从输出中提取API密钥"
      continue
    fi
    
    # 保存密钥
    echo "$api_key" >> "$gemini_key_file"
    if [ -s "$gemini_comma_file" ]; then
      echo -n "," >> "$gemini_comma_file"
    fi
    echo -n "$api_key" >> "$gemini_comma_file"
    
    log "SUCCESS" "成功获取项目 $project_id 的API密钥"
    ((success_count++))
    
    # 显示进度
    show_progress "$i" "$num_projects"
  done
  
  echo # 换行，结束进度条
  
  # 生成报告
  log "SUCCESS" "操作完成! 创建项目: $projects_created, 成功获取API密钥: $success_count"
  log "INFO" "API密钥已保存到:"
  echo "- 每行一个密钥: $gemini_key_file"
  echo "- 逗号分隔密钥: $gemini_comma_file"
  
  # 显示密钥内容
  if [ "$success_count" -gt 0 ]; then
    echo ""
    echo -e "${CYAN}${BOLD}密钥内容 (逗号分隔格式):${NC}"
    cat "$gemini_comma_file"
    echo ""
  fi
  
  return 0
}

# 从现有项目获取Gemini API密钥
gemini_get_keys_from_existing() {
  log "INFO" "======================================================" 
  log "INFO" "功能: 从现有项目获取Gemini API密钥" 
  log "INFO" "======================================================"
  
  # 获取项目列表
  log "INFO" "正在获取项目列表..."
  local projects
  if ! projects=$(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet); then
    log "ERROR" "获取项目列表失败"
    return 1
  fi
  
  if [ -z "$projects" ]; then
    log "INFO" "未找到任何项目"
    return 1
  fi
  
  # 转换为数组
  mapfile -t PROJECT_LIST <<< "$projects"
  local project_count=${#PROJECT_LIST[@]}
  log "INFO" "找到 $project_count 个项目"
  
  # 显示项目列表
  echo "项目列表:"
  for ((i=0; i<project_count && i<20; i++)); do
    echo "$((i+1)). ${PROJECT_LIST[$i]}"
  done
  if [ $project_count -gt 20 ]; then
    echo "...以及其他 $((project_count - 20)) 个项目"
  fi
  
  # 选择要处理的项目
  echo ""
  echo "请选择操作方式:"
  echo "1. 处理特定项目"
  echo "2. 处理所有项目"
  echo "0. 取消"
  
  read -p "请选择 [0-2]: " project_op_choice
  
  local selected_projects=()
  case $project_op_choice in
    1)
      read -p "请输入项目编号 (多个项目用空格分隔): " project_numbers
      for num in $project_numbers; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $project_count ]; then
          selected_projects+=("${PROJECT_LIST[$((num-1))]}")
        else
          log "WARN" "忽略无效的项目编号: $num"
        fi
      done
      ;;
    2)
      selected_projects=("${PROJECT_LIST[@]}")
      ;;
    0|"")
      log "INFO" "操作已取消"
      return 0
      ;;
    *)
      log "ERROR" "无效选项: $project_op_choice"
      return 1
      ;;
  esac
  
  if [ ${#selected_projects[@]} -eq 0 ]; then
    log "ERROR" "未选择任何有效项目"
    return 1
  fi
  
  log "INFO" "将处理 ${#selected_projects[@]} 个项目"
  
  # 确认操作
  if ! ask_yes_no "确认为选定项目创建/获取Gemini API密钥? [y/N]: " "N"; then
    log "INFO" "操作已取消"
    return 1
  fi
  
  # 准备密钥文件
  local gemini_key_file="gemini_keys_existing.txt"
  local gemini_comma_file="gemini_keys_existing_comma.txt"
  > "$gemini_key_file"
  > "$gemini_comma_file"
  
  # 处理选定的项目
  local total_projects=${#selected_projects[@]}
  local success_count=0
  
  for ((i=0; i<total_projects; i++)); do
    local project_id="${selected_projects[$i]}"
    log "INFO" "[$((i+1))/$total_projects] 处理项目: $project_id"
    
    # 启用API
    log "INFO" "为项目 $project_id 启用 Generative Language API"
    if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
      log "ERROR" "为项目 $project_id 启用API失败"
      continue
    fi
    
    # 检查现有密钥
    log "INFO" "检查项目 $project_id 的现有API密钥"
    local existing_keys
    if existing_keys=$(gcloud services api-keys list --project="$project_id" --format="json" 2>/dev/null); then
      if [ "$existing_keys" != "[]" ] && [ -n "$existing_keys" ]; then
        # 尝试获取现有密钥
        local key_name
        key_name=$(echo "$existing_keys" | grep -o '"name": "[^"]*' | head -1 | cut -d'"' -f4)
        if [ -n "$key_name" ]; then
          log "INFO" "找到现有密钥: $key_name"
          local key_details
          if key_details=$(gcloud services api-keys get-key-string "$key_name" --format="json" --project="$project_id" 2>/dev/null); then
            local api_key
            api_key=$(echo "$key_details" | grep -o '"keyString": "[^"]*' | cut -d'"' -f4)
            if [ -n "$api_key" ]; then
              log "SUCCESS" "成功获取项目 $project_id 的现有API密钥"
              echo "$api_key" >> "$gemini_key_file"
              if [ -s "$gemini_comma_file" ]; then
                echo -n "," >> "$gemini_comma_file"
              fi
              echo -n "$api_key" >> "$gemini_comma_file"
              ((success_count++))
              continue
            fi
          fi
        fi
      fi
    fi
    
    # 如果没有找到有效的现有密钥，创建新密钥
    log "INFO" "为项目 $project_id 创建新API密钥"
    local key_output
    if ! key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key (New)" --api-target=service=generativelanguage.googleapis.com --format="json" --quiet); then
      log "ERROR" "为项目 $project_id 创建API密钥失败"
      continue
    fi
    
    # 提取API密钥
    local api_key
    api_key=$(echo "$key_output" | grep -o '"keyString": "[^"]*' | cut -d'"' -f4)
    if [ -z "$api_key" ]; then
      log "ERROR" "无法从输出中提取API密钥"
      continue
    fi
    
    # 保存密钥
    echo "$api_key" >> "$gemini_key_file"
    if [ -s "$gemini_comma_file" ]; then
      echo -n "," >> "$gemini_comma_file"
    fi
    echo -n "$api_key" >> "$gemini_comma_file"
    
    log "SUCCESS" "成功获取项目 $project_id 的新API密钥"
    ((success_count++))
    
    # 显示进度
    show_progress "$((i+1))" "$total_projects"
  done
  
  echo # 换行，结束进度条
  
  # 生成报告
  log "SUCCESS" "操作完成! 处理项目: $total_projects, 成功获取API密钥: $success_count"
  log "INFO" "API密钥已保存到:"
  echo "- 每行一个密钥: $gemini_key_file"
  echo "- 逗号分隔密钥: $gemini_comma_file"
  
  # 显示密钥内容
  if [ "$success_count" -gt 0 ]; then
    echo ""
    echo -e "${CYAN}${BOLD}密钥内容 (逗号分隔格式):${NC}"
    cat "$gemini_comma_file"
    echo ""
  fi
  
  return 0
}

# 删除项目
gemini_delete_projects() {
  log "INFO" "======================================================" 
  log "INFO" "功能: 删除现有项目" 
  log "INFO" "======================================================"
  
  # 获取项目列表
  log "INFO" "正在获取项目列表..."
  local projects
  if ! projects=$(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet); then
    log "ERROR" "获取项目列表失败"
    return 1
  fi
  
  if [ -z "$projects" ]; then
    log "INFO" "未找到任何项目"
    return 1
  fi
  
  # 转换为数组
  mapfile -t PROJECT_LIST <<< "$projects"
  local project_count=${#PROJECT_LIST[@]}
  log "INFO" "找到 $project_count 个项目"
  
  # 显示项目列表
  echo "项目列表:"
  for ((i=0; i<project_count && i<20; i++)); do
    echo "$((i+1)). ${PROJECT_LIST[$i]}"
  done
  if [ $project_count -gt 20 ]; then
    echo "...以及其他 $((project_count - 20)) 个项目"
  fi
  
  # 选择要删除的项目
  echo ""
  echo "请选择要删除的项目:"
  echo "1. 删除特定项目"
  echo "2. 删除所有项目"
  echo "0. 取消"
  
  read -p "请选择 [0-2]: " delete_choice
  
  local selected_projects=()
  case $delete_choice in
    1)
      read -p "请输入项目编号 (多个项目用空格分隔): " project_numbers
      for num in $project_numbers; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $project_count ]; then
          selected_projects+=("${PROJECT_LIST[$((num-1))]}")
        else
          log "WARN" "忽略无效的项目编号: $num"
        fi
      done
      ;;
    2)
      selected_projects=("${PROJECT_LIST[@]}")
      ;;
    0|"")
      log "INFO" "操作已取消"
      return 0
      ;;
    *)
      log "ERROR" "无效选项: $delete_choice"
      return 1
      ;;
  esac
  
  if [ ${#selected_projects[@]} -eq 0 ]; then
    log "ERROR" "未选择任何有效项目"
    return 1
  fi
  
  # 确认删除
  echo -e "${RED}${BOLD}警告: 此操作将永久删除 ${#selected_projects[@]} 个项目!${NC}"
  echo -e "${RED}所有项目资源将被销毁，此操作不可撤销!${NC}"
  read -p "请输入 'DELETE-ALL' 确认删除: " delete_confirm
  
  if [ "$delete_confirm" != "DELETE-ALL" ]; then
    log "INFO" "删除操作已取消"
    return 1
  fi
  
  # 执行删除
  local total_projects=${#selected_projects[@]}
  local success_count=0
  
  for ((i=0; i<total_projects; i++)); do
    local project_id="${selected_projects[$i]}"
    log "INFO" "[$((i+1))/$total_projects] 删除项目: $project_id"
    
    if gcloud projects delete "$project_id" --quiet; then
      log "SUCCESS" "已成功删除项目: $project_id"
      ((success_count++))
    else
      log "ERROR" "删除项目 $project_id 失败"
    fi
    
    # 显示进度
    show_progress "$((i+1))" "$total_projects"
  done
  
  echo # 换行，结束进度条
  
  # 生成报告
  log "INFO" "删除操作完成! 总计: $total_projects, 成功: $success_count, 失败: $((total_projects - success_count))"
  return 0
}

# 显示主菜单
show_menu() {
  clear
  echo "======================================================"
  echo -e "     ${CYAN}${BOLD}GCP API 密钥管理工具 v${VERSION}${NC} （Gemini & Vertex）"
  echo -e "     ${BLUE}更新日期: ${LAST_UPDATED}${NC}"
  echo "======================================================"
  local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1)
  if [ -z "$current_account" ]; then current_account="无法获取 (gcloud auth list 失败?)"; fi
  local current_project; current_project=$(gcloud config get-value project 2>/dev/null)
  if [ -z "$current_project" ]; then current_project="未设置 (gcloud config get-value project 失败?)"; fi
  echo "当前账号: $current_account"
  echo "当前项目: $current_project"
  echo "并行任务数: $MAX_PARALLEL_JOBS"
  echo "重试次数: $MAX_RETRY_ATTEMPTS"
  echo ""
  
  # 在主菜单上显示风险提示摘要
  echo -e "${RED}${BOLD}⚠️ 风险提示 ⚠️${NC}"
  echo -e "${YELLOW}• Gemini API 批量创建可能导致 GCP 账号被封禁${NC}"
  echo -e "${YELLOW}• Vertex AI 会产生实际费用，请留意结算账户扣款${NC}"
  echo -e "${YELLOW}• 详细风险说明请查看帮助文档 (选项4)${NC}"
  echo ""
  
  echo "请选择功能:"
  echo "1. 创建 Gemini API 密钥 (Google大语言模型API，已内置完整功能)"
  echo -e "2. 创建 Vertex AI API 密钥 ${YELLOW}(需要结算账户，会产生费用)${NC}"
  echo "3. 修改 Vertex 配置参数"
  echo "4. 帮助和使用说明"
  echo "0. 退出"
  echo "======================================================"
  
  # 使用循环处理用户输入，确保输入有效
  local choice=""
  while true; do
    read -p "请输入选项 [0-4]: " choice
    
    # 检查输入是否为有效选项
    if [[ "$choice" =~ ^[0-4]$ ]]; then
      break  # 输入有效，退出循环
    else
      echo "无效选项: '$choice'，请输入0-4之间的数字"
    fi
  done

  case $choice in
    1) 
      # 在选择Gemini功能前特别提醒
      show_warning "
      ${BOLD}您选择了Gemini API功能。请注意:${NC}
      
      • 批量创建项目可能触发Google风控
      • 账号可能被临时或永久停用
      • 请不要一次性创建大量项目
      "
      gemini_main 
      ;;
    2) 
      # 在选择Vertex功能前特别提醒
      show_warning "
      ${BOLD}您选择了Vertex AI功能。请注意:${NC}
      
      • 此功能需要有效结算账户
      • 将产生实际费用
      • 用完免费额度后将自动计费
      • 请确保已设置预算警报
      "
      vertex_main 
      ;;
    3) configure_vertex_settings ;;
    4) show_help ;;
    0) 
      log "INFO" "正在退出..."; 
      # 清理资源并显示告别信息
      echo -e "${CYAN}感谢使用 GCP API 密钥管理工具${NC}"
      echo -e "${YELLOW}请记得检查并删除不需要的项目以避免额外费用${NC}"
      exit 0 
      ;;
  esac
  
  if [[ "$choice" =~ ^[1-4]$ ]]; then 
    echo ""; 
    read -p "按回车键返回主菜单..."; 
  fi
}

# Vertex 配置设置
configure_vertex_settings() {
  local setting_changed=false
  while true; do
    clear
    echo "======================================================"
    echo "Vertex AI 配置参数"
    echo "======================================================"
    echo "当前设置:"
    echo "1. Vertex 项目前缀: $VERTEX_PROJECT_PREFIX"
    echo "2. 每账户最大项目数: $MAX_PROJECTS_PER_ACCOUNT"
    echo "3. 服务账号名称: $SERVICE_ACCOUNT_NAME" 
    echo "4. 密钥存储目录: $KEY_DIR"
    echo "5. 最大并行任务数: $MAX_PARALLEL_JOBS"
    echo "6. 最大重试次数: $MAX_RETRY_ATTEMPTS"
    echo "0. 返回主菜单"
    echo "======================================================"
    
    # 使用循环处理用户输入，确保输入有效
    local setting_choice=""
    while true; do
      read -p "请选择要修改的设置 [0-6]: " setting_choice
      
      # 检查输入是否为有效选项
      if [[ "$setting_choice" =~ ^[0-6]$ ]]; then
        break  # 输入有效，退出循环
      else
        echo "无效选项: '$setting_choice'，请输入0-6之间的数字"
      fi
    done
    
    case $setting_choice in
      1) read -p "请输入新的项目前缀 (留空取消): " new_prefix
         if [ -n "$new_prefix" ]; then
           if [[ "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
             VERTEX_PROJECT_PREFIX="$new_prefix"
             log "INFO" "项目前缀已更新为: $VERTEX_PROJECT_PREFIX"
             setting_changed=true
           else
             echo "错误：前缀必须以小写字母开头，只能包含小写字母、数字和连字符，长度1-20。"
             sleep 2
           fi
         fi ;;
      2) read -p "请输入每账户最大项目数 (留空取消): " new_max
         if [[ "$new_max" =~ ^[1-9][0-9]*$ ]]; then
           MAX_PROJECTS_PER_ACCOUNT=$new_max
           log "INFO" "每账户最大项目数已更新为: $MAX_PROJECTS_PER_ACCOUNT"
           setting_changed=true
         elif [ -n "$new_max" ]; then
           echo "错误：请输入一个大于0的整数。"
           sleep 2
         fi ;;
      3) read -p "请输入服务账号名称 (留空取消): " new_sa_name
         if [ -n "$new_sa_name" ]; then
           SERVICE_ACCOUNT_NAME="$new_sa_name"
           log "INFO" "服务账号名称已更新为: $SERVICE_ACCOUNT_NAME"
           setting_changed=true
         fi ;;
      4) read -p "请输入密钥存储目录 (留空取消): " new_key_dir
         if [ -n "$new_key_dir" ]; then
           KEY_DIR="$new_key_dir"
           log "INFO" "密钥存储目录已更新为: $KEY_DIR"
           setting_changed=true
           mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
         fi ;;
      5) read -p "请输入最大并行任务数 (建议 5-50，留空取消): " new_parallel
         if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]]; then
           MAX_PARALLEL_JOBS=$new_parallel
           log "INFO" "最大并行任务数已更新为: $MAX_PARALLEL_JOBS"
           setting_changed=true
         elif [ -n "$new_parallel" ]; then
           echo "错误：请输入一个大于0的整数。"
           sleep 2
         fi ;;
      6) read -p "请输入最大重试次数 (建议 1-5，留空取消): " new_retries
         if [[ "$new_retries" =~ ^[1-9][0-9]*$ ]]; then
           MAX_RETRY_ATTEMPTS=$new_retries
           log "INFO" "最大重试次数已更新为: $MAX_RETRY_ATTEMPTS"
           setting_changed=true
         elif [ -n "$new_retries" ]; then
           echo "错误：请输入一个大于等于1的整数。"
           sleep 2
         fi ;;
      0) return ;;
      *) echo "无效选项 '$setting_choice'，请重新选择。"; sleep 2 ;;
    esac
    if $setting_changed; then
      sleep 1
      setting_changed=false
    fi
  done
}

# 添加帮助函数
show_help() {
  clear
  echo -e "${CYAN}${BOLD}========== GCP API 密钥管理工具使用说明 ==========${NC}"
  echo ""
  
  # 选择帮助类型
  echo "请选择查看的帮助内容:"
  echo "1. 通用帮助和风险说明"
  echo "2. Gemini API 详细帮助"
  echo "3. Vertex AI API 详细帮助" 
  echo "4. 命令行参数和高级用法"
  echo "5. 故障排除和常见问题"
  echo "6. 使用示例和最佳实践"
  echo "7. API特性比较与选择指南"
  echo "0. 进入脚本"
  echo ""
  
  # 使用循环处理用户输入，确保输入有效
  local help_choice=""
  while true; do
    read -p "请选择 [1-7, 0 返回]: " help_choice
    
    # 检查输入是否有效
    if [[ "$help_choice" =~ ^[0-7]$ ]]; then
      break  # 输入有效，退出循环
    else
      echo "无效选项: '$help_choice'，请输入0-7之间的数字"
    fi
  done
  
  case $help_choice in
    1) show_general_help ;;
    2) show_gemini_help ;;
    3) show_vertex_help ;;
    4) show_advanced_usage ;;
    5) show_troubleshooting ;;
    6) show_examples ;;
    7) show_api_comparison ;;
    0) return ;;
    *) 
      echo "无效选项，显示通用帮助..."
      sleep 1
      show_general_help
      ;;
  esac
}

# 通用帮助和风险说明
show_general_help() {
  clear
  echo -e "${RED}${BOLD}======================================================${NC}"
  echo -e "${RED}${BOLD}⚠️  重要风险提示与免责声明  ⚠️${NC}"
  echo -e "${RED}${BOLD}======================================================${NC}"
  echo -e "${YELLOW}• 使用本脚本批量创建 ${BOLD}Gemini API${NC}${YELLOW} 项目/密钥，可能触发GCP风控，导致账号或项目被 ${BOLD}停用/封禁${NC}${YELLOW}。${NC}"
  echo -e "${YELLOW}• 批量创建项目可能违反Google服务条款，可能导致账号被${BOLD}永久停用${NC}${YELLOW}。${NC}"
  echo -e "${YELLOW}• 使用 ${BOLD}Vertex AI${NC}${YELLOW} 需要有效结算账户，并会消耗 \$300 免费额度后开始 ${BOLD}实际计费${NC}${YELLOW}。${NC}"
  echo -e "${YELLOW}• 如不及时关闭或删除项目，可能产生${BOLD}持续费用${NC}${YELLOW}，直至信用卡额度用尽。${NC}"
  echo -e "${YELLOW}• 本脚本使用可能导致GCP账号风控审核，进而影响${BOLD}所有Google服务的使用${NC}${YELLOW}。${NC}"
  echo -e "${YELLOW}• Vertex服务的费用根据各模型和用量${BOLD}不同而异${NC}${YELLOW}，某些高级模型费用较高。${NC}"
  echo -e "${YELLOW}• 本脚本仅作学习测试用途，作者及维护者不对任何费用或账号封禁承担责任。${NC}"
  echo -e "${RED}${BOLD}======================================================${NC}"
  echo ""
  
  echo -e "${BOLD}功能概述:${NC}"
  echo "这个脚本可以帮助您管理 Google Cloud Platform (GCP) 的两种主要 AI API:"
  echo "1. Gemini API - Google的大语言模型API"
  echo "2. Vertex AI API - Google的机器学习平台"
  echo ""
  
  echo -e "${BOLD}主要区别:${NC}"
  echo -e "• ${GREEN}Gemini API${NC} - 通常有免费额度，不强制要求结算账户"
  echo -e "• ${YELLOW}Vertex AI${NC} - 必须关联有效结算账户，会根据使用量产生实际费用"
  echo ""
  
  echo -e "${BOLD}通用注意事项:${NC}"
  echo "• 请在使用前确保您完全理解相关风险"
  echo "• 请勿在公共场所或共享环境中使用，保护您的API密钥"
  echo "• 定期检查并删除不需要的项目以避免额外费用"
  echo "• 设置Google Cloud账户的预算警报以避免意外费用"
  echo "• 如使用结算账户，建议设置支出限额"
  echo ""
  
  echo -e "${CYAN}要查看更多详细信息，请使用菜单选择特定API的帮助文档。${NC}"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# Gemini API 详细帮助
show_gemini_help() {
  clear
  echo -e "${CYAN}${BOLD}========== Gemini API 帮助文档 ==========${NC}"
  echo ""
  
  echo -e "${RED}${BOLD}====== 风险警告 ======${NC}"
  echo -e "${YELLOW}• 批量创建 Gemini API 项目可能触发Google风控机制${NC}"
  echo -e "${YELLOW}• 可能导致账号或项目被临时或永久停用${NC}"
  echo -e "${YELLOW}• 如果您的GCP账号被标记为滥用，可能会影响您的其他Google服务${NC}"
  echo -e "${YELLOW}• 建议不要一次性创建大量项目，可分批次慢慢创建${NC}"
  echo -e "${YELLOW}• 批量创建项目可能违反Google服务条款${NC}"
  echo -e "${YELLOW}• 频繁创建项目可能导致GCP账号被标记为可疑账号${NC}"
  echo -e "${RED}${BOLD}=======================${NC}"
  echo ""
  
  echo -e "${BOLD}Gemini API 概述:${NC}"
  echo "Google Gemini API是一个强大的大语言模型API，可用于:"
  echo "• 文本生成和对话"
  echo "• 内容摘要"
  echo "• 信息提取"
  echo "• 语义搜索" 
  echo "• 代码生成和辅助"
  echo ""
  
  echo -e "${BOLD}使用流程:${NC}"
  echo "1. 通过脚本创建一个或多个GCP项目"
  echo "2. 启用Generative Language API (generativelanguage.googleapis.com)"
  echo "3. 创建API密钥"
  echo "4. 获取并保存API密钥以便在应用中使用"
  echo ""
  
  echo -e "${BOLD}脚本功能:${NC}"
  echo "• 创建新项目并获取API密钥 - 批量创建新项目并自动配置API"
  echo "• 从现有项目获取API密钥 - 在已有项目上启用API并获取密钥"
  echo "• 删除现有项目 - 清理不需要的项目以避免资源浪费"
  echo ""
  
  echo -e "${BOLD}密钥保存格式:${NC}"
  echo "• 每行一个密钥 - 保存在 gemini_keys.txt"
  echo "• 逗号分隔密钥 - 保存在 gemini_keys_comma.txt，适用于某些API聚合工具"
  echo ""
  
  echo -e "${BOLD}配额和使用限制:${NC}"
  echo "• 每个项目有自己的API配额限制"
  echo "• 默认情况下，每个项目每分钟有请求限制"
  echo "• 创建多个项目可以增加总体可用配额"
  echo "• 请注意遵守Google API服务条款"
  echo ""
  
  echo -e "${BOLD}最佳实践:${NC}"
  echo "• 不要一次性创建过多项目"
  echo "• 适当设置项目前缀以便于管理"
  echo "• 定期清理不使用的项目"
  echo "• 保护好您的API密钥，不要在公共代码库中暴露"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# Vertex AI 详细帮助
show_vertex_help() {
  clear
  echo -e "${CYAN}${BOLD}========== Vertex AI API 帮助文档 ==========${NC}"
  echo ""
  
  echo -e "${RED}${BOLD}====== 费用警告 ======${NC}"
  echo -e "${YELLOW}• Vertex AI 需要有效的结算账户${NC}"
  echo -e "${YELLOW}• 使用会消耗 Google Cloud \$300 免费额度${NC}"
  echo -e "${YELLOW}• 用完免费额度后将产生实际费用${NC}"
  echo -e "${YELLOW}• 未及时停止使用可能导致高额费用${NC}"
  echo -e "${YELLOW}• 强烈建议设置预算警报和支出限额${NC}"
  echo -e "${YELLOW}• 某些高级模型每次调用可能产生较高费用${NC}"
  echo -e "${YELLOW}• 测试完成后务必删除项目或禁用API以避免持续计费${NC}"
  echo -e "${RED}${BOLD}=======================${NC}"
  echo ""
  
  echo -e "${BOLD}Vertex AI 概述:${NC}"
  echo "Vertex AI 是 Google Cloud 的端到端机器学习平台，提供:"
  echo "• 高级AI模型API访问"
  echo "• 更强大的模型能力和更高的配额"
  echo "• 企业级API支持和SLA"
  echo "• 自定义训练和部署选项"
  echo "• 多模态AI功能（文本、图像、音频等）"
  echo ""
  
  echo -e "${BOLD}使用流程:${NC}"
  echo "1. 选择/创建一个有效结算账户关联的GCP项目"
  echo "2. 启用 Vertex AI API (aiplatform.googleapis.com)"
  echo "3. 创建服务账号并授予适当权限"
  echo "4. 生成JSON格式的服务账号密钥"
  echo "5. 使用服务账号密钥通过SDK或API访问Vertex AI服务"
  echo ""
  
  echo -e "${BOLD}脚本功能:${NC}"
  echo "• 创建新项目并生成服务账号密钥"
  echo "• 在现有项目上配置服务账号和权限"
  echo "• 管理多个结算账户下的项目"
  echo "• 配置最佳权限设置以确保API可用"
  echo ""
  
  echo -e "${BOLD}服务账号权限:${NC}"
  echo "脚本会为服务账号配置以下角色:"
  echo "• Vertex AI Administrator (aiplatform.admin)"
  echo "• Service Account User (iam.serviceAccountUser)"
  echo "• Service Account Token Creator (iam.serviceAccountTokenCreator)"
  echo "• Vertex AI User (aiplatform.user)"
  echo ""
  
  echo -e "${BOLD}密钥管理:${NC}"
  echo "• 所有JSON密钥文件将保存在 $KEY_DIR 目录"
  echo "• 密钥文件命名格式: [项目ID]-[服务账号名]-[时间戳].json"
  echo "• 密钥文件权限设置为600 (仅用户可读写)"
  echo "• 请妥善保管密钥文件，不要在公共场所暴露"
  echo ""
  
  echo -e "${BOLD}费用控制:${NC}"
  echo "• 为每个项目设置预算警报"
  echo "• 在Google Cloud控制台中监控使用情况"
  echo "• 不使用时及时禁用API或删除项目"
  echo "• 考虑使用Google Cloud的费用限额功能"
  echo "• 定期检查账单以防意外费用"
  echo ""
  
  echo -e "${BOLD}故障排除:${NC}"
  echo "如果使用API时出现权限错误，请检查:"
  echo "1. 项目是否已关联有效结算账户"
  echo "2. 是否已启用所需API (aiplatform.googleapis.com)"
  echo "3. 服务账号是否有正确的IAM角色分配"
  echo "4. 如有必要，可手动在GCP控制台中调整权限设置"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# 添加警告函数
# 显示带框的警告消息
show_warning() {
  local msg="$1"
  local width=80
  local border
  border=$(printf '%*s' "$width" | tr ' ' '=')
  
  echo -e "${YELLOW}${border}${NC}"
  echo -e "${YELLOW}${BOLD}!! 警告 !!${NC}"
  echo -e "${YELLOW}${msg}${NC}"
  echo -e "${YELLOW}${border}${NC}"
  
  if [ -t 0 ]; then  # 检查是否在交互式终端
    local confirm=""
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
      read -p "已阅读警告并确认继续? [y/N]: " confirm
      
      # 处理各种输入情况
      if [[ -z "$confirm" || "$confirm" =~ ^[Nn]$ ]]; then
        # 用户输入空或N，再次确认是否退出
        read -p "您选择了取消，确认要退出吗? [y/N]: " exit_confirm
        if [[ -z "$exit_confirm" || "$exit_confirm" =~ ^[Yy]$ ]]; then
          log "INFO" "用户取消操作"
          return 1
        else
          # 用户不想退出，重新开始确认流程
          echo "请重新确认是否继续操作"
          ((retry_count++))
          continue
        fi
      elif [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 用户确认继续
        return 0
      else
        # 无效输入
        echo "无效输入，请输入y或n"
        ((retry_count++))
      fi
    done
    
    # 达到最大重试次数，默认退出
    log "INFO" "多次无效输入，操作已取消"
    return 1
  fi
  
  # 非交互模式默认返回成功
  return 0
}

# 设置退出处理函数
trap cleanup_resources EXIT SIGINT SIGTERM

# 清理资源函数
cleanup_resources() {
  # 清理临时文件
  if [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    log "INFO" "已清理临时目录: $TEMP_DIR"
  fi
  
  # 检查是否有未完成的操作
  if [ -f "${TEMP_DIR}/running_operations.txt" ]; then
    log "WARN" "检测到可能有未完成的操作，请手动检查状态"
  fi
  
  # 显示退出信息
  log "INFO" "脚本已退出，感谢使用"
}

# 添加命令行参数和高级用法说明
show_advanced_usage() {
  clear
  echo -e "${CYAN}${BOLD}========== 命令行参数和高级用法 ==========${NC}"
  echo ""
  
  echo -e "${BOLD}环境变量:${NC}"
  echo "本脚本支持通过环境变量自定义多项配置:"
  echo -e "${YELLOW}PROJECT_PREFIX${NC} - 项目前缀 (默认: gemini-key/vertex)"
  echo -e "${YELLOW}MAX_RETRY${NC} - 失败操作最大重试次数 (默认: 3)"
  echo -e "${YELLOW}CONCURRENCY${NC} - 最大并行任务数 (默认: 20)"
  echo -e "${YELLOW}BILLING_ACCOUNT${NC} - 默认结算账户ID"
  echo -e "${YELLOW}MAX_PROJECTS_PER_ACCOUNT${NC} - 每账户最大项目数 (默认: 3)"
  echo -e "${YELLOW}SERVICE_ACCOUNT_NAME${NC} - 服务账号名称 (默认: vertex-admin)"
  echo -e "${YELLOW}KEY_DIR${NC} - 密钥存储目录 (默认: ./keys)"
  echo ""
  
  echo -e "${BOLD}使用示例:${NC}"
  echo "1. 设置项目前缀和并行任务数:"
  echo "   PROJECT_PREFIX=myproject CONCURRENCY=10 ./combined_gcp_keys.sh"
  echo ""
  echo "2. 指定结算账户和密钥目录:"
  echo "   BILLING_ACCOUNT=123456-ABCDEF KEY_DIR=/secure/keys ./combined_gcp_keys.sh"
  echo ""
  
  echo -e "${BOLD}批处理模式:${NC}"
  echo "可以通过管道或重定向输入来自动化某些操作:"
  echo "例如，创建多个批次的Gemini API密钥:"
  echo "  echo -e \"1\\n10\\ngemini-batch1\\ny\" | ./combined_gcp_keys.sh"
  echo "  (这将选择Gemini API选项，创建10个项目，前缀为gemini-batch1)"
  echo ""
  
  echo -e "${BOLD}选项细节:${NC}"
  echo "项目前缀 (PROJECT_PREFIX):"
  echo "  - 必须以小写字母开头"
  echo "  - 只能包含小写字母、数字和连字符"
  echo "  - 最大长度为28个字符(创建时会添加随机后缀)"
  echo ""
  echo "并行任务数 (CONCURRENCY):"
  echo "  - 建议值: 5-50"
  echo "  - 过大的值可能导致超出API限制或触发风控"
  echo "  - 过小的值会延长操作时间"
  echo ""
  echo "重试次数 (MAX_RETRY):"
  echo "  - 建议值: 1-5"
  echo "  - 增加此值可以提高在网络不稳定时的成功率"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# 添加故障排除和常见问题
show_troubleshooting() {
  clear
  echo -e "${CYAN}${BOLD}========== 故障排除和常见问题 ==========${NC}"
  echo ""
  
  echo -e "${BOLD}常见错误:${NC}"
  echo "1. 未授权/权限错误:"
  echo "   • 确保已运行 gcloud auth login 并成功登录"
  echo "   • 检查当前用户是否有足够的 IAM 权限"
  echo "   • 尝试运行 gcloud auth application-default login"
  echo ""
  
  echo "2. 项目创建失败:"
  echo "   • 可能达到项目创建配额限制"
  echo "   • 检查账号是否已被标记为可疑账号"
  echo "   • 尝试降低创建速率或减少批量创建数量"
  echo ""
  
  echo "3. API 启用失败:"
  echo "   • 检查项目是否已关联结算账户(Vertex AI需要)"
  echo "   • 可能受到API服务限制，等待一段时间后重试"
  echo "   • 尝试在GCP控制台手动启用API"
  echo ""
  
  echo "4. 服务账号创建失败:"
  echo "   • 检查IAM API是否已启用"
  echo "   • 确认您有足够的权限创建服务账号"
  echo "   • 检查是否达到服务账号数量限制"
  echo ""
  
  echo "5. 无法获取API密钥:"
  echo "   • 检查API是否已成功启用"
  echo "   • 确认项目状态是否为活跃"
  echo "   • 尝试在GCP控制台手动创建API密钥"
  echo ""
  
  echo -e "${BOLD}Gemini特有问题:${NC}"
  echo "1. 批量操作后账号被临时锁定:"
  echo "   • 这是正常的风控措施"
  echo "   • 停止创建新项目，等待24-48小时"
  echo "   • 后续操作请降低创建速率"
  echo ""
  
  echo "2. API密钥无效或不工作:"
  echo "   • 检查密钥是否已被禁用(可在GCP控制台查看)"
  echo "   • 验证API配额是否已用尽"
  echo "   • 尝试创建新的API密钥"
  echo ""
  
  echo -e "${BOLD}Vertex AI特有问题:${NC}"
  echo "1. Vertex API调用失败:"
  echo "   • 确认已正确设置服务账号权限"
  echo "   • 验证结算账户是否有效"
  echo "   • 检查服务账号密钥文件格式是否正确"
  echo ""
  
  echo "2. 意外计费:"
  echo "   • 立即检查并禁用不需要的API"
  echo "   • 删除不再使用的项目"
  echo "   • 在结算中心设置预算警报和限额"
  echo ""
  
  echo -e "${BOLD}其他常见问题:${NC}"
  echo "Q: 脚本执行时间过长怎么办?"
  echo "A: 增加CONCURRENCY值，减少创建的项目数量，或分批次执行"
  echo ""
  echo "Q: 如何验证API密钥是否有效?"
  echo "A: 可以使用curl命令测试API调用，具体请参考Google API文档"
  echo ""
  echo "Q: 如何管理大量创建的项目?"
  echo "A: 使用有意义的项目前缀，并维护一个项目清单文件"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# 添加使用示例和最佳实践
show_examples() {
  clear
  echo -e "${CYAN}${BOLD}========== 使用示例和最佳实践 ==========${NC}"
  echo ""
  
  echo -e "${BOLD}Gemini API 使用示例:${NC}"
  echo "1. 创建小批量项目并获取API密钥:"
  echo "   • 选择选项1 (创建 Gemini API 密钥)"
  echo "   • 选择子选项1 (创建新项目并获取API密钥)"
  echo "   • 输入项目数量: 5-10 (建议每次不超过20个)"
  echo "   • 使用有意义的项目前缀 (如gemini-test-0601)"
  echo "   • 操作完成后，密钥将保存在当前目录下"
  echo ""
  
  echo "2. 从现有项目获取密钥:"
  echo "   • 选择选项1 (创建 Gemini API 密钥)"
  echo "   • 选择子选项2 (从现有项目获取API密钥)"
  echo "   • 根据列表选择要处理的项目"
  echo "   • 脚本将启用API并获取密钥"
  echo ""
  
  echo "3. 清理不需要的项目:"
  echo "   • 定期执行此操作避免资源浪费"
  echo "   • 选择选项1 (创建 Gemini API 密钥)"
  echo "   • 选择子选项3 (删除现有项目)"
  echo "   • 谨慎选择要删除的项目"
  echo "   • 输入DELETE-ALL确认删除"
  echo ""
  
  echo -e "${BOLD}Vertex AI 使用示例:${NC}"
  echo "1. 在现有结算账户上创建项目:"
  echo "   • 选择选项2 (创建 Vertex AI API 密钥)"
  echo "   • 选择要使用的结算账户"
  echo "   • 选择操作方式2 (创建新项目)"
  echo "   • 指定项目数量 (建议1-3个)"
  echo "   • 设置项目前缀"
  echo "   • 操作完成后，密钥将保存在 $KEY_DIR 目录"
  echo ""
  
  echo "2. 在现有项目上配置Vertex AI:"
  echo "   • 选择选项2 (创建 Vertex AI API 密钥)"
  echo "   • 选择操作方式1 (在现有项目上创建密钥)"
  echo "   • 选择要处理的项目"
  echo "   • 脚本会自动启用API、创建服务账号和密钥"
  echo ""
  
  echo -e "${BOLD}最佳实践:${NC}"
  echo "1. Gemini API使用:"
  echo "   • 使用多个项目分散API调用，避免单一项目超出配额"
  echo "   • 建议每个普通应用场景创建5-10个项目即可"
  echo "   • 设置有规律的项目前缀便于管理"
  echo "   • 定期清理不再使用的项目"
  echo ""
  
  echo "2. Vertex AI使用:"
  echo "   • 严格控制项目数量，避免不必要的费用"
  echo "   • 为每个项目设置预算警报"
  echo "   • 测试完成后即禁用API或删除项目"
  echo "   • 妥善保管密钥文件，避免泄露"
  echo ""
  
  echo "3. 密钥管理:"
  echo "   • 将API密钥存储在安全位置"
  echo "   • 不要在公共代码库中硬编码密钥"
  echo "   • 考虑使用环境变量或密钥管理系统"
  echo "   • 定期轮换密钥以提高安全性"
  echo ""
  
  echo "4. 成本控制:"
  echo "   • 为结算账户设置预算警报"
  echo "   • 监控API使用情况"
  echo "   • 了解各API的计费模式和费率"
  echo "   • 不使用时及时关闭或删除资源"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# 添加API特性比较与选择指南
show_api_comparison() {
  clear
  echo -e "${CYAN}${BOLD}========== API特性比较与选择指南 ==========${NC}"
  echo ""
  
  echo -e "${BOLD}Gemini API 与 Vertex AI 特性比较:${NC}"
  echo -e "┌─────────────────┬────────────────────────┬────────────────────────┐"
  echo -e "│     特性        │      Gemini API        │      Vertex AI         │"
  echo -e "├─────────────────┼────────────────────────┼────────────────────────┤"
  echo -e "│ 计费模式        │ 有免费层级             │ 按使用量计费           │"
  echo -e "│ 需要结算账户    │ 否(基本功能)           │ 是(必需)               │"
  echo -e "│ 请求限制        │ 较低                   │ 较高                   │"
  echo -e "│ 可用模型        │ Gemini系列             │ 全系列AI模型           │"
  echo -e "│ 认证方式        │ API密钥                │ 服务账号JSON密钥       │"
  echo -e "│ 企业级支持      │ 有限                   │ 完整支持               │"
  echo -e "│ 风控敏感度      │ 较高                   │ 较低                   │"
  echo -e "│ 密钥格式        │ 简单字符串             │ JSON文件               │"
  echo -e "│ 使用复杂度      │ 简单                   │ 较复杂                 │"
  echo -e "│ 推荐场景        │ 个人项目、测试         │ 企业应用、生产环境     │"
  echo -e "└─────────────────┴────────────────────────┴────────────────────────┘"
  echo ""
  
  echo -e "${BOLD}选择指南:${NC}"
  echo "1. 如果您是个人开发者或学习测试使用:"
  echo "   • Gemini API 通常是更好的选择"
  echo "   • 有免费额度，适合小规模应用"
  echo "   • 无需关联结算账户，降低风险"
  echo "   • API调用方式简单，容易集成"
  echo ""
  
  echo "2. 如果您是企业用户或需要生产环境:"
  echo "   • Vertex AI 是更稳定可靠的选择"
  echo "   • 提供企业级SLA保障"
  echo "   • 更高的API调用限额"
  echo "   • 更全面的模型选择"
  echo "   • 更好的安全性和审计能力"
  echo ""
  
  echo -e "${BOLD}主要风险对比:${NC}"
  echo "Gemini API 风险:"
  echo "• 批量创建项目可能触发账号风控"
  echo "• 密钥可能被突然禁用"
  echo "• 配额和功能限制较多"
  echo ""
  
  echo "Vertex AI 风险:"
  echo "• 会产生实际费用，需要密切监控"
  echo "• 费用积累可能超出预期"
  echo "• 需要更复杂的权限管理"
  echo ""
  
  echo -e "${BOLD}技术细节对比:${NC}"
  echo "Gemini API:"
  echo "• REST API端点: generativelanguage.googleapis.com"
  echo "• 认证方式: API-Key (HTTP Header或URL参数)"
  echo "• 配额示例: 每分钟有限的请求，每天有限的tokens"
  echo ""
  
  echo "Vertex AI:"
  echo "• REST API端点: aiplatform.googleapis.com"
  echo "• 认证方式: OAuth2/服务账号(JWT认证)"
  echo "• 配额示例: 根据付费级别不同，最高可达数千QPS"
  echo ""
  
  read -p "按回车键继续..." _
  show_help
}

# 创建一个标志文件来跟踪是否已显示欢迎信息
WELCOME_SHOWN_FLAG="${TEMP_DIR}/.welcome_shown"

# 主程序启动逻辑
main() {
  # 检查是否已显示欢迎信息
  if [ ! -f "$WELCOME_SHOWN_FLAG" ]; then
    # 首次运行，显示欢迎横幅和帮助文档
    WELCOME_BANNER
    # 创建标志文件
    touch "$WELCOME_SHOWN_FLAG"
  fi
  
  # 主程序循环
  while true; do 
    show_menu
  done
}

# 执行主程序
main
