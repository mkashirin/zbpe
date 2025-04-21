const std = @import("std");

const testing = std.testing;
const unicode = std.unicode;

pub const Pair = struct { u32, u32 };

pub fn getStats(
    allocator: std.mem.Allocator,
    ids: []const u32,
    counts: ?std.AutoHashMap(Pair, u32),
) !std.AutoHashMap(Pair, u32) {
    var vcounts: std.AutoHashMap(Pair, u32) = undefined;
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
    pair: Pair,
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

    arena: std.mem.Allocator,
    merges: std.AutoHashMap(Pair, u32),
    inverted_merges: ?std.AutoHashMap(u32, Pair) = null,
    pattern: ?[]const u8,
    special_tokens: std.StringHashMap(u32),
    vocab: std.AutoHashMap(u32, []u8) = undefined,

    pub fn init(arena: std.mem.Allocator, pattern: ?[]const u8) Self {
        var self: Self = .{
            .arena = arena,
            .merges = std.AutoHashMap(Pair, u32).init(arena),
            .pattern = pattern,
            .special_tokens = std.StringHashMap(u32).init(arena),
        };
        self.buildVocab() catch unreachable;
        return self;
    }

    pub fn save(self: *Self, path_prefix: []const u8) !void {
        const efn = path_prefix ++ ".zbe";
        var cwd = try std.fs.cwd().openDir(".", .{});

        var encoding = try cwd.createFile(efn, .{});
        _ = try encoding.write("zeptobpe v1\n");
        _ = try encoding.write(std.fmt.allocPrint(
            self.arena,
            "{s}\n",
            .{self.pattern},
        ));
        _ = try encoding.write(std.fmt.allocPrint(
            self.arena,
            "{d}\n",
            .{self.special_tokens.count()},
        ));

        var st_it = self.special_tokens.iterator();
        while (st_it.next()) |entry| {
            const special = entry.key_ptr; // []const u8 (string key)
            const i = entry.value_ptr.*; // u32
            _ = try encoding.write(std.fmt.allocPrint(
                self.arena,
                "{s} {d}\n",
                .{ special.*, i },
            ));
        }

        var mit = self.merges.iterator();
        while (mit.next()) |entry| {
            const special = entry.key_ptr; // []const u8 (string key)
            const i = entry.value_ptr.*; // u32
            _ = try encoding.write(std.fmt.allocPrint(
                self.arena,
                "{s} {d}\n",
                .{ special.*, i },
            ));
        }

        const vfn = std.mem.concat(self.arena, u8, .{ path_prefix, ".zbv" });
        var inverted_merges = self.invertedMerges();
        var vocab = try cwd.createFile(vfn, .{});
        var vocab_it = self.vocab.iterator();
        while (vocab_it.next()) |entry| {
            const mi = entry.key_ptr.*; // u32
            const token = entry.value_ptr; // []const u8
            const str = renderToken(self.arena, token.*[0..]);
            if (inverted_merges.contains(mi)) {
                const mi0, const mi1 = inverted_merges.get(mi).?;
                const s0 = renderToken(self.arena, self.vocab.get(mi0));

                const s1 = renderToken(self.arena, self.vocab.get(mi1));
                _ = try vocab.write(std.fmt.allocPrint(
                    self.arena,
                    "[{s}][{s}] -> [{s}] {d}\n",
                    .{ s0, s1, str, mi },
                ));
            } else _ = try vocab.write(std.fmt.allocPrint(
                self.arena,
                "[{s}] {d}\n",
                .{ str, mi },
            ));
        }
    }

    pub fn load(arena: std.mem.Allocator, sub_path: []const u8) !void {
        if (!std.mem.endsWith(u8, sub_path, ".zbe")) return error.BadFileExt;
        _ = arena;
        // var merges: std.AutoHashMap(Pair, u32) = .init(arena);
        // var special_tokens: std.StringHashMap(u32) = .init(arena);
        // var i: u32 = 256;
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    fn buildVocab(self: *Self) !void {
        var vocab = std.AutoHashMap(u32, []u8).init(self.arena);

        // 1. Initialize vocab with single-byte entries: i -> [i]:
        for (0..256) |i| {
            const byte: u8 = @intCast(i);
            var arr = try self.arena.alloc(u8, 1);
            arr[0] = byte;
            try vocab.put(@intCast(i), arr);
        }

        // 2. For each merge ((p0, p1) -> i), set vocab[i] = vocab[p0]
        // + vocab[p1]:
        var merges_it = self.merges.iterator();
        while (merges_it.next()) |entry| {
            const pair = entry.key_ptr;
            const i = entry.value_ptr.*;
            const p0_val = vocab.get(pair[0]).?;

            const p1_val = vocab.get(pair[1]).?;
            const len = p0_val.len + p1_val.len;
            var merged = try self.arena.alloc(u8, len);

            std.mem.copyForwards(u8, merged[0..p0_val.len], p0_val);
            std.mem.copyForwards(u8, merged[p0_val.len..len], p1_val);

            if (vocab.contains(i)) {
                const old_val = vocab.get(i).?;
                self.arena.free(old_val);
                try vocab.put(i, merged);
            } else {
                try vocab.put(i, merged);
            }
        }

        // 3. For each special token (special string -> i), encode and insert:
        var st_it = self.special_tokens.iterator();
        while (st_it.next()) |entry| {
            const special = entry.key_ptr; // []const u8 (string key)
            const i = entry.value_ptr.*; // u32

            // Copy special token bytes into allocated buffer
            const special_copy = &(try self.arena.alloc(u8, special.len));
            std.mem.copyForwards(u8, special_copy.*, special.*);

            if (vocab.contains(i)) {
                const old_val = vocab.get(i).?;
                self.arena.free(old_val);
                try vocab.put(i, special_copy.*);
            } else {
                try vocab.put(i, special_copy.*);
            }
        }

        self.vocab = vocab;
    }

    fn invertedMerges(self: *Self) !std.HashMap(i32, Pair) {
        self.inverted_merges = std.AutoHashMap(i32, Pair).init(self.arena);

        // Iterate over all entries in merges
        var it = self.merges.iterator();
        while (it.next()) |entry| {
            // entry.key is Pair, entry.value is i32
            try self.inverted_merges.put(entry.value, entry.key);
        }

        return self.inverted_merges;
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokenizer: Tokenizer = .init(allocator, null);
    _ = &tokenizer;
}
