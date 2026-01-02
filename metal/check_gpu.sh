#!/bin/bash
# Check GPU availability and info

echo "GPU Information:"
system_profiler SPDisplaysDataType 2>/dev/null | grep -A2 "Chipset Model:" | head -5

echo ""
echo "Metal Support:"
if xcrun -sdk macosx metal --version 2>/dev/null; then
    echo "  Metal compiler: Available"
else
    echo "  Metal compiler: Not found"
fi
