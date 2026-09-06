// Gerber file parsing and representation. Ported from kiems/gerber_io.py.
#pragma once

#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

#include <nlohmann/json.hpp>

#include "net_name.hpp"

namespace kiems {

/// Plotting mode, matching the gerber file specification (G01, G02, G03).
enum class PlotMode : std::uint8_t {
    Linear = 1,
    CircularClockwise = 2,
    CircularCounterClockwise = 3,
};

/// Coordinates of a 2D point.
class Position {
public:
    Position() = default;
    Position(double x, double y) : _x(x), _y(y) {}

    double x() const { return _x; }
    double y() const { return _y; }
    void setX(double value) { _x = value; }
    void setY(double value) { _y = value; }

    void mirrorX() { _x = -_x; }
    void mirrorY() { _y = -_y; }
    /// Rotate point around (0,0). NOTE: mirrors the Python source's formula exactly, which passes
    /// its angle straight into std::cos/std::sin without a degrees->radians conversion despite
    /// callers treating the angle as degrees; preserved for behavioural fidelity.
    void rotate(double angle);
    void scale(double factor);
    void move(const Position& offset);

private:
    friend void to_json(nlohmann::json& j, const Position& p);
    friend void from_json(const nlohmann::json& j, Position& p);

    double _x = 0;
    double _y = 0;
};

void to_json(nlohmann::json& j, const Position& p);
void from_json(const nlohmann::json& j, Position& p);

/// Metadata about a pad (which component/pin it belongs to).
class PadMeta {
public:
    PadMeta(std::string compRef, std::string pinNum, std::string pinName)
        : _compRef(std::move(compRef)), _pinNum(std::move(pinNum)), _pinName(std::move(pinName)) {}

    const std::string& compRef() const { return _compRef; } // Reference designator of owning component
    const std::string& pinNum() const { return _pinNum; }   // Pad numeration inside the component (e.g. 1, A1)
    const std::string& pinName() const { return _pinName; } // Pad name/function (e.g. GPIO_1)

private:
    std::string _compRef;
    std::string _pinNum;
    std::string _pinName;
};

/// Describes a component pad (a flashed aperture in the gerber file).
class Pad {
public:
    Pad(std::string aperture, NetName net, Position pos, std::optional<PadMeta> pinRef = std::nullopt,
        bool additive = true, std::string mirror = "N", double rotation = 0, double scale = 1)
        : _aperture(std::move(aperture)),
          _net(std::move(net)),
          _pos(std::move(pos)),
          _pinRef(std::move(pinRef)),
          _additive(additive),
          _mirror(std::move(mirror)),
          _rotation(rotation),
          _scale(scale) {}

    const std::string& aperture() const { return _aperture; }
    const NetName& net() const { return _net; }
    const Position& pos() const { return _pos; }
    const std::optional<PadMeta>& pinRef() const { return _pinRef; }
    bool additive() const { return _additive; } // If false, this pad erases rather than draws
    const std::string& mirror() const { return _mirror; }
    double rotation() const { return _rotation; }
    double scale() const { return _scale; }

private:
    std::string _aperture;
    NetName _net;
    Position _pos;
    std::optional<PadMeta> _pinRef;
    bool _additive;
    std::string _mirror;
    double _rotation;
    double _scale;
};

/// A single trace segment (one line, possibly an arc endpoint pair).
class TraceSegment {
public:
    TraceSegment(Position start, Position stop, std::string aperture, double width,
                 PlotMode mode = PlotMode::Linear, bool normal = true)
        : _start(std::move(start)),
          _stop(std::move(stop)),
          _aperture(std::move(aperture)),
          _width(width),
          _mode(mode),
          _normal(normal) {}

    const Position& start() const { return _start; }
    const Position& stop() const { return _stop; }
    const std::string& aperture() const { return _aperture; } // Name/key of aperture used to create this trace
    double width() const { return _width; }
    PlotMode mode() const { return _mode; }
    /// Matters only for traces near-parallel to an axis and when width==0: if true, the normal
    /// (pointing inward the shape) aligns with the positive direction of the dominant axis.
    bool normal() const { return _normal; }
    void setNormal(bool value) { _normal = value; }

    /// True when the difference between start and stop is larger on the X axis than the Y axis.
    bool dominantX() const;

    void rotate(double angleDegrees);
    void mirrorX();
    void mirrorY();
    void scale(double factor);
    void move(const Position& offset);

private:
    Position _start;
    Position _stop;
    std::string _aperture;
    double _width;
    PlotMode _mode;
    bool _normal;
};

/// A collection of trace segments belonging to a single net.
class Trace {
public:
    Trace() = default;
    explicit Trace(std::vector<TraceSegment> segments) : _segments(std::move(segments)) {}

    const std::vector<TraceSegment>& segments() const { return _segments; }
    void addSegment(TraceSegment segment) { _segments.push_back(std::move(segment)); }
    void addSegments(const std::vector<TraceSegment>& segments) {
        _segments.insert(_segments.end(), segments.begin(), segments.end());
    }

private:
    std::vector<TraceSegment> _segments;
};

/// Abstract shape of an aperture. Concrete (not pure virtual) since an unrecognised aperture type
/// falls back to this base directly, contributing no geometry (mirrors Python's ApertureType()).
class ApertureType {
public:
    ApertureType() = default;
    virtual ~ApertureType() = default;

    std::optional<double> holeDiameter() const { return _holeDiameter; }
    void setHoleDiameter(double value) { _holeDiameter = value; }

    /// Returns the contours of this aperture with the given transform applied. `rot` is applied
    /// before scale/move; `postRot` is applied after.
    std::vector<TraceSegment> contours(std::optional<Position> pos = std::nullopt, double rot = 0,
                                        double scaleFactor = 1, const std::string& mirror = "N",
                                        double postRot = 0);

    /// Returns finely-tessellated closed polygon loops (points per loop, no repeated closing vertex)
    /// approximating this aperture's true shape with the given transform applied -- for the
    /// Clipper2-based copper compositor. Unlike contours() (a flat, often-coarse segment chain used
    /// only for grid-line-placement heuristics), this reconstructs the shape from its actual
    /// geometric definition: exact for straight-edged shapes, tessellated to `tessellationTolerance`
    /// (a chord/sagitta length, in the same units as coordinates) for curved ones. Transform
    /// parameters mirror contours() exactly. Every shape returns exactly one loop except
    /// ApertureMacro, whose sub-primitives may union into more than one disjoint region.
    std::vector<std::vector<Position>> toPolygon(std::optional<Position> pos = std::nullopt, double rot = 0,
                                                  double scaleFactor = 1, const std::string& mirror = "N",
                                                  double postRot = 0, double tessellationTolerance = 1);

protected:
    /// Returns the untransformed contours of this aperture. Non-const because ApertureMacro's
    /// override mutates its own instantiation args as a side effect (mirroring the Python source).
    virtual std::vector<TraceSegment> _contours() { return {}; }

    /// Returns the untransformed polygon loop(s) for this aperture. See toPolygon().
    virtual std::vector<std::vector<Position>> _toPolygon(double /*tessellationTolerance*/) { return {}; }

private:
    std::optional<double> _holeDiameter;
};

/// Aperture shape that is a circle.
class ApertureCircle : public ApertureType {
public:
    explicit ApertureCircle(double diameter) : _diameter(diameter) {}
    double diameter() const { return _diameter; }

protected:
    std::vector<TraceSegment> _contours() override;
    std::vector<std::vector<Position>> _toPolygon(double tessellationTolerance) override;

private:
    double _diameter;
};

/// Aperture shape that is a rectangle.
class ApertureRect : public ApertureType {
public:
    ApertureRect(double width, double height) : _width(width), _height(height) {}
    double width() const { return _width; }
    double height() const { return _height; }

protected:
    std::vector<TraceSegment> _contours() override;
    std::vector<std::vector<Position>> _toPolygon(double tessellationTolerance) override;

private:
    double _width;
    double _height;
};

/// Aperture shape that is an obround (two half circles with a rectangle in between).
class ApertureObround : public ApertureRect {
public:
    using ApertureRect::ApertureRect;

protected:
    std::vector<TraceSegment> _contours() override;
    std::vector<std::vector<Position>> _toPolygon(double tessellationTolerance) override;
};

/// Aperture shape that is a regular polygon.
class AperturePolygon : public ApertureType {
public:
    /// `diameter`: diameter of the circle circumscribing the polygon. `rotation`: in degrees
    /// counterclockwise; with rotation 0 there is a vertex on the positive X axis.
    AperturePolygon(double diameter, std::int32_t vertices, double rotation)
        : _diameter(diameter), _vertices(vertices), _rotation(rotation) {}

    double diameter() const { return _diameter; }
    std::int32_t vertices() const { return _vertices; }
    double rotation() const { return _rotation; }

protected:
    std::vector<TraceSegment> _contours() override;
    std::vector<std::vector<Position>> _toPolygon(double tessellationTolerance) override;

private:
    double _diameter;
    std::int32_t _vertices;
    double _rotation;
};

/// Aperture macro definition. Once `setArgs()` has been called (mirroring macro instantiation via
/// an AD command) it also represents that specific aperture instance.
class ApertureMacro : public ApertureType {
public:
    /// Parses an aperture macro definition from its (already `%`/`*`-stripped) definition lines.
    explicit ApertureMacro(const std::vector<std::string>& definitionLines);

    const std::string& name() const { return _name; } // Macro ID
    void setArgs(std::vector<double> args) { _args = std::move(args); } // Values for this instantiation
    const std::vector<double>& args() const { return _args; }

protected:
    std::vector<TraceSegment> _contours() override;
    std::vector<std::vector<Position>> _toPolygon(double tessellationTolerance) override;

private:
    std::string _name;
    std::vector<double> _args;
    // Expressions that calculate additional macro variables ($n = ...).
    std::vector<std::function<double(const std::vector<double>&)>> _variables;
    // Commands that create the shape of the aperture.
    std::vector<std::function<std::vector<TraceSegment>(const std::vector<double>&)>> _commands;
    // Parallel to _commands: produces each primitive's own closed polygon loop directly (rather than
    // via the TraceSegment-chain representation _commands uses), for toPolygon(). All sub-primitives
    // are treated as additive regardless of their own exposure parameter -- macro-internal
    // exposure/polarity compositing is an explicitly deferred, documented limitation matching this
    // project's existing behaviour for macro shapes generally.
    std::vector<std::function<std::vector<Position>(const std::vector<double>&, double)>> _polygonCommands;
};

/// An aperture as specified in a gerber file: a shape plus its intended function (e.g. Via,
/// SMD-pad). Shares ownership of its shape so that merging aperture maps (as the grid generator
/// does to inject synthetic port apertures) shares the same underlying instance, matching the
/// Python source's reference semantics.
class Aperture {
public:
    Aperture(std::string function, std::shared_ptr<ApertureType> data)
        : _function(std::move(function)), _data(std::move(data)) {}

    const std::string& function() const { return _function; }
    ApertureType& data() const { return *_data; }

private:
    std::string _function;
    std::shared_ptr<ApertureType> _data;
};

/// One copper-affecting paint operation, in original file order, tagged with the dark/clear
/// polarity active at the moment it was parsed. Captured alongside (not instead of) the existing
/// per-net `traces` map and flat `pads` list -- those remain net-/flash-order-only and are what
/// grid_gen.cpp keeps using unchanged; `copperOps` exists specifically so a copper-region compositor
/// can reproduce Gerber's actual dark/clear paint-order semantics, which the per-net/flat structures
/// discard (cross-net and trace-vs-pad interleaving order isn't otherwise recoverable).
struct CopperOp {
    enum class Kind { Stroke, Pad, Zone };

    Kind kind;
    bool additive; // Polarity active when this operation was parsed (dark = true, clear = false).
    // Net active when this operation was parsed (the same value that keys GerberFile::traces()/
    // GerberFile::pads() for the Stroke/Zone cases -- carried here too, uniformly across all three
    // Kinds, so a consumer can filter copperOps() by net membership without reaching into the
    // payload variant to distinguish how each Kind happens to track it).
    NetName net;
    // Stroke: a single drawn segment (already tessellated if it was an arc -- see _tessellateArc).
    // Pad: a flashed aperture.
    // Zone: a closed loop of segments forming one filled region (G36...G37), already force-closed.
    std::variant<TraceSegment, Pad, std::vector<TraceSegment>> payload;
};

/// Parsed representation of a gerber file.
class GerberFile {
public:
    /// Parses the gerber file at `path`. A constructor can't report failure, so parsing happens
    /// behind this factory instead; the object it returns is always fully parsed.
    /// `tessellationTolerance` (simulation units) controls arc-tessellation fidelity -- the same
    /// value gerber_composite.cpp's compositeOps()/triangulate() take explicitly.
    static std::expected<GerberFile, std::string> load(const std::filesystem::path& path,
                                                         double tessellationTolerance);

    /// Parts of the file that are currently not supported/interpreted by the parser.
    const std::string& unparsed() const { return _unparsed; }
    const std::unordered_map<std::string, Aperture>& apertures() const { return _apertures; }
    const std::unordered_map<NetName, Trace, NetNameHash>& traces() const { return _traces; }
    const std::vector<Pad>& pads() const { return _pads; }
    const std::vector<CopperOp>& copperOps() const { return _copperOps; }

    /// Returns the trace for `net`, or an empty Trace if none exists (mirrors dict.get(net, Trace([]))).
    Trace traceForNet(const NetName& net) const;

    /// Merges additional (name -> Aperture) entries in, overwriting existing names (mirrors
    /// dict.update()). Used by the grid generator to inject synthetic port apertures.
    void addApertures(const std::unordered_map<std::string, Aperture>& extra);

private:
    GerberFile() = default;

    struct ParserState; // Definition (and FileFormat/NumberFormat) are parsing-only, kept in the .cpp.

    std::expected<void, std::string> _parse(const std::filesystem::path& path, double tessellationTolerance);
    void _processPercentLine(const std::string& line, ParserState& parser);
    std::expected<void, std::string> _processNormalLine(const std::string& line, ParserState& parser,
                                                          double tessellationTolerance);
    std::expected<void, std::string> _processDrawingLine(const std::string& line, ParserState& parser,
                                                           double tessellationTolerance);
    void _handleApertureDefinition(const std::vector<std::string>& split, ParserState& parser);

    std::string _unparsed;
    std::unordered_map<std::string, Aperture> _apertures;
    std::unordered_map<NetName, Trace, NetNameHash> _traces;
    std::vector<Pad> _pads;
    std::unordered_map<std::string, ApertureMacro> _apMacros;
    std::vector<CopperOp> _copperOps;
};

} // namespace kiems
