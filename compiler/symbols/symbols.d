module symbols.symbols;

import ast.ast : TypeKind;

public struct FieldSymbol
{
    string name;
    TypeKind type;
    string namedType;
    size_t offset;
    TypeKind elementType = TypeKind.invalid;
    size_t arrayLength;
}

public struct FunctionSymbol
{
    string name;
    string sourceName;
    string ownerType;
    TypeKind returnType;
    TypeKind[] parameterTypes;
    size_t declarationIndex;
    bool externC;
    bool isConstructor;
    bool isMethod;
    bool isDestructor;
}

public struct StructSymbol
{
    string name;
    FieldSymbol[] fields;
    size_t size;
    size_t alignment;
    string destructorName;
    string[] constructorNames;
    FunctionSymbol[] methods;
    bool hasUserDestructor;
    bool hasGeneratedDestructor;
    bool needsDestruction;

    public bool hasDestructor() const
    {
        return destructorName.length != 0;
    }
}

public struct SymbolTable
{
    FunctionSymbol[string] functions;
    StructSymbol[string] structs;

    public bool containsFunction(string name) const
    {
        return (name in functions) !is null;
    }

    public void insertFunction(FunctionSymbol symbol)
    {
        functions[symbol.name] = symbol;
    }
}
