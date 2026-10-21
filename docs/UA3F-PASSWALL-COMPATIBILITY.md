# AX3000T：UA3F TPROXY + PassWall（firewall4 / nftables）

## 固件目标

- 硬件：小米 AX3000T V1（MT7531）与 V2（AN8855）分别编译、分别验证；只刷与实际硬件及 U-Boot 分区布局一致的镜像。
- 基础：OpenWrt 25.12、firewall4、nftables。
- 主流量改写：UA3F v3.7.0，TPROXY、端口 1080，默认全局改写。首启已启用 UA3F；User-Agent 使用项目要求的指定值。
- 代理：PassWall（不是 OpenClash），启用 nftables 透明代理后端；随固件编译 Xray 与 Sing-box，排除 Shadowsocks Rust，控制构建时间、闪存和内存负担。
- UI：LuCI 简体中文与 Argon v3 主题，主题设为默认。
- 必需 UA3F 依赖：`kmod-nft-queue`、`kmod-nft-tproxy`、`kmod-sched-bpf`、`libubox-lua`，并加入 conntrack-netlink、nftables 与 TC 工具。
- PassWall nftables 所需模块：`kmod-nft-socket`、`kmod-nft-nat`、`kmod-nf-reject`、`kmod-nf-reject6`、`kmod-nft-tproxy`。
- 软件/硬件 flow offloading 首启关闭，以免透明代理、NFQUEUE/Desync 与 TC eBPF 的数据路径被快速转发绕开。

## UA3F / PassWall 的流量分工

PassWall 当前 nftables 后端使用 fwmark `0x50535731`。UA3F 原本跳过 Clash 常见标记 `0x162`、`0x1ed4`；本工程在固定的 UA3F v3.7.0 源码中增加对 `0x50535731` 的跳过，并在构建前检查 PassWall 源码标记是否仍匹配。若上游标记变化，编译会失败而不是静默生成可能互抢的规则。

这套处理的含义是：

- PassWall 已选择接管并打上自己的标记的连接交给 PassWall，不再被 UA3F 二次 TPROXY 抢走。
- 不属于 PassWall 代理路径、没有该标记的 TCP 流量仍由 UA3F 处理。
- UA3F 仍保留对 Clash 常用标记及 Fake-IP 场景的上游兼容处理，但本固件**不安装 OpenClash**。

需要明确：这是两套透明代理的并行分工，避免冲突；它不等价于“同一条由 PassWall 接管的连接必然再经过 UA3F 改写”。如果要让每条 PassWall 代理连接都经过 UA3F 的 L7 改写，需要另行设计明确的代理链路，不能仅叠加两套 TPROXY 规则来保证。

## 已编译支持的 UA3F 功能

| 功能 | 固件支持 | 首启默认 |
|---|---|---|
| TPROXY | nftables 依赖已选中；TPROXY 模式与服务已配置启用 | 开启 |
| L3 TTL 重写 | UA3F LuCI 控件 + NFQUEUE 依赖 | 关闭，测试后再开 |
| L3 IPID 重写 | UA3F LuCI 控件 + NFQUEUE 依赖 | 关闭，测试后再开 |
| TCP 时间戳改写/删除 | UA3F LuCI 控件 + NFQUEUE 依赖 | 关闭，测试后再开 |
| TCP 初始窗口 | UA3F LuCI 控件 + NFQUEUE 依赖 | 关闭，测试后再开 |
| Desync 分片乱序/混淆注入 | LuCI 控件 + `kmod-nft-queue` | 关闭，按目标网络逐项验证 |
| TC eBPF L3 卸载 | `kmod-sched-bpf`、`tc-full` 与 LuCI 控件 | 关闭，先验证实际出口接口是否符合条件 |

**为什么不把所有高级功能首次开机全部打开：** Desync、QUIC 阻断、TCP 特征改写及 eBPF 都可能影响特定网站、游戏、校园认证或网络中继。先让 TPROXY 基线稳定，再逐项开启更容易定位故障。尤其 eBPF 不是只看内核版本：UA3F 还要找到带 IPv4 地址且属于 IPv4 默认路由的 Ethernet/PPP 出口接口。若实际接口不符合条件，会出现 `no eligible interfaces for TC`；把模块编进固件并不能代替接口条件验证。

## PassWall / DNS 注意事项

PassWall 使用自己的 nftables 规则和标记，第一次启动前应确认节点和 DNS 行为。首启将 dnsmasq include 目录固定为 `/tmp/dnsmasq.d`，并创建目录，用于兼容部分 OpenWrt 25.12 运行环境下 PassWall 查找 DNS 临时配置目录的情况。仍需查看启动日志以及生成的 `/var/etc/dnsmasq.conf.*` 内容，确认 `conf-dir` 指向实际目录。

PassWall 主服务保持其自身默认的未启用状态，待你导入节点后在 LuCI 内配置。优先使用 nftables 后端；本工程不提供旧 firewall3/iptables 作为并行代理后端。

## 自动构建与测试

打开 GitHub Actions 的 **Build Xiaomi AX3000T V1 and V2 firmware (UA3F TPROXY + PassWall)**。构建任务在编译前执行以下硬性检查：

1. 所需 UA3F 内核包与库在 `.config` 的 `make defconfig` 后仍被选中；
2. PassWall nftables 后端、Xray/Sing-box 与 Argon 已选中；
3. OpenClash 和 Shadowsocks Rust 未进入配置；
4. UA3F 包不再依赖旧 iptables 规则；
5. PassWall mark 与 UA3F 绕行补丁匹配；
6. UA3F LuCI 中 TTL、IPID、TCP 时间戳、TCP 窗口、eBPF 与 Desync 的控件都存在；
7. 首启模式、flow offloading、dnsmasq 目录与主题默认值符合预期。

构建通过只能证明配置解析、源码补丁与镜像生成通过；真实 TPROXY、eBPF、Desync 和 PassWall 代理连通性仍需在目标硬件上运行验证。烧录后执行：

```sh
fw4 check
/usr/bin/ua3f-passwall-check
```

先检查 UA3F 日志和 `inet UA3F` 表、PassWall 日志与 `inet passwall` 表、标记 `0x1c9` 对应的策略路由以及 PassWall 的 `0x50535731` 规则。先完成普通网页/HTTPS/DNS/校园网登录测试，再依次启用 L3 单项、eBPF 和 Desync。eBPF 报错时先检查 `ip -4 route show default`、`ip -o -4 addr show` 与 `tc qdisc show`，不要通过增加重复 nftables 规则来修复。

## 需要特别注意的刷机风险

本项目生成的是普通 OpenWrt stock-layout 目标，不是 `ubootmod` 镜像。不要用 V1 镜像刷 V2，也不要用 V2 镜像刷 V1。刷写前确认 U-Boot 当前布局、备份和恢复方式。 
