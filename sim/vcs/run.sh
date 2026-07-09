#!/usr/bin/env bash
#============================================================================
# run.sh -- run the elaborated VCS image (./simv).
#
#   ./run.sh                 # run, tee to simv.run.log, print the verdict
#   WAVES=1 ./run.sh         # also dump all signals to waves.vpd (DVE/Verdi)
#   ./run.sh +<plusarg> ...  # extra args are passed straight to simv
#
# The testbench self-checks (single-word packet on each of the 4 RIFL links,
# paired 0<->1 / 2<->3) and prints "TB PASSED" / "TB FAILED" before $finish.
#============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

[[ -x ./simv ]] || { echo "ERROR: ./simv not found -- run ./compile.sh (or 'make compile') first."; exit 1; }
LOG="${LOG:-simv.run.log}"

if [[ "${WAVES:-0}" == "1" ]]; then
  cat > .dump.ucli <<'EOF'
dump -file waves.vpd -type vpd
dump -add / -depth 0 -aggregates enable
run
quit
EOF
  echo "== running ./simv  (waveform -> waves.vpd) =="
  ./simv +vcs+initreg+0 -ucli -do .dump.ucli -l "$LOG" "$@"
else
  echo "== running ./simv =="
  ./simv +vcs+initreg+0 -l "$LOG" "$@"
fi

echo "---- verdict ----"
grep -E "TB (PASSED|FAILED)|all RIFL links up|Error|timeout" "$LOG" || echo "(no verdict line found -- see $LOG)"
