// Gerber file parsing and representation. Ported from gerber2ems/gerber_io.py.
#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace gerber2ems {

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
    double _x = 0;
    double _y = 0;
};

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
    Pad(std::string aperture, std::string net, Position pos, std::optional<PadMeta> pinRef = std::nullopt,
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
    const std::string& net() const { return _net; }
    const Position& pos() const { return _pos; }
    const std::optional<PadMeta>& pinRef() const { return _pinRef; }
    bool additive() const { return _additive; } // If false, this pad erases rather than draws
    const std::string& mirror() const { return _mirror; }
    double rotation() const { return _rotation; }
    double scale() const { return _scale; }

private:
    std::string _aperture;
    std::string _net;
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

protected:
    /// Returns the untransformed contours of this aperture. Non-const because ApertureMacro's
    /// override mutates its own instantiation args as a side effect (mirroring the Python source).
    virtual std::vector<TraceSegment> _contours() { return {}; }

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

private:
    std::string _name;
    std::vector<double> _args;
    // Expressions that calculate additional macro variables ($n = ...).
    std::vector<std::function<double(const std::vector<double>&)>> _variables;
    // Commands that create the shape of the aperture.
    std::vector<std::function<std::vector<TraceSegment>(const std::vector<double>&)>> _commands;
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

/// Parsed representation of a gerber file.
class GerberFile {
public:
    explicit GerberFile(const std::filesystem::path& path);

    /// Parts of the file that are currently not supported/interpreted by the parser.
    const std::string& unparsed() const { return _unparsed; }
    const std::unordered_map<std::string, Aperture>& apertures() const { return _apertures; }
    const std::unordered_map<std::string, Trace>& traces() const { return _traces; }
    const std::vector<Pad>& pads() const { return _pads; }

    /// Returns the trace for `net`, or an empty Trace if none exists (mirrors dict.get(net, Trace([]))).
    Trace traceForNet(const std::string& net) const;

    /// Merges additional (name -> Aperture) entries in, overwriting existing names (mirrors
    /// dict.update()). Used by the grid generator to inject synthetic port apertures.
    void addApertures(const std::unordered_map<std::string, Aperture>& extra);

private:
    struct ParserState; // Definition (and FileFormat/NumberFormat) are parsing-only, kept in the .cpp.

    void _processPercentLine(const std::string& line, ParserState& parser);
    void _processNormalLine(const std::string& line, ParserState& parser);
    void _processDrawingLine(const std::string& line, ParserState& parser);
    void _handleApertureDefinition(const std::vector<std::string>& split, ParserState& parser);

    std::string _unparsed;
    std::unordered_map<std::string, Aperture> _apertures;
    std::unordered_map<std::string, Trace> _traces;
    std::vector<Pad> _pads;
    std::unordered_map<std::string, ApertureMacro> _apMacros;
};

} // namespace gerber2ems
