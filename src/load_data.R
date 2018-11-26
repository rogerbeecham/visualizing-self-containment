# load_data
#
# Author: Roger Beecham
###############################################################################

# Origin-Desination data by occupation published via UK Data Service. 
# https://www.ukdataservice.ac.uk
data  <- read_csv("./data/wicid_output_occupation.csv")
# Get msoa_lad lookup.
# From: https://ons.maps.arcgis.com/home/item.html?id=552fd4886ebe417fab71da61555d4f8a
temp_lookup <-  read_csv("./data/msoa_lad_lookup.csv") %>% 
  rename("msoa_code"="MSOA11CD") %>%
  group_by(msoa_code) %>% 
  summarise(msoa_name=first(MSOA11NM),
            lad_code=first(LAD11CD),
            lad_name=first(LAD11NM))
# Upload london_squared layout: https://aftertheflood.com/projects/future-cities-catapult/ 
london_squared <- read_csv("./data/london_squared.csv") %>% select(fX,fY, authority, BOR, panel) %>% mutate(panel=as.factor(panel))
# Reverse northing cells.
max_y <- max(london_squared$fY)
min_y <- min(london_squared$fY)
london_squared <- london_squared %>% mutate(fY=map_scale(fY, min_y, max_y, max_y, min_y))
rm(min_y,max_y)
# Inner_join on london_squared and temp_lookup to filter out London msoas in lookup table.
temp_lookup <- temp_lookup %>% inner_join(london_squared %>% select(authority), by=c("lad_name"="authority"))
# Lookup to LAD: summarise over occupation.
data <- data %>% 
  # origin lookup
  inner_join(temp_lookup, by=c("origin_msoa"="msoa_code")) %>% 
  rename("o_msoa"="origin_msoa", "o_lad"="lad_code") %>% 
  select(o_msoa:`9_elementary`,o_lad) %>%
  # destination lookup
  inner_join(temp_lookup, by=c("destination_msoa"="msoa_code")) %>% rename("d_msoa"="destination_msoa", "d_lad"="lad_code") %>%
  select(-msoa_name)
rm(temp_lookup)
# London has 983 msoas, so can check lookup with.
data %>% group_by(o_msoa) %>% summarise() %>% nrow() 
# And 33 LADs.
data %>% group_by(o_lad) %>% summarise() %>% nrow() 
# Summarise over LADs : on occupation
data <- data %>% 
  mutate(od_pair=paste(o_lad, d_lad, sep="-")) %>%
  group_by(od_pair, o_lad, d_lad) %>%
  summarise_at(vars(all:`9_elementary`), funs(sum(.)))
data <- data %>% ungroup()
# Read in shapefile containing GB LAD boundaries. 
# Made available from ONS Open Geography Portal. 
download.file("http://geoportal.statistics.gov.uk/datasets/8edafbe3276d4b56aec60991cbddda50_3.zip", "boundaries_gb.zip")
unzip("boundaries_gb.zip")
gb_boundaries <- read_sf("Local_Authority_Districts_December_2015_Super_Generalised_Clipped_Boundaries_in_Great_Britain.shp")
# Set CRS to OSGB.
gb_boundaries <- st_transform(gb_boundaries, crs=27700)
# Simplify polygon.
gb_boundaries <- ms_simplify(gb_boundaries, keep=0.2)
# Inner_join with data to filter London LADs.
temp_london_lads <- data %>% group_by(o_lad) %>% summarise()  %>% rename("ladcd"="o_lad")
london_boundaries <- gb_boundaries %>%
  inner_join(temp_london_lads, by=c("lad15cd"="ladcd")) 
rm(gb_boundaries)
# Calculate real centroids of LADs.
london_centroids <- london_boundaries %>%
  st_centroid() %>%
  st_coordinates() %>%
  as_tibble() %>%
  rename("east"="X", "north"="Y") %>%
  add_column(ladcd=london_boundaries %>% pull(lad15cd))
# Add centroids to OD data.
data <- data %>% left_join(london_centroids %>% select(east, north, ladcd), by=c("o_lad"="ladcd")) %>% rename("o_east"="east", "o_north"="north")
data <- data %>% left_join(london_centroids %>% select(east, north, ladcd), by=c("d_lad"="ladcd")) %>% rename("d_east"="east", "d_north"="north")
# Add in london_squared data.
london_centroids <- london_centroids %>% add_column(ladnm=london_boundaries %>% pull(lad15nm)) %>% 
  left_join(london_squared, by=c("ladnm"="authority"))
# Add fX fY postions for OD data.
data <- data %>% 
  left_join(london_centroids %>% select(ladcd, fX, fY, BOR), by=c("o_lad"="ladcd")) %>% 
  rename("o_fX"="fX", "o_fY"="fY", "o_bor"="BOR") %>%
  left_join(london_centroids %>% select(ladcd, fX, fY, BOR), by=c("d_lad"="ladcd")) %>% 
  rename("d_fX"="fX", "d_fY"="fY", "d_bor"="BOR")

# Demand-side summary.
demand_side <- data %>% 
  group_by(od_pair) %>%
  mutate(
    prof=sum(`1_managers_senior`,`2_professional`, `3_associate_professional`),
    non_prof=all-prof
  ) %>%
  ungroup() %>%
  select(od_pair, d_bor, o_bor, d_fY, d_fX, o_fY, o_fX, o_lad, d_lad, prof, non_prof) %>%
  group_by(d_bor) %>%
  mutate(
    prof_total_jobs=sum(prof), 
    # Jobs filled by local residents.
    prof_demand_side=if_else(o_bor==d_bor, prof/prof_total_jobs,0), 
    prof_max_jobs=max(prof),
    prof_rank=row_number(desc(prof)), 
    non_prof_total_jobs=sum(non_prof), 
    # Jobs filled by local residents.
    non_prof_demand_side=if_else(o_bor==d_bor, non_prof/non_prof_total_jobs,0), 
    non_prof_rank=row_number(desc(non_prof)), 
    non_prof_max_jobs=max(non_prof),
    bor_label=if_else(d_bor==o_bor,d_bor,"")) %>%
  ungroup() %>%  
  rename("bor_focus"="d_bor", "fY"="d_fY", "fX"="d_fX") 

# Supply-side summary.
supply_side <- data %>%
  group_by(od_pair) %>%
  mutate(
    prof=sum(`1_managers_senior`,`2_professional`, `3_associate_professional`),
    non_prof=all-prof
  ) %>%
  ungroup() %>%
  select(od_pair, d_bor, o_bor, o_fY, o_fX, d_fX, d_fY, o_lad, d_lad, prof, non_prof) %>%
  group_by(o_bor) %>%
  mutate(
    prof_total_workers=sum(prof), 
    prof_supply_side=if_else(o_bor==d_bor, prof/prof_total_workers,0), 
    prof_rank=row_number(desc(prof)), 
    prof_max_workers=max(prof),
    non_prof_total_workers=sum(non_prof), 
    non_prof_supply_side=if_else(o_bor==d_bor, non_prof/non_prof_total_workers,0), 
    non_prof_rank=row_number(desc(non_prof)), 
    non_prof_max_workers=max(non_prof),
    bor_label=if_else(d_bor==o_bor,d_bor,"")) %>% 
  ungroup() %>%  
  rename("bor_focus"="o_bor", "fY"="o_fY", "fX"="o_fX")