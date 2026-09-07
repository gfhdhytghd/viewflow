// Exercise console stop events in a NEW, hidden test-only console.
// No existing console or user process receives the generated event.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#pragma comment(lib, "user32.lib")
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
std::wstring quote(const std::filesystem::path& path) {
    const auto value = path.wstring();
    require(value.find(L'"') == std::wstring::npos, "invalid path quote");
    return L"\"" + value + L"\"";
}
std::string read_log(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), {});
}
BOOL WINAPI ignore_controller_event(DWORD) { return TRUE; }
struct Child {
    PROCESS_INFORMATION process{};
    HANDLE log = INVALID_HANDLE_VALUE;
    HANDLE input = INVALID_HANDLE_VALUE;
    ~Child() {
        if (process.hProcess) {
            if (WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT) {
                TerminateProcess(process.hProcess, 99);
                WaitForSingleObject(process.hProcess, 5000);
            }
            CloseHandle(process.hProcess);
        }
        if (process.hThread) CloseHandle(process.hThread);
        if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
        if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    }
};

void exercise(const std::filesystem::path& binary, const std::filesystem::path& fixtures, DWORD event, bool reconnect) {
    // Own the isolated console from its creation; avoid racing a cross-process
    // attach against child exit and keep event delivery inside our test tree.
    FreeConsole();
    require(AllocConsole(), "allocate isolated console failed");
    struct ConsoleOwner { ~ConsoleOwner() { FreeConsole(); } } console_owner;
    ShowWindow(GetConsoleWindow(), SW_HIDE);
    // OpenSSH launchers may pass down the inheritable Ctrl-C ignore flag.
    // Installing our callback does not clear that independent process flag.
    require(SetConsoleCtrlHandler(nullptr, FALSE), "clear inherited Ctrl-C ignore failed");
    require(SetConsoleCtrlHandler(ignore_controller_event, TRUE), "controller handler failed");
    wchar_t temporary[MAX_PATH + 1]{}, log_name[MAX_PATH + 1]{};
    require(GetTempPathW(MAX_PATH, temporary) > 0, "temporary path unavailable");
    require(GetTempFileNameW(temporary, L"vfs", 0, log_name) != 0, "temporary log unavailable");
    Child child;
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    child.log = CreateFileW(log_name, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    child.input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    require(child.log != INVALID_HANDLE_VALUE && child.input != INVALID_HANDLE_VALUE, "test pipes unavailable");
    SIZE_T attribute_bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
    std::vector<unsigned char> storage(attribute_bytes);
    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    require(InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes), "handle list allocation failed");
    struct AttributeOwner {
        LPPROC_THREAD_ATTRIBUTE_LIST value;
        ~AttributeOwner() { DeleteProcThreadAttributeList(value); }
    } attribute_owner{attributes};
    HANDLE inherited[]{child.log, child.input};
    require(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                      inherited, sizeof(inherited), nullptr, nullptr), "handle list setup failed");
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.StartupInfo.wShowWindow = SW_HIDE;
    startup.StartupInfo.hStdInput = child.input;
    startup.StartupInfo.hStdOutput = child.log;
    startup.StartupInfo.hStdError = child.log;
    startup.lpAttributeList = attributes;
    auto command = quote(binary) + L" receive --listen 127.0.0.1:0 --persistent --timeout-ms " +
        (reconnect ? L"100 --reconnect" : L"60000") + L" --cert " +
        quote(fixtures / "peer.pem") + L" --key " + quote(fixtures / "peer.key") +
        L" --ca " + quote(fixtures / "ca.pem") + L" --stdin-compressed " + quote(binary);
    require(CreateProcessW(binary.c_str(), command.data(), nullptr, nullptr, TRUE,
                          EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
                          &startup.StartupInfo, &child.process), "test process creation failed");
    const auto ready_until = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    const char* marker = reconnect ? "native media retry after attempt=2 " : "native media owner stop handlers ready";
    while (read_log(log_name).find(marker) == std::string::npos) {
        require(WaitForSingleObject(child.process.hProcess, 0) == WAIT_TIMEOUT, "process exited before readiness");
        require(std::chrono::steady_clock::now() < ready_until, "handler readiness timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    require(WaitForSingleObject(child.process.hProcess, 0) == WAIT_TIMEOUT, "process exited after readiness");
    // Only this controller and its child inherit our isolated console.
    const auto started = std::chrono::steady_clock::now();
    require(GenerateConsoleCtrlEvent(event, 0), "console event delivery failed");
    require(WaitForSingleObject(child.process.hProcess, 5000) == WAIT_OBJECT_0, "graceful stop timed out");
    DWORD code = 0;
    require(GetExitCodeProcess(child.process.hProcess, &code) && code == 1, "original transport error not preserved");
    const auto log = read_log(log_name);
    require(log.find("stop requested; attempt retirement returned") != std::string::npos, "retirement did not return");
    require(log.find("Error:") != std::string::npos, "missing attempt error");
    require(log.find("native media cleanup failed") == std::string::npos, "cleanup failed");
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
    std::cout << (event == CTRL_C_EVENT ? "Ctrl-C" : "Ctrl-Break") << " reconnect=" << reconnect << " exit=1 stop_ms=" << elapsed
              << " retirement_returned=true transport_error_preserved=true\n";
    std::wcout << L"log=" << log_name << L"\n";
}
}
int wmain(int argc, wchar_t** argv) {
    try {
        require(argc == 3 || (argc == 4 && std::wstring(argv[3]) == L"--reconnect"),
                "usage: windows_media_shutdown_smoke BINARY FIXTURES [--reconnect]");
        const auto binary = std::filesystem::absolute(argv[1]);
        const auto fixtures = std::filesystem::absolute(argv[2]);
        exercise(binary, fixtures, CTRL_C_EVENT, argc == 4);
        exercise(binary, fixtures, CTRL_BREAK_EVENT, argc == 4);
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << " win32=" << GetLastError() << "\n";
        return 1;
    }
}
