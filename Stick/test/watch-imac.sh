#!/bin/sh
# Records what the iMac's Linux is doing, from this Mac over the Thunderbolt cable, so that if
# it stops dead there's a record of its last seconds: new kernel messages, the display
# program's and startup's logs, and every minute its memory, temperatures and fan.
#
#   test/watch-imac.sh            waits for the iMac, then records to out/logs/watch-<time>.txt
#
# When the iMac goes quiet (shut down, started again, or stopped dead) it waits for the next
# start and records that to a new file, until stopped.
cd "$(dirname "$0")/.."
mkdir -p out/logs
known=out/ssh/known_hosts
echo "tandem-display.local $(cut -d' ' -f1,2 out/ssh/host_key.pub)" > $known

remote='
k=0; d=0; b=0; t=0
new() { # file, lines already shown, tag
    c=$(wc -l < "$1" 2>/dev/null || echo 0)
    [ "$c" -lt "$2" ] && set -- "$1" 0 "$3"
    [ "$c" -gt "$2" ] && tail -n $((c - $2)) "$1" | sed "s/^/$3 /"
    echo "$c" > /tmp/watch-count
}
while :; do
    dmesg > /tmp/watch-k; new /tmp/watch-k $k K; k=$(cat /tmp/watch-count)
    new /run/tandem/display.log $d D; d=$(cat /tmp/watch-count)
    new /run/tandem/boot.log $b B; b=$(cat /tmp/watch-count)
    if [ $t -le 0 ]; then
        temps=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | while read v; do echo -n "$((v / 1000)) "; done)
        fan=$(cat /sys/class/hwmon/hwmon*/fan1_input 2>/dev/null | head -n 1)
        echo "S up $(cut -d" " -f1 /proc/uptime) s, $(grep MemAvailable /proc/meminfo | tr -s " "), load $(cut -d" " -f1-3 /proc/loadavg), temps ${temps}C, fan ${fan} rpm"
        t=12
    fi
    t=$((t - 1))
    sleep 5
done'

while :; do
log=out/logs/watch-$(date +%Y%m%d-%H%M%S).txt
echo "waiting for the iMac's Linux on the cable; recording to $log"
until ssh -i out/ssh/tandem_ed25519 -o UserKnownHostsFile=$known -o ConnectTimeout=3 -o BatchMode=yes \
          root@tandem-display.local true 2>/dev/null; do
    sleep 3
done
echo "connected at $(date)" | tee -a $log
# The Mac's own clock beside every line, and a dead link noticed within about 30 s.
ssh -i out/ssh/tandem_ed25519 -o UserKnownHostsFile=$known -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    root@tandem-display.local "$remote" 2>&1 |
    while IFS= read -r line; do echo "$(date +%H:%M:%S) $line"; done >> $log
echo "$(date +%H:%M:%S) the link went quiet" | tee -a $log
sleep 5
done
