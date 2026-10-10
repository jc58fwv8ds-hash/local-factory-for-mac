struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
        throw CheckFailure(description: message)
    }
}

func require<Value>(_ value: Value?) throws -> Value {
    guard let value else {
        throw CheckFailure(description: "Expected a value")
    }
    return value
}

func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        return
    }
    throw CheckFailure(description: message)
}
