## A WebSocket connection: `WebSocket`, opened by `connect` (a client) or
## `accept` (a server), and the `Message`s it sends and receives.

import base64;
import http;
import io;
import random;
import text;
import tls;
import "frame";
import "handshake";

## The largest message a `WebSocket` receives by default: 16 MiB.
export const DEFAULT_MAX_MESSAGE_SIZE: ulong = 16777216;

## The status code of a normal close (RFC 6455, section 7.4.1).
export const CLOSE_NORMAL: int = 1000;
## The status code of an endpoint going away, such as a server shutting down.
export const CLOSE_GOING_AWAY: int = 1001;
## The status code of a protocol error.
export const CLOSE_PROTOCOL_ERROR: int = 1002;
## The status code of a message of a type the endpoint does not accept.
export const CLOSE_UNSUPPORTED_DATA: int = 1003;
## The code a `Message` reports for a close frame that carried no code; it
## is never sent.
export const CLOSE_NO_STATUS: int = 1005;
## The status code of a text message that is not valid UTF-8.
export const CLOSE_INVALID_DATA: int = 1007;
## The status code of a message that breaks the endpoint's policy.
export const CLOSE_POLICY_VIOLATION: int = 1008;
## The status code of a message over the endpoint's size limit.
export const CLOSE_TOO_BIG: int = 1009;
## The status code of a server failing on an unexpected condition.
export const CLOSE_INTERNAL_ERROR: int = 1011;

## A message a `WebSocket` received: text, binary, or the peer's close.
##
## A message split into fragments arrives whole. For a `Close`,
## `close_code` and `text()` say why the peer closed.
export struct Message {
    ## `Opcode.Text`, `Opcode.Binary`, or `Opcode.Close`.
    var opcode: Opcode;
    ## The message's bytes; for a `Close`, the reason's UTF-8 bytes.
    var data: u8[];
    ## For a `Close`, the peer's status code (`CLOSE_NO_STATUS` when it gave
    ## none); 0 otherwise.
    var close_code: int;

    ## Creates a message.
    ##
    ## @param opcode `Opcode.Text`, `Opcode.Binary`, or `Opcode.Close`
    ## @param data the message's bytes
    ## @param close_code the peer's status code, for a `Close`
    construct(opcode: Opcode, data: u8[], close_code: int = 0) {
        this.opcode = opcode;
        this.data = data;
        this.close_code = close_code;
    }

    ## Returns whether this is a text message.
    ##
    ## @returns true for `Opcode.Text`
    is_text(): bool {
        return opcode == Opcode.Text;
    }

    ## Returns whether this is a binary message.
    ##
    ## @returns true for `Opcode.Binary`
    is_binary(): bool {
        return opcode == Opcode.Binary;
    }

    ## Returns whether this is the peer's close, after which the connection
    ## is closed.
    ##
    ## @returns true for `Opcode.Close`
    is_close(): bool {
        return opcode == Opcode.Close;
    }

    ## Returns `data` as text: the message of a text message, or the reason
    ## of a close. A `WebSocket` checks both are valid UTF-8.
    ##
    ## @returns the text; a byte of a binary message that is not valid UTF-8
    ##   becomes U+FFFD
    text(): String {
        return _text_of(data);
    }
}

## One WebSocket connection (RFC 6455), as a client (`connect`) or a server
## (`accept`), over TCP or TLS.
##
## `receive` returns the next text or binary message whole, joining
## fragments, answering pings, and skipping pongs; when the peer closes, it
## answers the close and returns a `Close` message. `send_text`,
## `send_binary` and `ping` send; `close` runs the closing handshake. A
## frame that breaks the protocol, an invalid UTF-8 text, or a message over
## `max_message_size` closes the connection with the matching status code
## and makes `receive` return an error.
##
## A connection belongs to one task at a time: use it from the task that
## opened it, or hand it over. In a task of `async.run`, a call that waits
## parks only the task.
##
## @example
##     import websocket;
##
##     main(): int {
##         var socket = websocket.WebSocket.connect("ws://localhost:8080/chat").value();
##         socket.send_text("hello");
##         var reply = socket.receive().value();
##         print(reply.text());
##         socket.close();
##         return 0;
##     }
export struct WebSocket {
    ## The opening handshake's request: on a server, the client's (its
    ## `url` is the target, such as `/chat?room=1`, and its headers hold
    ## `Origin`, `Sec-WebSocket-Protocol` and the like); on a client, the one
    ## it sent.
    var request: http.Request;
    ## The largest message `receive` accepts; a larger one closes the
    ## connection with `CLOSE_TOO_BIG`.
    var max_message_size: ulong;
    # The connection: reads and writes go through `_reader` and `_writer`,
    # the TLS stream when there is one and `_tcp` otherwise.
    var _tcp: io.TcpStream;
    var _tls: tls.TlsStream?;
    var _reader: io.Reader;
    var _writer: io.Writer;
    # A client masks what it sends; a server requires masked frames.
    var _client: bool;
    # Bytes read but not consumed start at `_start`.
    var _buffer: u8[];
    var _start: ulong;
    # Whether a close frame was sent, and whether the stream is closed.
    var _close_sent: bool;
    var _closed: bool;

    ## Wraps a connected stream that has finished no handshake. Use
    ## `connect` or `accept`.
    ##
    ## @param tcp the TCP connection
    ## @param stream the TLS stream over `tcp`, or Empty for plain TCP
    ## @param client true for the client end
    construct(tcp: io.TcpStream, stream: tls.TlsStream?, client: bool) {
        this.request = http.Request();
        this.max_message_size = DEFAULT_MAX_MESSAGE_SIZE;
        this._tcp = tcp;
        this._tls = stream;
        this._reader = tcp;
        this._writer = tcp;
        if (stream.is_value()) {
            this._reader = stream.value();
            this._writer = stream.value();
        }
        this._client = client;
        this._buffer = Array<u8>();
        this._start = 0;
        this._close_sent = false;
        this._closed = false;
    }

    ## Opens a connection to `url`, a `ws://` or `wss://` URL, and runs the
    ## opening handshake. `wss://` checks the server's certificate against
    ## the system's root certificates.
    ##
    ## @param url the server's URL, such as `wss://example.com/chat`
    ## @returns the open connection; an error when the URL is not a
    ##   WebSocket URL, the connection fails, or the server refuses the
    ##   upgrade
    static connect(url: String): Result<WebSocket> {
        if (url.lower().starts_with("wss:")) {
            var connector = tls.TlsConnector.create();
            if (connector.is_err()) {
                return Result<WebSocket>.err(Error(connector.error().message));
            }
            return WebSocket._connect(url, Optional<tls.TlsConnector>.Value(connector.value()));
        }
        return WebSocket._connect(url, Optional<tls.TlsConnector>.Empty);
    }

    ## Opens a connection to `url` and runs the opening handshake, using
    ## `connector` for `wss://`, such as one that trusts a private
    ## certificate authority.
    ##
    ## @param url the server's URL, such as `wss://example.com/chat`
    ## @param connector the TLS connector for `wss://`; unused for `ws://`
    ## @returns the open connection; an error when the URL is not a
    ##   WebSocket URL, the connection fails, or the server refuses the
    ##   upgrade
    static connect(url: String, connector: tls.TlsConnector): Result<WebSocket> {
        return WebSocket._connect(url, Optional<tls.TlsConnector>.Value(connector));
    }

    # `connect`, with the connector for `wss://` when there is one.
    static _connect(url: String, connector: tls.TlsConnector?): Result<WebSocket> {
        var parsed = Uri.parse(url);
        if (parsed.is_err()) {
            return Result<WebSocket>.err(parsed.error());
        }
        var uri = parsed.value();
        var secure = uri.scheme == "wss";
        if ((secure && connector.is_empty())
            || (!secure && uri.scheme != "ws")
            || uri.host.is_empty()
            || uri.host.value().is_empty) {
            return Result<WebSocket>.err(Error($"not a ws:// or wss:// URL: '{url}'"));
        }
        var host = uri.host.value();
        u16 port = secure ? 443 : 80;
        var authority = host.contains(":") ? $"[{host}]" : host;
        if (uri.port.is_value()) {
            port = uri.port.value();
            authority = $"{authority}:{port}";
        }
        var tcp = io.TcpStream.connect_host(host, port);
        if (tcp.is_err()) {
            return Result<WebSocket>.err(Error(tcp.error().message));
        }
        var stream = Optional<tls.TlsStream>.Empty;
        if (secure) {
            var handshake = connector.value().connect(tcp.value(), host);
            if (handshake.is_err()) {
                tcp.value().close();
                return Result<WebSocket>.err(Error(handshake.error().message));
            }
            stream = Optional<tls.TlsStream>.Value(handshake.value());
        }
        var socket = WebSocket(tcp.value(), stream, true);
        var opened = socket._open(authority, uri.path_and_query());
        if (opened.is_err()) {
            socket._close_stream();
            return Result<WebSocket>.err(opened.error());
        }
        return Result<WebSocket>.ok(socket);
    }

    ## Runs the server's side of the opening handshake on a connection a
    ## listener accepted: reads the client's upgrade request and answers it
    ## with `101 Switching Protocols`.
    ##
    ## A request that is not a valid upgrade is answered with `400 Bad
    ## Request` (or `426 Upgrade Required` for a version other than 13), and
    ## the connection is closed.
    ##
    ## @param tcp the accepted connection
    ## @returns the open connection, whose `request` is the client's; an
    ##   error when the request is not a valid upgrade or the connection
    ##   fails
    ## @example
    ##     var listener = io.TcpListener.bind(io.SocketAddress.parse("0.0.0.0:8080").value()).value();
    ##     var (tcp, peer) = listener.accept().value();
    ##     var socket = websocket.WebSocket.accept(tcp).value();
    ##     var message = socket.receive().value();
    ##     socket.send_text("you said " + message.text());
    static accept(tcp: io.TcpStream): Result<WebSocket> {
        return WebSocket(tcp, Optional<tls.TlsStream>.Empty, false)._accept();
    }

    ## Runs the server's side of the opening handshake on a TLS connection
    ## (`wss://`) that a `tls.TlsAcceptor` accepted. See `accept(tcp)`.
    ##
    ## @param tcp the accepted TCP connection
    ## @param stream the TLS stream over `tcp`
    ## @returns the open connection, whose `request` is the client's; an
    ##   error when the request is not a valid upgrade or the connection
    ##   fails
    static accept(tcp: io.TcpStream, stream: tls.TlsStream): Result<WebSocket> {
        return WebSocket(tcp, Optional<tls.TlsStream>.Value(stream), false)._accept();
    }

    ## Returns whether the connection is still open: no close was sent or
    ## received and no error closed it.
    ##
    ## @returns true until the closing handshake starts or the connection fails
    is_open(): bool {
        return !_closed && !_close_sent;
    }

    ## Sends a text message in one frame.
    ##
    ## @param message the text
    ## @returns an Ok result once it is written; an error when the
    ##   connection is closed or the write fails
    send_text(message: String): Result<void> {
        return send_frame(Frame(Opcode.Text, message.bytes()));
    }

    ## Sends a binary message in one frame.
    ##
    ## @param data the bytes
    ## @returns an Ok result once it is written; an error when the
    ##   connection is closed or the write fails
    send_binary(data: u8[]): Result<void> {
        return send_frame(Frame(Opcode.Binary, data));
    }

    ## Sends a ping; the peer answers with a pong, which `receive` skips.
    ##
    ## @param data at most `MAX_CONTROL_PAYLOAD` bytes for the pong to echo
    ## @returns an Ok result once it is written; an error when the
    ##   connection is closed, `data` is too long, or the write fails
    ping(data: u8[]): Result<void> {
        return send_frame(Frame(Opcode.Ping, data));
    }

    ## Sends one frame as it is, masked on a client. To send a message in
    ## fragments, send a `Text` or `Binary` frame with `fin` false, then
    ## `Continuation` frames, the last with `fin` true; control frames may
    ## go between them.
    ##
    ## @param frame the frame to send
    ## @returns an Ok result once it is written; an error when the
    ##   connection is closed, a control frame is fragmented or carries more
    ##   than `MAX_CONTROL_PAYLOAD` bytes, or the write fails
    send_frame(frame: Frame): Result<void> {
        if (!is_open()) {
            return Result<void>.err(Error("the connection is closed"));
        }
        if (frame.is_control() && (!frame.fin || frame.payload.count > MAX_CONTROL_PAYLOAD)) {
            return Result<void>.err(Error("a control frame must be one frame of at most 125 bytes"));
        }
        return _write(frame);
    }

    ## Receives the next text or binary message, or the peer's close.
    ##
    ## Answers each ping with a pong and skips pongs on the way. When the
    ## peer closes, it answers with a close, closes the connection, and
    ## returns a `Close` message.
    ##
    ## @returns the message; an error when the connection is closed, ends
    ##   without a close, or the peer breaks the protocol (which closes it
    ##   with the matching status code)
    receive(): Result<Message> {
        if (_closed) {
            return Result<Message>.err(Error("the connection is closed"));
        }
        # The message being joined from fragments, if any.
        var joining = false;
        var kind = Opcode.Text;
        var data = Array<u8>();
        while (true) {
            var next = _next_frame(max_message_size - data.count);
            if (next.is_err()) {
                var message = next.error().message;
                var code = message.contains("larger than") ? CLOSE_TOO_BIG : CLOSE_PROTOCOL_ERROR;
                return _fail(code, message);
            }
            var frame = next.value();
            if (frame.masked == _client) {
                return _fail(
                    CLOSE_PROTOCOL_ERROR,
                    _client ? "the server sent a masked frame" : "the client sent an unmasked frame"
                );
            }
            match (frame.opcode) {
                Opcode.Ping => {
                    if (!_close_sent) {
                        _write(Frame(Opcode.Pong, frame.payload));
                    }
                }
                Opcode.Pong => {}
                Opcode.Close => {
                    return _closed_by_peer(frame.payload);
                }
                Opcode.Continuation => {
                    if (!joining) {
                        return _fail(CLOSE_PROTOCOL_ERROR, "a continuation frame with no message to continue");
                    }
                    data.append_all(frame.payload);
                    if (frame.fin) {
                        return _deliver(kind, data);
                    }
                }
                else => {
                    if (joining) {
                        return _fail(CLOSE_PROTOCOL_ERROR, "a new message began before the last one ended");
                    }
                    if (frame.fin) {
                        return _deliver(frame.opcode, frame.payload);
                    }
                    joining = true;
                    kind = frame.opcode;
                    data = frame.payload;
                }
            }
        }
        return Result<Message>.err(Error("unreachable"));
    }

    ## Runs the closing handshake: sends a close with `code` and `reason`,
    ## reads until the peer's close (dropping any messages still on the
    ## way), and closes the connection. Closing a closed connection does
    ## nothing.
    ##
    ## @param code the status code, such as `CLOSE_NORMAL`
    ## @param reason why, in at most 123 bytes of UTF-8
    ## @returns an Ok result once the connection is closed; an error when
    ##   writing the close fails or the peer ends the connection without one
    close(code: int = CLOSE_NORMAL, reason: String = ""): Result<void> {
        if (_closed) {
            return Result<void>.ok();
        }
        if (!_close_sent) {
            var sent = _send_close(code, reason);
            if (sent.is_err()) {
                _close_stream();
                return sent;
            }
        }
        while (!_closed) {
            var next = _next_frame(max_message_size);
            if (next.is_err()) {
                _close_stream();
                return Result<void>.err(next.error());
            }
            if (next.value().opcode == Opcode.Close) {
                _close_stream();
            }
        }
        return Result<void>.ok();
    }

    # Sends the client's upgrade request and checks the server's answer.
    _open(authority: String, target: String): Result<void> {
        var key = base64.encode(random.bytes(16));
        request = _client_request(authority, target, key);
        var written = _writer.write_all(_request_bytes(request));
        if (written.is_err()) {
            return Result<void>.err(Error(written.error().message));
        }
        var head = _read_head();
        if (head.is_err()) {
            return Result<void>.err(head.error());
        }
        return _check_response(head.value(), key);
    }

    # Reads the client's upgrade request and answers it.
    _accept(): Result<WebSocket> {
        var head = _read_head();
        if (head.is_err()) {
            _close_stream();
            return Result<WebSocket>.err(head.error());
        }
        var parsed = _parse_request(head.value());
        if (parsed.is_err()) {
            var (status, message) = parsed.error();
            _writer.write_all(_refusal(status, message));
            _close_stream();
            return Result<WebSocket>.err(Error(message));
        }
        request = parsed.value();
        var written = _writer.write_all(_accept_response(request));
        if (written.is_err()) {
            _close_stream();
            return Result<WebSocket>.err(Error(written.error().message));
        }
        return Result<WebSocket>.ok(this);
    }

    # Reads an HTTP head up to its empty line and returns its lines; the
    # bytes after it stay in the buffer for the first frames.
    _read_head(): Result<String[]> {
        ulong scanned = 0;
        while (true) {
            while (_start + scanned + 4 <= _buffer.count) {
                var at = _start + scanned;
                if (_buffer[at] == '\r'
                    && _buffer[at + 1] == '\n'
                    && _buffer[at + 2] == '\r'
                    && _buffer[at + 3] == '\n') {
                    var head = _buffer.slice(_start, at).to_array();
                    _start = at + 4;
                    return _head_lines(head);
                }
                scanned = scanned + 1;
            }
            if (_buffer.count - _start > _MAX_HEAD) {
                return Result<String[]>.err(Error("the handshake's head is too large"));
            }
            var read = _fill();
            if (read.is_err()) {
                return Result<String[]>.err(read.error());
            }
        }
        return Result<String[]>.err(Error("unreachable"));
    }

    # Reads more bytes into the buffer; an error at the end of the stream.
    _fill(): Result<void> {
        if (_start > 0) {
            # Drop what was consumed, so the buffer holds one frame at most.
            _buffer = _buffer.split_off(_start);
            _start = 0;
        }
        var read = _reader.read(_buffer, 65536);
        if (read.is_err()) {
            return Result<void>.err(Error(read.error().message));
        }
        if (read.value() == 0) {
            return Result<void>.err(Error("the connection ended without a close frame"));
        }
        return Result<void>.ok();
    }

    # Reads the next frame, with a payload of at most `max_payload` bytes.
    _next_frame(max_payload: ulong): Result<Frame> {
        while (true) {
            var decoded = _decode_at(_buffer, _start, max_payload);
            if (decoded.is_err()) {
                return Result<Frame>.err(decoded.error());
            }
            if (decoded.value().is_value()) {
                var (frame, used) = decoded.value().value();
                _start = _start + used;
                return Result<Frame>.ok(frame);
            }
            var read = _fill();
            if (read.is_err()) {
                _close_stream();
                return Result<Frame>.err(read.error());
            }
        }
        return Result<Frame>.err(Error("unreachable"));
    }

    # Returns a received message, checking a text message's UTF-8.
    _deliver(kind: Opcode, data: u8[]): Result<Message> {
        if (kind == Opcode.Text && !text.Utf8.is_valid(data)) {
            return _fail(CLOSE_INVALID_DATA, "a text message is not valid UTF-8");
        }
        return Result<Message>.ok(Message(kind, data));
    }

    # Answers the peer's close frame carrying `payload`, and closes.
    _closed_by_peer(payload: u8[]): Result<Message> {
        var code = CLOSE_NO_STATUS;
        var reason = Array<u8>();
        if (payload.count == 1) {
            return _fail(CLOSE_PROTOCOL_ERROR, "a close frame with a one-byte payload");
        }
        if (payload.count >= 2) {
            code = ((payload[0] as int) << 8) | (payload[1] as int);
            if (!_valid_close_code(code)) {
                return _fail(CLOSE_PROTOCOL_ERROR, $"a close frame with the invalid status code {code}");
            }
            reason = payload.slice(2, payload.count).to_array();
            if (!text.Utf8.is_valid(reason)) {
                return _fail(CLOSE_INVALID_DATA, "a close reason is not valid UTF-8");
            }
        }
        if (!_close_sent) {
            # Echo the peer's code, as RFC 6455 (section 5.5.1) suggests.
            var echo = code == CLOSE_NO_STATUS ? Array<u8>() : payload.slice(0, 2).to_array();
            _write(Frame(Opcode.Close, echo));
            _close_sent = true;
        }
        _close_stream();
        return Result<Message>.ok(Message(Opcode.Close, reason, code));
    }

    # Closes with `code` after a failure, and returns the failure.
    _fail(code: int, message: String): Result<Message> {
        if (!_closed && !_close_sent) {
            _send_close(code, "");
        }
        _close_stream();
        return Result<Message>.err(Error(message));
    }

    # Sends a close frame.
    _send_close(code: int, reason: String): Result<void> {
        var payload = Array<u8>();
        payload.append((code >> 8) as u8);
        payload.append(code as u8);
        payload.append_all(reason.bytes());
        if (payload.count > MAX_CONTROL_PAYLOAD) {
            return Result<void>.err(Error("a close reason is longer than 123 bytes"));
        }
        var sent = _write(Frame(Opcode.Close, payload));
        _close_sent = true;
        return sent;
    }

    # Writes `frame`, masked with a fresh key on a client.
    _write(frame: Frame): Result<void> {
        var bytes = _client ? encode_frame(frame, random.bytes(4)) : encode_frame(frame);
        var written = _writer.write_all(bytes);
        if (written.is_err()) {
            _close_stream();
            return Result<void>.err(Error(written.error().message));
        }
        return Result<void>.ok();
    }

    # Closes the stream: close_notify over TLS, then the socket.
    _close_stream() {
        if (_closed) {
            return;
        }
        _closed = true;
        if (_tls.is_value()) {
            _tls.value().shutdown();
            _tls.value().close();
        }
        _tcp.close();
    }
}

# `data` decoded as UTF-8; a member named `text` hides the module there.
_text_of(data: u8[]): String {
    return text.Utf8.decode_lossy(data);
}

# Whether a peer may send `code` in a close frame (RFC 6455, section 7.4).
_valid_close_code(code: int): bool {
    if (code >= 3000 && code <= 4999) {
        return true;
    }
    return code >= 1000 && code <= 1011 && code != 1004 && code != 1005 && code != 1006;
}
