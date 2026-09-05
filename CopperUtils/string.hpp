#pragma once

#include <string_view>
#include <vector>

namespace Cu {

/// Split a string at every character present in `delimiters`.
///
/// Empty fields are retained, matching boost::split's default token_compress_off behaviour.
inline std::vector<std::string_view> splitAnyOf(
    std::string_view value,
    std::string_view delimiters
) {
    std::vector<std::string_view> fields;
    std::size_t fieldStart = 0;

    for (std::size_t position = 0; position < value.size(); ++position) {
        if (delimiters.find(value[position]) == std::string_view::npos) {
            continue;
        }

        fields.emplace_back(value.substr(fieldStart, position - fieldStart));
        fieldStart = position + 1;
    }

    fields.emplace_back(value.substr(fieldStart));
    return fields;
}

} // namespace Cu
