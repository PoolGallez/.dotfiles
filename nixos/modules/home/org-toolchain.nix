# Build/toolchain dependencies for the Emacs org-mode setup in
# emacs/.config/emacs (LaTeX preview, pdf-tools, dot diagrams) — carried
# over from home.nix with the same reasoning comments.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # Org-mode LaTeX equation preview (org-latex-preview, dvisvgm backend).
    # dvisvgm isn't a standalone nixpkgs package - it's bundled inside
    # texlive's own bin/ directory, so this alone is enough.
    texlive.combined.scheme-medium

    # AUCTeX's preview-latex (preview-mode) shells out to `pdf2dsc` to turn
    # the compiled PDF into a DSC file it can split into per-preview pages.
    # pdf2dsc ships with Ghostscript, not texlive.
    ghostscript

    # pdf-tools build deps (Emacs package itself is installed via elpa/straight
    # in post-init.el; these are just what its epdfinfo server compiles against).
    # Only the .dev output (headers/pkg-config) is needed here - the bare
    # `poppler` package aliases to the poppler-glib derivation, whose `out`
    # output collides with the libpoppler-glib.so that poppler-utils below
    # already bundles, breaking `home-manager switch` with a buildEnv
    # conflicting-paths error.
    poppler.dev
    pkg-config
    gcc

    # `dot` binary, for the #+begin_src dot diagram blocks in the course notes
    graphviz

    # `pdftoppm`/`pdftocairo`/`pdfimages`, for cropping a scan of the
    # original handwritten sketch out of a source PDF page
    poppler-utils
  ];
}
