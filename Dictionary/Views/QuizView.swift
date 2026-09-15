import SwiftUI

/// The quiz sheet: a definition, four words, and a running score.
///
/// The prompt is set like an entry's definition rather than like a game — the
/// only colour in the screen is the thin right/wrong tint after an answer.
struct QuizView: View {
    @StateObject private var model: QuizViewModel
    @Environment(\.dismiss) private var dismiss

    /// `pool` is the reader's own vocabulary — recents plus favourites,
    /// de-duplicated by the caller.
    init(pool: [String]) {
        _model = StateObject(wrappedValue: QuizViewModel(pool: pool))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .needsMoreWords(let have, let need):
                    needsMoreWords(have: have, need: need)
                case .question(let question, let index, let total, let selected):
                    questionScreen(question, index: index, total: total, selected: selected)
                case .finished(let score, let total):
                    finishedScreen(score: score, total: total)
                }
            }
            .navigationTitle("Quiz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Screens

    private func needsMoreWords(have: Int, need: Int) -> some View {
        VStack(spacing: 6) {
            Text("Look up a few more words first.")
                .font(.roboto(15))
            Text("The quiz needs \(need) words with definitions. You have \(have).")
                .font(.roboto(13))
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func questionScreen(_ question: QuizQuestion, index: Int,
                                total: Int, selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(index + 1) of \(total)")
                Spacer()
                Text("Score \(model.score)")
            }
            .font(.roboto(13))
            .foregroundStyle(.secondary)

            Text(question.partOfSpeech)
                .font(.roboto(14, italic: true))
                .foregroundStyle(.secondary)
                .padding(.top, 24)

            Text(question.definition)
                .font(.roboto(22))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 10) {
                ForEach(question.options, id: \.self) { option in
                    optionRow(option, question: question, selected: selected)
                }
            }
            .padding(.top, 32)

            Spacer(minLength: 24)

            // Only after answering, so the button can't be used to skip.
            if selected != nil {
                Button {
                    model.next()
                } label: {
                    Text(index + 1 == total ? "See Score" : "Next")
                        .font(.roboto(17, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func finishedScreen(score: Int, total: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(score) of \(total)")
                .font(.roboto(40))
            Text(score == 1 ? "word correct" : "words correct")
                .font(.roboto(15))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Button("Try Again") { model.restart() }
                    .font(.roboto(17, weight: .medium))
                Button("Done") { dismiss() }
                    .font(.roboto(17))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Options

    private func optionRow(_ option: String, question: QuizQuestion,
                           selected: String?) -> some View {
        let isAnswer = option.caseInsensitiveCompare(question.answer) == .orderedSame
        let isChosen = selected?.caseInsensitiveCompare(option) == .orderedSame
        let revealed = selected != nil

        // The correct word is always marked, so a wrong answer teaches the right
        // one rather than only scoring it.
        let tint: Color? = {
            guard revealed else { return nil }
            if isAnswer { return .green }
            return isChosen ? .red : nil
        }()

        return Button {
            model.answer(option)
        } label: {
            Text(option)
                .font(.roboto(17))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill((tint ?? .clear).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint ?? Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .foregroundStyle(tint ?? (revealed ? Color.secondary : Color.primary))
        }
        .buttonStyle(.plain)
        .disabled(revealed)
    }
}

#Preview {
    QuizView(pool: ["ephemeral", "laconic", "sanguine", "obdurate", "quixotic"])
}
