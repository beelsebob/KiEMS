#import "FieldFramePackageBridge.h"
#import "FieldSnapshotBridge+Private.h"

#include <filesystem>
#include <map>
#include <regex>

namespace {

NSError* makePackageError(NSString* message) {
    return [NSError errorWithDomain:@"EMSFieldFramePackage" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// For a package whose run never finished (series.json has no series list yet): each port's
/// most recently written slot.
std::vector<std::pair<std::int32_t, std::string>> scanSeriesFiles(const std::filesystem::path& package) {
    static const std::regex pattern(R"(^port_([0-9]+)_[01]\.h5$)");
    std::map<std::int32_t, std::pair<std::filesystem::file_time_type, std::string>> newest;
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(package, ec)) {
        const std::string name = entry.path().filename().string();
        std::smatch match;
        if (!std::regex_match(name, match, pattern)) continue;
        const auto port = static_cast<std::int32_t>(std::stol(match[1].str()));
        std::error_code timeError;
        const auto modified = entry.last_write_time(timeError);
        if (timeError) continue;
        auto found = newest.find(port);
        if (found == newest.end() || modified > found->second.first) newest[port] = {modified, name};
    }
    std::vector<std::pair<std::int32_t, std::string>> files;
    for (const auto& [port, entry] : newest) files.emplace_back(port, entry.second);
    return files;
}

} // namespace

@implementation EMSFieldFramePackage

- (instancetype)initWithSimulationName:(NSString*)simulationName
                        fieldSnapshots:(NSArray<EMSFieldSnapshot*>*)fieldSnapshots
                       geometryPreview:(nullable EMSGeometryPreview*)geometryPreview {
    self = [super init];
    if (self) {
        _simulationName = [simulationName copy];
        _fieldSnapshots = [fieldSnapshots copy];
        _geometryPreview = geometryPreview;
    }
    return self;
}

+ (nullable instancetype)packageWithURL:(NSURL*)url error:(NSError**)error {
    const std::filesystem::path package(url.fileSystemRepresentation);
    NSData* layoutData = [NSData dataWithContentsOfURL:[url URLByAppendingPathComponent:kFieldFramePackageLayoutName]];
    std::optional<FieldSeriesLayout> layout = layoutData ? decodeFieldSeriesLayout(layoutData) : std::nullopt;
    if (!layout.has_value()) {
        // Still playable, just without names or combined views.
        layout.emplace();
        layout->simulationName = url.URLByDeletingPathExtension.lastPathComponent.UTF8String;
    }
    if (layout->seriesFiles.empty()) {
        layout->seriesFiles = scanSeriesFiles(package);
    }

    NSMutableArray<EMSFieldSnapshot*>* singleEnded = [NSMutableArray array];
    for (const auto& [port, file] : layout->seriesFiles) {
        const auto name = layout->excitationNames.find(port);
        const std::string excitationName =
            name != layout->excitationNames.end() ? name->second : "Port " + std::to_string(port);
        if (EMSFieldSnapshot* snapshot = buildFieldSnapshot(package / file, excitationName, nil)) {
            [singleEnded addObject:snapshot];
        }
    }
    if (singleEnded.count == 0) {
        if (error) *error = makePackageError(@"The package contains no readable field frames.");
        return nil;
    }

    FieldSnapshotCombinationCache cache;
    NSArray<EMSFieldSnapshot*>* snapshots = assembleFieldSnapshots(singleEnded, *layout, cache);
    NSData* board = [NSData dataWithContentsOfURL:[url URLByAppendingPathComponent:kFieldFramePackageBoardName]
                                          options:NSDataReadingMappedIfSafe error:nil];
    EMSGeometryPreview* preview = board ? [EMSGeometryPreview previewWithArchivedData:board] : nil;
    return [[self alloc] initWithSimulationName:@(layout->simulationName.c_str()) fieldSnapshots:snapshots
                                geometryPreview:preview];
}

@end
