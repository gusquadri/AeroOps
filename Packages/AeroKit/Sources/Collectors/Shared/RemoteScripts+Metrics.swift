// Embeds Scripts/remote/metrics.sh. Do not edit the text below by hand: edit the script, then
// paste it between the delimiters. `MetricsScriptTests` fails until both are byte-identical.

extension RemoteScripts {
    /// `Scripts/remote/metrics.sh`, byte for byte: one run is one poll.
    /// Run it as ``RemoteScripts/shellCommand`` with this text on stdin and parse
    /// the output with `MetricsParser`.
    public static let metrics: String = #"""
#!/bin/sh
# AeroOps metrics collector. One run = one poll; output is "@@section" blocks.
# Run as: ssh aero-<id> 'LC_ALL=C sh -s' < metrics.sh
# POSIX sh, BusyBox-compatible. Reads only /proc, df, uname, hostname and
# os-release.
export LC_ALL=C
echo "@@stat";   head -n1 /proc/stat
echo "@@cpus";   grep -c '^processor' /proc/cpuinfo
echo "@@mem";    grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo
echo "@@uptime"; cat /proc/uptime
echo "@@load";   cat /proc/loadavg
echo "@@df";     df -Pk / 2>/dev/null
                 df -Pk -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -Pk
echo "@@host";   uname -srm; hostname
echo "@@os";     k='^(ID|ID_LIKE|NAME|PRETTY_NAME|VERSION_ID)='
                 grep -E "$k" /etc/os-release 2>/dev/null || grep -E "$k" /usr/lib/os-release 2>/dev/null
echo "@@end"

"""#
}
