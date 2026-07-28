#!/bin/bash

# Arguments passed to this script:
# $1 = RELEASE (e.g. bookworm)
# $2 = LINUXFAMILY (e.g. rk3399)
# $3 = BOARD (e.g. nanopi-r4s)
# $4 = BUILD_OPT (e.g. standard)

echo "=== Running Armbian Customization Script for NanoPi R4S ==="

Main() {
    # 1. 更新软件包列表与安装所需工具
    apt-get update
    apt-get install -y --no-install-recommends \
        nftables \
        dnsmasq \
        ppp \
        pppoe \
        odhcp6c \
        curl \
        wget \
        ca-certificates \
        iptables \
        iproute2 \
        net-tools \
        ethtool \
        lm-sensors \
        sudo

    # 2. 读取 PPPoE 账号密码（从 GH Secrets 注入的环境变量获取，默认使用占位符）
    PPPOE_ACCOUNT="${PPPOE_USER:-YOUR_PPPOE_ACCOUNT}"
    PPPOE_PASSWORD="${PPPOE_PASS:-YOUR_PPPOE_PASSWORD}"

    echo "Configuring PPPoE for WAN (eth0) with account: $PPPOE_ACCOUNT ..."

    # 配置 /etc/ppp/peers/dsl-provider
    cat <<EOF > /etc/ppp/peers/dsl-provider
plugin rp-pppoe.so eth0
user "$PPPOE_ACCOUNT"
usepeerdns
defaultroute
hide-password
lcp-echo-interval 20
lcp-echo-failure 3
noauth
persist
maxfail 0
holdoff 5
unit 0
EOF

    # 配置 PAP / CHAP 密钥认证
    echo "\"$PPPOE_ACCOUNT\" * \"$PPPOE_PASSWORD\"" > /etc/ppp/pap-secrets
    echo "\"$PPPOE_ACCOUNT\" * \"$PPPOE_PASSWORD\"" > /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/pap-secrets /etc/ppp/chap-secrets

    # 创建 pppoe 开机自启 systemd 服务
    cat <<EOF > /etc/systemd/system/pppoe-wan.service
[Unit]
Description=PPPoE WAN Connection
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/pon dsl-provider
ExecStop=/usr/bin/poff dsl-provider
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable pppoe-wan.service

    # 3. 配置网络接口 (/etc/network/interfaces)
    cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

# WAN Physical Interface
auto eth0
iface eth0 inet manual
    pre-up ip link set eth0 up

# LAN Interface
auto eth1
iface eth1 inet static
    address 192.168.100.1
    netmask 255.255.255.0
EOF

    # 4. 配置 dnsmasq (DHCP & DNS)
    cat <<EOF > /etc/dnsmasq.conf
domain-needed
bogus-priv
no-resolv
server=223.5.5.5
server=119.29.29.29

interface=eth1
dhcp-range=192.168.100.100,192.168.100.250,255.255.255.0,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1
    # 5. 开启内核转发与优化参数
    cat <<EOF > /etc/sysctl.d/99-router.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.netfilter.nf_conntrack_max = 131072
EOF

    # 6. 配置 nftables 防火墙与 NAT 转发规则 (纯粹干净的防火墙与 ppp0 NAT，不与 Mihomo TUN 冲突)
    cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # 允许本地环回与已建立连接
        iif "lo" accept
        ct state established,related accept

        # 允许 LAN (eth1) 访问路由器基础服务 (SSH, DNS, DHCP, ICMP, ICMPv6)
        iif "eth1" accept
        ip6 nspreview accept
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, echo-reply, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # 允许 LAN (eth1) 转发到 WAN (ppp0)
        iif "eth1" oif "ppp0" accept
        iif "ppp0" oif "eth1" ct state established,related accept

        # 允许 LAN 内部转发
        iif "eth1" oif "eth1" accept
        
        # 允许 IPv6 流量转发
        ip6 nspreview accept
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, echo-reply } accept
        iif "eth1" accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # WAN 接口 NAT 地址伪装
        oifname "ppp0" masquerade
    }
}
EOF

    systemctl enable nftables

    # 7. 配置 IPv6 DHCPv6-PD 前缀委派与 LAN 侧 RA/SLAAC 分发
    echo "Configuring IPv6 DHCPv6-PD and SLAAC..."
    
    # 编写 odhcp6c 回调脚本：获取 PD 前缀并自动分配给 eth1
    cat <<'EOF' > /usr/local/bin/odhcp6c-script.sh
#!/bin/sh
[ -z "$2" ] && exit 0

case "$2" in
    bound|informed|updated)
        if [ -n "$PREFIXES" ]; then
            # 提取第一个 IPv6 前缀并挂载到 eth1
            for prefix in $PREFIXES; do
                ADDR="${prefix%%/*}"
                LEN="${prefix##*/}"
                if [ "$LEN" -le 64 ]; then
                    LAN_IP="${ADDR}1"
                    ip -6 addr flush dev eth1 scope global 2>/dev/null
                    ip -6 addr add "${LAN_IP}/64" dev eth1
                    systemctl reload dnsmasq 2>/dev/null || true
                    break
                fi
            done
        fi
        ;;
    unbound)
        ip -6 addr flush dev eth1 scope global 2>/dev/null
        ;;
esac
EOF
    chmod +x /usr/local/bin/odhcp6c-script.sh

    # 配置 pppoe 拨号上线钩子触发 odhcp6c 获取 PD
    mkdir -p /etc/ppp/ipv6-up.d
    cat <<'EOF' > /etc/ppp/ipv6-up.d/dhcpv6-pd
#!/bin/sh
# 杀死已有的 odhcp6c 实例
killall odhcp6c 2>/dev/null || true
# 针对 ppp0 接口启动 odhcp6c 申请 PD 前缀 (前缀掩码范围 /60 到 /64)
/usr/sbin/odhcp6c -s /usr/local/bin/odhcp6c-script.sh -P 64 ppp0 &
EOF
    chmod +x /etc/ppp/ipv6-up.d/dhcpv6-pd

    # 更新 dnsmasq.conf 支持 IPv6 RA 与 SLAAC 无状态分发
    cat <<EOF > /etc/dnsmasq.conf
domain-needed
bogus-priv
no-resolv
server=223.5.5.5
server=119.29.29.29

# IPv4 DHCP
interface=eth1
dhcp-range=192.168.100.100,192.168.100.250,255.255.255.0,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1

# IPv6 RA 通告与 SLAAC 自动无状态前缀下发
enable-ra
dhcp-range=set:lan6,::100,::ffff,constructor:eth1,ra-stateless,ra-names,12h

dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

    systemctl enable dnsmasq

    # 8. 安装 Docker 与 Docker Compose
    echo "Installing Docker and Docker Compose..."
    apt-get install -y --no-install-recommends docker.io docker-compose-v2
    systemctl enable docker

    # 9. 下载并配置 Mihomo (Clash Meta)
    echo "Downloading and configuring Mihomo (arm64)..."
    mkdir -p /etc/mihomo /var/log/mihomo
    MIHOMO_LATEST_TAG=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "v1.19.0")
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_LATEST_TAG}/mihomo-linux-arm64-compatible-${MIHOMO_LATEST_TAG}.gz"
    
    echo "Fetching mihomo from: $MIHOMO_URL"
    curl -sSL "$MIHOMO_URL" | gunzip > /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo

    # 10. 下载并解压 MetaCubeXD 可视化面板到 /etc/mihomo/ui
    echo "Downloading MetaCubeXD Web UI..."
    mkdir -p /etc/mihomo/ui
    METACUBEXD_TAG=$(curl -s https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "v1.170.0")
    METACUBEXD_URL="https://github.com/MetaCubeX/metacubexd/releases/download/${METACUBEXD_TAG}/compressed-dist.tgz"
    
    echo "Fetching metacubexd from: $METACUBEXD_URL"
    curl -sSL "$METACUBEXD_URL" | tar -xz -C /etc/mihomo/ui

    # 基础 config.yaml (只保留纯粹干净的 TUN 模式模板)
    cat <<EOF > /etc/mihomo/config.yaml
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: true
external-controller: 0.0.0.0:9090
external-ui: ui
secret: ""

tun:
  enable: true
  stack: system
  dns-hijack:
    - "any:53"
  auto-route: true
  auto-detect-interface: true

dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 119.29.29.29

rules:
  - GEOIP,LAN,DIRECT
  - MATCH,DIRECT
EOF

    # 创建 mihomo systemd 服务
    cat <<EOF > /etc/systemd/system/mihomo.service
[Unit]
Description=Mihomo (Clash Meta) Daemon
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable mihomo.service

    echo "=== Customization script completed successfully ==="
}

Main "$@"
