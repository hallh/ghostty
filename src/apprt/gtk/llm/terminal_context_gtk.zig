const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.llm_terminal_context_gtk);

const Surface = @import("../Surface.zig");
const terminal_context = @import("../../../llm_assistant/terminal_context.zig");
const TerminalContext = terminal_context.TerminalContext;

/// Extract terminal context from the active GTK surface (thin adapter)
pub fn getTerminalContext(allocator: std.mem.Allocator, surface: ?*Surface) !?TerminalContext {
    if (surface == null) return null;

    // Convert GTK Surface to core Surface and delegate to cross-platform implementation
    return terminal_context.getTerminalContext(allocator, &surface.?.core_surface);
}
