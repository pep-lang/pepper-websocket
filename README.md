# pepper-websocket

[WebSocket (RFC 6455)](https://www.rfc-editor.org/rfc/rfc6455) for
[Pepper](https://github.com/pep-lang/pepper): a client and a server, over
TCP (`ws://`) and TLS (`wss://`), built on the runtime's `io`, `tls`,
`digest`, `base64` and `random` modules.

One module, **`websocket`**:

- **`WebSocket.connect(url)`** opens a client connection to a `ws://` or
  `wss://` URL and runs the opening handshake;
  `WebSocket.connect(url, connector)` takes a `tls.TlsConnector`, such as
  one that trusts a private certificate authority.
- **`WebSocket.accept(tcp)`** runs the server's side of the handshake on a
  connection an `io.TcpListener` accepted (`accept(tcp, stream)` for TLS).
  A request that is not a valid upgrade gets `400 Bad Request` (`426
  Upgrade Required` for a version other than 13). The client's request is
  in `socket.request`: its `url` (`/chat?room=1`) and `headers`.
- **`send_text`**, **`send_binary`** and **`ping`** send a message;
  **`send_frame`** sends one `Frame` as it is, for a message in fragments.
- **`receive()`** returns the next whole `Message`, joining fragments,
  answering pings and skipping pongs. When the peer closes, it answers and
  returns a `Close` message with `close_code` and the reason in `text()`.
- **`close(code, reason)`** runs the closing handshake.
- **`encode_frame`** and **`decode_frame`** are the wire format on its own,
  and **`accept_key`** the handshake's `Sec-WebSocket-Accept`.

The protocol is checked as RFC 6455 asks: a client masks every frame with a
fresh random key and a server refuses unmasked frames (and the reverse);
reserved bits, unknown opcodes, fragmented or oversized control frames, a
stray continuation, text that is not UTF-8, and invalid close codes each
close the connection with the matching status code (`CLOSE_PROTOCOL_ERROR`,
`CLOSE_INVALID_DATA`), and `receive` returns the error. A message over
`max_message_size` (16 MiB by default) closes it with `CLOSE_TOO_BIG`.

```pepper
import async;
import io;
import websocket;

main(): int {
    async.run(() => {
        var listener = io.TcpListener.bind(io.SocketAddress.parse("127.0.0.1:0").value()).value();
        var port = listener.local_address().value().port();

        # The server: echo one message, then wait for the client's close.
        var server = async.Task<void>.spawn_local(() => {
            var (tcp, peer) = listener.accept().value();
            var socket = websocket.WebSocket.accept(tcp).value();
            var message = socket.receive().value();
            socket.send_text("echo: " + message.text());
            socket.receive();   # the Close message
        });

        var client = websocket.WebSocket.connect($"ws://127.0.0.1:{port}/chat").value();
        client.send_text("hi");
        print(client.receive().value().text());   # echo: hi
        client.close();
        server.join();
    });
    return 0;
}
```

## Limits

- `http.Server` cannot hand a connection over after a `101`, so a server
  accepts WebSocket connections on its own listener rather than upgrading
  a request from an `http.Server` handler.
- No extensions (permessage-deflate) or subprotocol negotiation; a
  client's `Sec-WebSocket-Protocol` is in `request.headers` for a server
  to read, but `accept` does not answer it.
- No WebSocket over HTTP/2 (RFC 8441).
- A connection belongs to one task at a time: a task that sends while
  another receives on the same connection could interleave frames.
- The client sends no `Origin`; it follows no redirects.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `websocket` module. Add it to a project under the name
`websocket`:

```sh
pepper package add pep-lang/pepper-websocket --name websocket
```

which writes

```toml
[dependencies]
websocket = { github = "pep-lang/pepper-websocket" }
```

Without a project, put a folder named `websocket` that holds (or links
to) this repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test`: the wire
format and the RFC's examples (`frame_test.pep`), and connections over
loopback (`connection_test.pep`): client and server round trips over TCP
and TLS, fragments and pings, both sides closing first, the size limit,
and a hand-written client that breaks the protocol. The TLS test uses the
runtime's self-signed test certificate in `tests/testdata/`, whose key is
public.

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE).
