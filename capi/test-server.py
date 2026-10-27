# A tiny Gopher server for capi/test.c.  Prints its port, then serves:
#   ""        a two-line menu
#   "/stall"  never answers (for the cancellation test)
#   other     an error item
import socket, threading, time

def serve(conn):
    try:
        selector = conn.makefile("rb").readline().decode().rstrip("\r\n")
        if selector == "":
            conn.sendall(b"iHello from C\tfake\t(NULL)\t0\r\n"
                         b"0A text file\t/file\t127.0.0.1\t70\r\n.\r\n")
        elif selector == "/stall":
            time.sleep(30)
        else:
            conn.sendall(b"3Not found\t\terror.host\t1\r\n.\r\n")
    finally:
        conn.close()

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(16)
print(listener.getsockname()[1], flush=True)
while True:
    c, _ = listener.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
