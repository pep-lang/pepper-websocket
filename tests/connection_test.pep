# The websocket package's connections over loopback, in tasks: a client and
# a server round trip over TCP and TLS, fragments, pings, the closing
# handshake, the size limit, and a peer that breaks the protocol.
#
# testdata/certificate.pem and key.pem are the runtime's TLS test
# certificate (self-signed, for `localhost` and `127.0.0.1`) and its key:
# for these tests only, the key is public.

import async;
import io;
import text;
import tls;
import websocket;

listen(): io.TcpListener {
    return io.TcpListener.bind(io.SocketAddress(io.IpAddress.loopback_v4(), 0)).value();
}

url_of(listener: io.TcpListener, scheme: String): String {
    return $"{scheme}://127.0.0.1:{listener.local_address().value().port()}/chat?room=1";
}

# Accepts one connection and echoes every message until the client closes.
# The number of messages echoed.
echo(listener: io.TcpListener): int {
    var (tcp, peer) = listener.accept().value();
    var socket = websocket.WebSocket.accept(tcp).value();
    expect_equal(socket.request.url, "/chat?room=1");
    return echo_messages(socket);
}

echo_messages(socket: websocket.WebSocket): int {
    var count = 0;
    while (true) {
        var message = socket.receive().value();
        if (message.is_close()) {
            expect_equal(message.close_code, websocket.CLOSE_NORMAL);
            expect_equal(message.text(), "done");
            return count;
        }
        if (message.is_text()) {
            socket.send_text(message.text());
        } else {
            socket.send_binary(message.data);
        }
        count = count + 1;
    }
    return count;
}

[Test]
round_trips_text_and_binary() {
    async.run(
        () => {
            var listener = listen();
            var server = async.Task<int>.spawn_local(() => {
                return echo(listener);
            });
            var client = websocket.WebSocket.connect(url_of(listener, "ws")).value();
            expect_true(client.send_text("hello, ünïcode").is_ok());
            var reply = client.receive().value();
            expect_true(reply.is_text());
            expect_equal(reply.text(), "hello, ünïcode");

            var data = Array<u8>();
            while (data.count < 70000) {
                data.append((data.count % 256) as u8);
            }
            client.send_binary(data);
            var binary = client.receive().value();
            expect_true(binary.is_binary());
            expect_true(binary.data == data);

            # Fragments with a ping between them arrive as one message, and the
            # ping's pong is skipped.
            client.send_frame(websocket.Frame(websocket.Opcode.Text, "frag".bytes(), false));
            client.ping("are you there".bytes());
            client.send_frame(websocket.Frame(websocket.Opcode.Continuation, "men".bytes(), false));
            client.send_frame(websocket.Frame(websocket.Opcode.Continuation, "ted".bytes()));
            expect_equal(client.receive().value().text(), "fragmented");

            expect_true(client.close(websocket.CLOSE_NORMAL, "done").is_ok());
            expect_false(client.is_open());
            expect_true(client.send_text("late").is_err());
            expect_true(client.receive().is_err());
            expect_equal(server.join().value(), 3);
        }
    );
}

[Test]
round_trips_over_tls() {
    keep_for_the_program(() => {
        tls.TlsConnector.create();
    });
    async.run(
        () => {
            var listener = listen();
            var acceptor = tls.TlsAcceptor.create(
                io.Path("tests/testdata/certificate.pem"), io.Path("tests/testdata/key.pem")
            ).value();
            var server = async.Task<int>.spawn_local(() => {
                var (tcp, peer) = listener.accept().value();
                var stream = acceptor.accept(tcp).value();
                return echo_messages(websocket.WebSocket.accept(tcp, stream).value());
            });
            var connector = tls.TlsConnector.create().value();
            expect_true(connector.add_root_certificate(io.Path("tests/testdata/certificate.pem")).is_ok());
            var client = websocket.WebSocket.connect(url_of(listener, "wss"), connector).value();
            client.send_text("secret");
            expect_equal(client.receive().value().text(), "secret");
            expect_true(client.close(websocket.CLOSE_NORMAL, "done").is_ok());
            expect_equal(server.join().value(), 1);
        }
    );
}

[Test]
server_closes_first() {
    async.run(() => {
        var listener = listen();
        var server = async.Task<bool>.spawn_local(() => {
            var (tcp, peer) = listener.accept().value();
            var socket = websocket.WebSocket.accept(tcp).value();
            return socket.close(websocket.CLOSE_GOING_AWAY, "bye").is_ok();
        });
        var client = websocket.WebSocket.connect(url_of(listener, "ws")).value();
        var message = client.receive().value();
        expect_true(message.is_close());
        expect_equal(message.close_code, websocket.CLOSE_GOING_AWAY);
        expect_equal(message.text(), "bye");
        expect_false(client.is_open());
        expect_true(server.join().value());
    });
}

[Test]
closes_on_a_message_over_the_limit() {
    async.run(() => {
        var listener = listen();
        var server = async.Task<String>.spawn_local(() => {
            var (tcp, peer) = listener.accept().value();
            var socket = websocket.WebSocket.accept(tcp).value();
            socket.max_message_size = 8;
            var received = socket.receive();
            return received.is_err() ? received.error().message : "";
        });
        var client = websocket.WebSocket.connect(url_of(listener, "ws")).value();
        client.send_frame(websocket.Frame(websocket.Opcode.Text, "12345".bytes(), false));
        client.send_frame(websocket.Frame(websocket.Opcode.Continuation, "6789".bytes()));
        var message = client.receive().value();
        expect_true(message.is_close());
        expect_equal(message.close_code, websocket.CLOSE_TOO_BIG);
        expect_true(server.join().value().contains("larger than"));
    });
}

# A raw client: sends the upgrade request by hand, then `frame` as given,
# and returns what the server answered.
raw_exchange(listener: io.TcpListener, frame: u8[]): u8[] {
    var tcp = io.TcpStream.connect(listener.local_address().value()).value();
    var request = "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    tcp.write_all(request.bytes());
    tcp.write_all(frame);
    var answer = Array<u8>();
    while (tcp.read(answer, 4096).value() > 0) {}
    tcp.close();
    return answer;
}

# The status code of the close frame at the end of `answer`.
close_code_at_end(answer: u8[]): int {
    var n = answer.count;
    return ((answer[n - 2] as int) << 8) | (answer[n - 1] as int);
}

[Test]
server_refuses_protocol_errors() {
    async.run(
        () => {
            var listener = listen();
            var errors = async.Task<String[]>.spawn_local(() => {
                var messages = Array<String>();
                var n = 0;
                while (n < 3) {
                    var (tcp, peer) = listener.accept().value();
                    var received = websocket.WebSocket.accept(tcp).value().receive();
                    messages.append(received.is_err() ? received.error().message : "");
                    n = n + 1;
                }
                return messages;
            });
            # An unmasked frame from a client.
            var unmasked = raw_exchange(
                listener, websocket.encode_frame(websocket.Frame(websocket.Opcode.Text, "hi".bytes()))
            );
            expect_true(text.Utf8.decode_lossy(unmasked).contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
            expect_equal(close_code_at_end(unmasked), websocket.CLOSE_PROTOCOL_ERROR);
            # Text that is not UTF-8.
            var mask = [1 as u8, 2, 3, 4];
            var invalid = Array<u8>();
            invalid.append(0xFF);
            var bad_text = raw_exchange(
                listener, websocket.encode_frame(websocket.Frame(websocket.Opcode.Text, invalid), mask)
            );
            expect_equal(close_code_at_end(bad_text), websocket.CLOSE_INVALID_DATA);
            # A continuation with nothing to continue.
            var stray = raw_exchange(
                listener, websocket.encode_frame(websocket.Frame(websocket.Opcode.Continuation, "x".bytes()), mask)
            );
            expect_equal(close_code_at_end(stray), websocket.CLOSE_PROTOCOL_ERROR);
            var messages = errors.join().value();
            expect_true(messages[0].contains("unmasked"));
            expect_true(messages[1].contains("UTF-8"));
            expect_true(messages[2].contains("continuation"));
        }
    );
}

[Test]
server_refuses_a_bad_handshake() {
    async.run(
        () => {
            var listener = listen();
            var refused = async.Task<bool>.spawn_local(() => {
                var (tcp, peer) = listener.accept().value();
                return websocket.WebSocket.accept(tcp).is_err();
            });
            var tcp = io.TcpStream.connect(listener.local_address().value()).value();
            tcp.write_all("GET / HTTP/1.1\r\nHost: x\r\n\r\n".bytes());
            var answer = Array<u8>();
            while (tcp.read(answer, 4096).value() > 0) {}
            expect_true(text.Utf8.decode_lossy(answer).starts_with("HTTP/1.1 400 "));
            expect_true(refused.join().value());

            # A version other than 13 is told which one to use.
            var old_version = async.Task<bool>.spawn_local(() => {
                var (tcp, peer) = listener.accept().value();
                return websocket.WebSocket.accept(tcp).is_err();
            });
            var old = io.TcpStream.connect(listener.local_address().value()).value();
            var request = "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n";
            old.write_all(request.bytes());
            var refusal = Array<u8>();
            while (old.read(refusal, 4096).value() > 0) {}
            var refusal_text = text.Utf8.decode_lossy(refusal);
            expect_true(refusal_text.starts_with("HTTP/1.1 426 "));
            expect_true(refusal_text.contains("Sec-WebSocket-Version: 13\r\n"));
            expect_true(old_version.join().value());

            # A plain HTTP server is not a WebSocket server.
            var http_server = async.Task<void>.spawn_local(() => {
                var (tcp, peer) = listener.accept().value();
                var request = Array<u8>();
                tcp.read(request, 4096);
                tcp.write_all("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".bytes());
                tcp.close();
            });
            var client = websocket.WebSocket.connect(url_of(listener, "ws"));
            expect_true(client.is_err());
            expect_true(client.error().message.contains("refused the upgrade"));
            http_server.join();
            expect_true(websocket.WebSocket.connect("http://example.com/").is_err());
        }
    );
}

[Test]
refuses_a_close_frame_and_times_out_a_silent_peer() {
    async.run(
        () => {
            var listener = listen();
            # A server that finishes the handshake and then never answers.
            var server = async.Task<void>.spawn_local(() => {
                var (tcp, peer) = listener.accept().value();
                var socket = websocket.WebSocket.accept(tcp).value();
                var rest = Array<u8>();
                while (tcp.read(rest, 4096).ok_or(0) > 0) {}
            });
            var client = websocket.WebSocket.connect(url_of(listener, "ws")).value();
            expect_true(client.send_frame(websocket.Frame(websocket.Opcode.Close, Array<u8>())).is_err());
            expect_true(client.is_open());
            expect_true(client.set_read_timeout(100).is_ok());
            expect_true(client.close().is_err());
            expect_false(client.is_open());
            server.join();
        }
    );
}
