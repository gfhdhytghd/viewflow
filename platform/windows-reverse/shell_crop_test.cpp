#include "shell_crop.hpp"
#include <array>
#include <cassert>
int main(){
    using Microsoft::WRL::ComPtr;
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    assert(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context)));
    viewflow::reverse::ShellCrop crop;
    std::array<unsigned,32*24> pixels{};pixels[7*32+5]=0xffffffff;pixels[19*32+28]=0xff000000;
    D3D11_TEXTURE2D_DESC d{};d.Width=32;d.Height=24;d.MipLevels=d.ArraySize=1;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.SampleDesc.Count=1;
    D3D11_SUBRESOURCE_DATA data{pixels.data(),32*4,0};ComPtr<ID3D11Texture2D> texture;
    assert(SUCCEEDED(device->CreateTexture2D(&d,&data,&texture)));
    auto bounds=crop.measure(device.Get(),context.Get(),texture.Get());
    assert(bounds && bounds->left==5 && bounds->top==7 && bounds->right==29 && bounds->bottom==20);
    pixels.fill(0);context->UpdateSubresource(texture.Get(),0,nullptr,pixels.data(),32*4,0);
    assert(!crop.measure(device.Get(),context.Get(),texture.Get()));
}
