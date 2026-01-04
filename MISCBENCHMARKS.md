Parser,Language,Architecture / Approach,Hardware (approx.),Dataset Focus,Throughput (GB/s)
simdjson (On-Demand),C++,"SIMD (AVX-512/NEON), Lazy",Intel Xeon / Core i9 (AVX-512),Large Struct (twitter.json),~6.0 - 7.5
simdjson (DOM),C++,"SIMD (AVX-512/NEON), Tree",Apple M2/M3 (ARM64),"Mixed (citm, twitter)",~3.0 - 4.5
yyjson,C,"Optimized C, portable (no SIMD req)",Modern AMD Ryzen / Apple Silicon,"Mixed (citm, canada)",~3.5 - 5.0
sonic-rs,Rust,SIMD-accelerated (uses raw pointers),Intel/AMD (AVX2),Large Arrays,~3.0 - 4.5
GpJSON *,CUDA/C++,GPU Parallelism (Index Construction),NVIDIA A100 / H100,Massive logs/NDJSON,~15.0 - 25.0+
orjson,Python (Rust),Python Bindings (backend is Rust),Standard Cloud (AWS c7g),Web payloads,~1.2 - 1.5 **
RapidJSON,C++,Traditional SAX/DOM,Standard x64,Mixed,~0.5 - 1.0 (Baseline)

Note on GpJSON: Represents emerging 2025 research (e.g., VLDB '25) utilizing GPU massively parallel processing. While throughput is massive, latency (data transfer to GPU) makes it viable only for batch processing of huge files (GBs/TBs). ** Note on orjson: While slower in raw throughput than C++ counterparts, it is currently the SOTA for Python environments, significantly outperforming the standard json library.
Key Performance Drivers in 2025

1. The "On-Demand" Shift

The biggest leap in performance (seen in simdjson vs. traditional parsers) comes from On-Demand parsing.

How it works: Instead of parsing the entire JSON string into a DOM tree (which requires massive memory allocation), the parser iterates over the raw string and only parses the specific fields you request while you request them.

Result: This frequently doubles performance compared to DOM parsing because it skips constructing unused objects.

2. Hardware & Instruction Sets

Apple Silicon (ARM64): The wide adoption of M3/M4 chips has pushed parsers like yyjson and simdjson to optimize specifically for NEON instructions. simdjson implementation on ARM64 is now nearly competitive with AVX-512 due to the high clock speeds and efficient pipeline of Apple chips.

AVX-512: Remains the king for raw throughput on Intel hardware. If your server supports AVX-512, simdjson uses specific kernels that process 64 bytes of JSON per CPU instruction.

3. Benchmark Datasets

SOTA benchmarks typically rely on these standard files to ensure fairness:

twitter.json (600KB): The "Gold Standard." Represents typical web API payloads with a mix of text, numbers, and moderate nesting.

canada.json (2MB): A GeoJSON file. Heavily tests floating-point number parsing (lat/long coordinates). Parsers with poor float parsing optimization fail here.

citm_catalog.json (1.7MB): deeply nested structure with many keys; tests the parser's ability to handle structural overhead.

Recommendations

For C++ / Systems: Use simdjson (On-Demand API) if you know your schema and want maximum speed. Use yyjson if you need an easy-to-use C API that is extremely fast and robust without strict hardware requirements.

For Rust: Use sonic-rs for pure speed (if unsafe code is acceptable) or serde-json with jemalloc for standard safety/compatibility.

For Python Data Science: Always use orjson.

For Big Data / Logs: Look into GPU-accelerated parsers like GpJSON or cuDF (RAPIDS) if you are processing terabytes of JSON logs.

Would you like me to generate a C++ or Python code snippet demonstrating how to implement the "On-Demand" pattern for one of these parsers?
