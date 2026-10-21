#!/usr/bin/env bash
set -euo pipefail

TOPDIR="${1:-openwrt}"
CONFIG="$TOPDIR/.config"
UA3F_MAKEFILE="$TOPDIR/package/UA3F/openwrt/Makefile"
UA3F_TPROXY="$TOPDIR/package/UA3F/internal/server/tproxy/tproxy_linux.go"
PASSWALL_NFT="$TOPDIR/package/passwall-luci/luci-app-passwall/root/usr/share/passwall/nftables.sh"
UA3F_CBI="$TOPDIR/package/UA3F/openwrt/luasrc/model/cbi/ua3f"
DEFAULTS="$TOPDIR/files/etc/uci-defaults/99-ax3000t-ua3f-passwall"

[[ -f "$CONFIG" ]] || { echo "ERROR: missing resolved OpenWrt .config" >&2; exit 1; }
[[ -f "$UA3F_MAKEFILE" && -f "$UA3F_TPROXY" && -f "$PASSWALL_NFT" ]] || {
  echo "ERROR: missing UA3F/PassWall source files" >&2; exit 1;
}
[[ -f "$DEFAULTS" ]] || { echo "ERROR: first-boot defaults missing from OpenWrt files/" >&2; exit 1; }

required=(
  CONFIG_PACKAGE_firewall4=y
  CONFIG_PACKAGE_nftables-json=y
  CONFIG_PACKAGE_kmod-nft-core=y
  CONFIG_PACKAGE_kmod-nf-conntrack-netlink=y
  CONFIG_PACKAGE_kmod-nft-queue=y
  CONFIG_PACKAGE_kmod-nft-tproxy=y
  CONFIG_PACKAGE_kmod-sched-bpf=y
  CONFIG_PACKAGE_kmod-sched-core=y
  CONFIG_PACKAGE_tc-full=y
  CONFIG_PACKAGE_libubox-lua=y
  CONFIG_PACKAGE_ua3f=y
  CONFIG_PACKAGE_luci-app-passwall=y
  CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y
  CONFIG_PACKAGE_kmod-nft-socket=y
  CONFIG_PACKAGE_kmod-nft-nat=y
  CONFIG_PACKAGE_kmod-nf-reject=y
  CONFIG_PACKAGE_kmod-nf-reject6=y
  CONFIG_PACKAGE_dnsmasq-full=y
  CONFIG_PACKAGE_ip-full=y
  CONFIG_PACKAGE_luci-theme-argon=y
  CONFIG_LUCI_LANG_zh_Hans=y
  CONFIG_PACKAGE_sing-box=y
  CONFIG_PACKAGE_xray-core=y
)
for symbol in "${required[@]}"; do
  if ! grep -Fxq "$symbol" "$CONFIG"; then
    echo "ERROR: required UA3F/PassWall profile symbol missing after defconfig: $symbol" >&2
    exit 1
  fi
done

forbidden=(
  CONFIG_PACKAGE_luci-app-openclash=y
  CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy=y
  CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client=y
  CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server=y
  CONFIG_PACKAGE_shadowsocks-rust-sslocal=y
  CONFIG_PACKAGE_rust=y
)
for symbol in "${forbidden[@]}"; do
  if grep -Fxq "$symbol" "$CONFIG"; then
    echo "ERROR: forbidden/unwanted package selected: $symbol" >&2
    exit 1
  fi
done

deps="$(sed -n '/define Package\/ua3f/,/endef/p' "$UA3F_MAKEFILE" | grep 'DEPENDS:=' || true)"
for item in '+kmod-nf-conntrack-netlink' '+kmod-nft-queue' '+kmod-nft-tproxy' '+kmod-sched-bpf' '+libubox-lua'; do
  [[ "$deps" == *"$item"* ]] || { echo "ERROR: UA3F dependency missing $item" >&2; exit 1; }
done
if [[ "$deps" == *"+iptables"* || "$deps" == *"iptables-mod-nfqueue"* || "$deps" == *"iptables-mod-tproxy"* ]]; then
  echo "ERROR: UA3F still has legacy iptables dependencies." >&2
  exit 1
fi

# Pin/compatibility guards are intentionally fail-closed: never compile a
# silently incompatible pair if PassWall changes its mark or UA3F's patch anchor.
grep -Fxq 'PKG_VERSION:=3.7.0' "$UA3F_MAKEFILE"
grep -Fq 'FWMARK="0x50535731"' "$PASSWALL_NFT"
grep -Fq '"0x162"' "$UA3F_TPROXY"
grep -Fq '"0x1ed4"' "$UA3F_TPROXY"
grep -Fq '"0x50535731"' "$UA3F_TPROXY"

for feature in l3_rewrite_ttl l3_rewrite_ipid l3_rewrite_tcpts l3_rewrite_tcpwin l3_rewrite_bpf_offload; do
  grep -R -Fq "$feature" "$UA3F_CBI" || { echo "ERROR: UA3F LuCI feature unavailable: $feature" >&2; exit 1; }
done
for feature in desync_reorder desync_inject; do
  grep -R -Fq "$feature" "$UA3F_CBI" || { echo "ERROR: UA3F Desync feature unavailable: $feature" >&2; exit 1; }
done

grep -Fxq "uci -q set ua3f.enabled.enabled='1'" "$DEFAULTS"
grep -Fxq "uci -q set ua3f.main.server_mode='TPROXY'" "$DEFAULTS"
grep -Fxq "uci -q set ua3f.main.l3_rewrite_bpf_offload='0'" "$DEFAULTS"
grep -Fxq "uci -q set firewall.@defaults[0].flow_offloading='0'" "$DEFAULTS"
grep -Fxq "uci -q set firewall.@defaults[0].flow_offloading_hw='0'" "$DEFAULTS"
grep -Fxq "uci -q set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'" "$DEFAULTS"
grep -Fxq "uci -q set luci.main.mediaurlbase='/luci-static/argon'" "$DEFAULTS"
grep -Fxq "CONFIG_LUCI_LANG_zh_Hans=y" "$CONFIG"

if grep -R -n -E 'luci-app-openclash|OPENCLASH_COMMIT' "$TOPDIR/package" --include='Makefile' --include='*.mk' | grep -v passwall >/dev/null; then
  echo "ERROR: OpenClash package source unexpectedly exists in build tree." >&2
  exit 1
fi

echo "UA3F + PassWall profile validation passed."
echo "Firewall: firewall4/nftables; UA3F dependencies: nft queue, nft tproxy, sched-bpf, libubox-lua."
echo "PassWall: nftables transparent proxy selected; Xray/Sing-box enabled; Rust and OpenClash excluded."
echo "Interception mark compatibility: PassWall 0x50535731 is bypassed by UA3F; Clash marks 0x162/0x1ed4 remain ignored."
echo "Runtime defaults: UA3F TPROXY enabled; L3 mutations, Desync and eBPF offload remain opt-in for staged testing."
echo "Note: this is a build-profile test. Live packet-path validation still requires booting V1/V2 hardware."
