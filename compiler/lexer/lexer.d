module lexer.lexer;

import ast.ast : SourceLocation;
import diagnostics.diagnostics : Diagnostics;
import std.array : appender;
import std.algorithm.searching : canFind;
import std.ascii : isAlpha, isDigit, isWhite;

public enum TokenKind
{
    identifier,
    integer,
    stringLiteral,
    symbol,
    end,
    invalid
}

public struct Token
{
    TokenKind kind;
    string text;
    SourceLocation location;
}

public struct Lexer
{
    private string source;
    private string file;
    private size_t index;
    private size_t line = 1;
    private size_t column = 1;
    private Diagnostics* diagnostics;

    this(string source, string file, Diagnostics* diagnostics)
    {
        this.source = source;
        this.file = file;
        this.diagnostics = diagnostics;
    }

    private SourceLocation location() const
    {
        return SourceLocation(file, line, column);
    }

    private char peek(size_t offset = 0) const
    {
        auto position = index + offset;
        return position < source.length ? source[position] : '\0';
    }

    private char advance()
    {
        auto ch = source[index++];
        if (ch == '\n')
        {
            line++;
            column = 1;
        }
        else
        {
            column++;
        }
        return ch;
    }

    private void skipTrivia()
    {
        while (index < source.length)
        {
            if (isWhite(peek()))
            {
                advance();
                continue;
            }
            if (peek() == '/' && peek(1) == '/')
            {
                while (index < source.length && advance() != '\n')
                {
                }
                continue;
            }
            if (peek() == '/' && peek(1) == '*')
            {
                auto start = location();
                advance();
                advance();
                while (index < source.length && !(peek() == '*' && peek(1) == '/'))
                {
                    advance();
                }
                if (index == source.length)
                {
                    diagnostics.error(start, "unterminated block comment");
                    return;
                }
                advance();
                advance();
                continue;
            }
            break;
        }
    }

    public Token nextToken()
    {
        skipTrivia();
        auto start = location();
        if (index >= source.length)
        {
            return Token(TokenKind.end, "", start);
        }

        auto ch = peek();
        if (isAlpha(ch) || ch == '_')
        {
            auto begin = index;
            while (isAlpha(peek()) || isDigit(peek()) || peek() == '_')
            {
                advance();
            }
            return Token(TokenKind.identifier, source[begin .. index].idup, start);
        }

        if (isDigit(ch))
        {
            auto begin = index;
            while (isDigit(peek()) || peek() == '_')
            {
                advance();
            }
            return Token(TokenKind.integer, source[begin .. index].idup, start);
        }

        if (ch == '"')
        {
            advance();
            auto result = appender!string();
            while (index < source.length && peek() != '"' && peek() != '\n')
            {
                auto item = advance();
                if (item == '\\')
                {
                    if (index >= source.length)
                    {
                        break;
                    }
                    auto escape = advance();
                    switch (escape)
                    {
                    case 'n':
                        result.put('\n');
                        break;
                    case 'r':
                        result.put('\r');
                        break;
                    case 't':
                        result.put('\t');
                        break;
                    case '"':
                        result.put('"');
                        break;
                    case '\\':
                        result.put('\\');
                        break;
                    default:
                        diagnostics.error(start, "unsupported string escape");
                        result.put('?');
                    }
                }
                else
                {
                    result.put(item);
                }
            }
            if (peek() != '"')
            {
                diagnostics.error(start, "unterminated string literal");
                return Token(TokenKind.invalid, "", start);
            }
            advance();
            return Token(TokenKind.stringLiteral, result.data.idup, start);
        }

        immutable twoCharacter = [
            "==", "!=", "<=", ">=", "&&", "||", "++", "--"
        ];
        foreach (candidate; twoCharacter)
        {
            if (peek() == candidate[0] && peek(1) == candidate[1])
            {
                advance();
                advance();
                return Token(TokenKind.symbol, candidate, start);
            }
        }

        if ("{}[]();.,:=+-*/%!<>~".canFind(ch))
        {
            advance();
            return Token(TokenKind.symbol, [ch], start);
        }

        advance();
        diagnostics.error(start, "unrecognized character '" ~ [ch] ~ "'");
        return Token(TokenKind.invalid, [ch], start);
    }
}
