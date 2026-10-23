#include "application_icon.h"
#include <filesystem>
#include <cassert>
#include <vector>
int main() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const auto directory = std::filesystem::temp_directory_path() / (L"viewflow-icon-test-" + std::to_wstring(GetCurrentProcessId()));
  std::filesystem::create_directories(directory);
  const std::vector<unsigned char> ico{0,0,1,0,1,0,32,32,0,0,1,0,32,0,104,0,0,0,22,0,0,0,137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,32,0,0,0,32,8,6,0,0,0,115,122,122,244,0,0,0,47,73,68,65,84,120,156,237,206,33,1,0,0,8,3,48,66,16,145,96,52,133,24,55,19,243,171,158,189,164,18,16,16,16,16,16,16,16,16,16,16,16,16,16,16,72,7,30,200,237,92,121,142,206,156,152,0,0,0,0,73,69,78,68,174,66,96,130};
  { std::ofstream file(directory / "0-9.ico", std::ios::binary); file.write(reinterpret_cast<const char*>(ico.data()), ico.size()); }
  { std::ofstream file(directory / "0-9.appid"); file << "Viewflow.Remote.IconTest"; }
  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_ICON_DIR", directory.c_str());
  WNDCLASSW cls{}; cls.lpfnWndProc = DefWindowProcW; cls.lpszClassName = L"ViewflowIconTest"; cls.hInstance = GetModuleHandleW(nullptr);
  assert(RegisterClassW(&cls));
  {
    viewflow::windows_preview::ApplicationIcon icons;
    const HWND hwnd = CreateWindowW(cls.lpszClassName, L"icon test", WS_OVERLAPPEDWINDOW, 0,0,100,100,nullptr,nullptr,cls.hInstance,nullptr);
    assert(hwnd && !IsWindowVisible(hwnd));
    icons.Apply(hwnd, 0, 9);
    const auto big = reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0));
    const auto small_icon = reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, ICON_SMALL, 0));
    assert(big && small_icon);
    ICONINFO info{}; assert(GetIconInfo(big, &info));
    BITMAP bitmap{}; assert(GetObjectW(info.hbmColor, sizeof(bitmap), &bitmap));
    assert(bitmap.bmWidth == GetSystemMetrics(SM_CXICON));
    DeleteObject(info.hbmColor); DeleteObject(info.hbmMask);
    winrt::com_ptr<IPropertyStore> properties;
    assert(SUCCEEDED(SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(properties.put()))));
    PROPVARIANT value{}; assert(SUCCEEDED(properties->GetValue(PKEY_AppUserModel_ID, &value)));
    assert(value.vt == VT_LPWSTR && std::wstring(value.pwszVal) == L"Viewflow.Remote.IconTest");
    PropVariantClear(&value);
    icons.Apply(hwnd, 0, 9);
    assert(reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0)) == big);
    DestroyWindow(hwnd);
  }
  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_ICON_DIR", nullptr);
  std::filesystem::remove_all(directory);
  CoUninitialize();
}
