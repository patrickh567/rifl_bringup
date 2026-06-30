# VU47P RIFL Bring-up Image

Self-contained Vivado project for the VU47P RIFL optical-link bring-up image
(`top_rifl`). A JTAG-to-AXI master drives a fully software-controlled TX/RX
datapath over four RIFL links (GTY quads 131/133/135/229): per-link AXI clock
converters cross into each link's `rifl_usr_clk`, TX/RX/tkeep FIFOs buffer the
AXI-Stream, and an AXI-Lite register map provides control + status.

Everything required to build is in this repo — no external repositories or IP
paths.

## Module hierarchy

```
top_rifl
├── axi_jtag_master              design_1 (JTAG-to-AXI master + AXI switch)
├── rifl_axi_clock_converters    4x axi_clock_converter (init_clk <-> rifl_usr_clk)
└── rifl_subsystem               RIFL IPs + GTs, TX/RX/tkeep FIFOs, axi_lite_regs,
                                 reset/status plane, clk_wiz_0 MMCM (raw IBUFDS+BUFG)
```

The domain-1 reset VIO (`design_vio_rifl_rst`) lives at `top_rifl` and drives
design_1 + the register map. Three independent reset domains: VIO →
design_1/regmap, `cc_reset` → converters, `core_reset` → RIFL cores + FIFOs.

## Layout

| Path | Contents |
|------|----------|
| `v/` | RTL sources (`top_rifl`, `rifl_subsystem`, `axi_jtag_master`, `rifl_axi_clock_converters`, FIFOs, `axi_lite_regs`, `event_capture_cdc`, …) |
| `tb/` | `tb_rifl_subsystem` — single-word send/receive per paired RIFL link |
| `xdc/` | `io.xdc` (pins) + `impl.tcl` (GT placement) |
| `script/` | block-design / IP Tcl (`design_1_bd`, `axi_clock_converter_0`, `clk_wiz_0`), bitstream + FPGA-programming helpers, RIFL hardware-manager configs |
| `xci/` | RIFL IP instance configs (`RIFL_0..3`, one GTY quad each) |
| `common/RIFL/ip_repo/` | the RIFL IP source (in-tree) |
| `basejump_stl_bigblade/` | the BaseJump STL subset used (`bsg_misc`, `bsg_async`, `bsg_dataflow`, `bsg_mem`) |
| `vu47p_project.tcl` | base project script (sources, IP, block designs) |
| `vu47p_rifl_project.tcl` | layers `top_rifl` on the base + creates the `vu47p_rifl` project |

## Build

Requires Vivado **2019.1.3** (AR72746); part `xcvu47p-fsvh2892-3-e`.

```sh
export XILINX_VIVADO=/path/to/Xilinx/Vivado/2019.1
make build_rifl               # create (if needed) + synth + impl + bitstream
make create_rifl_project      # create the project only (no synth/impl)
make open_rifl_project        # open the project in the GUI
make program_fpga XVC_URL=<host:port>
```

## Notes

- A local fix is applied to the RIFL IP in `common/RIFL/ip_repo`: `RIFL.sv`'s
  `gt_bit_error` was driven by N concurrent assigns (a per-channel `for` loop) in
  the error-injection-disabled path; reduced to a single driver so it elaborates
  under stricter front-ends.
- Behavioral simulation compiles against the RIFL **RTL source** (not a netlist).
  Full GTY `secureip` elaboration is impractical under xsim 2019.1.3; for
  datapath/AXI verification use a GT-bypass loopback in place of the transceiver.
- `make build_rifl` implements with `Performance_ExplorePostRoutePhysOpt`. The
  ~390 MHz GTY user-clock datapath closes timing via AXIS register slices
  (`axis_skid_buffer` in `v/rifl_txrx_fifo.v`) on the FIFO↔RIFL TX/RX paths,
  which decouple FIFO placement from the GT. `xdc/impl.tcl` carries the GT refclk
  pin placement, the init/core/usr-clock CDC constraints, and the per-link pblocks.
