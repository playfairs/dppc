module ast.ast;

public struct SourceLocation
{
    string file;
    size_t line;
    size_t column;
}

public enum TypeKind
{
    invalid,
    voidType,
    intType,
    longType,
    boolType,
    stringType,
    cStringPointer,
    voidPointer,
    nullType,
    structType,
    fixedArray
}

public struct Parameter
{
    string name;
    TypeKind type;
    SourceLocation location;
    string namedType;
    bool isReference;
}

public enum ExprKind
{
    invalid,
    integer,
    boolean,
    stringLiteral,
    nullLiteral,
    variable,
    member,
    index,
    unary,
    binary,
    call
}

public class Expr
{
    ExprKind kind;
    SourceLocation location;
    string text;
    long integerValue;
    bool booleanValue;
    Expr left;
    Expr right;
    Expr[] arguments;
    TypeKind inferredType = TypeKind.invalid;
    string inferredNamedType;
    string memberOwnerType;
    size_t fieldIndex;
    string resolvedFunction;
    bool isConstructorCall;
    bool isMethodCall;
    TypeKind elementType = TypeKind.invalid;
    size_t arrayLength;
}

public enum ObjectLifetime
{
    uninitialized,
    constructing,
    live,
    destroyed
}

public enum StmtKind
{
    block,
    variable,
    expression,
    scopeExit,
    breakStatement,
    continueStatement,
    returnStatement,
    ifStatement,
    whileStatement
}

public struct Stmt
{
    StmtKind kind;
    SourceLocation location;
    string name;
    TypeKind declaredType = TypeKind.invalid;
    string declaredNamedType;
    bool inferredDeclaration;
    bool hasExpression;
    string selectedConstructor;
    ObjectLifetime objectLifetime = ObjectLifetime.uninitialized;
    TypeKind elementType = TypeKind.invalid;
    size_t arrayLength;
    Expr expression;
    Stmt[] body;
    Stmt[] alternate;
}

public struct FunctionDecl
{
    string name;
    string sourceName;
    TypeKind returnType;
    string returnNamedType;
    Parameter[] parameters;
    Stmt[] body;
    SourceLocation location;
    bool externC;
    bool hasBody;
    bool isDestructor;
    bool isConstructor;
    bool isMethod;
    bool isGenerated;
    string ownerType;
}

public struct FieldDecl
{
    string name;
    TypeKind type;
    string namedType;
    SourceLocation location;
    size_t offset;
    TypeKind elementType = TypeKind.invalid;
    size_t arrayLength;
}

public struct StructDecl
{
    string name;
    FieldDecl[] fields;
    SourceLocation location;
    size_t size;
    size_t alignment;
    string destructorName;
    bool hasUserDestructor;
    bool hasGeneratedDestructor;
    bool needsDestruction;
    string[] constructorNames;
}

public struct ImportDecl
{
    string moduleName;
    string[] symbols;
    SourceLocation location;
}

public struct Program
{
    string moduleName;
    ImportDecl[] imports;
    StructDecl[] structs;
    FunctionDecl[] functions;
}
