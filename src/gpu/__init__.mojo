"""GPU-Accelerated JSON Parsing.

Phase 2 optimization for mojo-json targeting 2,000+ MB/s.

Architecture:
    ┌─────────────────────────────────────────────────────────────┐
    │  GPU Stage 1 (Massively Parallel)                           │
    │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                       │
    │  │Thread│ │Thread│ │Thread│ │Thread│  1000s of threads     │
    │  │  0   │ │  1   │ │  2   │ │  3   │  scanning chunks      │
    │  └──────┘ └──────┘ └──────┘ └──────┘                       │
    │           ↓ Structural positions                            │
    └─────────────────────────────────────────────────────────────┘
                         ↓
    ┌─────────────────────────────────────────────────────────────┐
    │  CPU Stage 2 (Sequential)                                   │
    │  Build tape using GPU-computed structural positions         │
    └─────────────────────────────────────────────────────────────┘

Expected Performance:
    | File Size | CPU SIMD  | GPU Hybrid | Speedup |
    |-----------|-----------|------------|---------|
    | 100 KB    | 620 MB/s  | 1,200 MB/s | 1.9x    |
    | 1 MB      | 620 MB/s  | 2,000 MB/s | 3.2x    |
    | 10 MB     | 620 MB/s  | 3,000 MB/s | 4.8x    |

Crossover Point: GPU faster for files > 50-100 KB
"""

from src.gpu.structural_scan import (
    gpu_structural_scan,
    StructuralScanResult,
    is_gpu_available,
    GPU_CROSSOVER_SIZE,
)

from src.gpu.adaptive import (
    parse_adaptive,
    parse_to_tape_adaptive,
)
