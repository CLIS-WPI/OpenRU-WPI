# Sourced by split.sh, up.sh and restart_ru.sh. TX gain limit for the bench radio: TX_GAIN must be a plain decimal
# integer (no sign, decimals, spaces or leading zeros) <= the limit; the limit is 30 unless TX_GAIN_MAX (same format,
# at most 40) raises it for that run with the human's approval. All comparisons in bash base-10 arithmetic.
tx_gain_check() { # <caller name>; reads TX_GAIN and TX_GAIN_MAX; exits 2 on refusal
  local who="$1" int='^(0|[1-9][0-9]*)$' gmax="${TX_GAIN_MAX-30}" g="${TX_GAIN-}"
  [[ "$gmax" =~ $int ]] && (( 10#$gmax <= 40 )) \
    || { echo "$who: FAIL: TX_GAIN_MAX must be a plain integer <= 40 (got '$gmax')" >&2; exit 2; }
  [[ "$g" =~ $int ]] \
    || { echo "$who: FAIL: TX_GAIN must be a plain integer (got '$g')" >&2; exit 2; }
  (( 10#$g <= 10#$gmax )) \
    || { echo "$who: FAIL: TX_GAIN $g > limit $gmax (TX_GAIN_MAX raises the limit, at most 40)" >&2; exit 2; }
}
