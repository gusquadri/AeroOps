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
# POSIX sh, BusyBox-compatible. Reads only /proc, df, uname and hostname.
#
# Changes from the first version of this script:
# 1. "export LC_ALL=C" at the top, so the output is locale-independent even if
#    the script is run without the LC_ALL=C prefix.
# 2. @@df starts with "df -Pk /". On hosts whose root is an overlay filesystem
#    (Docker-based SSH servers such as dev/compose.yml's ssh and alpine
#    services) "-x overlay" removed "/" from the listing, so the card had no
#    root disk to show. Consequence for parsers: @@df may contain several
#    "Filesystem ..." header lines and repeated rows (the "/" row appears again
#    in the full listing, and GNU df's partial-error exit can trigger the
#    fallback listing too). Skip every line whose first field is "Filesystem"
#    and de-duplicate rows by device (first occurrence wins).
export LC_ALL=C
echo "@@stat";   head -n1 /proc/stat
echo "@@cpus";   grep -c '^processor' /proc/cpuinfo
echo "@@mem";    grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo
echo "@@uptime"; cat /proc/uptime
echo "@@load";   cat /proc/loadavg
echo "@@df";     df -Pk / 2>/dev/null
                 df -Pk -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -Pk
echo "@@host";   uname -srm; hostname
echo "@@end"

"""#
}
