# speedtest
api for speedtest Speedtest is better with the app. Download the Speedtest app for more metrics, video testing, mobile coverage maps, and more. Get it on Google Play
# main
```swift
import Foundation
import speedtest

@main
struct SpeedTestDemo {
    static func main() async {
        let tester = SpeedTest()
        let start = Date().timeIntervalSince1970
        do {
            let result = try await tester.runSpeedTest(limit: 1)
            let elapsed = Date().timeIntervalSince1970 - start

            print("   Download: \(result.download) Mbps")
            print("   Upload:   \(result.upload) Mbps")
            print("   Took:     \(String(format: "%.1f", elapsed)) sec")

            // Simple sanity check of the result
            if result.download <= 0 || result.upload <= 0 {
                print("\n⚠️  Speed is zero or negative — something went wrong " +
                      "(the server returned an empty response, a bad URL, or a timeout).")
            } else {
                print("\n✅  Test completed successfully.")
            }
        } catch {
            print("   ERROR running speed test: \(error.localizedDescription)")
            exit(1)
        }
        }
}
```

# Launch (your script)
```
swift run
```
