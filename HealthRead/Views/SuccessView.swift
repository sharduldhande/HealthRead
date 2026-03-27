import SwiftUI

/// Brief animated success confirmation overlay.
struct SuccessView: View {

    let deviceType: DeviceType
    let summary: String
    let onDone: (Int) -> Void  // passes the tab index to navigate to

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var opacity: CGFloat = 0

    private var targetTab: Int {
        deviceType == .weightScale ? 1 : 2
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .scaleEffect(checkmarkScale)

            Text("Saved to Health")
                .font(.title2)
                .fontWeight(.bold)

            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(Date().formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                onDone(targetTab)
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.green)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                checkmarkScale = 1.0
                opacity = 1.0
            }
        }
    }
}
