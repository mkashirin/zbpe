const std = @import("std");

const testing = std.testing;
const unicode = std.unicode;

pub fn getStats(
    allocator: std.mem.Allocator,
    ids: []const u32,
    counts: ?std.AutoHashMap(struct { u32, u32 }, u32),
) !std.AutoHashMap(struct { u32, u32 }, u32) {
    var vcounts: std.AutoHashMap(struct { u32, u32 }, u32) = undefined;
    if (counts) |in| vcounts = in else {
        vcounts = .init(allocator);
    }
    for (ids[0 .. ids.len - 1], ids[1..]) |p0, p1| {
        const count = try vcounts.getOrPut(.{ p0, p1 });
        if (count.found_existing) count.value_ptr.* += 1 else {
            count.value_ptr.* = 0;
        }
    }
    return vcounts;
}

pub fn merge(
    allocator: std.mem.Allocator,
    ids: []const u32,
    pair: struct { u32, u32 },
    idx: u32,
) ![]const u32 {
    var new_ids: std.ArrayList(u32) = .init(allocator);
    var icount: usize = 0;
    while (icount < ids.len) {
        if (ids[icount] == pair[0] and icount < ids.len - 1 and
            ids[icount + 1] == pair[1])
        {
            try new_ids.append(idx);
            icount += 2;
        } else {
            try new_ids.append(ids[icount]);
            icount += 1;
        }
    }
    return new_ids.toOwnedSlice();
}

fn isControlChar(char: u32) bool {
    return (char <= 0x1F) or (char == 0x7F) or (char >= 0x80 and char <= 0x9F);
}

pub fn replaceControlChars(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    const view = try unicode.Utf8View.init(input);
    var out: std.ArrayList(u8) = .init(allocator);
    defer out.deinit();

    var view_it = view.iterator();
    while (view_it.nextCodepoint()) |char| {
        if (!isControlChar(char)) {
            var buf: [4]u8 = undefined;
            const buf_len = try unicode.utf8Encode(char, &buf);
            try out.appendSlice(buf[0..buf_len]);
        } else {
            if (char <= 0xFFFF) {
                try out.appendSlice("\\u");
                // Format code point as 4-digit lowercase hex
                const hex = try std.fmt.allocPrint(allocator, "{x:04}", .{char});
                try out.appendSlice(hex);
                allocator.free(hex);
            } else {
                try out.appendSlice("\\U");
                // Format code point as 8-digit lowercase hex
                const hex = try std.fmt.allocPrint(allocator, "{x:08}", .{char});
                try out.appendSlice(hex);
                allocator.free(hex);
            }
        }
    }

    return out.toOwnedSlice();
}

pub fn renderToken(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var vtoken = try allocator.alloc(u8, token.len * 3);
    defer allocator.free(vtoken);

    var writer = std.io.fixedBufferStream(vtoken);
    try std.fmt.format(writer.writer(), "{}", .{unicode.fmtUtf8(token)});

    const written = writer.pos;
    return replaceControlChars(allocator, vtoken[0..written]);
}

pub const Tokenizer = struct {
    const Self = @This();

    merges: std.AutoHashMap(struct { u32, u32 }, u32),
    pattern: ?[]const u8,
    special_tokens: std.StringHashMap(u32),
    vocab: std.AutoHashMap(u32, []u8),

    pub fn init(allocator: std.mem.Allocator, pattern: ?[]const u8) *Self {
        return &.{
            .merges = std.AutoHashMap(struct { u32, u32 }, u32).init(
                allocator,
            ),
            .pattern = pattern,
            .special_tokens = std.StringHashMap(u32).init(allocator),
            .vocab = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn buildVocab(
        merges: std.AutoHashMap(struct { u32, u32 }, u32),
        special_tokens: std.StringHashMap(u32),
        allocator: std.mem.Allocator,
    ) !std.AutoHashMap(u32, []u8) {
        var vocab = std.AutoHashMap(u32, []u8).init(allocator);

        // 1. Initialize vocab with single-byte entries: i -> [i]
        for (0..256) |i| {
            const byte: u8 = @intCast(i);
            var arr = try allocator.alloc(u8, 1);
            arr[0] = byte;
            try vocab.put(@intCast(i), arr);
        }

        // 2. For each merge ((p0, p1) -> i), set vocab[i] = vocab[p0] + vocab[p1]
        var merges_it = merges.iterator();
        while (merges_it.next()) |entry| {
            const pair = entry.key_ptr.*;
            const i = entry.value_ptr.*;
            const p0_val = vocab.get(pair[0]).?;

            const p1_val = vocab.get(pair[1]).?;
            const len = p0_val.len + p1_val.len;
            var merged = try allocator.alloc(u8, len);

            std.mem.copyForwards(u8, merged[0..p0_val.len], p0_val);
            std.mem.copyForwards(u8, merged[p0_val.len..len], p1_val);

            if (vocab.contains(i)) {
                const old_val = vocab.get(i).?;
                allocator.free(old_val);
                try vocab.put(i, merged);
            } else {
                try vocab.put(i, merged);
            }
        }

        // 3. For each special token (special string -> i), encode and insert
        var st_it = special_tokens.iterator();
        while (st_it.next()) |entry| {
            const special = entry.key_ptr.*; // []const u8 (string key)
            const i = entry.value_ptr.*; // u32

            // Copy special token bytes into allocated buffer
            const special_copy = &(try allocator.alloc(u8, special.len));
            std.mem.copyForwards(u8, special_copy.*, special);

            if (vocab.contains(i)) {
                const old_val = vocab.get(i).?;
                allocator.free(old_val);
                try vocab.put(i, special_copy.*);
            } else {
                try vocab.put(i, special_copy.*);
            }
        }
        return vocab;
    }
};

test "`getStats()` counts pairs correctly without initial counts" {
    const allocator = testing.allocator;
    const ids = [_]u32{ 1, 2, 3, 2, 3, 4 };

    var counts = try getStats(allocator, ids[0..], null);
    defer counts.deinit();

    try testing.expect(counts.get(.{ 1, 2 }).? == 0);
    try testing.expect(counts.get(.{ 2, 3 }).? == 1);
    try testing.expect(counts.get(.{ 3, 2 }).? == 0);
    try testing.expect(counts.get(.{ 3, 4 }).? == 0);
}

test "`getStats()` increments existing counts" {
    const allocator = testing.allocator;
    var initial_counts = std.AutoHashMap(
        struct { u32, u32 },
        u32,
    ).init(allocator);
    defer initial_counts.deinit();

    try initial_counts.put(.{ 1, 2 }, 5);
    try initial_counts.put(.{ 2, 3 }, 10);

    const ids = [_]u32{ 1, 2, 3 };
    var counts = try getStats(allocator, ids[0..], initial_counts);

    try testing.expect(counts.get(.{ 1, 2 }).? == 6);
    try testing.expect(counts.get(.{ 2, 3 }).? == 11);
}

test "`merge()` merges pairs correctly" {
    const allocator = testing.allocator;

    const ids = [_]u32{ 1, 2, 3, 2, 3, 4 };
    const pair = .{ 2, 3 };
    const idx = 99;

    const merged = try merge(allocator, ids[0..], pair, idx);
    defer allocator.free(merged);

    try testing.expectEqualSlices(u32, merged, &[_]u32{ 1, 99, 99, 4 });
}

test "`merge()` with no matching pairs returns original array" {
    const allocator = testing.allocator;

    const ids = [_]u32{ 1, 2, 3, 4 };
    const pair = .{ 5, 6 };
    const idx = 99;

    const merged = try merge(allocator, ids[0..], pair, idx);
    defer allocator.free(merged);

    try testing.expectEqualSlices(u32, merged, ids[0..]);
}

test "`replaceControlChars()` replaces control characters with escapes" {
    const allocator = testing.allocator;

    // Contains control chars `\x01` and `\n`:
    const input = "Hello\x01World\n".*;
    const replaced = try replaceControlChars(allocator, &input);
    defer allocator.free(replaced);

    const expected = "Hello\\u0001World\\u000a";
    try testing.expect(std.mem.eql(u8, replaced, expected));
}

test "`replaceControlChars()` leaves normal characters unchanged" {
    const allocator = testing.allocator;

    const input = "Hello, Zig!".*;
    const replaced = try replaceControlChars(allocator, &input);
    defer allocator.free(replaced);

    try testing.expect(std.mem.eql(u8, replaced, &input));
}

test "`renderToken()` replaces invalid UTF-8 and control chars" {
    const allocator = testing.allocator;

    // Invalid UTF-8 sequence `\xFF` and control char `\x01`:
    const input = "Test\x01invalid\xFFbyte";
    const replaced = try renderToken(allocator, input);
    defer allocator.free(replaced);

    const expected = "Test\\u0001invalid�byte";
    try testing.expect(std.mem.eql(u8, replaced, expected));
}

test "`Tokenizer.buildVocab()` builds vocab correctly" {
    const allocator = testing.allocator;

    // Initialize empty merges map: (p0, p1) -> i
    var merges = std.AutoHashMap(struct { u32, u32 }, u32).init(allocator);
    defer merges.deinit();

    // Initialize special tokens map: string -> i
    var special_tokens = std.StringHashMap(u32).init(allocator);
    defer special_tokens.deinit();

    // Insert a merge: merge (65, 66) -> 256
    // 65 = 'A', 66 = 'B', so vocab[256] = "AB"
    try merges.put(.{ 65, 66 }, 256);

    // Insert a special token: "<PAD>" -> 257
    try special_tokens.put("<PAD>", 257);

    // Call buildVocab
    var vocab = try Tokenizer.buildVocab(merges, special_tokens, allocator);
    defer {
        // Free all allocated byte arrays in vocab
        var it = vocab.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        vocab.deinit();
    }

    // Check single-byte entries: e.g. vocab[65] == "A"
    const a_val = vocab.get(65) orelse unreachable;
    try testing.expectEqual(1, a_val.len);
    try testing.expectEqual('A', a_val[0]);

    // Check merged entry vocab[256] == "AB"
    const merged_val = vocab.get(256) orelse unreachable;
    try testing.expectEqual(2, merged_val.len);
    try testing.expectEqual('A', merged_val[0]);
    try testing.expectEqual('B', merged_val[1]);

    // Check special token vocab[257] == "<PAD>"
    const pad_val = vocab.get(257) orelse unreachable;
    try testing.expectEqual(5, pad_val.len);
    try testing.expectEqualSlices(u8, "PAD>", pad_val[1..]); // check substring after '<'
    try testing.expectEqual('<', pad_val[0]);

    // Check that some other byte is present, e.g. 97 = 'a'
    const a_lower = vocab.get(97) orelse unreachable;
    try testing.expectEqual('a', a_lower[0]);
}
