# CHANGES IN bookdown VERSION 0.2

## NEW FEATURES

- Added arguemnts `toc_unnumberred`, `toc_appendix`, `toc_bib`, and `quote_footer` to `pdf_book()`.

- Added support for cross-referencing equations in multi-page HTML output and EPUB; see https://bookdown.org/yihui/bookdown/ for the syntax (thanks, @deleeuw, #85).

- Rmd files can live in subdirectories if you use the Merge-and-Knit approach (the default), and they will be found if the configuration option `rmd_subdir` is true in `_bookdown.yml` (thanks, @leobuchignani, #205).

## MAJOR CHANGES

- The `force_knit` argument of `render_book()` was removed (to avoid confusion when switching output formats).

## MINOR CHANGES

- The merged R Markdown file will not be deleted if rendering failed so you can debug with this file (http://stackoverflow.com/q/38883222/559676).

- The configurations `edit: text` and `chapter_name` have been moved from the top-level options to the sub-options of `language: ui` in `_bookdown.yml`. See https://bookdown.org/yihui/bookdown/internationalization.html

## BUG FIXES

- Figures are not correctly numbered in Word output using the `bookdown::word_document2()` format (thanks, @byzheng, #158).

- For the "Knit and Merge" approach (`new_session: yes` in `_bookdown.yml`), certain parts like figures may not show up when switching from one output format to another (e.g. from HTML to LaTeX).

- The `rmd_files` option in `_bookdown.yml` does not work when it is a list of `html` and `latex` options (thanks, @ismayc, #177).

- Math expressions does not appear in the table of contents when the output format is `gitbook` (thanks, @philomonk, #204).

- Footnotes of multiple paragraphs are not displayed on the current page (thanks, @axitdn, #234).

- The output format `pdf_document2()` also works with articles now when an R Markdown document contains bookdown-specific headers, such as parts or appendix headers (http://stackoverflow.com/q/40529798/559676).

# CHANGES IN bookdown VERSION 0.1

## NEW FEATURES

- Initial CRAN release.
