#!/bin/sh
# simctl.sh - Dual-SIM control helper for u60pro-devui function pages.
# Fixed adapter used by act:sim* handlers. No arbitrary shell from HTML.
set -u

DIR=/data/plugins/sim-switch-devui
TRAFFIC_DIR=/data/plugins/dual-sim-traffic
STATE_JSON="$TRAFFIC_DIR/state.json"
LOG=/tmp/devui-sim-action.log

log() {
  export TZ=CST-8
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true
  tail -n 40 "$LOG" >"$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG" 2>/dev/null || true
}

json() {
  ubus -t 6 call zwrt_zte_mdm.api get_sim_info_before '{}' 2>/dev/null || true
}

jget() {
  # usage: jget <jsonfilter-expr>
  printf '%s' "$RAW" | jsonfilter -e "$1" 2>/dev/null || true
}

op_name() {
  case "$1" in
    CMCC) echo '中国移动' ;;
    CUCC) echo '中国联通' ;;
    CTCC) echo '中国电信' ;;
    ''|null) echo '未识别' ;;
    *) echo "$1" ;;
  esac
}

bytes_human() {
  # integer bytes -> human string
  b=${1:-}
  case "$b" in
    ''|null|-) echo '-' ; return ;;
  esac
  # shell arithmetic; keep simple
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    printf '%s GB' "$(awk -v n="$b" 'BEGIN{printf "%.2f", n/1073741824}')"
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    printf '%s MB' "$(awk -v n="$b" 'BEGIN{printf "%.1f", n/1048576}')"
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    printf '%s KB' "$(awk -v n="$b" 'BEGIN{printf "%.0f", n/1024}')"
  else
    printf '%s B' "$b"
  fi
}

status() {
  RAW=$(json)
  dual=$(jget '@.support_dual_sim')
  slot=$(jget '@.current_sim_slot')
  op1=$(jget '@.Operator')
  op2=$(jget '@.Operator2')
  sw=$(jget '@.switch_card_status')
  p1=$(jget '@.sim1_provision_state')
  p2=$(jget '@.sim2_provision_state')
  auto=$(uci -q get zwrt_zte_mdm.sim_info.st_auto_switch_card_flag 2>/dev/null || true)
  [ -n "$auto" ] || auto=$(jget '@.auto_switch_slot_flag')

  op1s=$(op_name "$op1")
  op2s=$(op_name "$op2")

  if [ "$dual" = "1" ]; then
    ready='双卡可用'
  else
    ready='未报告双卡'
  fi

  if [ "$p1" = "1" ] && [ "$p2" = "1" ]; then
    mode='双卡双待'
  else
    mode='单卡模式'
  fi

  case "$slot" in
    1) current="SIM1 · $op1s"; use1='正在使用'; use2='待机' ;;
    2) current="SIM2 · $op2s"; use1='待机'; use2='正在使用' ;;
    *) current='读取中'; use1='未知'; use2='未知' ;;
  esac

  if [ "$auto" = "1" ]; then
    auto_txt='已开启'
  else
    auto_txt='已关闭'
  fi

  # traffic snapshot from dual-sim-traffic/state.json if present
  d1='-'; u1='-'; l1='-'; r1='-'
  d2='-'; u2='-'; l2='-'; r2='-'
  src='未安装 collector'
  if [ -f "$STATE_JSON" ]; then
    src='dual-sim-traffic/state.json'
    # best-effort jsonfilter / sed free parse via jsonfilter if available on nested keys
    # fall back silently
    d1b=$(jsonfilter -i "$STATE_JSON" -e '@.sims["1"].day_bytes' 2>/dev/null || true)
    d2b=$(jsonfilter -i "$STATE_JSON" -e '@.sims["2"].day_bytes' 2>/dev/null || true)
    r1b=$(jsonfilter -i "$STATE_JSON" -e '@.sims["1"].remaining_bytes' 2>/dev/null || true)
    r2b=$(jsonfilter -i "$STATE_JSON" -e '@.sims["2"].remaining_bytes' 2>/dev/null || true)
    t1b=$(jsonfilter -i "$STATE_JSON" -e '@.sims["1"].package_total_bytes' 2>/dev/null || true)
    t2b=$(jsonfilter -i "$STATE_JSON" -e '@.sims["2"].package_total_bytes' 2>/dev/null || true)
    rd1=$(jsonfilter -i "$STATE_JSON" -e '@.sims["1"].reset_day' 2>/dev/null || true)
    rd2=$(jsonfilter -i "$STATE_JSON" -e '@.sims["2"].reset_day' 2>/dev/null || true)
    d1=$(bytes_human "${d1b:--}")
    d2=$(bytes_human "${d2b:--}")
    l1=$(bytes_human "${r1b:--}")
    l2=$(bytes_human "${r2b:--}")
    if [ -n "${t1b:-}" ] && [ -n "${r1b:-}" ]; then
      u1=$(bytes_human $((t1b - r1b))) 2>/dev/null || u1='-'
    fi
    if [ -n "${t2b:-}" ] && [ -n "${r2b:-}" ]; then
      u2=$(bytes_human $((t2b - r2b))) 2>/dev/null || u2='-'
    fi
    [ -n "$rd1" ] && r1="每月${rd1}日" || r1='-'
    [ -n "$rd2" ] && r2="每月${rd2}日" || r2='-'
  fi

  cat <<EOF
READY=$ready
DUAL=${dual:-0}
SLOT=${slot:-0}
MODE=$mode
CURRENT=$current
AUTO=$auto_txt
AUTO_FLAG=${auto:-0}
OP1=$op1s
OP2=$op2s
USE1=$use1
USE2=$use2
P1=${p1:-0}
P2=${p2:-0}
SW=${sw:-0}
DAY1=$d1
DAY2=$d2
USED1=$u1
USED2=$u2
LEFT1=$l1
LEFT2=$l2
RESET1=$r1
RESET2=$r2
SRC=$src
EOF
}

cmd_single() {
  # keep currently active slot provisioned; disable the other
  RAW=$(json)
  slot=$(jget '@.current_sim_slot')
  [ -n "$slot" ] || slot=1
  if [ "$slot" = "2" ]; then
    p1=0; p2=1
  else
    p1=1; p2=0
  fi
  log "set single-card mode active_slot=$slot"
  ubus -t 15 call zwrt_zte_mdm.api zwrt_mdm_change_provision_session "{\"active_slot\":2,\"active_flag\":$p2}" >/dev/null
  ubus -t 15 call zwrt_zte_mdm.api zwrt_mdm_change_provision_session "{\"active_slot\":1,\"active_flag\":$p1}" >/dev/null
  # disable auto switch when forcing single
  ubus -t 10 call zwrt_zte_mdm.api st_set_auto_switch_slot '{"auto_switch_slot_flag":0}' >/dev/null 2>&1 || true
  echo OK single
}

cmd_dual() {
  log "set dual-standby mode"
  ubus -t 15 call zwrt_zte_mdm.api zwrt_mdm_change_provision_session '{"active_slot":2,"active_flag":1}' >/dev/null
  ubus -t 15 call zwrt_zte_mdm.api zwrt_mdm_change_provision_session '{"active_slot":1,"active_flag":1}' >/dev/null
  echo OK dual
}

cmd_slot() {
  n=${1:-}
  case "$n" in
    1|2) ;;
    *) echo "usage: $0 slot 1|2" >&2; exit 2 ;;
  esac
  log "activate sim slot $n"
  # ensure at least this slot is provisioned, then activate
  ubus -t 15 call zwrt_zte_mdm.api zwrt_mdm_change_provision_session "{\"active_slot\":$n,\"active_flag\":1}" >/dev/null
  ubus -t 12 call zwrt_zte_mdm.api zwrt_zte_mdm_activate_sim "{\"sim_card_id\":$n}" >/dev/null
  echo OK slot "$n"
}

cmd_auto() {
  flag=${1:-0}
  case "$flag" in
    0|1) ;;
    on) flag=1 ;;
    off) flag=0 ;;
    *) echo "usage: $0 auto 0|1" >&2; exit 2 ;;
  esac
  log "set auto switch flag=$flag"
  ubus -t 10 call zwrt_zte_mdm.api st_set_auto_switch_slot "{\"auto_switch_slot_flag\":$flag}" >/dev/null
  echo OK auto "$flag"
}

case "${1:-status}" in
  status) status ;;
  single) cmd_single ;;
  dual) cmd_dual ;;
  slot) cmd_slot "${2:-}" ;;
  auto) cmd_auto "${2:-0}" ;;
  *)
    echo "usage: $0 {status|single|dual|slot <1|2>|auto <0|1>}" >&2
    exit 2
    ;;
esac
