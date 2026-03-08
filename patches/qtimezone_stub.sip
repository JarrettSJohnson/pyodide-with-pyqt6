// Minimal QTimeZone stub for WASM builds where QT_CONFIG(timezone) is disabled.
// Only exposes the always-available API (no timezone backend features).

class QTimeZone
{
%TypeHeaderCode
#include <qtimezone.h>
%End

public:
    enum Initialization
    {
        LocalTime,
        UTC,
    };

%If (Qt_6_5_0 -)
    QTimeZone(QTimeZone::Initialization spec);
%End
    QTimeZone(const QTimeZone &other);
    QTimeZone();
    ~QTimeZone();
    void swap(QTimeZone &other /Constrained/);
    bool isValid() const;
%If (- Qt_6_7_0)
    bool operator==(const QTimeZone &other) const;
%End
%If (- Qt_6_7_0)
    bool operator!=(const QTimeZone &other) const;
%End
%If (Qt_6_5_0 -)
    static QTimeZone fromSecondsAheadOfUtc(int offset);
%End
%If (Qt_6_5_0 -)
    Qt::TimeSpec timeSpec() const;
%End
%If (Qt_6_5_0 -)
    int fixedSecondsAheadOfUtc() const;
%End
%If (Qt_6_5_0 -)
    bool isUtcOrFixedOffset() const;
%End
%If (Qt_6_5_0 -)
    static bool isUtcOrFixedOffset(Qt::TimeSpec spec);
%End
%If (Qt_6_6_0 -)
    static const int MinUtcOffsetSecs;
%End
%If (Qt_6_6_0 -)
    static const int MaxUtcOffsetSecs;
%End
};

%If (Qt_6_7_0 -)
bool operator==(const QTimeZone &lhs, const QTimeZone &rhs);
%End
%If (Qt_6_7_0 -)
bool operator!=(const QTimeZone &lhs, const QTimeZone &rhs);
%End
