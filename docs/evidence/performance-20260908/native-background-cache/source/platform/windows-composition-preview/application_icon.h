#pragma once
#include <windows.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <iostream>
#include <propkey.h>
#include <propvarutil.h>
#include <winrt/base.h>
#include <fstream>
#include <string>
#include <cstdint>

namespace viewflow::windows_preview {
class ApplicationIcon {
 public:
  ApplicationIcon() = default;
  ApplicationIcon(const ApplicationIcon&) = delete;
  ApplicationIcon& operator=(const ApplicationIcon&) = delete;
  ~ApplicationIcon() { if (big_) DestroyIcon(big_); if (small_) DestroyIcon(small_); }
  void Apply(HWND hwnd, uint64_t high, uint64_t low) {
    if (GetTickCount64() < next_check_) return;
    next_check_ = GetTickCount64() + 250;
    wchar_t directory[32768]{};
    const DWORD length = GetEnvironmentVariableW(L"VIEWFLOW_ATLAS_ICON_DIR", directory, 32768);
    if (!length || length >= 32768) return;
    const auto stem = std::wstring(directory) + L"\\" + std::to_wstring(high) + L"-" + std::to_wstring(low);
    const auto path = stem + L".ico";
    WIN32_FILE_ATTRIBUTE_DATA file{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &file)) return;
    if (big_ && CompareFileTime(&file.ftLastWriteTime, &modified_) == 0) return;
    HICON big = static_cast<HICON>(LoadImageW(nullptr, path.c_str(), IMAGE_ICON,
        GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE));
    HICON small_icon = static_cast<HICON>(LoadImageW(nullptr, path.c_str(), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));
    if (!big || !small_icon) { if (big) DestroyIcon(big); if (small_icon) DestroyIcon(small_icon); return; }
    // Each proxy gets the source application's taskbar group and native icons.
    std::ifstream id_file((stem + L".appid").c_str());
    std::string id;
    std::getline(id_file, id);
    if (!id.empty() && id.size() <= 128) {
      const std::wstring app_id(id.begin(), id.end());
      winrt::com_ptr<IPropertyStore> properties;
      if (SUCCEEDED(SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(properties.put())))) {
        PROPVARIANT value{};
        if (SUCCEEDED(InitPropVariantFromString(app_id.c_str(), &value))) {
          properties->SetValue(PKEY_AppUserModel_ID, value);
          properties->Commit();
          PropVariantClear(&value);
        }
      }
    }
    SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big));
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon));
    if (big_) DestroyIcon(big_);
    if (small_) DestroyIcon(small_);
    big_ = big; small_ = small_icon; modified_ = file.ftLastWriteTime;
    std::cerr << "application-icon-applied window=" << high << ":" << low << " app=" << id << "\n";
  }
 private:
  HICON big_{}, small_{};
  FILETIME modified_{};
  ULONGLONG next_check_{};
};
}
