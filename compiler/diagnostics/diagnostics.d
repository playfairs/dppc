module diagnostics.diagnostics;

import ast.ast : SourceLocation;
import std.stdio : stderr;

public enum Severity
{
    error,
    warning
}

public struct Diagnostic
{
    Severity severity;
    SourceLocation location;
    string message;
}

public struct Diagnostics
{
    Diagnostic[] entries;

    public void error(SourceLocation location, string message)
    {
        entries ~= Diagnostic(Severity.error, location, message);
    }

    public void warning(SourceLocation location, string message)
    {
        entries ~= Diagnostic(Severity.warning, location, message);
    }

    public bool hasErrors() const
    {
        foreach (entry; entries)
        {
            if (entry.severity == Severity.error)
            {
                return true;
            }
        }
        return false;
    }

    public void print() const
    {
        foreach (entry; entries)
        {
            auto label = entry.severity == Severity.error ? "error" : "warning";
            stderr.writefln("%s:%s:%s: %s: %s", entry.location.file,
                    entry.location.line, entry.location.column, label, entry.message);
        }
    }
}
