#!/bin/bash

# Arguments passed to this script:
# $1 = RELEASE (e.g. bookworm)
# $2 = LINUXFAMILY (e.g. rk3399)
# $3 = BOARD (e.g. nanopi-r4s)
# $4 = BUILD_OPT (e.g. standard)

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Running Armbian Customization Script for NanoPi R4S ==="

Main() {
    # 1. 更新软件包列表与安装所需工具
    apt-get update
    apt-get install -y --no-install-recommends \
        nftables \
        dnsmasq \
        ppp \
        pppoe \
        curl \
        wget \
        ca-certificates \
        jq \
        locales \
        iptables \
        iproute2 \
        net-tools \
        ethtool \
        lm-sensors \
        sudo

    # 2. 预设基础初始化：只保留 root 用户，禁用 Armbian 首次登录向导。
    R4S_ROOT_PASSWORD='15956404411Zxl'
    echo "Configuring root password, locale, timezone, SSH login and login banner..."
    printf 'root:%s\n' "$R4S_ROOT_PASSWORD" | chpasswd

    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    grep -q '^zh_CN.UTF-8 UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
    locale-gen zh_CN.UTF-8
    update-locale LANG=zh_CN.UTF-8

    ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata

    rm -f /root/.not_logged_in_yet
    install -d -m 755 /etc/ssh/sshd_config.d
    cat <<EOF > /etc/ssh/sshd_config.d/99-r4s-root-login.conf
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

    if [ -f /etc/armbian-release ]; then
        sed -i 's/^VENDOR=.*/VENDOR=Armbian/' /etc/armbian-release
        sed -i 's/^VENDORPRETTYNAME=.*/VENDORPRETTYNAME=Armbian/' /etc/armbian-release
    fi
    if [ -f /etc/armbian-image-release ]; then
        sed -i 's/^VENDOR=.*/VENDOR=Armbian/' /etc/armbian-image-release
        sed -i 's/^VENDORPRETTYNAME=.*/VENDORPRETTYNAME=Armbian/' /etc/armbian-image-release
    fi

    cat <<EOF > /etc/issue
Armbian NanoPi R4S \l

EOF
    cat <<EOF > /etc/issue.net
Armbian NanoPi R4S
EOF

    mkdir -p /etc/update-motd.d
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    cat <<'EOF' > /etc/update-motd.d/10-r4s-header
#!/bin/sh
printf '\nArmbian\n'
printf 'NanoPi R4S router image\n\n'
EOF
    chmod +x /etc/update-motd.d/10-r4s-header

    # 3. 禁用 systemd 复杂预测网口名，内核级强制恢复传统 eth0 / eth1 网口命名 (100% 解决接口名漂移和找不到网卡问题)
    echo "Disabling Predictable Network Interface Names (net.ifnames=0)..."
    mkdir -p /boot
    touch /boot/armbianEnv.txt
    if ! grep -q "net.ifnames=0" /boot/armbianEnv.txt; then
        if grep -q '^extraargs=' /boot/armbianEnv.txt; then
            sed -i '/^extraargs=/ s/$/ net.ifnames=0 biosdevname=0/' /boot/armbianEnv.txt
        else
            echo "extraargs=net.ifnames=0 biosdevname=0" >> /boot/armbianEnv.txt
        fi
    fi

    # 4. 读取 PPPoE 账号密码
    # 注意：宿主机 userpatches/overlay 会挂载为 chroot 内的 /tmp/overlay。
    if [ -f "/tmp/overlay/secrets.sh" ]; then
        # shellcheck source=/dev/null
        . "/tmp/overlay/secrets.sh"
    fi
    PPPOE_ACCOUNT="${PPPOE_USER:-YOUR_PPPOE_ACCOUNT}"
    PPPOE_PASSWORD="${PPPOE_PASS:-YOUR_PPPOE_PASSWORD}"
    if [ "$PPPOE_ACCOUNT" = "YOUR_PPPOE_ACCOUNT" ] || [ "$PPPOE_PASSWORD" = "YOUR_PPPOE_PASSWORD" ]; then
        echo "WARNING: PPPoE credentials were not provided; placeholder credentials will be written." >&2
    fi

    echo "Configuring PPPoE for WAN (eth0) ..."

    # 配置 /etc/ppp/peers/dsl-provider
    cat <<EOF > /etc/ppp/peers/dsl-provider
plugin rp-pppoe.so eth0
user "$PPPOE_ACCOUNT"
noipdefault
usepeerdns
defaultroute
replacedefaultroute
hide-password
mtu 1492
mru 1492
+ipv6
ipv6cp-use-ipaddr
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
After=systemd-networkd.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/pppd call dsl-provider nodetach
ExecStop=/usr/bin/poff dsl-provider
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable pppoe-wan.service

    # 5. 配置网络接口。路由器镜像使用 systemd-networkd 固定 eth0/eth1，避免与 NetworkManager 抢配置。
    mkdir -p /etc/systemd/network
    cat <<EOF > /etc/systemd/network/10-wan-eth0.network
[Match]
Name=eth0

[Network]
DHCP=no
LinkLocalAddressing=no
ConfigureWithoutCarrier=yes
EOF

    cat <<EOF > /etc/systemd/network/20-lan-eth1.network
[Match]
Name=eth1

[Network]
Address=192.168.100.1/24
Address=fd00::1/64
LinkLocalAddressing=ipv6
ConfigureWithoutCarrier=yes
EOF

    systemctl enable systemd-networkd.service
    systemctl enable systemd-resolved.service || true
    systemctl disable NetworkManager.service 2>/dev/null || true

    # 保留一个最小 interfaces 文件，避免 ifupdown 意外接管 eth0/eth1。
    mkdir -p /etc/network
    cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback
EOF

    # 6. 配置 dnsmasq (DHCP & DNS)
    cat <<EOF > /etc/dnsmasq.conf
domain-needed
bogus-priv
no-resolv
bind-interfaces
server=223.5.5.5
server=119.29.29.29

interface=eth1
dhcp-range=192.168.100.100,192.168.100.250,255.255.255.0,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1

enable-ra
dhcp-range=set:lan6,fd00::100,fd00::ffff,64,12h
dhcp-option=option6:dns-server,[fd00::1]
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

    # 7. 开启内核转发与优化参数
    cat <<EOF > /etc/sysctl.d/99-router.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.netfilter.nf_conntrack_max = 131072
EOF

    # 8. 配置 nftables 防火墙与 NAT 转发规则 (纯粹干净的防火墙与 ppp0 NAT，不与 Mihomo TUN 冲突)
    cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # 允许本地环回与已建立连接
        iifname "lo" accept
        ct state established,related accept

        # 允许 LAN (eth1) 访问路由器基础服务 (SSH, DNS, DHCP, ICMP, ICMPv6)
        iifname "eth1" accept
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, echo-reply, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept

        # 解决 PPPoE 拨号导致的 MTU 过大问题；必须位于 LAN->WAN accept 之前。
        iifname "eth1" oifname "ppp0" tcp flags syn tcp option maxseg size set rt mtu

        # 允许 LAN (eth1) 转发到 WAN (ppp0)
        iifname "eth1" oifname "ppp0" accept

        # 允许 LAN 内部转发
        iifname "eth1" oifname "eth1" accept
        
        # 允许 IPv6 流量转发
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, echo-reply } accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "ppp0" masquerade
    }
}

table ip6 nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "ppp0" masquerade
    }
}
EOF

    systemctl enable nftables
    systemctl enable dnsmasq

    # 9. 安装 Docker 与 Docker Compose
    echo "Installing Docker and Docker Compose..."
    apt-get install -y --no-install-recommends docker.io docker-compose
    systemctl enable docker

    # 10. 下载并配置 Mihomo (Clash Meta)
    echo "Downloading and configuring Mihomo (arm64)..."
    mkdir -p /etc/mihomo /var/log/mihomo

    MIHOMO_URL="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | jq -r 'first(.assets[] | select(.name | test("^mihomo-linux-arm64-v[0-9].*\\.gz$")) | .browser_download_url) // empty')"
    if [ -z "$MIHOMO_URL" ]; then
        echo "Unable to discover latest mihomo arm64 release asset." >&2
        exit 1
    fi

    echo "Fetching mihomo from: $MIHOMO_URL"
    curl -sSfL "$MIHOMO_URL" | gunzip > /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo

    # 11. 下载并解压 MetaCubeXD 可视化面板到 /etc/mihomo/ui
    echo "Downloading MetaCubeXD Web UI..."
    mkdir -p /etc/mihomo/ui
    METACUBEXD_URL="$(curl -fsSL https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest \
        | jq -r 'first(.assets[] | select(.name == "compressed-dist.tgz") | .browser_download_url) // empty')"
    if [ -n "$METACUBEXD_URL" ]; then
        echo "Fetching metacubexd from: $METACUBEXD_URL"
        curl -sSfL "$METACUBEXD_URL" | tar -xz -C /etc/mihomo/ui
    else
        echo "WARNING: Unable to discover MetaCubeXD UI asset; continuing without bundled UI." >&2
    fi

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

    # 12. 配置 NanoPi R4S 原生板载指示灯 (SYS / WAN / LAN)
    echo "Configuring NanoPi R4S LED triggers for WAN (eth0) and LAN (eth1)..."
    cat <<'EOF' > /usr/local/bin/setup-r4s-leds.sh
#!/bin/sh
# SYS 灯设置为 heartbeat 心跳闪烁
if [ -d "/sys/class/leds/nanopi-r4s:red:sys" ]; then
    echo heartbeat > /sys/class/leds/nanopi-r4s:red:sys/trigger 2>/dev/null || true
fi

# WAN 灯绑定 eth0 网口 (Link + TX + RX 数据收发闪烁)
if [ -d "/sys/class/leds/nanopi-r4s:green:wan" ]; then
    echo netdev > /sys/class/leds/nanopi-r4s:green:wan/trigger 2>/dev/null || true
    echo eth0 > /sys/class/leds/nanopi-r4s:green:wan/device_name 2>/dev/null || true
    echo "link rx tx" > /sys/class/leds/nanopi-r4s:green:wan/settings 2>/dev/null || true
    echo "1 1 1" > /sys/class/leds/nanopi-r4s:green:wan/mode 2>/dev/null || true
fi

# LAN 灯绑定 eth1 网口 (Link + TX + RX 数据收发闪烁)
if [ -d "/sys/class/leds/nanopi-r4s:green:lan" ]; then
    echo netdev > /sys/class/leds/nanopi-r4s:green:lan/trigger 2>/dev/null || true
    echo eth1 > /sys/class/leds/nanopi-r4s:green:lan/device_name 2>/dev/null || true
    echo "link rx tx" > /sys/class/leds/nanopi-r4s:green:lan/settings 2>/dev/null || true
    echo "1 1 1" > /sys/class/leds/nanopi-r4s:green:lan/mode 2>/dev/null || true
fi
EOF
    chmod +x /usr/local/bin/setup-r4s-leds.sh

    # 创建 systemd 开机服务
    cat <<EOF > /etc/systemd/system/r4s-leds.service
[Unit]
Description=NanoPi R4S LED Indicator Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-r4s-leds.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable r4s-leds.service

    echo "=== Customization script completed successfully ==="
}

Main "$@"
