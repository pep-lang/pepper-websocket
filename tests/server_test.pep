# WebSockets from an http.Server handler (`WebSocket.accept(request,
# handler)`) over loopback: a WebSocket route and a plain HTTP route on one
# port, over TCP and TLS, and the requests the route refuses.

import async;
import http;
import io;
import text;
import tls;
import websocket;

# `/chat` echoes WebSocket messages until the client closes; any other path
# is plain HTTP.
route(request: http.Request): http.Response {
    if (request.path() == "/chat") {
        return websocket.WebSocket.accept(request, (socket) => {
            expect_equal(socket.request.url, "/chat?room=1");
            while (true) {
                var message = socket.receive();
                if (message.is_err() || message.value().is_close()) {
                    return;
                }
                socket.send_text("echo: " + message.value().text());
            }
        });
    }
    return http.Response(200).set_text("plain " + request.path());
}

# Starts a server running `route` in the running `async.run`; returns its port.
start(server: http.Server): u16 {
    async.spawn<void>(() => {
        server.serve(route);
    });
    return server.local_address().value().port();
}

# Sends `request` on a new connection and returns all the server answers.
raw(port: u16, request: String): String {
    var tcp = io.TcpStream.connect(io.SocketAddress(io.IpAddress.loopback_v4(), port)).value();
    tcp.write_all(request.bytes());
    tcp.shutdown_write();
    var answer = Array<u8>();
    while (tcp.read(answer, 4096).ok_or(0) > 0) {}
    return text.Utf8.decode_lossy(answer);
}

[Test]
a_server_route_shares_its_port_with_http() {
    async.run(() => {
        var port = start(http.Server.bind(io.SocketAddress(io.IpAddress.loopback_v4(), 0)).value());
        var client = websocket.WebSocket.connect($"ws://127.0.0.1:{port}/chat?room=1").value();
        client.send_text("hello");
        expect_equal(client.receive().value().text(), "echo: hello");
        client.send_text("again");
        expect_equal(client.receive().value().text(), "echo: again");
        expect_true(client.close().is_ok());

        var plain = raw(port, "GET /page HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        expect_true(plain.starts_with("HTTP/1.1 200 "));
        expect_true(plain.ends_with("plain /page"));
    });
}

[Test]
a_server_route_accepts_over_tls() {
    keep_for_the_program(() => {
        tls.TlsConnector.create();
    });
    async.run(() => {
        var certificate = io.Path("tests/testdata/certificate.pem");
        var acceptor = tls.TlsAcceptor.create(certificate, io.Path("tests/testdata/key.pem")).value();
        var port = start(http.Server.bind_tls(io.SocketAddress(io.IpAddress.loopback_v4(), 0), acceptor).value());
        var connector = tls.TlsConnector.create().value();
        expect_true(connector.add_root_certificate(certificate).is_ok());
        var client = websocket.WebSocket.connect($"wss://127.0.0.1:{port}/chat?room=1", connector).value();
        client.send_text("secret");
        expect_equal(client.receive().value().text(), "echo: secret");
        expect_true(client.close().is_ok());
    });
}

[Test]
a_server_route_refuses_what_it_cannot_upgrade() {
    async.run(
        () => {
            var port = start(http.Server.bind(io.SocketAddress(io.IpAddress.loopback_v4(), 0)).value());
            var upgrade = "Upgrade: websocket\r\nConnection: Upgrade\r\n";
            var key = "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
            var version = "Sec-WebSocket-Version: 13\r\n";

            # Not an upgrade at all.
            expect_true(raw(port, "GET /chat HTTP/1.1\r\nHost: x\r\n\r\n").starts_with("HTTP/1.1 400 "));
            # No key, and a key that is not 16 bytes.
            expect_true(raw(port, $"GET /chat HTTP/1.1\r\n{upgrade}{version}\r\n").starts_with("HTTP/1.1 400 "));
            var short_key = "Sec-WebSocket-Key: c2hvcnQ=\r\n";
            expect_true(
                raw(port, $"GET /chat HTTP/1.1\r\n{upgrade}{short_key}{version}\r\n").starts_with("HTTP/1.1 400 ")
            );
            # A method other than GET.
            expect_true(raw(port, $"POST /chat HTTP/1.1\r\n{upgrade}{key}{version}\r\n").starts_with("HTTP/1.1 400 "));
            # A version other than 13 is told which one to use.
            var old = raw(port, $"GET /chat HTTP/1.1\r\n{upgrade}{key}Sec-WebSocket-Version: 8\r\n\r\n");
            expect_true(old.starts_with("HTTP/1.1 426 "));
            expect_true(old.lower().contains("sec-websocket-version: 13\r\n"));
            # HTTP/1.0 cannot switch protocols.
            expect_true(raw(port, $"GET /chat HTTP/1.0\r\n{upgrade}{key}{version}\r\n").starts_with("HTTP/1.1 501 "));
        }
    );
}
