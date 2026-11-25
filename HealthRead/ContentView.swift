import SwiftUI

/// Root view — TabView with 3 tabs: Camera, Weight, Blood Pressure.
struct ContentView: View {

    @State private var camera = CameraController()
    @State private var healthKit = HealthKitManager()
    @State private var selectedTab = 0
    @AppStorage(ReadingMode.chosenKey) private var didChooseReadingMode = false

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
        // Ask for camera and Apple Health access only after onboarding, so the
        // system prompts come with context.
        .task(id: didChooseReadingMode) {
            guard didChooseReadingMode else { return }
            camera.start()
            _ = await healthKit.requestAuthorization()
        }
        .fullScreenCover(isPresented: .constant(!didChooseReadingMode)) {
            OnboardingView()
        }
    }
}

#Preview {
    ContentView()
}
