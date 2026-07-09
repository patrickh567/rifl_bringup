#!/usr/bin/env bash
#============================================================================
# compile.sh -- analyze + elaborate tb_rifl_subsystem with Synopsys VCS.
#
#   ./compile.sh                 # full build -> ./simv  (needs 'make ip' first)
#
# Stitches three inputs:
#   1. ip_sim_vhdl.f / ip_sim_vlog.f  - Vivado-generated IP sim sources
#                                       (clk_wiz_0 MMCM, RIFL_0..3 gtwizard/GTYE4)
#   2. filelist.f                     - in-tree RTL + the testbench
#   3. $SIMLIB_DIR                    - Xilinx sim libs compiled for VCS
#                                       (unisims_ver, secureip, xpm, ...)
# (1) and (3) are produced by gen_ip_and_simlib.tcl  ->  `make ip`.
#
# If the IP sources / simlib are absent, this still ANALYZES the in-tree RTL
# (a useful syntax/elaboration smoke check) and skips the transceiver link.
#
# Override any of these via the environment: RIFL_ROOT, SIMLIB_DIR, TOP, WORKLIB.
#============================================================================
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

: "${RIFL_ROOT:=$(cd "$here/../.." && pwd)}"
: "${SIMLIB_DIR:=$here/xil_simlib}"
: "${TOP:=tb_rifl_subsystem}"
: "${WORKLIB:=xil_defaultlib}"
export RIFL_ROOT

# true if a VCS -f file lists at least one real HDL source (ignores blank/
# comment/option lines such as +incdir+ or a bare header) -- an empty list with
# only a header must NOT trigger vlogan/vhdlan (they error on "no source files").
has_src() { [[ -f "$1" ]] && grep -qiE '\.(v|sv|vh|svh|vhd|vhdl)([[:space:]]|$)' "$1"; }

echo "== RIFL VCS compile =="
echo "   RIFL_ROOT  = $RIFL_ROOT"
echo "   SIMLIB_DIR = $SIMLIB_DIR"
echo "   TOP        = $TOP"

# ---- tool / environment checks -------------------------------------------
command -v vlogan >/dev/null || { echo "ERROR: vlogan not on PATH -- source your VCS setup."; exit 1; }
command -v vcs    >/dev/null || { echo "ERROR: vcs not on PATH -- source your VCS setup.";    exit 1; }
: "${XILINX_VIVADO:?set XILINX_VIVADO (needed for glbl.v and the Xilinx sim libs)}"
GLBL="$XILINX_VIVADO/data/verilog/src/glbl.v"
[[ -f "$GLBL" ]] || { echo "ERROR: glbl.v not found at $GLBL"; exit 1; }

# ---- library setup: work lib + chain to the compiled Xilinx simlib --------
# Map WORKLIB both as DEFAULT and by name, so `-work $WORKLIB` and the
# `$WORKLIB.<top>` elaboration target both resolve.
mkdir -p "$WORKLIB"
{
  echo "WORK > DEFAULT"
  echo "DEFAULT : $here/$WORKLIB"
  echo "$WORKLIB : $here/$WORKLIB"
} > synopsys_sim.setup
have_libs=0
if [[ -f "$SIMLIB_DIR/synopsys_sim.setup" ]]; then
  echo "OTHERS = $SIMLIB_DIR/synopsys_sim.setup" >> synopsys_sim.setup
  have_libs=1
else
  echo "WARNING: $SIMLIB_DIR/synopsys_sim.setup not found -- run 'make ip' for a full build."
fi

VLOGAN_OPTS=( -full64 -nc -sverilog -timescale=1ps/1ps -work "$WORKLIB" )
# -ignore initializer_driver_checks: the RTL uses declaration initializers
# (e.g. `logic led_breath = 1'b0;`) on vars also written in an always_ff -- legal
# SV (the initializer just sets the t=0 value), but VCS flags it by default.
# +vcs+initreg+random (with ./simv +vcs+initreg+0 in run.sh) clears power-up X.
# The TB's link-up check is now X-safe (!==) so it no longer NEEDS this, but the
# GT usr-clock / transmit datapath still has uninitialized power-up state that
# hangs the first AXI write without it -- so register init is enabled by default.
VCS_OPTS=(    -full64 -nc -debug_access+all -timescale=1ps/1ps -ignore initializer_driver_checks +vcs+initreg+random )
if [[ -n "${VCS_EXTRA:-}" ]]; then VCS_OPTS+=( ${VCS_EXTRA} ); fi

# ---- analyze: generated IP VHDL (only if the list has real sources) ------
if has_src ip_sim_vhdl.f; then
  command -v vhdlan >/dev/null || { echo "ERROR: vhdlan not on PATH"; exit 1; }
  echo "-- vhdlan (generated IP VHDL) --"
  vhdlan -full64 -nc -work "$WORKLIB" -l vhdlan.log -f ip_sim_vhdl.f
fi

# ---- analyze: generated IP Verilog/SV + in-tree RTL + TB + glbl ----------
vlog_args=()
if has_src ip_sim_vlog.f; then
  echo "-- vlogan (RTL + TB + IP) --"; vlog_args+=( -f ip_sim_vlog.f )
else
  echo "-- vlogan (RTL + TB) --"
fi
vlog_args+=( -f filelist.f "$GLBL" )
vlogan "${VLOGAN_OPTS[@]}" -l vlogan.log "${vlog_args[@]}"

# ---- elaborate -----------------------------------------------------------
if [[ "$have_libs" == "1" ]] && { has_src ip_sim_vlog.f || has_src ip_sim_vhdl.f; }; then
  # -L libraries for elaboration.  Override with the XIL_LIBS env var (e.g.
  # XIL_LIBS="-L secureip -L unisims_ver -L xpm"); otherwise -L every Xilinx
  # library mapped in the compiled simlib, skipping the simulator's own package
  # libs (IEEE/STD/SYNOPSYS/GTECH/NOVAS/SMARTMODEL/FLEXMODEL) which are not -L
  # targets and would fail (e.g. SMARTMODEL needs $LMC_HOME).
  if [[ -n "${XIL_LIBS:-}" ]]; then
    xil_libs="$XIL_LIBS"
  else
    xil_libs=$(awk -F: '/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:/{gsub(/[ \t]/,"",$1); print $1}' "$SIMLIB_DIR/synopsys_sim.setup" \
                 | grep -viE '^(DEFAULT|WORK|std|ieee|GTECH|IEEE_|_IEEE|SYNOPSYS|STD|STD_DEVELOPERSKIT|NOVAS|SMARTMODEL|FLEXMODEL)$' \
                 | sed 's/^/-L /' | tr '\n' ' ')
  fi
  echo "-- vcs (elaborate $TOP) --"
  echo "   libs: $(echo "$xil_libs" | tr ' ' '\n' | grep -c '^-L')  Xilinx libraries"
  # shellcheck disable=SC2086
  vcs "${VCS_OPTS[@]}" -l vcs.log "$WORKLIB.$TOP" "$WORKLIB.glbl" $xil_libs -o simv
  echo
  echo "OK: built ./simv   (run it with ./run.sh  or  'make run')"
else
  echo
  echo "NOTE: analysis-only -- the in-tree RTL compiled cleanly, but the"
  echo "      Vivado-generated IP sources / Xilinx simlib are not present, so"
  echo "      the transceiver-level testbench was NOT linked.  Run 'make ip'"
  echo "      first to build ./simv.  See README.md (GTY caveat)."
fi
