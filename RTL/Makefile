ARCH       ?= MachXO3D
DEVICE     ?= LCMXO3D-9400HC
PACKAGE    ?= CABGA256
PERF_GRADE ?= 5
OC         ?= Commercial

.PHONY: init list help

init:
ifndef PROJECT
	$(error PROJECT is required. Usage: make init PROJECT=MyProjectName)
endif
	@bash _automation/scaffold.sh "$(PROJECT)" "$(ARCH)" "$(DEVICE)" "$(PACKAGE)" "$(PERF_GRADE)" "$(OC)"

list:
	@bash -c ' \
	echo ""; \
	echo "Projects in this repository:"; \
	echo "-----------------------------"; \
	found=0; \
	for d in */; do \
	    if [ -f "$$d/project.meta" ]; then \
	        name=$${d%/}; \
	        dev=$$(grep -E "^(DEVICE|ARCH)=" "$$d/project.meta" 2>/dev/null | head -1 | cut -d= -f2 || true); \
	        spd=$$(grep -E "^(PERF_GRADE|SPEED)=" "$$d/project.meta" 2>/dev/null | head -1 | cut -d= -f2 || true); \
	        if [ -n "$$dev" ] && [ -n "$$spd" ]; then \
	            printf "  %-24s Device: %-20s Speed grade: %s\n" "$$name" "$$dev" "$$spd"; \
	        else \
	            printf "  %-24s\n" "$$name"; \
	        fi; \
	        found=1; \
	    fi; \
	done; \
	if [ "$$found" -eq 0 ]; then \
	    echo "  (none — run: make init PROJECT=<name>)"; \
	fi; \
	echo ""; \
	'

help:
	@echo ""
	@echo "Diamond FPGA Workspace — Root Commands"
	@echo "======================================================="
	@echo ""
	@echo "  make init PROJECT=<name>       Scaffold a new project with all boilerplate"
	@echo ""
	@echo "  Optional parameters for init:"
	@echo "    ARCH=<arch>                  Device architecture (default: MachXO3D)"
	@echo "    DEVICE=<device>              Device (default: LCMXO3D-9400HC)"
	@echo "    PACKAGE=<pkg>                Package code (default: CABGA256)"
	@echo "    PERF_GRADE=<grade>           Performance grade (default: 5)"
	@echo "    OC=<code>                    Operating condition (default: Commercial)"
	@echo ""
	@echo "  Example: make init PROJECT=uart ARCH=MachXO3D DEVICE=LCMXO3D-9400HC \\"
	@echo "           PACKAGE=CABGA256 PERF_GRADE=5 OC=Commercial"
	@echo ""
	@echo "  make list                      List all projects and their target devices"
	@echo "  make help                      Show this message"
	@echo ""
	@echo "After init, cd into the project and run: make help"
