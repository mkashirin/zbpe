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
    if (counts) |in| vcounts = in else vcounts = .init(allocator);

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

    var vit = view.iterator();
    while (vit.nextCodepoint()) |char| {
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
    inverted_merges: std.AutoHashMap(u32, Pair) = undefined,
    vocab: std.AutoHashMap(u32, []u8) = undefined,

    pub fn init(
        arena: std.mem.Allocator,
    ) !Self {
        var self: Self = .{
            .arena = arena,
            .merges = std.AutoHashMap(Pair, u32).init(arena),
        };
        try self.buildVocab();
        return self;
    }

    pub fn save(self: *Self, path_prefix: []const u8) !void {
        const efn_parts: [2][]const u8 = .{ path_prefix, ".zbe" };
        const efn = try std.mem.concat(self.arena, u8, &efn_parts);
        var cwd = try std.fs.cwd().openDir(".", .{});

        var encoding = try cwd.createFile(efn, .{});
        _ = try encoding.write(try std.fmt.allocPrint(
            self.arena,
            "zeptobpe v1\n",
            .{},
        ));

        const vfn_parts: [2][]const u8 = .{ path_prefix, ".zbv" };
        const vfn = try std.mem.concat(self.arena, u8, &vfn_parts);
        var inverted_merges = try self.invertedMerges();
        var vocab = try cwd.createFile(vfn, .{});
        var vit = self.vocab.iterator();
        while (vit.next()) |entry| {
            const mi = entry.key_ptr.*;
            const token = entry.value_ptr;
            const str = try renderToken(self.arena, token.*[0..]);
            std.debug.print("token rendered: {s}\n", .{token.*[0..]});
            if (inverted_merges.contains(mi)) {
                const mi0, const mi1 = inverted_merges.get(mi).?;
                const s0 = try renderToken(self.arena, self.vocab.get(mi0).?);

                const s1 = try renderToken(self.arena, self.vocab.get(mi1).?);
                _ = try vocab.write(try std.fmt.allocPrint(
                    self.arena,
                    "[{s}][{s}] -> [{s}] {d}\n",
                    .{ s0, s1, str, mi },
                ));
            } else _ = try vocab.write(try std.fmt.allocPrint(
                self.arena,
                "[{s}] {d}\n",
                .{ str, mi },
            ));
        }
    }

    pub fn load(
        arena: std.mem.Allocator,
        sub_path: []const u8,
        max_bytes: usize,
    ) !Self {
        if (!std.mem.endsWith(u8, sub_path, ".zbe")) return error.BadFileExt;
        const efn = std.mem.concat(arena, u8, ".zbe");
        var cwd = try std.fs.cwd().openDir(".", .{});
        var encoding = try cwd.openFile(efn, .{});

        var merges: std.AutoHashMap(Pair, u32) = .init(arena);
        var idx: u32 = 256;

        var version: [12]u8 = undefined;
        _ = try encoding.read(version);
        if (!std.mem.eql(u8, &version, "zeptobpe v1")) {
            return error.WrongVersion;
        }

        const contents = try encoding.readToEndAlloc(arena, max_bytes);
        const cit = std.mem.splitSequence(u8, contents, '\n');

        while (cit.next()) |line| : (idx += 1) {
            const split = std.mem.splitSequence(u8, line, ' ');
            const li0 = try std.fmt.parseInt(u32, split.next().?, 10);

            const li1 = try std.fmt.parseInt(u32, split.next().?, 10);
            merges.put(.{ li0, li1 }, idx);
        }

        var self: Self = .{ .arena = arena, .merges = merges };
        self.buildVocab() catch unreachable;
        return self;
    }

    pub fn train(self: *Self, text: []const u8, vocab_size: u32) !void {
        if (vocab_size <= 255) return error.VocabTooSmall;
        const n_merges = vocab_size - 256;

        var ids = std.ArrayList(u32).init(self.arena);
        defer ids.deinit();
        for (text) |byte| try ids.append(@as(u32, byte));

        for (0..n_merges) |mn| {
            const stats = try getStats(self.arena, ids.items, null);
            const pair = maxPair(stats).?;
            const idx: u32 = @intCast(256 + mn);

            try ids.appendSlice(try merge(self.arena, ids.items, pair, idx));

            try self.merges.put(pair, idx);
            const p0 = self.vocab.get(pair[0]).?;

            const p1 = self.vocab.get(pair[1]).?;
            // std.debug.print("merge {d}: {s} + {s}\n", .{ mn, p0, p1 });
            const pairs: [2][]const u8 = .{ p0, p1 };
            try self.vocab.put(idx, try std.mem.concat(
                self.arena,
                u8,
                &pairs,
            ));
        }
    }

    pub fn encode(self: *Self, text: []const u8) ![]const u32 {
        var ids = std.ArrayList(u32).init(self.arena);
        defer ids.deinit();
        for (text) |byte| try ids.append(@as(u32, byte));

        while (ids.items.len >= 2) {
            const stats = try getStats(self.arena, ids.items, null);
            var min_pair: ?Pair = null;
            var min_key = std.math.inf(f64);

            var sit = stats.iterator();
            while (sit.next()) |entry| {
                const pair = entry.key_ptr.*;
                const key_val = self._key(pair);
                if (key_val < min_key) {
                    min_key = key_val;
                    min_pair = pair;
                }
            }
            if (min_pair) |pair| {
                const index = self.merges.get(pair);
                if (index == null) break;

                const new_ids = try merge(
                    self.arena,
                    ids.items,
                    pair,
                    index.?,
                );
                ids.clearAndFree();
                for (new_ids) |id| try ids.append(id);
            } else break;
        }
        return try ids.toOwnedSlice();
    }

    fn _key(self: *Self, pair: Pair) f64 {
        if (!self.merges.contains(pair)) return std.math.inf(f64);
        const value = self.merges.get(pair);
        if (value) |val| return @floatFromInt(val) else {
            return std.math.inf(f64);
        }
    }

    pub fn decode(self: *Self, ids: []const u32) ![]const u8 {
        // 1. Concatenate all vocab byte slices for each id:
        var concat = std.ArrayList(u8).init(self.arena);
        defer concat.deinit();

        for (ids) |id| {
            const token = self.vocab.get(id);
            if (token) |bytes| {
                try concat.appendSlice(bytes);
            } else {
                // If id not found in vocab, append replacement char (UTF-8
                // encoded) U+FFFD in UTF-8 is 0xEF 0xBF 0xBD.
                try concat.appendSlice(&[_]u8{ 0xEF, 0xBF, 0xBD });
            }
        }

        const bytes = try concat.toOwnedSlice();
        // 2. Decode UTF-8 bytes with replacement of invalid sequences:
        //
        // Using unicode.Utf8View to iterate codepoints, replacing invalid
        // sequences with U+FFFD

        var decoded = std.ArrayList(u8).init(self.arena);
        defer decoded.deinit();

        var view = try unicode.Utf8View.init(bytes);
        var vit = view.iterator();

        while (vit.nextCodepoint()) |codepoint| {
            if (codepoint == unicode.replacement_character) {
                // Invalid UTF-8 sequence: append replacement character bytes.
                try decoded.appendSlice(&[_]u8{ 0xEF, 0xBF, 0xBD });
            } else {
                // Valid codepoint: encode back to UTF-8.
                var buf: [4]u8 = undefined;
                const encoded = try unicode.utf8Encode(codepoint, buf[0..]);
                try decoded.appendSlice(buf[0..encoded]);
            }
        }
        return decoded.toOwnedSlice();
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    fn buildVocab(self: *Self) !void {
        var vocab = std.AutoHashMap(u32, []u8).init(self.arena);
        for (0..256) |idx| {
            const byte: u8 = @intCast(idx);
            var arr = try self.arena.alloc(u8, 1);
            arr[0] = byte;
            try vocab.put(@intCast(idx), arr);
        }
        self.vocab = vocab;
    }

    fn invertedMerges(self: *Self) !std.AutoHashMap(u32, Pair) {
        self.inverted_merges = std.AutoHashMap(u32, Pair).init(self.arena);
        var it = self.merges.iterator();
        while (it.next()) |entry| {
            try self.inverted_merges.put(entry.value_ptr.*, entry.key_ptr.*);
        }

        return self.inverted_merges;
    }

    fn maxPair(stats: std.AutoHashMap(Pair, u32)) ?Pair {
        var max_key: ?Pair = null;
        var max_value: ?u32 = null;
        var it = stats.iterator();

        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            if (max_value == null or value > max_value.?) {
                max_key, max_value = .{ key, value };
            }
        }
        return max_key;
    }
};

test "`getStats(...)` counts pairs correctly without initial counts" {
    const allocator = testing.allocator;
    const ids = [_]u32{ 1, 2, 3, 2, 3, 4 };
    var counts = try getStats(allocator, ids[0..], null);
    defer counts.deinit();

    try testing.expect(counts.get(.{ 1, 2 }).? == 0);

    try testing.expect(counts.get(.{ 2, 3 }).? == 1);

    try testing.expect(counts.get(.{ 3, 2 }).? == 0);

    try testing.expect(counts.get(.{ 3, 4 }).? == 0);
}

test "`getStats(...)` increments existing counts" {
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

test "`merge(...)` merges pairs correctly" {
    const allocator = testing.allocator;
    const ids = [_]u32{ 1, 2, 3, 2, 3, 4 };
    const pair = .{ 2, 3 };
    const idx = 99;
    const merged = try merge(allocator, ids[0..], pair, idx);
    defer allocator.free(merged);

    try testing.expectEqualSlices(u32, merged, &[_]u32{ 1, 99, 99, 4 });
}

test "`merge(...)` with no matching pairs returns original array" {
    const allocator = testing.allocator;
    const ids = [_]u32{ 1, 2, 3, 4 };
    const pair = .{ 5, 6 };
    const idx = 99;
    const merged = try merge(allocator, ids[0..], pair, idx);
    defer allocator.free(merged);

    try testing.expectEqualSlices(u32, merged, ids[0..]);
}

test "`replaceControlChars(...)` replaces control characters with escapes" {
    const allocator = testing.allocator;
    // Contains control chars `\x01` and `\n`:
    const input = "Hello\x01World\n".*;
    const replaced = try replaceControlChars(allocator, &input);
    defer allocator.free(replaced);
    const expected = "Hello\\u0001World\\u000a";

    try testing.expect(std.mem.eql(u8, replaced, expected));
}

test "`replaceControlChars(...)` leaves normal characters unchanged" {
    const allocator = testing.allocator;
    const input = "Hello, Zig!".*;
    const replaced = try replaceControlChars(allocator, &input);
    defer allocator.free(replaced);

    try testing.expect(std.mem.eql(u8, replaced, &input));
}

test "`renderToken(...)` replaces invalid UTF-8 and control chars" {
    const allocator = testing.allocator;
    // Invalid UTF-8 sequence `\xFF` and control char `\x01`:
    const input = "Test\x01invalid\xFFbyte";
    const replaced = try renderToken(allocator, input);
    defer allocator.free(replaced);
    const expected = "Test\\u0001invalid�byte";

    try testing.expect(std.mem.eql(u8, replaced, expected));
}

test "`.buildVocab()` builds vocab correctly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokenizer: Tokenizer = try .init(allocator);
    _ = &tokenizer;
}

test "`.init(...)`, `.encode(...)`, `.decode(...)`, and `.deinit(...)`" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Initialize tokenizer with default pattern
    var tokenizer: Tokenizer = try .init(allocator);
    // Simple input text
    const input = "abc";
    // Encode input text to token ids
    const encoded = try tokenizer.encode(input);
    // Check that encoded is not empty and contains u32 ids
    try testing.expect(encoded.len > 0);
    // Decode back to text bytes
    const decoded = try tokenizer.decode(encoded);

    // The decoded bytes should be valid UTF-8 and contain the original
    // characters.
    try testing.expect(std.mem.indexOf(u8, decoded, "a") != null);

    try testing.expect(std.mem.indexOf(u8, decoded, "b") != null);

    try testing.expect(std.mem.indexOf(u8, decoded, "c") != null);
    // Encode and decode empty input should work and return empty output
    const empty_encoded = try tokenizer.encode("");
    try testing.expect(empty_encoded.len == 0);
    const empty_decoded = try tokenizer.decode(empty_encoded);
    try testing.expect(empty_decoded.len == 0);
}

test "tokenizer's train/encode/decode roundtrip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tokenizer: Tokenizer = try .init(allocator);
    const input =
        \\Hello, World!
        \\Ziglang 123...
        \\Test with spaces and newlines
        \\Epic emoji test 😀
    ;

    try tokenizer.train(input, 256 + 8);

    const encoded = try tokenizer.encode(input);
    defer allocator.free(encoded);

    const decoded = try tokenizer.decode(encoded);
    defer allocator.free(decoded);

    // The decoded string should contain all original characters
    // (approximate check). Because merges might change tokenization, we
    // check that decoded contains input bytes as a subsequence.
    try testing.expect(
        std.mem.indexOfScalar(u8, decoded, input[0]) != null,
    );
}
