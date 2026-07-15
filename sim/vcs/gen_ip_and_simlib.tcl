#=============================================================================
# gen_ip_and_simlib.tcl -- prepare the Xilinx-side inputs the VCS flow needs.
#
#   vivado -mode batch -source sim/vcs/gen_ip_and_simlib.tcl
#
# Does four things:
#   1. Compiles the Xilinx simulation libraries for VCS (compile_simlib), once.
#   2. Opens the created vu47p_rifl project, adds the testbench to sim_1, and
#      generates the IP simulation sources for clk_wiz_0 + RIFL_0..3
#      (MMCM, gtwizard/GTYE4 transceivers).
#   3. Writes VCS file lists for those generated IP sources, split by language:
#         ip_sim_vlog.f  (Verilog/SystemVerilog, with +incdir for headers)
#         ip_sim_vhdl.f  (VHDL, if any)
#      -- these are consumed by compile.sh; the in-tree RTL stays in filelist.f.
#   4. Also runs export_simulation -simulator vcs as an authoritative
#      cross-reference (under $EXPORT_DIR) -- see README.md.
#
# Environment (all optional, with defaults):
#   RIFL_ROOT    repo root                 (default: two dirs above this script)
#   PROJECT_XPR  created project .xpr       (default: $RIFL_ROOT/vu47p_rifl/vu47p_rifl.xpr)
#   SIMLIB_DIR   compiled-simlib output dir (default: <this dir>/xil_simlib)
#   EXPORT_DIR   export_simulation output   (default: <this dir>/ip_gen)
#   VCS_BIN_DIR  dir holding vcs/vlogan      (default: dirname of `which vcs`)
#   FORCE_SIMLIB if set, rebuild the simlib even if it already exists
#=============================================================================

set script_dir [file normalize [file dirname [info script]]]
proc envdef {name default} {
  return [expr {[info exists ::env($name)] ? $::env($name) : $default}]
}

set rifl_root   [envdef RIFL_ROOT   [file normalize $script_dir/../..]]
set project_xpr [envdef PROJECT_XPR [file join $rifl_root vu47p_rifl vu47p_rifl.xpr]]
set simlib_dir  [envdef SIMLIB_DIR  [file join $script_dir xil_simlib]]
set export_dir  [envdef EXPORT_DIR  [file join $script_dir ip_gen]]
set out_dir     $script_dir

puts "== gen_ip_and_simlib =="
puts "   rifl_root   = $rifl_root"
puts "   project_xpr = $project_xpr"
puts "   simlib_dir  = $simlib_dir"

if {![file exists $project_xpr]} {
  puts "ERROR: project not found: $project_xpr"
  puts "       Create it first:   make -C $rifl_root create_rifl_project"
  exit 1
}

# ---- 1. compile the Xilinx simulation libraries for VCS (idempotent) -------
if {![file exists [file join $simlib_dir synopsys_sim.setup]] || [info exists ::env(FORCE_SIMLIB)]} {
  puts "INFO: compiling Xilinx simulation libraries for VCS into $simlib_dir ..."
  set vcs_path ""
  if {[info exists ::env(VCS_BIN_DIR)]} {
    set vcs_path $::env(VCS_BIN_DIR)
  } else {
    catch { set vcs_path [file dirname [exec which vcs]] }
  }
  set cs_args [list -simulator vcs -family all -language all -library all -dir $simlib_dir -force]
  if {$vcs_path ne ""} { lappend cs_args -simulator_exec_path $vcs_path }
  compile_simlib {*}$cs_args
} else {
  puts "INFO: reusing existing simlib (set FORCE_SIMLIB=1 to rebuild)."
}

# ---- 2. open project, register the TB, generate IP simulation sources ------
open_project $project_xpr
update_compile_order -fileset sources_1

set tb [file join $rifl_root tb tb_rifl_subsystem.sv]
if {[llength [get_files -quiet -of_objects [get_filesets sim_1] *tb_rifl_subsystem.sv]] == 0} {
  add_files -fileset sim_1 -norecurse $tb
}
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] *tb_rifl_subsystem.sv]
set_property top     tb_rifl_subsystem [get_filesets sim_1]
set_property top_lib xil_defaultlib    [get_filesets sim_1]

# RIFL_0..3 were de-IP'd to in-context rtl/ (commit 1292f74); clk_wiz_0 is the only IP left.
set need_ips [get_ips -quiet {clk_wiz_0}]
puts "INFO: generating simulation targets for: $need_ips"
generate_target {simulation} $need_ips
catch { export_ip_user_files -of_objects $need_ips -no_script -sync -force -quiet }

# ---- 3. emit VCS file lists for the generated IP sim sources ---------------
# Walk the sim_1 compile order (dependency-ordered) and keep only the
# generated IP sources -- the in-tree RTL is compiled from filelist.f, and the
# TB (rifl_subsystem) uses neither design_1 nor the AXI clock converters.
set ordered [get_files -quiet -compile_order sources -used_in simulation -of_objects [get_filesets sim_1]]
set vlog {}
set vhdl {}
set incdirs {}
foreach f $ordered {
  set fp [file normalize $f]
  if {[string match $rifl_root/v/* $fp]
   || [string match $rifl_root/tb/* $fp]
   || [string match $rifl_root/basejump_stl_bigblade/* $fp]
   || [string match $rifl_root/common/* $fp]} { continue }
  if {[string match *design_1* $fp] || [string match *axi_clock_converter* $fp]} { continue }
  set ft [get_property FILE_TYPE [lindex [get_files -quiet -all $f] 0]]
  if {[string match VHDL* $ft]} {
    lappend vhdl $fp
  } elseif {[string match *Header* $ft]} {
    lappend incdirs [file dirname $fp]
  } else {
    lappend vlog $fp
  }
}

proc write_f {path header lines} {
  set fh [open $path w]
  puts $fh $header
  foreach l $lines { puts $fh $l }
  close $fh
  puts "INFO: wrote [llength $lines] source(s) -> [file tail $path]"
}
set vhdr "// generated IP Verilog/SV sim sources (clk_wiz_0 + RIFL_0..3) -- regenerated by gen_ip_and_simlib.tcl"
foreach d [lsort -unique $incdirs] { append vhdr "\n+incdir+$d" }
write_f [file join $out_dir ip_sim_vlog.f] $vhdr $vlog
write_f [file join $out_dir ip_sim_vhdl.f] "-- generated IP VHDL sim sources -- regenerated by gen_ip_and_simlib.tcl" $vhdl

# ---- 4. authoritative cross-reference: Vivado-generated VCS scripts --------
if {[catch {
  export_simulation -simulator vcs -of_objects [get_filesets sim_1] \
    -directory $export_dir -lib_map_path $simlib_dir -use_ip_compiled_libs -force
} err]} {
  puts "INFO: export_simulation skipped ($err) -- not required for the hand flow."
} else {
  puts "INFO: reference VCS scripts written under $export_dir (see README)."
}

close_project
puts "== done -- now run:  make compile && make run =="
