#!/usr/bin/env bash
#
# 非交互：按 VPC 列表为各 VPC 下全部关联路由表添加/更新指向指定 Transit Gateway 的 IPv4 路由。
#
# 用法:
#   ./apply-tgw-routes-to-vpcs.sh -r us-west-2 \
#     --vpcs vpc-aaa,vpc-bbb \
#     --tgw tgw-0123456789abcdef0 \
#     --cidr 10.0.0.0/8 --cidr 172.16.0.0/12
#
#   ./apply-tgw-routes-to-vpcs.sh --region ap-northeast-1 \
#     --vpcs "vpc-1 vpc-2" \
#     --transit-gateway-id tgw-xxx \
#     --cidrs 192.168.0.0/16 \
#     --on-conflict replace --yes
#
set -euo pipefail

export AWS_PAGER="${AWS_PAGER:-}"

DRY_RUN="${DRY_RUN:-0}"
REGION=""
VPCS_RAW=""
TGW_ID=""
CIDRS_CLI=()
ON_CONFLICT="skip" # skip | replace | fail
SKIP_CONFIRM=0
SKIP_ATTACHMENT_CHECK=0

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[信息] $*"; }
warn() { echo "[警告] $*" >&2; }

usage() {
  cat <<'EOF' >&2
用法: apply-tgw-routes-to-vpcs.sh [选项]

必填:
  -r, --region <区域>              例如 us-west-2、ap-northeast-1
      --vpcs <列表>                 VPC ID 列表，逗号或空格分隔，例: vpc-1,vpc-2 或 "vpc-1 vpc-2"
      --tgw, --transit-gateway-id <id>   Transit Gateway ID，例: tgw-0123456789abcdef0
      --cidr <CIDR>                 IPv4 CIDR，可重复多次
      --cidrs <列表>                逗号或空格分隔的多个 CIDR（与 --cidr 可混用）

可选:
  -n, --dry-run                     仅打印将执行的操作，不调用 create-route / replace-route
      --on-conflict <策略>          当目的 CIDR 已存在且下一跳不是所选 TGW 时:
                                    skip   — 跳过（默认）
                                    replace — replace-route 指向该 TGW
                                    fail   — 遇到即退出码 1
  -y, --yes                         跳过执行前确认
      --skip-attachment-check       不检查 VPC 与 TGW 的 VPC attachment（默认会检查并警告）
  -h, --help                        显示本说明

环境变量 DRY_RUN=1 等同 --dry-run（命令行优先）。
EOF
}

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --dry-run)
        DRY_RUN=1
        shift
        ;;
      -r | --region)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数"
        REGION="$2"
        shift 2
        ;;
      --region=*)
        REGION="${1#*=}"
        [[ -n "$REGION" ]] || die "--region= 后需要区域"
        shift
        ;;
      --vpcs)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数"
        VPCS_RAW="$2"
        shift 2
        ;;
      --vpcs=*)
        VPCS_RAW="${1#*=}"
        [[ -n "$VPCS_RAW" ]] || die "--vpcs= 后需要列表"
        shift
        ;;
      --tgw | --transit-gateway-id)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数"
        TGW_ID="$2"
        shift 2
        ;;
      --tgw=*)
        TGW_ID="${1#*=}"
        [[ -n "$TGW_ID" ]] || die "--tgw= 后需要 ID"
        shift
        ;;
      --transit-gateway-id=*)
        TGW_ID="${1#*=}"
        [[ -n "$TGW_ID" ]] || die "--transit-gateway-id= 后需要 ID"
        shift
        ;;
      --cidr)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数"
        CIDRS_CLI+=("$2")
        shift 2
        ;;
      --cidr=*)
        CIDRS_CLI+=("${1#*=}")
        shift
        ;;
      --cidrs)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数"
        CIDRS_CLI+=("$2")
        shift 2
        ;;
      --cidrs=*)
        CIDRS_CLI+=("${1#*=}")
        shift
        ;;
      --on-conflict)
        [[ -n "${2:-}" ]] || die "选项 $1 需要参数"
        ON_CONFLICT="$2"
        shift 2
        ;;
      --on-conflict=*)
        ON_CONFLICT="${1#*=}"
        shift
        ;;
      -y | --yes)
        SKIP_CONFIRM=1
        shift
        ;;
      --skip-attachment-check)
        SKIP_ATTACHMENT_CHECK=1
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

  case "${ON_CONFLICT,,}" in
    skip | replace | fail) ON_CONFLICT="${ON_CONFLICT,,}" ;;
    *) die "无效 --on-conflict: $ON_CONFLICT（应为 skip|replace|fail）" ;;
  esac
}

normalize_vpc_list() {
  VPC_IDS=()
  local norm raw v
  raw="$(trim "$VPCS_RAW")"
  [[ -n "$raw" ]] || die "--vpcs 为空"
  norm="${raw//,/ }"
  read -ra _VPC_TMP <<< "$norm"
  for v in "${_VPC_TMP[@]}"; do
    v="$(trim "$v")"
    [[ -z "$v" ]] && continue
    [[ "$v" == vpc-* ]] || die "无效的 VPC ID（应以 vpc- 开头）: $v"
    VPC_IDS+=("$v")
  done
  [[ ${#VPC_IDS[@]} -gt 0 ]] || die "解析 --vpcs 后为空"
}

normalize_cidr_list() {
  CIDRS=()
  local part c chunk
  for chunk in "${CIDRS_CLI[@]}"; do
    chunk="$(trim "$chunk")"
    [[ -z "$chunk" ]] && continue
    local norm="${chunk//,/ }"
    read -ra parts <<< "$norm"
    for part in "${parts[@]}"; do
      part="$(trim "$part")"
      [[ -z "$part" ]] && continue
      [[ "$part" == \#* ]] && continue
      is_valid_ipv4_cidr "$part" || die "无效 CIDR: $part"
      CIDRS+=("$part")
    done
  done
  [[ ${#CIDRS[@]} -gt 0 ]] || die "请通过 --cidr 或 --cidrs 提供至少一个 IPv4 CIDR"
}

# 返回: none | same_tgw | conflict|<描述>
route_status_for_cidr() {
  local region="$1" rtb="$2" cidr="$3" tgw="$4"
  local json match tgw_hit desc
  json="$(aws ec2 describe-route-tables --region "$region" --route-table-ids "$rtb" --output json)"
  match="$(echo "$json" | jq -c --arg c "$cidr" '.RouteTables[0].Routes[] | select(.DestinationCidrBlock == $c)' | head -n1)"
  if [[ -z "$match" || "$match" == "null" ]]; then
    echo "none"
    return
  fi
  tgw_hit="$(echo "$match" | jq -r --arg t "$tgw" 'if (.TransitGatewayId // "") == $t then "yes" else "no" end')"
  if [[ "$tgw_hit" == "yes" ]]; then
    echo "same_tgw"
    return
  fi
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

list_route_tables_for_vpc() {
  local region="$1" vpc="$2"
  local out
  out="$(aws ec2 describe-route-tables --region "$region" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)"
  [[ -z "${out// }" ]] && return 0
  echo "$out" | tr '\t' '\n' | grep -E '^rtb-' || true
}

vpc_exists() {
  local region="$1" vpc="$2"
  aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc" --query 'length(Vpcs)' --output text 2>/dev/null | grep -q '^1$'
}

apply_one_rtb_cidr() {
  local region="$1" rtb="$2" cidr="$3" tgw="$4"
  local st desc
  st="$(route_status_for_cidr "$region" "$rtb" "$cidr" "$tgw")"
  case "$st" in
    none)
      info "$rtb $cidr -> create-route (TGW)"
      if [[ "$DRY_RUN" != "1" ]]; then
        aws ec2 create-route --region "$region" --route-table-id "$rtb" \
          --destination-cidr-block "$cidr" --transit-gateway-id "$tgw" >/dev/null
      fi
      ;;
    same_tgw)
      info "$rtb $cidr -> 已存在且指向同一 TGW，跳过"
      ;;
    conflict*)
      desc="${st#conflict|}"
      case "$ON_CONFLICT" in
        skip)
          warn "$rtb $cidr 冲突（$desc），按策略跳过"
          ;;
        replace)
          info "$rtb $cidr -> replace-route (TGW)，原下一跳: $desc"
          if [[ "$DRY_RUN" != "1" ]]; then
            aws ec2 replace-route --region "$region" --route-table-id "$rtb" \
              --destination-cidr-block "$cidr" --transit-gateway-id "$tgw" >/dev/null
          fi
          ;;
        fail)
          die "$rtb $cidr 冲突（$desc），--on-conflict fail"
          ;;
      esac
      ;;
    *)
      die "未知路由状态: $st"
      ;;
  esac
}

main() {
  parse_args "$@"
  [[ -n "$REGION" ]] || die "缺少 --region"
  [[ -n "$TGW_ID" ]] || die "缺少 --tgw / --transit-gateway-id"
  [[ "$TGW_ID" == tgw-* ]] || die "无效的 TGW ID（应以 tgw- 开头）: $TGW_ID"
  normalize_vpc_list
  normalize_cidr_list

  need_cmd aws
  need_cmd jq

  [[ "${DRY_RUN:-0}" == "1" ]] && warn "DRY_RUN：不会执行 create-route / replace-route"

  local vpc rtb cidr
  for vpc in "${VPC_IDS[@]}"; do
    vpc_exists "$REGION" "$vpc" || die "VPC 不存在或无权访问: $vpc (region=$REGION)"
    if [[ "$SKIP_ATTACHMENT_CHECK" != "1" ]]; then
      if ! attachment_ok_for_vpc_tgw "$REGION" "$vpc" "$TGW_ID"; then
        warn "VPC $vpc 未检测到与 TGW $TGW_ID 的 available/pending VPC attachment，create-route 可能失败。"
      fi
    fi
  done

  echo
  echo "将要执行:"
  echo "  区域:   $REGION"
  echo "  VPC:    ${VPC_IDS[*]}"
  echo "  TGW:    $TGW_ID"
  echo "  CIDR:   ${CIDRS[*]}"
  echo "  冲突:   $ON_CONFLICT"
  [[ "$DRY_RUN" == "1" ]] && echo "  模式:   干跑"
  if [[ "$SKIP_CONFIRM" != "1" ]]; then
    read -r -p "确认执行？[y/N] " _yn
    case "${_yn,,}" in
      y | yes) ;;
      *) echo "已取消。" >&2; exit 0 ;;
    esac
  fi

  for vpc in "${VPC_IDS[@]}"; do
    info "处理 VPC: $vpc"
    mapfile -t RTBS < <(list_route_tables_for_vpc "$REGION" "$vpc")
    [[ ${#RTBS[@]} -gt 0 ]] || die "VPC $vpc 下未找到关联路由表"
    for rtb in "${RTBS[@]}"; do
      for cidr in "${CIDRS[@]}"; do
        apply_one_rtb_cidr "$REGION" "$rtb" "$cidr" "$TGW_ID"
      done
    done
  done

  info "完成。"
}

main "$@"
