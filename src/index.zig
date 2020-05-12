//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");

const io = std.io;
const os = std.os;
const fs = std.fs;
const math = std.math;
const testing = std.testing;

const windows = os.windows;
const posix = os.posix;

const Mutex = std.Mutex;

const TtyColor = enum {
    Red,
    Green,
    Yellow,
    Magenta,
    Cyan,
    Blue,
    Reset,
};

fn Protected(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Mutex,
        private_data: T,

        const HeldMutex = struct {
            value: *T,
            held: Mutex.Held,

            pub fn release(self: HeldMutex) void {
                self.held.release();
            }
        };

        pub fn init(data: T) Self {
            return Self{
                .mutex = Mutex.init(),
                .private_data = data,
            };
        }

        pub fn acquire(self: *Self) HeldMutex {
            return HeldMutex{
                .held = self.mutex.acquire(),
                .value = &self.private_data,
            };
        }
    };
}

const FOREGROUND_BLUE = 1;
const FOREGROUND_GREEN = 2;
const FOREGROUND_AQUA = 3;
const FOREGROUND_RED = 4;
const FOREGROUND_MAGENTA = 5;
const FOREGROUND_YELLOW = 6;

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

    fn color(self: Self) TtyColor {
        return switch (self) {
            Self.Trace => TtyColor.Blue,
            Self.Debug => TtyColor.Cyan,
            Self.Info => TtyColor.Green,
            Self.Warn => TtyColor.Yellow,
            Self.Error => TtyColor.Red,
            Self.Fatal => TtyColor.Magenta,
        };
    }
};

const date_handler = fn (
    log: *Logger,
) void;

fn default_date_handler(log: *Logger) void {
    var out = log.getOutStream();
    var out_held = out.acquire();
    defer out_held.release();
    out_held.value.*.print("{} ", .{std.time.timestamp()}) catch unreachable;
}

/// a simple thread-safe logger
pub const Logger = struct {
    const Self = @This();
    const ProtectedOutStream = Protected(*fs.File.OutStream);

    file: fs.File,
    file_stream: fs.File.OutStream,
    out_stream: ?ProtectedOutStream,
    date: ?date_handler,

    default_attrs: windows.WORD,

    level: Protected(Level),
    quiet: Protected(bool),
    use_color: bool,
    use_bright: bool,

    fn set_date_handler(self: *Self, func: date_handler) void {
        self.date = func;
    }

    /// create `Logger`.
    pub fn new(file: fs.File, use_color: bool) Self {
        // TODO handle error
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (std.Target.current.os.tag == .windows) {
            _ = windows.kernel32.GetConsoleScreenBufferInfo(file.handle, &info);
        }
        return Self{
            .file = file,
            .file_stream = file.outStream(),
            .out_stream = null,
            .date = null,
            .level = Protected(Level).init(Level.Trace),
            .quiet = Protected(bool).init(false),
            .default_attrs = info.wAttributes,
            .use_color = use_color,
            .use_bright = true,
        };
    }

    // can't be done in `Logger.new` because of no copy-elision
    fn getOutStream(self: *Self) ProtectedOutStream {
        if (self.out_stream) |out_stream| {
            return out_stream;
        } else {
            self.out_stream = ProtectedOutStream.init(&self.file_stream);
            return self.out_stream.?;
        }
    }

    fn getDateHandler(self: *Self) date_handler {
        if (self.date) |date| {
            return date;
        } else {
            self.date = default_date_handler;
            return self.date.?;
        }
    }

    fn setTtyColorWindows(self: *Self, color: TtyColor) void {
        // TODO handle errors
        const bright = if (self.use_bright) windows.FOREGROUND_INTENSITY else u16(0);
        _ = windows.SetConsoleTextAttribute(self.file.handle, switch (color) {
            TtyColor.Red => FOREGROUND_RED | bright,
            TtyColor.Green => FOREGROUND_GREEN | bright,
            TtyColor.Yellow => FOREGROUND_YELLOW | bright,
            TtyColor.Magenta => FOREGROUND_MAGENTA | bright,
            TtyColor.Cyan => FOREGROUND_AQUA | bright,
            TtyColor.Blue => FOREGROUND_BLUE | bright,
            TtyColor.Reset => self.default_attrs,
        });
    }

    fn setTtyColor(self: *Self, color: TtyColor) !void {
        if (std.Target.current.os.tag == .windows and !os.supportsAnsiEscapeCodes(self.file.handle)) {
            self.setTtyColorWindows(color);
        } else {
            var out = self.getOutStream();
            var out_held = out.acquire();
            defer out_held.release();

            const bright = if (self.use_bright) "\x1b[1m" else "";

            return switch (color) {
                TtyColor.Red => out_held.value.*.print("{}\x1b[31m", .{bright}),
                TtyColor.Green => out_held.value.*.print("{}\x1b[32m", .{bright}),
                TtyColor.Yellow => out_held.value.*.print("{}\x1b[33m", .{bright}),
                TtyColor.Magenta => out_held.value.*.print("{}\x1b[35m", .{bright}),
                TtyColor.Cyan => out_held.value.*.print("{}\x1b[36m", .{bright}),
                TtyColor.Blue => out_held.value.*.print("{}\x1b[34m", .{bright}),
                TtyColor.Reset => blk: {
                    _ = try out_held.value.*.write("\x1b[0m");
                },
            };
        }
    }

    /// enable or disable color.
    pub fn setColor(self: *Self, use_color: bool) void {
        self.use_color = use_color;
    }

    /// enable or disable bright versions of the colors.
    pub fn setBright(self: *Self, use_bright: bool) void {
        self.use_bright = use_bright;
    }

    /// Set the minimum logging level.
    pub fn setLevel(self: *Self, level: Level) void {
        var held = self.level.acquire();
        defer held.release();
        held.value.* = level;
    }

    /// Outputs to stderr if true. true by default.
    pub fn setQuiet(self: *Self, quiet: bool) void {
        var held = self.quiet.acquire();
        defer held.release();
        held.value.* = quiet;
    }

    /// General purpose log function.
    pub fn log(self: *Self, level: Level, comptime fmt: []const u8, args: var) !void {
        const level_held = self.level.acquire();
        defer level_held.release();

        if (@enumToInt(level) < @enumToInt(level_held.value.*)) {
            return;
        }

        var out = self.getOutStream();
        var date = self.getDateHandler();
        var out_held = out.acquire();
        defer out_held.release();
        var out_stream = out_held.value.*;

        const quiet_held = self.quiet.acquire();
        defer quiet_held.release();

        // TODO get filename and number
        // TODO get time as a string
        // time includes the year

        if (!quiet_held.value.*) {
            date(self);
            if (self.use_color and self.file.isTty()) {
                // try out_stream.print("{} ", .{date(self)});
                try self.setTtyColor(level.color());
                try out_stream.print("[{}]", .{level.toString()});
                try self.setTtyColor(TtyColor.Reset);
                try out_stream.print(": ", .{});
                // out_stream.print("\x1b[90m{}:{}:", filename, line);
                // self.resetTtyColor();
            } else {
                try out_stream.print("[{s}]: ", .{level.toString()});
            }
            if (args.len > 0) {
                out_stream.print(fmt, args) catch return;
            } else {
                _ = out_stream.write(fmt) catch return;
                _ = out_stream.write("\n") catch return;
            }
        }
    }

    /// log at level `Level.Trace`.
    pub fn Trace(self: *Self, comptime str: []const u8) void {
        self.log(Level.Trace, str, .{}) catch return;
    }

    /// log at level `Level.Debug`.
    pub fn Debug(self: *Self, comptime str: []const u8) void {
        self.log(Level.Debug, str, .{}) catch return;
    }

    /// log at level `Level.Info`.
    pub fn Info(self: *Self, comptime str: []const u8) void {
        self.log(Level.Info, str, .{}) catch return;
    }

    /// log at level `Level.Warn`.
    pub fn Warn(self: *Self, comptime str: []const u8) void {
        self.log(Level.Warn, str, .{}) catch return;
    }

    /// log at level `Level.Error`.
    pub fn Error(self: *Self, comptime str: []const u8) void {
        self.log(Level.Error, str, .{}) catch return;
    }

    /// log at level `Level.Fatal`.
    pub fn Fatal(self: *Self, comptime str: []const u8) void {
        self.log(Level.Fatal, str, .{}) catch return;
    }

    /// log at level `Level.Tracef`.
    pub fn Tracef(self: *Self, comptime fmt: []const u8, args: var) void {
        self.log(Level.Trace, fmt, args) catch return;
    }

    /// log at level `Level.Debugf`.
    pub fn Debugf(self: *Self, comptime fmt: []const u8, args: var) void {
        self.log(Level.Debug, fmt, args) catch return;
    }

    /// log at level `Level.Infof`.
    pub fn Infof(self: *Self, comptime fmt: []const u8, args: var) void {
        self.log(Level.Info, fmt, args) catch return;
    }

    /// log at level `Level.Warnf`.
    pub fn Warnf(self: *Self, comptime fmt: []const u8, args: var) void {
        self.log(Level.Warn, fmt, args) catch return;
    }

    /// log at level `Level.Errorf`.
    pub fn Errorf(self: *Self, comptime fmt: []const u8, args: var) void {
        self.log(Level.Error, fmt, args) catch return;
    }

    /// log at level `Level.Fatalf`.
    pub fn Fatalf(self: *Self, comptime fmt: []const u8, args: var) void {
        self.log(Level.Fatal, fmt, args) catch return;
    }
};

test "log_with_color" {
    var logger = Logger.new(io.getStdOut(), true);
    logger.Trace("hi");
    logger.Debug("hey");
    logger.Info("hello");
    const world = "world";
    const num = 12345;
    logger.Infof("hello {} {}\n", .{ world, num });
    logger.Warn("greetings");
    logger.Error("salutations");
    logger.Fatal("goodbye");
}

fn worker(logger: *Logger) void {
    logger.Trace("hi");
    std.time.sleep(10000);
    logger.Debug("hey");
    std.time.sleep(10);
    logger.Info("hello");
    std.time.sleep(100);
    logger.Warn("greetings");
    std.time.sleep(1000);
    logger.Error("salutations");
    std.time.sleep(10000);
    logger.Fatal("goodbye");
    std.time.sleep(1000000000);
}

test "log_thread_safe" {
    var logger = Logger.new(io.getStdOut(), true);
    std.debug.warn("\n", .{});

    const thread_count = 5;
    var threads: [thread_count]*std.Thread = undefined;

    for (threads) |*t| {
        t.* = try std.Thread.spawn(&logger, worker);
    }

    for (threads) |t| {
        t.wait();
    }
}

fn date_handler_test(log: *Logger) void {
    _ = log.file_stream.write("foo ") catch unreachable;
}

test "log_date_handler" {
    const file = try std.fs.cwd().createFile("test_temp", .{
        .mode = 0o755,
        .truncate = true,
    });
    defer file.close();
    var logger = Logger.new(file, true);
    logger.set_date_handler(date_handler_test);
    logger.Error("boo!");
    const expect = "foo [ERROR]: boo!\n";
    const out = try fs.cwd().readFileAlloc(testing.allocator, "test_temp", math.maxInt(usize));
    defer std.testing.allocator.free(out);
    std.debug.warn("\ngot: '{}'\nexp: '{}'\n", .{ out, expect });
    testing.expect(std.mem.eql(u8, out, expect));
    _ = std.fs.cwd().deleteFile("test_temp") catch unreachable;
}
