#!/bin/sh
# trafficctl.sh - 流量管理控制脚本（DevUI 插件版）
# 路径：/data/plugins/u60pro-devui/ui/functions/trafficctl.sh

set -u

DIR=/data/plugins/traffic-devui
DB=$DIR/traffic.db
LOG=/tmp/devui-traffic-action.log

mkdir -p "$DIR"

# ===== 工具函数 =====
log() {
  export TZ=CST-8
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true
  tail -n 40 "$LOG" >"$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG" 2>/dev/null || true
}

fmt_bytes() {
  _b=${1:-0}
  if [ "$_b" -ge 1073741824 ] 2>/dev/null; then
    printf '%.2f GB' "$(awk -v n="$_b" 'BEGIN{printf "%.2f", n/1073741824}')"
  elif [ "$_b" -ge 1048576 ] 2>/dev/null; then
    printf '%.1f MB' "$(awk -v n="$_b" 'BEGIN{printf "%.1f", n/1048576}')"
  elif [ "$_b" -ge 1024 ] 2>/dev/null; then
    printf '%.0f KB' "$(awk -v n="$_b" 'BEGIN{printf "%.0f", n/1024}')"
  else
    printf '%s B' "$_b"
  fi
}

# 读取所有非 lo 接口的累计流量
read_total() {
  _rx=0; _tx=0
  for _f in /sys/class/net/*/statistics/rx_bytes; do
    [ -f "$_f" ] || continue
    _if=$(basename "$(dirname "$_f")")
    [ "$_if" = "lo" ] && continue
    _v=$(cat "$_f" 2>/dev/null) || _v=0
    _rx=$((_rx + _v))
  done
  for _f in /sys/class/net/*/statistics/tx_bytes; do
    [ -f "$_f" ] || continue
    _if=$(basename "$(dirname "$_f")")
    [ "$_if" = "lo" ] && continue
    _v=$(cat "$_f" 2>/dev/null) || _v=0
    _tx=$((_tx + _v))
  done
  echo "$_rx $_tx"
}

# 初始化 DB（如果不存在）
init_db() {
  if [ -f "$DB" ]; then return; fi
  read -r rx tx <<EOF
$(read_total)
EOF
  cat >"$DB" <<EOF
total_rx_base=$rx
total_tx_base=$tx
day_rx_base=$rx
day_tx_base=$tx
month_rx_base=$rx
month_tx_base=$tx
last_day=$(date +%d)
last_month=$(date +%m)
limit_gb=0
alert=0
EOF
}

# ===== status：输出 C 代码解析的 KEY=value =====
do_status() {
  init_db
  read -r cur_rx cur_tx <<EOF
$(read_total)
EOF

  # 读取 DB
  . "$DB" 2>/dev/null || true

  # 自动跨天/跨月重置基准
  _today=$(date +%d)
  _thismonth=$(date +%m)
  _db_dirty=0

  if [ "${last_day:-0}" != "$_today" ]; then
    day_rx_base=$cur_rx
    day_tx_base=$cur_tx
    last_day=$_today
    _db_dirty=1
  fi

  if [ "${last_month:-0}" != "$_thismonth" ]; then
    month_rx_base=$cur_rx
    month_tx_base=$cur_tx
    last_month=$_thismonth
    _db_dirty=1
  fi

  if [ "$_db_dirty" -eq 1 ]; then
    cat >"$DB" <<EOF
total_rx_base=${total_rx_base:-$cur_rx}
total_tx_base=${total_tx_base:-$cur_tx}
day_rx_base=$day_rx_base
day_tx_base=$day_tx_base
month_rx_base=$month_rx_base
month_tx_base=$month_tx_base
last_day=$last_day
last_month=$last_month
limit_gb=${limit_gb:-0}
alert=${alert:-0}
EOF
  fi

  # 计算
  _day_rx=$((cur_rx - day_rx_base))
  _day_tx=$((cur_tx - day_tx_base))
  _mon_rx=$((cur_rx - month_rx_base))
  _mon_tx=$((cur_tx - month_tx_base))

  # 限额百分比
  _pct=0
  if [ "${limit_gb:-0}" -gt 0 ]; then
    _lim_bytes=$((limit_gb * 1073741824))
    _used=$(( (_mon_rx + _mon_tx) ))
    _pct=$(( _used * 100 / _lim_bytes ))
    [ "$_pct" -gt 100 ] && _pct=100
  fi

  # 超限提醒（如开启且超 90%，写 toast 文件供 C 代码读取）
  if [ "${alert:-0}" = "1" ] && [ "$limit_gb" -gt 0 ] && [ "$_pct" -ge 90 ]; then
    {
      echo "FMTOAST_TYPE=warn"
      echo "FMTOAST_TITLE=流量提醒"
      echo "FMTOAST_MSG=本月流量已用 ${_pct}%，接近 ${limit_gb}GB 限额"
    } > /tmp/fmswitch_result 2>/dev/null || true
  fi

  cat <<EOF
TR_DAY_RX=$(fmt_bytes "$_day_rx")
TR_DAY_TX=$(fmt_bytes "$_day_tx")
TR_MON_RX=$(fmt_bytes "$_mon_rx")
TR_MON_TX=$(fmt_bytes "$_mon_tx")
TR_LIMIT=$([ "${limit_gb:-0}" -eq 0 ] && echo '不限' || echo "${limit_gb}GB")
TR_PCT=$_pct
TR_ALERT=${alert:-0}
EOF
}

# ===== reset：重置统计 =====
do_reset() {
  init_db
  read -r cur_rx cur_tx <<EOF
$(read_total)
EOF
  . "$DB" 2>/dev/null || true

  case "$1" in
    day)
      day_rx_base=$cur_rx; day_tx_base=$cur_tx; last_day=$(date +%d)
      log "重置今日流量基准"
      echo "OK 已重置今日流量"
      ;;
    month)
      month_rx_base=$cur_rx; month_tx_base=$cur_tx; last_month=$(date +%m)
      log "重置本月流量基准"
      echo "OK 已重置本月流量"
      ;;
    *)
      echo "Usage: $0 reset {day|month}" >&2; exit 2
      ;;
  esac

  cat >"$DB" <<EOF
total_rx_base=${total_rx_base:-$cur_rx}
total_tx_base=${total_tx_base:-$cur_tx}
day_rx_base=$day_rx_base
day_tx_base=$day_tx_base
month_rx_base=$month_rx_base
month_tx_base=$month_tx_base
last_day=$last_day
last_month=$last_month
limit_gb=${limit_gb:-0}
alert=${alert:-0}
EOF
}

# ===== limit：设置月限额 =====
do_limit() {
  _gb="${1:-0}"
  case "$_gb" in
    ''|*[!0-9]*) echo "Invalid limit" >&2; exit 2 ;;
  esac
  init_db
  . "$DB" 2>/dev/null || true
  limit_gb=$_gb
  cat >"$DB" <<EOF
total_rx_base=${total_rx_base:-0}
total_tx_base=${total_tx_base:-0}
day_rx_base=${day_rx_base:-0}
day_tx_base=${day_tx_base:-0}
month_rx_base=${month_rx_base:-0}
month_tx_base=${month_tx_base:-0}
last_day=${last_day:-$(date +%d)}
last_month=${last_month:-$(date +%m)}
limit_gb=$limit_gb
alert=${alert:-0}
EOF
  if [ "$_gb" -eq 0 ]; then
    log "关闭流量限额"
    echo "OK 已关闭限额"
  else
    log "设置月限额为 ${_gb}GB"
    echo "OK 月限额已设为 ${_gb}GB"
  fi
}

# ===== alert：限额提醒开关 =====
do_alert() {
  _flag="${1:-0}"
  case "$_flag" in
    0|1) ;;
    *) echo "Usage: $0 alert <0|1>" >&2; exit 2 ;;
  esac
  init_db
  . "$DB" 2>/dev/null || true
  alert=$_flag
  cat >"$DB" <<EOF
total_rx_base=${total_rx_base:-0}
total_tx_base=${total_tx_base:-0}
day_rx_base=${day_rx_base:-0}
day_tx_base=${day_tx_base:-0}
month_rx_base=${month_rx_base:-0}
month_tx_base=${month_tx_base:-0}
last_day=${last_day:-$(date +%d)}
last_month=${last_month:-$(date +%m)}
limit_gb=${limit_gb:-0}
alert=$alert
EOF
  log "流量提醒已$([ "$_flag" -eq 1 ] && echo '开启' || echo '关闭')"
  echo "OK 提醒已$([ "$_flag" -eq 1 ] && echo '开启' || echo '关闭')"
}

# ===== 入口 =====
case "${1:-status}" in
  status) do_status ;;
  reset)  do_reset "${2:-}" ;;
  limit)  do_limit "${2:-0}" ;;
  alert)  do_alert "${2:-0}" ;;
  *)
    echo "Usage: $0 {status|reset day|reset month|limit <GB>|alert <0|1>}" >&2
    exit 2
    ;;
esac