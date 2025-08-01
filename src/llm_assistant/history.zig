const std = @import("std");

pub const Direction = enum { previous, next };

pub const History = struct {
    items: std.ArrayList([:0]u8),
    index: ?usize = null,
    max_size: usize = 50,

    pub fn init(allocator: std.mem.Allocator) History {
        return History{
            .items = std.ArrayList([:0]u8).init(allocator),
        };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |item| {
            self.items.allocator.free(item);
        }
        self.items.deinit();
    }

    /// Add a text entry to history
    pub fn addEntry(self: *History, text: []const u8) !void {
        // Add to history (null-terminated for compatibility)
        const owned_text = try self.items.allocator.dupeZ(u8, text);
        try self.items.append(owned_text);

        // Limit history size
        if (self.items.items.len > self.max_size) {
            self.items.allocator.free(self.items.orderedRemove(0));
        }

        // Reset history index
        self.index = null;
    }

    /// Navigate through history and return the text (platform-agnostic)
    pub fn navigate(self: *History, direction: Direction) ?[]const u8 {
        if (self.items.items.len == 0) return null;

        switch (direction) {
            .previous => self.navigatePrevious(),
            .next => self.navigateNext(),
        }

        return self.getCurrentText();
    }

    /// Get the current text at the history index
    pub fn getCurrentText(self: *History) ?[]const u8 {
        const index = self.index orelse return null;
        if (index >= self.items.items.len) return null;
        return self.items.items[index];
    }

    /// Clear the current history navigation (return to "current" state)
    pub fn clearNavigation(self: *History) void {
        self.index = null;
    }

    fn navigatePrevious(self: *History) void {
        const current_index = self.index orelse {
            self.index = self.items.items.len - 1;
            return;
        };

        if (current_index == 0) return;
        self.index = current_index - 1;
    }

    fn navigateNext(self: *History) void {
        const current_index = self.index orelse return;

        if (current_index >= self.items.items.len - 1) {
            self.index = null;
            return;
        }

        self.index = current_index + 1;
    }
};

test "History.init creates empty history" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();

    try testing.expect(hist.items.items.len == 0);
    try testing.expect(hist.index == null);
    try testing.expect(hist.max_size == 50);
}

test "History.addEntry adds entries and limits size" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();

    // Add a few entries
    try hist.addEntry("first command");
    try hist.addEntry("second command");
    try hist.addEntry("third command");

    try testing.expect(hist.items.items.len == 3);
    try testing.expectEqualStrings("first command", hist.items.items[0]);
    try testing.expectEqualStrings("second command", hist.items.items[1]);
    try testing.expectEqualStrings("third command", hist.items.items[2]);
    try testing.expect(hist.index == null);
}

test "History.addEntry limits max size correctly" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();
    hist.max_size = 3; // Set small max size for testing

    // Add more entries than max size
    try hist.addEntry("first");
    try hist.addEntry("second");
    try hist.addEntry("third");
    try hist.addEntry("fourth");
    try hist.addEntry("fifth");

    try testing.expect(hist.items.items.len == 3);
    try testing.expectEqualStrings("third", hist.items.items[0]);
    try testing.expectEqualStrings("fourth", hist.items.items[1]);
    try testing.expectEqualStrings("fifth", hist.items.items[2]);
}

test "History.navigate with empty history does nothing" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();

    // Navigate on empty history should return null
    const result = hist.navigate(.previous);
    try testing.expect(result == null);
    try testing.expect(hist.index == null);
}

test "History.navigate previous and next logic" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();

    // Add test entries
    try hist.addEntry("first");
    try hist.addEntry("second");
    try hist.addEntry("third");

    // Navigate to previous (should go to last item)
    const prev1 = hist.navigate(.previous);
    try testing.expect(prev1 != null);
    try testing.expectEqualStrings("third", prev1.?);
    try testing.expect(hist.index.? == 2);

    // Navigate previous again
    const prev2 = hist.navigate(.previous);
    try testing.expect(prev2 != null);
    try testing.expectEqualStrings("second", prev2.?);
    try testing.expect(hist.index.? == 1);

    // Navigate to next
    const next1 = hist.navigate(.next);
    try testing.expect(next1 != null);
    try testing.expectEqualStrings("third", next1.?);
    try testing.expect(hist.index.? == 2);

    // Navigate next again (should reset to null)
    const next2 = hist.navigate(.next);
    try testing.expect(next2 == null);
    try testing.expect(hist.index == null);
}

test "History.getCurrentText" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();

    try hist.addEntry("test entry");

    // No navigation yet, should return null
    try testing.expect(hist.getCurrentText() == null);

    // Navigate and then get current text
    _ = hist.navigate(.previous);
    const current = hist.getCurrentText();
    try testing.expect(current != null);
    try testing.expectEqualStrings("test entry", current.?);
}

test "History.clearNavigation" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);
    defer hist.deinit();

    try hist.addEntry("test");
    _ = hist.navigate(.previous);
    try testing.expect(hist.index != null);

    hist.clearNavigation();
    try testing.expect(hist.index == null);
}

test "History.deinit frees all memory" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hist = History.init(allocator);

    try hist.addEntry("test entry 1");
    try hist.addEntry("test entry 2");

    // Should not leak memory when deinit is called
    hist.deinit();
}
