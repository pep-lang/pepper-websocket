## WebSocket frames (RFC 6455, section 5): `Opcode`, `Frame`, and the wire
## format with `encode_frame` and `decode_frame`.

## What a frame carries (RFC 6455, section 5.2).
export enum Opcode: u8 {
    ## A later fragment of a message that a `Text` or `Binary` frame began.
    Continuation = 0,
    ## A UTF-8 text message, or its first fragment.
    Text = 1,
    ## A binary message, or its first fragment.
    Binary = 2,
    ## The closing handshake: an optional status code and reason.
    Close = 8,
    ## A ping, which the peer answers with a `Pong` carrying the same bytes.
    Ping = 9,
    ## The answer to a `Ping`, or an unasked heartbeat.
    Pong = 10,
}

## The most bytes a control frame (`Close`, `Ping`, `Pong`) may carry.
export const MAX_CONTROL_PAYLOAD: ulong = 125;

## One frame: an opcode, the payload, and whether it ends its message.
##
## @example
##     var frame = websocket.Frame(websocket.Opcode.Text, "hi".bytes());
##     var bytes = websocket.encode_frame(frame);   # 81 02 68 69
export struct Frame {
    ## Whether this is the last frame of its message (the FIN bit).
    var fin: bool;
    ## What the frame carries.
    var opcode: Opcode;
    ## The payload, unmasked.
    var payload: u8[];
    ## Whether the frame arrived masked. `decode_frame` sets it;
    ## `encode_frame` masks by its `mask` argument instead.
    var masked: bool;

    ## Creates a frame.
    ##
    ## @param opcode what the frame carries
    ## @param payload the payload, unmasked
    ## @param fin false for a fragment that more frames of its message follow
    construct(opcode: Opcode, payload: u8[], fin: bool = true) {
        this.fin = fin;
        this.opcode = opcode;
        this.payload = payload;
        this.masked = false;
    }

    ## Returns whether this is a control frame: `Close`, `Ping` or `Pong`.
    ##
    ## @returns true for an opcode of 8 or more
    is_control(): bool {
        return (opcode as u8) >= 8;
    }
}

## Encodes `frame` unmasked, as a server sends it.
##
## @param frame the frame to encode
## @returns the frame's bytes: header, then payload
## @example
##     var bytes = websocket.encode_frame(websocket.Frame(websocket.Opcode.Ping, Array<u8>()));
##     # bytes holds 89 00
export encode_frame(frame: Frame): u8[] {
    return _encode(frame, Array<u8>());
}

## Encodes `frame` masked with `mask`, as a client sends it: each payload
## byte is XORed with `mask[i % 4]`.
##
## @param frame the frame to encode
## @param mask the four-byte masking key; a client picks a new random one
##   for each frame
## @returns the frame's bytes: header, masking key, then masked payload
## @panics if `mask` does not hold exactly 4 bytes
export encode_frame(frame: Frame, mask: u8[]): u8[] {
    assert(mask.count == 4, "a masking key is 4 bytes");
    return _encode(frame, mask);
}

# Encodes `frame`, masked when `mask` holds the 4-byte key.
_encode(frame: Frame, mask: u8[]): u8[] {
    var size = frame.payload.count;
    var out = Array<u8>(size + 14);
    out.append(((frame.fin ? 128 : 0) | (frame.opcode as uint)) as u8);
    uint mask_bit = mask.count == 4 ? 128 : 0;
    if (size < 126) {
        out.append((mask_bit | (size as uint)) as u8);
    } else if (size <= 65535) {
        out.append((mask_bit | 126) as u8);
        out.append((size >> 8) as u8);
        out.append(size as u8);
    } else {
        out.append((mask_bit | 127) as u8);
        var shift = 56;
        while (shift >= 0) {
            out.append((size >> (shift as ulong)) as u8);
            shift = shift - 8;
        }
    }
    if (mask_bit == 0) {
        out.append_all(frame.payload);
        return out;
    }
    out.append_all(mask);
    ulong index = 0;
    while (index < size) {
        out.append(frame.payload[index] ^ mask[index % 4]);
        index = index + 1;
    }
    return out;
}

## Decodes the frame at the start of `bytes`.
##
## Checks what RFC 6455 requires of every frame: no reserved bits (this
## package negotiates no extensions), a known opcode, and a control frame
## that is not fragmented and carries at most `MAX_CONTROL_PAYLOAD` bytes.
## Whether a frame must be masked depends on who sent it, so that is left to
## the caller (see `Frame.masked`).
##
## @param bytes the received bytes, starting at a frame
## @param max_payload the largest payload to accept
## @returns the frame and how many bytes of `bytes` it took; Empty when
##   `bytes` does not hold the whole frame yet; an error when the frame
##   breaks the protocol or its payload is over `max_payload`
## @example
##     var bytes = [0x81 as u8, 0x02, 0x68, 0x69];   # "hi", unmasked
##     var (frame, used) = websocket.decode_frame(bytes, 1024).value().value();
##     # frame.opcode == websocket.Opcode.Text, used == 4
export decode_frame(bytes: u8[], max_payload: ulong): Result<(Frame, ulong)?> {
    return _decode_at(bytes, 0, max_payload);
}

# `decode_frame` for the frame at `bytes[start]`.
_decode_at(bytes: u8[], start: ulong, max_payload: ulong): Result<(Frame, ulong)?> {
    var available = bytes.count - start;
    if (available < 2) {
        return Result<(Frame, ulong)?>.ok(Optional<(Frame, ulong)>.Empty);
    }
    var first = bytes[start];
    var second = bytes[start + 1];
    if ((first & 0x70) != 0) {
        return Result<(Frame, ulong)?>.err(Error("a frame sets reserved bits"));
    }
    var opcode = Opcode.from_value((first & 0x0F) as u8);
    if (opcode.is_err()) {
        return Result<(Frame, ulong)?>.err(Error($"unknown opcode {first & 0x0F}"));
    }
    var frame = Frame(opcode.value(), Array<u8>(), (first & 0x80) != 0);
    frame.masked = (second & 0x80) != 0;
    ulong size = (second & 0x7F) as ulong;
    ulong header = 2;
    if (size == 126) {
        header = 4;
    } else if (size == 127) {
        header = 10;
    }
    if (available < header) {
        return Result<(Frame, ulong)?>.ok(Optional<(Frame, ulong)>.Empty);
    }
    if (size >= 126) {
        size = 0;
        ulong index = 2;
        while (index < header) {
            size = (size << 8) | (bytes[start + index] as ulong);
            index = index + 1;
        }
        if (header == 10 && (bytes[start + 2] & 0x80) != 0) {
            return Result<(Frame, ulong)?>.err(Error("a frame length sets its most significant bit"));
        }
    }
    if (frame.is_control()) {
        if (!frame.fin) {
            return Result<(Frame, ulong)?>.err(Error("a control frame is fragmented"));
        }
        if (size > MAX_CONTROL_PAYLOAD) {
            return Result<(Frame, ulong)?>.err(Error("a control frame carries more than 125 bytes"));
        }
    }
    if (size > max_payload) {
        return Result<(Frame, ulong)?>.err(Error($"a message is larger than {max_payload} bytes"));
    }
    if (frame.masked) {
        header = header + 4;
    }
    if (available < header || available - header < size) {
        return Result<(Frame, ulong)?>.ok(Optional<(Frame, ulong)>.Empty);
    }
    var payload = Array<u8>(size);
    var body = start + header;
    ulong index = 0;
    while (index < size) {
        var b = bytes[body + index];
        if (frame.masked) {
            b = b ^ bytes[body - 4 + index % 4];
        }
        payload.append(b);
        index = index + 1;
    }
    frame.payload = payload;
    return Result<(Frame, ulong)?>.ok(Optional<(Frame, ulong)>.Value((frame, header + size)));
}
