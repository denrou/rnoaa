#' Precipitation data from NOAA Climate Prediction Center (CPC)
#'
#' @export
#' @param date (date/character) date in YYYY-MM-DD format
#' @param us (logical) US data only? default: \code{FALSE}
#' @param drop_undefined (logical) drop undefined precipitation 
#' values (values in the \code{precip} column in the output data.frame). 
#' default: \code{FALSE}
#' @param ... curl options passed on to \code{\link[crul]{HttpClient}}
#' @return a data.frame, with columns:
#' \itemize{
#'  \item lon - longitude (0 to 360)
#'  \item lat - latitude (-90 to 90)
#'  \item precip - precipitation (in mm) (see Details for more information)
#' }
#'
#' @references \url{http://www.cpc.ncep.noaa.gov/}
#' ftp://ftp.cpc.ncep.noaa.gov/precip/CPC_UNI_PRCP
#' ftp://ftp.cpc.ncep.noaa.gov/precip/CPC_UNI_PRCP/GAUGE_CONUS/DOCU/PRCP_CU_GAUGE_V1.0CONUS_0.25deg.README
#' ftp://ftp.cpc.ncep.noaa.gov/precip/CPC_UNI_PRCP/GAUGE_GLB/DOCU/PRCP_CU_GAUGE_V1.0GLB_0.50deg_README.txt
#' https://www.esrl.noaa.gov/psd/data/gridded/data.unified.daily.conus.html
#'
#' @details
#' Rainfall data for the world (1979-present, resolution 50 km), and
#' the US (1948-present, resolution 25 km).
#' 
#' @section Data processing in this function:
#' Internally we multiply all precipitation measurements by 0.1 as 
#' per the CPC documentation. 
#' 
#' Values of -99.0 are classified as "undefined". These values can be
#' removed by setting \code{drop_undefined = TRUE} in the \code{cpc_prcp} 
#' function call. These undefined values are not dropped by default - 
#' so do remember to set \code{drop_undefined = TRUE} to drop them; or
#' you can easily do it yourself by e.g., \code{subset(x, precip >= 0)}
#'
#' @examples \dontrun{
#' cpc_prcp(date = "2017-01-15")
#' cpc_prcp(date = "2015-06-05")
#' cpc_prcp(date = "2017-01-15")
#' cpc_prcp(date = "2005-07-09")
#' cpc_prcp(date = "1979-07-19")
#'
#' # United States data only
#' cpc_prcp(date = "2005-07-09", us = TRUE)
#' cpc_prcp(date = "2009-08-03", us = TRUE)
#' cpc_prcp(date = "1998-04-23", us = TRUE)
#' 
#' # drop undefined values (those given as -99.0)
#' cpc_prcp(date = "1998-04-23", drop_undefined = TRUE)
#' }
cpc_prcp <- function(date, us = FALSE, drop_undefined = FALSE, ...) {
  assert(date, c("character", "Date"))
  assert(us, 'logical')
  dates <- str_extract_all_(date, "[0-9]+")[[1]]
  assert_range(dates[1], 1979:format(Sys.Date(), "%Y"))
  assert_range(as.numeric(dates[2]), 1:12)
  assert_range(as.numeric(dates[3]), 1:31)

  path <- cpc_get(year = dates[1], month = dates[2], day = dates[3],
                  us = us, ...)
  cpc_read(path, us, drop_undefined)
}

cpc_get <- function(year, month, day, us, cache = TRUE, overwrite = FALSE, ...) {
  cpc_cache$mkdir()
  key <- cpc_key(year, month, day, us)
  file <- file.path(cpc_cache$cache_path_get(), basename(key))
  if (!file.exists(file)) {
    suppressMessages(cpc_GET_write(sub("/$", "", key), file, overwrite, ...))
  }
  return(file)
}

cpc_GET_write <- function(url, path, overwrite = TRUE, ...) {
  cli <- crul::HttpClient$new(
    url = url,
    headers = list(Authorization = "Basic anonymous:myrmecocystus@gmail.com")
  )
  if (!overwrite) {
    if (file.exists(path)) {
      stop("file exists and ovewrite != TRUE", call. = FALSE)
    }
  }
  res <- tryCatch(cli$get(disk = path, ...), error = function(e) e)
  if (inherits(res, "error")) {
    unlink(path)
    stop(res$message, call. = FALSE)
  }
  return(res)
}

cpc_base_ftp <- function(x) {
  base <- "ftp://ftp.cpc.ncep.noaa.gov/precip/CPC_UNI_PRCP"
  if (x) file.path(base, "GAUGE_CONUS") else file.path(base, "GAUGE_GLB")
}

cpc_base_file <- function(x) {
  base <- "PRCP_CU_GAUGE_V1.0%sdeg.lnx."
  if (x) sprintf(base, "CONUS_0.25") else sprintf(base, "GLB_0.50")
}

cpc_key <- function(year, month, day, us) {
  if (us) {
    rt_or_v1 <- if (year < 2007) "V1.0" else "RT"  
  } else {
    rt_or_v1 <- if (year < 2006) "V1.0" else "RT"
  }

  sprintf("%s/%s/%s/%s%s%s",
    cpc_base_ftp(us),
    rt_or_v1,
    year,
    cpc_base_file(us),
    paste0(year, month, day),
    if (year < 2006) {
      ".gz"
    } else if (year > 2005 && year < 2009) {
      if (us && year == 2006) {
        ".gz"
      } else if (!us && year == 2006) {
        "RT.gz"
      } else {
        ".RT.gz"
      }
    } else {
      ".RT"
    }
  )
}

cpc_read <- function(x, us, drop_undefined) {
  conn <- if (grepl("\\.gz$", x)) gzfile(x, "rb") else file(x, "rb")
  on.exit(close(conn))

  if (us) {
    bites <- 120 * 300 * 2
    lats <- seq(from = 20.125, to = 49.875, by = 0.25)
    longs <- seq(from = 230.125, to = 304.875, by = 0.25)
  } else {
    bites <- 360 * 720 * 2
    lats <- seq(from = 0.25, to = 89.75, by = 0.5)
    lats <- c(rev(lats * -1), lats)
    longs <- seq(from = 0.25, to = 359.75, by = 0.5)
  }

  # read data
  tmp <- readBin(conn, numeric(), n = bites, size = 4, endian = "little")
  tmp <- tmp[seq_len(bites/2)] * 0.1

  # make data.frame
  df <- tibble::as_data_frame(
    stats::setNames(
      cbind(expand.grid(longs, lats), tmp),
      c('lon', 'lat', 'precip')
    )
  )
  # remove undefined values
  if (drop_undefined) df <- subset(df, precip >= 0)
  return(df)
}
