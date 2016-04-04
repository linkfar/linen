workbook <- function(style, sheets=NULL) {
  .R6_workbook$new(style, sheets)
}

worksheet <- function(cells, merged, workbook=NULL) {
  .R6_worksheet$new(cells, merged, workbook)
}

##' @importFrom R6 R6Class
.R6_workbook <- R6::R6Class(
  "workbook",
  public=list(
    sheets=NULL,
    style=NULL,

    ## TODO: this needs some sort of nice "reference" concept (path,
    ## id, etc), perhaps also a hook for updating or checking if we're
    ## out of date, etc.
    initialize=function(style, sheets) {
      self$style <- style
      self$sheets <- sheets
    }
  ))

.R6_worksheet <- R6::R6Class(
  "worksheet",

  public=list(
    cells=NULL,
    dim=NULL,
    pos=NULL,
    merged=NULL,
    lookup=NULL,
    lookup2=NULL,

    workbook=NULL,

    ## TODO: Need to get the name of the worksheet in here.
    initialize=function(cells, merged, workbook) {
      self$cells <- cells
      self$merged <- merged
      self$workbook <- workbook
      ## Spun out because it's super ugly:
      worksheet_init(self)

      self$workbook$sheets <- c(self$workbook$sheets, self)
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
    for (j in seq_along(cells)) {
      cells[[j]] <- cells[[j]][i]
    }
    cells_pos <- cells_pos[i, , drop=FALSE]
    tmp <- rbind(cells_pos, t(vapply(merged, function(el) el$lr, integer(2))))
    dim <- apply(tmp, 2, max)
  } else {
    dim <- apply(cells_pos, 2, max)
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
  ## First, let's give an overview?
  dim <- x$dim
  cat(sprintf("<xlsx data: %d x %d>\n", dim[[1]], dim[[2]]))

  ## Helper for the merged cells.
  print_merge <- function(el) {
    anc <- "\U2693"
    left <- "\U2190"
    up <- "\U2191"
    ul <- "\U2196"

    d <- dim(el)
    anchor <- el$ul
    loc <- loc_merge(el)
    if (d[[1]] == 1L) {
      str <- rep(left, d[[2L]])
    } else if (d[[2L]] == 1L) {
      str <- rep(up, d[[1L]])
    } else {
      str <- matrix(ul, d[[1]], d[[2]])
      str[1L, ] <- left
      str[, 1L] <- up
    }
    str[[1L]] <- anc
    list(loc=loc, str=str)
  }

  m <- matrix(NA, dim[[1]], dim[[2]])
  for (el in x$merged) {
    tmp <- print_merge(el)
    m[tmp$loc] <- tmp$str
  }

  pos <- x$pos
  m[pos[x$cells$is_formula & x$cells$is_number, , drop=FALSE]] <- "="
  m[pos[x$cells$is_formula & x$cells$is_text,   , drop=FALSE]] <- "$"
  m[pos[x$cells$is_formula & x$cells$is_bool,   , drop=FALSE]] <- "!"
  m[pos[x$cells$is_formula & x$cells$is_date,   , drop=FALSE]] <- "#"
  m[pos[x$cells$is_value   & x$cells$is_number, , drop=FALSE]] <- "0"
  m[pos[x$cells$is_value   & x$cells$is_text,   , drop=FALSE]] <- "a"
  m[pos[x$cells$is_value   & x$cells$is_bool,   , drop=FALSE]] <- "b"
  m[pos[x$cells$is_formula & x$cells$is_date,   , drop=FALSE]] <- "d"
  m[is.na(m)] <- " "

  mm <- rbind(rep(LETTERS, length.out=dim[[2]]), m)
  cat(paste(sprintf("%s: %s\n",
                    format(c("", seq_len(dim[[1]]))),
                    apply(mm, 1, paste, collapse="")), collapse=""))
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
    cols <- seq.int(anchor[[2]], by=1L, length.out=d[[2L]])
    rows <- seq.int(anchor[[1]], by=1L, length.out=d[[1L]])
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

cells <- function(ref, style, value, formula,
                  is_formula, is_value, is_blank,
                  is_bool, is_number, is_text, is_date) {
  n <- length(ref)
  assert_length(style, n)
  assert_length(formula, n)
  assert_length(value, n)
  assert_length(is_formula, n)
  assert_length(is_value, n)
  assert_length(is_blank, n)
  assert_length(is_bool, n)
  assert_length(is_number, n)
  assert_length(is_text, n)
  assert_length(is_date, n)

  assert_character(ref) # check with a regexp?
  assert_integer(style)

  assert_list(value)
  assert_list(formula)

  assert_logical(is_formula)
  assert_logical(is_value)
  assert_logical(is_blank)
  assert_logical(is_bool)
  assert_logical(is_number)
  assert_logical(is_text)
  assert_logical(is_date)

  tibble::data_frame(ref, style, value, formula,
                     is_formula, is_value, is_blank,
                     is_bool, is_number, is_text, is_date)
}