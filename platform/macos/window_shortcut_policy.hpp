#pragma once

#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace viewflow::macos {
enum ShortcutModifier : unsigned {
    shortcut_control = 1, shortcut_option = 2, shortcut_shift = 4, shortcut_command = 8,
};

class ShortcutPolicy {
    struct Rule { unsigned modifiers{}; std::string key; bool wildcard{}; };
    std::vector<Rule> rules_;
    static std::string lower(std::string_view value) {
        std::string out(value);
        std::ranges::transform(out, out.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return out;
    }
public:
    void add(std::string_view text) {
        Rule rule;
        std::string input = lower(text);
        std::size_t start = 0;
        while (start <= input.size()) {
            const auto end = input.find('+', start);
            const auto token = input.substr(start, end == std::string::npos ? input.size() - start : end - start);
            if (token == "ctrl" || token == "control") rule.modifiers |= shortcut_control;
            else if (token == "alt" || token == "option") rule.modifiers |= shortcut_option;
            else if (token == "shift") rule.modifiers |= shortcut_shift;
            else if (token == "cmd" || token == "command" || token == "super") rule.modifiers |= shortcut_command;
            else if (token == "*") rule.wildcard = true;
            else if (!token.empty() && rule.key.empty()) rule.key = token;
            else throw std::runtime_error("invalid --linux-shortcut rule");
            if (end == std::string::npos) break;
            start = end + 1;
        }
        if ((!rule.wildcard && rule.key.empty()) || (rule.wildcard && !rule.key.empty()) || rule.modifiers == 0)
            throw std::runtime_error("shortcut rule requires modifiers and one key or *");
        rules_.push_back(std::move(rule));
    }
    [[nodiscard]] bool linux_first(unsigned modifiers, std::string_view key) const {
        const auto normalized = lower(key);
        return std::ranges::any_of(rules_, [&](const Rule& rule) {
            const bool modifier_match = rule.wildcard
                ? (modifiers & rule.modifiers) == rule.modifiers
                : rule.modifiers == modifiers;
            return modifier_match && (rule.wildcard || rule.key == normalized);
        });
    }
};
}
