#!/usr/bin/env python3
"""Generate JSON test data for benchmarks.

Creates various JSON files to test different parsing scenarios:
- Small objects (API responses)
- Large arrays (data tables)
- Nested structures (config files)
- String-heavy (text content)
- Number-heavy (sensor data)
- Mixed realistic (typical payloads)

Sizes: 1KB, 10KB, 100KB, 1MB, 10MB
"""

import json
import random
import string
import os
from pathlib import Path

DATA_DIR = Path(__file__).parent / "data"


def random_string(length: int) -> str:
    """Generate a random ASCII string."""
    return ''.join(random.choices(string.ascii_letters + string.digits + ' ', k=length))


def random_unicode_string(length: int) -> str:
    """Generate a string with some unicode characters."""
    chars = string.ascii_letters + string.digits + ' ' + 'éàüöñ日本語中文'
    return ''.join(random.choices(chars, k=length))


def generate_small_object() -> dict:
    """Generate a small API-response-like object."""
    return {
        "id": random.randint(1, 1000000),
        "name": random_string(20),
        "email": f"{random_string(8)}@example.com",
        "active": random.choice([True, False]),
        "score": round(random.uniform(0, 100), 2),
        "tags": [random_string(5) for _ in range(3)],
        "metadata": {
            "created": "2024-01-15T10:30:00Z",
            "updated": "2024-12-25T15:45:00Z",
            "version": random.randint(1, 10)
        }
    }


def generate_nested_config(depth: int = 5) -> dict:
    """Generate a deeply nested configuration object."""
    if depth <= 0:
        return {"value": random.randint(1, 100)}

    return {
        "name": random_string(10),
        "enabled": random.choice([True, False]),
        "settings": {
            "option1": random.randint(1, 100),
            "option2": random_string(15),
            "nested": generate_nested_config(depth - 1)
        },
        "items": [generate_nested_config(depth - 2) for _ in range(2)] if depth > 2 else []
    }


def generate_number_array(count: int) -> list:
    """Generate array of numbers (sensor data style)."""
    return [
        {
            "timestamp": 1704067200 + i,
            "values": [round(random.uniform(-100, 100), 4) for _ in range(5)],
            "flags": random.randint(0, 255)
        }
        for i in range(count)
    ]


def generate_string_heavy(count: int) -> list:
    """Generate array of string-heavy objects."""
    return [
        {
            "id": str(random.randint(100000, 999999)),
            "title": random_string(50),
            "description": random_string(200),
            "content": random_string(500),
            "author": random_string(30),
            "tags": [random_string(10) for _ in range(5)]
        }
        for i in range(count)
    ]


def generate_mixed_realistic(count: int) -> dict:
    """Generate realistic mixed payload (like API response with pagination)."""
    return {
        "status": "success",
        "code": 200,
        "message": "Data retrieved successfully",
        "pagination": {
            "page": 1,
            "per_page": count,
            "total": count * 10,
            "total_pages": 10
        },
        "data": [generate_small_object() for _ in range(count)],
        "meta": {
            "request_id": random_string(32),
            "timestamp": "2024-12-25T12:00:00Z",
            "processing_time_ms": random.randint(10, 500)
        }
    }


def generate_twitter_like() -> dict:
    """Generate Twitter-like timeline data (common benchmark)."""
    return {
        "statuses": [
            {
                "id": random.randint(10**17, 10**18),
                "id_str": str(random.randint(10**17, 10**18)),
                "text": random_string(280),
                "truncated": False,
                "user": {
                    "id": random.randint(10**7, 10**8),
                    "name": random_string(20),
                    "screen_name": random_string(15),
                    "followers_count": random.randint(0, 1000000),
                    "verified": random.choice([True, False])
                },
                "retweet_count": random.randint(0, 10000),
                "favorite_count": random.randint(0, 50000),
                "created_at": "Mon Dec 25 12:00:00 +0000 2024"
            }
            for _ in range(100)
        ]
    }


def adjust_to_size(data: any, target_bytes: int, generator_func) -> any:
    """Adjust data to approximately target size by adding/removing elements."""
    current_size = len(json.dumps(data))

    if isinstance(data, dict) and "data" in data:
        # For paginated responses, adjust the data array
        while current_size < target_bytes * 0.9:
            data["data"].append(generator_func())
            current_size = len(json.dumps(data))
        while current_size > target_bytes * 1.1 and len(data["data"]) > 1:
            data["data"].pop()
            current_size = len(json.dumps(data))
    elif isinstance(data, list):
        while current_size < target_bytes * 0.9:
            data.append(generator_func())
            current_size = len(json.dumps(data))
        while current_size > target_bytes * 1.1 and len(data) > 1:
            data.pop()
            current_size = len(json.dumps(data))

    return data


def save_json(data: any, filename: str, pretty: bool = False):
    """Save JSON to file."""
    filepath = DATA_DIR / filename
    with open(filepath, 'w') as f:
        if pretty:
            json.dump(data, f, indent=2)
        else:
            json.dump(data, f, separators=(',', ':'))

    size = filepath.stat().st_size
    print(f"  {filename}: {size:,} bytes ({size/1024:.1f} KB)")


def main():
    """Generate all test data files."""
    DATA_DIR.mkdir(exist_ok=True)
    random.seed(42)  # Reproducible benchmarks

    sizes = {
        "1kb": 1024,
        "10kb": 10 * 1024,
        "100kb": 100 * 1024,
        "1mb": 1024 * 1024,
        "10mb": 10 * 1024 * 1024,
    }

    print("Generating JSON test data...\n")

    # 1. Small objects (API responses) - various sizes
    print("1. API Response Style (mixed objects):")
    for name, target_size in sizes.items():
        count = max(1, target_size // 250)  # ~250 bytes per object
        data = generate_mixed_realistic(count)
        data = adjust_to_size(data, target_size, generate_small_object)
        save_json(data, f"api_response_{name}.json")

    # 2. Number-heavy (sensor data)
    print("\n2. Number Heavy (sensor data):")
    for name, target_size in sizes.items():
        count = max(1, target_size // 100)
        data = generate_number_array(count)
        data = adjust_to_size(data, target_size, lambda: generate_number_array(1)[0])
        save_json(data, f"numbers_{name}.json")

    # 3. String-heavy (text content)
    print("\n3. String Heavy (text content):")
    for name, target_size in sizes.items():
        count = max(1, target_size // 1000)
        data = generate_string_heavy(count)
        data = adjust_to_size(data, target_size, lambda: generate_string_heavy(1)[0])
        save_json(data, f"strings_{name}.json")

    # 4. Deeply nested (config files)
    print("\n4. Deeply Nested (config style):")
    for name, target_size in list(sizes.items())[:4]:  # Skip 10MB for nested
        depth = min(10, max(3, target_size // 10000))
        data = generate_nested_config(depth)
        save_json(data, f"nested_{name}.json")

    # 5. Twitter-like (common benchmark)
    print("\n5. Twitter-like (realistic social media):")
    data = generate_twitter_like()
    save_json(data, "twitter_100.json")

    # 6. Pretty-printed versions (tests whitespace handling)
    print("\n6. Pretty-printed (whitespace handling):")
    data = generate_mixed_realistic(100)
    save_json(data, "pretty_100kb.json", pretty=True)

    # 7. Edge cases
    print("\n7. Edge Cases:")

    # Unicode heavy
    unicode_data = [{"text": random_unicode_string(100)} for _ in range(100)]
    save_json(unicode_data, "unicode_heavy.json")

    # Escape sequences
    escape_data = [
        {"text": 'Hello\nWorld\t"quoted"\r\nEnd\\slash'},
        {"path": "C:\\Users\\test\\file.json"},
        {"html": "<script>alert('xss')</script>"},
    ] * 100
    save_json(escape_data, "escape_heavy.json")

    # Deep array nesting
    deep_array = [[[[[[1, 2, 3]]]]]] * 100
    save_json(deep_array, "deep_arrays.json")

    # Many small keys
    many_keys = {f"key_{i}": i for i in range(1000)}
    save_json(many_keys, "many_keys.json")

    # Large integers
    large_ints = [{"big": 9007199254740992 + i, "small": i} for i in range(1000)]
    save_json(large_ints, "large_integers.json")

    # Floats with many decimals
    precise_floats = [{"value": 3.141592653589793 * i} for i in range(1, 1001)]
    save_json(precise_floats, "precise_floats.json")

    print("\n" + "="*50)
    print("Test data generation complete!")
    print(f"Files saved to: {DATA_DIR}")

    # Print summary
    total_size = sum(f.stat().st_size for f in DATA_DIR.glob("*.json"))
    file_count = len(list(DATA_DIR.glob("*.json")))
    print(f"Total: {file_count} files, {total_size/1024/1024:.1f} MB")


if __name__ == "__main__":
    main()
