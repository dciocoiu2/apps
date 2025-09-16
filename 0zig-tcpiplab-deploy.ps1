$root = "tcpip-lab-zig"
$dirs = @(
    "$root/src/net",
    "$root/src/io",
    "$root/src/plugins"
)

foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$files = @{
    "$root/build.zig" = ""
    "$root/src/main.zig" = @'
const std = @import("std");
const NetInterface = @import("io/interface.zig").NetInterface;
const EthernetFrame = @import("net/ethernet.zig").EthernetFrame;
const IPv4Packet = @import("net/ipv4.zig").IPv4Packet;

pub fn main() void {
    const allocator = std.heap.page_allocator;
    var iface = NetInterface.init(allocator, 1500);
    const raw = iface.receive();
    const eth = EthernetFrame.parse(raw);
    if (eth.ethertype == 0x0800) {
        const ip = IPv4Packet.parse(eth.payload);
        _ = ip;
    }
}
'@

    "$root/src/io/interface.zig" = @'
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

    "$root/src/net/ethernet.zig" = @'
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

    "$root/src/net/ipv4.zig" = @'
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

    "$root/src/net/icmp.zig" = @'
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

    "$root/src/net/tcp.zig" = @'
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

    "$root/src/plugins/echo_server.zig" = @'
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

    "$root/src/plugins/config_loader.zig" = @'
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
    EchoServer.handle(packet);
}
';
}

foreach ($path in $files.Keys) {
    Set-Content -Path $path -Value $files[$path] -Encoding UTF8
}

Write-Host "TCP/IP lab deployed at $root"