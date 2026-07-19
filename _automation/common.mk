# _automation/common.mk — shared Make logic for all FPGA projects (BATCH FLOW)
# Include this from project-level Makefiles only:
#   include $(shell git rev-parse --show-toplevel)/_automation/common.mk
#
# Do NOT add build logic to project Makefiles. All policy lives here.
# All targets use batch tools (synthesis, map, par, bitgen).

# ── Output control ────────────────────────────────────────────────────────────
# Set VERBOSE=1 to see live tool output while still logging
# Usage: make syn VERBOSE=1
VERBOSE    ?= 0

# ── Environment check (must fire before any recipe) ───────────────────────────
ifndef DIAMOND_ENV_SOURCED
$(error Environment not initialized. Run: source ../_automation/env.sh)
endif

# ── Project identity (derived entirely from filesystem) ───────────────────────
PROJECT_DIR  := $(abspath $(CURDIR))
PROJECT_NAME := $(notdir $(PROJECT_DIR))
AUTOMATION   := $(AUTOMATION_ROOT)
META         := $(PROJECT_DIR)/project.meta

# ── Validate project.meta exists ─────────────────────────────────────────────
ifeq ($(wildcard $(META)),)
$(error ERROR: project.meta not found in $(PROJECT_DIR))
endif

# ── Read hardware facts from project.meta (batch flow fields) ─────────────────
ARCH         := $(shell grep '^ARCH='         $(META) | cut -d= -f2)
DEVICE       := $(shell grep '^DEVICE='       $(META) | cut -d= -f2)
PACKAGE      := $(shell grep '^PACKAGE='      $(META) | cut -d= -f2)
PERF_GRADE   := $(shell grep '^PERF_GRADE='   $(META) | cut -d= -f2)
OC           := $(shell grep '^OC='           $(META) | cut -d= -f2)
TOP_MODULE   := $(shell grep '^TOP_MODULE='   $(META) | cut -d= -f2)

# ── Source discovery (evaluated at Make parse time) ───────────────────────────
RTL_SOURCES := $(shell cat $(PROJECT_DIR)/src/sources.f 2>/dev/null | \
    grep -v '^\s*\#' | grep -v '^\s*$$' | sed 's|^|$(PROJECT_DIR)/|')
TB_SOURCES  := $(shell cat $(PROJECT_DIR)/tb/tb_files.f 2>/dev/null | \
    grep -v '^\s*\#' | grep -v '^\s*$$' | sed 's|^|$(PROJECT_DIR)/|')

# ── Detect testbench module name (auto-extract from first tb file) ─────────────
TOP_TB := $(shell \
  first_tb=$$(echo "$(TB_SOURCES)" | cut -d' ' -f1); \
  if [ -f "$$first_tb" ]; then \
    grep -m1 "^[[:space:]]*module[[:space:]]" "$$first_tb" | sed 's/.*module[[:space:]]\+\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/'; \
  else \
    echo "$(TOP_MODULE)_tb"; \
  fi \
)

# ── Pin constraints (required for place-and-route) ─────────────────────────
TOP_LPF := $(PROJECT_DIR)/par/top.lpf

SYN_DEPS := $(RTL_SOURCES) $(META)
PAR_DEPS := $(TOP_LPF)
SIM_DEPS := $(RTL_SOURCES) $(TB_SOURCES)

# ── Package code mapping for device string ────────────────────────────────────
PKG_CODE := $(if $(filter CABGA256,$(PACKAGE)),BG256,$(if $(filter FTBGA256,$(PACKAGE)),FTG256,$(if $(filter QFN72,$(PACKAGE)),SG72,BG256)))
OC_CODE := $(shell echo "$(OC)" | cut -c1)
DEV_STRING := $(DEVICE)-$(PERF_GRADE)$(PKG_CODE)$(OC_CODE)

# ── Default goal ──────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

# ── Phony targets ─────────────────────────────────────────────────────────────
.PHONY: all syn par pgrm pgrm-bit pgrm-jed sim sim-gui lint prj prj-export \
        clean clean-syn clean-par clean-pgrm clean-sim clean-prj help check-env

# ── Validation checks ─────────────────────────────────────────────────────────
check-env:
ifndef DIAMOND_ENV_SOURCED
	$(error Environment not initialized. Run: source _automation/env.sh)
endif

# Validate project.meta fields exist
ifndef ARCH
	$(error ARCH not defined in project.meta)
endif
ifndef DEVICE
	$(error DEVICE not defined in project.meta)
endif
ifndef PACKAGE
	$(error PACKAGE not defined in project.meta)
endif
ifndef PERF_GRADE
	$(error PERF_GRADE not defined in project.meta)
endif
ifndef OC
	$(error OC not defined in project.meta)
endif

# ── Synthesis (batch mode) ──────────────────────────────────────────────────
# Runs from syn/out/, invokes synthesis batch tool with RTL sources
# Produces: syn/out/<ProjectName>_impl1.ngd

$(PROJECT_DIR)/syn/out/.syn_done: $(SYN_DEPS) | check-env
	@mkdir -p $(PROJECT_DIR)/syn/logs $(PROJECT_DIR)/syn/out
	$(eval _SYN_LOG := $(PROJECT_DIR)/syn/logs/syn_$(shell date +%Y%m%d_%H%M%S).log)
	@echo "[SYN] Running synthesis... Log: $(_SYN_LOG)"
	@cd $(PROJECT_DIR)/syn/out && \
	  if [ "$(VERBOSE)" = "1" ]; then \
	    synthesis \
	      -a "$(ARCH)" \
	      -d $(DEVICE) \
	      -t $(PACKAGE) \
	      -s $(PERF_GRADE) \
	      -top $(TOP_MODULE) \
	      $(foreach f,$(RTL_SOURCES),-ver "$(f)") \
	      -ngd $(PROJECT_NAME)_impl1.ngd 2>&1 | tee $(_SYN_LOG); \
	  else \
	    synthesis \
	      -a "$(ARCH)" \
	      -d $(DEVICE) \
	      -t $(PACKAGE) \
	      -s $(PERF_GRADE) \
	      -top $(TOP_MODULE) \
	      $(foreach f,$(RTL_SOURCES),-ver "$(f)") \
	      -ngd $(PROJECT_NAME)_impl1.ngd > $(_SYN_LOG) 2>&1; \
	  fi || (echo "Synthesis failed. Last 40 lines of $(_SYN_LOG):"; tail -40 $(_SYN_LOG); exit 1)
	@touch $@
	@echo "[SYN] Complete. Output: $(PROJECT_DIR)/syn/out/$(PROJECT_NAME)_impl1.ngd"

syn: $(PROJECT_DIR)/syn/out/.syn_done

# ── Place and Route (batch mode) ────────────────────────────────────────────
# Runs map + par from par/out/, requires prior synthesis
# Produces: par/out/<ProjectName>_impl1_par.ncd

$(PROJECT_DIR)/par/out/.par_done: $(PAR_DEPS) | check-env
	@if [ ! -f "$(PROJECT_DIR)/syn/out/.syn_done" ]; then \
	  echo "ERROR: Synthesis not completed. Run 'make syn' first."; exit 1; \
	fi
	@if [ ! -f "$(PROJECT_DIR)/par/top.lpf" ]; then \
	  echo "ERROR: par/top.lpf not found. Fill in pin assignments before running par."; exit 1; \
	fi
	@mkdir -p $(PROJECT_DIR)/par/logs $(PROJECT_DIR)/par/out
	$(eval _PAR_LOG := $(PROJECT_DIR)/par/logs/par_$(shell date +%Y%m%d_%H%M%S).log)
	@echo "[MAP] Running map... Log: $(_PAR_LOG)"
	@cd $(PROJECT_DIR)/par/out && \
	  if [ "$(VERBOSE)" = "1" ]; then \
	    map \
	      -a "$(ARCH)" \
	      -p $(DEVICE) \
	      -t $(PACKAGE) \
	      -s $(PERF_GRADE) \
	      -oc $(OC) \
	      ../../syn/out/$(PROJECT_NAME)_impl1.ngd \
	      -mp "$(PROJECT_NAME)_impl1.mrp" \
	      -o  "$(PROJECT_NAME)_impl1_map.ncd" \
	      -pr "$(PROJECT_NAME)_impl1.prf" \
	      -lpf "../top.lpf" \
	      -c 0 2>&1 | tee $(_PAR_LOG); \
	  else \
	    map \
	      -a "$(ARCH)" \
	      -p $(DEVICE) \
	      -t $(PACKAGE) \
	      -s $(PERF_GRADE) \
	      -oc $(OC) \
	      ../../syn/out/$(PROJECT_NAME)_impl1.ngd \
	      -mp "$(PROJECT_NAME)_impl1.mrp" \
	      -o  "$(PROJECT_NAME)_impl1_map.ncd" \
	      -pr "$(PROJECT_NAME)_impl1.prf" \
	      -lpf "../top.lpf" \
	      -c 0 >> $(_PAR_LOG) 2>&1; \
	  fi || (echo "Map failed. Last 40 lines of $(_PAR_LOG):"; tail -40 $(_PAR_LOG); exit 1)
	@echo "[PAR] Running place-and-route..."
	@cd $(PROJECT_DIR)/par/out && \
	  if [ "$(VERBOSE)" = "1" ]; then \
	    par -w -l 5 -i 6 -t 1 -c 0 -e 0 \
	      -exp parUseNBR=1:parCDP=0:parCDR=0:parPathBased=OFF:parASE=1 \
	      $(PROJECT_NAME)_impl1_map.ncd \
	      $(PROJECT_NAME)_impl1_par.ncd \
	      $(PROJECT_NAME)_impl1.prf 2>&1 | tee -a $(_PAR_LOG); \
	  else \
	    par -w -l 5 -i 6 -t 1 -c 0 -e 0 \
	      -exp parUseNBR=1:parCDP=0:parCDR=0:parPathBased=OFF:parASE=1 \
	      $(PROJECT_NAME)_impl1_map.ncd \
	      $(PROJECT_NAME)_impl1_par.ncd \
	      $(PROJECT_NAME)_impl1.prf >> $(_PAR_LOG) 2>&1; \
	  fi || (echo "P&R failed. Last 40 lines of $(_PAR_LOG):"; tail -40 $(_PAR_LOG); exit 1)
	@touch $@
	@echo "[PAR] Complete. Output: $(PROJECT_DIR)/par/out/$(PROJECT_NAME)_impl1_par.ncd"

par: $(PROJECT_DIR)/par/out/.par_done

# ── Programming (bitgen batch mode) ────────────────────────────────────────
# Generates bitstream and/or JEDEC files
# Requires prior P&R completion

$(PROJECT_DIR)/pgrm/.bit_done: $(PROJECT_DIR)/par/out/.par_done | check-env
	@if [ ! -f "$(PROJECT_DIR)/par/out/.par_done" ]; then \
	  echo "ERROR: Place-and-route not completed. Run 'make par' first."; exit 1; \
	fi
	@mkdir -p $(PROJECT_DIR)/pgrm/logs
	$(eval _PGRM_LOG := $(PROJECT_DIR)/pgrm/logs/pgrm_$(shell date +%Y%m%d_%H%M%S).log)
	@echo "[PGRM-BIT] Generating bitstream... Log: $(_PGRM_LOG)"
	@cd $(PROJECT_DIR)/pgrm && \
	  if [ "$(VERBOSE)" = "1" ]; then \
	    bitgen -w \
	      "../par/out/$(PROJECT_NAME)_impl1_par.ncd" \
	      "../par/out/$(PROJECT_NAME)_impl1.prf" 2>&1 | tee $(_PGRM_LOG); \
	  else \
	    bitgen -w \
	      "../par/out/$(PROJECT_NAME)_impl1_par.ncd" \
	      "../par/out/$(PROJECT_NAME)_impl1.prf" > $(_PGRM_LOG) 2>&1; \
	  fi || (echo "Bitgen (bitstream) failed. Last 40 lines of $(_PGRM_LOG):"; tail -40 $(_PGRM_LOG); exit 1)
	@cp $(PROJECT_DIR)/par/out/$(PROJECT_NAME)_impl1_par.bit $(PROJECT_DIR)/pgrm/$(PROJECT_NAME)_impl1_par.bit
	@touch $@
	@echo "[PGRM-BIT] Complete. Output: $(PROJECT_DIR)/pgrm/$(PROJECT_NAME)_impl1_par.bit"

pgrm-bit: $(PROJECT_DIR)/pgrm/.bit_done

$(PROJECT_DIR)/pgrm/.jed_done: $(PROJECT_DIR)/par/out/.par_done | check-env
	@if [ ! -f "$(PROJECT_DIR)/par/out/.par_done" ]; then \
	  echo "ERROR: Place-and-route not completed. Run 'make par' first."; exit 1; \
	fi
	@mkdir -p $(PROJECT_DIR)/pgrm/logs
	$(eval _PGRM_LOG := $(PROJECT_DIR)/pgrm/logs/pgrm_$(shell date +%Y%m%d_%H%M%S).log)
	@echo "[PGRM-JED] Generating JEDEC files... Log: $(_PGRM_LOG)"
	@cd $(PROJECT_DIR)/pgrm && \
	  if [ "$(VERBOSE)" = "1" ]; then \
	    bitgen -w \
	      "../par/out/$(PROJECT_NAME)_impl1_par.ncd" \
	      -jedec \
	      "../par/out/$(PROJECT_NAME)_impl1.prf" 2>&1 | tee $(_PGRM_LOG); \
	  else \
	    bitgen -w \
	      "../par/out/$(PROJECT_NAME)_impl1_par.ncd" \
	      -jedec \
	      "../par/out/$(PROJECT_NAME)_impl1.prf" > $(_PGRM_LOG) 2>&1; \
	  fi || (echo "Bitgen (JEDEC) failed. Last 40 lines of $(_PGRM_LOG):"; tail -40 $(_PGRM_LOG); exit 1)
	@cp $(PROJECT_DIR)/par/out/$(PROJECT_NAME)_impl1_par.fea $(PROJECT_DIR)/pgrm/$(PROJECT_NAME)_impl1_par.fea
	@cp $(PROJECT_DIR)/par/out/$(PROJECT_NAME)_impl1_par_a.jed $(PROJECT_DIR)/pgrm/$(PROJECT_NAME)_impl1_par_a.jed
	@touch $@
	@echo "[PGRM-JED] Complete. Outputs: $(PROJECT_DIR)/pgrm/$(PROJECT_NAME)_impl1_par.fea + $(PROJECT_NAME)_impl1_par_a.jed"

pgrm-jed: $(PROJECT_DIR)/pgrm/.jed_done

# ── Programming (combined) ────────────────────────────────────────────────
pgrm: pgrm-bit pgrm-jed

# ── Simulation (Questa headless or GUI) ────────────────────────────────────────
# Generates sim/out/run.do (headless) and sim/out/run_gui.do (GUI) from RTL/TB sources
# RTL_SOURCES and TB_SOURCES discovered from src/sources.f and tb/tb_files.f

$(PROJECT_DIR)/sim/out/run.do: $(SIM_DEPS)
	@mkdir -p $(PROJECT_DIR)/sim/out
	@echo "Generating sim/out/run.do (headless mode)..."
	@echo "project new . $(PROJECT_NAME)_sim rtl_work" > $(PROJECT_DIR)/sim/out/run.do
	@$(foreach src,$(RTL_SOURCES),echo "project addfile $(src)" >> $(PROJECT_DIR)/sim/out/run.do; )
	@$(foreach src,$(TB_SOURCES),echo "project addfile $(src)" >> $(PROJECT_DIR)/sim/out/run.do; )
	@echo "project compileall" >> $(PROJECT_DIR)/sim/out/run.do
	@echo "vsim work.$(TOP_TB)" >> $(PROJECT_DIR)/sim/out/run.do
	@echo "run -all" >> $(PROJECT_DIR)/sim/out/run.do
	@echo "exit" >> $(PROJECT_DIR)/sim/out/run.do

$(PROJECT_DIR)/sim/out/run_gui.do: $(SIM_DEPS)
	@mkdir -p $(PROJECT_DIR)/sim/out
	@echo "Generating sim/out/run_gui.do (GUI mode)..."
	@echo "project new . $(PROJECT_NAME)_sim rtl_work" > $(PROJECT_DIR)/sim/out/run_gui.do
	@$(foreach src,$(RTL_SOURCES),echo "project addfile $(src)" >> $(PROJECT_DIR)/sim/out/run_gui.do; )
	@$(foreach src,$(TB_SOURCES),echo "project addfile $(src)" >> $(PROJECT_DIR)/sim/out/run_gui.do; )
	@echo "project compileall" >> $(PROJECT_DIR)/sim/out/run_gui.do
	@echo "vsim -voptargs=+acc work.$(TOP_TB)" >> $(PROJECT_DIR)/sim/out/run_gui.do

# Console mode simulation (headless)
sim: $(PROJECT_DIR)/sim/out/run.do check-env
	@mkdir -p $(PROJECT_DIR)/sim/logs $(PROJECT_DIR)/sim/out
	$(eval _SIM_LOG := $(PROJECT_DIR)/sim/logs/sim_$(shell date +%Y%m%d_%H%M%S).log)
	@echo "[SIM] Running simulation (headless)... Log: $(_SIM_LOG)"
	@cd $(PROJECT_DIR)/sim/out && \
	  if [ "$(VERBOSE)" = "1" ]; then \
	    vsim -c -do run.do 2>&1 | tee $(_SIM_LOG); \
	  else \
	    vsim -c -do run.do > $(_SIM_LOG) 2>&1; \
	  fi || (echo "Simulation failed. Last 40 lines of $(_SIM_LOG):"; tail -40 $(_SIM_LOG); exit 1)
	@echo "[SIM] Complete. Log: $(_SIM_LOG)"

# GUI mode simulation (interactive)
sim-gui: $(PROJECT_DIR)/sim/out/run_gui.do check-env
	@mkdir -p $(PROJECT_DIR)/sim/logs $(PROJECT_DIR)/sim/out
	@echo "[SIM-GUI] Launching Questa GUI..."
	@cd $(PROJECT_DIR)/sim/out && vsim -do run_gui.do

# ── Linting (Verilator) ────────────────────────────────────────────────────────
# Runs static analysis on RTL and testbench sources
lint: check-env
	@echo "[LINT] Running Verilator linting on RTL and testbench..."
	verilator --lint-only -Wall $(RTL_SOURCES) $(TB_SOURCES)
	@echo "[LINT] Complete."

# ── Diamond GUI (interactive project flow) ─────────────────────────────────────
# Generates a TCL file with RTL sources and launches Diamond GUI
prj: check-env
	@mkdir -p $(PROJECT_DIR)/prj/impl1
	$(eval _TCL_FILE := $(PROJECT_DIR)/prj/impl1/project.tcl)
	@echo "Generating TCL file: $(_TCL_FILE)"
	@echo 'prj_project new -name "$(TOP_MODULE)" -impl "impl1" -dev $(DEV_STRING) -synthesis "lse" -lpf "$(PROJECT_DIR)/par/top.lpf"' > $(_TCL_FILE)
	@$(foreach src,$(RTL_SOURCES),echo 'prj_src add "$(src)"' >> $(_TCL_FILE); )
	@echo 'prj_project save' >> $(_TCL_FILE)
	@echo "[PRJ] Launching Diamond GUI with TCL file..."
	@cd $(PROJECT_DIR)/prj/impl1 && ~/lscc/diamond/3.14/bin/lin64/diamond -t project.tcl

# ── Diamond project export (creates deployable archive) ────────────────────────
# Copies RTL/TB/constraints to an export directory, creates a Diamond project with
# testbenches marked as simulation-only, and exports to a ZIP archive.
# Intermediate files are cleaned up; only the archive remains.

prj-export: check-env
	@mkdir -p $(PROJECT_DIR)/export/impl1/source $(PROJECT_DIR)/export/logs
	$(eval _EXPORT_DIR := $(PROJECT_DIR)/export)
	$(eval _SOURCE_DIR := $(_EXPORT_DIR)/impl1/source)
	$(eval _TCL_FILE := $(_EXPORT_DIR)/impl1/export.tcl)
	$(eval _ARCHIVE := $(_EXPORT_DIR)/$(PROJECT_NAME)_export.zip)
	@echo "[PRJ-EXPORT] Copying source files to $(_SOURCE_DIR)..."
	@cp $(RTL_SOURCES) $(TB_SOURCES) $(TOP_LPF) $(_SOURCE_DIR)/
	@echo "[PRJ-EXPORT] Generating TCL file: $(_TCL_FILE)"
	@echo 'prj_project new -name "$(TOP_MODULE)" -impl "impl1" -dev $(DEV_STRING) -synthesis "synplify" -lpf "$(_SOURCE_DIR)/top.lpf"' > $(_TCL_FILE)
	@$(foreach src,$(RTL_SOURCES),echo 'prj_src add "$(_SOURCE_DIR)/$(notdir $(src))"' >> $(_TCL_FILE); )
	@$(foreach src,$(TB_SOURCES),echo 'prj_src add "$(_SOURCE_DIR)/$(notdir $(src))"' >> $(_TCL_FILE); )
	@$(foreach src,$(TB_SOURCES),echo 'prj_src syn_sim -src "$(_SOURCE_DIR)/$(notdir $(src))" SimulateOnly' >> $(_TCL_FILE); )
	@echo 'prj_project save' >> $(_TCL_FILE)
	@echo 'prj_project archive -includeAll "$(_ARCHIVE)"' >> $(_TCL_FILE)
	@echo 'exit' >> $(_TCL_FILE)
	@echo "[PRJ-EXPORT] Running Diamond to create archive (log: $(_EXPORT_DIR)/logs/export.log)..."
	@cd $(_EXPORT_DIR)/impl1 && ~/lscc/diamond/3.14/bin/lin64/diamondc export.tcl > $(_EXPORT_DIR)/logs/export.log 2>&1 || (echo "[PRJ-EXPORT] FAILED. Check $(_EXPORT_DIR)/logs/export.log"; exit 1)
	@echo "[PRJ-EXPORT] Cleaning up intermediate files..."
	@rm -rf $(_EXPORT_DIR)/impl1 $(_EXPORT_DIR)/logs
	@echo "[PRJ-EXPORT] Complete. Archive: $(_ARCHIVE)"

# ── All (synthesis then place-and-route, fully headless) ──────────────────
all: syn par

# ── Clean targets ────────────────────────────────────────────────────────
clean:
	@echo "Cleaning all artifacts for $(PROJECT_NAME)"
	rm -rf $(PROJECT_DIR)/syn/out && rm -f $(PROJECT_DIR)/syn/logs/*
	rm -rf $(PROJECT_DIR)/par/out && rm -f $(PROJECT_DIR)/par/logs/*
	rm -f  $(PROJECT_DIR)/pgrm/*.bit $(PROJECT_DIR)/pgrm/*.jed $(PROJECT_DIR)/pgrm/*.fea
	rm -f $(PROJECT_DIR)/pgrm/logs/* $(PROJECT_DIR)/pgrm/.bit_done $(PROJECT_DIR)/pgrm/.jed_done
	rm -rf $(PROJECT_DIR)/sim/out && rm -f $(PROJECT_DIR)/sim/logs/*
	rm -rf $(PROJECT_DIR)/prj

clean-syn:
	rm -rf $(PROJECT_DIR)/syn/out

clean-par:
	rm -rf $(PROJECT_DIR)/par/out

clean-pgrm:
	rm -f  $(PROJECT_DIR)/pgrm/*.bit $(PROJECT_DIR)/pgrm/*.jed $(PROJECT_DIR)/pgrm/*.fea
	rm -f  $(PROJECT_DIR)/pgrm/.bit_done $(PROJECT_DIR)/pgrm/.jed_done

clean-sim:
	rm -f  $(PROJECT_DIR)/sim/out/run.do $(PROJECT_DIR)/sim/out/run_gui.do
	rm -f  $(PROJECT_DIR)/sim/out/transcript $(PROJECT_DIR)/sim/out/modelsim.ini
	rm -rf $(PROJECT_DIR)/sim/out/work $(PROJECT_DIR)/sim/out/rtl_work
	rm -f  $(PROJECT_DIR)/sim/out/*.wlf $(PROJECT_DIR)/sim/out/*.log $(PROJECT_DIR)/sim/out/*.jou
	rm -f  $(PROJECT_DIR)/sim/out/*.pb $(PROJECT_DIR)/sim/out/*.vstf
	rm -f  $(PROJECT_DIR)/sim/out/*.vcd $(PROJECT_DIR)/sim/out/$(PROJECT_NAME)_sim.cr.mti $(PROJECT_DIR)/sim/out/$(PROJECT_NAME)_sim.mpf

clean-prj:
	rm -rf $(PROJECT_DIR)/prj

# ── Help ─────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "Project: $(PROJECT_NAME)  [Device: $(shell grep '^DEVICE=' $(META) | cut -d= -f2)]"
	@echo "========================================================="
	@echo ""
	@echo "Environment (run once per shell session, from repo root):"
	@echo "  source _automation/env.sh    Initialize Diamond environment"
	@echo ""
	@echo "Build (default: silent mode; use VERBOSE=1 for live output):"
	@echo "  make all                     Run synthesis then place-and-route"
	@echo "  make syn [VERBOSE=1]         Synthesize RTL — batch mode"
	@echo "  make par [VERBOSE=1]         Map + place-and-route — batch mode"
	@echo ""
	@echo "Programming:"
	@echo "  make pgrm [VERBOSE=1]        Generate bitstream AND JEDEC files"
	@echo "  make pgrm-bit [VERBOSE=1]    Generate bitstream only (.bit)"
	@echo "  make pgrm-jed [VERBOSE=1]    Generate JEDEC files only (.fea + .jed)"
	@echo ""
	@echo "Simulation:"
	@echo "  make sim [VERBOSE=1]         Compile and run testbench — console (Questa Sim)"
	@echo "  make sim-gui                 Compile and run testbench — interactive GUI"
	@echo ""
	@echo "Linting:"
	@echo "  make lint                    Run Verilator linting on RTL and testbench"
	@echo ""
	@echo "Diamond GUI:"
	@echo "  make prj                     Launch Diamond GUI with generated project TCL file"
	@echo "  make prj-export              Create self-contained project archive (copies files, marks TB as sim-only)"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean                   Remove all artifacts"
	@echo "  make clean-syn               Remove synthesis artifacts only"
	@echo "  make clean-par               Remove place-and-route artifacts only"
	@echo "  make clean-pgrm              Remove programming artifacts only"
	@echo "  make clean-sim               Remove simulation artifacts only"
	@echo "  make clean-prj               Remove Diamond GUI project artifacts only"
	@echo ""
	@echo "Help:"
	@echo "  make help                    Show this message"
	@echo ""
	@echo "Config:  project.meta  Pin constraints: par/top.lpf"
	@echo "Sources: src/sources.f  Testbench: tb/tb_files.f"
	@echo "Outputs: syn/out/ par/out/ pgrm/    Logs: syn/logs/ par/logs/ pgrm/logs/"
	@echo ""
