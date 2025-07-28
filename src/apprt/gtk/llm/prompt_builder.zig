const std = @import("std");
const terminal_context = @import("terminal_context.zig");
const TerminalContext = terminal_context.TerminalContext;

/// Create an enhanced prompt that includes terminal context
pub fn createEnhancedPrompt(allocator: std.mem.Allocator, user_prompt: []const u8, context: TerminalContext) ![]u8 {
    var prompt_builder = std.ArrayList(u8).init(allocator);
    defer prompt_builder.deinit();

    // Use the new format that provides terminal context
    try prompt_builder.appendSlice("## The user is asking about how to perform certain steps or actions via their CLI.");

    // Add recent terminal content if available
    if (context.current_input_full_line) |terminal_content| {
        try prompt_builder.appendSlice("## The recent terminal activity is shown below (with line numbers for reference):\n\n");
        try prompt_builder.appendSlice("```\n");
        try prompt_builder.appendSlice(terminal_content);
        try prompt_builder.appendSlice("```\n");

        try prompt_builder.appendSlice("\n## The current state of the active line is the last line. Ignore any decorations that may be present. When returning the suggested CLI command, return only the part of the command that is missing and assume that it will replace the !!CURSOR!! marker.\n\n");
    } else {
        try prompt_builder.appendSlice("\n");
    }

    // Add the user's request
    try prompt_builder.appendSlice("## They wish to:\n\n");
    try prompt_builder.appendSlice(user_prompt);
    try prompt_builder.appendSlice("\n");

    return allocator.dupe(u8, prompt_builder.items);
}
