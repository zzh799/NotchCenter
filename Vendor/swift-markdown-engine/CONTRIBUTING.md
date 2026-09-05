# Contributing to MarkdownEngine

<<<<<<< HEAD
Thanks for your interest in helping out. This document covers the basics.
=======
Thanks for your interest. **MarkdownEngine is maintained by one person —
expect 1–2 weeks for review.** A pull request is the normal way in, for
fixes, documentation and new extensions alike. If a change is large or
architectural, open it as a draft PR with the design sketched in the
description — that gets you an answer faster than describing it in prose.
>>>>>>> 0.12.0

## Reporting Bugs

Open a GitHub issue with:

- A clear title summarizing the bug
- A minimal reproducer (the smallest Markdown input + code that triggers it)
- macOS version, Xcode version, and Swift version
- Expected vs actual behavior

If you can paste a screen recording or screenshot, please do.

## Suggesting a Feature

Open a GitHub issue **before** writing code for a non-trivial feature, so
we can talk through the design and avoid wasted effort. Small fixes and
documentation tweaks are welcome as PRs directly.

## Development Setup

```bash
git clone https://github.com/luca-chen198/MarkdownEngine.git
cd MarkdownEngine
swift build
swift test
```

Open `Package.swift` in Xcode for a graphical environment, or use the
command line — both work.

### Generating documentation locally

<<<<<<< HEAD
To preview the DocC catalog locally, add the swift-docc plugin to
`Package.swift` temporarily:

```swift
dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
]
```

Then run:

```bash
swift package --disable-sandbox preview-documentation --target MarkdownEngine
```

The plugin is intentionally **not** a permanent dependency to keep the
shipped package's transitive deps at zero.
=======
Temporarily add the [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin)
to `Package.swift`, then `swift package --disable-sandbox preview-documentation
--target MarkdownEngine`. It's intentionally not a permanent dependency — the
core product stays free of optional tooling.
>>>>>>> 0.12.0

## Coding Conventions

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Public symbols **must** carry triple-slash documentation comments
- Indent with 4 spaces
- Use `// MARK: -` to group related members in larger files
- Keep file headers minimal; the file path implies what it contains
- Favor `internal` over `public` — the smaller the public surface, the
  easier the package is to evolve
- Avoid adding external dependencies. The engine ships with zero deps; that
  is a design constraint, not an accident

## Tests

- Add unit tests for any new tokenizer / styler / service behavior
- Tests live in `Tests/MarkdownEngineTests/`
- Run with `swift test`
- Tests must pass on macOS 14+ with the latest stable Xcode

## Pull Requests

<<<<<<< HEAD
- Branch from `main`
- Keep the change focused — one logical change per PR
- Include test coverage for new behavior
- Update `CHANGELOG.md` under `[Unreleased]` with a one-line summary
- Update DocC docs for any public-API change
- Make sure `swift build` and `swift test` are green locally before
  opening the PR; CI will run the same checks
=======
- One logical change per PR, branched from `main`
- Tests for new tokenizer / styler / service / extension behavior in
  `Tests/MarkdownEngineTests/`
- DocC comments for any public-API change; update `Demo/` if relevant
- One-line entry in `CHANGELOG.md` under `[Unreleased]`
- `swift build` and `swift test` must be green; CI runs the same checks
>>>>>>> 0.12.0

## Commit Messages

<<<<<<< HEAD
Imperative, concise:
=======
Non-negotiable for the core `MarkdownEngine` target:

- **Don't add external dependencies to the core `MarkdownEngine`
  target.** App-specific behaviors plug in through the four service
  protocols (`WikiLinkResolver`, `EmbeddedImageProvider`,
  `SyntaxHighlighter`, `LatexRenderer`) instead. The two existing
  bridge products (`MarkdownEngineCodeBlocks` → HighlighterSwift,
  `MarkdownEngineLatex` → SwiftMath) are the deliberate exception so
  consumers can opt in. A new bridge or a new core dependency is a bigger
  call — make the case in the PR description.
- **New constructs are extensions, not core grammar.** A construct like
  `==highlight==` (inline) or a `::: … :::` fenced block belongs in
  `Sources/MarkdownEngine/Extensions/` as a `MarkdownExtension` — see
  `HighlightExtension` / `ContainerExtension` as templates — never a new case
  threaded through the parser, styler, and renderer. This keeps the core pure
  markdown and each construct isolated. Image/overlay-rendered constructs
  (tables, math) are the exception — they still need core work.
- **Public surface stays small.** Favor `internal`; new public symbols
  need a DocC comment.

## Commit messages

Imperative subject, blank line, then a paragraph explaining *why*:
>>>>>>> 0.12.0

```
Tokenize escaped backticks inside fenced code blocks

The previous tokenizer treated `\`` inside ``` … ``` as a token delimiter,
which broke any code block containing escaped backtick examples. The new
behavior matches CommonMark.
```

A short subject line, an empty line, then a paragraph (or two) explaining
*why* the change exists. The "what" is in the diff.

## License

By contributing, you agree that your contributions will be licensed under
the [MIT License](LICENSE).
