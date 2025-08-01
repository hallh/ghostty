const std = @import("std");
const gtk = @import("gtk");

const history_core = @import("../../../llm_assistant/history.zig");
const History = history_core.History;
const Direction = history_core.Direction;

/// GTK-specific wrapper for the cross-platform History implementation
pub const HistoryGTK = struct {
    core: History,

    pub fn init(allocator: std.mem.Allocator) HistoryGTK {
        return HistoryGTK{
            .core = History.init(allocator),
        };
    }

    pub fn deinit(self: *HistoryGTK) void {
        self.core.deinit();
    }

    /// Add a text entry to history
    pub fn addEntry(self: *HistoryGTK, text: []const u8) !void {
        try self.core.addEntry(text);
    }

    /// Navigate through history and update the provided entry widget
    pub fn navigate(self: *HistoryGTK, direction: Direction, entry: *gtk.Entry) void {
        const text = self.core.navigate(direction);
        self.updateEntryText(entry, text);
    }

    /// Clear navigation and reset entry to empty
    pub fn clearNavigation(self: *HistoryGTK, entry: *gtk.Entry) void {
        self.core.clearNavigation();
        self.updateEntryText(entry, null);
    }

    fn updateEntryText(self: *HistoryGTK, entry: *gtk.Entry, text: ?[]const u8) void {
        _ = self; // unused

        if (text) |t| {
            gtk.Editable.setText(entry.as(gtk.Editable), @ptrCast(t.ptr));
        } else {
            gtk.Editable.setText(entry.as(gtk.Editable), "");
        }
    }
};

test "HistoryGTK init and deinit" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = HistoryGTK.init(allocator);
    defer hist.deinit();

    try testing.expect(hist.core.items.items.len == 0);
    try testing.expect(hist.core.index == null);
}

test "HistoryGTK addEntry" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = HistoryGTK.init(allocator);
    defer hist.deinit();

    try hist.addEntry("test command");
    try testing.expect(hist.core.items.items.len == 1);
    try testing.expectEqualStrings("test command", hist.core.items.items[0]);
}

test "HistoryGTK clearNavigation" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = HistoryGTK.init(allocator);
    defer hist.deinit();

    try hist.addEntry("test");

    // Navigate to set index
    _ = hist.core.navigate(.previous);
    try testing.expect(hist.core.index != null);

    // Clear navigation should reset index
    // Note: We can't test the GTK entry part in unit tests, but we can test the core logic
    hist.core.clearNavigation();
    try testing.expect(hist.core.index == null);
}
