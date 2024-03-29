#' Download OSM Data
#' 
#' Hany Nagaty
#' Dec-2023
#' 


library(osmdata)
library(pins)
library(purrr)

# Inititalisation ----

# conf file
if (.Platform$OS.type == "Windows") {
  conf_file <- "D:/DataAnalytics/~Configs/globalConf.yaml"
} else if (.Platform$OS.type == "unix") {
  conf_file <- "~/MEGA/myDataScience/conf/globalConf.yaml"
} else {
  stop("Unsupported OS:", .Platform$OS.type, ". Config file not loaded. Aborting execution.")
}
global_conf <- yaml::read_yaml(conf_file)
egypt_box <- global_conf$geoBorders$egypt
cairo_box <- global_conf$geoBorders$cairo


# pin board
if (.Platform$OS.type == "Windows") {
  board <- board_folder(global_conf$pins$boardW)
} else {
  board <- board_folder(global_conf$pins$boardL)
}
pin_name <- global_conf$pins$osmI
message('Using this board: ', board$path)
message('Using this pin: ', pin_name)

# OverPass URL
set_overpass_url("https://maps.mail.ru/osm/tools/overpass/api/interpreter")

# User Function ----
#| label: userFunctions
#' Summarise an osmdata object
#' Data downloaded by osmdata is a list of sf object. This function
#' inspects this object, and lists the sf features within this object. 
#' Each feature also has the number of rows and the number of columns.
#'
#' @param osm osmdata object. An object downloaded via the omsdata library.
#'
#' @return a dataframe
summarise_osm <- function(osm) {
  interests <- grep("osm_", names(osm), value = TRUE)
  rows <- c()
  cols <- c()
  layers <- c()
  for (interest in interests) {
    rows <- c(rows, nrow(osm[[interest]]))
    cols <- c(cols, ncol(osm[[interest]]))
    if (!is.null(osm[[interest]])) {
      layers <- c(layers, str_to_title(str_extract(interest, "(?<=osm_).*")))
    }
  }
  return(tibble(
    Layer = layers,
    Rows = rows,
    Cols = cols))
}



#' List NA columns
#' Lists columns that has their NA count greater than or equal to
#' a given threshold.
#'
#' @param df A data.frame
#' @param thr numeric, between 0 and 1. The NA threshold to use.
#' 1 will return columns that has all NA. 0 will return all columns.
#'
#' @return named vector. The value is the NA count ratio in each column, 
#' the name is the name of the column.
na_cols <- function(df, thr = 0.5) {
  na_ratio <- colSums(is.na(df))/nrow(df)
  return(na_ratio[na_ratio >= thr])
}



make_osm_list <- function(osm_objects) {
  require(stringr)
  res_list <- list()
  for (obj in osm_objects) {
    obj_name <- str_to_title(obj)
    obj <- paste0("osm_", obj)
    if (exists(obj)) {
      res_list[[obj_name]] <- get(obj)
      message(paste("Adding", obj, "to the save list."))
    } else {
      message(paste(obj, "doesn't exist and will not be saved."))
    }
  }
  return(res_list)
}



#' Downloads an OSM Feature
#' Download an OSM feature, using the provided key & value
#' @param bbox a matrix, vector or object returned by osmdata::getbb()
#' @param key character. The key to use for the Overpass query.
#' @param value character. The query value. Default is NULL. If Null,
#' then query all available values.
#' @return returns the downloaded data invisibly.
#' The function is called mainly for its side effect. It assigns
#' the downloaded layer to a variable named osm_<key>
download_osm <- function(bbox, key, value = NULL) {
  message(paste("Now downloading osm layer: ", key, "..."))
  if (is_null(value)) {
    res <- opq(bbox) |>
      add_osm_feature(key = key) |> 
      osmdata_sf()
  } else {
    res <- opq(bbox) |>
      add_osm_feature(key = key, value = value) |> 
      osmdata_sf()
  }
  assign(paste0("osm_", key), res, envir = .GlobalEnv) #parent.frame())
}



#' Clean an OSM Data Object
#' Cleans on osmdata object (that generated by osmdata library)
#' It simply 
#' a. removes columns that have many NA (> thr)
#' b. combines all sub-layers into a single data frame
#'
#' @param osm_data on osm data object
#' @param drop_geom boolean. If TRUE, the drop the st geometry
#' @param drop_id boolean. If TRUE, the drop the osm_id column
#' @param double_clean boolean. If TRUE, then clean the NA columns
#' again after merging the sub-layers. Note that the drop threshold
#' here is hard coded at 0.9
#'
#' @return A dataframe or an sf object (according to drop_geom)
clean_osmdata <- function(
    osm_data,
    drop_geom = FALSE,
    drop_id = FALSE,
    double_clean = FALSE,
    ...) {
  layer_name <- osm_data$overpass_call |> 
    str_extract("(?<=node).*(?=\\])") |>
    str_extract('(?<=").*?(?=")')
  res <- map_dfr(
    osm_data,
    clean_osm_layer,
    .id = "layer",
    layer = layerName,
    ...)
  if (drop_id) {
    res <- select(res, -osm_id)
  }
  if (double_clean) {
    res <- clean_osm_layer(
      res, 
      layer_name = layer_name, 
      thr = 0.9,
      ...)
  }
  if (drop_geom) {
    res <- st_drop_geometry(res)
  }
  return(res)
}



#' Clean an SF object
#' Cleans an sf object. It simply removes the columns that has hight
#' count of NAs, larger than thr.
#' It will also remove all columns named name.xx and description.xx,
#' and keep only the .ar and .en columns.
#'
#' @param osm_layer sf object
#' @param layer_name the layer name. The layer_name is excluded from column
#' deletion.
#' @param thr between 0 and 1
#' @param keep_na_rows logical. If FALSE, then drop rows that has no name
#' and layer. I don't always want to do this, for example in natural
#' features that have no name, e.g. coastline or borders.
#' Note also that dropping rows will impact the column filter for 
#' the same threshold value.
#' @param keep_cols a vector of column name I want to keep anyway.
#' @return sf object
clean_osm_layer <- function(
    osm_layer, 
    layer_name,
    thr = 0.9,
    keep_na_rows = TRUE,
    keep_cols = NULL) {
  if (class(osm_layer)[1] == "sf") {
    if (missing(layer_name)) {
      warning("Layer Name parameter is not provided, hence it may be dropped.")
    }
    res <- osm_layer
    if (!keep_na_rows) {
      res <- res |> 
        filter(!is.na(name) | !is.na(.data[[layer_name]]))
    }
    res <- res |> 
      select(
        -all_of(names(na_cols(res, thr = thr))),
        -contains("name."), # remove names in languages other than en or ar
        any_of(c("name", "name.ar", "alt_name.ar", "name.en", "alt_name.en")),
        -contains("description."), 
        any_of(c("description", "description.ar", "description.en")),
        any_of(keep_cols),
        {{ layer_name }})
    return(res)
  }
}

init_proxy <- function() {
  proxy <- global_conf$httpProxy
  proxy$password <- rstudioapi::askForPassword(prompt = "Proxy Password")
  proxy_str <- paste0(
    proxy$username, ":",
    proxy$password, "@",
    proxy$server, ":",
    proxy$port
  )
  Sys.setenv(http_proxy = proxy_str)
  Sys.setenv(https_proxy = proxy_str)
}

deinit_proxy <- function() {
  Sys.setenv(http_proxy = "")
  Sys.setenv(https_proxy = "")
}


# Download OSM ----

if (.Platform$OS.type == "Windows") {
  init_proxy()
}


interest <- c("railway", "waterway")
# walk(interest, possibly(~download_osm(egypt_box, .x), NULL, quiet = F))
download_osm(egypt_box, "highway", c("motorway", "trunk", "primary"))
download_osm(egypt_box, "railway", c("rail", "subway", "monorail"))
download_osm(egypt_box, "waterway", c("river"))

if (.Platform$OS.type == "Windows") {
  deinit_proxy()
}


# Save to pin ----

message("Saving pin ...")
pin_write(board, make_osm_list(interest), name = pin_name, 
          type = "rds",
          versioned = TRUE,
          title = "OSM Layers of Interest")
message("\nPin saved to pin ", pin_name, " in local board at ", board$path)
