# 小米 AX3000T V1 / V2 固件：UA3F TPROXY + PassWall

本仓库构建两份独立的 OpenWrt 25.12 固件：

- **V1 / MT7531**：官方 stock-layout 设备目标 `xiaomi_mi-router-ax3000t`
- **V2 / AN8855**：本工程为 AN8855 版本增加独立 DTS 与 single-UBI stock-layout 目标

已经刷入 U-Boot 的设备不需要重新编译或刷写 U-Boot。本工程不安装 OpenClash，改为集成 **PassWall**。

## 本次集成重点

- **UA3F v3.7.0：TPROXY 模式**，首启配置为启用、端口 1080、全局改写，采用指定的 Windows / QQBrowser User-Agent。
- 适配 OpenWrt 25.12 的 **firewall4 + nftables**，不依赖 UA3F 的旧 iptables 规则。
- UA3F 依赖明确纳入：`kmod-nft-queue`、`kmod-nft-tproxy`、`kmod-sched-bpf`、`libubox-lua`，以及 conntrack-netlink、nftables、TC 工具。
- **PassWall** 使用 nftables 透明代理后端，随固件提供 Xray 26.7.11 和 Sing-box 两个常用核心。Xray 固定在支持 Go 1.26 的版本，因为 OpenWrt 25.12 当前构建环境使用 Go 1.26.10；上游 Xray 26.9+ 要求 Go 1.27，直接使用会导致编译失败。刻意排除 Shadowsocks Rust，避免把额外 Rust 工具链带入这款内存/闪存有限的设备。
- UA3F 保留上游 Clash 常见 mark 绕行，并增加对 PassWall nftables 标记 `0x50535731` 的绕行，避免已由 PassWall 接管的连接再被 UA3F 重复截获。
- **不默认打开** TTL、IPID、TCP 时间戳、TCP 初始窗口、QUIC 阻断、Desync 及 eBPF 卸载。相关 UA3F 控件与依赖都会打进固件；在实际校园网/中继网络中逐项测试后再启用。
- firewall4 软件/硬件 flow offloading 默认关闭，以免绕过 TPROXY、NFQUEUE/Desync 或 TC eBPF 的处理链。
- PassWall 的 dnsmasq include 目录设置为 `/tmp/dnsmasq.d`，并在首启时创建目录，以减少 OpenWrt 25.12 DNS 临时目录变化引起的启动兼容问题。
- **Argon v3 + 简体中文 LuCI**；Argon 设为默认主题，可在主题设置中调整浅色/深色模式与配色。
- 提供 `/usr/bin/ua3f-passwall-check` 只读诊断脚本，汇总防火墙表、策略路由、模块、日志、接口和 dnsmasq 配置。

## 重要的透明代理分工

PassWall 当前 nftables 后端使用 fwmark `0x50535731`。本工程让 UA3F 在 TPROXY 链中跳过这个 mark；PassWall 负责自己标记并接管的流量，其余符合 UA3F 规则的 TCP 流量由 UA3F 处理。该设计用于**避免两个透明代理相互抢流量**，不是把两个代理强制串成同一条链路。被 PassWall 接管的连接不会因此自动再经过 UA3F 的 HTTP 改写。

## 编译与验证

1. 打开 GitHub 仓库的 **Actions**。
2. 运行 **Build Xiaomi AX3000T V1 and V2 firmware (UA3F TPROXY + PassWall)**。
3. 编译前会运行配置校验：模块、PassWall nftables 后端、Xray/Sing-box、Argon、UA3F 功能控件、PassWall mark 补丁都必须匹配；若上游接口变化导致补丁不能安全应用，任务会失败而不是静默跳过。
4. 成功后下载对应 V1 或 V2 Artifact，其中包括升级镜像、initramfs 恢复镜像、解析后的构建配置、OpenWrt 源码提交号及 SHA256。

构建通过不等于已经在实体路由器上验证过所有网络路径。烧录后先执行：

```sh
fw4 check
/usr/bin/ua3f-passwall-check
```

确认 UA3F 的 `inet UA3F` 表、mark `0x1c9` 的策略路由、PassWall 的 `inet passwall` 表与 mark `0x50535731`，再逐步测试网页、HTTPS、DNS、校园网认证和游戏连接。L3 改写、eBPF 和 Desync 必须单独测试。若 eBPF 出现 `no eligible interfaces for TC`，要检查实际 IPv4 默认路由和出口接口；仅将 `kmod-sched-bpf` 编译进固件不能保证任意中继/多路由环境都满足 UA3F 的 TC 接口条件。

## 设备与刷写安全

- 这是普通 OpenWrt stock-layout 目标，不是 `ubootmod` 镜像。
- **绝不能 V1/V2 交叉刷写**。
- 刷写前确认设备硬件版本及 U-Boot 当前分区布局，备份原有配置和分区，并准备恢复方式。
- 不要再次刷写已安装好的 U-Boot/FIP 文件。
