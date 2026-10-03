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
        case TypeKind.structType: return "struct";
        case TypeKind.fixedArray: return "fixed array";
        case TypeKind.invalid: return "<invalid>";
    }
}

public struct PrimitiveLayout {
    size_t size;
    size_t alignment;
}

public PrimitiveLayout primitiveLayout(TypeKind type) {
    final switch (type) {
        case TypeKind.boolType: return PrimitiveLayout(1, 1);
        case TypeKind.intType: return PrimitiveLayout(4, 4);
        case TypeKind.longType: return PrimitiveLayout(8, 8);
        case TypeKind.stringType, TypeKind.cStringPointer, TypeKind.voidPointer:
            return PrimitiveLayout(8, 8);
        case TypeKind.voidType, TypeKind.nullType, TypeKind.invalid, TypeKind.structType:
            return PrimitiveLayout(0, 1);
        case TypeKind.fixedArray:
            return PrimitiveLayout(0, 1);
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
