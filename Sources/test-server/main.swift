import Foundation
import NIOWrapper

struct Session {
    var user: User
    var currentPath: String
}

struct User {
    var name: String
}

enum Node<I> {
    case node(Element<I>)
    case withInput((I) -> Node)
    case raw(String)
    // ...
}

struct Element<I> {
    var name: String
    var children: [Node<I>]

    func render(input: I) -> String {
        return "<\(name)>\(children.map { $0.render(input: input) }.joined(separator: " "))</\(name)>"
    }
}

extension Node {
    static func p(_ children: [Node]) -> Node {
        return .node(Element(name: "p", children: children))
    }
    
    static func div(_ children: [Node]) -> Node {
        return .node(Element(name: "div", children: children))
    }

    func render(input: I) -> String {
        switch self {
        case let .node(e):
            return e.render(input: input)
        case let .withInput(f):
            return f(input).render(input: input)
        case let .raw(str):
            return str
        }
    }
}

typealias SNode = Node<Session>

func layout(_ node: SNode) -> SNode {
    return .div([
            .raw("<h1>Title</h1>"),
            .withInput { .raw("Link to login with \($0.currentPath)") },
            node
        ])
}

func accountView() -> SNode {
    return layout(.withInput { .p([.raw("Your account: \($0.user.name)")]) })
}

func homePage() -> SNode {
    return layout(.p([.raw("The homepage")]))
}


struct Reader<Value, Result> {
    let run: (Value) -> Result
}

protocol Resp {
    static func write(_ string: String, status: HTTPResponseStatus, headers: [String : String]) -> Self
}

extension Resp {
    static func write(_ string: String) -> Self {
        return .write(string, status: .ok, headers: [:])
    }
}

extension NIOInterpreter: Resp {}


extension Reader where Result: Resp {
    static func write(_ node: Node<Value>) -> Reader<Value, Result> {
        return Reader { value in
            .write(node.render(input: value))
        }
    }
}


func interpret<I: Resp>(path: [String]) -> Reader<Session, I> {
    if path == ["account"] {
        return .write(accountView())
    } else if path == [] {
        return .write(homePage())
    } else {
        return .write(.raw("Not found"))
    }
}

let server = Server(resourcePaths: []) { request in
    let session  = Session(user: User(name: "Chris"), currentPath: "/" + request.path.joined(separator: "/"))
    let result: Reader<Session, NIOInterpreter> = interpret(path: request.path)
    return result.run(session)
}

try server.listen(port: 9999)


enum TestInterpreter: Resp {
    case _write(_ string: String, status: HTTPResponseStatus, headers: [String : String])
    
    static func write(_ string: String, status: HTTPResponseStatus, headers: [String : String]) -> TestInterpreter {
        return ._write(string, status: status, headers: headers)
    }
}

func test() {
    let session = Session(user: User(name: "Test"), currentPath: "")
    let result: TestInterpreter = interpret(path: []).run(session)
    guard case let ._write(s, _, _) = result else { assert(false) }
    assert(s.contains("homepage"))
    print("Test succeeded")
}

test()
