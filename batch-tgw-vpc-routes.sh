#!/usr/bin/env bash
#
# CloudShell / Bash: 按 VPC 批量为关联路由表添加指向 Transit Gateway 的 IPv4 路由。
# - 默认区域: us-west-2, us-east-2（可通过环境变量 REGIONS 覆盖）
# - 冲突检测: 同目的 CIDR 已存在且下一跳不是所选 TGW 时提示，并可选择跳过/替换/中止
# - TGW: 从当前区域动态列举，交互选择
#
# 用法:
#   ./batch-tgw-vpc-routes.sh
#   ./batch-tgw-vpc-routes.sh --dry-run
#   ./batch-tgw-vpc-routes.sh --regions us-west-2,us-east-2
#   ./batch-tgw-vpc-routes.sh -n -r ap-northeast-1
#   DRY_RUN=1 REGIONS="us-west-2" ./batch-tgw-vpc-routes.sh   # 环境变量仍可用；命令行优先于 REGIONS
#
set -euo pipefail

# 避免 AWS CLI v2 在交互环境打开 less 阻塞脚本
export AWS_PAGER="${AWS_PAGER:-}"

DEFAULT_REGIONS=(us-west-2 us-east-2)
DRY_RUN="${DRY_RUN:-0}"

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[信息] $*"; }
warn() { echo "[警告] $*" >&2; }

usage() {
  cat <<'EOF' >&2
用法: batch-tgw-vpc-routes.sh [选项]

  -n, --dry-run              仅预览，不执行 create-route / replace-route
  -r, --regions <列表>       候选区域，逗号或空格分隔，例: ap-northeast-1 或 us-west-2,us-east-2
  -h, --help                 显示本说明并退出

环境变量 DRY_RUN=1、REGIONS="a b" 仍可用；若传入 --regions / -r，则以命令行为准（忽略环境变量 REGIONS）。
EOF
}

parse_args() {
  REGIONS_CLI=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --dry-run)
        DRY_RUN=1
        shift
        ;;
      -r | --regions)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数（区域列表）"
        REGIONS_CLI="$2"
        shift 2
        ;;
      --regions=*)
        REGIONS_CLI="${1#*=}"
        [[ -n "$REGIONS_CLI" ]] || die "--regions= 后需要区域列表"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1（使用 --help）"
        ;;
    esac
  done

  if [[ -n "${REGIONS_CLI}" ]]; then
    REGIONS=()
    local _norm
    _norm="${REGIONS_CLI//,/ }"
    read -ra REGIONS <<< "${_norm}"
    [[ ${#REGIONS[@]} -gt 0 ]] || die "--regions 解析后为空"
  else
    # shellcheck disable=SC2206
    REGIONS=( ${REGIONS:-} )
    if [[ ${#REGIONS[@]} -eq 0 ]]; then
      REGIONS=("${DEFAULT_REGIONS[@]}")
    fi
  fi
}

parse_args "$@"
unset REGIONS_CLI

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令: $1（CloudShell 通常已预装 aws/jq）"
}

need_cmd aws
need_cmd jq

is_valid_ipv4_cidr() {
  local c="$1"
  [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  return 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 从终端读取 CIDR 列表，写入全局数组 CIDRS（避免 mapfile 子 shell 吞掉提示且导致 die 不可靠）
read_cidrs_into_array() {
  CIDRS=()
  echo >&2
  echo >&2 "请输入对端/汇总 IPv4 CIDR，每行一个（例: 10.0.0.0/8）。空行结束输入；行首 # 为注释。"
  local line
  while IFS= read -r line < /dev/tty; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && break
    [[ "$line" == \#* ]] && continue
    is_valid_ipv4_cidr "$line" || die "无效 CIDR: $line"
    CIDRS+=("$line")
  done
  [[ ${#CIDRS[@]} -eq 0 ]] && die "未输入任何 CIDR"
}

prompt_yn() {
  local msg="$1" d="${2:-n}"
  local hint="[y/N]"
  [[ "$d" == "y" ]] && hint="[Y/n]"
  while true; do
    read -r -p "$msg $hint " a
    a="${a:-$d}"
    case "${a,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "请输入 y 或 n" ;;
    esac
  done
}

# 返回: none | same_tgw | conflict|<描述>
route_status_for_cidr() {
  local region="$1" rtb="$2" cidr="$3" tgw="$4"
  local json
  json="$(aws ec2 describe-route-tables --region "$region" --route-table-ids "$rtb" --output json)"
  local match
  match="$(echo "$json" | jq -c --arg c "$cidr" '.RouteTables[0].Routes[] | select(.DestinationCidrBlock == $c)' | head -n1)"
  if [[ -z "$match" || "$match" == "null" ]]; then
    echo "none"
    return
  fi
  local tgw_hit
  tgw_hit="$(echo "$match" | jq -r --arg t "$tgw" 'if (.TransitGatewayId // "") == $t then "yes" else "no" end')"
  if [[ "$tgw_hit" == "yes" ]]; then
    echo "same_tgw"
    return
  fi
  local desc
  desc="$(echo "$match" | jq -r '
    if .GatewayId == "local" then "local(VPC本地)"
    elif (.GatewayId // "") != "" then "GatewayId=\(.GatewayId)"
    elif (.NatGatewayId // "") != "" then "NatGatewayId=\(.NatGatewayId)"
    elif (.TransitGatewayId // "") != "" then "TransitGatewayId=\(.TransitGatewayId)"
    elif (.VpcPeeringConnectionId // "") != "" then "VpcPeeringConnectionId=\(.VpcPeeringConnectionId)"
    elif (.NetworkInterfaceId // "") != "" then "NetworkInterfaceId=\(.NetworkInterfaceId)"
    elif (.InstanceId // "") != "" then "InstanceId=\(.InstanceId)"
    elif (.VpcEndpointId // "") != "" then "VpcEndpointId=\(.VpcEndpointId)"
    elif (.CarrierGatewayId // "") != "" then "CarrierGatewayId=\(.CarrierGatewayId)"
    elif (.LocalGatewayId // "") != "" then "LocalGatewayId=\(.LocalGatewayId)"
    elif (.CoreNetworkArn // "") != "" then "CoreNetworkArn=\(.CoreNetworkArn)"
    else "其他/未知下一跳"
    end')"
  echo "conflict|${desc}"
}

attachment_ok_for_vpc_tgw() {
  local region="$1" vpc="$2" tgw="$3"
  local cnt
  cnt="$(aws ec2 describe-transit-gateway-attachments \
    --region "$region" \
    --filters \
      "Name=transit-gateway-id,Values=$tgw" \
      "Name=resource-type,Values=vpc" \
      "Name=resource-id,Values=$vpc" \
      "Name=state,Values=available,pending" \
    --query 'length(TransitGatewayAttachments)' \
    --output text 2>/dev/null || echo 0)"
  [[ "${cnt:-0}" != "0" ]]
}

print_region_header() {
  echo
  echo "========== 区域: $1 =========="
}

list_vpcs_summary() {
  local region="$1"
  aws ec2 describe-vpcs --region "$region" --output json | jq -r '
    .Vpcs[] |
    [
      .VpcId,
      (.Tags // [] | map(select(.Key=="Name")) | .[0].Value // "-"),
      (.CidrBlock // "-"),
      (if .IsDefault then "default" else "custom" end)
    ] | @tsv' | sort -t$'\t' -k2
}

list_route_tables_for_vpc() {
  local region="$1" vpc="$2"
  local out
  out="$(aws ec2 describe-route-tables --region "$region" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)"
  [[ -z "${out// }" ]] && return 0
  echo "$out" | tr '\t' '\n' | grep -E '^rtb-' || true
}

describe_rtb_one_line() {
  local region="$1" rtb="$2" tgw="$3"
  local json main tags routes
  json="$(aws ec2 describe-route-tables --region "$region" --route-table-ids "$rtb" --output json)"
  main="$(echo "$json" | jq -r '
    .RouteTables[0] as $rt
    | if (($rt.Associations // []) | map(select(.Main == true)) | length) > 0 then "main" else "subnet" end')"
  tags="$(echo "$json" | jq -r '.RouteTables[0].Tags // [] | map(select(.Key=="Name")) | .[0].Value // "-"')"
  routes="$(echo "$json" | jq -r --arg t "$tgw" '[.RouteTables[0].Routes[] | select((.TransitGatewayId // "") == $t) | .DestinationCidrBlock] | length')"
  printf '%s\t%s\t%s\t指向所选TGW:%s条\n' "$rtb" "$main" "$tags" "$routes"
}

list_tgws_menu() {
  local region="$1"
  aws ec2 describe-transit-gateways --region "$region" --output json | jq -r '
    .TransitGateways[]
    | select(.State == "available")
    | [
        .TransitGatewayId,
        (.Description // "-"),
        (.Tags // [] | map(select(.Key=="Name")) | .[0].Value // "-")
      ] | @tsv' | sort
}

select_from_menu() {
  local title="$1"
  shift
  local -a rows=("$@")
  [[ ${#rows[@]} -eq 0 ]] && die "$title：无可用项"
  echo >&2
  echo >&2 "--- $title ---"
  local i=1
  local line
  for line in "${rows[@]}"; do
    printf '%2d) %s\n' "$i" "$line" >&2
    ((i++)) || true
  done
  local pick
  while true; do
    read -r -p "请输入序号 (1-${#rows[@]}): " pick >&2
    [[ "$pick" =~ ^[0-9]+$ ]] || { echo "请输入数字" >&2; continue; }
    (( pick >= 1 && pick <= ${#rows[@]} )) || { echo "序号超出范围" >&2; continue; }
    printf '%s\n' "${rows[$((pick-1))]}"
    return
  done
}

main() {
  info "区域列表: ${REGIONS[*]}"
  [[ "$DRY_RUN" == "1" ]] && warn "DRY_RUN=1：不会执行 create-route / replace-route"

  echo
  echo "请选择要查看/操作的区域:"
  local -a reg_lines=()
  local r
  for r in "${REGIONS[@]}"; do
    reg_lines+=("$r")
  done
  local reg_pick
  reg_pick="$(select_from_menu "区域" "${reg_lines[@]}")"
  REGION="$reg_pick"
  print_region_header "$REGION"

  info "列举 VPC（VpcId / Name / Cidr / 类型）"
  mapfile -t VPC_ROWS < <(list_vpcs_summary "$REGION")
  [[ ${#VPC_ROWS[@]} -eq 0 ]] && die "该区域无 VPC"

  echo
  printf '%-22s %-28s %-18s %s\n' "VpcId" "Name" "CidrBlock" "类型"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local row vid name cidr typ
  local -a VPC_IDS=()
  for row in "${VPC_ROWS[@]}"; do
    IFS=$'\t' read -r vid name cidr typ <<<"$row"
    VPC_IDS+=("$vid")
    printf '%-22s %-28s %-18s %s\n' "$vid" "$name" "$cidr" "$typ"
  done

  echo
  local vpc_pick_idx
  while true; do
    read -r -p "请输入要操作的 VPC 序号 (1-${#VPC_IDS[@]}): " vpc_pick_idx
    [[ "$vpc_pick_idx" =~ ^[0-9]+$ ]] || { echo "请输入数字"; continue; }
    (( vpc_pick_idx >= 1 && vpc_pick_idx <= ${#VPC_IDS[@]} )) || { echo "序号超出范围"; continue; }
    break
  done
  VPC_ID="${VPC_IDS[$((vpc_pick_idx-1))]}"
  info "已选 VPC: $VPC_ID"

  echo
  info "列举当前区域可用的 Transit Gateway（State=available）"
  mapfile -t TGW_ROWS < <(list_tgws_menu "$REGION")
  [[ ${#TGW_ROWS[@]} -eq 0 ]] && die "该区域没有 state=available 的 TGW，请换区域或先创建 TGW"

  local tgw_line
  tgw_line="$(select_from_menu "Transit Gateway" "${TGW_ROWS[@]}")"
  TGW_ID="$(echo "$tgw_line" | awk -F'\t' '{print $1}')"
  info "已选 TGW: $TGW_ID"

  if ! attachment_ok_for_vpc_tgw "$REGION" "$VPC_ID" "$TGW_ID"; then
    warn "未检测到该 VPC 与所选 TGW 的可用/挂起中的 VPC Attachment（resource-id=$VPC_ID）。"
    warn "继续执行可能因无 Attachment 导致 create-route 失败。建议先在 TGW 上完成 VPC 挂载。"
    prompt_yn "仍要继续？" "n" || exit 0
  fi

  read_cidrs_into_array

  echo
  info "以下路由表属于 VPC $VPC_ID ："
  mapfile -t RTBS < <(list_route_tables_for_vpc "$REGION" "$VPC_ID")
  [[ ${#RTBS[@]} -eq 0 ]] && die "未找到关联路由表"

  printf '%s\n' "RouteTableId(main/subnet) Name 指向所选TGW的IPv4路由条数"
  printf '%s\n' "------------------------------------------------------------------"
  for rtb in "${RTBS[@]}"; do
    describe_rtb_one_line "$REGION" "$rtb" "$TGW_ID"
  done | column -t -s $'\t' 2>/dev/null || true

  echo
  echo "全局冲突处理策略（当某 CIDR 在路由表中已存在且下一跳不是所选 TGW 时）:"
  echo "  1) 逐项询问（默认）"
  echo "  2) 全部跳过冲突（不修改已有路由）"
  echo "  3) 全部替换为指向所选 TGW（replace-route）"
  read -r -p "请选择 [1/2/3] (默认 1): " POLICY
  POLICY="${POLICY:-1}"
  [[ "$POLICY" =~ ^[123]$ ]] || die "无效策略: $POLICY"

  echo
  echo "将要执行:"
  echo "  区域:   $REGION"
  echo "  VPC:    $VPC_ID"
  echo "  TGW:    $TGW_ID"
  echo "  路由表: ${RTBS[*]}"
  echo "  CIDR:   ${CIDRS[*]}"
  [[ "$DRY_RUN" == "1" ]] && echo "  模式:   干跑（不写 API 变更）"
  prompt_yn "确认执行？" "n" || exit 0

  local rtb cidr st desc action
  for rtb in "${RTBS[@]}"; do
    for cidr in "${CIDRS[@]}"; do
      st="$(route_status_for_cidr "$REGION" "$rtb" "$cidr" "$TGW_ID")"
      case "$st" in
        none)
          info "$rtb $cidr -> create-route (TGW)"
          if [[ "$DRY_RUN" != "1" ]]; then
            aws ec2 create-route --region "$REGION" --route-table-id "$rtb" \
              --destination-cidr-block "$cidr" --transit-gateway-id "$TGW_ID" >/dev/null
          fi
          ;;
        same_tgw)
          info "$rtb $cidr -> 已存在且指向同一 TGW，跳过"
          ;;
        conflict*)
          desc="${st#conflict|}"
          warn "$rtb $cidr 冲突: 当前下一跳为 $desc"
          action=""
          case "$POLICY" in
            1)
              echo "  处理方式: [s]跳过  [r]替换为TGW  [a]中止整个脚本"
              while true; do
                read -r -p "  请选择 s/r/a: " a
                case "${a,,}" in
                  s) action="skip"; break ;;
                  r) action="replace"; break ;;
                  a) action="abort"; break ;;
                  *) echo "  无效输入" ;;
                esac
              done
              ;;
            2) action="skip" ;;
            3) action="replace" ;;
          esac
          if [[ "$action" == "abort" ]]; then
            die "用户中止"
          fi
          if [[ "$action" == "skip" ]]; then
            info "$rtb $cidr -> 跳过（保留原路由）"
            continue
          fi
          if [[ "$action" == "replace" ]]; then
            info "$rtb $cidr -> replace-route (TGW)"
            if [[ "$DRY_RUN" != "1" ]]; then
              aws ec2 replace-route --region "$REGION" --route-table-id "$rtb" \
                --destination-cidr-block "$cidr" --transit-gateway-id "$TGW_ID" >/dev/null
            fi
          fi
          ;;
        *)
          die "未知路由状态: $st"
          ;;
      esac
    done
  done

  info "完成。"
}

main
