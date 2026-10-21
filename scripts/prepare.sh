#!/usr/bin/env bash
set -euo pipefail

OPENWRT_DIR="${1:-openwrt}"
PASSWALL_LUCI_COMMIT="ae258e4da46aa34567230f55e401ced4cb7738ad"
PASSWALL_PACKAGES_COMMIT="6edb7efcf3a9505128824ea47c1c058151e290af"
ARGON_COMMIT="915602d22e3d2098a285d02e55fdea77ea86b59a"

cd "$OPENWRT_DIR"
./scripts/feeds update -a
./scripts/feeds install -a

# Remove upstream feed copies that overlap the pinned PassWall packages.
# This follows the PassWall project's current build instructions and prevents
# duplicate package definitions / stale dependency versions.
PASSWALL_PACKAGE_NAMES=(
  xray-core v2ray-geodata sing-box chinadns-ng dns2socks hysteria
  ipt2socks microsocks naiveproxy shadowsocks-rust shadowsocksr-libev
  simple-obfs tcping v2ray-plugin xray-plugin geoview shadow-tls
)
for pkg in "${PASSWALL_PACKAGE_NAMES[@]}"; do
  rm -rf "feeds/packages/net/$pkg" "package/feeds/packages/$pkg"
done
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf package/feeds/luci/luci-app-passwall

rm -rf package/UA3F package/UA2F package/luci-app-openclash
rm -rf package/passwall-packages package/passwall-luci package/luci-theme-argon

clone_at_commit() {
  local url="$1" dest="$2" commit="$3"
  mkdir -p "$(dirname "$dest")"
  git init -q "$dest"
  git -C "$dest" remote add origin "$url"
  git -C "$dest" -c advice.detachedHead=false fetch --depth 1 origin "$commit"
  git -C "$dest" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  local actual
  actual="$(git -C "$dest" rev-parse HEAD)"
  if [[ "$actual" != "$commit" ]]; then
    echo "Pinned source mismatch at $dest: expected $commit, got $actual" >&2
    exit 1
  fi
  echo "$dest => $actual"
}

clone_at_commit \
  https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git \
  package/passwall-packages "$PASSWALL_PACKAGES_COMMIT"
clone_at_commit \
  https://github.com/Openwrt-Passwall/openwrt-passwall.git \
  package/passwall-luci "$PASSWALL_LUCI_COMMIT"
clone_at_commit \
  https://github.com/jerrykuku/luci-theme-argon.git \
  package/luci-theme-argon "$ARGON_COMMIT"

git clone --depth 1 --branch v3.7.0 https://github.com/SunBK201/UA3F.git package/UA3F

# OpenWrt 25.12 uses firewall4/nftables. Replace UA3F's legacy iptables
# dependencies with the nftables/TC modules actually selected for this build.
python3 - "package/UA3F/openwrt/Makefile" <<'PY_UA3F'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "DEPENDS:=$(GO_ARCH_DEPENDS) +luci-compat +ipset +iptables +iptables-mod-tproxy +iptables-mod-extra +iptables-mod-ipopt +iptables-mod-nfqueue +iptables-mod-conntrack-extra +kmod-nf-conntrack-netlink"
new = "DEPENDS:=$(GO_ARCH_DEPENDS) +luci-compat +kmod-nf-conntrack-netlink +kmod-nft-queue +kmod-nft-tproxy +kmod-sched-bpf +libubox-lua"

if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("UA3F Makefile dependency line changed; refusing to patch blindly")

start = text.find("define Package/ua3f\n")
end = text.find("\nendef", start)
if start < 0 or end < 0:
    raise SystemExit("Could not locate Package/ua3f dependency block")
block = text[start:end]
dep_lines = [line.strip() for line in block.splitlines() if "DEPENDS:=" in line]
if len(dep_lines) != 1:
    raise SystemExit("Expected exactly one UA3F DEPENDS line")
deps = dep_lines[0]
required = (
    "+kmod-nf-conntrack-netlink",
    "+kmod-nft-queue",
    "+kmod-nft-tproxy",
    "+kmod-sched-bpf",
    "+libubox-lua",
)
missing = [item for item in required if item not in deps]
if missing:
    raise SystemExit("UA3F nftables dependencies missing: " + ", ".join(missing))
legacy = ("+ipset", "+iptables", "iptables-mod-tproxy", "iptables-mod-nfqueue")
found = [item for item in legacy if item in deps]
if found:
    raise SystemExit("Legacy UA3F iptables dependencies remain: " + ", ".join(found))
path.write_text(text)
PY_UA3F

# PassWall (nftables) uses fwmark 0x50535731. Teach UA3F TPROXY to leave
# PassWall-selected packets to PassWall, preserving existing Clash marks too.
python3 - "package/UA3F/internal/server/tproxy/tproxy_linux.go" <<'PY_MARK'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
mark = '"0x50535731"'
if mark not in text:
    pattern = re.compile(r'(?m)^([ \t]*)"0x1ed4", // sc tproxy mark 7892$')
    text, count = pattern.subn(
        r'\1"0x1ed4", // sc tproxy mark 7892\n'
        r'\1"0x50535731", // PassWall nftables fwmark',
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit("Could not locate UA3F Clash-mark bypass anchor; refusing to patch blindly")
path.write_text(text)
if '"0x162"' not in text or '"0x1ed4"' not in text or mark not in text:
    raise SystemExit("UA3F transparent-proxy mark bypass validation failed")
PY_MARK

# Argon v3 uses wget-any conditionally on APK builds. Keep the package
# compatible with the pinned OpenWrt source package available in this build.
python3 - "package/luci-theme-argon/Makefile" <<'PY_ARGON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "+USE_APK:wget-any +!USE_APK:wget"
if old in text:
    text = text.replace(old, "+wget-ssl", 1)
if "+wget-ssl" not in text:
    raise SystemExit("Argon download dependency could not be adapted to wget-ssl")
path.write_text(text)
PY_ARGON

mkdir -p package/feeds/ua3f_local
ln -sfn ../../UA3F/openwrt package/feeds/ua3f_local/ua3f

test -f package/UA3F/openwrt/Makefile
test -f package/UA3F/internal/server/tproxy/tproxy_linux.go
grep -Fxq 'PKG_VERSION:=3.7.0' package/UA3F/openwrt/Makefile
grep -Fq 'FWMARK="0x50535731"' package/passwall-luci/luci-app-passwall/root/usr/share/passwall/nftables.sh
grep -Fq '"0x50535731"' package/UA3F/internal/server/tproxy/tproxy_linux.go
test -f package/passwall-luci/luci-app-passwall/Makefile
test -f package/passwall-packages/sing-box/Makefile
test -f package/passwall-packages/xray-core/Makefile
test -f package/luci-theme-argon/Makefile

echo "Prepared pinned UA3F v3.7.0, PassWall nftables feeds, Xray/Sing-box cores, and Argon v3."
echo "UA3F package dependencies include kmod-nft-queue, kmod-nft-tproxy, kmod-sched-bpf and libubox-lua."
echo "UA3F bypasses PassWall-marked 0x50535731 flows while keeping the upstream Clash-mark bypasses."
