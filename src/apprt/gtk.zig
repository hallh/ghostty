//! Application runtime that uses GTK4.

pub const App = @import("gtk/App.zig");
pub const Surface = @import("gtk/Surface.zig");
pub const resourcesDir = @import("gtk/flatpak.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("gtk/inspector.zig");
    _ = @import("gtk/key.zig");

    // Import LLM assistant modules to ensure test discovery
    _ = @import("gtk/LLMAssistantDialog.zig");
    _ = @import("gtk/llm/history.zig");
    _ = @import("gtk/llm/prompt_builder.zig");
    _ = @import("gtk/llm/terminal_context.zig");
    _ = @import("gtk/llm/worker.zig");
}
