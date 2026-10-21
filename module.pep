## WebSocket (RFC 6455): a client and a server, over TCP (`ws://`) and TLS
## (`wss://`).
##
## Bring it in with `import websocket`. A client opens a connection with
## `WebSocket.connect(url)`; a server runs the handshake on a connection its
## listener accepted with `WebSocket.accept(tcp)`. Either end then sends
## with `send_text` and `send_binary` and gets whole messages from
## `receive`, which joins fragments, answers pings, and checks the protocol.
## Every call that waits parks only its task inside `async.run`.
##
## - `WebSocket`, `Message`: a connection and what it receives
## - `Frame`, `Opcode`, `encode_frame`, `decode_frame`: the wire format
## - `accept_key`: the handshake's `Sec-WebSocket-Accept`
## - `CLOSE_NORMAL` and the other `CLOSE_` constants: close status codes
##
## @example
##     import async;
##     import io;
##     import websocket;
##
##     main(): int {
##         async.run(() => {
##             var listener = io.TcpListener.bind(io.SocketAddress.parse("127.0.0.1:0").value()).value();
##             var port = listener.local_address().value().port();
##             var server = async.Task<void>.spawn_local(() => {
##                 var (tcp, peer) = listener.accept().value();
##                 var socket = websocket.WebSocket.accept(tcp).value();
##                 var message = socket.receive().value();
##                 socket.send_text("echo: " + message.text());
##                 socket.receive();   # the client's close
##             });
##             var client = websocket.WebSocket.connect($"ws://127.0.0.1:{port}/").value();
##             client.send_text("hi");
##             print(client.receive().value().text());   # echo: hi
##             client.close();
##             server.join();
##         });
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "frame";
import "handshake";
import "websocket";

export Opcode;
export MAX_CONTROL_PAYLOAD;
export Frame;
export encode_frame;
export decode_frame;
export accept_key;
export DEFAULT_MAX_MESSAGE_SIZE;
export CLOSE_NORMAL;
export CLOSE_GOING_AWAY;
export CLOSE_PROTOCOL_ERROR;
export CLOSE_UNSUPPORTED_DATA;
export CLOSE_NO_STATUS;
export CLOSE_INVALID_DATA;
export CLOSE_POLICY_VIOLATION;
export CLOSE_TOO_BIG;
export CLOSE_INTERNAL_ERROR;
export Message;
export WebSocket;
