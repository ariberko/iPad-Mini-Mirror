import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HomeView()
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    ToastView(toast: toast)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .fullScreenCover(isPresented: $model.showMirror) {
                MirrorScreen()
                    .environment(model)
            }
            .sheet(item: $model.pairPrompt) { prompt in
                PairingCodeSheet(prompt: prompt)
                    .environment(model)
            }
            .sheet(isPresented: $model.showOnboarding) {
                OnboardingView()
                    .environment(model)
                    .interactiveDismissDisabled()
            }
    }
}
