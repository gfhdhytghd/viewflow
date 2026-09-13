#include "window_io.hpp"
#include <cassert>
#include <future>
#include <unistd.h>

int main() {
    int pipe_fds[2]; assert(pipe(pipe_fds) == 0);
    const int original = dup(STDOUT_FILENO); assert(original >= 0);
    assert(dup2(pipe_fds[1], STDOUT_FILENO) >= 0); close(pipe_fds[1]);
    {
        viewflow::macos::Output output(1);
        assert(output.push(std::vector<uint8_t>(1024 * 1024, 1)));
        // The reader stays idle. One record blocks in the pipe, another fills
        // the bounded queue, and the third must unblock when shutdown starts.
        auto producer = std::async(std::launch::async, [&] {
            if (!output.push(std::vector<uint8_t>(1024 * 1024, 2), true)) return false;
            return output.push(std::vector<uint8_t>(1024 * 1024, 3), true);
        });
        assert(producer.wait_for(std::chrono::milliseconds(30)) == std::future_status::timeout);
        output.stop();
        assert(producer.wait_for(std::chrono::seconds(2)) == std::future_status::ready);
        assert(!producer.get());
    }
    assert(dup2(original, STDOUT_FILENO) >= 0); close(original); close(pipe_fds[0]);
}
