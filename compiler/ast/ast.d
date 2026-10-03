module ast.ast;

public struct SourceLocation {
    string file;
    size_t line;
    size_t column;
}

public enum TypeKind {
    invalid,
    voidType,
    intType,
    longType,
    boolType,
    stringType,
    cStringPointer,
    voidPointer,
    nullType
}

public struct Parameter {
    string name;
    TypeKind type;
    SourceLocation location;
}

public enum ExprKind {
    invalid,
    integer,
    boolean,
    stringLiteral,
    nullLiteral,
    variable,
    unary,
    binary,
    call
}

public class Expr {
    ExprKind kind;
    SourceLocation location;
    string text;
    long integerValue;
    bool booleanValue;
    Expr left;
    Expr right;
    Expr[] arguments;
    TypeKind inferredType = TypeKind.invalid;
}

public enum StmtKind {
    block,
    variable,
    expression,
    returnStatement,
    ifStatement,
    whileStatement
}

public struct Stmt {
    StmtKind kind;
    SourceLocation location;
    string name;
    TypeKind declaredType = TypeKind.invalid;
    bool inferredDeclaration;
    bool hasExpression;
    Expr expression;
    Stmt[] body;
    Stmt[] alternate;
}

public struct FunctionDecl {
    string name;
    TypeKind returnType;
    Parameter[] parameters;
    Stmt[] body;
    SourceLocation location;
    bool externC;
    bool hasBody;
}

public struct ImportDecl {
    string moduleName;
    string[] symbols;
    SourceLocation location;
}

public struct Program {
    string moduleName;
    ImportDecl[] imports;
    FunctionDecl[] functions;
}
