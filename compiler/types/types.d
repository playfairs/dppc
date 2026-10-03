module types.types;

import ast.ast : TypeKind;

public string typeName(TypeKind type) {
    final switch (type) {
        case TypeKind.voidType: return "void";
        case TypeKind.intType: return "int";
        case TypeKind.longType: return "long";
        case TypeKind.boolType: return "bool";
        case TypeKind.stringType: return "string";
        case TypeKind.cStringPointer: return "const(char)*";
        case TypeKind.voidPointer: return "void*";
        case TypeKind.nullType: return "null";
        case TypeKind.invalid: return "<invalid>";
    }
}

public bool isInteger(TypeKind type) {
    return type == TypeKind.intType || type == TypeKind.longType;
}

public bool canConvert(TypeKind from, TypeKind to) {
    if (from == to) {
        return true;
    }
    return (from == TypeKind.intType && to == TypeKind.longType)
        || (from == TypeKind.nullType
            && (to == TypeKind.voidPointer || to == TypeKind.cStringPointer));
}
