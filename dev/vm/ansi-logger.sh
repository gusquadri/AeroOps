# Busy logger for the demo-logger container (busybox sh). Prints two lines a
# second forever: ANSI-coloured levels, a bold line, a 256-colour line, a
# plain line, a UTF-8 line; the ERROR lines (every 8th) go to stderr.
i=0
while :; do
  i=$((i + 1))
  case $((i % 8)) in
    0) printf '\033[31mERROR\033[0m request %d failed: upstream timeout after 3000ms\n' "$i" >&2 ;;
    1) printf '\033[32mINFO\033[0m  GET /api/items/%d 200 %dms\n' "$i" $((i % 40 + 3)) ;;
    2) printf '\033[33mWARN\033[0m  slow query took %dms (threshold 500ms)\n' $((i * 37 % 900 + 500)) ;;
    3) printf '\033[1;34mDEBUG\033[0m cache hit ratio=0.%02d entries=%d\n' $((i % 100)) $((i * 3)) ;;
    4) printf 'plain line %d without colour codes\n' "$i" ;;
    5) printf '\033[38;5;208mNOTICE\033[0m 256-colour line, \033[1mbold\033[0m and \033[4munderline\033[0m %d\n' "$i" ;;
    6) printf 'unicode line %d: caf\303\251 \342\234\223 \346\227\245\346\234\254\n' "$i" ;;
    7) printf '\033[32mINFO\033[0m  POST /api/orders 201 id=%d\n' "$i" ;;
  esac
  sleep 0.5
done
