import SwiftUI

// MARK: - Intro Tab

struct IntroTab: View {
    @Binding var hasSeenIntro: Bool
    @Binding var selectedTab: Int
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 20)

                // Logo e titolo
                VStack(spacing: 12) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.green, .mint],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("smol")
                        .font(.system(size: 48, weight: .bold, design: .rounded))

                    Text("intro.tagline".localized(localization))
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Il problema
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.title2)
                        Text("intro.the_problem".localized(localization))
                            .font(.title2)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        BloatwareExampleRow(
                            app: "BloatCleaner Pro™",
                            problem: "intro.bloat1_problem".localized(localization),
                            icon: "trash.fill",
                            color: .red
                        )
                        BloatwareExampleRow(
                            app: "Mouse Drivers 2024",
                            problem: "intro.bloat2_problem".localized(localization),
                            icon: "computermouse.fill",
                            color: .orange
                        )
                        BloatwareExampleRow(
                            app: "Creative Suite Helper",
                            problem: "intro.bloat3_problem".localized(localization),
                            icon: "paintpalette.fill",
                            color: .purple
                        )
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.red.opacity(0.1))
                )

                // La soluzione
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("intro.the_solution".localized(localization))
                            .font(.title2)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SolutionRow(
                            title: "intro.solution1_title".localized(localization),
                            description: "intro.solution1_desc".localized(localization),
                            icon: "memorychip"
                        )
                        SolutionRow(
                            title: "intro.solution2_title".localized(localization),
                            description: "intro.solution2_desc".localized(localization),
                            icon: "cpu"
                        )
                        SolutionRow(
                            title: "intro.solution3_title".localized(localization),
                            description: "intro.solution3_desc".localized(localization),
                            icon: "arrow.triangle.swap"
                        )
                        SolutionRow(
                            title: "intro.solution4_title".localized(localization),
                            description: "intro.solution4_desc".localized(localization),
                            icon: "eye"
                        )
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.green.opacity(0.1))
                )

                // Confronto dimensioni
                HStack(spacing: 24) {
                    SizeComparisonCard(
                        app: "BloatCleaner™",
                        size: "~500 MB",
                        ram: "200+ MB",
                        isEvil: true,
                        localization: localization
                    )

                    Text("intro.vs".localized(localization))
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    SizeComparisonCard(
                        app: "smol",
                        size: "~5 MB",
                        ram: "~15 MB",
                        isEvil: false,
                        localization: localization
                    )
                }

                // Quote
                VStack(spacing: 8) {
                    Text(localization.currentLanguage == .italian ?
                         "\"Le app di pulizia usano 500MB per dirti che il Mac è sporco." :
                         "\"Cleaning apps use 500MB to tell you your Mac is dirty.")
                        .font(.body)
                        .italic()
                    Text(localization.currentLanguage == .italian ?
                         "smol usa 5MB per dirti la verità.\"" :
                         "smol uses 5MB to tell you the truth.\"")
                        .font(.body)
                        .italic()
                        .fontWeight(.semibold)
                }
                .foregroundColor(.secondary)
                .padding()

                // Pulsante
                Button {
                    hasSeenIntro = true
                    withAnimation {
                        selectedTab = 1
                    }
                } label: {
                    HStack {
                        Text(localization.currentLanguage == .italian ?
                             "Inizia a Monitorare" : "Start Monitoring")
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [.green, .mint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Intro Components

struct BloatwareExampleRow: View {
    let app: String
    let problem: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app)
                    .fontWeight(.semibold)
                Text(problem)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red.opacity(0.6))
        }
    }
}

struct SolutionRow: View {
    let title: String
    let description: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.green)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green.opacity(0.6))
        }
    }
}

struct SizeComparisonCard: View {
    let app: String
    let size: String
    let ram: String
    let isEvil: Bool
    @ObservedObject var localization: LocalizationManager

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isEvil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(isEvil ? .red : .green)

            Text(app)
                .font(.headline)
                .fontWeight(.bold)

            VStack(spacing: 4) {
                HStack {
                    Text("intro.size".localized(localization) + ":")
                        .foregroundColor(.secondary)
                    Text(size)
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("intro.ram".localized(localization) + ":")
                        .foregroundColor(.secondary)
                    Text(ram)
                        .fontWeight(.medium)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(width: 140)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isEvil ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                .stroke(isEvil ? Color.red.opacity(0.3) : Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}
