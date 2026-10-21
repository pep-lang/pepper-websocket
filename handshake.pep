## The opening handshake (RFC 6455, section 4): the HTTP/1.1 `Upgrade`
## request a client sends and the `101 Switching Protocols` a server answers
## it with, tied together by `accept_key`.

import base64;
import digest;
import http;
import text;

# The GUID RFC 6455 appends to a client's key before hashing it.
const _GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

# The most bytes the head of a handshake request or response may take.
const _MAX_HEAD: ulong = 65536;

## Returns the `Sec-WebSocket-Accept` value that answers a client's
## `Sec-WebSocket-Key`: the base64 of the SHA-1 of the key followed by RFC
## 6455's GUID.
##
## @param key the client's `Sec-WebSocket-Key`, as sent
## @returns the server's `Sec-WebSocket-Accept`
## @example
##     # The example of RFC 6455, section 1.3:
##     websocket.accept_key("dGhlIHNhbXBsZSBub25jZQ==");   # "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
export accept_key(key: String): String {
    return base64.encode(digest.sha1(key + _GUID));
}

# The lines of an HTTP head (without the empty line ending it), or an error
# when it is not all there or not text.
_head_lines(head: u8[]): Result<String[]> {
    var decoded = text.Utf8.decode(head);
    if (decoded.is_empty()) {
        return Result<String[]>.err(Error("the handshake is not UTF-8 text"));
    }
    return Result<String[]>.ok(decoded.value().split("\r\n"));
}

# Reads the header fields of `lines` after the first into `headers`.
_read_fields(lines: String[], headers: http.Headers): Result<void> {
    ulong index = 1;
    while (index < lines.count) {
        var field = lines[index].split_once(":");
        if (field.is_empty()) {
            return Result<void>.err(Error($"a malformed header field '{lines[index]}'"));
        }
        var (name, value) = field.value();
        headers.add(name.trim(), value.trim());
        index = index + 1;
    }
    return Result<void>.ok();
}

# Whether the comma-separated `value` of `headers[name]` holds `token`,
# ignoring case.
_has_token(headers: http.Headers, name: String, token: String): bool {
    for (var value in headers.values(name)) {
        for (var item in value.split(",")) {
            if (item.trim().lower() == token) {
                return true;
            }
        }
    }
    return false;
}

# The request a client sends to open a connection to `target` on `host`.
_client_request(host: String, target: String, key: String): http.Request {
    var request = http.Request("GET", target);
    request.headers["Host"] = host;
    request.headers["Upgrade"] = "websocket";
    request.headers["Connection"] = "Upgrade";
    request.headers["Sec-WebSocket-Key"] = key;
    request.headers["Sec-WebSocket-Version"] = "13";
    return request;
}

# `request` as it goes on the wire.
_request_bytes(request: http.Request): u8[] {
    var head = $"{request.method} {request.url} HTTP/1.1\r\n";
    for (var name in request.headers.names()) {
        for (var value in request.headers.values(name)) {
            head = head + $"{name}: {value}\r\n";
        }
    }
    return (head + "\r\n").bytes();
}

# Checks a server's answer to a request that sent `key`.
_check_response(lines: String[], key: String): Result<void> {
    var status = lines[0].split(" ");
    if (status.count < 2 || !status[0].starts_with("HTTP/1.") || status[1] != "101") {
        return Result<void>.err(Error($"the server refused the upgrade: '{lines[0]}'"));
    }
    var headers = http.Headers();
    var fields = _read_fields(lines, headers);
    if (fields.is_err()) {
        return fields;
    }
    if (!_has_token(headers, "Upgrade", "websocket") || !_has_token(headers, "Connection", "upgrade")) {
        return Result<void>.err(Error("the server's answer is not a WebSocket upgrade"));
    }
    var accept = headers.get("Sec-WebSocket-Accept");
    if (accept.is_empty() || accept.value() != accept_key(key)) {
        return Result<void>.err(Error("the server's Sec-WebSocket-Accept does not match the key"));
    }
    return Result<void>.ok();
}

# Parses an opening handshake request. On an error, the status to answer
# with comes first in the message's tuple.
_parse_request(lines: String[]): Result<http.Request, (int, String)> {
    var parts = lines[0].split(" ");
    if (parts.count != 3 || parts[2] != "HTTP/1.1") {
        return Result<http.Request, (int, String)>.err((400, $"not a WebSocket upgrade request: '{lines[0]}'"));
    }
    var request = http.Request(parts[0], parts[1]);
    var fields = _read_fields(lines, request.headers);
    if (fields.is_err()) {
        return Result<http.Request, (int, String)>.err((400, fields.error().message));
    }
    var checked = _check_request(request);
    if (checked.is_err()) {
        return Result<http.Request, (int, String)>.err(checked.error());
    }
    return Result<http.Request, (int, String)>.ok(request);
}

# Checks that an HTTP/1.1 `request` asks for a WebSocket. On an error, the
# status to answer with comes first in the message's tuple.
_check_request(request: http.Request): Result<void, (int, String)> {
    if (request.method != "GET") {
        return Result<void, (int, String)>.err(
            (400, $"not a WebSocket upgrade request: '{request.method} {request.url}'")
        );
    }
    if (!_has_token(request.headers, "Upgrade", "websocket") || !_has_token(request.headers, "Connection", "upgrade")) {
        return Result<void, (int, String)>.err((400, "the request does not ask to upgrade to websocket"));
    }
    var version = request.headers.get("Sec-WebSocket-Version");
    if (version.is_empty() || version.value() != "13") {
        return Result<void, (int, String)>.err((426, "the request does not ask for WebSocket version 13"));
    }
    var key = request.headers.get("Sec-WebSocket-Key");
    if (key.is_empty()) {
        return Result<void, (int, String)>.err((400, "the request has no Sec-WebSocket-Key"));
    }
    var nonce = base64.decode(key.value());
    if (nonce.is_err() || nonce.value().count != 16) {
        return Result<void, (int, String)>.err((400, "the Sec-WebSocket-Key is not 16 bytes in base64"));
    }
    return Result<void, (int, String)>.ok();
}

# The server's answer to a valid request.
_accept_response(request: http.Request): u8[] {
    var key = request.headers.get("Sec-WebSocket-Key").value();
    var head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n";
    return (head + $"Sec-WebSocket-Accept: {accept_key(key)}\r\n\r\n").bytes();
}

# The header fields of a refusal with `status`, beyond its length: a `426`
# names the version the server speaks.
_refusal_fields(status: int): Array<(String, String)> {
    var fields = [("Content-Type", "text/plain")];
    if (status == 426) {
        fields.append(("Sec-WebSocket-Version", "13"));
    }
    return fields;
}

# An `http.Server` handler's answer to a request it refuses with `status`.
_refusal_response(status: int, message: String): http.Response {
    var response = http.Response(status).set_text(message);
    for (var (name, value) in _refusal_fields(status)) {
        response.headers[name] = value;
    }
    return response;
}

# The server's answer to a request it refuses with `status`.
_refusal(status: int, message: String): u8[] {
    var head = $"HTTP/1.1 {status} {http.reason_phrase(status)}\r\n";
    for (var (name, value) in _refusal_fields(status)) {
        head = head + $"{name}: {value}\r\n";
    }
    var body = message.bytes();
    head = head + $"Content-Length: {body.count}\r\nConnection: close\r\n\r\n";
    var out = head.bytes();
    out.append_all(body);
    return out;
}
