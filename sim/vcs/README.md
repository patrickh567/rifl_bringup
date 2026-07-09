# VCS simulation of `tb_rifl_subsystem`

Synopsys VCS flow for the RIFL subsystem testbench (`tb/tb_rifl_subsystem.sv`).
The TB instantiates `rifl_subsystem` directly, wires the four RIFL links in
peer pairs over the GT serial (0↔1, 2↔3), brings the links up through the
AXI-Lite register map, then sends and receives one word per link and checks it.

## What this needs (and why it isn't one command)

The testbench drives the **real** RIFL IP and transceivers, so a build pulls in
three things from two different places:

| Piece | Source | Provided by |
|-------|--------|-------------|
| In-tree RTL + TB | `v/`, `tb/`, `basejump_stl_bigblade/` | `filelist.f` (committed) |
| Generated IP sim sources — `clk_wiz_0` (MMCM), `RIFL_0..3` (gtwizard/**GTYE4**) | Vivado, from the `.xci` | `ip_sim_vlog.f` / `ip_sim_vhdl.f` (made by `make ip`) |
| Xilinx sim libraries — `unisims_ver`, `secureip`, `xpm`, … | `compile_simlib` | `$SIMLIB_DIR` (made by `make ip`) |

`compile.sh` stitches all three together. None of the GTY/MMCM logic exists as
in-tree RTL, so `make ip` (which runs Vivado once) is a prerequisite for a real
run — see the **GTY caveat** below.

## Prerequisites

- **Vivado 2019.1.3** (`vivado` on `PATH`, or set `VIVADO=`). `XILINX_VIVADO`
  must point at the install (used for `glbl.v` and the sim libs).
- **Synopsys VCS** (`vlogan`, `vhdlan`, `vcs` on `PATH`).
- The project must already be created (it supplies the IP):
  ```sh
  make -C ../.. create_rifl_project        # from this dir; builds vu47p_rifl/
  ```

## Usage

```sh
cd sim/vcs

make ip          # ONE-TIME (slow): compile_simlib + generate IP sim sources.
                 #   Reuse an existing simlib instead:  make ip SIMLIB_DIR=/path/to/vcs_simlib
make compile     # vlogan + vcs  ->  ./simv
make run         # run ./simv, print "TB PASSED" / "TB FAILED"

make waves       # run with a full VPD dump (waves.vpd; open in DVE/Verdi)
make all         # compile + run
make clean       # remove build products (keeps the simlib)
```

Environment knobs (all optional): `RIFL_ROOT`, `SIMLIB_DIR`, `PROJECT_XPR`,
`EXPORT_DIR`, `VCS_BIN_DIR`, `WORKLIB`, `TOP`, `FORCE_SIMLIB=1`.

## Files

| File | Role |
|------|------|
| `filelist.f` | In-tree RTL + TB: defines, `+incdir`, hardened-primitive overrides, BaseJump `-y` dirs. The part you hand-maintain. |
| `gen_ip_and_simlib.tcl` | Vivado batch: `compile_simlib`, generate IP sim sources, emit `ip_sim_*.f`, and run `export_simulation` as a cross-check. |
| `compile.sh` | Renders `synopsys_sim.setup`, runs `vhdlan`/`vlogan`/`vcs`, derives the `-L` library list from the simlib. |
| `run.sh` | Runs `./simv` (optionally with waveforms) and prints the verdict. |
| `Makefile` | Orchestrates the above. |
| `ip_sim_vlog.f`, `ip_sim_vhdl.f` | **Generated** by `make ip` — do not edit. |
| `ip_gen/` | **Generated**: Vivado's own `export_simulation` VCS scripts, kept as an authoritative reference. |

## GTY caveat

`README.md` at the repo root notes that full **GTY `secureip` elaboration is
slow** — link bring-up takes a long simulation time, and on `xsim` it was
impractical. VCS handles `secureip` better, but expect a long run; the TB has a
50 µs global watchdog. If you only want to syntax/elaboration-check the in-tree
RTL, `./compile.sh` run **without** `make ip` analyzes `filelist.f` alone and
skips the transceiver link.

If the hand-stitched build hits an IP ordering or library-mapping snag, the
Vivado-generated scripts under `ip_gen/` (from `export_simulation`) are the
authoritative reference for the exact compile order and `-L` list.

## Not in this flow

`design_1` (JTAG-to-AXI) and the AXI clock converters live in `top_rifl`, not in
`rifl_subsystem`, so they are intentionally excluded. To simulate the full
`top_rifl`, add it as the sim top and drop the two `*design_1* / *axi_clock_converter*`
skips in `gen_ip_and_simlib.tcl`.
