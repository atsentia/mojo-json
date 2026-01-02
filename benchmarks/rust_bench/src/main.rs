//! JSON Parser Benchmark: sonic-rs vs simd-json vs serde_json
//! Using SF citylots.json - famous GeoJSON benchmark

use std::fs;
use std::time::Instant;

fn benchmark<F>(iterations: usize, mut f: F) -> f64
where
    F: FnMut(),
{
    // Warmup
    for _ in 0..3 {
        f();
    }
    
    let start = Instant::now();
    for _ in 0..iterations {
        f();
    }
    let elapsed = start.elapsed();
    
    elapsed.as_micros() as f64 / iterations as f64
}

fn main() {
    println!("=================================================================");
    println!("Rust JSON Parsers - SF citylots.json Benchmark");
    println!("=================================================================");
    println!();
    
    let files = vec![
        ("citylots_10mb.json", "../data/citylots_10mb.json", 20),
        ("citylots_25mb.json", "../data/citylots_25mb.json", 10),
        ("citylots_50mb.json", "../data/citylots_50mb.json", 5),
        ("citylots_100mb.json", "../data/citylots_100mb.json", 3),
        ("citylots.json (full)", "../data/citylots.json", 2),
    ];
    
    for (name, path, iterations) in files {
        let data = match fs::read_to_string(path) {
            Ok(d) => d,
            Err(e) => {
                println!("Could not read {}: {}", path, e);
                continue;
            }
        };
        let size_mb = data.len() as f64 / (1024.0 * 1024.0);
        
        println!("File: {} ({:.1} MB, {} iterations)", name, size_mb, iterations);
        println!("-----------------------------------------------------------------");
        
        // serde_json
        let serde_time = benchmark(iterations, || {
            let _: serde_json::Value = serde_json::from_str(&data).unwrap();
        });
        let serde_mbps = size_mb / (serde_time / 1_000_000.0);
        println!("  serde_json:  {:10.1} ms  ({:7.1} MB/s)", serde_time / 1000.0, serde_mbps);
        
        // simd-json
        let simd_time = benchmark(iterations, || {
            let mut data_copy = data.clone().into_bytes();
            let _: simd_json::BorrowedValue = simd_json::to_borrowed_value(&mut data_copy).unwrap();
        });
        let simd_mbps = size_mb / (simd_time / 1_000_000.0);
        println!("  simd-json:   {:10.1} ms  ({:7.1} MB/s)", simd_time / 1000.0, simd_mbps);
        
        // sonic-rs
        let sonic_time = benchmark(iterations, || {
            let _: sonic_rs::Value = sonic_rs::from_str(&data).unwrap();
        });
        let sonic_mbps = size_mb / (sonic_time / 1_000_000.0);
        println!("  sonic-rs:    {:10.1} ms  ({:7.1} MB/s)", sonic_time / 1000.0, sonic_mbps);
        
        println!();
    }
}
