#' @import stats utils

bookdown_file = function(...) {
  system.file(..., package = 'bookdown', mustWork = TRUE)
}

# find the y[j] closest to x[i] with y[j] > x[i]; x and y have been sorted
next_nearest = function(x, y, allow_eq = FALSE) {
  n = length(x); z = integer(n)
  for (i in seq_len(n)) z[i] = y[if (allow_eq) y >= x[i] else y > x[i]][1]
  z
}

# counters for figures/tables
new_counters = function(type, rownames) {
  base = matrix(
    0L, nrow = length(rownames), ncol = length(type),
    dimnames = list(rownames, type)
  )
  list(
    inc = function(type, which) {
      base[which, type] <<- base[which, type] + 1L
    }
  )
}

# set common format config
common_format_config = function(
  config, format, file_scope = getOption('bookdown.render.file_scope', FALSE)
) {

  # provide file_scope if requested
  if (file_scope) config$file_scope = md_chapter_splitter

  # prepend the custom-environment filter unless opt-out
  if (getOption("bookdown.theorem.enabled", TRUE)) {
    config$pandoc$lua_filters = c(
      lua_filter("custom-environment.lua"),
      config$pandoc$lua_filters
    )
  }
  # and add bookdown metadata file for the filter to work
  config$pandoc$args = c(bookdown_yml_arg(), config$pandoc$args)

  # set output format
  config$bookdown_output_format = format

  # use labels of the form (\#label) in knitr
  config$knitr$opts_knit$bookdown.internal.label = TRUE
  # when the output is LaTeX, force LaTeX tables instead of default Pandoc tables
  # http://tex.stackexchange.com/q/276699/9128
  config$knitr$opts_knit$kable.force.latex = TRUE

  # deactivate header attributes handling from rmarkdown
  # as done in bookdown::clean_html_tag()
  opts <- options(rmarkdown.html_dependency.header_attr = FALSE)
  config$on_exit <- function() options(opts)

  config
}

get_base_format = function(format, options = list()) {
  if (is.character(format)) format = eval(parse(text = format))
  if (!is.function(format)) stop('The output format must be a function')
  # make sure named elements in `options` have corresponding named arguments in
  # the format function, unless the function has the ... argument
  nms = names(formals(format))
  if (!('...' %in% nms)) options = options[names(options) %in% c(nms, '')]
  do.call(format, options)
}

load_config = function(config_file = '_bookdown.yml') {
  config_file = opts$get('config_file') %||% config_file
  if (length(opts$get('config')) == 0 && file.exists(config_file)) {
    # store the book config
    opts$set(config = rmarkdown:::yaml_load_file(config_file))
  }
  opts$get('config')
}

book_filename = function(config = load_config(), fallback = TRUE) {
  if (is.character(config[['book_filename']])) {
    config[['book_filename']][1]
  } else if (fallback) '_main'
}

source_files = function(format = NULL, config = load_config(), all = FALSE) {
  subdir = config[['rmd_subdir']]; subdir_yes = isTRUE(subdir) || is.character(subdir)
  ext_regex = if (isTRUE(config[['include_md']])) '[.]R?md$' else '[.]Rmd$'
  # a list of Rmd chapters
  files = list.files('.', ext_regex, ignore.case = TRUE)
  # content in subdir if asked
  subdir_files = unlist(mapply(
    list.files,
    if (is.character(subdir)) subdir else '.', ext_regex, ignore.case = TRUE,
    recursive = subdir_yes, full.names = is.character(subdir), USE.NAMES = FALSE
  ))
  subdir_files = setdiff(subdir_files, files)
  files = c(files, subdir_files)
  # if rmd_files is provided, use those files in addition to those under rmd_subdir
  if (length(files2 <- config[['rmd_files']]) > 0) {
    # users should specify 'docx' as the output format name for Word, but let's
    # make 'word' an alias of 'docx' to avoid further confusion:
    # https://stackoverflow.com/q/63678601/559676
    if ('word' %in% names(files2) && identical(format, 'docx')) format = 'word'
    if (is.list(files2)) files2 = if (all) unlist(files2) else files2[[format]]
    # add those files to subdir content if any
    files = if (subdir_yes) c(files2, subdir_files) else files2
  }
  # exclude files that start with _, and the merged file
  files = files[grep('^[^_]', basename(files))]
  files = setdiff(files, with_ext(book_filename(config), c('.md', '.Rmd')))
  files = unique(gsub('^[.]/', '', files))
  index = 'index' == with_ext(files, '')
  # if there is a index.Rmd, put it in the beginning
  if (any(index)) files = c(files[index], files[!index])
  check_special_chars(files)
}

output_dirname = function(dir, config = load_config(), create = TRUE) {
  if (is.null(dir)) {
    dir2 = config[['output_dir']]
    if (!is.null(dir2)) dir = dir2
  }
  if (is.null(dir)) dir = '_book'
  if (length(dir)) {
    if (create) dir_create(dir)
    # ignore dir that is just the current working directory
    if (same_path(dir, getwd())) dir = NULL
  }
  dir
}

# mark directories with trailing slashes
mark_dirs = function(x) {
  i = dir_exists(x)
  x[i] = paste0(x[i], '/')
  x
}

merge_chapters = function(files, to, before = NULL, after = NULL, orig = files) {
  # in the preview mode, only use some placeholder text instead of the full Rmd
  preview = opts$get('preview'); input = opts$get('input_rmd')
  content = unlist(mapply(files, orig, SIMPLIFY = FALSE, FUN = function(f, o) {
    x = read_utf8(f)
    # if a chapter is short enough (<= 30 lines), just include the full chapter for preview
    preview = preview && length(x) >= getOption('bookdown.preview.cutoff', 30)
    x = if (preview && !(o %in% input)) create_placeholder(x) else {
      insert_code_chunk(x, before, after)
    }
    c(x, '', paste0('<!--chapter:end:', o, '-->'), '')
  }))
  if (preview && !(files[1] %in% input))
    content = c(fetch_yaml(read_utf8(files[1])), content)
  unlink(to)
  write_utf8(content, to)
  Sys.chmod(to, '644')
}

# split a markdown file into a set of chapters
md_chapter_splitter = function(file) {
  x = read_utf8(file)

  # get positions of the chapter delimiters (r_chap_pattern defined in html.R)
  if (length(pos <- grep(r_chap_pattern, x)) <= 1) return()
  pos = c(0, pos)

  # get the filenames
  names = gsub(r_chap_pattern, '\\1', x[pos])

  # extract the chapters and pair them w/ the names
  lapply(seq_along(names), function(i) {
    i1 = pos[i] + 1
    i2 = pos[i + 1]
    list(name = names[i], content = x[i1:i2])
  })
}

match_dashes = function(x) grep('^---\\s*$', x)

create_placeholder = function(x) {
  # filter out fenced code blocks (which may contain #'s that are comments)
  x = x[xfun::prose_index(x)]
  h = grep('^# ', x, value = TRUE)  # chapter title
  h1 = grep(reg_part, h, value = TRUE)  # part title
  h2 = grep(reg_app, h, value = TRUE)   # appendix title
  h3 = setdiff(h, c(h1, h2))
  h4 = grep('^#{2,} ', x, value = TRUE)  # section/subsection/... titles
  c('', head(h1, 1), head(h2, 1), placeholder(h3), '', h4)
}

# add a placeholder paragraph
placeholder = function(x) {
  if (length(x)) c(x[1], '\nPlaceholder\n')
}

fetch_yaml = function(x) {
  i = match_dashes(x)
  if (length(i) >= 2) x[(i[1]):(i[2])]
}

insert_code_chunk = function(x, before, after) {
  if (length(before) + length(after) == 0) return(x)
  if (length(x) == 0 || length(match_dashes(x[1])) == 0) return(c(before, x, after))
  i = match_dashes(x)
  if (length(i) < 2) {
    warning('There may be something wrong with your YAML frontmatter (no closing ---)')
    return(c(before, x, after))
  }
  # insert `before` after the line i[2], i.e. the second ---
  c(append(x, before, i[2]), after)
}

insert_chapter_script = function(config, where = 'before') {
  script = get_chapter_script(config, where)
  if (is.character(script)) {
    c('```{r include=FALSE, cache=FALSE}', script, '```')
  }
}

get_chapter_script = function(config, where) {
  script = config[[sprintf('%s_chapter_script', where)]]
  unlist(lapply(script, read_utf8))
}

merge_chapter_script = function(config, where) {
  if (!is.character(script <- get_chapter_script(config, where)) || length(script) == 0)
    return('')
  f = tempfile(fileext = '.R')
  write_utf8(script, f)
  f
}

check_special_chars = function(filename) {
  reg = rmarkdown:::.shell_chars_regex
  for (i in grep(reg, filename)) warning(
    'The filename "', filename[i], '" contains special characters. ',
    'You may rename it to, e.g., "', gsub(reg, '-', filename[i]), '".'
  )
  if (!is.null(i)) stop('Filenames must not contain special characters')
  filename
}

Rscript = function(...) xfun::Rscript(...)

Rscript_render = function(file, ...) {
  args = shQuote(c(bookdown_file('scripts', 'render_one.R'), file, ...))
  if (Rscript(args) != 0) stop('Failed to compile ', file)
}

source_utf8 = function(file) {
  if (file == '') return()
  eval(xfun::parse_only(read_utf8(file)), envir = globalenv())
}

clean_meta = function(meta_file, files) {
  meta = readRDS(meta_file)
  for (i in setdiff(names(meta), files)) meta[[i]] = NULL
  meta = setNames(meta[files], files)  # order by input filenames
  for (i in files) if (is.null(meta[[i]])) meta[[i]] = basename(with_ext(i, '.md'))
  saveRDS(meta, meta_file)
  meta
}

# remove HTML tags and remove extra spaces
strip_html = function(x) {
  gsub('\\s{2,}', ' ', xfun::strip_html(x), perl = TRUE)
}

# remove the <script><script> content and references
strip_search_text = function(x) {
  x = gsub('<script[^>]*>(.*?)</script>', '', x)
  x = gsub('<div id="refs" class="references[^"]*">.*', '', x)
  x = strip_html(x)
  x = gsub('[[:space:]]', ' ', x)
  x
}

# manipulate internal options
opts = knitr:::new_defaults(list(config = list()))

# a wrapper of file.path to ignore `output_dir` if it is NULL
output_path = function(...) {
  dir = opts$get('output_dir')
  if (is.null(dir)) file.path(...) else file.path(dir, ...)
}

local_resources = function(x) {
  grep('^(f|ht)tps?://.+', x, value = TRUE, invert = TRUE)
}

# write out reference keys to _book/reference-keys.txt (for the RStudio visual
# editor to autocomplete \@ref())
write_ref_keys = function(x) {
  # this only works for books rendered with bookdown::render_book() (and not for
  # rmarkdown::render())
  if (is.null(preview <- opts$get('preview'))) return()
  # collect reference keys from parse_fig_labels() and parse_section_labels()
  if (is.null(d <- opts$get('output_dir'))) return()
  p = ref_keys_path(d)
  if (file.exists(p)) x = unique(c(xfun::read_utf8(p), x))
  xfun::write_utf8(x, p)
}

ref_keys_path = function(d = opts$get('output_dir')) {
  file.path(d, 'reference-keys.txt')
}

#' Continuously preview the HTML output of a book using the \pkg{servr} package
#'
#' When any files are modified or added to the book directory, the book will be
#' automatically recompiled, and the current HTML page in the browser will be
#' refreshed. This function is based on \code{servr::\link[servr:httd]{httw}()}
#' to continuously watch a directory.
#'
#' For \code{in_session = TRUE}, you will have access to all objects created in
#' the book in the current R session: if you use a daemonized server (via the
#' argument \code{daemon = TRUE}), you can check the objects at any time when
#' the current R session is not busy; otherwise you will have to stop the server
#' before you can check the objects. This can be useful when you need to
#' interactively explore the R objects in the book. The downside of
#' \code{in_session = TRUE} is that the output may be different with the book
#' compiled from a fresh R session, because the state of the current R session
#' may not be clean.
#'
#' For \code{in_session = FALSE}, you do not have access to objects in the book
#' from the current R session, but the output is more likely to be reproducible
#' since everything is created from new R sessions. Since this function is only
#' for previewing purposes, the cleanness of the R session may not be a big
#' concern. You may choose \code{in_session = TRUE} or \code{FALSE} depending on
#' your specific applications. Eventually, you should run \code{render_book()}
#' from a fresh R session to generate a reliable copy of the book output.
#' @param dir The root directory of the book (containing the Rmd source files).
#' @param output_dir The directory for output files; see
#'   \code{\link{render_book}()}.
#' @param preview Whether to render the modified/added chapters only, or the
#'   whole book; see \code{\link{render_book}()}.
#' @param in_session Whether to compile the book using the current R session, or
#'   always open a new R session to compile the book whenever changes occur in
#'   the book directory.
#' @param quiet Whether to suppress output (e.g., the knitting progress) in the
#'   console.
#' @param ... Other arguments passed to \code{servr::\link[servr:httd]{httw}()}
#'   (not including the \code{handler} argument, which has been set internally).
#' @export
serve_book = function(
  dir = '.', output_dir = '_book', preview = TRUE, in_session = TRUE, quiet = FALSE, ...
) {
  # when this function is called via the RStudio addin, use the dir of the
  # current active document
  if (missing(dir) && requireNamespace('rstudioapi', quietly = TRUE) &&
      rstudioapi::isAvailable()) {
    path = rstudioapi::getSourceEditorContext()[['path']]
    if (!(is.null(path) || path == '')) dir = dirname(path)
  }
  owd = setwd(dir); on.exit(setwd(owd), add = TRUE)
  if (missing(output_dir) || is.null(output_dir)) {
    on.exit(opts$restore(), add = TRUE)
    output_dir = load_config()[['output_dir']]
  }
  if (is.null(output_dir)) output_dir = '_book'
  if (missing(preview)) preview = getOption('bookdown.preview', TRUE)
  output_format = first_html_format()
  rebuild = function(..., preview_ = preview) {
    files = grep('[.]R?md$', c(...), value = TRUE, ignore.case = TRUE)
    i = match(sans_ext(book_filename()), sans_ext(basename(files)))
    if (!is.na(i)) files = files[-i]
    i = grep('[.](knit|utf8)[.]md$', files)
    if (length(i)) files = files[-i]
    if (length(files) == 0) return()
    # if the output dir has been deleted, rebuild the whole book
    if (!dir_exists(output_dir)) preview_ = FALSE
    if (in_session) render_book(
      files, output_format, output_dir = output_dir, preview = preview_,
      envir = globalenv(), quiet = quiet
    ) else {
      args = shQuote(c(
        bookdown_file('scripts', 'servr.R'), output_format, output_dir, preview_,
        quiet, files
      ))
      if (Rscript(args) != 0) stop('Failed to compile ', paste(files, collapse = ' '))
    }
  }
  index <- get_index_file()
  if (is_empty(index)) {
    stop("`serve_book()` expects `index.Rmd` in the book project.", call. = FALSE)
  }
  rebuild(index, preview_ = FALSE)  # build the whole book initially
  servr::httw('.', ..., site.dir = output_dir, handler = rebuild)
}

get_index_file <- function() {
  index_files <- list.files('.', '^index[.]Rmd$', ignore.case = TRUE)
  if (length(index_files) == 0) return(character())
  index <- index_files[1]
  if (length(index_files) > 1) {
    warning(
      sprintf(
        "Several index files found - only one expected. %s will be use, please check your project.",
        sQuote(index)
      ))
  }
  index
}

# can only preview HTML output via servr, so look for the first HTML format
first_html_format = function() {
  fallback = 'bookdown::gitbook'
  html_format = function(f) grep('gitbook|html|bs4_book', f, value = TRUE)
  get_output_formats(fallback, html_format, first = TRUE)
}

get_output_formats = function(fallback_format, filter = identity, first = FALSE, fallback_index = NULL) {
  # Use index files if one exists
  index = get_index_file()
  # Use fallback file unless no YAML
  if (is_empty(index)) {
    if (length(fallback_index) == 1 &&
        xfun::file_exists(fallback_index) &&
        length(rmarkdown::yaml_front_matter(fallback_index)) != 0
    ) {
      index = fallback_index
    } else {
      return(fallback_format)
    }
  }
  # Retrieve output formats
  formats = rmarkdown::all_output_formats(index)
  formats = filter(formats)
  if (length(formats) == 0) return(fallback_format)
  if (first) return(formats[1])
  formats
}

# base64 encode resources in url("")
base64_css = function(css, exts = 'png', overwrite = FALSE) {
  x = read_utf8(css)
  r = sprintf('[.](%s)$', paste(exts, collapse = '|'))
  m = gregexpr('url\\("[^"]+"\\)', x)
  regmatches(x, m) = lapply(regmatches(x, m), function(ps) {
    if (length(ps) == 0) return(ps)
    ps = gsub('^url\\("|"\\)$', '', ps)
    sprintf('url("%s")', sapply(ps, function(p) {
      if (grepl(r, p) && file.exists(p)) xfun::base64_uri(p) else p
    }))
  })
  if (overwrite) write_utf8(x, css) else x
}

files_cache_dirs = function(dir = '.') {
  if (!dir_exists(dir)) return(character())
  r = '_(files|cache)$'
  out = list.files(dir, r, full.names = TRUE)
  out = out[dir_exists(out)]
  # only use dirs that have corresponding Rmd files
  if (dir == '.') out = out[file.exists(sub(r, '.Rmd', out))]
  out = out[basename(out) != '_bookdown_files']
  out
}

#' @importFrom xfun existing_files
existing_r = function(base) {
  x = apply(expand.grid(base, c('R', 'r')), 1, paste, collapse = '.')
  existing_files(x)
}

target_format = function(format) {
  if (grepl('(html|gitbook|bs4)', format)) return('html')
  if (grepl('pdf', format)) return('latex')
  if (grepl('beamer_', format)) return('latex')
  if (grepl('epub_', format)) return('epub')
  if (grepl('word_', format)) return('docx')
  if (grepl('powerpoint_', format)) return('pptx')
  switch(format,
         tufte_book2 = 'latex', `bookdown::tufte_book2` = 'latex',
         tufte_handout2 = 'latex', `bookdown::tufte_handout2` = "latex")
}

verify_rstudio_version = function() {
  if (requireNamespace('rstudioapi', quietly = TRUE) && rstudioapi::isAvailable()) {
    if (!rstudioapi::isAvailable('0.99.1200')) warning(
      'Please install a newer version of the RStudio IDE: ',
      'https://posit.co/download/rstudio-desktop/'
    )
  } else if (!rmarkdown::pandoc_available('1.17.2')) warning(
    "Please install or upgrade Pandoc to at least version 1.17.2; ",
    "or if you are using RStudio, you can just install RStudio 1.0+."
  )
}

str_trim = function(x) gsub('^\\s+|\\s+$', '', x)

if (getRversion() < '4.4.0') `%||%` = function(x, y) if (is.null(x)) y else x

output_md = function() getOption('bookdown.output.markdown', FALSE)

# a theorem engine for knitr (can also be used for lemmas, definitions, etc)
eng_theorem = function(type, env) {
  function(options) {
    v = if (knitr::pandoc_to(c('epub', 'epub2', 'epub3', 'docx', 'pptx', 'odt'))) '1' else '2'
    i = sprintf('eng_%s%s', env, v)
    f = eng_funcs[[i]]
    f(type, options)
  }
}
# TODO: remove eng_theorem1(), eng_proof1(), and process_block() when
# https://github.com/rstudio/bookdown/issues/1179 is resolved
eng_funcs = list(
  eng_theorem1 = function(type, options) {
    options$type = type
    label = paste(theorem_abbr[type], options$label, sep = ':')
    html.before2 = sprintf('(\\#%s) ', label)
    name = options$name; to_md = output_md()
    if (length(name) == 1) {
      if (to_md) {
        html.before2 = paste(html.before2, sprintf('(%s) ', name))
      } else {
        options$latex.options = sprintf('[%s]', name)
        html.before2 = paste(html.before2, sprintf('\\iffalse (%s) \\fi{} ', name))
      }
    }
    options$html.before2 = sprintf(
      '<span class="%s" id="%s"><strong>%s</strong></span>', type, label, html.before2
    )
    process_block(options, to_md)
  },
  eng_theorem2 = function(type, options) {
    label = paste0('#', options$label)
    name = sprintf('name="%s"', options$name)
    res = paste(c(paste0('.', type), label, name), collapse = ' ')
    paste(c(sprintf('::: {%s}', res), options$code, ':::'), collapse = '\n')
  },
  eng_proof1 = function(type, options) {
    options$type = type
    label = label_prefix(type, label_names_math2)()
    name = options$name; to_md = output_md()
    if (length(name) == 1) {
      if (!to_md) options$latex.options = sprintf('[%s]', sub('[.]\\s*$', '', name))
      r = '^(.+?)([[:punct:][:space:]]+)$'  # "Remark. " -> "Remark (Name). "
      if (grepl(r, label)) {
        label1 = gsub(r, '\\1', label)
        label2 = paste0(' (', name, ')', gsub(r, '\\2', label))
      } else {
        label1 = label; label2 = ''
      }
      label = sprintf('<em>%s</em>%s', label1, label2)
    } else {
      label = sprintf('<em>%s</em>', label)
    }
    options$html.before2 = sprintf(
      '<span class="%s">%s</span> ', type, label
    )
    if (!to_md) options$html.before2 = paste('\\iffalse{}', options$html.before2, '\\fi{}')
    process_block(options, to_md)
  },
  eng_proof2 = function(type, options) {
    name = sprintf('name="%s"', options$name)
    res = paste(c(paste0('.', type), name), collapse = ' ')
    paste(c(sprintf('::: {%s}', res), options$code, ':::'), collapse = '\n')
  }
)

process_block = function(options, md) {
  if (md) {
    code = options$code
    code = knitr:::pandoc_fragment(code)
    r = '^<p>(.+)</p>$'
    if (length(code) > 0 && grepl(r, code[1])) code[1] = gsub(r, '\\1', code[1])
    options$code = code
  }
  knitr:::eng_block2(options)
}

register_eng_math = function() {
  lapply(c('theorem', 'proof'), function(env) {
    envs = names(if (env == 'theorem') theorem_abbr else label_names_math2)
    knitr::knit_engines$set(setNames(lapply(envs, eng_theorem, env = env), envs))
  })
}

pandoc2.0 = function() rmarkdown::pandoc_available('2.0')

# remove the body of the LaTeX document; only keep section headers and
# figure/table captions
strip_latex_body = function(x, alt = '\nThe content was intentionally removed.\n') {
  i = which(x == '\\mainmatter')
  if (length(i) == 0) i = which(x == '\\begin{document}')
  x1 = head(x, i[1])  # preamble (or frontmatter)
  x2 = tail(x, -i[1]) # body
  i = grep('^\\\\(part|chapter|(sub)*section)\\*?\\{', x2)  # headers
  x2[i] = sub('}}$', '}\n', x2[i])  # get rid of the closing } from \hypertarget{
  x2[i] = paste0(x2[i], alt)
  i = c(i, grep('^\\\\bibliography', x2))
  # extract figure/table environments
  envs = list(
    fig = c('figure', '.*(\\\\caption\\{.+})\\\\label\\{fig:.+}.*'),
    tab = c('table', '^(\\\\caption\\{\\\\label\\{tab:.+}).*')
  )
  for (j in names(envs)) {
    r = envs[[j]][2]; i2 = grep(r, x2); env = envs[[j]][1]
    x2[i2] = sprintf('\\begin{%s}%s\\end{%s}\n', env, gsub(r, '\\1', x2[i2]), env)
    i = c(i, i2)
  }
  c(x1, x2[sort(i)], '\\end{document}')
}

# bookdown Lua filters paths
lua_filter = function (filters = NULL) {
  rmarkdown::pkg_file_lua(filters, package = 'bookdown')
}

# pass _bookdown.yml to Pandoc's Lua filters
bookdown_yml_arg = function(config = load_config(), path = tempfile()) {
  # this is supported for Pandoc >= 2.3 only
  if (!rmarkdown::pandoc_available('2.3') || length(config) == 0) return()
  yaml::write_yaml(list(bookdown = config), path)
  c("--metadata-file", rmarkdown::pandoc_path_arg(path))
}

#' Convert the syntax of theorem and proof environments from code blocks to
#' fenced Divs
#'
#' This function converts the syntax \samp{```{theorem, label, ...}} to
#' \samp{::: {.theorem #label ...}} (Pandoc's fenced Div) for theorem
#' environments.
#' @param input Path to an Rmd file that contains theorem environments written
#'   in the syntax of code blocks.
#' @param text A character vector of the Rmd source. When \code{text} is
#'   provided, the \code{input} argument will be ignored.
#' @param output The output file to write the converted input content. You can
#'   specify \code{output} to be identical to \code{input}, which means the
#'   input file will be overwritten. If you want to overwrite the input file,
#'   you are strongly recommended to put the file under version control or make
#'   a backup copy in advance.
#' @references Learn more about
#'   \href{https://bookdown.org/yihui/bookdown/markdown-extensions-by-bookdown.html#theorems}{theorems
#'    and proofs} and
#'   \href{https://bookdown.org/yihui/rmarkdown-cookbook/custom-blocks.html}{custom
#'    blocks} in the \pkg{bookdown} book.
#' @return If \code{output = NULL}, the converted text is returned, otherwise
#'   the text is written to the output file.
#' @export
fence_theorems = function(input, text = xfun::read_utf8(input), output = NULL) {
  # identify blocks
  md_pattern = knitr::all_patterns$md
  block_start = grep(md_pattern$chunk.begin, text)
  # extract params
  params = gsub(md_pattern$chunk.begin, "\\1", text[block_start])
  # find block with custom environment engine
  reg = sprintf("^(%s).*", paste(all_math_env, collapse = "|"))
  to_convert = grepl(reg, params)
  # only modify those blocks
  params = params[to_convert]
  block_start = block_start[to_convert]
  block_end = grep(md_pattern$chunk.end, text)
  block_end = vapply(block_start, function(x) block_end[block_end > x][1], integer(1))
  # add a . to engine name
  params = sprintf(".%s", params)
  # change implicit label to id
  params = gsub("^([.][a-zA-Z0-9_]+(?:\\s*,\\s*|\\s+))([-/[:alnum:]]+)(\\s*,|\\s*$)", "\\1#\\2", params)
  # change explicit label to id
  params = gsub("label\\s*=\\s*\"([-/[:alnum:]]+)\"", "#\\1", params)
  # clean , and spaces
  params = gsub("\\s*,\\s*", " ", params)
  params = gsub("\\s*=\\s*", "=", params)
  # modify the blocks
  text[block_start] = sprintf("::: {%s}", params)
  text[block_end] = ":::"
  # return the text or write to output file
  if (is.null(output)) xfun::raw_string(text) else xfun::write_utf8(text, output)
}

stop_if_not_exists = function(inputs) {
  if (!all(exist <- xfun::file_exists(inputs))) {
    stop("Some files were not found: ",  paste(inputs[!exist], collapse = ' '))
  }
}

is_empty = function(x) {
  length(x) == 0 || !nzchar(x)
}
