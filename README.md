# tcp_bbr_aggr

一个更激进、可在线调参的 BBR（v1）拥塞控制内核模块，拥塞控制名为 `bbr_aggr`。

基于 Linux v6.12 自带的 `net/ipv4/tcp_bbr.c`，保留官方 BBR 的全部修复，只改动几处参数和策略。作为独立模块加载，和系统自带的 `bbr` 并存，**不需要换内核**。

## 和原版 BBR 的区别

| 项目 | 原版 BBR | bbr_aggr | 来源 |
|---|---|---|---|
| STARTUP 加速倍数 | 2.885 | 3.0 | hysteria aggressive |
| 判定带宽已满前等待轮数 | 3 | 4 | hysteria aggressive |
| 稳定期 cwnd 倍数 | 2.0 | 2.5 | hysteria aggressive |
| 带宽最大值记忆 | 10 轮 | 15 轮 | tsunami |
| PROBE_RTT 间隔 | 10 秒 | 20 秒 | tsunami |
| PROBE_RTT 持续 | 200ms | 100ms | nanqinlang |
| PROBE_RTT 时的 cwnd | 4 个包 | 0.5 × BDP | BBRv2 |
| PROBE_BW 探测周期 | 固定 8 阶段 | 随机 2~8 个 min_rtt | bbrplus |
| PROBE_BW 探测倍数 | 1.25 | 1.5 | 本项目（v0.3，晚高峰实测） |
| 带宽被低估时 | 每个探测周期只涨 25% | 采样高出估计 8% 就重新进入 STARTUP，每个往返翻倍 | 本项目（v0.2，v0.3 调整阈值） |
| 巡航速度 | 1.0 | 1.0（不变） | — |
| 限速（policer）识别、丢包处理 | — | 不变 | — |

设计取舍：

- **不提高巡航速度**：nanqinlang 等魔改把巡航速度提到 1.25~1.5 倍，会在瓶颈处一直排队，丢包和延迟都会上升，所以这里保持 1.0。
- **保留限速识别**：运营商 QoS 按速率丢包时，BBR 会自动按限速值发送。放宽这部分（如 nanqinlang）在限速线路上会更差。
- **PROBE_RTT 不再“断崖”**：原版每 10 秒把 cwnd 降到 4 个包持续 200ms，长 RTT 链路上吞吐会周期性掉坑。这里改为 0.5 × BDP，与 BBRv2 一致。顺带修正了 tsunami 的问题：tsunami 只把 cwnd 减半，但进入计时的条件仍然是“在途包 ≤ 4”，实际每个 ACK 都在继续减半，最后照样掉到 4 个包。

- **复用连接上的下载提速慢（v0.2 修复）**：网页、API 这类“一问一答”的小请求，会让 BBR 在很低的速度上就判定“带宽已满”，结束 STARTUP。之后同一条连接上开始下载文件或视频时，原版 BBR 每个探测周期（8 个往返，跨太平洋约 1.6 秒）只把速度提高 25%。代理、HTTP/2 这类长期复用的连接最容易遇到。v0.2 在 PROBE_BW 中只要看到非 app-limited 的采样明显高于当前带宽估计，就重新进入 STARTUP（v0.2 阈值 15%，v0.3 改为 8%）。

  实测（家庭宽带经 AnyTLS 代理连美国服务器，RTT 约 200ms，同一条连接先发 15 个 30KB 请求再下载，3 轮平均）：

  | | 原版 bbr | bbr_aggr v0.2 |
  |---|---|---|
  | 复用连接下载 5MB | 8.25s | 4.56s |
  | 复用连接下载 20MB | 19.25s | 5.84s |
  | 全新连接 | 基本相同 | 基本相同 |

  当时抓到的原版连接状态：带宽估计只有 1.5 Mbps，此后 5.6 秒里只爬到 8.2 Mbps。

- **v0.3 参数来自晚高峰实测**：家庭宽带经 AnyTLS 代理，在 20:50~22:25 晚高峰交替测试（每轮所有变体各跑一次，取中位数；没下完的按 30 秒计）。日本服务器上先单独试了 5 个参数，只有“更早重新进入 STARTUP（1.08）”和“探测倍数 1.5”有效；“STARTUP 3.5 倍”“带宽记忆 30 轮”“不做 PROBE_RTT”都更差，没采用。两者组合后在美国服务器上验证（4 轮中位数）：

  | | 原版 bbr | v0.2 | v0.3 |
  |---|---|---|---|
  | 复用连接下载 5MB | 18.7s | 14.9s | 9.4s |
  | 复用连接下载 20MB | 30s 内没下完 | 29.7s | 15.3s |
  | 全新连接下载 5MB | 14.1s | 9.7s | 9.0s |
  | 下载进行中，小请求最慢首字节 | 0.87s | 1.00s | 0.84s |
  | 失败/超时次数 | 3 | 2 | 0 |

## 安装（DKMS，内核升级后自动重新编译）

需要内核头文件和 dkms。Debian / Ubuntu：

```bash
apt install -y build-essential dkms linux-headers-$(uname -r)
git clone https://github.com/Kopw/tcp_bbr_aggr.git
cd tcp_bbr_aggr
make dkms
modprobe tcp_bbr_aggr
echo tcp_bbr_aggr > /etc/modules-load.d/tcp-bbr-aggr.conf   # 开机自动加载
```

只加载模块不会改变系统默认算法。启用：

```bash
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr_aggr
```

只对之后新建的连接生效；改回 `bbr` 同理。要永久生效，写进 `/etc/sysctl.d/`。

卸载：`make dkms-remove`（先把默认算法改回 `bbr`）。

从旧版本升级（0.1.0 / 0.2.0）：先把默认算法改回 `bbr`，等用旧模块的连接结束（或用 `ss -K` 关掉），再执行 `dkms remove -m tcp_bbr_aggr -v <旧版本> --all`、`modprobe -r tcp_bbr_aggr`，然后按上面的步骤 `make dkms`。

已在 Debian 13（6.12.113）和 Debian 12（6.1.0）上编译、DKMS 安装、加载，并跑过实际传输。内核 6.10 前后 `cong_control` 接口的差异已做兼容。

## 在线调参

所有参数都在 `/sys/module/tcp_bbr_aggr/parameters/` 下，修改后下一个 ACK 就生效，正在传输的连接也会生效。增益单位是千分比（1000 = 1.0 倍），方括号里是原版 BBR 的值：

| 参数 | 默认 | 说明 |
|---|---|---|
| `high_gain` | 3000 [2885] | STARTUP 加速倍数，DRAIN 自动取倒数 |
| `full_bw_cnt` | 4 [3] | 带宽连续几轮没涨 25% 就认为已满（1~7） |
| `cwnd_gain` | 2500 [2000] | 稳定期 cwnd 倍数 |
| `probe_up_gain` | 1500 [1250] | 探测阶段发送倍数 |
| `probe_down_gain` | 750 [750] | 排空阶段发送倍数 |
| `cruise_gain` | 1000 [1000] | 巡航发送倍数，大于 1000 会持续排队 |
| `bw_rtts` | 15 [10] | 带宽最大值记忆多少轮 |
| `min_rtt_win_sec` | 20 [10] | 多久做一次 PROBE_RTT（秒） |
| `probe_rtt_mode_ms` | 100 [200] | PROBE_RTT 持续时间，0 = 不做 |
| `probe_rtt_cwnd_gain` | 500 [0] | PROBE_RTT 时 cwnd 占 BDP 的比例，0 = 原版的 4 个包 |
| `rand_cycle` | 1 [0] | 1 = bbrplus 式随机探测周期，0 = 原版 8 阶段 |
| `restartup_ratio` | 1080 [关] | 采样比带宽估计高出这个比例就重新进入 STARTUP（1050~4000），0 = 关闭 |
| `restartup_count` | 只读 | 加载以来重新进入 STARTUP 的次数，用来确认是否生效 |

例如恢复原版 PROBE_RTT 行为：

```bash
cd /sys/module/tcp_bbr_aggr/parameters
echo 10 > min_rtt_win_sec; echo 200 > probe_rtt_mode_ms; echo 0 > probe_rtt_cwnd_gain
```

查看正在使用的连接：`ss -tin | grep bbr_aggr`。

## A/B 测试

`tools/cc_server.py` 是一个临时测速服务端（端口 18090），按请求参数给每条连接单独设置拥塞算法，不用改系统默认值：

```bash
# 服务端
python3 tools/cc_server.py
# 客户端：交替用 bbr 和 bbr_aggr 下载，5 轮，每次 20 秒
sh tools/ab_client.sh <服务器IP> 5 20
```

同一线路要多轮交替测试，最好在晚高峰测，空闲时段两者差别通常在误差范围内。

## 只影响发送方向

拥塞控制只管本机发出去的数据。装在服务器上，影响的是用户的下载方向；上传方向由用户自己的系统决定。

## 参考

- [Linux tcp_bbr.c (v6.12)](https://github.com/torvalds/linux/blob/v6.12/net/ipv4/tcp_bbr.c)
- [hrimfaxi/tcp_bbr_modules](https://github.com/hrimfaxi/tcp_bbr_modules)（bbrplus / tsunami / nanqinlang 的新内核移植）
- [cx9208/bbrplus](https://github.com/cx9208/bbrplus)
- [KozakaiAya/TCP_BBR](https://github.com/KozakaiAya/TCP_BBR)
- [google/bbr v3](https://github.com/google/bbr/tree/v3)
- hysteria 的 BBR aggressive profile

## 免责声明

实验性质的拥塞控制修改，对其他流量不那么“谦让”。不保证在所有线路上都比原版好，请先 A/B 测试再决定是否设为默认。

## License

GPL-2.0，与 Linux 内核相同。
