# How linux-submit.sh builds and installs fdroidpublisher, like a PKGBUILD's build()
# and package(). Every distro's recipe runs these two functions:
#   - from the top of the release's source, as POSIX sh (not bash: Debian
#     runs them with dash, Alpine with ash), stopping at the first error;
#   - build(): compile what needs it, with ${CC:-cc} $CFLAGS $LDFLAGS (the
#     distros set them); leave just ':' when there is nothing to build;
#   - package(): install into "$DESTDIR$PREFIX" — PREFIX is /usr on most
#     distros, the package's own folder on Nix and Homebrew;
#   - download nothing: most distros build without internet.
# Each distro adds the license and the README its own way.

build() {
  :
}

package() {
  install -Dm755 fdroidPublisher "$DESTDIR$PREFIX/bin/fdroidPublisher"
}
