# Ghostty Architecture Guide

This document provides a comprehensive overview of Ghostty's architecture, dependencies, and development environment. It serves as a guide for developers contributing to the project.

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Key Dependencies](#key-dependencies)
- [Architecture Layers](#architecture-layers)
- [Component Communication](#component-communication)
- [Development Guidelines](#development-guidelines)
- [Documentation Sources](#documentation-sources)

## Overview

Ghostty is a fast, native, feature-rich terminal emulator written in Zig. The project follows a layered architecture design with clear separation of concerns between the UI layer, terminal emulation, input handling, PTY management, and rendering.

### Design Principles

1. **Cross-platform native UI**: Each platform uses native UI frameworks (SwiftUI on macOS, GTK on Linux)
2. **Performance-first**: Competitive with fastest terminal emulators
3. **Standards compliance**: Comprehensive xterm compatibility
4. **Embeddable**: `libghostty` C API for embedding in other applications
5. **Memory safety**: Leverages Zig's safety features with explicit memory management

## Project Structure

```
ghostty/
├── src/                    # Core Zig implementation
│   ├── App.zig            # Main application controller
│   ├── Surface.zig        # Terminal surface abstraction
│   ├── apprt/             # Application runtime layer
│   │   ├── embedded.zig   # C API embedding interface
│   │   ├── gtk/          # GTK3 implementation
│   │   └── gtk-ng/       # GTK4/libadwaita implementation
│   ├── config/           # Configuration system
│   ├── input/            # Input handling and key binding
│   ├── renderer/         # Multi-backend rendering (OpenGL/Metal)
│   ├── terminal/         # VT terminal emulation
│   ├── termio/           # PTY and process management
│   ├── font/             # Font handling and text shaping
│   └── ...
├── macos/                 # Swift/macOS native implementation
├── pkg/                   # C library dependencies
├── build.zig             # Zig build configuration
├── build.zig.zon         # Zig package dependencies
└── include/              # C API headers
```

## Key Dependencies

### Core Dependencies

| Dependency       | Purpose                   | Documentation Available           |
| ---------------- | ------------------------- | --------------------------------- |
| **libxev**       | Cross-platform event loop | ✅ [Context7](/mitchellh/libxev)  |
| **FreeType**     | Font rendering            | ✅ [Context7](/freetype/freetype) |
| **HarfBuzz**     | Text shaping              | ❌ (Use official docs)            |
| **zig-wayland**  | Wayland protocol bindings | ❌ (Use codeberg docs)            |
| **oniguruma**    | Regular expressions       | ❌ (Use official docs)            |
| **OpenGL/Metal** | Graphics rendering        | ❌ (Use official specs)           |

### Platform-Specific Dependencies

- **Linux**: GTK3/GTK4, libadwaita, fontconfig
- **macOS**: SwiftUI, Metal, CoreText
- **Build Tools**: Zig 0.14.0+, blueprint-compiler (Linux only)

### External Documentation

For dependencies not available in Context7, refer to:

- [libxev GitHub](https://github.com/mitchellh/libxev) - Event loop documentation
- [HarfBuzz Documentation](https://harfbuzz.github.io/) - Text shaping
- [FreeType Documentation](https://freetype.org/freetype2/docs/) - Font rendering
- [GTK Documentation](https://docs.gtk.org/) - Linux UI framework

## Architecture Layers

### 1. Application Runtime Layer (`src/apprt/`)

The apprt layer abstracts platform-specific windowing and event handling:

- **Purpose**: Provides unified interface across platforms
- **Key Files**:
  - `src/apprt/embedded.zig` - C API for external integration
  - `src/apprt/gtk/` - GTK3 implementation
  - `src/apprt/gtk-ng/` - GTK4/libadwaita implementation
- **Communication**: Uses message passing and mailboxes for thread safety

### 2. Configuration System (`src/config/`)

Hierarchical configuration with multiple sources:

- **Architecture**: Load order: defaults → XDG config → CLI args → recursive files
- **Key Features**:
  - Live reloading
  - Platform-specific defaults
  - Validation and error reporting
- **Entry Point**: `src/config/Config.zig`

### 3. Input Layer (`src/input/`)

Handles keyboard and mouse input with comprehensive layout support:

- **Key Encoding**: Supports legacy and Kitty keyboard protocols
- **Layout Support**: Dead keys, IME, international layouts
- **Binding System**: Configurable key bindings with action dispatch
- **Mouse Support**: Full mouse tracking with pressure sensitivity

### 4. Terminal Emulation (`src/terminal/`)

Standards-compliant VT terminal emulation:

- **Parser**: State machine based on vt100.net specification
- **Features**: Primary/alternate screens, scrollback, ANSI/escape sequences
- **Standards**: Comprehensive xterm compatibility
- **Performance**: Optimized for high-throughput text processing

### 5. PTY Layer (`src/termio/`)

Process and pseudoterminal management:

- **Architecture**: Dedicated IO thread with async operations
- **Cross-platform**: POSIX pty on Unix, ConPTY on Windows
- **Features**: Shell integration, environment management
- **Communication**: Uses libxev for async IO operations

### 6. Rendering Layer (`src/renderer/`)

Multi-backend graphics rendering:

- **Backends**: OpenGL (Linux), Metal (macOS)
- **Architecture**: Threaded rendering with frame synchronization
- **Features**: Ligature support, high DPI, animations
- **Performance**: 60fps+ under heavy load

### 7. Font System (`src/font/`)

Advanced font handling and text shaping:

- **Shaping**: HarfBuzz integration for complex scripts
- **Fallback**: Automatic font fallback chains
- **Caching**: Glyph atlas and shaping result caching
- **Features**: Ligatures, emoji, international text support

## Shortcuts and Keybindings

Ghostty's keybinding system (`src/input/Binding.zig`) maps input triggers to actions using the format: `trigger=action`.

### Implementation Architecture

**Trigger Format**: `+`-separated modifiers and keys (e.g., `ctrl+shift+c`, `super+t`)

**Modifiers**: `ctrl`, `shift`, `alt` (`opt`), `super` (`cmd`) - mapped to platform-specific keys

**Key Types**:

- Physical keys (layout-independent): `.physical = .arrow_left`
- Unicode codepoints (layout-dependent): `.unicode = 'c'`

### Configuration System

Default keybindings are initialized in `src/config/Config.zig`:

```zig
try self.set.put(alloc,
    .{ .key = .{ .unicode = 'c' }, .mods = mods },
    .{ .copy_to_clipboard = {} }
);
```

Platform-specific defaults use `builtin.target.os.tag.isDarwin()` checks.

### Advanced Features

**Key Sequences**: Multi-key bindings using `>` separator

```ini
keybind = ctrl+a>n=new_window  # Press Ctrl+A, then N
```

**Binding Flags**:

- `global`: System-wide shortcuts
- `performable`: Only trigger if action is available
- `all`: Forward to all active surfaces

### Developer Tools

```bash
# List all available actions for binding
ghostty +list-actions

# Show current keybinding configuration
ghostty +list-keybinds

# Command palette for runtime action discovery
# Triggered by toggle_command_palette action
```

### Platform Differences

- **macOS**: Uses `super` (Cmd) as primary modifier
- **Linux**: Uses `ctrl+shift` to avoid shell conflicts
- **Input Handling**: Platform-specific in `src/apprt/` layer, unified in `src/input/`

Key encoding supports both legacy terminal sequences and modern protocols (Kitty keyboard protocol) via `src/input/KeyEncoder.zig`.

## Component Communication

### Thread Architecture

Ghostty uses a multi-threaded architecture for performance:

```
Main Thread (UI)
├── Handles UI events and user interaction
├── Manages windows and surfaces
└── Communicates via mailboxes

Renderer Thread
├── Updates frame data from terminal state
├── Executes GPU rendering commands
└── Synchronizes with terminal updates

IO Thread (per terminal)
├── Manages PTY read/write operations
├── Processes terminal escape sequences
└── Updates terminal state with mutex protection
```

### Message Passing

Inter-thread communication uses mailboxes and blocking queues:

- **App Mailbox**: Core application message routing
- **Surface Mailbox**: Per-surface message handling
- **Renderer Mailbox**: GPU rendering coordination

Key message types:

- Window management (create, close, focus)
- Rendering requests and frame updates
- Configuration changes and reloading
- User actions and key bindings

### State Management

- **Terminal State**: Protected by mutexes, accessed by renderer and IO threads
- **Configuration**: Immutable after loading, reloaded on change
- **UI State**: Platform-specific, managed by apprt layer

## Development Guidelines

### Building from Source

Required additional dependencies for Git checkout:

- **Linux**: `blueprint-compiler` for GTK UI definitions
- **macOS**: Xcode 26+ with macOS 26 SDK for main branch

Build commands:

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run specific test
zig build test -Dtest-filter=<filter>
```

### Code Style

- **Zig Code**: Follow Zig community conventions
- **Documentation**: Use `prettier` for markdown/docs
- **Nix Files**: Format with `alejandra`

### Coverage Validation

⚠️  **MANDATORY FOR ALL AI CODING AGENTS** ⚠️

**Run `agents/check_coverage.sh` after every code change.** This validates formatting, runs tests with coverage, and identifies gaps in modified files.

#### Usage

```bash
agents/check_coverage.sh                    # Full validation
agents/check_coverage.sh --skip-tests       # Skip tests, analyze existing data
agents/check_coverage.sh --filter "config"  # Filter tests by pattern
```

#### AI Agent Requirements

1. **Always run** `agents/check_coverage.sh` after code changes
2. **Fix formatting** with `zig fmt .` if needed
3. **Address coverage gaps** by writing tests
4. **Re-run until all checks pass**

**Failure to run this script invalidates code changes.**

### Platform Testing

Use Nix VMs for testing across Linux desktop environments:

```bash
# Available VMs: gnome, plasma6, cinnamon, etc.
nix run .#<vmtype>
```

### Performance Testing

Critical areas requiring manual testing:

- Input stack (IME, dead keys, keyboard layouts)
- Rendering performance under load
- Memory usage during extended sessions

## Documentation Sources

### Official Documentation

- **Website**: [ghostty.org](https://ghostty.org/docs) - User documentation
- **Contributing**: `CONTRIBUTING.md` - Development process and guidelines
- **README**: `README.md` - Build instructions and project overview

### API Documentation

- **C API**: `include/ghostty.h` - Header for embedding libghostty
- **Zig Docs**: Generated via `zig build docs` (when available)

### External Resources

- **libxev**: [Context7 Documentation](/mitchellh/libxev) - Event loop usage
- **FreeType**: [Context7 Documentation](/freetype/freetype) - Font rendering
- **VT Standards**: [vt100.net](https://vt100.net/) - Terminal emulation reference
- **Xterm**: Source code reference for compatibility
- **Zig Standard Library**: Use `zig-docs` tool for browsing Zig std lib documentation

### Community

- **GitHub**: [Issues and Discussions](https://github.com/ghostty-org/ghostty)
- **Discord**: Community chat and support

---

This architecture guide should be updated as the project evolves. For the most current information, always refer to the source code and official documentation.
