# FPGA Workspace

A structured Lattice Diamond FPGA development environment with automation for synthesis, place-and-route, simulation, and project export.

## Quick Start

### 0. Create or List Projects (from repo root)

List all projects in the workspace:

```bash
make list
```

Create a new project with boilerplate scaffolding:

```bash
make init PROJECT=my_design
```

This creates a complete project directory with all subdirectories and configuration files. See [Adding a New Project](#adding-a-new-project) for more details.

### 1. Initialize Your Environment

From the repository root, source the environment setup script **once per shell session**:

```bash
source _automation/env.sh
```

This configures paths to Diamond tools, Vivado, simulators, and other EDA tools.

### 2. Navigate to Your Project

```bash
cd counter    # or uart, or your project directory
```

Each project directory contains a `project.meta` file with hardware configuration (device, package, etc.) and source file lists.

### 3. Run a Build

```bash
make all      # Synthesize + place-and-route (headless, batch mode)
make syn      # Synthesis only
make par      # Place-and-route only
```

All tools run in silent mode by default. For live output, use `VERBOSE=1`:

```bash
make syn VERBOSE=1
```

## Project Structure

```
fpga-workspace/
├── _automation/           # Shared build automation (do not modify)
│   ├── common.mk          # Master Makefile with all build logic
│   ├── env.sh             # Environment setup script
│   ├── paths.cfg          # Local tool paths (not in git)
│   └── paths.cfg.example  # Template for paths.cfg

├── counter/               # Example project: counter module
│   ├── project.meta       # Hardware config (device, package, etc.)
│   ├── Makefile           # Project-level Makefile (delegates to common.mk)
│   ├── src/               # RTL sources
│   │   └── sources.f      # List of RTL source files
│   ├── tb/                # Testbenches
│   │   └── tb_files.f     # List of testbench files
│   ├── par/               # Place-and-route constraints
│   │   └── top.lpf        # Pin assignments
│   ├── syn/               # Synthesis artifacts (generated)
│   ├── par/               # P&R artifacts (generated)
│   ├── pgrm/              # Programming files: bitstreams, JEDEC (generated)
│   ├── sim/               # Simulation scripts and outputs (generated)
│   ├── prj/               # Diamond GUI projects (generated, .gitignored)
│   └── export/            # Project archives for distribution (generated, .gitignored)
└── uart/                  # Another example project (same structure)
```

## Working with Projects

### Project Configuration

Each project directory has a `project.meta` file defining the target hardware:

```
ARCH=MachXO3L
DEVICE=LCMXO3D-9400HC
PACKAGE=CABGA256
PERF_GRADE=5
OC=Commercial
TOP_MODULE=counter
```

Edit this file to target different Lattice devices.

### Source Files

RTL sources are listed in `src/sources.f`:

```
src/counter_top.v
src/counter_logic.v
```

Testbenches are listed in `tb/tb_files.f`:

```
tb/counter_tb.sv
```

Each file path is relative to the project root. Comments (`#`) and blank lines are ignored.

### Pin Assignments

Constraints go in `par/top.lpf`. Edit this file to assign pins to ports on your top module:

```
LOCATE COMP "clk" SITE "C8";
IOBUF PORT "clk" IO_TYPE=LVCMOS33;
```

## Build Targets

### Synthesis & Place-and-Route (Batch Mode)

| Target | Purpose |
|--------|---------|
| `make all` | Run synthesis → place-and-route (default) |
| `make syn` | Synthesis only (RTL → NGD netlist) |
| `make par` | Place-and-route only (requires prior synthesis) |

**Outputs:**
- `syn/out/<project>_impl1.ngd` — Synthesized netlist
- `par/out/<project>_impl1_par.ncd` — Placed and routed netlist

**Logs:**
- `syn/logs/` — Synthesis logs (timestamped)
- `par/logs/` — P&R logs (timestamped)

### Programming (Bitstream & JEDEC Generation)

| Target | Purpose |
|--------|---------|
| `make pgrm` | Generate bitstream (.bit) AND JEDEC files (.jed) |
| `make pgrm-bit` | Bitstream only |
| `make pgrm-jed` | JEDEC files only |

**Outputs:**
- `pgrm/<project>_impl1_par.bit` — Bitstream for programming
- `pgrm/<project>_impl1_par_a.jed` — JEDEC file
- `pgrm/<project>_impl1_par.fea` — Feature file

### Simulation

| Target | Purpose |
|--------|---------|
| `make sim` | Run simulation headless (Questa/ModelSim, console output) |
| `make sim-gui` | Run simulation in interactive Questa GUI |

**Outputs:**
- `sim/out/run.do` — Headless simulation script
- `sim/out/run_gui.do` — GUI simulation script
- `sim/logs/` — Simulation logs (timestamped)

The testbench module is auto-detected from the first TB file in `tb/tb_files.f`.

### Linting

| Target | Purpose |
|--------|---------|
| `make lint` | Run Verilator linting on RTL and TB sources |

Catches common Verilog issues without requiring synthesis.

### Diamond GUI (Interactive Project Flow)

| Target | Purpose |
|--------|---------|
| `make prj` | Launch Diamond GUI with generated project |
| `make prj-export` | Create self-contained project archive (ZIP) |

**`make prj`:**
- Generates a TCL script with RTL sources and constraints
- Launches Lattice Diamond GUI
- Useful for interactive synthesis, P&R tuning, debugging

**`make prj-export`:**
- Copies all RTL, TB, and constraints to an `export/` directory
- Marks testbenches as "simulation only" in the project
- Creates a distributable ZIP archive with everything needed to re-open the project
- Cleans up intermediate files; only the ZIP remains
- Use this to hand off a project to colleagues or archive a completed design

### Cleanup

| Target | Purpose |
|--------|---------|
| `make clean` | Remove all artifacts and logs |
| `make clean-syn` | Remove synthesis artifacts only |
| `make clean-par` | Remove P&R artifacts only |
| `make clean-pgrm` | Remove bitstream/JEDEC only |
| `make clean-sim` | Remove simulation artifacts only |
| `make clean-prj` | Remove Diamond GUI project artifacts |

## Typical Workflow

### Development

```bash
# Initialize environment
source _automation/env.sh

# Navigate to project
cd counter

# Run full build
make all

# Check results
ls -la syn/out/ par/out/

# View detailed logs if needed
tail -f syn/logs/syn_*.log
```

### Simulation

```bash
# Compile and run headless simulation
make sim

# Or, open interactive GUI
make sim-gui
```

### Static Analysis

```bash
# Lint RTL and TB
make lint
```

### Interactive Development (Diamond GUI)

```bash
# Launch Diamond GUI
make prj
```

### Export for Distribution

```bash
# Create self-contained archive
make prj-export

# Archive location: export/<project>_export.zip
# Share with colleagues or archive for later reference
```

## Output Locations

| Artifact | Location |
|----------|----------|
| Synthesized netlist | `syn/out/<project>_impl1.ngd` |
| Placed & routed netlist | `par/out/<project>_impl1_par.ncd` |
| Bitstream | `pgrm/<project>_impl1_par.bit` |
| JEDEC file | `pgrm/<project>_impl1_par_a.jed` |
| Feature file | `pgrm/<project>_impl1_par.fea` |
| Synthesis logs | `syn/logs/` |
| P&R logs | `par/logs/` |
| Simulation logs | `sim/logs/` |
| Export archive | `export/<project>_export.zip` |

## Configuring Tool Paths

Tool paths are defined in `_automation/paths.cfg` (not in git). To set up your system:

1. Copy the template:
   ```bash
   cp _automation/paths.cfg.example _automation/paths.cfg
   ```

2. Edit `paths.cfg` to point to your installed tools:
   ```
   DIAMOND_PATH=/path/to/lscc/diamond/3.14
   QUESTA_PATH=/path/to/questa/bin
   VERILATOR_PATH=/path/to/verilator/bin
   ```

3. Source the environment:
   ```bash
   source _automation/env.sh
   ```

## Adding a New Project

Run the `init` command from the repository root with your desired project name:

```bash
make init PROJECT=my_design
```

This scaffolds a complete project structure with boilerplate files. Optional parameters:

```bash
make init PROJECT=my_design \
  ARCH=MachXO3D \
  DEVICE=LCMXO3D-9400HC \
  PACKAGE=CABGA256 \
  PERF_GRADE=5 \
  OC=Commercial
```

**Default hardware:**
- Architecture: `MachXO3D`
- Device: `LCMXO3D-9400HC`
- Package: `CABGA256`
- Speed Grade: `5`
- Operating Condition: `Commercial`

After scaffolding, edit the generated files:

1. **`my_design/project.meta`** — Verify hardware configuration matches your target device
2. **`my_design/src/sources.f`** — Add your RTL source files (one per line, relative paths)
3. **`my_design/tb/tb_files.f`** — Add your testbench files (one per line, relative paths)
4. **`my_design/par/top.lpf`** — Add pin assignments for I/O ports

Then build:

```bash
cd my_design
source ../_automation/env.sh
make all
```

## Troubleshooting

### "Environment not initialized"

**Problem:** Error says `Environment not initialized. Run: source ../_automation/env.sh`

**Solution:** Source the environment script from the repository root:
```bash
source _automation/env.sh
```

Do this once per shell session.

### Synthesis fails

**Problem:** `make syn` fails with tool errors

**Steps:**
1. Check the log file (printed in the error message):
   ```bash
   tail -100 syn/logs/syn_*.log
   ```

2. Verify:
   - All RTL sources in `src/sources.f` exist and have correct paths
   - `project.meta` specifies a valid Lattice device
   - No Verilog syntax errors in source files

3. Retry with verbose output:
   ```bash
   make clean-syn
   make syn VERBOSE=1
   ```

### Place-and-route fails

**Problem:** `make par` fails

**Steps:**
1. Verify synthesis completed:
   ```bash
   ls -la syn/out/.syn_done
   ```

2. Check the log file:
   ```bash
   tail -100 par/logs/par_*.log
   ```

3. Verify `par/top.lpf` exists and has valid constraints.

### Simulation doesn't compile

**Problem:** `make sim` fails during compilation

**Steps:**
1. Check the log:
   ```bash
   tail -100 sim/logs/sim_*.log
   ```

2. Verify testbench module name in the first TB file matches the auto-detected name, or set it explicitly in the Makefile.

3. Check for syntax errors in TB files.

## Getting Help

- Check the [_automation/SPEC.md](_automation/SPEC.md) for detailed automation design documentation
- Review `make help` for a quick command reference:
  ```bash
  make help
  ```

- Inspect the generated scripts (e.g., `sim/out/run.do`) to understand what tools are being invoked

## License

[Add project license information here]

## Contact

[Add team contact information here]
