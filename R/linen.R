##' Create a workbook object
##'
##' @title Create a workbook object
##' @param names Names of sheets within the workbook
##' @param style A big list of style information.  This is not yet
##'   validated and we'll change what goes on here at some point.
##' @param defined_names A data.frame of named ranges and other things
##'   that Excel puts into the \code{definedNames} section.
##' @export
workbook <- function(names, style, defined_names) {
  .R6_workbook$new(names, style, defined_names)
}

##' Create a worksheet object
##'
##' @title Create a worksheet object
##' @param name The name of the worksheet
##' @param cols columns
##' @param rows rows
##' @param cells A \code{tbl_df}, created by \code{\link{cells}}.
##' @param merged A list of \code{cell_limits} objects indicating
##'   merged cellls.  Can be an empty list if there are no merged
##'   cells.
##' @param view view
##' @param comments comments
##' @param workbook A workbook object.
##' @export
worksheet <- function(name, cols, rows, cells, merged, view, comments,
                      workbook) {
  ## There's more to come here, at least:
  ##
  ##   - ranges
  ##   - charts
  ##   - drawings
  ##   - frozen panes
  ##   - calc chain
  ##
  ## So expect the interface here to wildly thrash about a bit.
  ## Especially because some of those naturally belong at the
  ## worksheet level, rather than the worksheet level.  Support is
  ## being added as I get it working in rexcel.
  .R6_worksheet$new(name, cols, rows, cells, merged, view, comments, workbook)
}

##' Create a \code{tbl_df} of cell contents
##'
##' @title Create cell contents
##' @param ref A cell reference in A1 format
##' @param style An integer indicating which style to apply
##' @param type String describing the type of the cell.  Must be one
##'   of "blank", "bool", "date", "number" or "text".
##' @param value A \emph{list} of values (NULL values when blank)
##' @param formula A character vector of formulae (NA values when blank)
##' @export
cells <- function(ref, style, type, value, formula) {
  n <- length(ref)
  assert_character(ref) # check with a regexp?
  assert_length(style, n)
  assert_character(type) # check valid values?
  assert_length(formula, n)
  assert_length(value, n)

  assert_integer(style)

  assert_list(value)
  assert_character(formula)

  ## TODO: There are some blanks in here I need to get; formulae that
  ## yield zerolength strings, text cells that have no length.
  is_formula <- !is.na(formula)
  is_value <- lengths(value) > 0L& !is_formula

  is_blank <- type == "blank"
  is_bool <- type == "bool"
  is_number <- is_bool | type == "number"
  is_date <- type == "date"
  is_text <- type == "text"

  tibble::data_frame(ref, style, value, formula, type,
                     is_formula, is_value, is_blank,
                     is_bool, is_number, is_text, is_date)
}

##' @importFrom R6 R6Class
.R6_workbook <- R6::R6Class(
  "workbook",
  public=list(
    names=NULL,
    sheets=NULL,
    style=NULL,
    defined_names=NULL,

    ## TODO: this needs some sort of nice "reference" concept (path,
    ## id, etc), perhaps also a hook for updating or checking if we're
    ## out of date, etc.
    ## TODO: Validate style
    initialize=function(names, style, defined_names) {
      self$names <- names
      if (inherits(style, "linen_style")) {
        self$style <- style
      } else if (!is.null(style)) {
        stop("'style' must be NULL or a linen_style object")
      }
      self$defined_names <- defined_names
      self$sheets <- setNames(vector("list", length(names)), names)
    },

    ## TODO: name this vector too, once worksheet names are done.
    add_sheet=function(sheet) {
      self$sheets[[sheet$name]] <- sheet
    }
  ))

.R6_worksheet <- R6::R6Class(
  "worksheet",

  public=list(
    workbook=NULL,
    name=NULL,

    cols=NULL,
    rows=NULL,
    cells=NULL,
    merged=NULL,
    comments=NULL,
    view=NULL,

    dim=NULL,
    pos=NULL,
    lookup=NULL,
    lookup2=NULL,

    ## TODO: Need to get the name of the worksheet in here.
    initialize=function(name, rows, cols, cells, merged, view, comments,
                        workbook) {
      ## TODO: validate all the things
      self$name <- name
      self$cols <- cols
      self$rows <- rows
      self$cells <- cells
      self$merged <- merged
      self$view <- view
      self$comments <- comments
      self$workbook <- workbook
      ## Spun out because it's super ugly:
      worksheet_init(self)
      self$workbook$add_sheet(self)
    },
    values=function() {
      to_values(self)
    }),
  active=list(
    sheet=function() {
      self
    },
    xr=function() {
      cellranger::cell_limits(c(1, 1), self$dim)
    }
  ))

worksheet_init <- function(self) {
  cells_pos <- A1_to_matrix(self$cells$ref)
  merged <- self$merged

  ## I want to delete all merged cells from the cells list; forget
  ## about them as they inherit things from the anchor cell.
  if (length(merged) > 0L) {
    merged_pos <- lapply(merged, loc_merge, TRUE)
    merged_drop <- do.call("rbind", merged_pos)
    i <- match_cells(merged_drop, cells_pos)
    i <- -i[!is.na(i)]

    self$cells <- self$cells[i, ]
    cells_pos <- cells_pos[i, , drop=FALSE]
    tmp <- rbind(cells_pos, t(vapply(merged, function(el) el$lr, integer(2))))
    dim <- apply(rbind(0, tmp), 2, max)
  } else {
    dim <- apply(rbind(0, cells_pos), 2, max)
  }

  ## Now, build a look up table for all the cells.
  ## Lookup for "true" cells.
  lookup <- array(NA_integer_, dim)
  lookup[cells_pos] <- seq_len(nrow(cells_pos))

  ## A second table with merged cells, distinguished by being
  ## negative.  abs(lookup2) will give the correct value within the
  ## cells structure.
  if (length(merged) > 0L) {
    lookup2 <- lookup
    i <- match_cells(t(vapply(merged, function(x) x$ul, integer(2))), cells_pos)
    lookup2[merged_drop] <- -rep(i, vapply(merged_pos, nrow, integer(1)))
  } else {
    lookup2 <- lookup
  }

  self$dim <- dim
  self$pos <- cells_pos
  self$lookup <- lookup
  self$lookup2 <- lookup2
}

##' @export
print.worksheet <- function(x, ...) {
  cat(sprintf("<worksheet: %d x %d>\n", x$dim[[1L]], x$dim[[2L]]))
  fg <- bg <- NULL
  if (crayon::has_color()) {
    style <- style_lookup(x, fg="font/color", bg="fill/fg")
    if (!is.null(style)) {
      fg <- style$fg[x$cells$style]
      bg <- style$bg[x$cells$style]
    }
  }
  print_sheet(x, NULL, bg, fg)
  invisible(x)
}

loc_merge <- function(el, drop_anchor=FALSE) {
  d <- dim(el)
  anchor <- el$ul
  if (d[[1]] == 1L) {
    rows <- anchor[[1]]
    cols <- seq.int(anchor[[2]], by=1L, length.out=d[[2L]])
  } else if (d[[2L]] == 1L) {
    rows <- seq.int(anchor[[1]], by=1L, length.out=d[[1L]])
    cols <- anchor[[2]]
  } else {
    cols <- rep(seq.int(anchor[[2]], by=1L, length.out=d[[2L]]), each=d[[1L]])
    rows <- rep(seq.int(anchor[[1]], by=1L, length.out=d[[1L]]), d[[2L]])
  }
  ret <- cbind(row=rows, col=cols)
  if (drop_anchor) {
    ret[-1, , drop=FALSE]
  } else {
    ret
  }
}

match_cells <- function(x, table, ...) {
  ## assumes 2-column integer matrix
  x <- paste(x[, 1L], x[, 2L], sep="\r")
  table <- paste(table[, 1L], table[, 2L], sep="\r")
  match(x, table, ...)
}
