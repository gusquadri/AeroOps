#!/bin/sh
# AeroOps metrics collector. One run = one poll; output is "@@section" blocks.
# Run as: ssh aero-<id> 'LC_ALL=C sh -s' < metrics.sh
export LC_ALL=C
if [ "$(uname -s)" = Darwin ]; then
echo "@@cpubusy"; iostat -n 0 -c 2 -w 1 | awk 'END { print 100 - $3 }'
echo "@@cpus";    sysctl -n hw.logicalcpu
echo "@@mem";     { sysctl -n hw.memsize hw.pagesize vm.swapusage; vm_stat; } | awk -F: '
                  function kib(s,  n, u) {
                      n = s + 0; u = substr(s, length(s))
                      return int(n * (u == "G" ? 1048576 : u == "M" ? 1024 : u == "K" ? 1 : 1 / 1024))
                  }
                  NR == 1 { total = $1 / 1024; next }
                  NR == 2 { page = $1 / 1024; next }
                  NR == 3 { split($0, f, " "); swap = kib(f[3]); swapfree = kib(f[9]); next }
                  { v[$1] = $2 + 0 }
                  END {
                      used = (v["Anonymous pages"] - v["Pages purgeable"] + v["Pages wired down"] \
                              + v["Pages occupied by compressor"]) * page
                      avail = total - used; if (avail < 0) avail = 0
                      printf "MemTotal: %d kB\nMemAvailable: %d kB\n", total, avail
                      printf "SwapTotal: %d kB\nSwapFree: %d kB\n", swap, swapfree
                  }'
echo "@@uptime";  sysctl -n kern.boottime | awk -v now="$(date +%s)" '{ s = $4; sub(/,/, "", s); print now - s }'
echo "@@load";    sysctl -n vm.loadavg | awk '{ print $2, $3, $4 }'
echo "@@df";      df -Pkl | awk '
                  $1 == "Filesystem" { print; next }
                  {
                      for (i = 5; i < NF; i++) if ($i ~ /^[0-9]+%$/) break
                      m = $(i + 1)
                      if (i == NF || $(i - 3) == 0 || (m != "/" && m !~ /^\/Volumes\//) || m == "/Volumes/Recovery") next
                      $(i - 2) = $(i - 3) - $(i - 1)
                      $i = int((100 * $(i - 2) + $(i - 3) - 1) / $(i - 3)) "%"
                      print
                  }'
echo "@@host";    uname -srm; hostname
echo "@@os";      printf 'ID=macos\nNAME="%s"\nVERSION_ID=%s\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)"
else
echo "@@stat";    head -n1 /proc/stat
echo "@@cpus";    grep -c '^processor' /proc/cpuinfo
echo "@@mem";     grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo
echo "@@uptime";  cat /proc/uptime
echo "@@load";    cat /proc/loadavg
echo "@@df";      df -Pk / 2>/dev/null
                  df -Pk -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -Pk
echo "@@host";    uname -srm; hostname
echo "@@os";      k='^(ID|ID_LIKE|NAME|PRETTY_NAME|VERSION_ID)='
                  grep -E "$k" /etc/os-release 2>/dev/null || grep -E "$k" /usr/lib/os-release 2>/dev/null
fi
echo "@@end"
