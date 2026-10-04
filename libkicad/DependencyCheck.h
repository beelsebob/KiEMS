// Force-included into every C/C++/Objective-C compile (OTHER_CFLAGS in BuildPaths.xcconfig) so the
// build stops with one clear error until Scripts/check_dependencies.sh has verified this machine's
// Homebrew libraries and written the untracked DependenciesChecked.generated.h next to this file.
#pragma once

#if !__has_include("DependenciesChecked.generated.h")
#error "Third-party dependencies have not been checked: run Scripts/check_dependencies.sh"
#endif
