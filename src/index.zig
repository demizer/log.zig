//  Copyright (c) 2018,2020 emekoi, demizer
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const math = std.math;
const root = @import("root");

const io = std.io;
const os = std.os;
const fs = std.fs;

// TODO: check windows support
const windows = os.windows;
const posix = os.posix;
const Mutex = std.Mutex;

// TODO: readd windows support
// const FOREGROUND_BLUE = 1;
// const FOREGROUND_GREEN = 2;
// const FOREGROUND_AQUA = 3;
// const FOREGROUND_RED = 4;
// const FOREGROUND_MAGENTA = 5;
// const FOREGROUND_YELLOW = 6;

pub const TTY = enum {
    const Self = @This();

    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    Reset,
    Bright,
    Dim,

    fn Code(self: Self) []const u8 {
        return switch (self) {
            .Red => "\x1b[31m",
            .Green => "\x1b[32m",
            .Yellow => "\x1b[33m",
            .Blue => "\x1b[34m",
            .Magenta => "\x1b[35m",
            .Cyan => "\x1b[36m",
            .White => "\x1b[37m",
            .Reset => "\x1b[0m",
            .Bright => "\x1b[1m",
            .Dim => "\x1b[2m",
        };
    }
};

/// The default log level is based on build mode.
pub const default_level: Level = switch (builtin.mode) {
    .Debug => .Debug,
    .ReleaseSafe => .Info,
    .ReleaseFast => .Error,
    .ReleaseSmall => .Error,
};

/// The current log level. This is set to root.log_level if present, otherwise
/// log.default_level.
pub const level: Level = if (@hasDecl(root, "log_level"))
    root.log_level
else
    default_level;

/// different levels of logging
pub const Level = enum {
    const Self = @This();

    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Fatal,

    fn toString(self: Self) []const u8 {
        return switch (self) {
            Self.Trace => "TRACE",
            Self.Debug => "DEBUG",
            Self.Info => "INFO",
            Self.Warn => "WARN",
            Self.Error => "ERROR",
            Self.Fatal => "FATAL",
        };
    }

    fn color(self: Self) TTY {
        return switch (self) {
            Self.Trace => TTY.Blue,
            Self.Debug => TTY.Cyan,
            Self.Info => TTY.Green,
            Self.Warn => TTY.Yellow,
            Self.Error => TTY.Red,
            Self.Fatal => TTY.Magenta,
        };
    }
};

pub const LoggerOptions = struct {
    color: bool = false,
    fileName: bool = false,
    lineNumber: bool = false,
    timestamp: bool = false,
    doubleSpacing: bool = false,
};

pub fn LogFormatPrefix(
    allocator: *std.mem.Allocator,
    writer: anytype,
    config: LoggerOptions,
    scopelevel: Level,
) void {
    // TODO: readd windows support
    //     if (std.Target.current.os.tag == .windows and !os.supportsAnsiEscapeCodes(self.file.handle)) {
    //         self.setTtyColorWindows(color);
    //     } else {
    //     }
    if (config.timestamp) {
        writer.print("{} ", .{std.time.timestamp()}) catch return;
    }
    if (config.color) {
        writer.print("{}", .{TTY.Code(.Reset)}) catch return;
        writer.writeAll(scopelevel.color().Code()) catch return;
        writer.print("[{}]", .{scopelevel.toString()}) catch return;
        writer.writeAll(TTY.Reset.Code()) catch return;
        writer.print(": ", .{}) catch return;
    } else {
        writer.print("[{s}]: ", .{scopelevel.toString()}) catch return;
    }

    // TODO: allow independt fileName and lineNumber
    if (!config.fileName and !config.lineNumber) {
        return;
    }

    // TODO remove the need for an allocator
    // TODO use better method to get the filename and line number
    // https://github.com/ziglang/zig/issues/7106
    var dbconfig: std.debug.TTY.Config = .no_color;
    var lineBuf = std.ArrayList(u8).init(allocator);
    defer lineBuf.deinit();

    const debug_info = std.debug.getSelfDebugInfo() catch return;
    var it = std.debug.StackIterator.init(@returnAddress(), null);
    var count: u8 = 0;
    var address: usize = 0;
    while (it.next()) |return_address| {
        if (count == 2) {
            address = return_address;
            break;
        }
        count += 1;
    }
    std.debug.printSourceAtAddress(debug_info, lineBuf.outStream(), address - 1, dbconfig) catch unreachable;
    const colPos = std.mem.indexOf(u8, lineBuf.items[0..], ": ");

    if (config.color) {
        writer.print("{}[{}]: ", .{ TTY.Code(.Reset), lineBuf.items[0..colPos.?] }) catch unreachable;
    } else {
        writer.print("[{}]: ", .{lineBuf.items[0..colPos.?]}) catch unreachable;
    }
}

/// a simple thread-safe logger
pub const Logger = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    file: fs.File,
    writer: fs.File.Writer,
    default_attrs: windows.WORD,
    options: LoggerOptions,

    /// create `Logger`.
    pub fn init(allocator: *std.mem.Allocator, file: fs.File, options: LoggerOptions) Self {
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (std.Target.current.os.tag == .windows) {
            _ = windows.kernel32.GetConsoleScreenBufferInfo(file.handle, &info);
        }
        return Self{
            .allocator = allocator,
            .file = file,
            .writer = file.writer(),
            .default_attrs = info.wAttributes,
            .options = options,
        };
    }

    /// General purpose log function.
    pub fn log(self: *Self, scopeLevel: Level, comptime fmt: []const u8, args: anytype) !void {
        if (@enumToInt(scopeLevel) < @enumToInt(level)) {
            return;
        }
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        nosuspend LogFormatPrefix(self.allocator, self.writer, self.options, scopeLevel);
        nosuspend self.writer.print(fmt, args) catch return;
        if (self.options.doubleSpacing) {
            self.writer.writeAll("\n") catch return;
        }
    }

    /// log at level `Level.Trace`.
    pub fn Trace(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(Level.Trace, fmt, args) catch return;
    }

    /// log at level `Level.Debug`.
    pub fn Debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(Level.Debug, fmt, args) catch return;
    }

    /// log at level `Level.Info`.
    pub fn Info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(Level.Info, fmt, args) catch return;
    }

    /// log at level `Level.Warn`.
    pub fn Warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(Level.Warn, fmt, args) catch return;
    }

    /// log at level `Level.Error`.
    pub fn Error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(Level.Error, fmt, args) catch return;
    }

    /// log at level `Level.Fatal`.
    pub fn Fatal(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(Level.Fatal, fmt, args) catch return;
    }
};

test "Log without style" {
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();

    var logger = Logger.init(testing.allocator, file, LoggerOptions{
        .color = false,
        .timestamp = false,
        .fileName = false,
        .lineNumber = false,
        .doubleSpacing = false,
    });

    logger.Trace("hi\n", .{});
    logger.Debug("hey\n", .{});
    logger.Info("hello\n", .{});
    logger.Info("hello {} {}\n", .{ "hello", 25 });
    logger.Warn("greetings\n", .{});
    logger.Error("salutations\n", .{});
    logger.Fatal("goodbye\n", .{});

    const expect = "[DEBUG]: hey\n[INFO]: hello\n[INFO]: hello hello 25\n[WARN]: greetings\n[ERROR]: salutations\n[FATAL]: goodbye\n";
    const out = try tmpDir.dir.readFileAlloc(testing.allocator, "test", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    if (!std.mem.eql(u8, out, expect)) {
        std.debug.warn("TEST FAILED!\ngot:\n\n{}\n\nexpect:\n\n{}\n", .{ out, expect });
        std.os.exit(1);
    }
}

test "Log with color" {
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();

    var logger = Logger.init(testing.allocator, file, LoggerOptions{
        .color = true,
        .timestamp = false,
        .fileName = false,
        .lineNumber = false,
        .doubleSpacing = false,
    });

    logger.Trace("hi\n", .{});
    logger.Debug("hey\n", .{});
    logger.Info("hello\n", .{});
    logger.Warn("greetings\n", .{});
    logger.Error("salutations\n", .{});
    logger.Fatal("goodbye\n", .{});

    const expect = "\x1b[0m\x1b[36m[DEBUG]\x1b[0m: hey\n\x1b[0m\x1b[32m[INFO]\x1b[0m: hello\n\x1b[0m\x1b[33m[WARN]\x1b[0m: greetings\n\x1b[0m\x1b[31m[ERROR]\x1b[0m: salutations\n\x1b[0m\x1b[35m[FATAL]\x1b[0m: goodbye\n";
    const out = try tmpDir.dir.readFileAlloc(testing.allocator, "test", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    if (!std.mem.eql(u8, out, expect)) {
        std.debug.warn("TEST FAILED!\ngot:\n\n{}\n\nexpect:\n\n{}\n", .{ out, expect });
        std.os.exit(1);
    }
}

fn worker(logger: *Logger) void {
    logger.Trace("hi\n", .{});
    std.time.sleep(10000);
    logger.Debug("hey\n", .{});
    std.time.sleep(10);
    logger.Info("hello\n", .{});
    std.time.sleep(100);
    logger.Warn("greetings\n", .{});
    std.time.sleep(1000);
    logger.Error("salutations\n", .{});
    std.time.sleep(10000);
    logger.Fatal("goodbye\n", .{});
    std.time.sleep(1000000000);
}

test "Log Thread Safe" {
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();
    var logger = Logger.init(testing.allocator, file, LoggerOptions{});

    const thread_count = 5;
    var threads: [thread_count]*std.Thread = undefined;

    for (threads) |*t| {
        t.* = try std.Thread.spawn(&logger, worker);
    }

    for (threads) |t| {
        t.wait();
    }
}

test "Log with Timestamp" {
    // Zig does not have date formatted timestamps in std lib yet
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();

    var logger = Logger.init(testing.allocator, file, LoggerOptions{
        .color = false,
        .timestamp = true,
        .fileName = false,
        .lineNumber = false,
        .doubleSpacing = false,
    });
    var tsBuf: [10]u8 = undefined;
    // If there is slowness between these next two lines, the test will fail
    var ts = try std.fmt.bufPrint(tsBuf[0..], "{}", .{std.time.timestamp()});
    logger.Error("boo!\n", .{});
    const expect = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ ts, " ", "[ERROR]: boo!\n" });
    defer testing.allocator.free(expect);
    const out = try tmpDir.dir.readFileAlloc(testing.allocator, "test", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    if (!std.mem.eql(u8, out, expect)) {
        std.debug.warn("TEST FAILED!\ngot:\n\n{}\n\nexpect:\n\n{}\n", .{ out, expect });
        std.os.exit(1);
    }
}

test "Log with File Name and Line Number" {
    // Zig does not have date formatted timestamps in std lib yet
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();

    var logger = Logger.init(testing.allocator, file, LoggerOptions{
        .color = false,
        .timestamp = false,
        .fileName = true,
        .lineNumber = true,
        .doubleSpacing = false,
    });
    logger.Error("boo!\n", .{});
    // TODO: replace with a regex someday, or use @src()
    const expect = "/src/index.zig:391:17]: boo!\n";
    const out = try tmpDir.dir.readFileAlloc(testing.allocator, "test", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    const inStr = if (std.mem.indexOf(u8, out, expect)) |in| in else 1;
    if (inStr == 0) {
        std.debug.warn("TEST FAILED!\ngot:\n\n{}\nexpect:\n\n{}\n", .{ out, expect });
        std.os.exit(1);
    }
}

test "Log with File Name and Line Number with Double Space" {
    // Zig does not have date formatted timestamps in std lib yet
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();

    var logger = Logger.init(testing.allocator, file, LoggerOptions{
        .color = false,
        .timestamp = false,
        .fileName = true,
        .lineNumber = true,
        .doubleSpacing = true,
    });
    logger.Error("boo!\n", .{});
    // TODO: replace with a regex someday, or use @src()
    const expect = "src/index.zig:420:17]: boo!\n\n";
    const out = try tmpDir.dir.readFileAlloc(testing.allocator, "test", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    const inStr = if (std.mem.indexOf(u8, out, expect)) |in| in else 1;
    if (inStr == 0) {
        std.debug.warn("TEST FAILED!\ngot:\n\n{}\nexpect:\n\n{}\n", .{ out, expect });
        std.os.exit(1);
    }
}

test "Log starts with reset" {
    // Zig does not have date formatted timestamps in std lib yet
    var tmpDir = testing.tmpDir(std.fs.Dir.OpenDirOptions{});
    defer tmpDir.cleanup();
    const file = try tmpDir.dir.createFile("test", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();

    var logger = Logger.init(testing.allocator, file, LoggerOptions{
        .color = true,
        .timestamp = false,
        .fileName = false,
        .lineNumber = false,
        .doubleSpacing = false,
    });
    logger.Error("boo!\n", .{});
    logger.Error("boo2!\n", .{});
    // TODO: replace with a regex someday, or use @src()
    const expect = "\x1b[0m\x1b[31m[ERROR]\x1b[0m: boo!\n\x1b[0m\x1b[31m[ERROR]\x1b[0m: boo2!\n";
    const out = try tmpDir.dir.readFileAlloc(testing.allocator, "test", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    if (!std.mem.eql(u8, out, expect)) {
        std.debug.warn("TEST FAILED!\ngot:\n\n{}\nexpect:\n\n{}\n", .{ out, expect });
        std.os.exit(1);
    }
}
