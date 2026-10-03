module symbols.symbols;

import ast.ast : FunctionDecl, TypeKind;

public struct FunctionSymbol {
    string name;
    TypeKind returnType;
    TypeKind[] parameterTypes;
    size_t declarationIndex;
    bool externC;
}

public struct SymbolTable {
    FunctionSymbol[string] functions;

    public bool containsFunction(string name) const {
        return (name in functions) !is null;
    }

    public void insertFunction(FunctionSymbol symbol) {
        functions[symbol.name] = symbol;
    }
}
