const std = @import("std");

pub fn Bloom(comptime K: type, comptime H: fn (K) u128) type {
    return struct {
        num_hashes: usize,
        bitset: std.bit_set.Dynamic,

        const Self = @This();

        const Sizing = struct {
            bits: usize,
            hashes: usize,

            fn derive(n: usize, p: f64) !Sizing {
                if (n == 0 or !(p > 0 and p < 1)) return error.InvalidConfig;
                const ln2 = @log(2.0);
                const nf: f64 = @floatFromInt(n);
                // -nlnp/(ln2)^2
                const m = -nf * @log(p) / (ln2 * ln2);
                // (m/n)ln2
                const k = m / nf * ln2;
                return .{
                    .bits = try std.math.ceilPowerOfTwo(usize, std.math.lossyCast(usize, @ceil(m))),
                    .hashes = @intFromFloat(@max(1.0, @ceil(k))),
                };
            }
        };

        pub const Config = struct {
            expected_count: usize,
            false_positive_rate: f64 = 0.01,
        };

        pub fn init(gpa: std.mem.Allocator, cfg: Config) !Self {
            const s = try Sizing.derive(cfg.expected_count, cfg.false_positive_rate);
            return .{
                .num_hashes = s.hashes,
                .bitset = try .initEmpty(gpa, s.bits),
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.bitset.deinit(gpa);
        }

        const HashIterator = struct {
            i: usize,
            // num hashes to generate
            n: usize,
            // mod divisor
            m: usize,
            hash_a: u64,
            hash_b: u64,

            fn init(n: usize, m: usize, hash: u128) HashIterator {
                const hash_a: u64 = @truncate(hash >> 64);
                // force coprime to m
                const hash_b: u64 = @as(u64, @truncate(hash)) | 1;
                return .{
                    .i = 0,
                    .n = n,
                    .m = m,
                    .hash_a = hash_a,
                    .hash_b = hash_b,
                };
            }

            fn next(self: *HashIterator) ?u64 {
                if (self.i >= self.n) {
                    return null;
                }
                const hash = (self.hash_a +% self.i *% self.hash_b) % self.m;
                self.i += 1;
                return hash;
            }
        };

        fn hashIterator(self: *Self, key: K) HashIterator {
            const n = self.num_hashes;
            const m = self.bitset.capacity();
            const hash = H(key);
            return .init(n, m, hash);
        }

        pub fn insert(self: *Self, key: K) void {
            var iter = self.hashIterator(key);
            while (iter.next()) |hash| {
                self.bitset.set(hash);
            }
        }

        pub fn contains(self: *Self, key: K) bool {
            var iter = self.hashIterator(key);
            while (iter.next()) |hash| {
                if (!self.bitset.isSet(hash)) {
                    return false;
                }
            }
            return true;
        }
    };
}

test {
    const key: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const hash = struct {
        fn h(x: u64) u128 {
            return std.crypto.auth.siphash.SipHash128(2, 4).toInt(&std.mem.toBytes(x), &key);
        }
    }.h;
    const gpa = std.testing.allocator;
    var b = try Bloom(u64, hash).init(gpa, .{ .expected_count = 100 });
    defer b.deinit(gpa);
    for (0..100) |i| {
        b.insert(@as(u64, i));
    }
    for (0..100) |i| {
        try std.testing.expect(b.contains(@as(u64, i)));
    }
    for (1000..1010) |i| {
        try std.testing.expect(!b.contains(@as(u64, i)));
    }
}
