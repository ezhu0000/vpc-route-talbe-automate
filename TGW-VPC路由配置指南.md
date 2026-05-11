# TGW VPC 路由配置指南

本文档说明仓库根目录下两个 Bash 脚本的用途、交互流程、命令行参数与行为约定。适用于 **AWS CloudShell** 或已安装 **AWS CLI v2**、`bash` 4+、`jq` 的环境。

## 背景

Transit Gateway 侧路由由 TGW/BGP 等机制维护，**VPC 子网路由表不会自动出现指向 TGW 的静态路由**。若需经 TGW 访问对端网段，要在各子网/主路由表上显式执行 `create-route`（必要时 `replace-route`）。本仓库脚本用于按 VPC 批量写入 **IPv4** 目的网段、下一跳为指定 TGW 的路由。

## 依赖

- AWS CLI v2（已配置凭证或角色）
- `bash` 4+
- `jq`

建议关闭分页以免阻塞：`export AWS_PAGER=""`（脚本内已尽量设置）。

## 建议权限

目标账号/角色至少需：

- `ec2:DescribeVpcs`、`ec2:DescribeRouteTables`
- `ec2:CreateRoute`、`ec2:ReplaceRoute`（实际变更时）
- `ec2:DescribeTransitGateways`、`ec2:DescribeTransitGatewayAttachments`

可按最小权限收紧到具体 VPC/TGW/路由表资源；快速验证时常用 `AmazonVPCFullAccess` 一类策略（生产环境请收紧）。

## 从 GitHub 获取脚本

仓库：[vpc-route-talbe-automate](https://github.com/ezhu0000/vpc-route-talbe-automate)（`main` 分支根目录）。

| 脚本 | GitHub 浏览（blob） | raw 直链（供 `curl -o`） |
|------|---------------------|-------------------------|
| 交互 | [batch-tgw-vpc-routes.sh](https://github.com/ezhu0000/vpc-route-talbe-automate/blob/main/batch-tgw-vpc-routes.sh) | `https://raw.githubusercontent.com/ezhu0000/vpc-route-talbe-automate/main/batch-tgw-vpc-routes.sh` |
| 非交互 | [apply-tgw-routes-to-vpcs.sh](https://github.com/ezhu0000/vpc-route-talbe-automate/blob/main/apply-tgw-routes-to-vpcs.sh) | `https://raw.githubusercontent.com/ezhu0000/vpc-route-talbe-automate/main/apply-tgw-routes-to-vpcs.sh` |

示例（与 [README.md](https://github.com/ezhu0000/vpc-route-talbe-automate/blob/main/README.md) 中一致）：

```bash
curl -fsSL -o batch-tgw-vpc-routes.sh \
  https://raw.githubusercontent.com/ezhu0000/vpc-route-talbe-automate/main/batch-tgw-vpc-routes.sh
chmod +x batch-tgw-vpc-routes.sh

# 可选
curl -fsSL -o apply-tgw-routes-to-vpcs.sh \
  https://raw.githubusercontent.com/ezhu0000/vpc-route-talbe-automate/main/apply-tgw-routes-to-vpcs.sh
chmod +x apply-tgw-routes-to-vpcs.sh
```

## 脚本对照

| 文件 | 模式 | 适用场景 |
|------|------|----------|
| `batch-tgw-vpc-routes.sh` | 交互 | 在终端里选区域、多选 VPC、选 TGW、粘贴 CIDR、选冲突策略 |
| `apply-tgw-routes-to-vpcs.sh` | 非交互 | CI/CD、重复执行：传入区域、VPC 列表、TGW ID、CIDR |

两者对**每个所选 VPC** 均通过 `describe-route-tables`（`vpc-id` 过滤）作用于该 VPC 下**全部**关联路由表（含主表与各子网关联表）。

---

## 一、`batch-tgw-vpc-routes.sh`（交互）

### 交互流程

1. 选择**区域**（来自启动时候选区域列表，见下文 `-r` / `REGIONS`）。
2. 列出当前区域 **VPC**（VpcId / Name / CidrBlock / 类型）。
3. **多选 VPC**：输入序号，**逗号或空格**分隔（例：`1,3,5` 或 `1 3 5`）；输入 **`all`** 表示全选。重复序号会去重。
4. 列出 **`State=available`** 的 Transit Gateway，**选择一个**。
5. 对每个所选 VPC 检查是否存在指向该 TGW 的 **VPC 类型** Attachment（`available` / `pending`）；若有 VPC 未挂载，会**汇总警告**并**只询问一次**是否继续。
6. **输入 CIDR**：每行一个 IPv4 CIDR，`#` 开头为注释，**单独一行空行**表示结束。
7. 按 VPC 展示关联**路由表预览**（主表/子网表、名称、已指向所选 TGW 的 IPv4 条数等）。
8. 选择**全局冲突策略**（见下文），确认后执行。

### 命令行参数

| 选项 | 说明 |
|------|------|
| `-n` / `--dry-run` | 仅预览，不调用 `create-route` / `replace-route` |
| `-r <列表>` / `--regions <列表>` / `--regions=<列表>` | 候选区域，逗号或空格分隔；指定后**不再**读取环境变量 `REGIONS` |
| `-h` / `--help` | 打印说明并退出 |

### 环境变量

| 变量 | 说明 |
|------|------|
| `REGIONS` | 未传 `--regions` 时生效，空格分隔；未设置时默认为 `us-west-2 us-east-2` |
| `DRY_RUN=1` | 等同 `--dry-run`；若已加 `-n`，以命令行为准 |

### 冲突策略（交互脚本）

当某路由表上该 CIDR **已存在**且下一跳**不是**所选 TGW（如 `local`、IGW、NAT、Peering、其他 TGW 等）：

1. **逐项询问**（默认）：每条冲突可选跳过、替换为 TGW，或中止脚本。
2. **全部跳过**：不修改已有路由。
3. **全部替换**：对冲突项执行 `replace-route` 指向所选 TGW。

### 示例

```bash
chmod +x batch-tgw-vpc-routes.sh
./batch-tgw-vpc-routes.sh --regions ap-northeast-1
./batch-tgw-vpc-routes.sh -n -r us-west-2,us-east-2
```

---

## 二、`apply-tgw-routes-to-vpcs.sh`（非交互）

### 必填参数

| 参数 | 说明 |
|------|------|
| `-r` / `--region` | 区域，如 `us-west-2` |
| `--vpcs` | VPC ID 列表，逗号或空格分隔 |
| `--tgw` 或 `--transit-gateway-id` | Transit Gateway ID |
| `--cidr` | 可重复；或配合 `--cidrs`（逗号/空格分隔多个 CIDR） |

### 可选参数

| 参数 | 说明 |
|------|------|
| `-n` / `--dry-run` | 不执行写 API |
| `--on-conflict skip` | 冲突时跳过（默认） |
| `--on-conflict replace` | 冲突时 `replace-route` 指向该 TGW |
| `--on-conflict fail` | 遇冲突即退出码 1 |
| `-y` / `--yes` | 跳过执行前确认 |
| `--skip-attachment-check` | 不做 TGW VPC attachment 检查（仍会执行路由 API） |
| `-h` / `--help` | 帮助 |

环境变量 `DRY_RUN=1` 等同 `--dry-run`。

### 示例

```bash
chmod +x apply-tgw-routes-to-vpcs.sh

./apply-tgw-routes-to-vpcs.sh -r us-west-2 \
  --vpcs vpc-0aaa,vpc-0bbb \
  --tgw tgw-0123456789abcdef0 \
  --cidr 10.0.0.0/8 --cidr 172.16.0.0/12 \
  --on-conflict skip -y
```

---

## 共同行为与注意

- **仅 IPv4**：使用 `DestinationCidrBlock`，不支持 IPv6（若需 IPv6 需另写 `create-route` 的 IPv6 参数）。
- **幂等**：若该 CIDR **已指向同一 TGW**，跳过。
- **最长前缀匹配**：汇总大网段（如 `10.0.0.0/8`）与 VPC 本地更具体路由并存时，以更长前缀为准。
- **`replace-route` 失败**：与路由语义或 AWS 限制冲突时，CLI 可能报错；脚本启用了 `set -e`，失败会导致退出，需按报错调整 CIDR 或设计。

## 仓库根目录文件

| 文件 | 说明 |
|------|------|
| `batch-tgw-vpc-routes.sh` | 交互式批量配置 |
| `apply-tgw-routes-to-vpcs.sh` | 命令行参数批量配置 |
| `README.md` | 简要说明 |
| `TGW-VPC路由配置指南.md` | 本文档 |
