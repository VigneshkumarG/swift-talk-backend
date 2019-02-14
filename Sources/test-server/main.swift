import Foundation
import NIOWrapper
import WebServer

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

extension Reader where Result == NIOInterpreter {
    static func write(_ node: Node<Value>) -> Reader<Value, Result> {
        return Reader { value in
            .write(node.render(input: value))
        }
    }
}

typealias I = NIOInterpreter

func interpret(path: [String]) -> Reader<Session, I> {
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
    let result = interpret(path: request.path).run(session)
    return result
}

try server.listen(port: 9999)
