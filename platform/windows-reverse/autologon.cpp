#include <windows.h>
#include <ntsecapi.h>
#include <wincred.h>
#include <algorithm>
#include <iostream>
#include <string>
#include <stdexcept>

namespace {
void check(LONG result){if(result)throw std::runtime_error("Windows error "+std::to_string(result));}
struct Key {HKEY handle{};~Key(){if(handle)RegCloseKey(handle);}};
void value(HKEY key,const wchar_t* name,const std::wstring& data){check(RegSetValueExW(key,name,0,REG_SZ,reinterpret_cast<const BYTE*>(data.c_str()),DWORD((data.size()+1)*sizeof(wchar_t))));}
LSA_UNICODE_STRING string(std::wstring& text){return {USHORT(text.size()*2),USHORT((text.size()+1)*2),text.data()};}
}
// Explicit administrator setup only. Password arrives on stdin, never argv.
int wmain(int argc,wchar_t** argv){try {
    if(argc!=4 || (wcscmp(argv[1],L"enable") && wcscmp(argv[1],L"credential")))throw std::runtime_error("usage: viewflow_autologon {enable USER DOMAIN|credential USER SERVER} (password on stdin)");
    std::string utf8;if(!std::getline(std::cin,utf8) || utf8.empty())throw std::runtime_error("missing password on stdin");
    if(!utf8.empty() && utf8.back()=='\r')utf8.pop_back();
    const auto length=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8.data(),int(utf8.size()),nullptr,0);
    if(!length || length>32766)throw std::runtime_error("invalid password encoding");
    std::wstring password(length,L'\0');MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8.data(),int(utf8.size()),password.data(),length);
    SecureZeroMemory(utf8.data(),utf8.size());
    if(!wcscmp(argv[1],L"credential")) {
        CREDENTIALW credential{};credential.Type=CRED_TYPE_DOMAIN_PASSWORD;credential.TargetName=argv[3];credential.UserName=argv[2];
        credential.CredentialBlobSize=DWORD(password.size()*2);credential.CredentialBlob=reinterpret_cast<BYTE*>(password.data());credential.Persist=CRED_PERSIST_LOCAL_MACHINE;
        const auto ok=CredWriteW(&credential,0);const auto error=GetLastError();SecureZeroMemory(password.data(),password.size()*2);
        if(!ok)check(error);std::cout<<"SMB credential stored in Windows Credential Manager\n";return 0;
    }
    LSA_OBJECT_ATTRIBUTES attributes{};attributes.Length=sizeof(attributes);LSA_HANDLE policy{};
    auto status=LsaOpenPolicy(nullptr,&attributes,POLICY_CREATE_SECRET,&policy);
    if(status){SecureZeroMemory(password.data(),password.size()*2);check(LsaNtStatusToWinError(status));}
    std::wstring name=L"DefaultPassword";auto key_name=string(name),secret=string(password);
    status=LsaStorePrivateData(policy,&key_name,&secret);LsaClose(policy);
    SecureZeroMemory(password.data(),password.size()*2);check(LsaNtStatusToWinError(status));
    Key key;check(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon",0,KEY_SET_VALUE,&key.handle));
    value(key.handle,L"DefaultUserName",argv[2]);value(key.handle,L"DefaultDomainName",argv[3]);
    RegDeleteValueW(key.handle,L"DefaultPassword");RegDeleteValueW(key.handle,L"AutoLogonCount");
    value(key.handle,L"AutoAdminLogon",L"1");
    std::cout<<"autologon enabled; credential stored as LSA secret; no plaintext Winlogon password\n";return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
