module parser.parser;

import ast.ast;
import diagnostics.diagnostics : Diagnostics;
import lexer.lexer : Token, TokenKind;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.string : replace;

public struct Parser
{
    private Token[] tokens;
    private size_t index;
    private Diagnostics* diagnostics;
    private string[] structNames;

    this(Token[] tokens, Diagnostics* diagnostics)
    {
        this.tokens = tokens;
        this.diagnostics = diagnostics;
    }

    private bool parseFixedArraySuffix(ref TypeKind type, ref string namedType,
            ref size_t arrayLength, ref TypeKind elementType)
    {
        if (!match("["))
        {
            return false;
        }
        auto sizeToken = advance();
        if (sizeToken.kind != TokenKind.integer)
        {
            diagnostics.error(sizeToken.location, "fixed-array length must be an integer literal");
        }
        else
        {
            try
            {
                auto parsedLength = to!ulong(sizeToken.text.replace("_", ""));
                if (parsedLength == 0 || parsedLength > 1024)
                {
                    diagnostics.error(sizeToken.location,
                            "fixed-array length must be between 1 and 1024");
                }
                else
                {
                    arrayLength = cast(size_t) parsedLength;
                }
            }
            catch (Exception)
            {
                diagnostics.error(sizeToken.location, "fixed-array length is out of range");
            }
        }
        expect("]");
        elementType = type;
        if (type != TypeKind.structType)
        {
            diagnostics.error(sizeToken.location,
                    "this compiler increment supports fixed arrays of structs only");
        }
        type = TypeKind.fixedArray;
        return true;
    }

    private Token current() const
    {
        return tokens[index < tokens.length ? index : tokens.length - 1];
    }

    private Token advance()
    {
        auto token = current();
        if (token.kind != TokenKind.end)
        {
            index++;
        }
        return token;
    }

    private bool check(string text) const
    {
        return current().text == text;
    }

    private bool match(string text)
    {
        if (!check(text))
        {
            return false;
        }
        advance();
        return true;
    }

    private Token expect(string text)
    {
        if (check(text))
        {
            return advance();
        }
        diagnostics.error(current().location,
                "expected '" ~ text ~ "', found '" ~ current().text ~ "'");
        return current();
    }

    private Token expectIdentifier(string role)
    {
        if (current().kind == TokenKind.identifier)
        {
            return advance();
        }
        diagnostics.error(current().location, "expected " ~ role);
        return current();
    }

    private TypeKind parseType(bool allowAuto = false)
    {
        string ignoredName;
        return parseType(ignoredName, allowAuto);
    }

    private TypeKind parseType(out string namedType, bool allowAuto = false)
    {
        namedType = "";
        if (check("void") && index + 1 < tokens.length && tokens[index + 1].text == "*")
        {
            advance();
            advance();
            return TypeKind.voidPointer;
        }
        if (match("const"))
        {
            expect("(");
            expect("char");
            expect(")");
            expect("*");
            return TypeKind.cStringPointer;
        }
        if (match("char"))
        {
            expect("*");
            return TypeKind.cStringPointer;
        }
        auto token = advance();
        if (token.kind == TokenKind.identifier && structNames.canFind(token.text))
        {
            namedType = token.text;
            return TypeKind.structType;
        }
        switch (token.text)
        {
        case "void":
            return TypeKind.voidType;
        case "pointer":
            return TypeKind.voidPointer;
        case "int":
            return TypeKind.intType;
        case "long":
            return TypeKind.longType;
        case "bool":
            return TypeKind.boolType;
        case "string":
            return TypeKind.stringType;
        case "auto":
            if (allowAuto)
            {
                return TypeKind.invalid;
            }
            break;
        default:
        }
        diagnostics.error(token.location, "unsupported type '" ~ token.text ~ "'");
        return TypeKind.invalid;
    }

    public Program parseProgram()
    {
        Program program;
        if (match("module"))
        {
            program.moduleName = expectIdentifier("module name").text;
            expect(";");
        }

        while (current().kind != TokenKind.end)
        {
            if (check("import"))
            {
                auto importToken = advance();
                program.imports ~= parseImport(importToken.location);
                continue;
            }
            if (check("struct"))
            {
                auto structure = parseStruct(program);
                program.structs ~= structure;
                continue;
            }

            auto start = current();
            bool externC;
            if (match("extern"))
            {
                expect("(");
                auto linkage = advance();
                if (linkage.text != "C")
                {
                    diagnostics.error(linkage.location,
                            "only extern(C) declarations are supported");
                }
                expect(")");
                externC = true;
            }
            string returnNamedType;
            auto returnType = parseType(returnNamedType);
            size_t returnArrayLength;
            TypeKind returnElementType;
            if (parseFixedArraySuffix(returnType, returnNamedType,
                    returnArrayLength, returnElementType))
            {
                diagnostics.error(start.location,
                        "fixed-array function return types are not supported");
            }
            auto name = expectIdentifier("function name");
            if (!match("("))
            {
                diagnostics.error(current().location, "expected '(' after function name");
                synchronizeDeclaration();
                continue;
            }

            FunctionDecl declaration;
            declaration.name = name.text;
            declaration.sourceName = name.text;
            declaration.returnType = returnType;
            declaration.returnNamedType = returnNamedType;
            declaration.location = start.location;
            declaration.externC = externC;
            if (!check(")"))
            {
                do
                {
                    declaration.parameters ~= parseParameter();
                }
                while (match(","));
            }
            expect(")");
            if (match(";"))
            {
                declaration.hasBody = false;
                if (!externC)
                {
                    diagnostics.error(start.location,
                            "only extern(C) function prototypes may omit a body");
                }
            }
            else
            {
                declaration.hasBody = true;
                declaration.body = parseBlock().body;
            }
            program.functions ~= declaration;
        }
        return program;
    }

    private StructDecl parseStruct(ref Program program)
    {
        auto start = advance();
        auto name = expectIdentifier("struct name");
        StructDecl structure;
        structure.name = name.text;
        structure.location = start.location;
        if (structNames.canFind(structure.name))
        {
            diagnostics.error(name.location, "duplicate struct '" ~ structure.name ~ "'");
        }
        else
        {
            structNames ~= structure.name;
        }
        expect("{");
        size_t constructorIndex;
        size_t methodIndex;
        while (current().kind != TokenKind.end && !check("}"))
        {
            if (match("~"))
            {
                auto destructorLocation = tokens[index - 1].location;
                auto thisToken = expectIdentifier("'this' in destructor");
                if (thisToken.text != "this")
                {
                    diagnostics.error(thisToken.location, "struct destructor must be named ~this");
                }
                expect("(");
                expect(")");
                FunctionDecl destructor;
                destructor.name = "__dtor_" ~ structure.name;
                destructor.sourceName = "~this";
                destructor.returnType = TypeKind.voidType;
                destructor.location = destructorLocation;
                destructor.hasBody = true;
                destructor.isDestructor = true;
                destructor.ownerType = structure.name;
                destructor.parameters ~= Parameter("this", TypeKind.structType,
                        destructorLocation, structure.name, true);
                destructor.body = parseBlock().body;
                if (structure.destructorName.length)
                {
                    diagnostics.error(destructorLocation,
                            "struct '" ~ structure.name ~ "' has more than one destructor");
                }
                else
                {
                    structure.destructorName = destructor.name;
                    structure.hasUserDestructor = true;
                }
                program.functions ~= destructor;
                continue;
            }

            if (current().kind == TokenKind.identifier && current()
                    .text == structure.name && index + 1 < tokens.length
                    && tokens[index + 1].text == "(")
            {
                auto constructorLocation = current().location;
                advance();
                FunctionDecl constructor;
                constructor.name = "__dpp_ctor_" ~ structure.name ~ "_" ~ to!string(
                        constructorIndex++);
                constructor.sourceName = structure.name;
                constructor.returnType = TypeKind.voidType;
                constructor.location = constructorLocation;
                constructor.hasBody = true;
                constructor.isConstructor = true;
                constructor.ownerType = structure.name;
                constructor.parameters ~= Parameter("this", TypeKind.structType,
                        constructorLocation, structure.name, true);
                parseMemberParameters(constructor);
                constructor.body = parseBlock().body;
                structure.constructorNames ~= constructor.name;
                program.functions ~= constructor;
                continue;
            }

            auto fieldLocation = current().location;
            string namedType;
            auto fieldType = parseType(namedType);
            size_t arrayLength;
            TypeKind elementType;
            parseFixedArraySuffix(fieldType, namedType, arrayLength, elementType);
            auto fieldName = expectIdentifier("field name");
            if (match("("))
            {
                FunctionDecl method;
                method.name = "__dpp_method_" ~ structure.name ~ "_" ~ fieldName.text ~ "_" ~ to!string(
                        methodIndex++);
                method.sourceName = fieldName.text;
                method.returnType = fieldType;
                method.returnNamedType = namedType;
                method.location = fieldLocation;
                method.hasBody = true;
                method.isMethod = true;
                method.ownerType = structure.name;
                method.parameters ~= Parameter("this", TypeKind.structType,
                        fieldLocation, structure.name, true);
                if (!check(")"))
                {
                    do
                    {
                        method.parameters ~= parseParameter();
                    }
                    while (match(","));
                }
                expect(")");
                method.body = parseBlock().body;
                program.functions ~= method;
                continue;
            }
            expect(";");
            if (fieldType == TypeKind.voidType || fieldType == TypeKind.invalid
                    || fieldType == TypeKind.stringType)
            {
                diagnostics.error(fieldLocation,
                        "struct fields currently support scalar, pointer, struct, or fixed-array-of-struct types");
            }
            foreach (field; structure.fields)
            {
                if (field.name == fieldName.text)
                {
                    diagnostics.error(fieldName.location,
                            "duplicate field '" ~ fieldName.text
                            ~ "' in struct '" ~ structure.name ~ "'");
                }
            }
            FieldDecl field;
            field.name = fieldName.text;
            field.type = fieldType;
            field.namedType = namedType;
            field.location = fieldLocation;
            field.elementType = elementType;
            field.arrayLength = arrayLength;
            structure.fields ~= field;
        }
        expect("}");
        return structure;
    }

    private Parameter parseParameter()
    {
        auto parameterLocation = current().location;
        string namedType;
        auto parameterType = parseType(namedType);
        auto parameterName = expectIdentifier("parameter name");
        return Parameter(parameterName.text, parameterType, parameterLocation, namedType);
    }

    private void parseMemberParameters(ref FunctionDecl declaration)
    {
        expect("(");
        if (!check(")"))
        {
            do
            {
                declaration.parameters ~= parseParameter();
            }
            while (match(","));
        }
        expect(")");
    }

    private ImportDecl parseImport(SourceLocation location)
    {
        ImportDecl declaration;
        declaration.location = location;
        declaration.moduleName = expectIdentifier("module name").text;
        while (match("."))
        {
            declaration.moduleName ~= "." ~ expectIdentifier("module component").text;
        }
        if (match(":"))
        {
            do
            {
                declaration.symbols ~= expectIdentifier("imported symbol").text;
            }
            while (match(","));
        }
        expect(";");
        return declaration;
    }

    private Stmt parseBlock()
    {
        auto start = expect("{");
        Stmt result;
        result.kind = StmtKind.block;
        result.location = start.location;
        while (current().kind != TokenKind.end && !check("}"))
        {
            auto before = index;
            result.body ~= parseStatement();
            if (index == before)
            {
                advance();
            }
        }
        expect("}");
        return result;
    }

    private Stmt parseStatement()
    {
        auto start = current();
        if (check("{"))
        {
            return parseBlock();
        }

        if (match("scope"))
        {
            Stmt result;
            result.kind = StmtKind.scopeExit;
            result.location = start.location;
            expect("(");
            auto exitKind = advance();
            if (exitKind.text != "exit")
            {
                diagnostics.error(exitKind.location, "only scope(exit) cleanup is supported");
            }
            expect(")");
            result.expression = parseExpression();
            expect(";");
            return result;
        }

        if (match("break"))
        {
            Stmt result;
            result.kind = StmtKind.breakStatement;
            result.location = start.location;
            expect(";");
            return result;
        }

        if (match("continue"))
        {
            Stmt result;
            result.kind = StmtKind.continueStatement;
            result.location = start.location;
            expect(";");
            return result;
        }

        if (match("return"))
        {
            Stmt result;
            result.kind = StmtKind.returnStatement;
            result.location = start.location;
            if (!check(";"))
            {
                result.expression = parseExpression();
                result.hasExpression = true;
            }
            expect(";");
            return result;
        }

        if (match("if"))
        {
            Stmt result;
            result.kind = StmtKind.ifStatement;
            result.location = start.location;
            expect("(");
            result.expression = parseExpression();
            expect(")");
            auto thenBlock = parseBlock();
            result.body = thenBlock.body;
            if (match("else"))
            {
                auto elseBlock = parseBlock();
                result.alternate = elseBlock.body;
            }
            return result;
        }

        if (match("while"))
        {
            Stmt result;
            result.kind = StmtKind.whileStatement;
            result.location = start.location;
            expect("(");
            result.expression = parseExpression();
            expect(")");
            result.body = parseBlock().body;
            return result;
        }

        if (current().kind == TokenKind.identifier && (isTypeName(current()
                .text) || structNames.canFind(current().text) || current()
                .text == "auto" || (current().text == "void"
                && index + 1 < tokens.length && tokens[index + 1].text == "*")))
        {
            Stmt result;
            result.kind = StmtKind.variable;
            result.location = start.location;
            result.inferredDeclaration = match("auto");
            if (!result.inferredDeclaration)
            {
                result.declaredType = parseType(result.declaredNamedType);
                parseFixedArraySuffix(result.declaredType,
                        result.declaredNamedType, result.arrayLength, result.elementType);
            }
            result.name = expectIdentifier("variable name").text;
            if (match("="))
            {
                result.expression = parseExpression();
                result.hasExpression = true;
            }
            else if (result.declaredType != TypeKind.structType
                    && result.declaredType != TypeKind.fixedArray)
            {
                diagnostics.error(current().location, "expected '=' in variable declaration");
            }
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

    private Expr parseExpression(int minimumPrecedence = 1)
    {
        auto left = parseUnary();
        while (true)
        {
            auto precedence = binaryPrecedence(current().text);
            if (precedence < minimumPrecedence)
            {
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

    private Expr parseUnary()
    {
        if (check("!") || check("-"))
        {
            auto operation = advance();
            auto result = new Expr();
            result.kind = ExprKind.unary;
            result.location = operation.location;
            result.text = operation.text;
            result.left = parseUnary();
            return result;
        }
        return parsePostfix(parsePrimary());
    }

    private Expr parsePrimary()
    {
        auto token = advance();
        auto result = new Expr();
        result.location = token.location;

        if (token.kind == TokenKind.integer)
        {
            result.kind = ExprKind.integer;
            try
            {
                result.integerValue = to!long(token.text.replace("_", ""));
            }
            catch (Exception)
            {
                diagnostics.error(token.location, "integer literal is out of range");
            }
            return result;
        }
        if (token.kind == TokenKind.stringLiteral)
        {
            result.kind = ExprKind.stringLiteral;
            result.text = token.text;
            return result;
        }
        if (token.text == "null")
        {
            result.kind = ExprKind.nullLiteral;
            return result;
        }
        if (token.text == "true" || token.text == "false")
        {
            result.kind = ExprKind.boolean;
            result.booleanValue = token.text == "true";
            return result;
        }
        if (token.kind == TokenKind.identifier)
        {
            result.kind = ExprKind.variable;
            result.text = token.text;
            return result;
        }
        if (token.text == "(")
        {
            result = parseExpression();
            expect(")");
            return result;
        }

        diagnostics.error(token.location, "expected expression");
        result.kind = ExprKind.integer;
        return result;
    }

    private Expr parsePostfix(Expr expression)
    {
        while (true)
        {
            if (match("."))
            {
                auto memberName = expectIdentifier("member name");
                auto member = new Expr();
                member.kind = ExprKind.member;
                member.location = memberName.location;
                member.text = memberName.text;
                member.left = expression;
                expression = member;
                continue;
            }
            if (match("["))
            {
                auto indexExpression = parseExpression();
                expect("]");
                auto indexed = new Expr();
                indexed.kind = ExprKind.index;
                indexed.location = expression.location;
                indexed.left = expression;
                indexed.right = indexExpression;
                expression = indexed;
                continue;
            }
            if (match("("))
            {
                auto call = new Expr();
                call.kind = ExprKind.call;
                call.location = expression.location;
                call.left = expression;
                if (!check(")"))
                {
                    do
                    {
                        call.arguments ~= parseExpression();
                    }
                    while (match(","));
                }
                expect(")");
                expression = call;
                continue;
            }
            return expression;
        }
    }

    private static bool isTypeName(string name)
    {
        return name == "int" || name == "long" || name == "bool"
            || name == "string" || name == "pointer";
    }

    private static int binaryPrecedence(string operation)
    {
        switch (operation)
        {
        case "=":
            return 1;
        case "||":
            return 2;
        case "&&":
            return 3;
        case "==", "!=":
            return 4;
        case "<", "<=", ">", ">=":
            return 5;
        case "+", "-":
            return 6;
        case "*", "/", "%":
            return 7;
        default:
            return 0;
        }
    }

    private void synchronizeDeclaration()
    {
        while (current().kind != TokenKind.end && !check(";") && !check("}"))
        {
            advance();
        }
        match(";");
    }
}
