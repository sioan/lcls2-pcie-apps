# Load RUCKUS environment and library
source -quiet $::env(RUCKUS_DIR)/vivado_proc.tcl

# Load local Source Code and Constraints
loadSource      -dir "$::DIR_PATH/hdl"
loadIpCore -path "$::DIR_PATH/coregen/ila_0.xci"

# Load Simulation
loadSource -sim_only -dir "$::DIR_PATH/tb"

