#include "gerber_io.hpp"

#include <cctype>
#include <cmath>
#include <fstream>
#include <regex>
#include <sstream>
#include <stdexcept>

#include "constants.hpp"
#include "logging.hpp"

namespace gerber2ems {

namespace {

// ---- small string helpers (mirroring the bits of Python's str API this parser leans on) ----

std::string _stripChars(const std::string& s, std::string_view chars) {
    std::size_t begin = 0;
    while (begin < s.size() && chars.find(s[begin]) != std::string_view::npos) {
        ++begin;
    }
    std::size_t end = s.size();
    while (end > begin && chars.find(s[end - 1]) != std::string_view::npos) {
        --end;
    }
    return s.substr(begin, end - begin);
}

std::vector<std::string> _split(const std::string& s, char delimiter) {
    std::vector<std::string> parts;
    std::string current;
    for (const char c : s) {
        if (c == delimiter) {
            parts.push_back(current);
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    parts.push_back(current);
    return parts;
}

bool _startsWith(const std::string& s, std::string_view prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

std::string _removePrefix(const std::string& s, std::string_view prefix) {
    return _startsWith(s, prefix) ? s.substr(prefix.size()) : s;
}

std::string _removeSuffix(const std::string& s, std::string_view suffix) {
    if (s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0) {
        return s.substr(0, s.size() - suffix.size());
    }
    return s;
}

bool _endsWith(const std::string& s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string _lstripDigits(const std::string& s) {
    std::size_t i = 0;
    while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i])) != 0) {
        ++i;
    }
    return s.substr(i);
}

std::string _toUpper(std::string s) {
    for (char& c : s) {
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    return s;
}

std::string _rstrip(const std::string& s) {
    std::size_t end = s.size();
    while (end > 0 && std::isspace(static_cast<unsigned char>(s[end - 1])) != 0) {
        --end;
    }
    return s.substr(0, end);
}

// Mirrors Python's str.partition(sep): splits at the first occurrence of `sep`, discarding it.
// If `sep` isn't present, returns (s, "").
std::pair<std::string, std::string> _partition(const std::string& s, char sep) {
    const std::size_t pos = s.find(sep);
    if (pos == std::string::npos) {
        return {s, ""};
    }
    return {s.substr(0, pos), s.substr(pos + 1)};
}

// ---- file format / unit scale ----
//
// This really is process-global mutable state shared across every FileFormat instance, matching
// the Python source's `FileFormat.gbr2sim` ClassVar (itself set as a side effect of assigning
// `.unit`, which happens once, at FileFormat construction, to its hardcoded default "MM" -- the
// Python source never actually parses a file's `%MOMM*%`/`%MOIN*%` unit declaration or its `%FS...`
// number-format declaration, so this always resolves to the millimetre scale regardless of what
// the gerber file itself declares). Preserved as-is rather than fixed, and as a genuine global
// rather than per-instance, to match gerber2ems's current behaviour.
double _sharedGerberToSimulationScale = 0;

double _fileFormatScale() { return _sharedGerberToSimulationScale; }

/// Format used to encode floats in a gerber file. Note int_digits is stored but never actually
/// consulted anywhere (matching the Python source).
class NumberFormat {
public:
    NumberFormat() = default;
    NumberFormat(std::int32_t intDigits, std::int32_t fracDigits) : _intDigits(intDigits), _fracDigits(fracDigits) {}

    std::int32_t intDigits() const { return _intDigits; }
    std::int32_t fracDigits() const { return _fracDigits; }

    double parse(const std::string& value) const { return std::stod(value) / std::pow(10.0, _fracDigits); }

private:
    std::int32_t _intDigits = 4;
    std::int32_t _fracDigits = 6;
};

/// Format data about a gerber file (unit, number format). See the scale-state comment above: the
/// unit/number-format fields are parsed but never actually driven by the file's own declarations.
class FileFormat {
public:
    FileFormat() { setUnit("MM"); }

    const std::string& unit() const { return _unit; }
    void setUnit(const std::string& value) {
        _unit = value;
        const double mm2sim = static_cast<double>(constants::unitMultiplier) / constants::baseUnit / 1000.0;
        const double in2sim = 25.4 * static_cast<double>(constants::unitMultiplier) / constants::baseUnit / 1000.0;
        _sharedGerberToSimulationScale = (value == "MM") ? mm2sim : in2sim;
    }

    bool omitZeros() const { return _omitZeros; }
    bool absolute() const { return _absolute; }
    const NumberFormat& xFormat() const { return _xFormat; }
    const NumberFormat& yFormat() const { return _yFormat; }

    Position parsePosition(const std::string& x, const std::string& y) const {
        Position pos(_xFormat.parse(x), _yFormat.parse(y));
        pos.setX(pos.x() * _fileFormatScale());
        pos.setY(pos.y() * _fileFormatScale());
        return pos;
    }

private:
    std::string _unit = "MM";
    bool _omitZeros = true;
    bool _absolute = true;
    NumberFormat _xFormat;
    NumberFormat _yFormat;
};

// ---- points -> outline ----
// TODO(gerber2ems bug, preserved intentionally): this should almost certainly connect each point
// to the *next* one, i.e. `points[(idx + 1) % points.size()]`. As written, `idx % points.size()`
// is always just `idx` again (idx never reaches points.size() inside this loop), so every segment
// degenerates to a zero-length point-to-itself segment, meaning AperturePolygon and aperture-macro
// outline primitives currently contribute no real copper. Kept bug-for-bug to match the Python
// tool's current behaviour per explicit instruction; tracked as a follow-up fix.
std::vector<TraceSegment> _pointsToOutline(const std::vector<Position>& points) {
    std::vector<TraceSegment> segments;
    segments.reserve(points.size());
    for (std::size_t idx = 0; idx < points.size(); ++idx) {
        TraceSegment s(points[idx], points[idx % points.size()], "", 0, PlotMode::Linear);
        if (s.dominantX()) {
            s.setNormal(s.start().y() < 0);
        } else {
            s.setNormal(s.start().x() < 0);
        }
        segments.push_back(s);
    }
    return segments;
}

// ---- aperture macro expression parsing ----
// Gerber macro expressions use 'x' for multiplication and `$N` for parameter references, plus the
// usual +, -, /, unary minus and parentheses. Python's implementation just rewrites the text and
// calls eval(); here we parse once into a reusable closure evaluated against an args vector.
class _MacroExpressionParser {
public:
    explicit _MacroExpressionParser(const std::string& text) : _text(text) {}

    std::function<double(const std::vector<double>&)> parse() {
        auto result = _parseExpression();
        return result;
    }

private:
    using Expr = std::function<double(const std::vector<double>&)>;

    char _peek() const { return _pos < _text.size() ? _text[_pos] : '\0'; }
    char _advance() { return _pos < _text.size() ? _text[_pos++] : '\0'; }
    void _skipSpaces() {
        while (_pos < _text.size() && std::isspace(static_cast<unsigned char>(_text[_pos])) != 0) {
            ++_pos;
        }
    }

    Expr _parseExpression() {
        Expr left = _parseTerm();
        _skipSpaces();
        while (_peek() == '+' || _peek() == '-') {
            const char op = _advance();
            Expr right = _parseTerm();
            if (op == '+') {
                left = [left, right](const std::vector<double>& args) { return left(args) + right(args); };
            } else {
                left = [left, right](const std::vector<double>& args) { return left(args) - right(args); };
            }
            _skipSpaces();
        }
        return left;
    }

    Expr _parseTerm() {
        Expr left = _parseUnary();
        _skipSpaces();
        while (_peek() == 'x' || _peek() == 'X' || _peek() == '/') {
            const char op = _advance();
            Expr right = _parseUnary();
            if (op == '/') {
                left = [left, right](const std::vector<double>& args) { return left(args) / right(args); };
            } else {
                left = [left, right](const std::vector<double>& args) { return left(args) * right(args); };
            }
            _skipSpaces();
        }
        return left;
    }

    Expr _parseUnary() {
        _skipSpaces();
        if (_peek() == '-') {
            _advance();
            Expr operand = _parseUnary();
            return [operand](const std::vector<double>& args) { return -operand(args); };
        }
        return _parsePrimary();
    }

    Expr _parsePrimary() {
        _skipSpaces();
        if (_peek() == '(') {
            _advance();
            Expr inner = _parseExpression();
            _skipSpaces();
            if (_peek() == ')') {
                _advance();
            }
            return inner;
        }
        if (_peek() == '$') {
            _advance();
            std::string digits;
            while (std::isdigit(static_cast<unsigned char>(_peek())) != 0) {
                digits.push_back(_advance());
            }
            const std::size_t index = digits.empty() ? 0 : static_cast<std::size_t>(std::stoul(digits));
            return [index](const std::vector<double>& args) { return args.at(index); };
        }
        std::string number;
        while (std::isdigit(static_cast<unsigned char>(_peek())) != 0 || _peek() == '.') {
            number.push_back(_advance());
        }
        if (number.empty()) {
            throw std::runtime_error("Failed to parse aperture macro expression: " + _text);
        }
        const double value = std::stod(number);
        return [value](const std::vector<double>&) { return value; };
    }

    std::string _text;
    std::size_t _pos = 0;
};

std::function<double(const std::vector<double>&)> _parseMacroExpression(const std::string& text) {
    _MacroExpressionParser parser(text);
    return parser.parse();
}

} // namespace

// ---- Position ----

void Position::rotate(double angle) {
    const double newX = _x * std::cos(angle) + _y * std::sin(angle);
    const double newY = _x * std::sin(angle) + _y * std::cos(angle);
    _x = newX;
    _y = newY;
}

void Position::scale(double factor) {
    _x *= factor;
    _y *= factor;
}

void Position::move(const Position& offset) {
    _x += offset._x;
    _y += offset._y;
}

// ---- TraceSegment ----

bool TraceSegment::dominantX() const {
    return std::abs(_start.x() - _stop.x()) > std::abs(_start.y() - _stop.y());
}

void TraceSegment::rotate(double angleDegrees) {
    bool flippedNorm;
    if (dominantX()) {
        flippedNorm = (_start.y() < 0) != _normal;
    } else {
        flippedNorm = (_start.x() < 0) != _normal;
    }
    _start.rotate(angleDegrees);
    _stop.rotate(angleDegrees);
    if (dominantX()) {
        _normal = (_start.y() < 0) != flippedNorm;
    } else {
        _normal = (_start.x() < 0) != flippedNorm;
    }
    double normalizedAngle = std::fmod(angleDegrees, 360.0);
    if (normalizedAngle < 0) {
        normalizedAngle += 360.0;
    }
    if (!(normalizedAngle < 180.0)) {
        _normal = !_normal;
    }
}

void TraceSegment::mirrorX() {
    _start.mirrorX();
    _stop.mirrorX();
    if (!dominantX()) {
        _normal = !_normal;
    }
}

void TraceSegment::mirrorY() {
    _start.mirrorY();
    _stop.mirrorY();
    if (dominantX()) {
        _normal = !_normal;
    }
}

void TraceSegment::scale(double factor) {
    _start.scale(factor);
    _stop.scale(factor);
    if (!(factor > 0)) {
        _normal = !_normal;
    }
}

void TraceSegment::move(const Position& offset) {
    _start.move(offset);
    _stop.move(offset);
}

// ---- ApertureType ----

std::vector<TraceSegment> ApertureType::contours(std::optional<Position> pos, double rot, double scaleFactor,
                                                   const std::string& mirror, double postRot) {
    std::vector<TraceSegment> cont = _contours();
    const Position actualPos = pos.value_or(Position(0, 0));
    for (auto& c : cont) {
        if (mirror.find('X') != std::string::npos) {
            c.mirrorX();
        }
        if (mirror.find('Y') != std::string::npos) {
            c.mirrorY();
        }
        c.rotate(rot);
        c.scale(scaleFactor);
        c.move(actualPos);
        c.rotate(postRot);
    }
    return cont;
}

// ---- ApertureCircle ----

std::vector<TraceSegment> ApertureCircle::_contours() {
    const double halfDiameter = _diameter / 2;
    const Position points[4] = {
        Position(0, halfDiameter),
        Position(halfDiameter, 0),
        Position(-halfDiameter, 0),
        Position(0, -halfDiameter),
    };
    return {
        TraceSegment(points[0], points[1], "", 0, PlotMode::CircularClockwise),
        TraceSegment(points[1], points[2], "", 0, PlotMode::CircularClockwise),
        TraceSegment(points[2], points[3], "", 0, PlotMode::CircularClockwise),
        TraceSegment(points[3], points[0], "", 0, PlotMode::CircularClockwise),
    };
}

// ---- ApertureRect ----

std::vector<TraceSegment> ApertureRect::_contours() {
    const double halfWidth = _width / 2;
    const double halfHeight = _height / 2;
    const Position points[4] = {
        Position(halfWidth, halfHeight),
        Position(-halfWidth, halfHeight),
        Position(-halfWidth, -halfHeight),
        Position(halfWidth, -halfHeight),
    };
    return {
        TraceSegment(points[0], points[1], "", 0, PlotMode::Linear, false),
        TraceSegment(points[1], points[2], "", 0, PlotMode::Linear, true),
        TraceSegment(points[2], points[3], "", 0, PlotMode::Linear, true),
        TraceSegment(points[3], points[0], "", 0, PlotMode::Linear, false),
    };
}

// ---- ApertureObround ----

std::vector<TraceSegment> ApertureObround::_contours() {
    const double halfWidth = width() / 2;
    const double halfHeight = height() / 2;
    const double d = halfHeight - halfWidth;
    const Position rect[4] = {
        Position(d, halfHeight),
        Position(-d, halfHeight),
        Position(-d, -halfHeight),
        Position(d, -halfHeight),
    };
    const Position circ[2] = {Position(halfWidth, 0), Position(-halfWidth, 0)};
    return {
        TraceSegment(rect[0], rect[1], "", 0, PlotMode::Linear, false),
        TraceSegment(rect[2], rect[3], "", 0, PlotMode::Linear, true),
        TraceSegment(rect[0], circ[0], "", 0, PlotMode::CircularClockwise),
        TraceSegment(rect[3], circ[0], "", 0, PlotMode::CircularClockwise),
        TraceSegment(rect[1], circ[1], "", 0, PlotMode::CircularClockwise),
        TraceSegment(rect[2], circ[1], "", 0, PlotMode::CircularClockwise),
    };
}

// ---- AperturePolygon ----

std::vector<TraceSegment> AperturePolygon::_contours() {
    std::vector<Position> points;
    points.reserve(static_cast<std::size_t>(_vertices));
    const double d2 = _diameter;
    for (std::int32_t i = 0; i < _vertices; ++i) {
        const double angleDegrees = _rotation + 360.0 * static_cast<double>(i) / static_cast<double>(_vertices);
        const double angle = angleDegrees * (M_PI / 180.0);
        points.emplace_back(d2 * std::cos(angle), d2 * std::sin(angle));
    }
    return _pointsToOutline(points);
}

// ---- ApertureMacro ----

ApertureMacro::ApertureMacro(const std::vector<std::string>& definitionLines) {
    if (definitionLines.empty()) {
        return;
    }
    _name = _removePrefix(definitionLines.front(), "AM");

    for (std::size_t li = 1; li < definitionLines.size(); ++li) {
        const std::string& line = definitionLines[li];
        if (_startsWith(line, "0")) {
            continue; // comment line
        }
        if (_startsWith(line, "$")) {
            _variables.push_back(_parseMacroExpression(_partition(line, '=').second));
            continue;
        }

        const std::vector<std::string> lineParts = _split(line, ',');
        const std::string op = lineParts.front();
        std::vector<std::function<double(const std::vector<double>&)>> sline;
        for (std::size_t i = 1; i < lineParts.size(); ++i) {
            sline.push_back(_parseMacroExpression(lineParts[i]));
        }

        if (op == "1") {
            // circle
            _commands.push_back([sline](const std::vector<double>& args) -> std::vector<TraceSegment> {
                std::vector<double> param;
                param.reserve(sline.size());
                for (const auto& p : sline) {
                    param.push_back(p(args));
                }
                ApertureCircle ap(param.at(1) * _fileFormatScale());
                const double rot = param.size() > 4 ? param[4] : 0;
                return ap.contours(Position(param.at(2) * _fileFormatScale(), param.at(3) * _fileFormatScale()), 0, 1,
                                    "N", rot);
            });
        } else if (op == "20") {
            // line start/stop/width
            _commands.push_back([sline](const std::vector<double>& args) -> std::vector<TraceSegment> {
                std::vector<double> param;
                param.reserve(sline.size());
                for (const auto& p : sline) {
                    param.push_back(p(args));
                }
                TraceSegment trace(
                    Position(param.at(2) * _fileFormatScale(), param.at(3) * _fileFormatScale()),
                    Position(param.at(4) * _fileFormatScale(), param.at(5) * _fileFormatScale()), "",
                    param.at(1) * _fileFormatScale());
                trace.rotate(param.at(6));
                return {trace};
            });
        } else if (op == "21") {
            // line center/width/length
            _commands.push_back([sline](const std::vector<double>& args) -> std::vector<TraceSegment> {
                std::vector<double> param;
                param.reserve(sline.size());
                for (const auto& p : sline) {
                    param.push_back(p(args));
                }
                const double len2 = _fileFormatScale() * param.at(1) / 2;
                TraceSegment trace(
                    Position(param.at(3) * _fileFormatScale() - len2, param.at(4) * _fileFormatScale()),
                    Position(param.at(3) * _fileFormatScale() + len2, param.at(4) * _fileFormatScale()), "",
                    param.at(2) * _fileFormatScale());
                trace.rotate(param.at(5));
                return {trace};
            });
        } else if (op == "4") {
            // outline
            _commands.push_back([sline](const std::vector<double>& args) -> std::vector<TraceSegment> {
                std::vector<double> param;
                param.reserve(sline.size());
                for (const auto& p : sline) {
                    param.push_back(p(args));
                }
                std::vector<Position> points;
                const auto vertexCount = static_cast<std::size_t>(param.at(1));
                for (std::size_t i = 0; i <= vertexCount; ++i) {
                    points.emplace_back(param.at(2 + i * 2) * _fileFormatScale(),
                                         param.at(3 + i * 2) * _fileFormatScale());
                }
                std::vector<TraceSegment> contours = _pointsToOutline(points);
                for (auto& seg : contours) {
                    seg.rotate(param.back());
                }
                return contours;
            });
        } else if (op == "5") {
            // polygon
            _commands.push_back([sline](const std::vector<double>& args) -> std::vector<TraceSegment> {
                std::vector<double> param;
                param.reserve(sline.size());
                for (const auto& p : sline) {
                    param.push_back(p(args));
                }
                AperturePolygon ap(param.at(4) * _fileFormatScale(), static_cast<std::int32_t>(param.at(1)), 0);
                return ap.contours(Position(param.at(2) * _fileFormatScale(), param.at(3) * _fileFormatScale()), 0, 1,
                                    "N", param.at(5));
            });
        } else if (op == "7") {
            // Thermal relief -- TODO, matches the Python source (unimplemented, silently skipped).
        } else {
            throw std::runtime_error("Unknown aperture macro op: " + line);
        }
    }
}

std::vector<TraceSegment> ApertureMacro::_contours() {
    for (const auto& variable : _variables) {
        std::vector<double> callArgs;
        callArgs.reserve(_args.size() + 1);
        callArgs.push_back(0.0);
        callArgs.insert(callArgs.end(), _args.begin(), _args.end());
        _args.push_back(variable(callArgs));
    }
    std::vector<TraceSegment> contours;
    for (const auto& command : _commands) {
        std::vector<double> callArgs;
        callArgs.reserve(_args.size() + 1);
        callArgs.push_back(0.0);
        callArgs.insert(callArgs.end(), _args.begin(), _args.end());
        std::vector<TraceSegment> segs = command(callArgs);
        contours.insert(contours.end(), segs.begin(), segs.end());
    }
    return contours;
}

// ---- GerberFile ----

/// Temporary state of the gerber file parser. Purely internal (never visible outside GerberFile),
/// so its fields are left as plain mutable state rather than getter/setter-encapsulated.
struct GerberFile::ParserState {
    std::string aperture;        // Recently set aperture (used for upcoming trace/pad creation)
    std::string apertureFunc;    // Recently set aperture function (applies to upcoming aperture decls)
    std::string net = "no-net";  // Recently set net (used for upcoming trace/pad creation)
    std::optional<PadMeta> refpin;
    bool unparsedRegion = false; // Region of code currently ignored by the parser
    Position pos;                // Current position (used for upcoming trace creation)
    PlotMode plotMode = PlotMode::Linear;
    bool additive = true;
    std::string mirror = "N";
    double rotation = 0;
    double scale = 1;
    FileFormat fformat;
    bool zone = false; // Plotting zone (started by G37, ends with G36)
    std::vector<TraceSegment> zoneContours;
    std::vector<std::string> apMacro; // Body of the currently-parsed aperture macro
};

GerberFile::GerberFile(const std::filesystem::path& path) {
    logInfo("Parsing gerber file: " + path.string());
    std::ifstream fileHandle(path);
    std::stringstream buffer;
    buffer << fileHandle.rdbuf();
    const std::string file = buffer.str();

    static const std::regex lineRegex(R"(.*\*%?\n)");
    ParserState parser;
    for (auto it = std::sregex_iterator(file.begin(), file.end(), lineRegex); it != std::sregex_iterator(); ++it) {
        const std::string line = it->str();
        if (_startsWith(line, "%")) {
            _processPercentLine(line, parser);
        } else {
            _processNormalLine(line, parser);
        }
    }
}

Trace GerberFile::traceForNet(const std::string& net) const {
    const auto it = _traces.find(net);
    if (it != _traces.end()) {
        return it->second;
    }
    return Trace();
}

void GerberFile::addApertures(const std::unordered_map<std::string, Aperture>& extra) {
    for (const auto& [key, value] : extra) {
        _apertures.insert_or_assign(key, value);
    }
}

void GerberFile::_handleApertureDefinition(const std::vector<std::string>& split, ParserState& parser) {
    const std::string fullId = _removePrefix(split[0], "AD");
    std::string apertureDataType = _lstripDigits(_removePrefix(fullId, "D"));
    const std::string name = _removeSuffix(fullId, apertureDataType);

    const std::vector<std::string> p = split.size() > 1 ? _split(split[1], 'X') : std::vector<std::string>{};
    std::size_t pUsed = p.size();
    std::shared_ptr<ApertureType> apertureData = std::make_shared<ApertureType>();
    const double scale = _fileFormatScale();

    if (apertureDataType == "C") {
        apertureData = std::make_shared<ApertureCircle>(std::stod(p.at(0)) * scale);
        pUsed = 1;
    } else if (apertureDataType == "R") {
        apertureData = std::make_shared<ApertureRect>(std::stod(p.at(0)) * scale, std::stod(p.at(1)) * scale);
        pUsed = 2;
    } else if (apertureDataType == "O") {
        apertureData = std::make_shared<ApertureObround>(std::stod(p.at(0)) * scale, std::stod(p.at(1)) * scale);
        pUsed = 2;
    } else if (apertureDataType == "P") {
        apertureData = std::make_shared<AperturePolygon>(
            std::stod(p.at(0)) * scale, static_cast<std::int32_t>(std::stoi(p.at(1))), std::stod(p.at(2)));
        pUsed = 3;
    } else if (const auto it = _apMacros.find(apertureDataType); it != _apMacros.end()) {
        pUsed = p.size();
        std::vector<double> args;
        args.reserve(p.size());
        for (const auto& value : p) {
            args.push_back(std::stod(value));
        }
        ApertureMacro instance = it->second;
        instance.setArgs(std::move(args));
        apertureData = std::make_shared<ApertureMacro>(std::move(instance));
    }

    if (pUsed < p.size()) {
        apertureData->setHoleDiameter(std::stod(p.at(pUsed)) * scale);
    }
    _apertures.insert_or_assign(name, Aperture(parser.apertureFunc, apertureData));
}

void GerberFile::_processPercentLine(const std::string& line, ParserState& parser) {
    _unparsed += line;
    const std::string sline = _stripChars(line, "%*\n");
    const std::vector<std::string> split = _split(sline, ',');

    if (split[0].size() >= 2 && split[0].compare(0, 2, "AM") == 0) {
        parser.apMacro.push_back(sline);
    } else if (split[0] == "TO.P") {
        parser.refpin = PadMeta(split.at(1), split.at(2), split.size() > 3 ? split[3] : "");
    } else if (split[0] == "TO.N") {
        parser.net = split.at(1);
    } else if (split[0] == "TA" && split.size() > 1 && split[1] == "AperFunction") {
        parser.apertureFunc = split.at(2);
    } else if (split[0] == "TD") {
        parser.net = "no-net";
        parser.refpin = std::nullopt;
    } else if (split[0].size() >= 2 && split[0].compare(0, 2, "LP") == 0) {
        parser.additive = split[0][2] == 'D';
    } else if (split[0].size() >= 2 && split[0].compare(0, 2, "LR") == 0) {
        parser.rotation = std::stod(split[0].substr(2));
    } else if (split[0].size() >= 2 && split[0].compare(0, 2, "LM") == 0) {
        parser.mirror = _toUpper(split[0].substr(2));
    } else if (split[0].size() >= 2 && split[0].compare(0, 2, "LS") == 0) {
        parser.scale = std::stod(split[0].substr(2));
    } else if (_startsWith(split[0], "AD")) {
        _handleApertureDefinition(split, parser);
    }
}

void GerberFile::_processNormalLine(const std::string& line, ParserState& parser) {
    const std::string sline = _stripChars(line, "%*\n");
    const std::vector<std::string> split = _split(sline, ',');

    if (split[0] == "AB" || split[0] == "SR") {
        parser.unparsedRegion = !parser.unparsedRegion;
    }

    if (parser.unparsedRegion) {
        _unparsed += line;
        return;
    }

    if (!parser.apMacro.empty()) {
        parser.apMacro.push_back(sline);
        if (_endsWith(_rstrip(line), "%")) {
            ApertureMacro apm(parser.apMacro);
            const std::string name = apm.name();
            _apMacros.insert_or_assign(name, std::move(apm));
            parser.apMacro.clear();
        }
    } else if (split[0] == "G36") {
        parser.zoneContours.clear();
        parser.zone = true;
    } else if (split[0] == "G37") {
        const Position sStart = parser.zoneContours.front().start();
        const Position sEnd = parser.zoneContours.back().stop();
        parser.zoneContours.emplace_back(sStart, sEnd, "", 0, PlotMode::Linear);
        Trace trace = traceForNet(parser.net);
        trace.addSegments(parser.zoneContours);
        _traces.insert_or_assign(parser.net, trace);
        parser.zoneContours.clear();
        parser.zone = false;
    } else if (split[0].size() >= 3 && (split[0].compare(0, 3, "G04") == 0 || split[0].compare(0, 3, "G75") == 0)) {
        _unparsed += line;
    } else if (_startsWith(split[0], "G")) {
        parser.plotMode = static_cast<PlotMode>(split[0].at(2) - '0');
    } else if (_startsWith(split[0], "D")) {
        parser.aperture = split[0];
    } else if (_startsWith(split[0], "X")) {
        _processDrawingLine(sline, parser);
    }
}

void GerberFile::_processDrawingLine(const std::string& line, ParserState& parser) {
    const std::string sline = _removePrefix(line, "X");
    const auto [x, afterX] = _partition(sline, 'Y');
    const auto [y1, afterY] = _partition(afterX, 'D');
    const auto [y2, afterJ] = _partition(y1, 'J');
    const auto [y, afterI] = _partition(y2, 'I');
    (void)afterJ;
    (void)afterI;
    const std::string& op = afterY;

    const Position pos = parser.fformat.parsePosition(x, y);
    const std::int32_t opi = static_cast<std::int32_t>(std::stoi(op));

    if (opi == 1) {
        if (parser.zone) {
            parser.zoneContours.emplace_back(parser.pos, pos, "", 0, parser.plotMode);
        } else {
            Trace trace = traceForNet(parser.net);
            const std::string apName = parser.aperture;
            const auto it = _apertures.find(apName);
            if (it == _apertures.end()) {
                logError("Aperture `" + apName + "` used for line: `" + line + "` not defined!");
                return;
            }
            auto* circle = dynamic_cast<ApertureCircle*>(&it->second.data());
            if (circle == nullptr) {
                logError("Aperture `" + apName + "` used for line: `" + line + "` is not circular aperture!");
                return;
            }
            trace.addSegment(TraceSegment(parser.pos, pos, apName, circle->diameter(), parser.plotMode));
            _traces.insert_or_assign(parser.net, trace);
        }
        parser.pos = pos;
    } else if (opi == 2) {
        parser.pos = pos;
    } else if (opi == 3) {
        const auto it = _apertures.find(parser.aperture);
        std::optional<PadMeta> pinRef;
        if (it != _apertures.end() && it->second.function() == "ComponentPad") {
            pinRef = parser.refpin;
        }
        _pads.emplace_back(parser.aperture, parser.net, pos, pinRef, parser.additive, parser.mirror, parser.rotation,
                            parser.scale);
    }
}

} // namespace gerber2ems
