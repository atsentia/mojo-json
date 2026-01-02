#!/bin/bash
# Run all JSON parser benchmarks
#
# Prerequisites:
#   - Python 3.8+ with pip
#   - Mojo (pip install mojo --extra-index-url https://modular.gateway.scarf.sh/simple/)
#   - C++ compiler (clang++ or g++)
#
# Usage:
#   ./run_all.sh           # Run all benchmarks
#   ./run_all.sh python    # Run only Python benchmarks
#   ./run_all.sh simdjson  # Run only simdjson benchmarks
#   ./run_all.sh mojo      # Run only Mojo benchmarks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}   JSON Parser Benchmark Suite${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Check for test data
if [ ! -d "data" ] || [ -z "$(ls -A data/*.json 2>/dev/null)" ]; then
    echo -e "${YELLOW}Generating test data...${NC}"
    python3 generate_test_data.py
    echo ""
fi

# Create results directory
mkdir -p results

# Determine which benchmarks to run
RUN_ALL=true
RUN_PYTHON=false
RUN_SIMDJSON=false
RUN_MOJO=false

if [ -n "$1" ]; then
    RUN_ALL=false
    case "$1" in
        python)   RUN_PYTHON=true ;;
        simdjson) RUN_SIMDJSON=true ;;
        mojo)     RUN_MOJO=true ;;
        *)        echo "Unknown option: $1"; exit 1 ;;
    esac
fi

# ============================================
# Python Benchmarks (json, orjson, ujson)
# ============================================
if [ "$RUN_ALL" = true ] || [ "$RUN_PYTHON" = true ]; then
    echo -e "${GREEN}[1/3] Python Benchmarks${NC}"
    echo "----------------------------------------"

    # Install dependencies if needed
    if ! python3 -c "import orjson" 2>/dev/null; then
        echo -e "${YELLOW}Installing orjson...${NC}"
        pip3 install orjson ujson --quiet
    fi

    python3 bench_python.py
    echo ""
fi

# ============================================
# simdjson (C++) Benchmark
# ============================================
if [ "$RUN_ALL" = true ] || [ "$RUN_SIMDJSON" = true ]; then
    echo -e "${GREEN}[2/3] simdjson (C++) Benchmark${NC}"
    echo "----------------------------------------"

    # Check if simdjson is cloned
    if [ ! -d "competitors/simdjson" ]; then
        echo -e "${YELLOW}Cloning simdjson...${NC}"
        mkdir -p competitors
        git clone --depth 1 https://github.com/simdjson/simdjson.git competitors/simdjson
    fi

    # Build the benchmark
    if [ ! -f "bench_simdjson" ] || [ "bench_simdjson.cpp" -nt "bench_simdjson" ]; then
        echo -e "${YELLOW}Building simdjson benchmark...${NC}"

        # Find simdjson single header
        SIMDJSON_HEADER="competitors/simdjson/singleheader/simdjson.h"
        if [ ! -f "$SIMDJSON_HEADER" ]; then
            echo -e "${RED}Error: simdjson.h not found at $SIMDJSON_HEADER${NC}"
            echo "Please ensure simdjson is properly cloned"
            exit 1
        fi

        # Compile with single-header
        clang++ -O3 -std=c++17 \
            -I competitors/simdjson/singleheader \
            competitors/simdjson/singleheader/simdjson.cpp \
            bench_simdjson.cpp \
            -o bench_simdjson

        echo "Build complete."
    fi

    ./bench_simdjson
    echo ""
fi

# ============================================
# Mojo JSON Benchmark
# ============================================
if [ "$RUN_ALL" = true ] || [ "$RUN_MOJO" = true ]; then
    echo -e "${GREEN}[3/3] Mojo JSON Benchmark${NC}"
    echo "----------------------------------------"

    # Check if mojo is available
    if ! command -v mojo &> /dev/null; then
        echo -e "${YELLOW}Warning: Mojo not found in PATH${NC}"
        echo "Install: pip install mojo --extra-index-url https://modular.gateway.scarf.sh/simple/"
        echo "Skipping Mojo benchmarks."
    else
        mojo bench_mojo.mojo
    fi
    echo ""
fi

# ============================================
# Summary Comparison
# ============================================
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}   Benchmark Summary${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Compare results if all benchmarks ran
if [ -f "results/python_benchmarks.csv" ] && [ -f "results/simdjson_benchmarks.csv" ]; then
    echo "Results saved to: $SCRIPT_DIR/results/"
    echo ""

    # Quick summary using Python
    python3 - << 'PYSCRIPT'
import csv
from pathlib import Path
from collections import defaultdict

results_dir = Path("results")

def read_csv(filename):
    """Read CSV and return dict of file -> throughput."""
    data = {}
    filepath = results_dir / filename
    if not filepath.exists():
        return data
    with open(filepath) as f:
        reader = csv.DictReader(f)
        for row in reader:
            file = row.get('file', '')
            throughput = float(row.get('throughput_mb_s', 0))
            data[file] = throughput
    return data

# Read all results
python_json = {}
python_orjson = {}
simdjson = read_csv("simdjson_benchmarks.csv")
mojo_json = read_csv("mojo_benchmarks.csv")

# Read Python results (grouped by library)
python_file = results_dir / "python_benchmarks.csv"
if python_file.exists():
    with open(python_file) as f:
        reader = csv.DictReader(f)
        for row in reader:
            lib = row.get('library', '')
            file = row.get('file', '')
            throughput = float(row.get('throughput_mb_s', 0))
            if lib == 'json':
                python_json[file] = throughput
            elif lib == 'orjson':
                python_orjson[file] = throughput

# Calculate averages
def avg(d):
    if not d:
        return 0
    return sum(d.values()) / len(d)

print("Average Parse Throughput (MB/s):")
print("-" * 40)
print(f"  simdjson (C++):      {avg(simdjson):>8.1f} MB/s")
print(f"  orjson (Rust/Py):    {avg(python_orjson):>8.1f} MB/s")
print(f"  mojo-json (Mojo):    {avg(mojo_json):>8.1f} MB/s")
print(f"  json (Python):       {avg(python_json):>8.1f} MB/s")

# Speedups
if avg(python_json) > 0:
    print("")
    print("Speedup vs Python stdlib json:")
    print("-" * 40)
    baseline = avg(python_json)
    if avg(simdjson) > 0:
        print(f"  simdjson:  {avg(simdjson)/baseline:>6.1f}x")
    if avg(python_orjson) > 0:
        print(f"  orjson:    {avg(python_orjson)/baseline:>6.1f}x")
    if avg(mojo_json) > 0:
        print(f"  mojo-json: {avg(mojo_json)/baseline:>6.1f}x")
PYSCRIPT
fi

echo ""
echo -e "${GREEN}Benchmarks complete!${NC}"
