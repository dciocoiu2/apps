$root = "tcpip-lab-zig"
$dirs = @(
    "$root/src/net",
    "$root/src/io",
    "$root/src/plugins",
    "$root/src/test"
)

foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

function Write-ZigFile($path, $content) {
    Set-Content -Path $path -Value $content -Encoding UTF8
}

# build.zig
Write-ZigFile "$root/build.zig" @'
const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("stack", "src/main.zig");
    exe.setBuildMode(mode);
    exe.install();
}
'@

# main.zig
Write-ZigFile "$root/src/main.zig" @'
const std = @import("std");
const injectEchoPacket = @import("io/injector.zig").injectEchoPacket;
const dispatch = @import("net/router.zig").dispatch;
const fuzz = @import("test/fuzz.zig").fuzz;
const metrics = @import("net/router.zig").metrics;

pub fn main() void {
    const allocator = std.heap.page_allocator;
    const echo = injectEchoPacket(allocator);
    dispatch(echo);
    allocator.free(echo);
    fuzz(allocator, 1000);
    const stdout = std.io.getStdOut().writer();
    metrics.toJson(stdout) catch unreachable;
    stdout.writeByte(0x0A) catch unreachable;
}
'@

# io/interface.zig
Write-ZigFile "$root/src/io/interface.zig" @'
const std = @import("std");

pub const NetInterface = struct {
    allocator: *std.mem.Allocator,
    buffer: []u8,

    pub fn init(allocator: *std.mem.Allocator, size: usize) NetInterface {
        return NetInterface{
            .allocator = allocator,
            .buffer = allocator.alloc(u8, size) catch unreachable,
        };
    }

    pub fn send(self: *NetInterface, packet: []u8) void {
        std.mem.copy(u8, self.buffer[0..packet.len], packet);
    }

    pub fn receive(self: *NetInterface) []u8 {
        return self.buffer;
    }
};
'@

# io/injector.zig
Write-ZigFile "$root/src/io/injector.zig" @'
const std = @import("std");

pub fn injectEchoPacket(allocator: *std.mem.Allocator) []u8 {
    const packet = allocator.alloc(u8, 64) catch unreachable;
    packet[0..6] = [_]u8{0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
    packet[6..12] = [_]u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
    packet[12] = 0x08;
    packet[13] = 0x00;
    packet[14..34] = [_]u8{
        0x45,0x00,0x00,0x30,0x00,0x00,0x40,0x00,
        0x40,0x06,0x00,0x00,10,0,0,1,10,0,0,2
    };
    packet[34..54] = [_]u8{
        0x15,0xb3,0x15,0xb3,0x00,0x00,0x00,0x01,
        0x00,0x00,0x00,0x00,0x50,0x18,0x72,0x10,
        0x00,0x00,0x00,0x00
    };
    packet[54..64] = [_]u8{69,99,104,111,32,76,97,98,10,0};
    return packet;
}
'@

# net/ethernet.zig
Write-ZigFile "$root/src/net/ethernet.zig" @'
const std = @import("std");

pub const EthernetFrame = struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,
    payload: []u8,

    pub fn parse(buf: []u8) EthernetFrame {
        return EthernetFrame{
            .dst_mac = buf[0..6].*,
            .src_mac = buf[6..12].*,
            .ethertype = @as(u16, buf[12]) << 8 | buf[13],
            .payload = buf[14..],
        };
    }
};
'@

# net/ipv4.zig
Write-ZigFile "$root/src/net/ipv4.zig" @'
const std = @import("std");

pub const IPv4Packet = struct {
    version: u4,
    ihl: u4,
    total_length: u16,
    protocol: u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    payload: []u8,

    pub fn parse(buf: []u8) IPv4Packet {
        const version_ihl = buf[0];
        return IPv4Packet{
            .version = @truncate(u4, version_ihl >> 4),
            .ihl = @truncate(u4, version_ihl & 0x0F),
            .total_length = @as(u16, buf[2]) << 8 | buf[3],
            .protocol = buf[9],
            .src_ip = buf[12..16].*,
            .dst_ip = buf[16..20].*,
            .payload = buf[20..],
        };
    }
};
'@

# net/icmp.zig
Write-ZigFile "$root/src/net/icmp.zig" @'
const std = @import("std");

pub const ICMPPacket = struct {
    type: u8,
    code: u8,
    checksum: u16,
    payload: []u8,

    pub fn parse(buf: []u8) ICMPPacket {
        return ICMPPacket{
            .type = buf[0],
            .code = buf[1],
            .checksum = @as(u16, buf[2]) << 8 | buf[3],
            .payload = buf[4..],
        };
    }

    pub fn is_echo_request(self: ICMPPacket) bool {
        return self.type == 8 and self.code == 0;
    }
};
'@

# net/tcp.zig
Write-ZigFile "$root/src/net/tcp.zig" @'
const std = @import("std");

pub const TCPPacket = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    payload: []u8,

    pub fn parse(buf: []u8) TCPPacket {
        return TCPPacket{
            .src_port = @as(u16, buf[0]) << 8 | buf[1],
            .dst_port = @as(u16, buf[2]) << 8 | buf[3],
            .seq = (@as(u32, buf[4]) << 24) | (@as(u32, buf[5]) << 16) | (@as(u32, buf[6]) << 8) | buf[7],
            .ack = (@as(u32, buf[8]) << 24) | (@as(u32, buf[9]) << 16) | (@as(u32, buf[10]) << 8) | buf[11],
            .flags = buf[13] & 0x3F,
            .payload = buf[20..],
        };
    }

    pub fn is_syn(self: TCPPacket) bool {
        return (self.flags & 0x02) != 0;
    }

    pub fn is_ack(self: TCPPacket) bool {
        return (self.flags & 0x10) != 0;
    }

    pub fn is_psh(self: TCPPacket) bool {
        return (self.flags & 0x08) != 0;
    }
};
'@

# net/metrics.zig
Write-ZigFile "$root/src/net/metrics.zig" @'
const std = @import("std");

pub const ProtocolMetrics = struct {
    ethernet: usize = 0,
    ipv4: usize = 0,
    tcp: usize = 0,
    icmp: usize = 0,

    pub fn reset(self: *ProtocolMetrics) void {
        self.* = ProtocolMetrics{};
    }

    pub fn toJson(self: *ProtocolMetrics, writer: anytype) !void {
        try writer.print("{{\"ethernet\":{},\"ipv4\":{},\"tcp\":{},\"icmp\":{}}}", .{
            self.ethernet, self.ipv4, self.tcp, self.icmp
        });
    }
};
'@

# net/logger.zig
Write-ZigFile "$root/src/net/logger.zig" @'
const std = @import("std");

pub const Logger = struct {
    enabled: bool = true,

    pub fn log(self: *Logger, msg: []const u8) void {
        if (self.enabled) {
            std.debug.print("LOG: {s}\n", .{msg});
        }
    }
};
'@

# net/router.zig
Write-ZigFile "$root/src/net/router.zig" @'
const std = @import("std");
const EthernetFrame = @import("ethernet.zig").EthernetFrame;
const IPv4Packet = @import("ipv4.zig").IPv4Packet;
const TCPPacket = @import("tcp.zig").TCPPacket;
const loadPlugins = @import("../plugins/config_loader.zig").loadPlugins;
const ProtocolMetrics = @import("metrics.zig").ProtocolMetrics;
const Logger = @import("logger.zig").Logger;

pub var metrics = ProtocolMetrics{};
pub var logger = Logger{};

pub fn dispatch(packet: []u8) void {
    metrics.ethernet += 1;
    const eth = EthernetFrame.parse(packet);
    if (eth.ethertype != 0x0800) return;
    metrics.ipv4 += 1;
    const ip = IPv4Packet.parse(eth.payload);
    if (ip.protocol == 1) metrics.icmp += 1;
    if (ip.protocol == 6) {
        metrics.tcp += 1;
        const tcp = TCPPacket.parse(ip.payload);
        logger.log("Dispatching TCP packet");
        const plugins = loadPlugins();
        for (plugins) |plugin| {
            plugin.handler(ip.payload);
        }
    }
}
'@

# plugins/echo_server.zig
Write-ZigFile "$root/src/plugins/echo_server.zig" @'
const std = @import("std");
const TCPPacket = @import("../net/tcp.zig").TCPPacket;

pub const EchoServer = struct {
    pub fn handle(packet: TCPPacket) void {
        if (packet.is_psh()) {
            std.debug.print("Echo: {s}\n", .{packet.payload});
        }
    }
};
'@

# plugins/config_loader.zig
Write-ZigFile "$root/src/plugins/config_loader.zig" @'
const std = @import("std");

pub const Plugin = struct {
    name: []const u8,
    handler: fn([]u8) void,
};

pub fn loadPlugins() []Plugin {
    return &[_]Plugin{
        Plugin{
            .name = "echo",
            .handler = echoHandler,
        },
    };
}

fn echoHandler(buf: []u8) void {
    const TCPPacket = @import("../net/tcp.zig").TCPPacket;
    const EchoServer = @import("echo_server.zig").EchoServer;
    const packet = TCPPacket.parse(buf);
    const start = std.time.nanoTimestamp();
    EchoServer.handle(packet);
    const end = std.time.nanoTimestamp();
    const elapsed = end - start;
    std.debug.print("Plugin echo executed in {} ns\n", .{elapsed});
}
'@

# test/fuzz.zig
Write-ZigFile "$root/src/test/fuzz.zig" @'
const std = @import("std");
const dispatch = @import("../net/router.zig").dispatch;
const ProtocolMetrics = @import("../net/metrics.zig").ProtocolMetrics;

pub fn fuzz(allocator: *std.mem.Allocator, iterations: usize) void {
    var prng = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));
    const rand = prng.random();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const size = rand.intRangeLessThan(usize, 40, 1500);
        const packet = allocator.alloc(u8, size) catch unreachable;
        for (packet) |*b| { b.* = rand.int(u8); }
        dispatch(packet);
        allocator.free(packet);
    }
    const metrics = @import("../net/router.zig").metrics;
    const stdout = std.io.getStdOut().writer();
    metrics.toJson(stdout) catch unreachable;
    stdout.writeByte(0x0A) catch unreachable;
}
'@

Write-Host "TCP/IP lab deployed at $root with structured metrics, plugin profiling, injector, router, and fuzz harness"