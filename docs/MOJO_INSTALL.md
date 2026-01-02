# Installing Mojo

This document describes how to install Mojo for developing mojo-contrib libraries.

## Quick Install (pip)

The simplest method is using pip:

```bash
pip3 install mojo
```

This installs:
- `mojo` - Mojo compiler (currently v0.25.7.0)
- `mojo-compiler` - Compiler binaries
- `mblack` - Mojo code formatter
- `mojo-lldb-libs` - Debugger libraries

## Verify Installation

```bash
mojo --version
# Mojo 0.25.7.0 (e5af2b2f)
```

## Running Mojo Code

```bash
# Run a .mojo file directly
mojo run myfile.mojo

# Compile to executable
mojo build myfile.mojo -o myprogram

# Start REPL
mojo
```

## System Requirements

- **macOS**: Apple Silicon (M1/M2/M3/M4), macOS 13+
- **Linux**: x86_64 or aarch64, glibc 2.31+
- **Windows**: Not supported

## GPU Support (Apple Silicon)

For GPU programming on Apple Silicon:

```bash
# Download Metal toolchain (required for GPU)
xcodebuild -downloadComponent MetalToolchain
```

Requires:
- macOS 15+ (Sequoia)
- Xcode 16+

## Alternative: Using Pixi

For project-based installation with dependency management:

```bash
# Install pixi
curl -fsSL https://pixi.sh/install.sh | bash

# Create a Mojo project
pixi init my-project \
  -c https://conda.modular.com/max-nightly/ -c conda-forge

cd my-project
pixi add mojo
```

## VS Code Extension

Install the Mojo extension from the VS Code marketplace:
- Search for "Mojo" by Modular
- Provides syntax highlighting, LSP, diagnostics, code completion

## Troubleshooting

### "command not found: mojo"

Check if the pip bin directory is in PATH:
```bash
# Find where pip installs binaries
python3 -c "import sysconfig; print(sysconfig.get_path('scripts'))"

# Add to PATH if needed (add to ~/.zshrc or ~/.bashrc)
export PATH="$PATH:/path/to/scripts"
```

### Import errors in .mojo files

Make sure to use relative imports within packages:
```mojo
# Correct (from within package)
from .parser import parse

# Incorrect (absolute path may not work)
from mypackage.parser import parse
```

## References

- [Official Install Docs](https://docs.modular.com/mojo/manual/install/)
- [Mojo on PyPI](https://pypi.org/project/mojo/)
- [Getting Started Guide](https://docs.modular.com/mojo/manual/get-started/)
