const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.llm_terminal_context_embedded);

const EmbeddedSurface = @import("../../embedded.zig").Surface;
const terminal_context = @import("../../../llm_assistant/terminal_context.zig");
const TerminalContext = terminal_context.TerminalContext;

/// Extract terminal context from the active embedded surface (thin adapter for macOS/libghostty)
pub fn getTerminalContext(allocator: std.mem.Allocator, surface: ?*EmbeddedSurface) !?TerminalContext {
    if (surface == null) return null;

    // Convert embedded Surface to core Surface and delegate to cross-platform implementation
    return terminal_context.getTerminalContext(allocator, &surface.?.core_surface);
}
