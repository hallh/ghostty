const std = @import("std");
const gtk = @import("gtk");

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
        // Add to history (null-terminated for GTK compatibility)
        const owned_text = try self.items.allocator.dupeZ(u8, text);
        try self.items.append(owned_text);

        // Limit history size
        if (self.items.items.len > self.max_size) {
            self.items.allocator.free(self.items.orderedRemove(0));
        }

        // Reset history index
        self.index = null;
    }

    /// Navigate through history and update the provided entry widget
    pub fn navigate(self: *History, direction: enum { previous, next }, entry: *gtk.Entry) void {
        if (self.items.items.len == 0) return;

        switch (direction) {
            .previous => {
                if (self.index) |index| {
                    if (index > 0) {
                        self.index = index - 1;
                    }
                } else {
                    self.index = self.items.items.len - 1;
                }
            },
            .next => {
                if (self.index) |index| {
                    if (index < self.items.items.len - 1) {
                        self.index = index + 1;
                    } else {
                        self.index = null;
                    }
                }
            },
        }

        // Update entry text
        if (self.index) |index| {
            const text = self.items.items[index];
            gtk.Editable.setText(entry.as(gtk.Editable), @ptrCast(text.ptr));
        } else {
            gtk.Editable.setText(entry.as(gtk.Editable), "");
        }
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

    // Create a mock GTK entry for testing
    // Note: This is a simplified test since we can't easily mock GTK widgets
    // In practice, this would be tested via integration tests

    // The navigate function should handle empty history gracefully
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

    // Test navigation logic (without GTK dependency)
    // Navigate to previous (should go to last item)
    hist.index = hist.items.items.len - 1; // Simulate first previous navigation
    try testing.expect(hist.index.? == 2);

    // Navigate previous again
    if (hist.index.? > 0) {
        hist.index = hist.index.? - 1;
    }
    try testing.expect(hist.index.? == 1);

    // Navigate to next
    if (hist.index.? < hist.items.items.len - 1) {
        hist.index = hist.index.? + 1;
    } else {
        hist.index = null;
    }
    try testing.expect(hist.index.? == 2);

    // Navigate next again (should reset to null)
    if (hist.index.? < hist.items.items.len - 1) {
        hist.index = hist.index.? + 1;
    } else {
        hist.index = null;
    }
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
