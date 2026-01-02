/**
 * simdjson Benchmark
 *
 * Benchmarks simdjson parsing performance against test data.
 *
 * Build:
 *   cd benchmarks/competitors/simdjson
 *   mkdir build && cd build
 *   cmake .. -DCMAKE_BUILD_TYPE=Release
 *   make
 *   cd ../../../..
 *   clang++ -O3 -std=c++17 -I competitors/simdjson/singleheader \
 *           bench_simdjson.cpp -o bench_simdjson
 *
 * Or with single-header:
 *   clang++ -O3 -std=c++17 bench_simdjson.cpp -o bench_simdjson
 */

// Use single-header simdjson if available
#if __has_include("competitors/simdjson/singleheader/simdjson.h")
    #include "competitors/simdjson/singleheader/simdjson.h"
#elif __has_include("simdjson.h")
    #include "simdjson.h"
#else
    #error "simdjson.h not found. Clone simdjson to competitors/simdjson/"
#endif

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

const int WARMUP_ITERATIONS = 3;
const int BENCH_ITERATIONS = 10;

struct BenchResult {
    std::string file;
    size_t file_size;
    double parse_time_ms;
    double throughput_mb_s;
};

std::string read_file(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    std::ostringstream ss;
    ss << file.rdbuf();
    return ss.str();
}

double benchmark_parse(simdjson::ondemand::parser& parser,
                       simdjson::padded_string& json_content,
                       int iterations) {
    double total_time = 0;

    for (int i = 0; i < iterations; i++) {
        auto start = std::chrono::high_resolution_clock::now();

        // Parse with on-demand API
        auto doc = parser.iterate(json_content);

        // Force parsing by accessing root element
        // (simdjson is lazy, so we need to trigger actual parsing)
        simdjson::ondemand::json_type type = doc.type();
        (void)type;

        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
        total_time += duration.count() / 1000.0;  // Convert to ms
    }

    return total_time / iterations;
}

double benchmark_parse_dom(simdjson::dom::parser& parser,
                           const std::string& json_content,
                           int iterations) {
    double total_time = 0;

    for (int i = 0; i < iterations; i++) {
        auto start = std::chrono::high_resolution_clock::now();

        // Parse with DOM API (full parse)
        auto doc = parser.parse(json_content);

        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
        total_time += duration.count() / 1000.0;
    }

    return total_time / iterations;
}

int main(int argc, char* argv[]) {
    fs::path data_dir = "data";

    // Allow custom data directory
    if (argc > 1) {
        data_dir = argv[1];
    }

    if (!fs::exists(data_dir)) {
        std::cerr << "Error: Data directory not found: " << data_dir << std::endl;
        std::cerr << "Run: python generate_test_data.py" << std::endl;
        return 1;
    }

    // Print header
    std::cout << "simdjson Benchmark" << std::endl;
    std::cout << std::string(60, '=') << std::endl;
    std::cout << "Implementation: " << simdjson::get_active_implementation()->name() << std::endl;
    std::cout << "Description: " << simdjson::get_active_implementation()->description() << std::endl;
    std::cout << "Iterations: " << BENCH_ITERATIONS << " (warmup: " << WARMUP_ITERATIONS << ")" << std::endl;
    std::cout << std::endl;

    std::cout << std::string(80, '=') << std::endl;
    std::cout << std::left << std::setw(30) << "File"
              << std::right << std::setw(12) << "Size"
              << std::setw(10) << "API"
              << std::setw(12) << "Parse (ms)"
              << std::setw(12) << "MB/s" << std::endl;
    std::cout << std::string(80, '=') << std::endl;

    std::vector<BenchResult> results;

    // Create parsers
    simdjson::ondemand::parser ondemand_parser;
    simdjson::dom::parser dom_parser;

    // Iterate through JSON files
    for (const auto& entry : fs::directory_iterator(data_dir)) {
        if (entry.path().extension() != ".json") continue;

        std::string filename = entry.path().filename().string();
        size_t file_size = entry.file_size();

        // Skip files > 20MB
        if (file_size > 20 * 1024 * 1024) {
            std::cout << std::left << std::setw(30) << filename
                      << "  SKIPPED (too large)" << std::endl;
            continue;
        }

        // Read file
        std::string content = read_file(entry.path());
        simdjson::padded_string padded_content(content);

        // Warmup
        for (int i = 0; i < WARMUP_ITERATIONS; i++) {
            auto doc = ondemand_parser.iterate(padded_content);
            (void)doc.type();
        }

        // Benchmark On-Demand API
        double ondemand_time = benchmark_parse(ondemand_parser, padded_content, BENCH_ITERATIONS);
        double ondemand_throughput = (file_size / 1024.0 / 1024.0) / (ondemand_time / 1000.0);

        std::string size_str;
        if (file_size < 1024 * 1024) {
            size_str = std::to_string(file_size / 1024) + " KB";
        } else {
            size_str = std::to_string(file_size / 1024 / 1024) + " MB";
        }

        std::cout << std::left << std::setw(30) << filename
                  << std::right << std::setw(12) << size_str
                  << std::setw(10) << "ondemand"
                  << std::setw(12) << std::fixed << std::setprecision(3) << ondemand_time
                  << std::setw(12) << std::fixed << std::setprecision(1) << ondemand_throughput
                  << std::endl;

        // Benchmark DOM API (full parse)
        double dom_time = benchmark_parse_dom(dom_parser, content, BENCH_ITERATIONS);
        double dom_throughput = (file_size / 1024.0 / 1024.0) / (dom_time / 1000.0);

        std::cout << std::left << std::setw(30) << ""
                  << std::right << std::setw(12) << ""
                  << std::setw(10) << "dom"
                  << std::setw(12) << std::fixed << std::setprecision(3) << dom_time
                  << std::setw(12) << std::fixed << std::setprecision(1) << dom_throughput
                  << std::endl;

        results.push_back({filename, file_size, dom_time, dom_throughput});

        std::cout << std::string(80, '-') << std::endl;
    }

    // Summary
    std::cout << std::endl;
    std::cout << std::string(60, '=') << std::endl;
    std::cout << "SUMMARY: Average Parse Throughput (DOM API)" << std::endl;
    std::cout << std::string(60, '=') << std::endl;

    double total_throughput = 0;
    for (const auto& r : results) {
        total_throughput += r.throughput_mb_s;
    }
    double avg_throughput = total_throughput / results.size();

    std::cout << "  simdjson: " << std::fixed << std::setprecision(1)
              << avg_throughput << " MB/s average" << std::endl;

    // Save results to CSV
    fs::create_directories("results");
    std::ofstream csv("results/simdjson_benchmarks.csv");
    csv << "file,file_size,parse_time_ms,throughput_mb_s" << std::endl;
    for (const auto& r : results) {
        csv << r.file << "," << r.file_size << ","
            << std::fixed << std::setprecision(3) << r.parse_time_ms << ","
            << std::fixed << std::setprecision(1) << r.throughput_mb_s << std::endl;
    }
    std::cout << std::endl << "Results saved to: results/simdjson_benchmarks.csv" << std::endl;

    return 0;
}
