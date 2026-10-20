# The websocket package's wire format: encoding and decoding frames,
# including the examples of RFC 6455 (section 5.7), each length encoding,
# masking, partial input, and the frames the protocol forbids; and the
# handshake key of RFC 6455 (section 1.3).

import websocket;

bytes_of(values: int[]): u8[] {
    var out = Array<u8>();
    for (var value in values) {
        out.append(value as u8);
    }
    return out;
}

zeros(count: ulong): u8[] {
    var out = Array<u8>();
    out.resize(count, 0);
    return out;
}

# Decodes a whole frame, checking it used every byte.
decode(bytes: u8[]): websocket.Frame {
    var decoded = websocket.decode_frame(bytes, 1 << 20);
    if (decoded.is_err()) {
        print(decoded.error().message);
        panic("decode failed");
    }
    var (frame, used) = decoded.value().value();
    expect_equal(used, bytes.count);
    return frame;
}

error_of(bytes: u8[]): String {
    var decoded = websocket.decode_frame(bytes, 1 << 20);
    expect_true(decoded.is_err());
    return decoded.is_err() ? decoded.error().message : "";
}

[Test]
computes_the_rfc_accept_key() {
    expect_equal(websocket.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

[Test]
encodes_the_rfc_examples() {
    var hello = websocket.Frame(websocket.Opcode.Text, "Hello".bytes());
    expect_true(websocket.encode_frame(hello) == bytes_of([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]));
    var masked = websocket.encode_frame(hello, bytes_of([0x37, 0xfa, 0x21, 0x3d]));
    expect_true(masked == bytes_of([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]));
    var first = websocket.Frame(websocket.Opcode.Text, "Hel".bytes(), false);
    expect_true(websocket.encode_frame(first) == bytes_of([0x01, 0x03, 0x48, 0x65, 0x6c]));
    var rest = websocket.Frame(websocket.Opcode.Continuation, "lo".bytes());
    expect_true(websocket.encode_frame(rest) == bytes_of([0x80, 0x02, 0x6c, 0x6f]));
}

[Test]
decodes_the_rfc_examples() {
    var frame = decode(bytes_of([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]));
    expect_true(frame.fin);
    expect_true(frame.masked);
    expect_true(frame.opcode == websocket.Opcode.Text);
    expect_true(frame.payload == "Hello".bytes());
    var ping = decode(bytes_of([0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]));
    expect_true(ping.opcode == websocket.Opcode.Ping);
    expect_true(ping.is_control());
    expect_false(ping.masked);
    var first = decode(bytes_of([0x01, 0x03, 0x48, 0x65, 0x6c]));
    expect_false(first.fin);
}

[Test]
round_trips_each_length_encoding() {
    # 125 fits the first byte, 126 and 65535 take two more, 65536 eight.
    for (var size in [0 as ulong, 125, 126, 65535, 65536]) {
        var payload = Array<u8>();
        while (payload.count < size) {
            payload.append((payload.count % 251) as u8);
        }
        var frame = websocket.Frame(websocket.Opcode.Binary, payload);
        var plain = websocket.encode_frame(frame);
        var header = size < 126 ? 2 : size <= 65535 ? 4 : 10;
        expect_equal(plain.count, payload.count + header as ulong);
        expect_true(decode(plain).payload == payload);
        var masked = websocket.encode_frame(frame, bytes_of([1, 2, 3, 4]));
        expect_equal(masked.count, payload.count + header as ulong + 4);
        var back = decode(masked);
        expect_true(back.masked);
        expect_true(back.payload == payload);
    }
}

[Test]
waits_for_a_whole_frame() {
    var bytes = websocket.encode_frame(websocket.Frame(websocket.Opcode.Binary, zeros(300)), bytes_of([9, 8, 7, 6]));
    var cut = 0 as ulong;
    while (cut < bytes.count) {
        var partial = bytes.slice(0, cut).to_array();
        var decoded = websocket.decode_frame(partial, 1 << 20);
        expect_true(decoded.is_ok());
        expect_true(decoded.value().is_empty());
        cut = cut + 1;
    }
    # Bytes after the frame are left for the next one.
    bytes.append_all(bytes_of([0x89, 0x00]));
    var (frame, used) = websocket.decode_frame(bytes, 1 << 20).value().value();
    expect_equal(used, bytes.count - 2);
}

[Test]
refuses_forbidden_frames() {
    expect_true(error_of(bytes_of([0xC1, 0x00])).contains("reserved bits"));
    expect_true(error_of(bytes_of([0x83, 0x00])).contains("unknown opcode 3"));
    expect_true(error_of(bytes_of([0x09, 0x00])).contains("fragmented"));
    expect_true(error_of(bytes_of([0x89, 0x7E, 0x00, 0x7E])).contains("more than 125"));
    expect_true(error_of(bytes_of([0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0])).contains("most significant bit"));
    var big = websocket.encode_frame(websocket.Frame(websocket.Opcode.Binary, zeros(11)));
    var decoded = websocket.decode_frame(big, 10);
    expect_true(decoded.is_err());
    expect_true(decoded.error().message.contains("larger than 10 bytes"));
}
