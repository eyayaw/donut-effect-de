library(data.table)
library(sf)
source("script/helpers/helpers.R")

### This script ------------------------------------------------------------ ###
# 1) downloads shapes of Germany at all admin levels, and grid
# 2) cleans it and produce shape files for states, districts and municipalities
# 3) creates administrative levels: district & municipality names and codes
### ------------------------------------------------------------------------ ###

# Downloading ------------------------------------------------------------------

## Territorial Codes References, Administrative areas -------
## Federal Agency for Cartography and Geodesy (gdz.BKG-bund.de)
### website: https://gdz.bkg.bund.de/index.php/default/digitale-geodaten/verwaltungsgebiete.html?___store=default
### Administrative areas 1:250 000 (levels), as of December 31st (VG250 31.12.)
### It is based on the territorial definition of 2019 (end of the year).

furl = "https://daten.gdz.bkg.bund.de/produkte/vg/vg250_ebenen_1231/2019/vg250_12-31.utm32s.shape.ebenen.zip"
dname = "data/geodata/"
dir.create(dname, showWarnings = FALSE)
zfpath = sprintf("%s/%s", dname, basename(furl))

try(download_file(furl, zfpath))

# unzipping
suppressWarnings(unzip(zfpath, exdir = dname, overwrite = FALSE))
fpath = sprintf('%s/%s/dokumentation/struktur_und_attribute_vg250.xls', dname, file.stem(zfpath))
extract_dname = sprintf('%s/%s', dname, file.stem(zfpath)) # the extracted folder

## States, Bundesländer ---------------------
# source: https://www.destatis.de/DE/Themen/Laender-Regionen/Regionales/Gemeindeverzeichnis/Glossar/bundeslaender.html

states = read.table(
  text = "
  state_code state_name state_abb
  01 Schleswig-Holstein (SH)
  02 Hamburg (HH)
  03 Niedersachsen (NI)
  04 Bremen (HB)
  05 Nordrhein-Westfalen (NW)
  06 Hessen (HE)
  07 Rheinland-Pfalz (RP)
  08 Baden-Württemberg (BW)
  09 Bayern (BY)
  10 Saarland (SL)
  11 Berlin (BE)
  12 Brandenburg (BB)
  13 Mecklenburg-Vorpommern (MV)
  14 Sachsen (SN)
  15 Sachsen-Anhalt (ST)
  16 Thüringen (TH)
  ",
  header = TRUE, row.names = NULL, colClasses = rep("character", 3)
)


## Geographic grids for Germany in Lambert projection (GeoGitter Inspire) ----
grid_furl = "https://daten.gdz.bkg.bund.de/produkte/sonstige/geogitter/aktuell/DE_Grid_ETRS89-LAEA_1km.gpkg.zip"
grid_dname = "data/geodata/germany-grid"
grid_zfpath = sprintf("%s/%s", grid_dname, basename(grid_furl))
dir.create(grid_dname, showWarnings = FALSE)

try(download_file(grid_furl, grid_zfpath))
suppressWarnings(unzip(grid_zfpath, exdir = grid_dname, overwrite = FALSE))

de_grid = st_read(dir(grid_dname, ".*_1km.gpkg$", recursive = TRUE, full.names = TRUE))[, c("id", "geom")]
## EW_NS (note the rearrange \2_\1)
de_grid$grid_id = sub("1km[NS](\\d{4})[EW](\\d{4})", "\\2_\\1", de_grid$id)
st_geometry(de_grid) = "geometry"
de_grid = de_grid[, c("grid_id", "geometry")]

st_write(de_grid, "data/geodata/germany-grid/de-grid.gpkg", append = FALSE)
unlink(tools::file_path_sans_ext(grid_zfpath), recursive = TRUE)

# Cleaning ---------------------------------------------------------------

## administrative units ----
admin_areas = readxl::read_excel(fpath, sheet = "VG250")
names(admin_areas) = tolower(names(admin_areas))
ibz = readxl::read_excel(fpath, sheet = "VG250_IBZ") # attribute table
setDT(admin_areas)
setDT(ibz)
setDT(states)
admin_areas = admin_areas[, c(
  "ade", "ars", "ags", "gen", "ibz", "sn_l", "sn_r", "sn_k", "sn_v1", "sn_v2",
  "sn_g", "ars_0", "ags_0"
), with = FALSE]

setnames(
  admin_areas,
  c("sn_l", "sn_r", "sn_k", "sn_v1", "sn_v2", "sn_g"),
  c("state", "admin_district", "district", "admin_assoc_frontpart", "admin_assoc_rearpart", "municipality")
)
setnames(admin_areas, c("ade", "gen", "ibz"), c("admin_level", "name", "admin_unit"))

ibz = ibz[, .(admin_unit = IBZ, bez = BEZ)]
ibz = unique(ibz, by = c("admin_unit", "bez"))
admin_areas = merge(admin_areas, ibz, "admin_unit")

### districts ----
districts = admin_areas[admin_level == 4L, !"admin_level"] # Kreise

## since we kept only ADE == 4 (i.e. districts), ARS should be the same as AGS
if (with(districts, all(ags == ars))) {
  message("AGS == ARS")
  districts[, ars := NULL]
  setcolorder(districts, "ags")
}

districts = districts[, .(ags, name, state, admin_unit = paste0(admin_unit, "-", bez))]


# merge with the states data.frame for state_abb
districts = districts[states[, c("state_code", "state_abb")], on = "state==state_code"
                      ][, state := NULL]

setnames(districts, "state_abb", "state")
setcolorder(districts, "state", after = "name")

### municipalities ----
municips = admin_areas[admin_level == 6L, .(
  ags, geo_name = name, district_ags = paste0(state, admin_district, district),
  admin_unit = paste0(admin_unit, "-", bez)
  )
]

# merge with the districts data.frame for district id and name
municips = municips[districts[, .(district_ags = ags, district_name = name, state)],
  on = "district_ags"
]
setcolorder(municips, c("district_name", "state"), after = "district_ags")

## Shapes ---------------------------------------------------------------------
# In the "Levels" (Ebenen) version, <the data are structured according to levels (country/state, Länder (federal states),
# Regierungsbezirke (administrative districts), Kreise (districts/counties),
# Verwaltungsgemeinschaften (administrative associations), Gemeinden (municipalities),
# whereby the areas contained are directly carrying the attributive information.>

shape_path = sprintf("%s/VG250_GEM.shp", dir(extract_dname, "vg250_ebenen_1231", full.names = TRUE))
municips_shape = st_read(shape_path)

## Filter by GF = Geofactor : Survey of values
                          # 1 = Waters without structures
                          # 2 = Waters with structures
                          # 3 = Land without structure
                          # 4 = Land with structure
names(municips_shape) = tolower(names(municips_shape))
municips_shape = subset(municips_shape, gf == 4L, select = c("ags", "geometry"))
municips_shape = merge(municips_shape, municips, "ags")

## districts shape
districts_shape = st_read(sub("GEM", "KRS", shape_path)) |>
   {\(.x) setNames(.x, tolower(names(.x)))}() |>
  subset(gf == 4L, select = c("ags", "geometry")) |>
  merge(districts, "ags")


### add municipality info to the grid --via spatial join ----
de_grid = st_transform(de_grid, st_crs(municips_shape))
de_grid = st_join(de_grid, municips_shape, join=st_contains_properly, left=FALSE, largest=TRUE)
de_grid = de_grid[, c("grid_id", "ags", "geo_name", "district_ags", "district_name", "geometry")]


# write to disk -----
## admin area names, codes
dname = "data/geodata/admin-areas"
dir.create(dname, showWarnings = FALSE)
fwrite(municips, file.path(dname, "municipalities_bkg.csv"))
fwrite(districts, file.path(dname, "districts_bkg.csv"))
fwrite(states, file.path(dname, "states.csv"))

## admin area shapes
st_write(municips_shape, file.path(dname, "municipalities.gpkg"), append = FALSE)
st_write(districts_shape, file.path(dname, "districts.gpkg"), append = FALSE)


## grids with admin info (municipalities)
st_write(de_grid, file.path(dname, "grid-germany_with-admin-areas.gpkg"), append = FALSE)
fwrite(st_drop_geometry(de_grid), file.path(dname, "grid-germany_with-admin-areas.csv"))
