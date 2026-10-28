#!/bin/sh
# A/B 对比下载速度：服务端先运行 tools/cc_server.py（监听 18090）
# 用法: sh ab_client.sh <服务器IP> [轮数] [每次秒数]
# 每轮依次用 bbr 和 bbr_aggr 下载，同一条线路交替测，减少时段差异的影响
HOST=${1:?usage: ab_client.sh <server-ip> [rounds] [seconds]}
ROUNDS=${2:-5}
SECS=${3:-20}

i=1
while [ "$i" -le "$ROUNDS" ]; do
	for cc in bbr bbr_aggr; do
		curl -s -o /dev/null -m "$SECS" -w "%{speed_download} %{size_download}" \
			"http://$HOST:18090/?cc=$cc&n=4000000000" |
			awk -v cc="$cc" -v r="$i" '{printf "#%s %-9s %7.1f Mbps (%.0f MB)\n", r, cc, $1*8/1e6, $2/1e6}'
	done
	i=$((i + 1))
done
