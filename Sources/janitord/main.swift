import Foundation
import JanitorCore

setpriority(PRIO_PROCESS, 0, 10)
let monitor = Monitor()
let server = SocketServer(monitor: monitor)
monitor.start()
server.start()
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
dispatchMain()
