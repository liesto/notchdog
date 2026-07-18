import Foundation

let filter = CommandLine.arguments.dropFirst().first
let runner = TestRunner(filter: filter)

await registerEventTests(runner)
await registerSessionRegistryTests(runner)
await registerHTTPRequestTests(runner)
await registerConfigTests(runner)
await registerEventServerTests(runner)

runner.finish()
