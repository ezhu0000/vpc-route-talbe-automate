# TGW VPC 路由批量配置脚本

在 **AWS CloudShell**（或已安装 AWS CLI v2、`jq`、`bash` 的 Linux/macOS）中，按 **VPC** 为其下所有关联 **子网/主路由表** 批量添加指向 **Transit Gateway** 的 IPv4 静态路由，并带 **冲突检测** 与 **TGW 动态选择**。

## 背景

Transit Gateway 与 BGP 只维护 TGW 侧路由；**VPC 子网路由表不会自动写入指向 TGW 的路由**，需显式 `create-route`。本脚本用于批量完成该步骤，适合与「汇总大网段（如 `10.0.0.0/8`）指向 TGW」类方案配合使用。

## 依赖

- AWS CLI v2（已配置凭证/角色）
- `bash` 4+
- `jq`

CloudShell 默认满足上述条件。

## 权限建议

对目标 VPC 所在账号/角色至少需要：

- `ec2:DescribeVpcs`、`ec2:DescribeRouteTables`
- `ec2:CreateRoute`、`ec2:ReplaceRoute`（实际写入时）
- `ec2:DescribeTransitGateways`、`ec2:DescribeTransitGatewayAttachments`

例如托管策略：`AmazonVPCFullAccess`（按组织最小权限原则可再收紧到具体资源）。

## 使用方法

在 **AWS CloudShell** 中执行：

```bash
curl -fsSL -o batch-tgw-vpc-routes.sh \
  https://raw.githubusercontent.com/ezhu0000/vpc-route-talbe-automate/main/batch-tgw-vpc-routes.sh
chmod +x batch-tgw-vpc-routes.sh
./batch-tgw-vpc-routes.sh
```

按提示选择：**区域** → **多选 VPC**（序号逗号/空格分隔，或 `all` 全选）→ **Transit Gateway** → **多行 CIDR（空行结束）** → **冲突策略** → **确认**。

### 命令行参数（推荐）

| 选项 | 说明 |
|------|------|
| `-n` / `--dry-run` | 仅预览，不执行 `create-route` / `replace-route` |
| `-r <列表>` / `--regions <列表>` / `--regions=<列表>` | 候选区域，逗号或空格分隔。若指定，则**不再**读取环境变量 `REGIONS` |
| `-h` / `--help` | 打印说明并退出 |

示例：

```bash
./batch-tgw-vpc-routes.sh --dry-run
./batch-tgw-vpc-routes.sh --regions ap-northeast-1
./batch-tgw-vpc-routes.sh -n -r us-west-2,us-east-2
```

### 环境变量（可选，与命令行并存）

| 变量 | 说明 |
|------|------|
| `REGIONS` | 未使用 `-r` / `--regions` 时生效。空格分隔。未设置时默认为 `us-west-2 us-east-2`。 |
| `DRY_RUN` | 设为 `1` 等同 `--dry-run`；若命令行已加 `-n`，以命令行为准。 |

## 行为说明

- **作用范围**：所选 VPC 下，通过 `describe-route-tables`（`vpc-id` 过滤器）得到的**全部**关联路由表（含主表与各子网关联表）。
- **TGW**：仅列出当前区域中 `State=available` 的 Transit Gateway；选择后会检查是否存在指向该 VPC 的 **VPC 类型** Attachment（`available` / `pending`），缺失时会警告并询问是否继续。
- **CIDR 输入**：每行一个 IPv4 CIDR；`#` 开头为注释；空行结束。仅支持 IPv4（`DestinationCidrBlock`）。
- **幂等**：若某路由表上该 CIDR **已指向所选 TGW**，则跳过。
- **冲突**：若该 CIDR **已存在**且下一跳**不是**所选 TGW（如 IGW、NAT、Peering、另一 TGW、`local` 等），则根据策略处理：
  - **1 — 逐项询问**：每条冲突可选跳过、替换为 TGW，或中止整个脚本。
  - **2 — 全部跳过**：保留原有路由。
  - **3 — 全部替换**：对冲突项执行 `replace-route` 指向所选 TGW。

**注意**：若 AWS 不允许替换某条目的下一跳（例如与本地路由语义冲突），`replace-route` 可能失败并导致脚本因 `set -e` 退出；需根据 CLI 报错调整 CIDR 或路由设计。

## 与「大网段」方案的关系

在子网路由表中加入 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 等汇总路由指向 TGW 时，可将这些 CIDR 逐行粘贴进脚本；更长前缀的 VPC 本地路由仍优先（最长前缀匹配）。

## 文件

| 文件 | 说明 |
|------|------|
| `batch-tgw-vpc-routes.sh` | 交互式主脚本 |
| `apply-tgw-routes-to-vpcs.sh` | 非交互：VPC 列表 + TGW + CIDR |
| `TGW-VPC路由配置指南.md` | 两脚本参数与流程说明 |
