#define VIEWFLOW_DESKTOP_EMBED
#include "../linux-window-input/main.cpp"
#include "pipe.hpp"
#include <poll.h>
#include <filesystem>
namespace h=viewflow::handoff;
int main(int argc,char** argv) {
    try {
        if(argc==2 && std::string(argv[1])=="--self-test")return h::self_test();
        const auto [local,remote]=h::geometry(argc,argv);
        h::Core validate(local,remote);
        std::signal(SIGPIPE,SIG_IGN);
        // The transport owns shutdown. EOF runs App cleanup even when the GUI
        // signals the whole process group.
        std::signal(SIGINT,SIG_IGN);std::signal(SIGTERM,SIG_IGN);
        char directory[]="/tmp/viewflow-handoff-XXXXXX";
        if(!mkdtemp(directory))throw std::runtime_error("handoff private directory unavailable");
        struct Cleanup {std::string path;~Cleanup(){std::filesystem::remove_all(path);}} cleanup{directory};
        const std::string path=std::string(directory)+"/input.sock";
        sockaddr_un address{};address.sun_family=AF_UNIX;std::strcpy(address.sun_path,path.c_str());
        int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0);
        if(listener<0 || bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))<0 || listen(listener,1)<0)
            throw std::runtime_error("handoff local listener failed");
        App app;app.desktop=true;app.start();
        std::string command="/eval hl.plugin.viewflow.handoff_connect('"+path+"'";
        for(int i=1;i<argc;++i)command+=","+std::string(argv[i]);
        const auto response=ipc(command+")");
        if(response.find("error")!=std::string::npos || response.find("Error")!=std::string::npos)
            throw std::runtime_error("handoff plugin unavailable: "+response);
        int socket=accept4(listener,nullptr,nullptr,SOCK_CLOEXEC);close(listener);
        if(socket<0)throw std::runtime_error("handoff plugin connection failed");
        struct Close {int fd;~Close(){::close(fd);}} close_socket{socket};
        uint64_t sequence=0,output_sequence=0;
        for(;;) {
            pollfd fds[]={{0,POLLIN,0},{socket,POLLIN,0}};
            if(poll(fds,2,-1)<0){if(errno==EINTR)continue;throw std::runtime_error("handoff poll failed");}
            if(fds[0].revents&(POLLHUP|POLLERR|POLLNVAL))break;
            if(fds[0].revents&POLLIN) {
                std::vector<uint8_t> bytes;if(!vf::read_record(0,bytes))break;
                if(bytes.size()!=40 || send(socket,bytes.data(),bytes.size(),MSG_NOSIGNAL)!=ssize_t(bytes.size()))break;
            }
            if(fds[1].revents&(POLLHUP|POLLERR|POLLNVAL))break;
            if(fds[1].revents&POLLIN) {
                uint8_t bytes[41];const auto n=recv(socket,bytes,sizeof(bytes),0);if(n!=40)break;
                auto event=h::decode(std::span(bytes,40));
                if(h::kind(event)>=401 && h::kind(event)<=408) {
                    event.kind=static_cast<vf::InputKind>(h::kind(event)-400);event.id=1;event.sequence=++sequence;
                    try{app.desktop_input(event);}catch(const std::exception& e){
                        std::fprintf(stderr,"handoff receiver recovering: %s\n",e.what());
                        app.release();event=h::message(h::fault);event.sequence=++output_sequence;
                        vf::write_record(1,vf::pack_input(event));
                    }
                } else {event.sequence=++output_sequence;vf::write_record(1,vf::pack_input(event));}
            }
        }
        // App releases virtual keys/buttons before destroying its devices.
        return 0;
    }catch(const std::exception& e){std::fprintf(stderr,"handoff unavailable: %s\n",e.what());return 1;}
}
