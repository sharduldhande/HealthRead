import SwiftUI

/// Root view — TabView with 3 tabs: Camera, Weight, Blood Pressure.
struct ContentView: View {

    @State private var camera = CameraController()
    @State private var healthKit = HealthKitManager()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CameraTab(
                camera: camera,
                healthKit: healthKit,
                backCamera: $camera.backCamera,
                selectedTab: $selectedTab
            )
            .tabItem {
                Image(systemName: "camera.fill")
                Text("Scan")
            }
            .tag(0)

            WeightHistoryTab(healthKit: healthKit)
                .tabItem {
                    Image(systemName: "scalemass.fill")
                    Text("Weight")
                }
                .tag(1)

            BPHistoryTab(healthKit: healthKit)
                .tabItem {
                    Image(systemName: "heart.fill")
                    Text("Blood Pressure")
                }
                .tag(2)
        }
        .task {
            camera.start()
            await healthKit.requestAuthorization()
        }
    }
}

#Preview {
    ContentView()
}
