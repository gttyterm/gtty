# Contributing to gtty

Thanks for helping. A few rules:

- **License.** gtty is GPL-3.0-or-later. By contributing, you agree that
  your contribution is licensed under GPL-3.0-or-later too. New source
  files start with:

  ```
  // SPDX-FileCopyrightText: 2026 Your Name
  // SPDX-License-Identifier: GPL-3.0-or-later
  ```

  Don't add code copied from elsewhere unless its license allows it.
  Say where it came from in the pull request and in `THIRD_PARTY.md`.
- **DCO sign-off.** Every commit needs a
  [Developer Certificate of Origin](https://developercertificate.org/)
  sign-off line, `Signed-off-by: Name <email>`, which `git commit -s`
  adds for you.
- **AI.** AI-assisted contributions are welcome; you're responsible for
  understanding and testing what you submit.

Building and testing are covered in [HACKING.md](HACKING.md): build, unit
tests, and script mode for testing UI changes. The detailed feature notes
and conventions are in [CLAUDE.md](CLAUDE.md) (section "Build & test").
