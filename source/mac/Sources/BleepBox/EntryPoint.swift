import Foundation

@main
enum EntryPoint {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--monitor-helper") {
            MonitorHelper.run()
        } else {
            BleepBoxApp.main()
        }
    }
}
