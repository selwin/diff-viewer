/// An author's first word, so the time stays visible beside long names. It is not
/// necessarily a given name ("robbieadi", "dependabot[bot]").
enum AuthorName {
    static func firstToken(of author: String) -> String {
        String(author.split(whereSeparator: \.isWhitespace).first ?? "")
    }
}
