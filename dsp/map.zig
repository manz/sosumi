//! The stage libraries' `.const` values, read from their source at compile time, so the players
//! and tests stage memory where the programs look: the memory map lives in the .sm files alone.
//!
//! An expression is numbers (decimal or 0x hex) and other constants joined by + - *, left to
//! right, which is all the libraries' address constants use.
const std = @import("std");
const harness = @import("harness.zig");

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The text after `.const NAME =` on its line, comment stripped, or null.
fn find(comptime name: []const u8) ?[]const u8 {
    @setEvalBranchQuota(10_000_000);
    for (harness.libs) |l| {
        var lines = std.mem.splitScalar(u8, l.text, '\n');
        while (lines.next()) |line0| {
            const line = std.mem.trim(u8, line0, " \t\r");
            if (!std.mem.startsWith(u8, line, ".const ")) continue;
            const rest = std.mem.trimStart(u8, line[".const ".len..], " \t");
            if (!std.mem.startsWith(u8, rest, name)) continue;
            const after = rest[name.len..];
            if (after.len == 0 or isIdent(after[0])) continue;
            const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
            const expr = after[eq + 1 ..];
            const end = std.mem.indexOfScalar(u8, expr, ';') orelse expr.len;
            return std.mem.trim(u8, expr[0..end], " \t");
        }
    }
    return null;
}

fn eval(comptime expr: []const u8) i64 {
    @setEvalBranchQuota(10_000_000);
    var acc: i64 = 0;
    var op: u8 = '+';
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (c == ' ' or c == '\t' or c == '(' or c == ')') {
            i += 1;
            continue;
        }
        if (c == '+' or c == '-' or c == '*') {
            op = c;
            i += 1;
            continue;
        }
        var j = i;
        while (j < expr.len and isIdent(expr[j])) j += 1;
        if (j == i) @compileError("map: cannot read '" ++ expr ++ "'");
        const tok = expr[i..j];
        const v: i64 = if (std.ascii.isDigit(tok[0])) std.fmt.parseInt(i64, tok, 0) catch @compileError("map: bad number " ++ tok) else get(tok);
        acc = switch (op) {
            '+' => acc + v,
            '-' => acc - v,
            '*' => acc * v,
            else => unreachable,
        };
        i = j;
    }
    return acc;
}

/// The value of `.const name` in the libraries.
pub fn get(comptime name: []const u8) comptime_int {
    const expr = comptime find(name) orelse @compileError("map: no .const " ++ name);
    return comptime eval(expr);
}

/// `get` as an address.
pub fn at(comptime name: []const u8) u32 {
    return get(name);
}

test "reads plain, hex and derived constants" {
    try std.testing.expectEqual(14, get("OP_ADD"));
    try std.testing.expectEqual(get("AK") + 1, get("AK_ST"));
    try std.testing.expectEqual(get("ST_Y") + 0x2E0, get("ST_RUNS"));
}
