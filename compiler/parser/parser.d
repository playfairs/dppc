module parser.parser;

import ast.ast;
import diagnostics.diagnostics : Diagnostics;
import lexer.lexer : Token, TokenKind;
import std.conv : to;
import std.string : replace;

public struct Parser {
    private Token[] tokens;
    private size_t index;
    private Diagnostics* diagnostics;

    this(Token[] tokens, Diagnostics* diagnostics) {
        this.tokens = tokens;
        this.diagnostics = diagnostics;
    }

    private Token current() const {
        return tokens[index < tokens.length ? index : tokens.length - 1];
    }

    private Token advance() {
        auto token = current();
        if (token.kind != TokenKind.end) {
            index++;
        }
        return token;
    }

    private bool check(string text) const {
        return current().text == text;
    }

    private bool match(string text) {
        if (!check(text)) {
            return false;
        }
        advance();
        return true;
    }

    private Token expect(string text) {
        if (check(text)) {
            return advance();
        }
        diagnostics.error(current().location, "expected '" ~ text ~ "', found '" ~ current().text ~ "'");
        return current();
    }

    private Token expectIdentifier(string role) {
        if (current().kind == TokenKind.identifier) {
            return advance();
        }
        diagnostics.error(current().location, "expected " ~ role);
        return current();
    }

    private TypeKind parseType(bool allowAuto = false) {
        if (check("void") && index + 1 < tokens.length && tokens[index + 1].text == "*") {
            advance();
            advance();
            return TypeKind.voidPointer;
        }
        if (match("const")) {
            expect("(");
            expect("char");
            expect(")");
            expect("*");
            return TypeKind.cStringPointer;
        }
        if (match("char")) {
            expect("*");
            return TypeKind.cStringPointer;
        }
        auto token = advance();
        switch (token.text) {
            case "void": return TypeKind.voidType;
            case "int": return TypeKind.intType;
            case "long": return TypeKind.longType;
            case "bool": return TypeKind.boolType;
            case "string": return TypeKind.stringType;
            case "auto":
                if (allowAuto) {
                    return TypeKind.invalid;
                }
                break;
            default:
        }
        diagnostics.error(token.location, "unsupported type '" ~ token.text ~ "'");
        return TypeKind.invalid;
    }

    public Program parseProgram() {
        Program program;
        if (match("module")) {
            program.moduleName = expectIdentifier("module name").text;
            expect(";");
        }

        while (current().kind != TokenKind.end) {
            if (check("import")) {
                auto importToken = advance();
                program.imports ~= parseImport(importToken.location);
                continue;
            }

            auto start = current();
            bool externC;
            if (match("extern")) {
                expect("(");
                auto linkage = advance();
                if (linkage.text != "C") {
                    diagnostics.error(linkage.location, "only extern(C) declarations are supported");
                }
                expect(")");
                externC = true;
            }
            auto returnType = parseType();
            auto name = expectIdentifier("function name");
            if (!match("(")) {
                diagnostics.error(current().location, "expected '(' after function name");
                synchronizeDeclaration();
                continue;
            }

            FunctionDecl declaration;
            declaration.name = name.text;
            declaration.returnType = returnType;
            declaration.location = start.location;
            declaration.externC = externC;
            if (!check(")")) {
                do {
                    auto parameterLocation = current().location;
                    auto parameterType = parseType();
                    auto parameterName = expectIdentifier("parameter name");
                    declaration.parameters ~= Parameter(parameterName.text, parameterType, parameterLocation);
                } while (match(","));
            }
            expect(")");
            if (match(";")) {
                declaration.hasBody = false;
                if (!externC) {
                    diagnostics.error(start.location, "only extern(C) function prototypes may omit a body");
                }
            } else {
                declaration.hasBody = true;
                declaration.body = parseBlock().body;
            }
            program.functions ~= declaration;
        }
        return program;
    }

    private ImportDecl parseImport(SourceLocation location) {
        ImportDecl declaration;
        declaration.location = location;
        declaration.moduleName = expectIdentifier("module name").text;
        while (match(".")) {
            declaration.moduleName ~= "." ~ expectIdentifier("module component").text;
        }
        if (match(":")) {
            do {
                declaration.symbols ~= expectIdentifier("imported symbol").text;
            } while (match(","));
        }
        expect(";");
        return declaration;
    }

    private Stmt parseBlock() {
        auto start = expect("{");
        Stmt result;
        result.kind = StmtKind.block;
        result.location = start.location;
        while (current().kind != TokenKind.end && !check("}")) {
            auto before = index;
            result.body ~= parseStatement();
            if (index == before) {
                advance();
            }
        }
        expect("}");
        return result;
    }

    private Stmt parseStatement() {
        auto start = current();
        if (check("{")) {
            return parseBlock();
        }

        if (match("return")) {
            Stmt result;
            result.kind = StmtKind.returnStatement;
            result.location = start.location;
            if (!check(";")) {
                result.expression = parseExpression();
                result.hasExpression = true;
            }
            expect(";");
            return result;
        }

        if (match("if")) {
            Stmt result;
            result.kind = StmtKind.ifStatement;
            result.location = start.location;
            expect("(");
            result.expression = parseExpression();
            expect(")");
            auto thenBlock = parseBlock();
            result.body = thenBlock.body;
            if (match("else")) {
                auto elseBlock = parseBlock();
                result.alternate = elseBlock.body;
            }
            return result;
        }

        if (match("while")) {
            Stmt result;
            result.kind = StmtKind.whileStatement;
            result.location = start.location;
            expect("(");
            result.expression = parseExpression();
            expect(")");
            result.body = parseBlock().body;
            return result;
        }

        if (current().kind == TokenKind.identifier
                && (isTypeName(current().text) || current().text == "auto"
                    || (current().text == "void" && index + 1 < tokens.length
                        && tokens[index + 1].text == "*"))) {
            Stmt result;
            result.kind = StmtKind.variable;
            result.location = start.location;
            result.inferredDeclaration = match("auto");
            if (!result.inferredDeclaration) {
                result.declaredType = parseType();
            }
            result.name = expectIdentifier("variable name").text;
            expect("=");
            result.expression = parseExpression();
            result.hasExpression = true;
            expect(";");
            return result;
        }

        Stmt result;
        result.kind = StmtKind.expression;
        result.location = start.location;
        result.expression = parseExpression();
        expect(";");
        return result;
    }

    private Expr parseExpression(int minimumPrecedence = 1) {
        auto left = parseUnary();
        while (true) {
            auto precedence = binaryPrecedence(current().text);
            if (precedence < minimumPrecedence) {
                break;
            }
            auto operation = advance();
            auto right = parseExpression(precedence + (operation.text == "=" ? 0 : 1));
            auto combined = new Expr();
            combined.kind = ExprKind.binary;
            combined.location = operation.location;
            combined.text = operation.text;
            combined.left = left;
            combined.right = right;
            left = combined;
        }
        return left;
    }

    private Expr parseUnary() {
        if (check("!") || check("-")) {
            auto operation = advance();
            auto result = new Expr();
            result.kind = ExprKind.unary;
            result.location = operation.location;
            result.text = operation.text;
            result.left = parseUnary();
            return result;
        }
        return parsePrimary();
    }

    private Expr parsePrimary() {
        auto token = advance();
        auto result = new Expr();
        result.location = token.location;

        if (token.kind == TokenKind.integer) {
            result.kind = ExprKind.integer;
            try {
                result.integerValue = to!long(token.text.replace("_", ""));
            } catch (Exception) {
                diagnostics.error(token.location, "integer literal is out of range");
            }
            return result;
        }
        if (token.kind == TokenKind.stringLiteral) {
            result.kind = ExprKind.stringLiteral;
            result.text = token.text;
            return result;
        }
        if (token.text == "null") {
            result.kind = ExprKind.nullLiteral;
            return result;
        }
        if (token.text == "true" || token.text == "false") {
            result.kind = ExprKind.boolean;
            result.booleanValue = token.text == "true";
            return result;
        }
        if (token.kind == TokenKind.identifier) {
            result.kind = ExprKind.variable;
            result.text = token.text;
            if (match("(")) {
                auto callee = result;
                result = new Expr();
                result.kind = ExprKind.call;
                result.location = token.location;
                result.left = callee;
                if (!check(")")) {
                    do {
                        result.arguments ~= parseExpression();
                    } while (match(","));
                }
                expect(")");
            }
            return result;
        }
        if (token.text == "(") {
            auto nested = parseExpression();
            expect(")");
            return nested;
        }

        diagnostics.error(token.location, "expected expression");
        result.kind = ExprKind.integer;
        return result;
    }

    private static bool isTypeName(string name) {
        return name == "int" || name == "long" || name == "bool" || name == "string";
    }

    private static int binaryPrecedence(string operation) {
        switch (operation) {
            case "=": return 1;
            case "||": return 2;
            case "&&": return 3;
            case "==", "!=": return 4;
            case "<", "<=", ">", ">=": return 5;
            case "+", "-": return 6;
            case "*", "/", "%": return 7;
            default: return 0;
        }
    }

    private void synchronizeDeclaration() {
        while (current().kind != TokenKind.end && !check(";") && !check("}")) {
            advance();
        }
        match(";");
    }
}
